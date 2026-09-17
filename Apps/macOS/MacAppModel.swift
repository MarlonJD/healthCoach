import Foundation
import SwiftUI
import HealthCoachKit
import Network
import ServiceManagement
import AppKit

@MainActor
final class MacAppModel: ObservableObject {
    let store: HealthCoachStore?
    let macPeerID: UUID
    private let pairingStore: PairingCredentialStore
    private var listener: HealthCoachNetworkListener?
    private var worker: CodexJobWorker?
    private var workerTask: Task<Void, Never>?
    private var workerRetryTask: Task<Void, Never>?
    private var queueListenerTask: Task<Void, Never>?
    private var workerRetryAttempt = 0
    private var pairingRefreshTask: Task<Void, Never>?
    private var syncChangeContinuation: AsyncStream<Void>.Continuation?
    private var pendingCredential: PairingCredential?

    private let pairingRenewalLeadTime: TimeInterval = 30
    private let workerRetryDelays: [UInt64] = [5, 15, 30, 60, 60]
    private let queuePollInterval: UInt64 = 2_000_000_000

    @Published private(set) var pairingCredential: PairingCredential?
    @Published private(set) var qrPayload: Data?
    @Published private(set) var syncStatus = "Starting local listener…"
    @Published private(set) var codexStatus = CodexStatus(readiness: .missingInstallation)
    @Published private(set) var jobs: [CoachJob] = []
    @Published private(set) var pendingReverseSyncCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var lastSyncAt: Date?
    @Published var analysisPaused = false
    @Published var launchAtLogin: Bool {
        didSet { updateLaunchAtLogin() }
    }

    init() {
        pairingStore = KeychainPairingCredentialStore()
        let peerKey = "HealthCoach.macPeerID"
        if let stored = UserDefaults.standard.string(forKey: peerKey), let id = UUID(uuidString: stored) {
            macPeerID = id
        } else {
            let id = UUID()
            macPeerID = id
            UserDefaults.standard.set(id.uuidString, forKey: peerKey)
        }
        launchAtLogin = UserDefaults.standard.bool(forKey: "HealthCoach.launchAtLogin")
        do {
            let base = try HealthCoachStore.applicationSupportURL().deletingLastPathComponent()
            let path = base.appendingPathComponent("mac-mirror.sqlite")
            store = try HealthCoachStore(path: path)
        } catch {
            store = nil
        }
        start()
    }

    deinit {
        listener?.stop()
        workerTask?.cancel()
        workerRetryTask?.cancel()
        queueListenerTask?.cancel()
        pairingRefreshTask?.cancel()
    }

    func start() {
        codexStatus = CodexAppServerProbe.probe(executableURL: CodexAppServerProbe.defaultExecutableURL())
        guard let store else {
            syncStatus = "Storage unavailable"
            lastError = "The Mac mirror database could not be opened."
            return
        }
        do {
            try store.recoverStagedSnapshots()
            _ = try store.normalizeFailedJobsToDeadLetters()
            _ = try store.recoverInterruptedJobs()
            var shouldRunWorker = false
            if let pairID = store.activePairID, let credential = try pairingStore.load(pairID: pairID), credential.isUsable {
                pairingCredential = credential
                pendingCredential = nil
                pairingRefreshTask?.cancel()
                pairingRefreshTask = nil
                startListener(credential: credential, showPairingQR: false)
                syncStatus = "Paired; waiting for iPhone"
                shouldRunWorker = true
            } else {
                if let pairID = store.activePairID {
                    try? pairingStore.delete(pairID: pairID)
                    try? store.setActivePair(nil)
                }
                try beginPairing()
            }
            refresh()
            if shouldRunWorker {
                startQueueListener()
                runWorker()
            }
        } catch {
            lastError = error.localizedDescription
            syncStatus = "Listener unavailable"
        }
    }

    func refresh() {
        guard let store else { return }
        do {
            jobs = try store.jobs()
            pendingReverseSyncCount = try store.pendingOutbox(sender: .mac).count
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    func runWorker() {
        workerRetryTask?.cancel()
        workerRetryTask = nil
        workerRetryAttempt = 0
        startWorker()
    }

    private func startQueueListener() {
        guard queueListenerTask == nil else { return }
        let interval = queuePollInterval
        queueListenerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.startWorkerIfNeeded()
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
            }
        }
    }

    private func stopQueueListener() {
        queueListenerTask?.cancel()
        queueListenerTask = nil
    }

    private func startWorkerIfNeeded() {
        startWorker()
    }

