import Foundation
import CryptoKit
import Security

/// Manages the Ed25519 device identity used for OpenClaw Gateway authentication.
/// Keys are generated once and stored in the Keychain.
final class DeviceIdentity {

    private static let keychainServicePriv = "com.clawsses.device.ed25519.private"
    private static let keychainServicePub  = "com.clawsses.device.ed25519.public"
    private static let keychainServiceToken = "com.clawsses.device.token"

    private let privateKey: Curve25519.Signing.PrivateKey

    /// SHA-256 hex fingerprint of the raw 32-byte public key.
    let deviceId: String

    /// Raw 32-byte public key, base64url-encoded (no padding).
    let publicKeyBase64Url: String

    /// Persisted device token from a successful pairing (nil if not yet paired).
    var deviceToken: String? {
        get { KeychainHelper.load(service: Self.keychainServiceToken) }
        set {
            if let value = newValue {
                KeychainHelper.save(service: Self.keychainServiceToken, data: value)
            } else {
                KeychainHelper.delete(service: Self.keychainServiceToken)
            }
        }
    }

    init() {
        if let restoredKey = Self.loadOrGenerateKey() {
            privateKey = restoredKey
        } else {
            privateKey = Curve25519.Signing.PrivateKey()
            Self.persistKey(privateKey)
        }

        let rawPublicKey = Data(privateKey.publicKey.rawRepresentation)

        let digest = SHA256.hash(data: rawPublicKey)
        deviceId = digest.map { String(format: "%02x", $0) }.joined()

        publicKeyBase64Url = rawPublicKey.base64URLEncodedString()
    }

    /// Build and sign the device auth payload per OpenClaw protocol v2.
    /// Format: "v2|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce"
    func signAuthPayload(
        clientId: String,
        clientMode: String,
        role: String,
        scopes: [String],
        signedAtMs: Int64,
        token: String,
        nonce: String
    ) -> String {
        let payload = ["v2", deviceId, clientId, clientMode, role,
                       scopes.joined(separator: ","),
                       String(signedAtMs), token, nonce].joined(separator: "|")
        guard let data = payload.data(using: .utf8),
              let sig = try? privateKey.signature(for: data) else { return "" }
        return Data(sig).base64URLEncodedString()
    }

    // MARK: - Private

    private static func loadOrGenerateKey() -> Curve25519.Signing.PrivateKey? {
        guard let rawData = KeychainHelper.loadData(service: keychainServicePriv),
              rawData.count == 32 else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: rawData)
    }

    private static func persistKey(_ key: Curve25519.Signing.PrivateKey) {
        let privRaw = Data(key.rawRepresentation)
        let pubRaw  = Data(key.publicKey.rawRepresentation)
        KeychainHelper.saveData(service: keychainServicePriv, data: privRaw)
        KeychainHelper.saveData(service: keychainServicePub,  data: pubRaw)
        // Clear any stale device token since device ID changed.
        KeychainHelper.delete(service: keychainServiceToken)
    }
}

// MARK: - Keychain Helper

enum KeychainHelper {
    static func save(service: String, data: String) {
        saveData(service: service, data: Data(data.utf8))
    }

    static func load(service: String) -> String? {
        guard let data = loadData(service: service) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveData(service: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String:   data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func loadData(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(service: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Data base64url extension

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
