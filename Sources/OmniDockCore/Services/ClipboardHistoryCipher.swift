import CryptoKit
import Darwin
import Foundation

// Clipboard history is the densest personal data this app keeps: a rolling
// record of everything the user copied, including material that no app marked
// as concealed. The archive is therefore sealed with AES-256-GCM, so the store
// file holds no readable content: nothing in it can be recovered with sqlite3,
// strings, or a text editor, and a copy of the file — a backup, a clone, a disk
// handed on to someone else — carries no readable history with it.
//
// The key is 32 random bytes kept beside the archive with 0600 permissions.
// That is a deliberate trade: a process running as this user can read the key
// as easily as the archive, so this does not defend against one. In exchange
// the feature works on every Mac, with no Keychain in the picture — no
// dependency on a login keychain that may not exist, no authorization prompts
// when the app is re-signed, and no environment where history silently stops
// persisting.
enum ClipboardHistoryKeyError: Error, Equatable {
    case storageUnavailable(Int32)
    case malformedKey
}

protocol ClipboardHistoryKeyStoring {
    func loadOrCreateKey() throws -> SymmetricKey
}

struct ClipboardHistoryLocalKeyStore: ClipboardHistoryKeyStoring {
    private static let keyByteCount = 32

    private let keyURL: URL?
    private let fileManager: FileManager

    init(
        keyURL: URL? = ClipboardHistoryLocalKeyStore.defaultKeyURL(),
        fileManager: FileManager = .default
    ) {
        self.keyURL = keyURL
        self.fileManager = fileManager
    }

    static func defaultKeyURL() -> URL? {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("OmniDock", isDirectory: true)
            .appendingPathComponent("ClipboardHistoryKey", isDirectory: false)
    }

    func loadOrCreateKey() throws -> SymmetricKey {
        guard let keyURL else {
            throw ClipboardHistoryKeyError.storageUnavailable(ENOENT)
        }
        if let key = try loadKey(at: keyURL) {
            return key
        }
        return try createKey(at: keyURL)
    }

    private func loadKey(at url: URL) throws -> SymmetricKey? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        guard data.count == Self.keyByteCount else {
            throw ClipboardHistoryKeyError.malformedKey
        }
        // Re-assert the permissions in case the file was ever restored or
        // copied back with something looser.
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return SymmetricKey(data: data)
    }

    private func createKey(at url: URL) throws -> SymmetricKey {
        try? ClipboardStoreFileProtection.prepareDirectory(
            url.deletingLastPathComponent(),
            fileManager: fileManager
        )

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }

        // O_EXCL with mode 0600: the file is created atomically and is never
        // readable by other accounts, not even for the instant between creating
        // it and adjusting its permissions. A second instance that loses the
        // race reads the key that won rather than overwriting it, which would
        // strand the archive the winner is already encrypting.
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                return -1
            }
            return open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == EEXIST, let existing = try loadKey(at: url) {
                return existing
            }
            throw ClipboardHistoryKeyError.storageUnavailable(code)
        }
        defer { close(descriptor) }

        let written = keyData.withUnsafeBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else {
                return -1
            }
            return write(descriptor, baseAddress, buffer.count)
        }
        guard written == Self.keyByteCount else {
            let code = errno
            // Never leave a short key behind; it would decrypt nothing and
            // would be indistinguishable from a valid one on the next launch.
            try? fileManager.removeItem(at: url)
            throw ClipboardHistoryKeyError.storageUnavailable(code)
        }
        return key
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
