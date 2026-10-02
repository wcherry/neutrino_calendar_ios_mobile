import Foundation
import MapKit

/// A place found by searching the map: what the picker lists and what Smart Add offers for an
/// `@Safeway` that names no saved place.
struct PlaceSearchResult: Identifiable, Equatable {
    let id = UUID()
    let name: String
    /// The address, or empty.
    let detail: String
    let point: GeoPoint

    static func == (a: PlaceSearchResult, b: PlaceSearchResult) -> Bool {
        a.name == b.name && a.detail == b.detail && a.point == b.point
    }
}

/// MapKit's local search. Apple's, not Neutrino's: the query goes to Apple, as it does when you
/// search in Maps, and nothing about it reaches the Neutrino server.
enum PlaceSearch {

    /// Results for `query`, those near `location` first when it is known.
    static func search(_ query: String, near location: GeoPoint?) async throws -> [PlaceSearchResult] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.pointOfInterest, .address]
        if let location {
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude),
                latitudinalMeters: 20_000, longitudinalMeters: 20_000)
        }
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.map { item in
            let coordinate = item.placemark.coordinate
            return PlaceSearchResult(name: item.name ?? text,
                                     detail: address(of: item.placemark),
                                     point: GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }
    }

    /// "123 Main St, Springfield": street and town, without the country.
    private static func address(of placemark: MKPlacemark) -> String {
        let street = [placemark.subThoroughfare, placemark.thoroughfare].compactMap { $0 }.joined(separator: " ")
        return [street, placemark.locality ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
