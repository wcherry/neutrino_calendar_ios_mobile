import Foundation
import os.log

// MARK: - PendingWrite

/// An edit or delete that could not reach the server, kept to be sent again. Only `PUT`, `PATCH`
/// and `DELETE`: they name the thing they change, so sending one twice does no harm. A create
/// is not queued; replaying one could make a duplicate.
struct PendingWrite: Codable, Identifiable, Equatable {
    var id = UUID()
    let method: String
    let path: String
    let body: Data?
    var attempts = 0

    init(method: String, path: String, body: Data? = nil) {
        self.method = method
        self.path = path
        self.body = body
    }

    init(method: String, path: String, json: some Encodable) {
        self.init(method: method, path: path, body: try? JSONEncoder().encode(json))
    }
}

// MARK: - PendingWrites

/// Writes made offline, sent in order once the server can be reached again.
///
/// Saved to a file after every change, so a queued edit survives the app being closed. The
/// replay is last-writer-wins on the fields each write carries. An edit only sends what it
/// changed, so a field changed elsewhere in the meantime is overwritten only when this edit
/// changed the same field.
@MainActor
final class PendingWrites: ObservableObject {

    @Published private(set) var writes: [PendingWrite] = []

    /// A write the server keeps failing with a 5xx is dropped after this many tries, so one bad
    /// write can't hold up every one queued behind it.
    static let maxAttempts = 5

    private let fileURL: URL
    private var isReplaying = false
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoCalendar",
                                category: "PendingWrites")

    init(fileURL: URL = PendingWrites.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([PendingWrite].self, from: data) {
            writes = saved
        }
    }

    nonisolated static var defaultFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("pending-writes.json")
    }

    var isEmpty: Bool { writes.isEmpty }

    func enqueue(_ write: PendingWrite) {
        // A later delete makes every queued edit of the same thing moot.
        if write.method == "DELETE" { writes.removeAll { $0.path == write.path } }
        writes.append(write)
        save()
        logger.info("queued \(write.method, privacy: .public) \(write.path, privacy: .public)")
    }

    /// Forgets every queued write, for sign-out: the next account must not send this one's edits.
    func clear() {
        writes = []
        save()
    }

    /// Sends the queued writes in order, stopping at the first that still can't get through.
    /// Returns how many were done with, sent or dropped, so the caller knows whether to reload.
    @discardableResult
    func replay(using client: CalendarAPIClient) async -> Int {
        guard !isReplaying else { return 0 }
        isReplaying = true
        defer { isReplaying = false }
        var finished = 0
        while let write = writes.first {
            do {
                try await client.replay(write)
            } catch let error as CalendarAPIError {
                if error.isNetwork || error == .notAuthenticated { break }
                if case .serverError(let code) = error, code >= 500 {
                    guard writes.first?.id == write.id else { break }
                    writes[0].attempts += 1
                    save()
                    if writes[0].attempts < Self.maxAttempts { break }
                }
                // A 404 means it was deleted elsewhere; any other 4xx is a write the server will
                // never take. Either way, sending it again cannot help.
                logger.error("dropping \(write.method, privacy: .public) \(write.path, privacy: .public): \(error, privacy: .public)")
            } catch {
                logger.error("dropping \(write.path, privacy: .public): \(error, privacy: .public)")
            }
            // Sign-out may have cleared the queue while this write was in flight.
            guard writes.first?.id == write.id else { break }
            writes.removeFirst()
            save()
            finished += 1
        }
        return finished
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(writes).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("save failed: \(error, privacy: .public)")
        }
    }
}
