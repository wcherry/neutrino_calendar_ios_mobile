import Foundation
import NeutrinoCrypto
import os.log

/// The user's saved places, decrypted on this device.
///
/// The server holds each place as a `PlaceEnvelope` and can't read its name or where it is, so
/// everything that needs a place — the picker, Smart Add's `@Home`, the region planner, Nearby —
/// reads it from here. A place this device can't open (no key yet, or a key version it lacks) is
/// counted in `unreadable` rather than shown, and its tasks aren't watched.
@MainActor
final class PlacesService: ObservableObject {

    @Published private(set) var places: [TaskPlace] = []
    @Published private(set) var hasLoaded = false
    /// Saved places this device couldn't decrypt.
    @Published private(set) var unreadable = 0
    /// False once the server has answered 404: it predates saved places. One-off points still work.
    @Published private(set) var isSupported = true
    @Published var error: String?

    private let client: CalendarAPIClient
    private let keys: AttachmentKeys
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoCalendar",
                                category: "PlacesService")

    /// `keys` defaults to this device's; tests pass their own.
    init(client: CalendarAPIClient, keys: AttachmentKeys? = nil) {
        self.client = client
        self.keys = keys ?? DeviceKeys()
    }

    func place(id: String) -> TaskPlace? { places.first { $0.id == id } }

    /// Saving a place needs the account key, as reading one does.
    var canSave: Bool { isSupported && keys.activeKeyPair() != nil }

    // MARK: - Loading

    func reload() async {
        error = nil
        do {
            let records = try await client.taskPlaces()
            var opened: [TaskPlace] = []
            var failed = 0
            for record in records {
                if let place = open(record) { opened.append(place) } else { failed += 1 }
            }
            places = opened.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            unreadable = failed
            isSupported = true
            hasLoaded = true
        } catch let error as CalendarAPIError where error.isNotFound {
            places = []
            unreadable = 0
            isSupported = false
            hasLoaded = true
        } catch {
            logger.error("reload failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    func reset() {
        places = []
        hasLoaded = false
        unreadable = 0
        isSupported = true
        error = nil
    }

    // MARK: - Changes

    @discardableResult
    func create(name: String, point: GeoPoint) async throws -> TaskPlace {
        let payload = PlaceEnvelope.Payload(name: name, lat: point.latitude, lng: point.longitude, radiusM: point.radius)
        let record = try await client.createTaskPlace(SaveTaskPlaceRequest(encryptedPayload: try seal(payload)))
        let place = TaskPlace(id: record.id, payload: payload)
        replace(place)
        return place
    }

    @discardableResult
    func update(_ place: TaskPlace) async throws -> TaskPlace {
        _ = try await client.updateTaskPlace(id: place.id, SaveTaskPlaceRequest(encryptedPayload: try seal(place.payload)))
        replace(place)
        return place
    }

    /// Deletes the place. The server clears it from every task that used it, and the caller
    /// reloads the tasks to see that.
    func delete(_ place: TaskPlace) async throws {
        try await client.deleteTaskPlace(id: place.id)
        places.removeAll { $0.id == place.id }
    }

    // MARK: - Smart Add

    /// The saved place `text` names, for `@Home` in Smart Add: an exact name first, ignoring case
    /// and accents, then the only place whose name starts with it. Nil when nothing or more than
    /// one place would fit — a geofence is never attached on a guess.
    func match(_ text: String) -> TaskPlace? {
        Self.match(text, in: places)
    }

    static func match(_ text: String, in places: [TaskPlace]) -> TaskPlace? {
        func fold(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .replacingOccurrences(of: "[^\\p{L}\\p{N}]", with: "", options: .regularExpression)
        }
        let query = fold(text)
        guard !query.isEmpty else { return nil }
        if let exact = places.first(where: { fold($0.name) == query }) { return exact }
        let prefixed = places.filter { fold($0.name).hasPrefix(query) }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    // MARK: - Helpers

    private func seal(_ payload: PlaceEnvelope.Payload) throws -> String {
        guard let active = keys.activeKeyPair() else { throw AttachmentError.noKey }
        return try PlaceEnvelope.seal(payload, publicKey: active.publicKey, keyVersion: active.version)
    }

    private func open(_ record: TaskPlaceRecord) -> TaskPlace? {
        do {
            let version = try PlaceEnvelope.keyVersion(of: record.encryptedPayload)
            let pair = try keys.keyPair(forVersion: version)
            let payload = try PlaceEnvelope.open(record.encryptedPayload, publicKey: pair.publicKey,
                                                 secretKey: pair.secretKey)
            return TaskPlace(id: record.id, payload: payload)
        } catch {
            logger.error("could not open place \(record.id, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }

    private func replace(_ place: TaskPlace) {
        places.removeAll { $0.id == place.id }
        places.append(place)
        places.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
