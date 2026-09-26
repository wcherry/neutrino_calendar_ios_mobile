import Foundation
import os.log
import UniformTypeIdentifiers
import NeutrinoAuth
import NeutrinoCrypto

// MARK: - AttachmentError

enum AttachmentError: LocalizedError, Equatable {
    /// This device holds no encryption key for the account.
    case noKey
    /// It holds one, but not the version this file's key was sealed to.
    case missingKeyVersion(Int)
    case tooLarge
    case uploadIncomplete

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "This file is encrypted, and this iPhone doesn't have your encryption key yet. Add it in Settings › Encryption."
        case .missingKeyVersion(let version):
            return "This file needs encryption key version \(version), which this iPhone doesn't have. Restore your key again in Settings › Encryption."
        case .tooLarge:
            return "This file is too large to open here. Open it in Neutrino Drive."
        case .uploadIncomplete:
            return "The file was uploaded but its key couldn't be saved, so it was removed. Try again."
        }
    }
}

// MARK: - Keys

/// The account keys this app can use, from the keyring every Neutrino app on the device shares.
/// Behind a protocol so tests can supply a keypair without a Keychain.
@MainActor
protocol AttachmentKeys {
    func activeKeyPair() -> (publicKey: [UInt8], secretKey: [UInt8], version: Int)?
    func keyPair(forVersion version: Int) throws -> (publicKey: [UInt8], secretKey: [UInt8])
}

/// The account's keys on this device, wherever they were put.
///
/// Two stores exist. The keyring is shared by every Neutrino app on the device, and is what
/// pairing with another device writes. The older split store is this app's own, and is what
/// first-time setup and a recovery-kit restore (`KeyProvisioningService`) write. The keyring is
/// read first; either one is enough.
@MainActor
struct DeviceKeys: AttachmentKeys {
    static var hasKey: Bool { KeyringStore.shared.hasKeyring || KeyImportService.hasStoredKeys() }

    func activeKeyPair() -> (publicKey: [UInt8], secretKey: [UInt8], version: Int)? {
        if let active = KeyringStore.shared.activeKeyPair() { return active }
        guard let stored = KeyImportService.storedKeys(),
              let publicKey = Self.decode(stored.publicKey),
              let secretKey = Self.decode(stored.privateKey) else { return nil }
        return (publicKey, secretKey, KeyImportService.activeKeyVersion())
    }

    func keyPair(forVersion version: Int) throws -> (publicKey: [UInt8], secretKey: [UInt8]) {
        if let pair = try? KeyringStore.shared.keyPair(forVersion: version) { return pair }
        switch KeyImportService.keyPair(forVersion: version) {
        case .found(let publicKey, let privateKey):
            guard let pub = Self.decode(publicKey), let sec = Self.decode(privateKey) else {
                throw AttachmentError.noKey
            }
            return (pub, sec)
        case .missingVersion(let missing):
            throw AttachmentError.missingKeyVersion(missing)
        case .noKey:
            throw KeyringStore.shared.hasKeyring ? AttachmentError.missingKeyVersion(version) : AttachmentError.noKey
        }
    }

    /// The split store holds base64url or base64, padded or not; `Base64URL` reads them all.
    private static func decode(_ string: String) -> [UInt8]? { Base64URL.decode(string) }
}

// MARK: - AttachmentFiles

/// Gets attached Drive files onto the phone to preview, and new ones into Drive.
///
/// Drive files are end-to-end encrypted: the server holds ciphertext and a key sealed to the
/// account's identity key, which only the user's devices have. So opening one means fetching both
/// and decrypting here, and adding one means encrypting here first, exactly as the web does
/// (`DriveFileCrypto`, shared with the other apps). A file that was stored in the clear, from
/// before encryption, opens as it is. An upload is never sent in the clear: without a key it
/// fails, as it does on the web.
@MainActor
final class AttachmentFiles: ObservableObject {

    /// The Drive folder new attachments go in, the one the web uses for inserted images.
    static let folderName = "Attachments"
    /// Decryption happens in memory, as on the web; past this a phone might not cope.
    static let maxOpenBytes: Int64 = 250 * 1024 * 1024

