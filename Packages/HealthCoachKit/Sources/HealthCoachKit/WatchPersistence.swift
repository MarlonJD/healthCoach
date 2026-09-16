import Foundation

/// Small durable Watch-side queue. It stores only the replaceable phone
/// snapshot, entered commands, and their terminal acknowledgments; the phone
/// remains the canonical owner of workout records.
public struct WatchQueueState: Codable, Equatable, Sendable {
    public var commands: [WatchCommand]
    public var acknowledgments: [WatchCommandAck]
    public var snapshot: WatchWorkoutSnapshot?
    public var lastSequenceBySession: [String: Int64]

    public init(
        commands: [WatchCommand] = [],
        acknowledgments: [WatchCommandAck] = [],
        snapshot: WatchWorkoutSnapshot? = nil,
        lastSequenceBySession: [String: Int64] = [:]
    ) {
        self.commands = commands
        self.acknowledgments = acknowledgments
        self.snapshot = snapshot
        self.lastSequenceBySession = lastSequenceBySession
    }
}

public final class WatchCommandQueue: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()
    private var state: WatchQueueState

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            self.state = try HealthCoachJSON.decode(WatchQueueState.self, from: Data(contentsOf: fileURL))
        } else {
            self.state = WatchQueueState()
            try persistLocked()
        }
    }

    public func snapshotState() -> WatchQueueState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public func nextSequence(for sessionID: UUID) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let key = sessionID.uuidString
        let pendingMaximum = state.commands.filter { $0.sessionID == sessionID }.map(\.sequence).max() ?? 0
        return max(state.lastSequenceBySession[key] ?? 0, pendingMaximum) + 1
    }

    /// Command persistence precedes the Watch UI's “saved” state.
    @discardableResult
    public func enqueue(_ command: WatchCommand) throws -> WatchCommand {
        lock.lock()
        defer { lock.unlock() }
        guard !state.commands.contains(where: { $0.id == command.id }) else { return command }
        guard command.sequence > 0 else { throw HealthCoachError.invalidInput("The Watch command sequence must be positive.") }
        let key = command.sessionID.uuidString
        guard command.sequence > (state.commands.filter { $0.sessionID == command.sessionID }.map(\.sequence).max() ?? 0) else {
            throw HealthCoachError.invalidInput("The Watch command sequence must increase.")
        }
        state.lastSequenceBySession[key] = max(state.lastSequenceBySession[key] ?? 0, command.sequence)
        state.commands.append(command)
        try persistLocked()
        return command
    }

    public func acknowledge(_ acknowledgment: WatchCommandAck) throws {
        lock.lock()
        defer { lock.unlock() }
        state.acknowledgments.removeAll { $0.commandID == acknowledgment.commandID }
        state.acknowledgments.append(acknowledgment)
        if acknowledgment.status == .applied || acknowledgment.status == .duplicate {
            state.commands.removeAll { $0.id == acknowledgment.commandID }
        } else if let index = state.commands.firstIndex(where: { $0.id == acknowledgment.commandID }) {
            state.commands[index].status = acknowledgment.status
            state.commands[index].terminalMessage = acknowledgment.message
        }
        try persistLocked()
    }

    /// A rejected command retains its original values and sequence. The user
    /// can correct the local condition and retry that exact command ID without
    /// allocating another sequence or creating a second set.
    @discardableResult
    public func retry(commandID: UUID) throws -> WatchCommand? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = state.commands.firstIndex(where: { $0.id == commandID && $0.status == .rejected }) else { return nil }
        state.commands[index].status = .queued
        state.commands[index].terminalMessage = nil
        try persistLocked()
        return state.commands[index]
    }

    /// An older Watch snapshot can arrive after a newer one. It must not
    /// regress the cached workout view.
    @discardableResult
    public func replaceSnapshot(_ snapshot: WatchWorkoutSnapshot) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let current = state.snapshot, current.phoneRevision > snapshot.phoneRevision {
            return false
        }
        state.snapshot = snapshot
        try persistLocked()
        return true
    }

    private func persistLocked() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try HealthCoachJSON.encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }
}
