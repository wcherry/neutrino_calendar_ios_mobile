import Foundation

// MARK: - GeofenceRegion

/// One circle the app may ask iOS to watch, and the open tasks that remind you there.
///
/// Every task at a saved place shares that place's region, so "Home" costs one of the 20 regions
/// iOS allows however many tasks use it. A one-off point is a region of its own.
struct GeofenceRegion: Equatable, Codable {
    /// `CLRegion.identifier`. Stable across launches, so a region already watched is left alone.
    let identifier: String
    let center: GeoPoint
    /// What the arrival alert says you reached: the place's name, or the task's location text.
    let name: String
    let alerts: [Alert]

    struct Alert: Equatable, Codable {
        let taskID: String
        let title: String
    }
}

// MARK: - GeofencePlan

/// Which geofences the device watches. No CoreLocation, so it tests on its own; the
/// `GeofenceMonitor` hands the result to iOS.
enum GeofencePlan {
    /// iOS monitors at most 20 regions per app, and this app watches nothing else.
    static let regionLimit = 20
    /// Prefixes every region this app registers, so nothing else's is ever removed.
    static let regionPrefix = "ncal.geo."

    static func identifier(placeID: String) -> String { "\(regionPrefix)place.\(placeID)" }
    static func identifier(taskID: String) -> String { "\(regionPrefix)task.\(taskID)" }

    /// Every region an open, geofenced task needs, in the order the tasks are listed. A task at a
    /// saved place that `places` doesn't hold (deleted, or not decryptable on this device) has
    /// nowhere to be watched and is left out.
    static func candidates(tasks: [CalendarTask], places: [TaskPlace]) -> [GeofenceRegion] {
        let placesByID = Dictionary(places.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var order: [String] = []
        var regions: [String: (center: GeoPoint, name: String, alerts: [GeofenceRegion.Alert])] = [:]
        for task in tasks where !task.done {
            let id: String, center: GeoPoint, name: String
            switch task.geofence {
            case .place(let placeID)?:
                guard let place = placesByID[placeID] else { continue }
                (id, center, name) = (identifier(placeID: placeID), place.point, place.name)
            case .point(let point)?:
                (id, center, name) = (identifier(taskID: task.id), point, task.location ?? "this place")
            case nil:
                continue
            }
            let alert = GeofenceRegion.Alert(taskID: task.id, title: task.title)
            if regions[id] == nil {
                order.append(id)
                regions[id] = (center, name, [alert])
            } else {
                regions[id]?.alerts.append(alert)
            }
        }
        return order.map { id in
            let r = regions[id]!
            return GeofenceRegion(identifier: id, center: r.center, name: r.name, alerts: r.alerts)
        }
    }

    /// The `limit` regions to watch: the nearest to `location`, or the first ones listed while
    /// the device's location isn't known. Nearest by the edge of the circle, not its centre, so a
    /// large region you are almost inside isn't dropped for a small one further off.
    static func nearest(_ candidates: [GeofenceRegion], to location: GeoPoint?,
                        limit: Int = regionLimit) -> [GeofenceRegion] {
        guard let location, candidates.count > limit else { return Array(candidates.prefix(limit)) }
        return candidates.enumerated()
            .map { (offset: $0.offset, region: $0.element,
                    distance: location.distance(to: $0.element.center) - Double($0.element.center.radius)) }
            .sorted { ($0.distance, $0.offset) < ($1.distance, $1.offset) }
            .prefix(limit)
            .map(\.region)
    }

    /// What to tell iOS: the regions to stop watching, and those to start. A region whose circle
    /// moved is replaced; one whose tasks merely changed stays, since the alert is read from the
    /// plan when it fires.
    static func changes(monitored: [String: GeoPoint], planned: [GeofenceRegion])
        -> (remove: [String], add: [GeofenceRegion]) {
        let plannedIDs = Set(planned.map(\.identifier))
        let remove = monitored.keys
            .filter { $0.hasPrefix(regionPrefix) }
            .filter { id in !plannedIDs.contains(id) || planned.first { $0.identifier == id }?.center != monitored[id] }
            .sorted()
        let add = planned.filter { monitored[$0.identifier] != $0.center }
        return (remove, add)
    }
}

// MARK: - Nearby

/// The Tasks tab's Nearby filter: open tasks with a geofence within `range` of you, nearest
/// first. On the device, because the server can't read where a saved place is.
enum NearbyTasks {
    enum Range: Int, CaseIterable, Identifiable {
        case walk = 500, neighborhood = 2_000, town = 10_000

        var id: Int { rawValue }
        var meters: Double { Double(rawValue) }

        var title: String {
            switch self {
            case .walk:         return "Within 500 m"
            case .neighborhood: return "Within 2 km"
            case .town:         return "Within 10 km"
            }
        }
    }

    struct Entry: Equatable {
        let task: CalendarTask
        /// Metres to the edge of the task's region; 0 inside it.
        let distance: Double
    }

    static func list(_ tasks: [CalendarTask], places: [TaskPlace], from location: GeoPoint,
                     within range: Double) -> [Entry] {
        let placesByID = Dictionary(places.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return tasks.enumerated()
            .compactMap { offset, task -> (Int, Entry)? in
                guard !task.done, let center = center(of: task, places: placesByID) else { return nil }
                let distance = max(0, location.distance(to: center) - Double(center.radius))
                guard distance <= range else { return nil }
                return (offset, Entry(task: task, distance: distance))
            }
            .sorted { ($0.1.distance, $0.0) < ($1.1.distance, $1.0) }
            .map(\.1)
    }

    static func center(of task: CalendarTask, places: [String: TaskPlace]) -> GeoPoint? {
        switch task.geofence {
        case .place(let id)?:     return places[id]?.point
        case .point(let point)?:  return point
        case nil:                 return nil
        }
    }

    /// "Here", "350 m", "1.2 km".
    static func format(_ meters: Double) -> String {
        if meters < 1 { return "Here" }
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        return measurement.formatted(.measurement(width: .abbreviated, usage: .road,
                                                  numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }
}
