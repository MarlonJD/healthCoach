#if os(macOS)
import Foundation

public struct CodexAppServerConfiguration: Sendable {
    public var executableURL: URL
    public var mcpExecutableURL: URL
    public var snapshotURL: URL
    public var workingDirectory: URL
    public var modelID: String
    public var reasoningEffort: String
    public var serviceTier: String
    public var allowedMCPTools: Set<String>

    public init(
        executableURL: URL,
        mcpExecutableURL: URL,
        snapshotURL: URL,
        workingDirectory: URL,
        modelID: String = "gpt-5.6-luna",
        reasoningEffort: String = "max",
        serviceTier: String = "priority",
        allowedMCPTools: Set<String> = HealthCoachMCPToolCatalog.nameSet
    ) {
        self.executableURL = executableURL
        self.mcpExecutableURL = mcpExecutableURL
        self.snapshotURL = snapshotURL
        self.workingDirectory = workingDirectory
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.allowedMCPTools = allowedMCPTools
    }
}

public struct CodexTurnResult: Sendable, Equatable {
    public var threadID: String
    public var turnID: String
    public var assistantText: String
    public var rawTurn: Data

    public init(threadID: String, turnID: String, assistantText: String, rawTurn: Data) {
        self.threadID = threadID
        self.turnID = turnID
        self.assistantText = assistantText
        self.rawTurn = rawTurn
    }
}

