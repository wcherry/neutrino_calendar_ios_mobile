import Foundation
import NeutrinoCrypto

// MARK: - TaskGeofence

/// Where a task reminds you: on arrival at one of your saved places, or at a one-off point.
///
/// The server keeps the two apart (`tasks.geo_place_id`, or `geo_lat` / `geo_lng` /
/// `geo_radius_m`), and a task uses one or the other. A saved place is end-to-end encrypted, so
/// only a device holding the account key knows where it is; a one-off point is plaintext on
/// purpose, as the ticket decided (wcherry/neutrino_calendar_ios_mobile#23).
enum TaskGeofence: Equatable, Hashable {
    case place(id: String)
    case point(GeoPoint)

    var placeID: String? {
        if case .place(let id) = self { return id }
        return nil
    }
}

/// A circle on the map: what iOS monitors and what a one-off geofence stores.
struct GeoPoint: Equatable, Hashable, Codable {
    var latitude: Double
    var longitude: Double
    /// Metres.
    var radius: Int

    /// iOS reports arrival unreliably below about 100 m, so nothing smaller is offered.
    static let minimumRadius = 100
    /// Big enough for a supermarket car park.
    static let defaultRadius = 150
    /// The radius picker's top end. A region larger than this is a neighbourhood, not a place.
    static let maximumRadius = 2_000

    init(latitude: Double, longitude: Double, radius: Int = GeoPoint.defaultRadius) {
        self.latitude = latitude
        self.longitude = longitude
        self.radius = GeoPoint.clamp(radius)
    }

    static func clamp(_ radius: Int) -> Int { min(max(radius, minimumRadius), maximumRadius) }

    /// Metres from here to `other` along the Earth's surface (haversine). Kept free of
    /// CoreLocation so the region planner and the Nearby filter test without it.
    func distance(to other: GeoPoint) -> Double {
        let r = 6_371_000.0
        let φ1 = latitude * .pi / 180, φ2 = other.latitude * .pi / 180
        let dφ = (other.latitude - latitude) * .pi / 180
        let dλ = (other.longitude - longitude) * .pi / 180
        let a = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}

// MARK: - TaskPlace

/// One of the user's saved places ("Home", "Work", "Safeway on 5th"), decrypted.
struct TaskPlace: Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    var point: GeoPoint
}

/// A saved place as the server holds it: an id and ciphertext. `TaskPlaceResponse` in
/// `neutrino/src/calendar/task_places/dto.rs`.
struct TaskPlaceRecord: Decodable, Equatable {
    let id: String
    let encryptedPayload: String
}

/// `GET /api/v1/calendar/task-places`.
struct TaskPlacesResponse: Decodable {
    let places: [TaskPlaceRecord]
}

/// The body of a create or an update: the server never sees anything else.
struct SaveTaskPlaceRequest: Encodable, Equatable {
    let encryptedPayload: String
}

// MARK: - PlaceEnvelope

/// The field-level envelope a saved place travels in. The first end-to-end encrypted data in
/// Calendar, and built only from primitives every client already shares with Drive, so the web
/// needs no new cryptography to read it:
///
/// ```
/// encryptedPayload = JSON { "v": 1, "keyVersion": <int>, "key": <sealed DEK>, "data": <ciphertext> }
///   key  = crypto_box_seal(DEK, account public key), base64url without padding
///          (web: encryptFileKey · Swift: DriveFileCrypto.seal)
///   data = one secretstream push of the JSON payload with the DEK, base64url without padding
///          (web: encryptMetadata · Swift: DriveFileCrypto.encrypt)
/// payload        = JSON { "name": String, "lat": Double, "lng": Double, "radiusM": Int }
/// ```
///
/// A fresh 32-byte DEK per write, sealed to the active keyring version, which the envelope names
/// so a place saved before a key rotation still opens. Fields a later version adds to the payload
/// are ignored, not rejected; a different `v` is.
///
/// The spec, and the fixture both sides test against, are in `agent_docs/task-geofencing.md` and
/// `NeutrinoCalendarTests/Fixtures/place_envelope_vectors.json`. Changing this is a wire-format
/// change across the web, this app and the server.
enum PlaceEnvelope {
    static let version = 1

    struct Payload: Codable, Equatable {
        var name: String
        var lat: Double
        var lng: Double
        var radiusM: Int
    }

    private struct Envelope: Codable {
        let v: Int
        let keyVersion: Int
        let key: String
        let data: String
    }

    enum Failure: LocalizedError, Equatable {
        case malformed
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .malformed:
                return "A saved place is damaged and can't be read."
            case .unsupportedVersion:
                return "A saved place was written by a newer version of Neutrino. Update Calendar to read it."
            }
        }
    }

    static func seal(_ payload: Payload, publicKey: [UInt8], keyVersion: Int) throws -> String {
        let dek = DriveFileCrypto.newDEK()
        let json = try JSONEncoder.sorted.encode(payload)
        let envelope = Envelope(v: version, keyVersion: keyVersion,
                                key: try DriveFileCrypto.seal(dek: dek, toPublicKey: publicKey),
                                data: Base64URL.encode([UInt8](try DriveFileCrypto.encrypt(json, dek: dek))))
        return String(decoding: try JSONEncoder.sorted.encode(envelope), as: UTF8.self)
    }

    /// The key version `encrypted` was sealed to, so the caller can find that keypair.
    static func keyVersion(of encrypted: String) throws -> Int {
        try envelope(encrypted).keyVersion
    }

    static func open(_ encrypted: String, publicKey: [UInt8], secretKey: [UInt8]) throws -> Payload {
        let envelope = try envelope(encrypted)
        let dek = try DriveFileCrypto.openDEK(envelope.key, publicKey: publicKey, secretKey: secretKey)
        guard let data = Base64URL.decode(envelope.data) else { throw Failure.malformed }
        let json = try DriveFileCrypto.decrypt(Data(data), dek: dek)
        guard let payload = try? JSONDecoder().decode(Payload.self, from: json) else { throw Failure.malformed }
        return payload
    }

    private static func envelope(_ encrypted: String) throws -> Envelope {
        guard let data = encrypted.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformed
        }
        // Checked before decoding the rest: a later version may change the other fields.
        guard let v = object["v"] as? Int else { throw Failure.malformed }
        guard v == version else { throw Failure.unsupportedVersion(v) }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { throw Failure.malformed }
        return envelope
    }
}

extension TaskPlace {
    init(id: String, payload: PlaceEnvelope.Payload) {
        self.init(id: id, name: payload.name,
                  point: GeoPoint(latitude: payload.lat, longitude: payload.lng, radius: payload.radiusM))
    }

    var payload: PlaceEnvelope.Payload {
        PlaceEnvelope.Payload(name: name, lat: point.latitude, lng: point.longitude, radiusM: point.radius)
    }
}

private extension JSONEncoder {
    /// Sorted keys, so the same value always encodes the same way; the tests compare bytes.
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
