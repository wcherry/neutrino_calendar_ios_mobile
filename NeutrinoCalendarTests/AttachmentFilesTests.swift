import XCTest
import Sodium
import NeutrinoCrypto
@testable import NeutrinoCalendar

/// A keyring holding one keypair, at `version`.
@MainActor
private struct FakeKeys: AttachmentKeys {
    let pair: Box.KeyPair?
    var version = 2

    func activeKeyPair() -> (publicKey: [UInt8], secretKey: [UInt8], version: Int)? {
        pair.map { ($0.publicKey, $0.secretKey, version) }
    }

    func keyPair(forVersion wanted: Int) throws -> (publicKey: [UInt8], secretKey: [UInt8]) {
        guard let pair else { throw AttachmentError.noKey }
        guard wanted == version else { throw AttachmentError.missingKeyVersion(wanted) }
        return (pair.publicKey, pair.secretKey)
    }
}

@MainActor
final class AttachmentFilesTests: XCTestCase {

    private let sodium = Sodium()
    private var pair: Box.KeyPair!
    private var cache: URL!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        pair = sodium.box.keyPair()!
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("att-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cache)
        super.tearDown()
    }

    private func files(keys: FakeKeys? = nil) -> AttachmentFiles {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CalendarAPIClient(session: URLSession(configuration: config),
                                       baseURL: { "https://example.test" }, token: { "tok" })
        return AttachmentFiles(client: client, keys: keys ?? FakeKeys(pair: pair), cacheDirectory: cache,
                               userID: { "user-1" })
    }