public actor CodexAppServerClient {
    private struct Notification: Sendable {
        let method: String
        let params: Data
    }

    private let configuration: CodexAppServerConfiguration
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var outputBuffer = Data()
    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<Data, Error>] = [:]
    private var queuedNotifications: [Notification] = []
    private var notificationWaiters: [CheckedContinuation<Notification, Error>] = []
    private var sessionHome: URL?
    private var isInitialized = false
    private var activeThreadID: String?
    private var activeTurnID: String?
    private var effectiveTools: [String] = []

    public init(configuration: CodexAppServerConfiguration) {
        self.configuration = configuration
    }

    public func start() async throws {
        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: configuration.executableURL.path) else {
            throw HealthCoachError.unavailable("Codex App Server executable is not installed at the configured path.")
        }
        guard FileManager.default.isExecutableFile(atPath: configuration.mcpExecutableURL.path) else {
            throw HealthCoachError.unavailable("The HealthCoach MCP helper is not built.")
        }
        try FileManager.default.createDirectory(at: configuration.workingDirectory, withIntermediateDirectories: true)
        let home = configuration.workingDirectory.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try writeIsolatedConfig(at: home)
        try linkExistingCodexSignIn(to: home)

        let process = Process()
        process.executableURL = configuration.executableURL
        // The desktop installation can expose its first-party `codex_apps`
        // server when an existing sign-in is reused. Apps are outside the
        // HealthCoach data boundary, so disable the feature at the process
        // boundary as well as in the isolated config.
        process.arguments = ["app-server", "--listen", "stdio://", "--strict-config", "--disable", "apps"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        // Do not make unrelated developer or CI credentials visible to a
        // hosted model process, even though its configured tools are
        // read-only and the Apps feature is disabled.
        for key in [
            "GH_TOKEN", "GITHUB_TOKEN", "OPENAI_API_KEY", "ANTHROPIC_API_KEY",
            "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"
        ] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        process.currentDirectoryURL = configuration.workingDirectory
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] _ in
            Task { await self?.processExited() }
        }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.consume(data) }
        }
        // Drain diagnostics without persisting prompts, meal text, or model
        // output. The helper has no path to stdout, which is protocol-only.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        try process.run()
        self.process = process
        self.input = stdin.fileHandleForWriting
        self.output = stdout.fileHandleForReading
        self.sessionHome = home

        do {
            _ = try await request(
                method: "initialize",
                params: [
                    "clientInfo": ["name": "HealthCoach", "version": "1.0"],
                    "capabilities": [
                        "experimentalApi": false,
                        "optOutNotificationMethods": ["thread/started"]
                    ]
                ]
            )
            try sendNotification(method: "initialized", params: [:])
            let status = try await request(method: "mcpServerStatus/list", params: ["detail": "full"])
            guard let rawServers = status["data"] as? NSArray else {
                let dataShape = status["data"].map { String(describing: type(of: $0)) } ?? "missing"
                throw HealthCoachError.unavailable("HealthCoach App Server isolation could not be verified (unexpected MCP status shape: \(dataShape)).")
            }
            guard rawServers.count == 1 else {
                throw HealthCoachError.unavailable("HealthCoach App Server isolation could not be verified (expected one MCP server, found \(rawServers.count)).")
            }
            guard let server = rawServers.firstObject as? NSDictionary else {
                throw HealthCoachError.unavailable("HealthCoach App Server isolation could not be verified (MCP server entry is malformed).")
            }
            guard server["name"] as? String == "healthcoach" else {
                throw HealthCoachError.unavailable("HealthCoach App Server isolation could not be verified (unexpected MCP server name).")
            }
            guard let tools = server["tools"] as? NSDictionary else {
                throw HealthCoachError.unavailable("HealthCoach App Server isolation could not be verified (MCP tool catalog is unavailable).")
            }
            let toolNames = Set(tools.allKeys.compactMap { $0 as? String })
            guard toolNames == configuration.allowedMCPTools else {
                throw HealthCoachError.unavailable("The effective MCP catalog is not the HealthCoach read-only catalog.")
            }
            effectiveTools = toolNames.sorted()
            isInitialized = true
        } catch {
            await stop()
            throw error
        }
    }

    public func runTurn(prompt: String, outputSchema: Data, developerInstructions: String) async throws -> CodexTurnResult {
        guard isInitialized else { throw HealthCoachError.unavailable("Codex App Server is not initialized.") }
        let threadResponse = try await request(
            method: "thread/start",
            params: [
                "model": configuration.modelID,
                "serviceTier": configuration.serviceTier,
                "ephemeral": true,
                "cwd": configuration.workingDirectory.path,
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "developerInstructions": developerInstructions,
                "serviceName": "HealthCoach"
            ]
        )
        guard let thread = threadResponse["thread"] as? [String: Any], let threadID = thread["id"] as? String else {
            throw HealthCoachError.protocolError("thread/start did not return a thread id.")
        }
        let schemaObject = try JSONSerialization.jsonObject(with: outputSchema)
        let turnResponse = try await request(
            method: "turn/start",
            params: [
                "threadId": threadID,
                "input": [["type": "text", "text": prompt]],
                "outputSchema": schemaObject,
                "approvalPolicy": "never",
                "sandboxPolicy": ["type": "readOnly", "networkAccess": false],
                "effort": configuration.reasoningEffort,
                "serviceTierForTurn": configuration.serviceTier
            ]
        )
        guard let responseTurn = turnResponse["turn"] as? [String: Any], let turnID = responseTurn["id"] as? String else {
            throw HealthCoachError.protocolError("turn/start did not return a turn id.")
        }
        activeThreadID = threadID
        activeTurnID = turnID
        if let completed = try completedTurnIfTerminal(responseTurn, threadID: threadID, turnID: turnID) {
            activeThreadID = nil
            activeTurnID = nil
            return completed
        }
        while true {
            let notification = try await nextNotification()
            guard notification.method == "turn/completed" || notification.method == "error" else { continue }
            let params = try jsonObject(notification.params)
            if notification.method == "error" {
                let message = ((params["error"] as? [String: Any])?["message"] as? String) ?? "Codex reported an error."
                throw HealthCoachError.protocolError(message)
            }
            guard params["threadId"] as? String == threadID,
                  params["turnId"] as? String == turnID,
                  let completedTurn = params["turn"] as? [String: Any] else { continue }
            guard let result = try completedTurnIfTerminal(completedTurn, threadID: threadID, turnID: turnID) else {
                throw HealthCoachError.protocolError("Codex returned no terminal turn state.")
            }
            activeThreadID = nil
            activeTurnID = nil
            return result
        }
    }

    public func interrupt(threadID: String, turnID: String) async {
        _ = try? await request(method: "turn/interrupt", params: ["threadId": threadID, "turnId": turnID])
    }

    public func interruptActiveTurn() async {
        guard let threadID = activeThreadID, let turnID = activeTurnID else { return }
        await interrupt(threadID: threadID, turnID: turnID)
    }

    /// A cancellation can arrive while thread/start or turn/start is still
    /// pending, before an interruptible turn ID exists. In that case dispose
    /// of this per-job process so the worker cannot continue a cancelled turn.
    public func cancelActiveTurn() async {
        guard activeThreadID != nil, activeTurnID != nil else {
            await stop()
            return
        }
        await interruptActiveTurn()
    }

    public func stop() async {
        output?.readabilityHandler = nil
        process?.terminationHandler = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil
        output = nil
        isInitialized = false
        activeThreadID = nil
        activeTurnID = nil
        effectiveTools.removeAll()
        let error = HealthCoachError.cancelled
        for continuation in pendingRequests.values { continuation.resume(throwing: error) }
        pendingRequests.removeAll()
        for continuation in notificationWaiters { continuation.resume(throwing: error) }
        notificationWaiters.removeAll()
        queuedNotifications.removeAll()
        outputBuffer.removeAll()
    }

    public func sessionHomeURL() -> URL? {
        sessionHome
    }

    public func effectiveMCPTools() -> [String] {
        effectiveTools
    }

    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextRequestID
        nextRequestID += 1
        let data = try message(id: id, method: method, params: params)
        let responseData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            pendingRequests[id] = continuation
            do {
                guard let input else {
                    throw HealthCoachError.unavailable("Codex App Server input is closed.")
                }
                try input.write(contentsOf: data)
            } catch {
                pendingRequests.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
        let response = try jsonObject(responseData)
        if let error = response["error"] as? [String: Any] {
            throw HealthCoachError.protocolError((error["message"] as? String) ?? "Codex request failed.")
        }
        return response["result"] as? [String: Any] ?? [:]
    }

    private func sendNotification(method: String, params: [String: Any]) throws {
        guard let input else { throw HealthCoachError.unavailable("Codex App Server input is closed.") }
        try input.write(contentsOf: message(id: nil, method: method, params: params))
    }

    private func message(id: Int?, method: String, params: [String: Any]) throws -> Data {
        var object: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id { object["id"] = id }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0a)
        return data
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0a) {
            let line = outputBuffer.subdata(in: 0..<newline)
            outputBuffer.removeSubrange(0...newline)
            guard !line.isEmpty else { continue }
            guard let object = try? jsonObject(line) else { continue }
            if let id = object["id"] as? Int, let continuation = pendingRequests.removeValue(forKey: id) {
                continuation.resume(returning: line)
            } else if let method = object["method"] as? String {
                let params = (try? JSONSerialization.data(withJSONObject: object["params"] as? [String: Any] ?? [:], options: [.sortedKeys])) ?? Data("{}".utf8)
                let notification = Notification(method: method, params: params)
                if let waiter = notificationWaiters.first {
                    notificationWaiters.removeFirst()
                    waiter.resume(returning: notification)
                } else {
                    queuedNotifications.append(notification)
                }
            }
        }
    }

    private func nextNotification() async throws -> Notification {
        if !queuedNotifications.isEmpty { return queuedNotifications.removeFirst() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Notification, Error>) in
            notificationWaiters.append(continuation)
        }
    }

    private func completedTurnIfTerminal(_ turn: [String: Any], threadID: String, turnID: String) throws -> CodexTurnResult? {
        guard let status = turn["status"] as? String else { return nil }
        if status == "failed" || status == "interrupted" {
            let error = (turn["error"] as? [String: Any])?["message"] as? String ?? "Codex turn \(status)."
            throw HealthCoachError.protocolError(error)
        }
        guard status == "completed" else { return nil }
        let items = turn["items"] as? [[String: Any]] ?? []
        let messages = items.compactMap { item -> String? in
            guard item["type"] as? String == "agentMessage" else { return nil }
            return item["text"] as? String
        }
        guard let assistantText = messages.last, !assistantText.isEmpty else {
            throw HealthCoachError.invalidOutput("Codex completed without a structured assistant message.")
        }
        return CodexTurnResult(threadID: threadID, turnID: turnID, assistantText: assistantText, rawTurn: try jsonData(turn))
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HealthCoachError.protocolError("Codex returned a non-object JSON message.")
        }
        return object
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func writeIsolatedConfig(at home: URL) throws {
        let command = tomlString(configuration.mcpExecutableURL.path)
        let snapshot = tomlString(configuration.snapshotURL.path)
        let enabledTools = configuration.allowedMCPTools.sorted().map(tomlString).joined(separator: ", ")
        let config = """
        approval_policy = "never"
        sandbox_mode = "read-only"

        [apps._default]
        enabled = false
        open_world_enabled = false
        destructive_enabled = false

        [mcp_servers.healthcoach]
        command = \(command)
        args = ["--database", \(snapshot)]
        enabled = true
        required = true
        enabled_tools = [\(enabledTools)]
        """
        try Data(config.utf8).write(to: home.appendingPathComponent("config.toml"), options: [.atomic])
    }

    /// Reuses the user's supported Codex sign-in without copying auth data into
    /// HealthCoach storage. The per-job CODEX_HOME contains only a symlink to
    /// the existing CLI credential plus the generated restrictive config.
    private func linkExistingCodexSignIn(to home: URL) throws {
        let fileManager = FileManager.default
        let source = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
        guard fileManager.fileExists(atPath: source.path) else { return }
        let destination = home.appendingPathComponent("auth.json")
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        try fileManager.createSymbolicLink(at: destination, withDestinationURL: source)
    }

    private func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func processExited() {
        let error = HealthCoachError.unavailable("Codex App Server exited before completing the request.")
        for continuation in pendingRequests.values { continuation.resume(throwing: error) }
        pendingRequests.removeAll()
        for continuation in notificationWaiters { continuation.resume(throwing: error) }
        notificationWaiters.removeAll()
        process = nil
        isInitialized = false
        activeThreadID = nil
        activeTurnID = nil
    }
}

public enum CodexAppServerProbe {
    public static func defaultExecutableURL() -> URL? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex"
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func probe(executableURL: URL?) -> CodexStatus {
        guard let executableURL, FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return CodexStatus(readiness: .missingInstallation)
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["login", "status"]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return CodexStatus(readiness: .ready, executablePath: executableURL.path, modelID: "gpt-5.6-luna", reasoningEffort: "max")
            }
            return CodexStatus(readiness: .signInRequired, executablePath: executableURL.path, lastError: "Codex account sign-in is required.")
        } catch {
            return CodexStatus(readiness: .offline, executablePath: executableURL.path, lastError: "Codex readiness check failed.")
        }
    }
}
#endif
