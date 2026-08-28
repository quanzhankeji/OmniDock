import CryptoKit
import Foundation
import Security

// Clipboard history is the densest personal data this app keeps: a rolling
// record of everything the user copied, including material that no app marked
// as concealed. In the Developer ID build it lives in Application Support,
// which carries no TCC protection, so file permissions alone leave it readable
// by anything running as this user and by anything that reads a backup or a
// cloned disk. Entry contents are therefore sealed with a key kept in the
// Keychain: reading the store file is no longer enough to read the history.
enum ClipboardHistoryKeyError: Error, Equatable {
    case keychainUnavailable(OSStatus)
    case malformedKey
}

protocol ClipboardHistoryKeyStoring {
    func loadOrCreateKey() throws -> SymmetricKey
}

// The item is stored in the login keychain, whose ACL admits the creating
// application and prompts the user for anything else. The data protection
// keychain is deliberately not used: it needs a keychain access group
// entitlement the Developer ID build does not carry.
struct ClipboardHistoryKeychainKeyStore: ClipboardHistoryKeyStoring {
    static let service = "com.quanzhankeji.OmniDock"
    static let account = "clipboard-history-key"
    private static let keyByteCount = 32

    func loadOrCreateKey() throws -> SymmetricKey {
        if let key = try loadKey() {
            return key
        }
        return try createKey()
    }

    private func loadKey() throws -> SymmetricKey? {
        var query = Self.baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  data.count == Self.keyByteCount
            else {
                throw ClipboardHistoryKeyError.malformedKey
            }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw ClipboardHistoryKeyError.keychainUnavailable(status)
        }
    }

    private func createKey() throws -> SymmetricKey {
        var keyData = Data(count: Self.keyByteCount)
        let result = keyData.withUnsafeMutableBytes { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else {
                return errSecAllocate
            }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard result == errSecSuccess else {
            throw ClipboardHistoryKeyError.keychainUnavailable(OSStatus(result))
        }

        var attributes = Self.baseQuery
        attributes[kSecValueData as String] = keyData
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return SymmetricKey(data: keyData)
        case errSecDuplicateItem:
            // Another instance created the key between the read and the write.
            guard let key = try loadKey() else {
                throw ClipboardHistoryKeyError.keychainUnavailable(status)
            }
            return key
        default:
            throw ClipboardHistoryKeyError.keychainUnavailable(status)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}

// Every sealed value is a self-contained AES-GCM box: nonce, ciphertext, and
// tag. Authentication matters as much as secrecy here, because the store file
// is writable by anything running as this user and decoded content is handed
// straight back to the pasteboard.
struct ClipboardHistoryCipher {
    private let contentKey: SymmetricKey
    private let indexKey: SymmetricKey

    init(key: SymmetricKey) {
        // Separate subkeys so the deduplication index cannot be used to probe
        // the content encryption, and vice versa.
        contentKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key,
            info: Data("omnidock.clipboard.content".utf8),
            outputByteCount: 32
        )
        indexKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key,
            info: Data("omnidock.clipboard.index".utf8),
            outputByteCount: 32
        )
    }

    // A store that never touches the disk has nothing to protect against, but
    // routing it through the same path keeps one code path in production.
    static func ephemeral() -> ClipboardHistoryCipher {
        ClipboardHistoryCipher(key: SymmetricKey(size: .bits256))
    }

    func seal(_ data: Data) -> Data? {
        try? AES.GCM.seal(data, using: contentKey).combined
    }

    // Returns nil when the box does not open: a wrong key, or a value that was
    // tampered with. Both mean the entry is gone, not that it can be salvaged.
    func open(_ sealed: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed) else {
            return nil
        }
        return try? AES.GCM.open(box, using: contentKey)
    }

    func seal(text: String) -> Data? {
        seal(Data(text.utf8))
    }

    func openText(_ sealed: Data) -> String? {
        open(sealed).flatMap { String(data: $0, encoding: .utf8) }
    }

    // Deduplication needs a stable identifier for identical content, but a
    // plain digest of the payload would let anyone holding the file confirm a
    // guess about what was copied. Keying it keeps lookups working while making
    // the column meaningless without the key.
    func blindIndex(for fingerprint: String) -> String {
        HMAC<SHA256>.authenticationCode(
            for: Data(fingerprint.utf8),
            using: indexKey
        ).map { String(format: "%02x", $0) }.joined()
    }
}
