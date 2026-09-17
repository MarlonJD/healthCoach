import Foundation
import Network
import HealthCoachKit

enum PhoneSyncService {
    static func synchronize(store: HealthCoachStore, localPeerID: UUID, credential: PairingCredential, duration: TimeInterval) async throws {
        let browser = HealthCoachBonjourBrowser()
        defer { browser.stop() }
        let endpoint = try await findEndpoint(browser: browser, peerID: credential.peerID)
        #if canImport(Security)
        let connection = try await HealthCoachNetworkClient.connect(endpoint: endpoint, credential: credential)
        defer { Task { await connection.close() } }
        let coordinator = SyncSessionCoordinator(store: store, pairID: credential.pairID, localPeerID: localPeerID, remotePeerID: credential.peerID, localSender: .phone)
        let runner = Task {
            try await SyncConnectionRunner.run(transport: connection, coordinator: coordinator)
        }
        let deadline = Date().addingTimeInterval(max(duration, 0.5))
        while Date() < deadline {
            if await coordinator.isAuthenticated(), await coordinator.isQuiescent() {
                // SyncSessionCoordinator keeps a short remote-activity settle
                // window so a Mac result batch can be applied and acknowledged
                // before this foreground connection closes.
                if await coordinator.isQuiescent() { break }
            } else {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        runner.cancel()
        await connection.close()
        _ = await runner.result
        if !(await coordinator.isAuthenticated()) {
            throw HealthCoachError.protocolError("The Mac did not complete the pairing acknowledgment.")
        }
        #else
        throw HealthCoachError.unavailable("TLS is unavailable on this platform.")
        #endif
    }

    private static func findEndpoint(browser: HealthCoachBonjourBrowser, peerID: UUID) async throws -> NWEndpoint {
        try await withThrowingTaskGroup(of: NWEndpoint.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let resolver = EndpointResolver(continuation: continuation)
                    browser.start { results in
                        for result in results {
                            if case .service(let name, _, _, _) = result.endpoint, name == peerID.uuidString {
                                resolver.resolve(.success(result.endpoint))
                                return
                            }
                        }
                    } onError: { error in
                        resolver.resolve(.failure(error))
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 8_000_000_000)
                throw HealthCoachError.unavailable("The paired Mac was not found on the local network.")
            }
            guard let endpoint = try await group.next() else { throw HealthCoachError.unavailable("No Mac endpoint was discovered.") }
            group.cancelAll()
            return endpoint
        }
    }

    private final class EndpointResolver: @unchecked Sendable {
        private let lock = NSLock()
        private var resolved = false
        private let continuation: CheckedContinuation<NWEndpoint, Error>

        init(continuation: CheckedContinuation<NWEndpoint, Error>) {
            self.continuation = continuation
        }

        func resolve(_ result: Result<NWEndpoint, Error>) {
            lock.lock()
            guard !resolved else { lock.unlock(); return }
            resolved = true
            lock.unlock()
            continuation.resume(with: result)
        }
    }
}
