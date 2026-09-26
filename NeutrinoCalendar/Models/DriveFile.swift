import Foundation

// MARK: - Attachment

/// One attachment on an event or a task: a Drive file, or a short text note, never both.
///
/// `GET /calendar/events/{id}/attachments` and `GET /calendar/tasks/{id}/attachments` answer the
/// same shape, so both screens share this type and `AttachmentsSection`.
struct Attachment: Decodable, Identifiable, Hashable {
    let id: String
    let fileId: String?
    let name: String?
    let note: String?

    var isFile: Bool { fileId != nil }
}

typealias EventAttachment = Attachment
typealias TaskAttachment = Attachment

struct ListAttachmentsResponse: Decodable {
    let attachments: [Attachment]
}

typealias ListTaskAttachmentsResponse = ListAttachmentsResponse

/// `CreateAttachmentRequest` (events) and `CreateTaskAttachmentRequest` (tasks): a file id and
/// its name, or a note.
struct CreateAttachmentRequest: Encodable, Equatable {
    var fileId: String?
    var name: String?
    var note: String?

    static func file(id: String, name: String) -> Self { .init(fileId: id, name: name) }
    static func note(_ text: String) -> Self { .init(note: text) }
}

typealias CreateTaskAttachmentRequest = CreateAttachmentRequest

// MARK: - Drive

/// A file in a Drive listing (`FileResponse` in `neutrino/src/drive/filesystem/dto.rs`). The
/// name is stored in the clear; for an encrypted file the content and `encryptedMetadata` are
/// ciphertext.
struct DriveFile: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let mimeType: String
    let sizeBytes: Int64
    let encryptedMetadata: String?
    let contentVersion: Int?

    var isEncrypted: Bool { !(encryptedMetadata ?? "").isEmpty }

    private enum CodingKeys: String, CodingKey {
        case id, name, mimeType, sizeBytes, encryptedMetadata, contentVersion
    }

    /// Tolerant, because three endpoints answer with three variants: the upload and metadata
    /// responses may leave `mimeType` out.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? "application/octet-stream"
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes) ?? 0
        encryptedMetadata = try c.decodeIfPresent(String.self, forKey: .encryptedMetadata)
        contentVersion = try c.decodeIfPresent(Int.self, forKey: .contentVersion)
    }

    /// For tests and previews.
    init(id: String, name: String, mimeType: String, sizeBytes: Int64 = 0,
         encryptedMetadata: String? = nil, contentVersion: Int? = nil) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.encryptedMetadata = encryptedMetadata
        self.contentVersion = contentVersion
    }
}

struct DriveFolder: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let parentId: String?
}

/// `GET /drive/folders/{id}`. The root has no folder row; its id is the user's id.
struct DriveFolderContents: Decodable {
    let folder: DriveFolder?
    let folders: [DriveFolder]
    let files: [DriveFile]
}

struct CreateFolderRequest: Encodable {
    let name: String
    var parentId: String?
}

/// `GET /drive/files/{id}/key`: the file's DEK sealed to one of the caller's keyring versions.
struct DriveFileKey: Codable, Equatable {
    let encryptedFileKey: String
    let keyVersion: Int
}
