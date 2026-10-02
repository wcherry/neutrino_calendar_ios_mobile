import XCTest
import Sodium
import NeutrinoCrypto
@testable import NeutrinoCalendar

/// A keyring holding a keypair per version, the last one active.
@MainActor
private struct VersionedKeys: AttachmentKeys {
    var pairs: [Int: (publicKey: [UInt8], secretKey: [UInt8])]

    func activeKeyPair() -> (publicKey: [UInt8], secretKey: [UInt8], version: Int)? {
        guard let version = pairs.keys.max(), let pair = pairs[version] else { return nil }
        return (pair.publicKey, pair.secretKey, version)
    }

    func keyPair(forVersion version: Int) throws -> (publicKey: [UInt8], secretKey: [UInt8]) {
        guard !pairs.isEmpty else { throw AttachmentError.noKey }
        guard let pair = pairs[version] else { throw AttachmentError.missingKeyVersion(version) }
        return pair
    }
}

// MARK: - PlaceEnvelope

/// `Fixtures/place_envelope_vectors.json` is sealed by the web's own `e2e-crypto`
/// (`scripts/generate_place_envelope_vectors.mjs`), so these prove the app opens what the web
/// writes. The web's tests read the same file the other way round.
final class PlaceEnvelopeTests: XCTestCase {

    private struct Vectors: Decodable {
        struct Key: Decodable { let publicKey: String; let secretKey: String }
        struct Case: Decodable {
            let name: String
            let keyVersion: Int
            let encryptedPayload: String
            let expected: PlaceEnvelope.Payload
        }
        struct Rejected: Decodable { let name: String; let encryptedPayload: String; let error: String }
        let keys: [String: Key]
        let cases: [Case]
        let rejected: [Rejected]
    }

    private func vectors() throws -> Vectors {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "place_envelope_vectors", withExtension: "json"))
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func testOpensWhatTheWebSealed() throws {
        let vectors = try vectors()
        XCTAssertFalse(vectors.cases.isEmpty)
        for vector in vectors.cases {
            let key = try XCTUnwrap(vectors.keys[String(vector.keyVersion)], vector.name)
            XCTAssertEqual(try PlaceEnvelope.keyVersion(of: vector.encryptedPayload), vector.keyVersion, vector.name)
            let payload = try PlaceEnvelope.open(vector.encryptedPayload,
                                                 publicKey: XCTUnwrap(Base64URL.decode(key.publicKey)),
                                                 secretKey: XCTUnwrap(Base64URL.decode(key.secretKey)))
            XCTAssertEqual(payload, vector.expected, vector.name)
        }
    }

    func testRejectsWhatItCantRead() throws {
        for vector in try vectors().rejected {
            XCTAssertThrowsError(try PlaceEnvelope.keyVersion(of: vector.encryptedPayload), vector.name) { error in
                switch (vector.error, error as? PlaceEnvelope.Failure) {
                case ("unsupportedVersion", .unsupportedVersion?), ("malformed", .malformed?): break
                default: XCTFail("\(vector.name): expected \(vector.error), got \(error)")
                }
            }
        }
    }

    func testTheWrongKeyCantOpenIt() throws {
        let vectors = try vectors()
        let vector = try XCTUnwrap(vectors.cases.first { $0.keyVersion == 2 })
        let other = try XCTUnwrap(vectors.keys["1"])
        XCTAssertThrowsError(try PlaceEnvelope.open(vector.encryptedPayload,
                                                    publicKey: XCTUnwrap(Base64URL.decode(other.publicKey)),
                                                    secretKey: XCTUnwrap(Base64URL.decode(other.secretKey))))
    }

    /// What this app seals has the shape the web reads, and holds nothing in the clear.
    func testSealsTheSharedShape() throws {
        let pair = try XCTUnwrap(Sodium().box.keyPair())
        let payload = PlaceEnvelope.Payload(name: "Home", lat: 51.501364, lng: -0.14189, radiusM: 150)
        let sealed = try PlaceEnvelope.seal(payload, publicKey: pair.publicKey, keyVersion: 3)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sealed.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["v", "keyVersion", "key", "data"])
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["keyVersion"] as? Int, 3)
        XCTAssertFalse(sealed.contains("Home"))
        XCTAssertFalse(sealed.contains("51.5"))

        XCTAssertEqual(try PlaceEnvelope.open(sealed, publicKey: pair.publicKey, secretKey: pair.secretKey), payload)
        // Through the Drive primitives the web's `decryptFileKey` / `decryptMetadata` mirror.
        let dek = try DriveFileCrypto.openDEK(XCTUnwrap(object["key"] as? String),
                                              publicKey: pair.publicKey, secretKey: pair.secretKey)
        let json = try DriveFileCrypto.decrypt(Data(XCTUnwrap(Base64URL.decode(XCTUnwrap(object["data"] as? String)))), dek: dek)
        XCTAssertEqual(try JSONDecoder().decode(PlaceEnvelope.Payload.self, from: json), payload)
    }

    /// Each seal has its own key, so two saves of one place don't show they are the same.
    func testEverySealIsFresh() throws {
        let pair = try XCTUnwrap(Sodium().box.keyPair())
        let payload = PlaceEnvelope.Payload(name: "Work", lat: 1, lng: 2, radiusM: 100)
        XCTAssertNotEqual(try PlaceEnvelope.seal(payload, publicKey: pair.publicKey, keyVersion: 1),
                          try PlaceEnvelope.seal(payload, publicKey: pair.publicKey, keyVersion: 1))
    }
}

