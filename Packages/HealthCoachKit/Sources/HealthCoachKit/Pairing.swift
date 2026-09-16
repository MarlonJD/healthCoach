import Foundation

#if canImport(Security)
import Security
#endif

public enum PairingCredentialFactory {
    public static func make(peerID: UUID, lifetime: TimeInterval = 600) throws -> PairingCredential {
        var bytes = [UInt8](repeating: 0, count: 32)
        #if canImport(Security)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw HealthCoachError.unavailable("The system random source is unavailable.")
        }
        #else
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = generator.next() }
        #endif
        return PairingCredential(peerID: peerID, secret: Data(bytes), expiresAt: Date().addingTimeInterval(lifetime))
    }

    public static func makeQRPayload(from credential: PairingCredential) throws -> Data {
        guard credential.isUsable else { throw HealthCoachError.revokedPair }
        return try HealthCoachJSON.encode(
            PairingQRPayload(
                pairID: credential.pairID,
                macPeerID: credential.peerID,
                credential: credential.secret,
                expiresAt: credential.expiresAt
            )
        )
    }

    public static func decodeQRPayload(_ data: Data, now: Date = Date()) throws -> PairingQRPayload {
        let payload = try HealthCoachJSON.decode(PairingQRPayload.self, from: data)
        guard payload.protocolVersion == HealthCoachConstants.protocolVersion,
              payload.expiresAt > now,
              payload.credential.count == 32 else {
            throw HealthCoachError.revokedPair
        }
        return payload
    }

    /// QR credentials are short-lived until both peers acknowledge the first
    /// authenticated session. The resulting paired credential is persistent;
    /// its secret is still device-only Keychain data and can be revoked by
    /// removing the pairing.
    public static func activated(_ credential: PairingCredential) -> PairingCredential {
        var activated = credential
        activated.expiresAt = .distantFuture
        return activated
    }
}

public protocol PairingCredentialStore: Sendable {
    func save(_ credential: PairingCredential) throws
    func load(pairID: UUID) throws -> PairingCredential?
    func delete(pairID: UUID) throws
}

#if canImport(Security)
/// Stores the PSK only in the non-synchronizing device Keychain. The service
/// and account contain identifiers, never display names or health content.
public final class KeychainPairingCredentialStore: PairingCredentialStore, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.marlonjd.HealthCoach.pairing") {
        self.service = service
    }

    public func save(_ credential: PairingCredential) throws {
        let data = try HealthCoachJSON.encode(credential)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: credential.pairID.uuidString,
            kSecAttrSynchronizable: false
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else { throw keychainError(updateStatus) }
        } else if status != errSecSuccess {
            throw keychainError(status)
        }
    }

    public func load(pairID: UUID) throws -> PairingCredential? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: pairID.uuidString,
            kSecAttrSynchronizable: false,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw keychainError(status) }
        return try HealthCoachJSON.decode(PairingCredential.self, from: data)
    }

    public func delete(pairID: UUID) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: pairID.uuidString,
            kSecAttrSynchronizable: false
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }

    private func keychainError(_ status: OSStatus) -> HealthCoachError {
        .unavailable("Keychain operation failed (\(status)).")
    }
}
#else
public final class KeychainPairingCredentialStore: PairingCredentialStore, @unchecked Sendable {
    public init(service: String = "com.marlonjd.HealthCoach.pairing") {}
    public func save(_ credential: PairingCredential) throws { throw HealthCoachError.unavailable("Keychain is unavailable on this platform.") }
    public func load(pairID: UUID) throws -> PairingCredential? { nil }
    public func delete(pairID: UUID) throws {}
}
#endif
