#if canImport(Network)
import Dispatch
import Foundation
import Network

#if canImport(Security)
import Security
#endif

public enum HealthCoachLANService {
    public static let bonjourType = "_healthcoach._tcp"
}

#if canImport(Security)
public enum TLSPSK {
    public static func configureClient(_ options: NWProtocolTLS.Options, credential: PairingCredential) {
        configure(options, credential: credential, advertiseHint: false)
        let expectedIdentity = Data(credential.pairID.uuidString.utf8)
        let identity = dispatchData(expectedIdentity)
        sec_protocol_options_set_pre_shared_key_selection_block(
            options.securityProtocolOptions,
            { _, hint, complete in
                if let hint, dispatchDataToData(hint) != expectedIdentity {
                    complete(nil)
                    return
                }
                complete(identity as __DispatchData)
            },
            DispatchQueue(label: "com.marlonjd.HealthCoach.tls-psk-client")
        )
    }

    public static func configureServer(_ options: NWProtocolTLS.Options, credential: PairingCredential) {
        configure(options, credential: credential, advertiseHint: true)
    }

    private static func configure(_ options: NWProtocolTLS.Options, credential: PairingCredential, advertiseHint: Bool) {
        let secret = dispatchData(credential.secret)
        let identity = dispatchData(Data(credential.pairID.uuidString.utf8))
        sec_protocol_options_add_pre_shared_key(options.securityProtocolOptions, secret, identity)
        if advertiseHint {
            sec_protocol_options_set_tls_pre_shared_key_identity_hint(options.securityProtocolOptions, identity)
        }
        // PSK authenticates the peer; a certificate exchange is neither
        // required nor accepted for this local pairing protocol.
        sec_protocol_options_set_peer_authentication_required(options.securityProtocolOptions, false)
    }

    private static func dispatchData(_ data: Data) -> dispatch_data_t {
        data.withUnsafeBytes { DispatchData(bytes: $0) as __DispatchData }
    }

    private static func dispatchDataToData(_ data: dispatch_data_t) -> Data {
        let dispatchData = data as DispatchData
        return dispatchData.withUnsafeBytes { Data(bytes: $0, count: dispatchData.count) }
    }
}
#endif

public final class HealthCoachNetworkConnection: SyncByteTransport, @unchecked Sendable {
    private final class StartResolution: @unchecked Sendable {
        private let lock = NSLock()
        private var resolved = false

        func resolve(_ body: () -> Void) {
            lock.lock()
            guard !resolved else {
                lock.unlock()
                return
            }
            resolved = true
            lock.unlock()
            body()
        }
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var streamContinuation: AsyncThrowingStream<SyncEnvelope, Error>.Continuation?
    private var didStartReceiving = false

    public init(connection: NWConnection, queue: DispatchQueue = DispatchQueue(label: "com.marlonjd.HealthCoach.connection")) {
        self.connection = connection
        self.queue = queue
    }

    public func start() async throws {
        let resolution = StartResolution()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        resolution.resolve { continuation.resume() }
                    case .failed(let error):
                        resolution.resolve { continuation.resume(throwing: HealthCoachError.protocolError(error.localizedDescription)) }
                    case .cancelled:
                        resolution.resolve { continuation.resume(throwing: HealthCoachError.cancelled) }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        }, onCancel: { [connection] in
            connection.cancel()
        })
    }

    public func send(_ envelope: SyncEnvelope) async throws {
        let frame = try LengthPrefixedFrameCodec.encode(envelope)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: HealthCoachError.protocolError(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func receive() -> AsyncThrowingStream<SyncEnvelope, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            streamContinuation = continuation
            let shouldStart = !didStartReceiving
            didStartReceiving = true
            lock.unlock()
            if shouldStart { receiveNext(decoder: LengthPrefixedFrameDecoder()) }
        }
    }

    public func close() async {
        connection.cancel()
        finishReceiving()
    }

    private func receiveNext(decoder: LengthPrefixedFrameDecoder) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: HealthCoachConstants.maximumFrameBytes + 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var decoder = decoder
            do {
                if let error { throw HealthCoachError.protocolError(error.localizedDescription) }
                if let data {
                    for body in try decoder.append(data) {
                        self.yield(try HealthCoachJSON.decode(SyncEnvelope.self, from: body))
                    }
                }
                if isComplete {
                    self.finishReceiving()
                } else {
                    self.receiveNext(decoder: decoder)
                }
            } catch {
                self.finishReceiving(with: error)
            }
        }
    }

    private func yield(_ envelope: SyncEnvelope) {
        lock.lock()
        streamContinuation?.yield(envelope)
        lock.unlock()
    }

    private func finishReceiving(with error: Error? = nil) {
        lock.lock()
        if let error { streamContinuation?.finish(throwing: error) } else { streamContinuation?.finish() }
        streamContinuation = nil
        lock.unlock()
    }
}

