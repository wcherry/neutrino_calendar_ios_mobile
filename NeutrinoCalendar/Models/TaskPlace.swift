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

// The envelope a saved place travels in is `PlaceEnvelope` in NeutrinoCrypto
// (neutrino_shared_ios), shared by every app that reads places and tested there against the
// vectors the web also opens.

extension TaskPlace {
    init(id: String, payload: PlaceEnvelope.Payload) {
        self.init(id: id, name: payload.name,
                  point: GeoPoint(latitude: payload.lat, longitude: payload.lng, radius: payload.radiusM))
    }

    var payload: PlaceEnvelope.Payload {
        PlaceEnvelope.Payload(name: name, lat: point.latitude, lng: point.longitude, radiusM: point.radius)
    }
}