    private let client: CalendarAPIClient
    private let keys: AttachmentKeys
    private let cacheDirectory: URL
    private let userID: () -> String?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoCalendar",
                                category: "AttachmentFiles")

    init(client: CalendarAPIClient, keys: AttachmentKeys? = nil,
         cacheDirectory: URL = AttachmentFiles.defaultCacheDirectory,
         userID: @escaping () -> String? = { AccessToken.currentUserID() }) {
        self.client = client
        self.keys = keys ?? DeviceKeys()
        self.cacheDirectory = cacheDirectory
        self.userID = userID
    }

    nonisolated static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Attachments", isDirectory: true)
    }

    // MARK: - Browsing

    /// A Drive folder's contents, for the picker. The root's id is the user's id.
    func folder(id: String) async throws -> DriveFolderContents {
        try await client.driveFolder(id: id)
    }

    // MARK: - Opening

    /// The file's metadata, for choosing how to open it.
    func metadata(fileID: String) async throws -> DriveFile {
        try await client.driveFileMetadata(id: fileID)
    }

    /// A plaintext copy of the file on this device, for Quick Look. Kept in Caches under its
    /// content version, so opening it again doesn't download it again, and an edited file does.
    func localCopy(of file: DriveFile) async throws -> URL {
        guard file.sizeBytes <= Self.maxOpenBytes else { throw AttachmentError.tooLarge }
        let folder = cacheDirectory
            .appendingPathComponent(file.id, isDirectory: true)
            .appendingPathComponent("v\(file.contentVersion ?? 0)", isDirectory: true)
        if let cached = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first {
            return cached
        }

        let stored = try await client.driveFileContent(id: file.id)
        var name = file.name
        var plaintext = stored
        if file.isEncrypted, let sealed = try await client.driveFileKey(id: file.id) {
            let pair = try keyPair(forVersion: sealed.keyVersion)
            let encryptedMetadata = file.encryptedMetadata
            (name, plaintext) = try await Task.detached(priority: .userInitiated) {
                let dek = try DriveFileCrypto.openDEK(sealed.encryptedFileKey,
                                                      publicKey: pair.publicKey, secretKey: pair.secretKey)
                let metadata = try encryptedMetadata.map { try DriveFileCrypto.decryptMetadata($0, dek: dek) }
                let content = try DriveFileCrypto.decrypt(stored, dek: dek, chunkSize: metadata?.chunkSize)
                return (metadata?.name.isEmpty == false ? metadata!.name : name, content)
            }.value
        }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Self.safeFileName(name, mimeType: file.mimeType))
        // Complete protection: the plaintext is unreadable while the phone is locked.
        try plaintext.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Forgets every decrypted copy, for sign-out.
    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    private func keyPair(forVersion version: Int) throws -> (publicKey: [UInt8], secretKey: [UInt8]) {
        guard keys.activeKeyPair() != nil else { throw AttachmentError.noKey }
        return try keys.keyPair(forVersion: version)
    }

    // MARK: - Uploading

    /// Whether this device can add files: it needs the account's key to encrypt them.
    var canUpload: Bool { keys.activeKeyPair() != nil }

    /// Encrypts `data` and stores it in Drive's Attachments folder, as the web does.
    func upload(_ data: Data, name: String, mimeType: String) async throws -> DriveFile {
        guard let active = keys.activeKeyPair() else { throw AttachmentError.noKey }
        let folderID = try await attachmentsFolderID()
        let fileName = Self.safeFileName(name, mimeType: mimeType)

        let sealed = try await Task.detached(priority: .userInitiated) {
            let dek = DriveFileCrypto.newDEK()
            return (content: try DriveFileCrypto.encrypt(data, dek: dek),
                    metadata: try DriveFileCrypto.encryptMetadata(.init(name: fileName, mimeType: mimeType), dek: dek),
                    key: try DriveFileCrypto.seal(dek: dek, toPublicKey: active.publicKey))
        }.value

        let file = try await client.uploadDriveFile(ciphertext: sealed.content, name: fileName, mimeType: mimeType,
                                                    folderID: folderID, encryptedMetadata: sealed.metadata)
        // Without its key the file can never be opened, by anyone. Try hard, and if the key
        // still can't be stored, take the file back out rather than leave it unreadable.
        let key = DriveFileKey(encryptedFileKey: sealed.key, keyVersion: active.version)
        for attempt in 1...3 {
            do {
                try await client.setDriveFileKey(id: file.id, key)
                return file
            } catch {
                logger.error("storing the key failed (attempt \(attempt)): \(error, privacy: .public)")
                if attempt < 3 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000) }
            }
        }
        try? await client.trashDriveFile(id: file.id)
        throw AttachmentError.uploadIncomplete
    }

    /// The id of the root's "Attachments" folder, made if it isn't there. The root's id is the
    /// user's id.
    private func attachmentsFolderID() async throws -> String? {
        guard let root = userID() else { throw CalendarAPIError.notAuthenticated }
        let contents = try await client.driveFolder(id: root)
        if let existing = contents.folders.first(where: {
            $0.name.caseInsensitiveCompare(Self.folderName) == .orderedSame
        }) {
            return existing.id
        }
        return try await client.createDriveFolder(name: Self.folderName).id
    }

    // MARK: - Names

    /// A name safe as a file name and as a multipart `filename`, with an extension that matches
    /// its type so Quick Look knows what it is.
    nonisolated static func safeFileName(_ name: String, mimeType: String) -> String {
        var clean = name.components(separatedBy: CharacterSet(charactersIn: "/\\\"\r\n:")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        if clean.isEmpty || clean.hasPrefix(".") { clean = "Attachment" + clean }
        if (clean as NSString).pathExtension.isEmpty,
           let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension {
            clean += "." + ext
        }
        return clean
    }
}
