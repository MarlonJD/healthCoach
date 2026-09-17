import Foundation

/// The first four bytes of every LAN message are a big-endian body length.
/// Keeping framing separate from Network.framework makes malformed input
/// testable without ever opening a real socket.
public struct LengthPrefixedFrameDecoder: Sendable {
    private var buffer = Data()
    public let maximumBodyBytes: Int

    public init(maximumBodyBytes: Int = HealthCoachConstants.maximumFrameBytes) {
        self.maximumBodyBytes = maximumBodyBytes
    }

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0, Int(length) <= maximumBodyBytes else {
                throw length > UInt32(maximumBodyBytes)
                    ? HealthCoachError.frameTooLarge(Int(length))
                    : HealthCoachError.malformedFrame
            }
            let bodyLength = Int(length)
            let total = 4 + bodyLength
            guard buffer.count >= total else { break }
            // Copy through collection operations instead of constructing a
            // range from assumed integer indices. Network.framework may hand
            // us a Data value whose slice indices are not zero-based; using
            // dropFirst/prefix keeps the bounds tied to the actual collection
            // and prevents a malformed peer frame from trapping the listener.
            let body = Data(buffer.dropFirst(4).prefix(bodyLength))
            guard body.count == bodyLength else { throw HealthCoachError.malformedFrame }
            frames.append(body)
            buffer.removeFirst(total)
        }
        return frames
    }

    public var remainder: Data { buffer }
}

public enum LengthPrefixedFrameCodec {
    public static func encode(body: Data, maximumBodyBytes: Int = HealthCoachConstants.maximumFrameBytes) throws -> Data {
        guard !body.isEmpty else { throw HealthCoachError.malformedFrame }
        guard body.count <= maximumBodyBytes else { throw HealthCoachError.frameTooLarge(body.count) }
        let length = UInt32(body.count)
        var frame = Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff)
        ])
        frame.append(body)
        return frame
    }

    public static func encode(_ envelope: SyncEnvelope) throws -> Data {
        try encode(body: HealthCoachJSON.encode(envelope))
    }

    public static func decodeEnvelopes(from data: Data) throws -> ([SyncEnvelope], Data) {
        var decoder = LengthPrefixedFrameDecoder()
        let bodies = try decoder.append(data)
        let envelopes = try bodies.map { try HealthCoachJSON.decode(SyncEnvelope.self, from: $0) }
        return (envelopes, decoder.remainder)
    }
}

public struct SyncHello: Codable, Equatable, Sendable {
    public var peerID: UUID
    public var pairID: UUID
    public var sender: SyncSender
    public var protocolVersion: Int
    public var schemaVersion: Int
    public var lastAppliedSequence: Int64
    public var currentWatermark: Int64

    public init(
        peerID: UUID,
        pairID: UUID,
        sender: SyncSender,
        protocolVersion: Int = HealthCoachConstants.protocolVersion,
        schemaVersion: Int = HealthCoachConstants.schemaVersion,
        lastAppliedSequence: Int64 = 0,
        currentWatermark: Int64 = 0
    ) {
        self.peerID = peerID
        self.pairID = pairID
        self.sender = sender
        self.protocolVersion = protocolVersion
        self.schemaVersion = schemaVersion
        self.lastAppliedSequence = lastAppliedSequence
        self.currentWatermark = currentWatermark
    }
}

public struct SyncAuthenticated: Codable, Equatable, Sendable {
    public var peerID: UUID
    public var acceptedSender: SyncSender
    public var cursor: Int64
    public var requiresSnapshot: Bool

    public init(peerID: UUID, acceptedSender: SyncSender, cursor: Int64, requiresSnapshot: Bool) {
        self.peerID = peerID
        self.acceptedSender = acceptedSender
        self.cursor = cursor
        self.requiresSnapshot = requiresSnapshot
    }
}

