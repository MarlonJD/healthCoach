import Foundation
import SwiftUI
import HealthCoachKit

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

@MainActor
final class WatchAppModel: ObservableObject {
    private let queue: WatchCommandQueue?
    private let bridge: WatchConnectivityBridge

    @Published private(set) var snapshot: WatchWorkoutSnapshot?
    @Published private(set) var status: WatchSyncStatus = .unavailable
    @Published private(set) var lastError: String?
    @Published private(set) var terminalCommands: [WatchCommand] = []
    @Published var showingSetEntry = false

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("HealthCoach/watch-queue.json")
        queue = try? WatchCommandQueue(fileURL: url)
        bridge = WatchConnectivityBridge()
        if let initial = bridge.receiveInitialContext(), let value = try? HealthCoachJSON.decode(WatchWorkoutSnapshot.self, from: initial) {
            snapshot = value
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
        let sessionID = snapshot.activeSessionID ?? UUID()
        enqueue(WatchCommand(kind: .startSession, sessionID: sessionID, sequence: nextSequence(sessionID), programID: programID, programRevision: programRevision))
        var optimistic = snapshot
        optimistic.activeSessionID = sessionID
        optimistic.activeSessionSetCount = 0
        self.snapshot = optimistic
        _ = try? queue?.replaceSnapshot(optimistic)
    }

    func recordSet(reps: Int, loadKg: Double, rir: Double?) {
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
        enqueue(WatchCommand(kind: .recordSet, sessionID: sessionID, sequence: nextSequence(sessionID), programID: programID, programRevision: programRevision, exerciseID: exercise.exerciseID, reps: reps, loadKg: loadKg, rir: rir))
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
        enqueue(WatchCommand(kind: .finishSession, sessionID: sessionID, sequence: nextSequence(sessionID), programID: programID, programRevision: programRevision))
    }

    func retry(_ command: WatchCommand) {
        do {
            guard let command = try queue?.retry(commandID: command.id) else { return }
            bridge.send(command: command)
            refreshStatus()
        } catch { lastError = error.localizedDescription }
    }

    private func enqueue(_ command: WatchCommand) {
        do {
            guard let queue else { throw HealthCoachError.unavailable("Watch storage is unavailable.") }
            _ = try queue.enqueue(command)
            bridge.send(command: command)
            refreshStatus()
        } catch {
            lastError = error.localizedDescription
            status = .error(error.localizedDescription)
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
            if let snapshot = transfer.snapshot {
                if try queue?.replaceSnapshot(snapshot) ?? false { self.snapshot = snapshot }
            }
            if let ack = transfer.acknowledgment {
                try queue?.acknowledge(ack)
                if ack.status == .rejected {
                    lastError = ack.message ?? "The iPhone rejected this command."
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
}