    private func startWorker() {
        guard workerTask == nil else { return }
        guard workerRetryTask == nil else { return }
        guard !analysisPaused else {
            syncStatus = "Analysis paused locally"
            return
        }
        guard let store else { return }
        let pendingJobs: [CoachJob]
        do {
            pendingJobs = try store.pendingJobs()
        } catch {
            lastError = error.localizedDescription
            return
        }
        guard !pendingJobs.isEmpty else { return }
        guard codexStatus.readiness == .ready else {
            lastError = codexStatus.lastError ?? "Codex is not ready."
            return
        }
        guard let executable = CodexAppServerProbe.defaultExecutableURL() else {
            lastError = "Codex App Server is not installed."
            return
        }
        guard let helper = helperURL() else {
            lastError = "The packaged healthcoach-mcp helper is missing."
            return
        }
        let root = (try? HealthCoachStore.applicationSupportURL().deletingLastPathComponent().appendingPathComponent("jobs", isDirectory: true)) ?? FileManager.default.temporaryDirectory.appendingPathComponent("HealthCoachJobs", isDirectory: true)
        let worker = CodexJobWorker(store: store, codexExecutableURL: executable, mcpExecutableURL: helper, workRoot: root)
        self.worker = worker
        syncStatus = "Running queued Codex work"
        workerTask = Task { [weak self, worker] in
            let outcomes = await worker.runPending { @MainActor [weak self] in
                self?.refresh()
                self?.signalSyncChange()
            }
            await MainActor.run {
                self?.workerTask = nil
                self?.refresh()
                self?.lastSyncAt = Date()
                guard let self else { return }
                let queued = outcomes.filter { $0.status == .queued }
                let failed = outcomes.filter { $0.status == .failed }
                let deadLettered = outcomes.filter { $0.status == .deadLettered }
                if let queuedError = queued.compactMap(\.message).first {
                    self.lastError = queuedError
                } else if let deadLetterError = deadLettered.compactMap(\.message).first {
                    self.lastError = deadLetterError
                } else if let failedError = failed.compactMap(\.message).first {
                    self.lastError = failedError
                } else {
                    self.lastError = nil
                }
                if !queued.isEmpty {
                    self.syncStatus = "Codex unavailable; queued work retained"
                    self.scheduleWorkerRetry()
                } else if !deadLettered.isEmpty || !failed.isEmpty {
                    self.syncStatus = "Some Codex work moved to the dead-letter queue"
                } else {
                    self.syncStatus = outcomes.isEmpty ? "No queued work" : "Codex work complete"
                }
                self.startWorkerIfNeeded()
            }
        }
    }