public struct SyncPausePolicy: Codable, Equatable, Sendable {
    public var policy: AnalysisPolicy
    public var acknowledgedRevision: Int?

    public init(policy: AnalysisPolicy, acknowledgedRevision: Int? = nil) {
        self.policy = policy
        self.acknowledgedRevision = acknowledgedRevision
    }
}

public protocol SyncByteTransport: Sendable {
    func send(_ envelope: SyncEnvelope) async throws
    func receive() -> AsyncThrowingStream<SyncEnvelope, Error>
    func close() async
}

/// Runs one already-authenticated transport until its peer disconnects. Every
/// response is derived from durable cursors/outboxes, so a reconnect repeats
/// safely instead of treating socket delivery as a commit.
public enum SyncConnectionRunner {
    private enum Event: Sendable {
        case envelope(SyncEnvelope)
        case localChange
    }

    public static func run(
        transport: SyncByteTransport,
        coordinator: SyncSessionCoordinator,
        onCommitted: (@MainActor @Sendable (SyncEnvelope) async -> Void)? = nil,
        localChanges: AsyncStream<Void>? = nil
    ) async throws {
        try await transport.send(await coordinator.hello())
        guard let localChanges else {
            for try await envelope in transport.receive() {
                let responses = try await coordinator.handle(envelope)
                await onCommitted?(envelope)
                for response in responses {
                    try await transport.send(response)
                }
            }
            return
        }

        // A peer may be connected while the local store commits a result or
        // status update. Multiplex receive events and durable local-change
        // signals, then serialize all coordinator reads and socket writes in
        // this one loop so a push cannot race an acknowledgment.
        let events = AsyncThrowingStream<Event, Error> { continuation in
            let receiveTask = Task {
                do {
                    for try await envelope in transport.receive() {
                        continuation.yield(.envelope(envelope))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let localChangeTask = Task {
                for await _ in localChanges {
                    continuation.yield(.localChange)
                }
            }
            continuation.onTermination = { _ in
                receiveTask.cancel()
                localChangeTask.cancel()
            }
        }

        for try await event in events {
            switch event {
            case .envelope(let envelope):
                let responses = try await coordinator.handle(envelope)
                await onCommitted?(envelope)
                for response in responses {
                    try await transport.send(response)
                }
            case .localChange:
                for response in try await coordinator.nextOutgoing() {
                    try await transport.send(response)
                }
            }
        }
    }
}

/// Owns the protocol-level cursor and mutation rules for one authenticated
/// phone↔Mac connection. The concrete socket is deliberately kept outside the
/// store so reconnects can resend from durable outbox state.
public actor SyncSessionCoordinator {
    public let pairID: UUID
    public let localPeerID: UUID
    public private(set) var remotePeerID: UUID?
    public let localSender: SyncSender
    public let remoteSender: SyncSender

    private let store: HealthCoachStore
    /// Sequence from the Mac/phone stream that this store has applied.
    private var remoteAppliedSequence: Int64 = 0
    /// Local outbox sequence the peer has durably acknowledged.
    private var localAcknowledgedSequence: Int64 = 0
    private var authenticated = false
    private var receivingSnapshot = false
    private var lastRemoteActivityAt: Date?
    private let remoteSettleWindow: TimeInterval = 0.25

    public init(
        store: HealthCoachStore,
        pairID: UUID,
        localPeerID: UUID,
        remotePeerID: UUID? = nil,
        localSender: SyncSender
    ) {
        self.store = store
        self.pairID = pairID
        self.localPeerID = localPeerID
        self.remotePeerID = remotePeerID
        self.localSender = localSender
        self.remoteSender = localSender == .phone ? .mac : .phone
    }

    public func hello() throws -> SyncEnvelope {
        remoteAppliedSequence = try store.appliedSequence(pairID: pairID, sender: remoteSender)
        let body = SyncHello(
            peerID: localPeerID,
            pairID: pairID,
            sender: localSender,
            lastAppliedSequence: remoteAppliedSequence,
            currentWatermark: try store.currentWatermark()
        )
        return try makeEnvelope(kind: .hello, body: body)
    }

    public func handle(_ envelope: SyncEnvelope) throws -> [SyncEnvelope] {
        guard envelope.version == HealthCoachConstants.protocolVersion else {
            throw HealthCoachError.unsupportedVersion(envelope.version)
        }
        guard envelope.pairID == pairID,
              remotePeerID == nil || envelope.authenticatedPeerID == remotePeerID else {
            throw HealthCoachError.revokedPair
        }
        switch envelope.kind {
        case .hello:
            let hello = try HealthCoachJSON.decode(SyncHello.self, from: envelope.body)
            guard hello.pairID == pairID,
                  hello.sender == remoteSender,
                  hello.protocolVersion == HealthCoachConstants.protocolVersion,
                  hello.schemaVersion == HealthCoachConstants.schemaVersion else {
                throw HealthCoachError.protocolError("The peer hello is not compatible.")
            }
            if let remotePeerID {
                guard hello.peerID == remotePeerID, envelope.authenticatedPeerID == remotePeerID else {
                    throw HealthCoachError.revokedPair
                }
            } else {
                remotePeerID = hello.peerID
                guard envelope.authenticatedPeerID == hello.peerID else {
                    throw HealthCoachError.protocolError("The peer hello identity is inconsistent.")
                }
            }
            remoteAppliedSequence = try store.appliedSequence(pairID: pairID, sender: remoteSender)
            localAcknowledgedSequence = max(localAcknowledgedSequence, hello.lastAppliedSequence)
            try store.acknowledgeOutbox(pairID: pairID, sender: localSender, through: hello.lastAppliedSequence)
            authenticated = true
            lastRemoteActivityAt = Date()
            let hasRecords = try !store.snapshotRecords(limit: 1).isEmpty
            let peerNeedsSnapshot = hello.lastAppliedSequence == 0 && hasRecords
            let localNeedsSnapshot = remoteAppliedSequence == 0 && hello.currentWatermark > 0
            let accepted = try makeEnvelope(kind: .authenticated, body: SyncAuthenticated(peerID: localPeerID, acceptedSender: localSender, cursor: remoteAppliedSequence, requiresSnapshot: localNeedsSnapshot))
            if peerNeedsSnapshot {
                return [accepted] + (try snapshotMessages())
            }
            return [accepted] + (try makeNextOutgoing())

        case .authenticated:
            let response = try HealthCoachJSON.decode(SyncAuthenticated.self, from: envelope.body)
            guard let remotePeerID,
                  response.peerID == remotePeerID, response.acceptedSender == remoteSender else {
                throw HealthCoachError.protocolError("The authenticated response is invalid.")
            }
            authenticated = true
            lastRemoteActivityAt = Date()
            localAcknowledgedSequence = max(localAcknowledgedSequence, response.cursor)
            try store.acknowledgeOutbox(pairID: pairID, sender: localSender, through: response.cursor)
            if response.requiresSnapshot {
                return try snapshotMessages()
            }
            return try makeNextOutgoing()

        case .batch:
            guard authenticated else { throw HealthCoachError.protocolError("The session is not authenticated.") }
            guard let remotePeerID else { throw HealthCoachError.protocolError("The peer identity is not established.") }
            let batch = try HealthCoachJSON.decode(SyncBatch.self, from: envelope.body)
            guard batch.sender == remoteSender else { throw HealthCoachError.wrongOwner }
            let ack = try store.applyIncoming(batch, authenticatedPeerID: remotePeerID, pairID: pairID)
            remoteAppliedSequence = ack.lastSequence
            lastRemoteActivityAt = Date()
            let acknowledgment = try makeEnvelope(kind: .acknowledgment, body: ack)
            var responses = [acknowledgment]
            if let pauseAcknowledgment = try makePauseAcknowledgment(for: batch) {
                responses.append(pauseAcknowledgment)
            }
            return responses + (try makeNextOutgoing())

        case .acknowledgment:
            guard authenticated else { throw HealthCoachError.protocolError("The session is not authenticated.") }
            let ack = try HealthCoachJSON.decode(SyncAcknowledgment.self, from: envelope.body)
            guard ack.sender == localSender else { throw HealthCoachError.wrongOwner }
            localAcknowledgedSequence = max(localAcknowledgedSequence, ack.lastSequence)
            try store.acknowledgeOutbox(pairID: pairID, sender: localSender, through: ack.lastSequence)
            return try makeNextOutgoing()

        case .snapshotOffer:
            guard authenticated, envelope.sender == remoteSender else { throw HealthCoachError.protocolError("The session is not authenticated.") }
            let descriptor = try HealthCoachJSON.decode(SnapshotDescriptor.self, from: envelope.body)
            guard descriptor.pairID == pairID, descriptor.sourceSender == remoteSender else { throw HealthCoachError.wrongOwner }
            receivingSnapshot = true
            lastRemoteActivityAt = Date()
            try store.beginSnapshot(descriptor)
            return []

        case .snapshotBatch:
            guard authenticated, envelope.sender == remoteSender else { throw HealthCoachError.protocolError("The session is not authenticated.") }
            let payload = try HealthCoachJSON.decode(SnapshotBatchPayload.self, from: envelope.body)
            try store.stageSnapshotBatch(pairID: pairID, snapshotID: payload.snapshotID, records: payload.records)
            return []

        case .snapshotComplete:
            guard authenticated, envelope.sender == remoteSender else { throw HealthCoachError.protocolError("The session is not authenticated.") }
            let descriptor = try HealthCoachJSON.decode(SnapshotDescriptor.self, from: envelope.body)
            guard descriptor.pairID == pairID, descriptor.sourceSender == remoteSender else { throw HealthCoachError.wrongOwner }
            try store.completeSnapshot(pairID: pairID, snapshotID: descriptor.snapshotID)
            remoteAppliedSequence = descriptor.sourceSequence
            receivingSnapshot = false
            lastRemoteActivityAt = Date()
            return try makeNextOutgoing()

        case .pausePolicy:
            guard authenticated, envelope.sender == remoteSender else { throw HealthCoachError.protocolError("The session is not authenticated.") }
            let pause = try HealthCoachJSON.decode(SyncPausePolicy.self, from: envelope.body)
            if localSender == .phone {
                let currentPolicyRevision = try store.analysisPolicy().revision
                guard pause.acknowledgedRevision == pause.policy.revision,
                      pause.policy.revision == currentPolicyRevision else {
                    throw HealthCoachError.protocolError("The pause acknowledgment is invalid.")
                }
                try store.recordAnalysisPolicyAcknowledgment(revision: pause.policy.revision)
                return []
            }
            try store.applyRemoteAnalysisPolicy(pause.policy)
            let acknowledgement = SyncPausePolicy(policy: pause.policy, acknowledgedRevision: pause.policy.revision)
            return [try makeEnvelope(kind: .pausePolicy, body: acknowledgement)]

        case .goodbye:
            return []
        }
    }

    public func nextOutgoing(limit: Int = HealthCoachConstants.maximumBatchRecords) throws -> [SyncEnvelope] {
        try makeNextOutgoing(limit: limit)
    }

    public func isAuthenticated() -> Bool {
        authenticated
    }

    /// True only after the local sender has no unacknowledged mutations and a
    /// received snapshot has been activated. Model work may still be queued;
    /// this only describes the durable initial sync exchange.
    public func isQuiescent() -> Bool {
        guard authenticated, !receivingSnapshot else { return false }
        guard (try? store.pendingOutbox(sender: localSender, after: localAcknowledgedSequence, limit: 1).isEmpty) ?? false else { return false }
        guard let lastRemoteActivityAt else { return true }
        return Date().timeIntervalSince(lastRemoteActivityAt) >= remoteSettleWindow
    }

    private func makeNextOutgoing(limit: Int = HealthCoachConstants.maximumBatchRecords) throws -> [SyncEnvelope] {
        guard authenticated else { return [] }
        let mutations = try store.pendingOutbox(sender: localSender, after: localAcknowledgedSequence, limit: min(limit, HealthCoachConstants.maximumBatchRecords))
        guard let first = mutations.first else { return [] }
        let batch = SyncBatch(sender: localSender, firstSequence: first.sequence, lastSequence: mutations.last?.sequence ?? first.sequence, mutations: mutations)
        return [try makeEnvelope(kind: .batch, body: batch)]
    }

    private func makePauseAcknowledgment(for batch: SyncBatch) throws -> SyncEnvelope? {
        guard localSender == .mac,
              let mutation = batch.mutations.last(where: { $0.mutationKind == .policy }) else { return nil }
        let policy = try HealthCoachJSON.decode(AnalysisPolicy.self, from: mutation.payload)
        return try makeEnvelope(
            kind: .pausePolicy,
            body: SyncPausePolicy(policy: policy, acknowledgedRevision: policy.revision)
        )
    }

    private func snapshotMessages() throws -> [SyncEnvelope] {
        let records = try store.snapshotRecords()
        let descriptor = try store.makeSnapshotDescriptor(pairID: pairID, sourceSender: localSender)
        var messages = [try makeEnvelope(kind: .snapshotOffer, body: descriptor)]
        for start in stride(from: 0, to: records.count, by: HealthCoachConstants.maximumBatchRecords) {
            let end = min(start + HealthCoachConstants.maximumBatchRecords, records.count)
            let payload = SnapshotBatchPayload(snapshotID: descriptor.snapshotID, records: Array(records[start..<end]))
            messages.append(try makeEnvelope(kind: .snapshotBatch, body: payload))
        }
        messages.append(try makeEnvelope(kind: .snapshotComplete, body: descriptor))
        localAcknowledgedSequence = max(localAcknowledgedSequence, descriptor.sourceSequence)
        // Mutations created while the snapshot was being assembled are newer
        // than its source watermark. Send them immediately after completion;
        // they must not wait for a reconnect to become visible to the peer.
        return messages + (try makeNextOutgoing())
    }

    private func makeEnvelope<T: Encodable>(kind: SyncMessageKind, body: T) throws -> SyncEnvelope {
        SyncEnvelope(version: HealthCoachConstants.protocolVersion, kind: kind, pairID: pairID, authenticatedPeerID: localPeerID, sender: localSender, body: try HealthCoachJSON.encode(body))
    }

}

/// Reconnects a paired endpoint using durable cursors. A failed socket is
/// disposable; queued mutations remain in SQLite and are sent again after the
/// bounded backoff. Cancellation is the only normal way to stop the loop.
public actor SyncReconnectLoop {
    private let connect: @Sendable () async throws -> SyncByteTransport
    private let coordinator: SyncSessionCoordinator
    private var stopped = false

    public init(
        connect: @escaping @Sendable () async throws -> SyncByteTransport,
        coordinator: SyncSessionCoordinator
    ) {
        self.connect = connect
        self.coordinator = coordinator
    }

    public func stop() {
        stopped = true
    }

    public func run() async {
        var attempt = 0
        while !stopped && !Task.isCancelled {
            do {
                let transport = try await connect()
                attempt = 0
                try await SyncConnectionRunner.run(transport: transport, coordinator: coordinator)
                await transport.close()
            } catch {
                attempt = min(attempt + 1, 6)
                let seconds = UInt64(1 << min(attempt - 1, 5))
                do {
                    try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                } catch {
                    return
                }
            }
        }
    }
}
