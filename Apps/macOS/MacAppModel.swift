import Foundation
import SwiftUI
import HealthCoachKit
import Network
import ServiceManagement

@MainActor
final class MacAppModel: ObservableObject {
    let store: HealthCoachStore?
    let macPeerID: UUID
    private let pairingStore: PairingCredentialStore
    private var listener: HealthCoachNetworkListener?
    private var worker: CodexJobWorker?
    private var workerTask: Task<Void, Never>?
    private var pendingCredential: PairingCredential?

    @Published private(set) var pairingCredential: PairingCredential?
    @Published private(set) var qrPayload: Data?
    @Published private(set) var syncStatus = "Starting local listener…"
    @Published private(set) var codexStatus = CodexStatus(readiness: .missingInstallation)
    @Published private(set) var jobs: [CoachJob] = []
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
            var shouldRunWorker = false
            if let pairID = store.activePairID, let credential = try pairingStore.load(pairID: pairID), credential.isUsable {
                pairingCredential = credential
                startListener(credential: credential, showPairingQR: false)
                syncStatus = "Paired; waiting for iPhone"
                shouldRunWorker = true
            } else {
                let credential = try PairingCredentialFactory.make(peerID: macPeerID)
                pendingCredential = credential
                pairingCredential = credential
                qrPayload = try PairingCredentialFactory.makeQRPayload(from: credential)
                startListener(credential: credential, showPairingQR: true)
                syncStatus = "Scan the pairing QR with the iPhone"
            }
            refresh()
            if shouldRunWorker { runWorker() }
        } catch {
            lastError = error.localizedDescription
            syncStatus = "Listener unavailable"
        }
    }

    func refresh() {
        guard let store else { return }
        do {
            jobs = try store.jobs()
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    func runWorker() {
        guard workerTask == nil else { return }
        guard !analysisPaused else {
            syncStatus = "Analysis paused locally"
            return
        }
        guard let store else { return }
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
            let outcomes = await worker.runPending()
            await MainActor.run {
                self?.workerTask = nil
                self?.refresh()
                self?.lastSyncAt = Date()
                self?.syncStatus = outcomes.isEmpty ? "No queued work" : "Codex work complete"
            }
        }
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
            pairingCredential = nil
            pendingCredential = nil
            let credential = try PairingCredentialFactory.make(peerID: macPeerID)
            pendingCredential = credential
            pairingCredential = credential
            qrPayload = try PairingCredentialFactory.makeQRPayload(from: credential)
            startListener(credential: credential, showPairingQR: true)
            syncStatus = "Unpaired; scan the new QR"
        } catch { lastError = error.localizedDescription }
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
            lastError = "The pairing QR credential has expired. Restart pairing to create a new QR."
            await connection.close()
            return
        }
        do {
            let coordinator = SyncSessionCoordinator(store: store, pairID: credential.pairID, localPeerID: macPeerID, remotePeerID: nil, localSender: .mac)
            try await SyncConnectionRunner.run(transport: connection, coordinator: coordinator) { @MainActor [weak self] envelope in
                guard envelope.kind == .batch else { return }
                self?.handleCommittedPhoneBatch()
            }
            if await coordinator.isAuthenticated() {
                // Keep a QR credential pending until both peers complete the
                // authenticated exchange. Only then bind this mirror to the
                // pair and retain the credential for automatic reconnect.
                try store.setActivePair(credential.pairID)
                let activatedCredential = PairingCredentialFactory.activated(credential)
                try pairingStore.save(activatedCredential)
                pairingCredential = activatedCredential
                pendingCredential = nil
                qrPayload = nil
                syncStatus = "Paired and synced"
                lastSyncAt = Date()
                refresh()
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
                if await worker.activeJobNeedsCancellation() {
                    await worker.cancelActiveJob()
                }
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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open HealthCoach") { openWindow(id: "dashboard") }
        Text(model.syncStatus)
        Text("Codex: \(model.codexStatus.readiness.rawValue)")
        Divider()
        Button(model.analysisPaused ? "Resume analysis" : "Pause analysis") { model.toggleAnalysisPause() }
        Button("Run queued work") { model.runWorker() }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}
