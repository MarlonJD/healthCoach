import Foundation
import SwiftUI
import HealthCoachKit
import HealthKit

enum WatchSyncStatus: Equatable {
    case unavailable
    case pending
    case synced
    case error(String)

    var title: String {
        switch self {
        case .unavailable: return "iPhone unavailable"
        case .pending: return "Pending iPhone delivery"
        case .synced: return "Synced"
        case .error: return "Needs attention"
        }
    }
}

enum WatchLiveWorkoutStatus: Equatable {
    case idle
    case authorizing
    case starting
    case running
    case paused
    case stopping
    case awaitingPhone
    case error(String)

    var title: String {
        switch self {
        case .idle: return "Ready"
        case .authorizing: return "Requesting HealthKit access…"
        case .starting: return "Starting workout…"
        case .running: return "Workout active"
        case .paused: return "Workout paused"
        case .stopping: return "Saving workout…"
        case .awaitingPhone: return "Waiting for iPhone"
        case .error: return "Workout needs attention"
        }
    }

    var isActive: Bool {
        switch self {
        case .authorizing, .starting, .running, .paused, .stopping, .awaitingPhone:
            return true
        case .idle, .error:
            return false
        }
    }
}

@MainActor
final class WatchAppModel: ObservableObject {
    private let queue: WatchCommandQueue?
    private let bridge: WatchConnectivityBridge
    private let sessionController: WatchWorkoutSessionController
    private var lastPersistedMetricsAt: Date?