public final class HealthCoachNetworkListener: @unchecked Sendable {
    public let peerID: UUID
    public let port: NWEndpoint.Port?
    private let listener: NWListener
    private let queue: DispatchQueue

    #if canImport(Security)
    public init(peerID: UUID, credential: PairingCredential, port: NWEndpoint.Port? = nil) throws {
        self.peerID = peerID
        self.queue = DispatchQueue(label: "com.marlonjd.HealthCoach.listener")
        let tls = NWProtocolTLS.Options()
        TLSPSK.configureServer(tls, credential: credential)
        let parameters = NWParameters(tls: tls)
        parameters.allowLocalEndpointReuse = true
        self.listener = try port.map { try NWListener(using: parameters, on: $0) } ?? NWListener(using: parameters)
        self.port = port
        listener.service = NWListener.Service(name: peerID.uuidString, type: HealthCoachLANService.bonjourType)
    }
    #else
    public init(peerID: UUID, credential: PairingCredential, port: NWEndpoint.Port? = nil) throws {
        throw HealthCoachError.unavailable("TLS is unavailable on this platform.")
    }
    #endif

    public func start(onConnection: @escaping @Sendable (HealthCoachNetworkConnection) -> Void, onError: (@Sendable (Error) -> Void)? = nil) {
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { onError?(HealthCoachError.protocolError(error.localizedDescription)) }
        }
        listener.newConnectionHandler = { connection in
            let framed = HealthCoachNetworkConnection(connection: connection, queue: self.queue)
            connection.start(queue: self.queue)
            onConnection(framed)
        }
        listener.start(queue: queue)
    }

    public var boundPort: NWEndpoint.Port? {
        listener.port
    }

    public func stop() {
        listener.cancel()
    }
}

#if canImport(Security)
public enum HealthCoachNetworkClient {
    public static func connect(host: NWEndpoint.Host, port: NWEndpoint.Port, credential: PairingCredential) async throws -> HealthCoachNetworkConnection {
        try await connect(endpoint: .hostPort(host: host, port: port), credential: credential)
    }

    public static func connect(endpoint: NWEndpoint, credential: PairingCredential) async throws -> HealthCoachNetworkConnection {
        let tls = NWProtocolTLS.Options()
        TLSPSK.configureClient(tls, credential: credential)
        let parameters = NWParameters(tls: tls)
        parameters.allowLocalEndpointReuse = true
        let connection = NWConnection(to: endpoint, using: parameters)
        let framed = HealthCoachNetworkConnection(connection: connection)
        try await framed.start()
        return framed
    }
}
#endif

public final class HealthCoachBonjourBrowser: @unchecked Sendable {
    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "com.marlonjd.HealthCoach.browser")

    public init() {
        browser = NWBrowser(for: .bonjour(type: HealthCoachLANService.bonjourType, domain: nil), using: .tcp)
    }

    public func start(onChange: @escaping @Sendable ([NWBrowser.Result]) -> Void, onError: (@Sendable (Error) -> Void)? = nil) {
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state { onError?(HealthCoachError.protocolError(error.localizedDescription)) }
        }
        browser.browseResultsChangedHandler = { results, _ in onChange(Array(results)) }
        browser.start(queue: queue)
    }

    public func stop() {
        browser.cancel()
    }
}
#endif