// MARK: - Task geofence fields

final class TaskGeofenceModelTests: XCTestCase {

    private func decode(_ json: String) throws -> CalendarTask {
        try JSONDecoder().decode(CalendarTask.self, from: Data(json.utf8))
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    func testDecodesASavedPlaceAndAPoint() throws {
        let place = try decode(#"{"id":"a","title":"Milk","location":"Home","geoPlaceId":"p1"}"#)
        XCTAssertEqual(place.geofence, .place(id: "p1"))

        let point = try decode(#"{"id":"b","title":"Parcel","geoLat":51.5,"geoLng":-0.1,"geoRadiusM":250}"#)
        XCTAssertEqual(point.geofence, .point(GeoPoint(latitude: 51.5, longitude: -0.1, radius: 250)))
    }

    /// A server older than geofencing sends none of the fields; nulls mean none too.
    func testNoFieldsIsNoGeofence() throws {
        XCTAssertNil(try decode(#"{"id":"a","title":"t"}"#).geofence)
        XCTAssertNil(try decode(#"{"id":"a","title":"t","geoPlaceId":null,"geoLat":null,"geoLng":null}"#).geofence)
    }

    func testARadiusBelowTheMinimumIsRaised() {
        XCTAssertEqual(GeoPoint(latitude: 0, longitude: 0, radius: 20).radius, GeoPoint.minimumRadius)
        XCTAssertEqual(GeoPoint(latitude: 0, longitude: 0, radius: 99_999).radius, GeoPoint.maximumRadius)
    }

    /// One kind replaces the other, so all four fields go every time the geofence changes.
    func testSettingAGeofenceClearsTheOtherKind() throws {
        var place = UpdateTaskRequest()
        place.setGeofence(.place(id: "p1"))
        let p = try json(place)
        XCTAssertEqual(p["geoPlaceId"] as? String, "p1")
        XCTAssertTrue(p["geoLat"] is NSNull && p["geoLng"] is NSNull && p["geoRadiusM"] is NSNull)

        var point = UpdateTaskRequest()
        point.setGeofence(.point(GeoPoint(latitude: 1.5, longitude: 2.5, radius: 200)))
        let q = try json(point)
        XCTAssertTrue(q["geoPlaceId"] is NSNull)
        XCTAssertEqual(q["geoLat"] as? Double, 1.5)
        XCTAssertEqual(q["geoRadiusM"] as? Int, 200)

        var none = UpdateTaskRequest()
        none.setGeofence(nil)
        XCTAssertEqual(Set(try json(none).keys), ["geoPlaceId", "geoLat", "geoLng", "geoRadiusM"])
    }

    /// An edit that doesn't touch the place sends none of its fields, so an older client's edit
    /// — or this one's — never drops a geofence.
    @MainActor
    func testAnEditLeavesTheGeofenceAlone() throws {
        let task = CalendarTask(id: "t", title: "Milk", location: "Home", geofence: .place(id: "p1"))
        let rename = TasksService.request(from: task, title: "Oat milk", notes: "", dueDay: nil, calendar: .current)
        XCTAssertEqual(Set(try json(rename).keys), ["title"])

        let same = TasksService.request(from: task, title: "Milk", notes: "", dueDay: nil,
                                        geofence: .some(.place(id: "p1")), location: .some("Home"), calendar: .current)
        XCTAssertEqual(same, UpdateTaskRequest())

        let moved = TasksService.request(from: task, title: "Milk", notes: "", dueDay: nil,
                                         geofence: .some(.place(id: "p2")), location: .some("Work"), calendar: .current)
        let body = try json(moved)
        XCTAssertEqual(body["geoPlaceId"] as? String, "p2")
        XCTAssertEqual(body["location"] as? String, "Work")
    }

    func testAPlaceChangedOnBothSidesIsAConflictAboutThePlace() {
        var mine = UpdateTaskRequest(); mine.setGeofence(.place(id: "a"))
        var theirs = UpdateTaskRequest(); theirs.setGeofence(.place(id: "b"))
        XCTAssertEqual(EditConflict.clashes(mine: mine, theirs: theirs), ["place"])
    }

    func testAnOfflineEditKeepsTheGeofence() {
        let task = CalendarTask(id: "t", title: "Milk", geofence: .place(id: "p1"))
        XCTAssertEqual(task.with(title: "Oat milk").geofence, .place(id: "p1"))
        XCTAssertNil(task.with(geofence: .some(nil)).geofence)
    }
}

// MARK: - GeofencePlan

final class GeofencePlanTests: XCTestCase {

    private let home = TaskPlace(id: "home", name: "Home", point: GeoPoint(latitude: 51.5, longitude: -0.12))

    private func point(_ lat: Double, _ lng: Double = 0, radius: Int = 150) -> GeoPoint {
        GeoPoint(latitude: lat, longitude: lng, radius: radius)
    }

    func testTasksAtOneSavedPlaceShareARegion() {
        let tasks = [
            CalendarTask(id: "a", title: "Water plants", geofence: .place(id: "home")),
            CalendarTask(id: "b", title: "Parcel", location: "Post office", geofence: .point(point(51.6))),
            CalendarTask(id: "c", title: "Bins", geofence: .place(id: "home")),
            CalendarTask(id: "d", title: "Done already", done: true, geofence: .place(id: "home")),
            CalendarTask(id: "e", title: "Deleted place", geofence: .place(id: "gone")),
            CalendarTask(id: "f", title: "No place"),
        ]
        let regions = GeofencePlan.candidates(tasks: tasks, places: [home])
        XCTAssertEqual(regions.map(\.identifier), ["ncal.geo.place.home", "ncal.geo.task.b"])
        XCTAssertEqual(regions[0].name, "Home")
        XCTAssertEqual(regions[0].alerts.map(\.taskID), ["a", "c"])
        XCTAssertEqual(regions[1].name, "Post office")
        XCTAssertEqual(regions[1].center, point(51.6))
    }

    func testWatchesTheTwentyNearest() {
        let tasks = (0..<30).map { CalendarTask(id: "t\($0)", title: "\($0)", geofence: .point(point(Double($0) * 0.01))) }
        let candidates = GeofencePlan.candidates(tasks: tasks, places: [])
        // Standing by task 29, the far end of the list.
        let near = GeofencePlan.nearest(candidates, to: point(0.29))
        XCTAssertEqual(near.count, 20)
        XCTAssertEqual(near.first?.identifier, "ncal.geo.task.t29")
        XCTAssertEqual(Set(near.map(\.identifier)), Set((10..<30).map { "ncal.geo.task.t\($0)" }))
        // Unknown position: the first twenty, in list order.
        XCTAssertEqual(GeofencePlan.nearest(candidates, to: nil).map(\.identifier),
                       (0..<20).map { "ncal.geo.task.t\($0)" })
    }

    func testNearestByTheEdgeOfTheCircle() {
        let big = GeofenceRegion(identifier: "ncal.geo.task.big", center: point(0.02, radius: 2_000), name: "", alerts: [])
        let small = GeofenceRegion(identifier: "ncal.geo.task.small", center: point(0.015, radius: 100), name: "", alerts: [])
        // ~2.2 km to the big one's centre but inside its edge; ~1.7 km to the small one's.
        XCTAssertEqual(GeofencePlan.nearest([small, big], to: point(0), limit: 1).map(\.identifier), ["ncal.geo.task.big"])
    }

    func testOnlyChangedRegionsAreReregistered() {
        let keep = GeofenceRegion(identifier: "ncal.geo.task.keep", center: point(1), name: "", alerts: [])
        let moved = GeofenceRegion(identifier: "ncal.geo.task.moved", center: point(2), name: "", alerts: [])
        let new = GeofenceRegion(identifier: "ncal.geo.task.new", center: point(3), name: "", alerts: [])
        let monitored = [
            "ncal.geo.task.keep": point(1),
            "ncal.geo.task.moved": point(9),
            "ncal.geo.task.stale": point(4),
            "someone.else": point(5),
        ]
        let changes = GeofencePlan.changes(monitored: monitored, planned: [keep, moved, new])
        XCTAssertEqual(changes.remove, ["ncal.geo.task.moved", "ncal.geo.task.stale"])
        XCTAssertEqual(changes.add.map(\.identifier), ["ncal.geo.task.moved", "ncal.geo.task.new"])
    }

    func testRegionsRoundTripThroughTheStore() throws {
        let region = GeofenceRegion(identifier: "ncal.geo.place.home", center: home.point, name: "Home",
                                    alerts: [.init(taskID: "a", title: "Water plants")])
        let data = try JSONEncoder().encode([region])
        XCTAssertEqual(try JSONDecoder().decode([GeofenceRegion].self, from: data), [region])
    }
}

// MARK: - Nearby

final class NearbyTasksTests: XCTestCase {

    func testOpenTasksInRangeNearestFirst() {
        let here = GeoPoint(latitude: 0, longitude: 0)
        let shop = TaskPlace(id: "shop", name: "Shop", point: GeoPoint(latitude: 0.003, longitude: 0, radius: 100))
        let tasks = [
            CalendarTask(id: "far", title: "Far", geofence: .point(GeoPoint(latitude: 0.5, longitude: 0))),
            CalendarTask(id: "shop", title: "Milk", geofence: .place(id: "shop")),
            CalendarTask(id: "here", title: "Here", geofence: .point(GeoPoint(latitude: 0.0005, longitude: 0, radius: 150))),
            CalendarTask(id: "done", title: "Done", done: true, geofence: .place(id: "shop")),
            CalendarTask(id: "none", title: "Nowhere"),
            CalendarTask(id: "locked", title: "Undecryptable", geofence: .place(id: "locked")),
        ]
        let list = NearbyTasks.list(tasks, places: [shop], from: here, within: 2_000)
        XCTAssertEqual(list.map(\.task.id), ["here", "shop"])
        XCTAssertEqual(list[0].distance, 0, "inside the circle is here")
        XCTAssertEqual(list[1].distance, 233, accuracy: 2)
    }
}

// MARK: - PlacesService

@MainActor
final class PlacesServiceTests: XCTestCase {

    private var keys: VersionedKeys!
    private var service: PlacesService!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        let sodium = Sodium()
        let old = sodium.box.keyPair()!, current = sodium.box.keyPair()!
        keys = VersionedKeys(pairs: [1: (old.publicKey, old.secretKey), 2: (current.publicKey, current.secretKey)])
        service = makeService(keys: keys)
    }

    private func makeService(keys: VersionedKeys) -> PlacesService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CalendarAPIClient(session: URLSession(configuration: config),
                                       baseURL: { "https://example.test" }, token: { "tok" })
        return PlacesService(client: client, keys: keys)
    }

    private func record(_ id: String, _ name: String, version: Int) throws -> String {
        let pair = try XCTUnwrap(keys.pairs[version])
        let sealed = try PlaceEnvelope.seal(.init(name: name, lat: 1, lng: 2, radiusM: 150),
                                            publicKey: pair.publicKey, keyVersion: version)
        let quoted = String(decoding: try JSONEncoder().encode(sealed), as: UTF8.self)
        return #"{"id":"\#(id)","encryptedPayload":\#(quoted),"createdAt":"2026-10-01T00:00:00Z"}"#
    }

    func testLoadsAndDecryptsEveryKeyVersion() async throws {
        MockURLProtocol.respond(status: 200, body: #"{"places":[\#(try record("w", "Work", version: 2)),\#(try record("h", "home", version: 1))]}"#)
        await service.reload()
        XCTAssertEqual(service.places.map(\.name), ["home", "Work"], "sorted by name, ignoring case")
        XCTAssertEqual(service.unreadable, 0)
        XCTAssertTrue(service.hasLoaded)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/v1/calendar/task-places")
    }

    func testAPlaceThisDeviceCantOpenIsCountedNotShown() async throws {
        let body = #"{"places":[\#(try record("w", "Work", version: 2)),{"id":"x","encryptedPayload":"garbage"}]}"#
        MockURLProtocol.respond(status: 200, body: body)
        await service.reload()
        XCTAssertEqual(service.places.map(\.id), ["w"])
        XCTAssertEqual(service.unreadable, 1)
    }

    func testAPlaceSealedToAKeyVersionThisDeviceLacksIsUnreadable() async throws {
        MockURLProtocol.respond(status: 200, body: #"{"places":[\#(try record("h", "Home", version: 1))]}"#)
        let service = makeService(keys: VersionedKeys(pairs: [2: keys.pairs[2]!]))
        await service.reload()
        XCTAssertTrue(service.places.isEmpty)
        XCTAssertEqual(service.unreadable, 1)
    }

    func testAServerWithoutSavedPlacesIsNotAnError() async {
        MockURLProtocol.respond(status: 404, body: "")
        await service.reload()
        XCTAssertFalse(service.isSupported)
        XCTAssertTrue(service.hasLoaded)
        XCTAssertNil(service.error)
    }

    /// The server is sent ciphertext and nothing else.
    func testCreateSendsOnlyCiphertext() async throws {
        MockURLProtocol.respond(status: 201, body: #"{"id":"new","encryptedPayload":"x"}"#)
        let place = try await service.create(name: "Safeway on 5th", point: GeoPoint(latitude: 37.77, longitude: -122.41, radius: 200))
        XCTAssertEqual(place.id, "new")
        XCTAssertEqual(service.places.map(\.name), ["Safeway on 5th"])

        let body = try XCTUnwrap(MockURLProtocol.lastJSON)
        XCTAssertEqual(Set(body.keys), ["encryptedPayload"])
        let sealed = try XCTUnwrap(body["encryptedPayload"] as? String)
        XCTAssertFalse(sealed.contains("Safeway"))
        XCTAssertFalse(sealed.contains("37.77"))
        XCTAssertEqual(try PlaceEnvelope.keyVersion(of: sealed), 2, "sealed to the active version")
        let pair = try XCTUnwrap(keys.pairs[2])
        XCTAssertEqual(try PlaceEnvelope.open(sealed, publicKey: pair.publicKey, secretKey: pair.secretKey).name,
                       "Safeway on 5th")
    }

    func testNoKeyNoSave() async {
        let service = makeService(keys: VersionedKeys(pairs: [:]))
        XCTAssertFalse(service.canSave)
        do {
            _ = try await service.create(name: "Home", point: GeoPoint(latitude: 0, longitude: 0))
            XCTFail("saved without a key")
        } catch {
            XCTAssertEqual(error as? AttachmentError, .noKey)
        }
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testDelete() async throws {
        MockURLProtocol.respond(status: 200, body: #"{"places":[\#(try record("h", "Home", version: 2))]}"#)
        await service.reload()
        MockURLProtocol.respond(status: 204, body: "")
        try await service.delete(service.places[0])
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/v1/calendar/task-places/h")
        XCTAssertTrue(service.places.isEmpty)
    }

    func testSmartAddMatchesASavedPlaceByName() {
        let places = [
            TaskPlace(id: "1", name: "Home", point: GeoPoint(latitude: 0, longitude: 0)),
            TaskPlace(id: "2", name: "Safeway on 5th", point: GeoPoint(latitude: 0, longitude: 0)),
            TaskPlace(id: "3", name: "Café Zoë", point: GeoPoint(latitude: 0, longitude: 0)),
            TaskPlace(id: "4", name: "Homebase", point: GeoPoint(latitude: 0, longitude: 0)),
        ]
        XCTAssertEqual(PlacesService.match("home", in: places)?.id, "1", "an exact name beats a prefix")
        XCTAssertEqual(PlacesService.match("Safeway", in: places)?.id, "2", "the only place it starts")
        XCTAssertEqual(PlacesService.match("cafe_zoe", in: places)?.id, "3")
        XCTAssertNil(PlacesService.match("Hom", in: places), "two places start with it: no guess")
        XCTAssertNil(PlacesService.match("Target", in: places))
    }
}

// MARK: - TasksService

@MainActor
final class TaskGeofenceServiceTests: XCTestCase {

    private var service: TasksService!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        service = TasksService(client: CalendarAPIClient(session: URLSession(configuration: config),
                                                         baseURL: { "https://example.test" }, token: { "tok" }))
    }

    func testSmartAddCreatesWithTheSavedPlace() async throws {
        MockURLProtocol.respond(status: 201, body: #"{"id":"t","title":"Milk","location":"Home","geoPlaceId":"p1"}"#)
        var request = SmartAdd.request(for: SmartAdd.parse("Milk @Home"))
        request.geoPlaceId = "p1"
        let task = try await service.create(request)
        XCTAssertEqual(task.geofence, .place(id: "p1"))
        let body = try XCTUnwrap(MockURLProtocol.lastJSON)
        XCTAssertEqual(body["location"] as? String, "Home")
        XCTAssertEqual(body["geoPlaceId"] as? String, "p1")
        XCTAssertNil(body["geoLat"])
    }

    func testAttachingAPointAfterTheOffer() async throws {
        MockURLProtocol.respond(status: 200, body: #"[{"id":"t","title":"Milk"}]"#)
        await service.reload()
        MockURLProtocol.respond(status: 200, body: #"{"id":"t","title":"Milk","geoLat":1.5,"geoLng":2.5,"geoRadiusM":150}"#)
        let updated = try await service.setGeofence(service.tasks[0], .point(GeoPoint(latitude: 1.5, longitude: 2.5)))
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "PATCH")
        XCTAssertEqual(MockURLProtocol.lastJSON?["geoLat"] as? Double, 1.5)
        XCTAssertEqual(updated.geofence, .point(GeoPoint(latitude: 1.5, longitude: 2.5)))
    }

    func testForgettingAPlaceClearsItLocally() async {
        MockURLProtocol.respond(status: 200, body: #"[{"id":"a","title":"A","geoPlaceId":"p1"},{"id":"b","title":"B","geoPlaceId":"p2"}]"#)
        await service.reload()
        service.forgetPlace(id: "p1")
        XCTAssertNil(service.task(id: "a")?.geofence)
        XCTAssertEqual(service.task(id: "b")?.geofence, .place(id: "p2"))
    }
}