    private func string(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

    // MARK: - Opening

    func testAPlaintextFileOpensAsItIs() async throws {
        let file = DriveFile(id: "f", name: "Notes.txt", mimeType: "text/plain", contentVersion: 1)
        MockURLProtocol.respondInSequence([(200, "plain words")])
        let url = try await files().localCopy(of: file)
        XCTAssertEqual(url.lastPathComponent, "Notes.txt")
        XCTAssertEqual(try string(url), "plain words")
        XCTAssertEqual(MockURLProtocol.requests.map { $0.url!.path }, ["/api/v1/drive/files/f"])
    }

    /// Written as the web writes it; opened with the keyring version its key names, and saved
    /// under the name in its encrypted metadata.
    func testAnEncryptedFileIsDecryptedHere() async throws {
        let dek = DriveFileCrypto.newDEK()
        let content = try DriveFileCrypto.encrypt(Data("secret agenda".utf8), dek: dek)
        let metadata = try DriveFileCrypto.encryptMetadata(.init(name: "Agenda.txt", mimeType: "text/plain"), dek: dek)
        let sealed = try DriveFileCrypto.seal(dek: dek, toPublicKey: pair.publicKey)
        let file = DriveFile(id: "f", name: "Agenda.txt", mimeType: "text/plain", encryptedMetadata: metadata, contentVersion: 3)
        MockURLProtocol.respondInSequenceData([
            (200, content),
            (200, Data(#"{"encryptedFileKey":"\#(sealed)","keyVersion":2}"#.utf8)),
        ])

        let url = try await files().localCopy(of: file)

        XCTAssertEqual(try string(url), "secret agenda")
        XCTAssertEqual(url.lastPathComponent, "Agenda.txt")
        XCTAssertTrue(url.path.contains("/f/v3/"), "cached under its content version")
    }

    func testASecondOpenUsesTheCopyOnThePhone() async throws {
        let file = DriveFile(id: "f", name: "a.txt", mimeType: "text/plain", contentVersion: 1)
        MockURLProtocol.respondInSequence([(200, "one")])
        let service = files()
        _ = try await service.localCopy(of: file)
        _ = try await service.localCopy(of: file)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
    }

    func testWithoutTheKeyAnEncryptedFileSaysSo() async {
        let file = DriveFile(id: "f", name: "a.txt", mimeType: "text/plain", encryptedMetadata: "x", contentVersion: 1)
        MockURLProtocol.respondInSequence([(200, "cipher"), (200, #"{"encryptedFileKey":"k","keyVersion":1}"#)])
        do {
            _ = try await files(keys: FakeKeys(pair: nil)).localCopy(of: file)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AttachmentError, .noKey)
        }
    }

    func testAMissingKeyVersionIsNamed() async {
        let file = DriveFile(id: "f", name: "a.txt", mimeType: "text/plain", encryptedMetadata: "x", contentVersion: 1)
        MockURLProtocol.respondInSequence([(200, "cipher"), (200, #"{"encryptedFileKey":"k","keyVersion":1}"#)])
        do {
            _ = try await files().localCopy(of: file)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AttachmentError, .missingKeyVersion(1))
        }
    }

    /// The web's rule: flagged encrypted but with no key stored for us, the bytes are the file.
    func testEncryptedMetadataWithNoStoredKeyOpensAsItIs() async throws {
        let file = DriveFile(id: "f", name: "a.txt", mimeType: "text/plain", encryptedMetadata: "x", contentVersion: 1)
        MockURLProtocol.respondInSequence([(200, "as stored"), (404, "{}")])
        let url = try await files().localCopy(of: file)
        XCTAssertEqual(try string(url), "as stored")
    }

    func testAHugeFileIsNotOpenedHere() async {
        let file = DriveFile(id: "f", name: "a.mov", mimeType: "video/quicktime",
                             sizeBytes: AttachmentFiles.maxOpenBytes + 1)
        do {
            _ = try await files().localCopy(of: file)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AttachmentError, .tooLarge)
        }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    // MARK: - Uploading

    private static let root = #"{"folders":[{"id":"att","name":"attachments"}],"files":[]}"#
    private static let uploaded = #"{"id":"new","name":"Photo.jpg","mimeType":"image/jpeg","sizeBytes":42}"#

    func testAnUploadIsEncryptedAndItsKeyStored() async throws {
        MockURLProtocol.respondInSequence([(200, Self.root), (201, Self.uploaded), (200, "{}")])

        let file = try await files().upload(Data("jpeg bytes".utf8), name: "Photo.jpg", mimeType: "image/jpeg")

        XCTAssertEqual(file.id, "new")
        let requests = MockURLProtocol.requests
        XCTAssertEqual(requests.map { "\($0.httpMethod!) \($0.url!.path)" },
                       ["GET /api/v1/drive/folders/user-1", "POST /api/v1/drive/files/upload",
                        "PUT /api/v1/drive/files/new/key"])

        // The key: sealed to this keyring's active version.
        let key = try JSONDecoder().decode(DriveFileKey.self, from: try XCTUnwrap(MockURLProtocol.lastBody))
        XCTAssertEqual(key.keyVersion, 2)
        let dek = try DriveFileCrypto.openDEK(key.encryptedFileKey, publicKey: pair.publicKey, secretKey: pair.secretKey)

        // The upload: fields before the file, the file ciphertext, into Attachments.
        let body = try XCTUnwrap(MockURLProtocol.bodies[1])
        let text = String(decoding: body, as: UTF8.self)
        let fields = ["name=\"encrypted_metadata\"", "name=\"folder_id\"", "name=\"file\"; filename=\"Photo.jpg\""]
        let positions = fields.map { text.range(of: $0)?.lowerBound }
        XCTAssertFalse(positions.contains(nil), text)
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted())
        XCTAssertTrue(text.contains("\r\n\r\natt\r\n"), "into the Attachments folder")
        XCTAssertFalse(text.contains("jpeg bytes"), "never in the clear")

        let marker = Data("Content-Type: image/jpeg\r\n\r\n".utf8)
        let start = try XCTUnwrap(body.range(of: marker)).upperBound
        let end = try XCTUnwrap(body.range(of: Data("\r\n--".utf8), in: start..<body.endIndex)).lowerBound
        XCTAssertEqual(try DriveFileCrypto.decrypt(body[start..<end], dek: dek), Data("jpeg bytes".utf8))
    }

    func testTheAttachmentsFolderIsMadeWhenMissing() async throws {
        MockURLProtocol.respondInSequence([
            (200, #"{"folders":[],"files":[]}"#), (201, #"{"id":"att2","name":"Attachments"}"#),
            (201, Self.uploaded), (200, "{}"),
        ])
        _ = try await files().upload(Data("x".utf8), name: "a.txt", mimeType: "text/plain")
        XCTAssertEqual(MockURLProtocol.requests[1].url?.path, "/api/v1/drive/folders")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: MockURLProtocol.bodies[1]!) as? [String: String],
                       ["name": "Attachments"])
    }

    /// A file whose key never reached the server can't be opened by anyone: it is taken back out.
    func testAnUploadWhoseKeyCantBeStoredIsRemoved() async {
        MockURLProtocol.respondInSequence([(200, Self.root), (201, Self.uploaded),
                                           (500, "{}"), (500, "{}"), (500, "{}"), (200, "{}")])
        do {
            _ = try await files().upload(Data("x".utf8), name: "a.txt", mimeType: "text/plain")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AttachmentError, .uploadIncomplete)
        }
        XCTAssertEqual(MockURLProtocol.requests.last.map { "\($0.httpMethod!) \($0.url!.path)" },
                       "DELETE /api/v1/drive/files/new")
    }

    func testNothingIsUploadedWithoutAKey() async {
        do {
            _ = try await files(keys: FakeKeys(pair: nil)).upload(Data("x".utf8), name: "a", mimeType: "text/plain")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AttachmentError, .noKey)
        }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    // MARK: - Names

    func testSafeFileNames() {
        XCTAssertEqual(AttachmentFiles.safeFileName("Photo 2026-09-26", mimeType: "image/jpeg"), "Photo 2026-09-26.jpeg")
        XCTAssertEqual(AttachmentFiles.safeFileName("a/b\"c.pdf", mimeType: "application/pdf"), "a-b-c.pdf")
        XCTAssertEqual(AttachmentFiles.safeFileName("  ", mimeType: "text/plain"), "Attachment.txt")
        XCTAssertEqual(AttachmentFiles.safeFileName(".hidden", mimeType: "text/plain"), "Attachment.hidden")
    }

    func testAttachmentRequests() throws {
        let file = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CreateAttachmentRequest.file(id: "f", name: "a.pdf"))) as? [String: String]
        XCTAssertEqual(file, ["fileId": "f", "name": "a.pdf"])
        let note = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CreateAttachmentRequest.note("hi"))) as? [String: String]
        XCTAssertEqual(note, ["note": "hi"])
    }
}