    private func scheduleWorkerRetry() {
        guard !analysisPaused, workerRetryTask == nil else { return }
        let index = min(workerRetryAttempt, workerRetryDelays.count - 1)
        let delay = workerRetryDelays[index]
        workerRetryAttempt = min(workerRetryAttempt + 1, workerRetryDelays.count - 1)
        workerRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.workerRetryTask = nil
            self.startWorker()
        }
    }

    private func signalSyncChange() {
        syncChangeContinuation?.yield(())
    }

    func toggleAnalysisPause() {
        analysisPaused.toggle()
        if analysisPaused { syncStatus = "Analysis paused locally" } else { runWorker() }
    }

    func unpair() {
        do {
            if let pairID = pairingCredential?.pairID { try pairingStore.delete(pairID: pairID) }
            try store?.setActivePair(nil)
            listener?.stop()
            listener = nil
            stopQueueListener()
            try beginPairing()
            syncStatus = "Unpaired; scan the new QR"
        } catch { lastError = error.localizedDescription }
    }

    /// Creates the one-time QR credential and starts the listener that owns it.
    /// Pending credentials are intentionally not persisted: if the companion
    /// is restarted, a new QR is generated rather than reviving an old one.
    private func beginPairing() throws {
        listener?.stop()
        listener = nil
        let credential = try PairingCredentialFactory.make(peerID: macPeerID)
        pendingCredential = credential
        pairingCredential = credential
        qrPayload = try PairingCredentialFactory.makeQRPayload(from: credential)
        startListener(credential: credential, showPairingQR: true)
        syncStatus = "Scan the pairing QR with the iPhone"
        startPairingRefreshLoop()
    }

    private func startPairingRefreshLoop() {
        pairingRefreshTask?.cancel()
        pairingRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.refreshExpiredPairingIfNeeded()
            }
        }
    }

    private func refreshExpiredPairingIfNeeded() {
        guard let credential = pendingCredential,
              credential.expiresAt.timeIntervalSinceNow <= pairingRenewalLeadTime else { return }
        do {
            try beginPairing()
            syncStatus = "QR refreshed; scan the new code"
        } catch {
            lastError = error.localizedDescription
            syncStatus = "Pairing QR unavailable"
        }
    }

    func helperURL() -> URL? {
        let candidates: [URL?] = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/healthcoach-mcp"),
            Bundle.main.resourceURL?.appendingPathComponent("Helpers/healthcoach-mcp"),
            ProcessInfo.processInfo.environment["HEALTHCOACH_MCP_PATH"].map(URL.init(fileURLWithPath:)),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/healthcoach-mcp")
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func startListener(credential: PairingCredential, showPairingQR: Bool) {
        do {
            let listener = try HealthCoachNetworkListener(peerID: macPeerID, credential: credential)
            self.listener = listener
            listener.start { [weak self] connection in
                Task { @MainActor [weak self] in
                    await self?.handle(connection: connection, credential: credential)
                }
            } onError: { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.lastError = error.localizedDescription
                    self?.syncStatus = "Network listener error"
                }
            }
            if !showPairingQR { qrPayload = nil }
        } catch { lastError = error.localizedDescription }
    }

    private func handle(connection: HealthCoachNetworkConnection, credential: PairingCredential) async {
        guard let store else { await connection.close(); return }
        guard credential.isUsable else {
            if pendingCredential?.pairID == credential.pairID {
                refreshExpiredPairingIfNeeded()
            }
            await connection.close()
            return
        }
        do {
            let coordinator = SyncSessionCoordinator(store: store, pairID: credential.pairID, localPeerID: macPeerID, remotePeerID: nil, localSender: .mac)
            var localChangeContinuation: AsyncStream<Void>.Continuation?
            let localChanges = AsyncStream<Void> { continuation in
                localChangeContinuation = continuation
            }
            syncChangeContinuation = localChangeContinuation
            defer {
                localChangeContinuation?.finish()
                syncChangeContinuation = nil
            }
            try await SyncConnectionRunner.run(transport: connection, coordinator: coordinator, onCommitted: { @MainActor [weak self] envelope in
                guard envelope.kind == .batch else { return }
                self?.handleCommittedPhoneBatch()
            }, localChanges: localChanges)
            if await coordinator.isAuthenticated() {
                // A pending QR may have rotated while this connection was in
                // flight. Never activate an older credential after rotation.
                guard pendingCredential?.pairID == credential.pairID else {
                    await connection.close()
                    return
                }
                // Keep a QR credential pending until both peers complete the
                // authenticated exchange. Only then bind this mirror to the
                // pair and retain the credential for automatic reconnect.
                try store.setActivePair(credential.pairID)
                let activatedCredential = PairingCredentialFactory.activated(credential)
                try pairingStore.save(activatedCredential)
                pairingCredential = activatedCredential
                pendingCredential = nil
                pairingRefreshTask?.cancel()
                pairingRefreshTask = nil
                qrPayload = nil
                syncStatus = "Paired and synced"
                lastSyncAt = Date()
                refresh()
                startQueueListener()
                runWorker()
            }
        } catch {
            lastError = error.localizedDescription
            syncStatus = "Sync interrupted; queued data is retained"
        }
        await connection.close()
    }

    private func handleCommittedPhoneBatch() {
        // Cancelled jobs are intentionally no longer in the queued/running
        // list. Ask the worker about its own active job so an old cancellation
        // cannot interrupt an unrelated newer turn.
        if let worker {
            Task {
                let jobs = await worker.activeJobsNeedingCancellation()
                await worker.cancelActiveJobs(jobs)
            }
        }
        runWorker()
    }

    private func updateLaunchAtLogin() {
        UserDefaults.standard.set(launchAtLogin, forKey: "HealthCoach.launchAtLogin")
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { lastError = "Launch-at-login setting could not be applied: \(error.localizedDescription)" }
    }
}

struct MacMenuView: View {
    @ObservedObject var model: MacAppModel
    @ObservedObject var dashboardWindow: MacDashboardWindowController

    var body: some View {
        Button("Open HealthCoach") {
            dashboardWindow.show(model: model)
        }
        Text(model.syncStatus)
        Text("Codex: \(model.codexStatus.readiness.rawValue)")
        Divider()
        Button(model.analysisPaused ? "Resume analysis" : "Pause analysis") { model.toggleAnalysisPause() }
        Button("Run queued work") { model.runWorker() }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}