    @Published private(set) var snapshot: WatchWorkoutSnapshot?
    @Published private(set) var status: WatchSyncStatus = .unavailable
    @Published private(set) var liveStatus: WatchLiveWorkoutStatus = .idle
    @Published private(set) var liveMetrics: LiveWorkoutMetrics?
    @Published private(set) var lastError: String?
    @Published private(set) var terminalCommands: [WatchCommand] = []
    @Published var showingSetEntry = false

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("HealthCoach/watch-queue.json")
        queue = try? WatchCommandQueue(fileURL: url)
        bridge = WatchConnectivityBridge()
        let sessionController = WatchWorkoutSessionController()
        self.sessionController = sessionController
        sessionController.onPhaseChanged = { [weak self] phase in
            self?.receive(phase)
        }
        sessionController.onMetrics = { [weak self] metrics in
            self?.receive(metrics)
        }
        sessionController.onError = { [weak self] message in
            self?.recordLiveError(message)
        }
        if let persisted = queue?.snapshotState().snapshot {
            snapshot = persisted
            liveMetrics = persisted.liveMetrics
        }
        if let initial = bridge.receiveInitialContext(), let value = try? HealthCoachJSON.decode(WatchWorkoutSnapshot.self, from: initial) {
            if (try? queue?.replaceSnapshot(value)) ?? false {
                snapshot = value
                liveMetrics = value.liveMetrics
            }
        }
        bridge.onTransfer = { [weak self] data in
            Task { @MainActor [weak self] in self?.receive(data) }
        }
        bridge.onActivated = { [weak self] in
            Task { @MainActor [weak self] in self?.resendQueuedCommands() }
        }
        refreshStatus()
    }

    var exercises: [WatchExerciseSnapshot] {
        snapshot?.exercises.sorted { $0.order < $1.order } ?? []
    }

    var currentExercise: WatchExerciseSnapshot? {
        guard let snapshot, !exercises.isEmpty else { return nil }
        var completedSets = max(snapshot.activeSessionSetCount, 0)
        for exercise in exercises {
            let targetSets = max(exercise.sets, 1)
            if completedSets < targetSets { return exercise }
            completedSets -= targetSets
        }
        return nil
    }

    var currentExerciseSetNumber: Int {
        guard let snapshot, let current = currentExercise else { return 0 }
        var completedSets = max(snapshot.activeSessionSetCount, 0)
        for exercise in exercises {
            let targetSets = max(exercise.sets, 1)
            if exercise.exerciseID == current.exerciseID { return completedSets + 1 }
            completedSets = max(0, completedSets - targetSets)
        }
        return 0
    }

    var nextExercise: WatchExerciseSnapshot? {
        guard let current = currentExercise, let index = exercises.firstIndex(of: current), index + 1 < exercises.count else { return nil }
        return exercises[index + 1]
    }

    func startSession() {
        guard let snapshot, let programID = snapshot.programID, let programRevision = snapshot.programRevision else {
            lastError = "No cached accepted program is available. Open HealthCoach on the iPhone first."
            status = .error(lastError!)
            return
        }
        guard liveStatus == .idle || isLiveError else { return }
        guard queue != nil else {
            recordLiveError("Watch storage is unavailable; the workout was not started.")
            return
        }
        let sessionID = snapshot.activeSessionID ?? UUID()
        let command = WatchCommand(kind: .startSession, sessionID: sessionID, sequence: nextSequence(sessionID), programID: programID, programRevision: programRevision)
        liveMetrics = nil
        lastPersistedMetricsAt = nil
        liveStatus = .authorizing
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.sessionController.start()
                guard self.enqueue(command) else {
                    self.sessionController.discardWithoutSaving()
                    return
                }
                var optimistic = self.snapshot ?? snapshot
                optimistic.activeSessionID = sessionID
                optimistic.activeSessionSetCount = 0
                optimistic.liveMetrics = self.liveMetrics
                if (try? self.queue?.replaceSnapshot(optimistic)) ?? false {
                    self.snapshot = optimistic
                } else if let persisted = self.queue?.snapshotState().snapshot {
                    self.snapshot = persisted
                }
                self.liveStatus = .running
            } catch {
                self.recordLiveError(error.localizedDescription)
            }
        }
    }

    func recordSet(reps: Int, loadKg: Double, rir: Double?) {
        guard liveStatus == .running || liveStatus == .paused else {
            lastError = "Start the live workout before logging a set."
            status = .error(lastError!)
            return
        }
        guard let snapshot, let sessionID = snapshot.activeSessionID, let exercise = currentExercise, let programID = snapshot.programID, let programRevision = snapshot.programRevision else {
            lastError = "Start the cached session before logging a set."
            status = .error(lastError!)
            return
        }
        guard reps > 0, loadKg.isFinite, loadKg >= 0 else {
            lastError = "Enter positive reps and a non-negative load."
            status = .error(lastError!)
            return
        }
        if let rir, (!rir.isFinite || rir < 0) {
            lastError = "RIR must be non-negative."
            status = .error(lastError!)
            return
        }
        let command = WatchCommand(kind: .recordSet, sessionID: sessionID, sequence: nextSequence(sessionID), programID: programID, programRevision: programRevision, exerciseID: exercise.exerciseID, reps: reps, loadKg: loadKg, rir: rir)
        guard enqueue(command) else { return }
        var optimistic = snapshot
        optimistic.activeSessionSetCount += 1
        self.snapshot = optimistic
        _ = try? queue?.replaceSnapshot(optimistic)
    }

    func finishSession() {
        guard let snapshot, let sessionID = snapshot.activeSessionID, let programID = snapshot.programID, let programRevision = snapshot.programRevision else {
            lastError = "There is no active cached session."
            status = .error(lastError!)
            return
        }
        guard liveStatus == .running || liveStatus == .paused else { return }
        guard sessionController.hasActiveSession else {
            recordLiveError("The HealthKit workout is not active on this Watch. Wait for recovery or start a new session.")
            return
        }
        liveStatus = .stopping
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let metrics = try await self.sessionController.stopAndSave()
                self.liveMetrics = metrics
                var cached = self.snapshot
                cached?.liveMetrics = metrics
                if let cached {
                    self.snapshot = cached
                    _ = try? self.queue?.replaceSnapshot(cached)
                }
                let command = WatchCommand(
                    kind: .finishSession,
                    sessionID: sessionID,
                    sequence: self.nextSequence(sessionID),
                    programID: programID,
                    programRevision: programRevision,
                    liveMetrics: metrics
                )
                guard self.enqueue(command) else { return }
                self.liveStatus = .awaitingPhone
            } catch {
                self.recordLiveError(error.localizedDescription)
            }
        }
    }

    func retry(_ command: WatchCommand) {
        do {
            let retriedKind = queue?.command(id: command.id)?.kind
            guard let command = try queue?.retry(commandID: command.id) else { return }
            if retriedKind == .startSession {
                liveStatus = .authorizing
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await self.sessionController.start()
                        self.bridge.send(command: command)
                        self.liveStatus = .running
                        self.refreshStatus()
                    } catch {
                        self.recordLiveError(error.localizedDescription)
                    }
                }
            } else {
                bridge.send(command: command)
                if retriedKind == .finishSession { liveStatus = .awaitingPhone }
                refreshStatus()
            }
        } catch { lastError = error.localizedDescription }
    }

    @discardableResult
    private func enqueue(_ command: WatchCommand) -> Bool {
        do {
            guard let queue else { throw HealthCoachError.unavailable("Watch storage is unavailable.") }
            _ = try queue.enqueue(command)
            bridge.send(command: command)
            refreshStatus()
            return true
        } catch {
            lastError = error.localizedDescription
            status = .error(error.localizedDescription)
            return false
        }
    }

    private func resendQueuedCommands() {
        guard let queue else { return }
        for command in queue.snapshotState().commands where command.status == .queued {
            bridge.send(command: command)
        }
        refreshStatus()
    }

    private func nextSequence(_ sessionID: UUID) -> Int64 {
        queue?.nextSequence(for: sessionID) ?? 1
    }

    private func receive(_ data: Data) {
        guard let transfer = try? HealthCoachJSON.decode(WatchTransfer.self, from: data) else {
            lastError = "The iPhone sent an unreadable Watch payload."
            status = .error(lastError!)
            return
        }
        do {
            if var incomingSnapshot = transfer.snapshot {
                let isSameCachedSession = incomingSnapshot.activeSessionID == self.snapshot?.activeSessionID
                if incomingSnapshot.liveMetrics == nil, (incomingSnapshot.activeSessionID == nil || isSameCachedSession) {
                    incomingSnapshot.liveMetrics = liveMetrics
                }
                if try queue?.replaceSnapshot(incomingSnapshot) ?? false {
                    self.snapshot = incomingSnapshot
                    self.liveMetrics = incomingSnapshot.liveMetrics
                    if incomingSnapshot.activeSessionID == nil, liveStatus == .awaitingPhone {
                        liveStatus = .idle
                    }
                }
            }
            if let ack = transfer.acknowledgment {
                let command = queue?.command(id: ack.commandID)
                try queue?.acknowledge(ack)
                if ack.status == .rejected {
                    let message = ack.message ?? "The iPhone rejected this command."
                    lastError = message
                    if command?.kind == .startSession {
                        sessionController.discardWithoutSaving()
                        liveStatus = .error(message)
                    }
                }
                if command?.kind == .finishSession {
                    if ack.status == .applied || ack.status == .duplicate {
                        liveStatus = .idle
                        var cached = snapshot
                        cached?.activeSessionID = nil
                        if let cached {
                            self.snapshot = cached
                            _ = try? queue?.replaceSnapshot(cached)
                        }
                    } else if ack.status == .rejected {
                        liveStatus = .error(ack.message ?? "The iPhone rejected the finished workout.")
                    }
                }
                // A later command may have been queued behind an undelivered
                // one. Once the phone commits an acknowledgment, promptly
                // retry the remaining durable queue so ordering can advance.
                resendQueuedCommands()
            }
            refreshStatus()
        } catch { lastError = error.localizedDescription; status = .error(error.localizedDescription) }
    }

    private func refreshStatus() {
        guard let queue else { status = .unavailable; return }
        let state = queue.snapshotState()
        terminalCommands = state.commands.filter { $0.status == .rejected }
        if let rejected = terminalCommands.last {
            status = .error(rejected.terminalMessage ?? "The iPhone rejected a command.")
        } else if !state.commands.isEmpty {
            status = .pending
        } else if snapshot != nil {
            status = .synced
        } else {
            status = .unavailable
        }
    }

    func recoverActiveWorkout(_ session: HKWorkoutSession) {
        guard snapshot?.activeSessionID != nil else {
            recordLiveError("A HealthKit workout was recovered, but no cached HealthCoach session is available.")
            return
        }
        sessionController.recover(session)
        liveStatus = .running
    }

    func recordLiveError(_ message: String) {
        lastError = message
        liveStatus = .error(message)
        status = .error(message)
    }

    private var isLiveError: Bool {
        if case .error = liveStatus { return true }
        return false
    }

    private func receive(_ phase: WatchHealthWorkoutPhase) {
        switch phase {
        case .prepared:
            if liveStatus != .stopping && liveStatus != .awaitingPhone { liveStatus = .starting }
        case .running:
            if liveStatus != .stopping && liveStatus != .awaitingPhone { liveStatus = .running }
        case .paused:
            if liveStatus != .stopping && liveStatus != .awaitingPhone { liveStatus = .paused }
        case .stopped:
            if liveStatus != .stopping && liveStatus != .awaitingPhone { liveStatus = .error("The HealthKit workout stopped unexpectedly.") }
        case .ended:
            if liveStatus != .awaitingPhone { liveStatus = .idle }
        }
    }

    private func receive(_ metrics: LiveWorkoutMetrics) {
        liveMetrics = metrics
        guard var cached = snapshot else { return }
        cached.liveMetrics = metrics
        snapshot = cached
        if lastPersistedMetricsAt == nil || metrics.capturedAt.timeIntervalSince(lastPersistedMetricsAt!) >= 15 {
            _ = try? queue?.replaceSnapshot(cached)
            lastPersistedMetricsAt = metrics.capturedAt
        }
    }
}
