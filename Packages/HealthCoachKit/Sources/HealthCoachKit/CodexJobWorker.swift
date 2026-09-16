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
    private let store: HealthCoachStore
    private let codexExecutableURL: URL
    private let mcpExecutableURL: URL
    private let workRoot: URL
    private var activeClient: CodexAppServerClient?
    private var activeJobID: UUID?

    public init(store: HealthCoachStore, codexExecutableURL: URL, mcpExecutableURL: URL, workRoot: URL) {
        self.store = store
        self.codexExecutableURL = codexExecutableURL
        self.mcpExecutableURL = mcpExecutableURL
        self.workRoot = workRoot
    }

    public func runPending() async -> [JobWorkerOutcome] {
        let pending = (try? store.pendingJobs()) ?? []
        var outcomes: [JobWorkerOutcome] = []
        for job in pending {
            do {
                try await run(jobID: job.id)
                outcomes.append(JobWorkerOutcome(jobID: job.id, status: .succeeded))
            } catch {
                let status = (try? store.job(id: job.id)?.status) ?? .failed
                outcomes.append(JobWorkerOutcome(jobID: job.id, status: status, message: error.localizedDescription))
            }
        }
        return outcomes
    }

    public func run(jobID: UUID) async throws {
        guard let initialJob = try store.job(id: jobID) else { throw HealthCoachError.invalidInput("The job does not exist.") }
        guard initialJob.intent == .active, initialJob.status == .queued || initialJob.status == .running else {
            throw HealthCoachError.cancelled
        }
        guard try store.analysisPolicy().enabled else {
            throw HealthCoachError.unavailable("Analysis is paused on the iPhone.")
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

        let jobDirectory = workRoot.appendingPathComponent("job-" + jobID.uuidString, isDirectory: true)
        let snapshotURL = jobDirectory.appendingPathComponent("context.sqlite")
        var client: CodexAppServerClient?
        activeJobID = jobID
        do {
            try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
            let artifact = try store.captureJobSnapshot(for: initialJob, at: snapshotURL)
            let configuration = CodexAppServerConfiguration(
                executableURL: codexExecutableURL,
                mcpExecutableURL: mcpExecutableURL,
                snapshotURL: artifact.path,
                workingDirectory: jobDirectory
            )
            let newClient = CodexAppServerClient(configuration: configuration)
            client = newClient
            activeClient = newClient
            try await newClient.start()
            let turn = try await withTimeout(seconds: 300, onTimeout: {
                await newClient.stop()
            }) {
                try await newClient.runTurn(
                    prompt: HealthCoachJobPrompt.make(for: initialJob),
                    outputSchema: try HealthCoachOutputSchema.jobOutput(),
                    developerInstructions: "HealthCoach jobs may use only the required read-only HealthCoach MCP tools. Do not execute commands, edit files, browse the web, or call any other MCP server."
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
            await newClient.stop()
            cleanup(jobDirectory)
            activeClient = nil
            activeJobID = nil
        } catch {
            if let client { await client.stop() }
            cleanup(jobDirectory)
            activeClient = nil
            activeJobID = nil
            let latest = try? store.job(id: jobID)
            let status: JobStatus
            if latest?.intent == .cancelRequested || error is CancellationError || error.localizedDescription == HealthCoachError.cancelled.localizedDescription {
                status = .cancelled
            } else if isTransient(error) {
                status = .queued
            } else {
                status = .failed
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
            throw error
        }
    }

    public func cancelActiveJob() async {
        await activeClient?.cancelActiveTurn()
    }

    public func activeJobNeedsCancellation() -> Bool {
        guard let activeJobID else { return false }
        do {
            guard let job = try store.job(id: activeJobID) else { return false }
            return job.intent == .cancelRequested && job.status != .succeeded
        } catch {
            return false
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
        case HealthCoachError.unavailable, HealthCoachError.protocolError:
            return true
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
