#if os(macOS)
import Foundation

public struct JobWorkerOutcome: Equatable, Sendable {
    public var jobID: UUID
    public var status: JobStatus
    public var message: String?

    public init(jobID: UUID, status: JobStatus, message: String? = nil) {
        self.jobID = jobID
        self.status = status
        self.message = message
    }
}

public actor CodexJobWorker {
    public static let maxConcurrentJobs = 2
    public static let maxAttempts = 3

    private let store: HealthCoachStore
    private let codexExecutableURL: URL
    private let mcpExecutableURL: URL
    private let workRoot: URL
    private var activeClients: [UUID: CodexAppServerClient] = [:]
    private var activeJobIDs: Set<UUID> = []

    public init(store: HealthCoachStore, codexExecutableURL: URL, mcpExecutableURL: URL, workRoot: URL) {
        self.store = store
        self.codexExecutableURL = codexExecutableURL
        self.mcpExecutableURL = mcpExecutableURL
        self.workRoot = workRoot
    }

    public func runPending(onJobChange: (@MainActor @Sendable () async -> Void)? = nil) async -> [JobWorkerOutcome] {
        let pending = (try? store.pendingJobs()) ?? []
        guard !pending.isEmpty else { return [] }

        var outcomes: [JobWorkerOutcome] = []
        for start in stride(from: 0, to: pending.count, by: Self.maxConcurrentJobs) {
            let end = min(start + Self.maxConcurrentJobs, pending.count)
            let batch = Array(pending[start..<end])
            let batchOutcomes = await withTaskGroup(of: JobWorkerOutcome.self, returning: [JobWorkerOutcome].self) { group in
                for job in batch {
                    group.addTask { await self.runOutcome(jobID: job.id, onJobChange: onJobChange) }
                }
                var values: [JobWorkerOutcome] = []
                for await outcome in group {
                    values.append(outcome)
                }
                return values
            }
            outcomes.append(contentsOf: batchOutcomes)
        }
        return outcomes
    }

    public func run(jobID: UUID) async throws {
        try await run(jobID: jobID, onJobChange: nil)
    }

    private func runOutcome(jobID: UUID, onJobChange: (@MainActor @Sendable () async -> Void)?) async -> JobWorkerOutcome {
        do {
            try await run(jobID: jobID, onJobChange: onJobChange)
            return JobWorkerOutcome(jobID: jobID, status: .succeeded)
        } catch {
            let status = (try? store.job(id: jobID)?.status) ?? .deadLettered
            return JobWorkerOutcome(jobID: jobID, status: status, message: error.localizedDescription)
        }
    }

    private func run(jobID: UUID, onJobChange: (@MainActor @Sendable () async -> Void)?) async throws {
        guard let initialJob = try store.job(id: jobID) else { throw HealthCoachError.invalidInput("The job does not exist.") }
        guard initialJob.intent == .active, initialJob.status == .queued || initialJob.status == .running else {
            throw HealthCoachError.cancelled
        }
        guard try store.analysisPolicy().enabled else {
            throw HealthCoachError.unavailable("Analysis is paused on the iPhone.")
        }

        if initialJob.attempts >= Self.maxAttempts {
            let reason = initialJob.errorMessage ?? "The maximum retry attempts were exhausted."
            try store.recordMacExecutionUpdate(JobExecutionUpdate(
                jobID: initialJob.id,
                generation: initialJob.requestGeneration,
                sourceRevision: initialJob.sourceRevision,
                status: .deadLettered,
                attempts: initialJob.attempts,
                errorMessage: reason
            ))
            await onJobChange?()
            throw HealthCoachError.invalidOutput(reason)
        }

        activeJobIDs.insert(jobID)
        defer {
            activeJobIDs.remove(jobID)
            activeClients.removeValue(forKey: jobID)
        }

        let attempts = initialJob.attempts + 1
        try store.recordMacExecutionUpdate(
            JobExecutionUpdate(
                jobID: initialJob.id,
                generation: initialJob.requestGeneration,
                sourceRevision: initialJob.sourceRevision,
                status: .running,
                attempts: attempts
            )
        )
        await onJobChange?()
        guard try store.job(id: jobID)?.intent == .active else { throw HealthCoachError.cancelled }

        let jobDirectory = workRoot.appendingPathComponent("job-" + jobID.uuidString, isDirectory: true)
        let snapshotURL = jobDirectory.appendingPathComponent("context.sqlite")
        var client: CodexAppServerClient?
        do {
            try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
            let artifact = try store.captureJobSnapshot(for: initialJob, at: snapshotURL)
            let configuration = CodexAppServerConfiguration(
                executableURL: codexExecutableURL,
                mcpExecutableURL: mcpExecutableURL,
                snapshotURL: artifact.path,
                workingDirectory: jobDirectory,
                allowedMCPTools: initialJob.kind == .discoverEquipment ? [] : HealthCoachMCPToolCatalog.nameSet,
                networkAccess: initialJob.kind == .discoverEquipment && initialJob.request.allowsOnlineLookup == true
            )
            let newClient = CodexAppServerClient(configuration: configuration)
            client = newClient
            activeClients[jobID] = newClient
            try await newClient.start()
            let turn = try await withTimeout(seconds: 300, onTimeout: {
                await newClient.stop()
            }) {
                try await newClient.runTurn(
                    prompt: HealthCoachJobPrompt.make(for: initialJob),
                    outputSchema: try HealthCoachOutputSchema.jobOutput(),
                    developerInstructions: initialJob.kind == .discoverEquipment
                        ? "This is an equipment discovery job. Do not access HealthCoach MCP tools or health records. Public web lookup is allowed only when the request explicitly sets allowsOnlineLookup=true. Return only structured equipment findings; do not make purchases, contact the venue, or change files."
                        : "HealthCoach jobs may use only the required read-only HealthCoach MCP tools. Do not execute commands, edit files, browse the web, or call any other MCP server.",
                    imageData: initialJob.request.referenceImageData ?? []
                )
            }
            try store.recordMacExecutionUpdate(
                JobExecutionUpdate(
                    jobID: initialJob.id,
                    generation: initialJob.requestGeneration,
                    sourceRevision: initialJob.sourceRevision,
                    status: .running,
                    attempts: attempts,
                    threadID: turn.threadID,
                    turnID: turn.turnID
                )
            )
            await onJobChange?()
            let output = try decodeOutput(turn.assistantText, for: initialJob)
            let result = JobResultEnvelope(
                jobID: initialJob.id,
                generation: initialJob.requestGeneration,
                kind: initialJob.kind,
                inputRevision: initialJob.inputRevision,
                sourceRevision: initialJob.sourceRevision,
                context: artifact.context,
                output: output,
                sourceModel: configuration.modelID
            )
            try store.recordMacResult(result)
            await onJobChange?()
            await newClient.stop()
            cleanup(jobDirectory)
        } catch {
            if let client { await client.stop() }
            cleanup(jobDirectory)
            let latest = try? store.job(id: jobID)
            let status: JobStatus
            if latest?.intent == .cancelRequested || error is CancellationError || error.localizedDescription == HealthCoachError.cancelled.localizedDescription {
                status = .cancelled
            } else if isTransient(error) && attempts < Self.maxAttempts {
                status = .queued
            } else {
                status = .deadLettered
            }
            try? store.recordMacExecutionUpdate(
                JobExecutionUpdate(
                    jobID: initialJob.id,
                    generation: initialJob.requestGeneration,
                    sourceRevision: initialJob.sourceRevision,
                    status: status,
                    attempts: attempts,
                    errorMessage: safeErrorMessage(error)
                )
            )
            await onJobChange?()
            throw error
        }
    }

    public func activeJobsNeedingCancellation() -> [UUID] {
        activeJobIDs.filter { jobID in
            do {
                guard let job = try store.job(id: jobID) else { return false }
                return job.intent == .cancelRequested && job.status != .succeeded
            } catch {
                return false
            }
        }.sorted { $0.uuidString < $1.uuidString }
    }

    public func cancelActiveJobs(_ jobIDs: [UUID]) async {
        for jobID in jobIDs {
            await activeClients[jobID]?.cancelActiveTurn()
        }
    }

    private func decodeOutput(_ text: String, for job: CoachJob) throws -> JobOutput {
        let candidates: [Data] = [Data(text.utf8), extractedJSON(text)].compactMap { $0 }
        var decoded: JobOutput?
        for candidate in candidates {
            if let value = try? HealthCoachJSON.decode(JobOutput.self, from: candidate) {
                decoded = value
                break
            }
        }
        guard let output = decoded else { throw HealthCoachError.invalidOutput("The assistant response was not valid HealthCoach JSON.") }
        guard output.kind == job.kind else { throw HealthCoachError.invalidOutput("The assistant returned the wrong job kind.") }
        try output.validate(excludedEquipment: Set((try store.equipment()?.excluded) ?? []))
        switch output.kind {
        case .analyzeMeal:
            guard let meal = output.meal,
                  meal.sourceMealID == job.request.mealID,
                  meal.sourceMealRevision == job.inputRevision,
                  meal.sourceJobID == job.id else {
                throw HealthCoachError.invalidOutput("Meal result provenance does not match the request.")
            }
        case .generateProgram:
            guard let program = output.program,
                  program.inputRevision == job.inputRevision,
                  program.days.allSatisfy({ $0.exercises.allSatisfy { !$0.alternatives.isEmpty } }) else {
                throw HealthCoachError.invalidOutput("Every generated exercise must carry a cached alternative.")
            }
        case .discoverEquipment:
            guard output.equipment != nil else {
                throw HealthCoachError.invalidOutput("Equipment discovery result is missing.")
            }
        case .suggestProgression:
            guard let progression = output.progression, progression.sourceSessionID == job.request.sessionID else {
                throw HealthCoachError.invalidOutput("Progression result provenance does not match the request.")
            }
        case .answerQuestion:
            break
        }
        return output
    }

    private func withTimeout<T: Sendable>(seconds: UInt64, onTimeout: @escaping @Sendable () async -> Void, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                await onTimeout()
                throw HealthCoachError.unavailable("The Codex turn timed out.")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw HealthCoachError.unavailable("The Codex turn did not return a result.")
            }
            return result
        }
    }

    private func extractedJSON(_ text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else { return nil }
        return Data(text[start...end].utf8)
    }

    private func isTransient(_ error: Error) -> Bool {
        switch error {
        case HealthCoachError.unavailable:
            return true
        case HealthCoachError.protocolError(let message):
            // A malformed transport, unavailable App Server, or interrupted
            // turn can be retried. The API's schema rejection is deterministic
            // for this job and must become a visible terminal error instead of
            // retrying forever while the phone reports Queued.
            return !message.localizedCaseInsensitiveContains("invalid_json_schema")
        default:
            return false
        }
    }

    private func safeErrorMessage(_ error: Error) -> String {
        switch error {
        case HealthCoachError.invalidOutput(let message): return message
        case HealthCoachError.unavailable(let message): return message
        case HealthCoachError.protocolError(let message): return message
        default: return error.localizedDescription
        }
    }

    private func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif
