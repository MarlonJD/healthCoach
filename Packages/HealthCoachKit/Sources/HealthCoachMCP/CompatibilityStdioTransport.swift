import Foundation
import Logging
import MCP

/// The Codex App Server advertises experimental MCP capabilities as a map of
/// JSON objects. MCP Swift SDK 0.12.1 models that field as `[String: String]`,
/// although HealthCoach never uses client experimental capabilities. Keep the
/// official SDK server and stdio transport, normalizing only this unsupported
/// capability at the transport boundary so Codex can initialize the helper.
actor CompatibilityStdioTransport: Transport {
    private let underlying: StdioTransport
    nonisolated let logger: Logger

    init() {
        underlying = StdioTransport()
        logger = Logger(label: "healthcoach.mcp.stdio", factory: { _ in SwiftLogNoOpLogHandler() })
    }

    func connect() async throws {
        try await underlying.connect()
    }

    func disconnect() async {
        await underlying.disconnect()
    }

    func send(_ data: Data) async throws {
        try await underlying.send(data)
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        let underlying = self.underlying
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let messages = await underlying.receive()
                    for try await message in messages {
                        continuation.yield(Self.normalized(message))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private static func normalized(_ data: Data) -> Data {
        guard
            var message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            message["method"] as? String == "initialize",
            var params = message["params"] as? [String: Any],
            var capabilities = params["capabilities"] as? [String: Any],
            let experimental = capabilities["experimental"]
        else { return data }

        // The SDK can decode an experimental object only when its values are
        // strings. The current Codex capability value is an object, so omit
        // this unused optional capability rather than misrepresenting it.
        if !(experimental is [String: String]) {
            capabilities.removeValue(forKey: "experimental")
            params["capabilities"] = capabilities
            message["params"] = params
            return (try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])) ?? data
        }
        return data
    }
}
