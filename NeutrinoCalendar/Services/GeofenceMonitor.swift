import Combine
import CoreLocation
import Foundation
import UserNotifications
import os.log

/// Arrival alerts for tasks: watches up to 20 regions with `CLLocationManager` and posts a local
/// notification when you enter one. Nothing is sent to the server; it never learns where you are.
///
/// * **What is watched** is `GeofencePlan`'s answer for the open tasks and the saved places. It
///   is re-picked when either list changes (a sync, a task completed or deleted, a place
///   deleted) and, with more regions than iOS allows, as you move: significant location changes
///   wake the app to re-pick the 20 nearest.
/// * **Launched by iOS.** An arrival can relaunch an app that was terminated, with nothing
///   loaded. So the candidate regions, with their task titles, are kept in a file, and the
///   manager's delegate is set during launch (`AppServices`).
/// * **Permission** is asked in context: When In Use the first time a place is picked or Nearby
///   is turned on, then Always once a task has a geofence, since iOS only reports arrivals in the
///   background with Always.
@MainActor
final class GeofenceMonitor: NSObject, ObservableObject {

    @Published private(set) var authorization: CLAuthorizationStatus
    /// The device's last known position, for Nearby and for picking the nearest regions.
    @Published private(set) var location: GeoPoint?
    /// The regions being watched, nearest first.
    @Published private(set) var watched: [GeofenceRegion] = []

    weak var tasks: TasksService?
    weak var places: PlacesService?

    static let notificationCategory = "TASK_ARRIVAL"
    static let notificationPrefix = "arrival."

    private let manager = CLLocationManager()
    private let storeURL: URL
    /// Every region an open task needs; `watched` is the nearest of these.
    private var candidates: [GeofenceRegion] = []
    private var cancellables: Set<AnyCancellable> = []
    private var locationWaiters: [CheckedContinuation<GeoPoint?, Never>] = []
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoCalendar",
                                category: "GeofenceMonitor")

    init(storeURL: URL = GeofenceMonitor.defaultStoreURL) {
        self.storeURL = storeURL
        authorization = manager.authorizationStatus
        super.init()
    }

    nonisolated static var defaultStoreURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("geofences.json")
    }

    /// Must run during launch: an arrival can be what launched the app.
    func configure() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        candidates = load()
        location = manager.location.map(GeoPoint.init)
        logger.debug("configured with \(self.candidates.count) candidate region(s)")
    }

    /// Re-plans whenever the tasks or the places change, once both have loaded: before that an
    /// empty list means "not loaded yet", and planning from it would stop every alert.
    func observe(tasks: TasksService, places: PlacesService) {
        self.tasks = tasks
        self.places = places
        Publishers.CombineLatest(tasks.$tasks, places.$places)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] tasks, places in
                guard let self, self.tasks?.hasLoaded == true, self.places?.hasLoaded == true else { return }
                self.replan(tasks: tasks, places: places)
            }
            .store(in: &cancellables)
    }

    // MARK: - Permission

    /// Whether arrivals can be reported at all: Always, and hardware that monitors regions.
    var canAlert: Bool {
        authorization == .authorizedAlways && CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
    }

    /// Why arrival alerts aren't working, in words for the task editor; nil when they are.
    var inactiveReason: String? {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            return "This device can't watch for arrivals."
        }
        switch authorization {
        case .authorizedAlways:
            return nil
        case .authorizedWhenInUse:
            return "Arrival alerts need location access set to Always. The task is saved either way."
        case .denied, .restricted:
            return "Location access is off for Calendar, so this place won't alert you. The task is saved either way."
        default:
            return "Calendar will ask for your location so it can alert you on arrival."
        }
    }

    /// For the place picker and Nearby: enough to know where you are while the app is open.
    func requestWhenInUse() {
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    /// For a task with a geofence. iOS shows the upgrade to Always once; after that, Settings.
    func requestAlways() {
        switch authorization {
        case .notDetermined, .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    /// The device's position now, or nil if it can't be had. One fix, not a stream.
    func currentLocation() async -> GeoPoint? {
        guard authorization == .authorizedAlways || authorization == .authorizedWhenInUse else { return location }
        return await withCheckedContinuation { continuation in
            locationWaiters.append(continuation)
            if locationWaiters.count == 1 { manager.requestLocation() }
        }
    }

    // MARK: - Planning

    func replan(tasks: [CalendarTask], places: [TaskPlace]) {
        candidates = GeofencePlan.candidates(tasks: tasks, places: places)
        save(candidates)
        apply()
    }

    /// Hands iOS the nearest regions. With more candidates than iOS allows, significant location
    /// changes are watched too, so the set follows you; otherwise they would only cost battery.
    private func apply() {
        guard canAlert else {
            stopMonitoringAll()
            return
        }
        let planned = GeofencePlan.nearest(candidates, to: location)
        let monitored = Dictionary(manager.monitoredRegions.compactMap { region -> (String, GeoPoint)? in
            guard let circle = region as? CLCircularRegion else { return nil }
            return (circle.identifier, GeoPoint(latitude: circle.center.latitude, longitude: circle.center.longitude,
                                                radius: Int(circle.radius.rounded())))
        }, uniquingKeysWith: { first, _ in first })
        let changes = GeofencePlan.changes(monitored: monitored, planned: planned)
        for id in changes.remove {
            if let region = manager.monitoredRegions.first(where: { $0.identifier == id }) {
                manager.stopMonitoring(for: region)
            }
        }
        for region in changes.add {
            let circle = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: region.center.latitude, longitude: region.center.longitude),
                radius: min(CLLocationDistance(region.center.radius), manager.maximumRegionMonitoringDistance),
                identifier: region.identifier)
            circle.notifyOnEntry = true
            circle.notifyOnExit = false
            manager.startMonitoring(for: circle)
        }
        watched = planned
        if candidates.count > GeofencePlan.regionLimit {
            manager.startMonitoringSignificantLocationChanges()
        } else {
            manager.stopMonitoringSignificantLocationChanges()
        }
        logger.debug("watching \(planned.count) of \(self.candidates.count): +\(changes.add.count) −\(changes.remove.count)")
    }

    /// Sign-out: the next account must not be alerted at this one's places.
    func stop() {
        candidates = []
        watched = []
        try? FileManager.default.removeItem(at: storeURL)
        stopMonitoringAll()
    }

    private func stopMonitoringAll() {
        for region in manager.monitoredRegions where region.identifier.hasPrefix(GeofencePlan.regionPrefix) {
            manager.stopMonitoring(for: region)
        }
        manager.stopMonitoringSignificantLocationChanges()
        watched = []
    }

    // MARK: - Arrival

    /// One notification per open task at the place. iOS reports an entry once per arrival, so
    /// it fires once until you leave and come back; completing the task takes it out of the plan.
    private func arrived(at identifier: String) async {
        guard let region = candidates.first(where: { $0.identifier == identifier }) else { return }
        guard UserDefaults.standard.object(forKey: ReminderNotifications.enabledKey) as? Bool ?? true else { return }
        let center = UNUserNotificationCenter.current()
        for alert in region.alerts {
            // A task completed here since the plan was saved is skipped, even before a re-plan.
            if let task = tasks?.task(id: alert.taskID), task.done { continue }
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = "You're at \(region.name)"
            content.sound = .default
            content.categoryIdentifier = Self.notificationCategory
            content.userInfo = ["taskID": alert.taskID]
            content.threadIdentifier = "arrivals"
            let request = UNNotificationRequest(identifier: "\(Self.notificationPrefix)\(alert.taskID)",
                                                content: content, trigger: nil)
            do {
                try await center.add(request)
            } catch {
                logger.error("could not post arrival for \(alert.taskID, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Store

    /// Kept beside the app's other data, protected until the device is first unlocked: an
    /// arrival can relaunch the app while the phone is locked in a pocket.
    private func save(_ regions: [GeofenceRegion]) {
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(regions).write(to: storeURL,
                                                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            logger.error("could not save the plan: \(error, privacy: .public)")
        }
    }

    private func load() -> [GeofenceRegion] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        return (try? JSONDecoder().decode([GeofenceRegion].self, from: data)) ?? []
    }

    private func resolveLocationWaiters(_ point: GeoPoint?) {
        let waiters = locationWaiters
        locationWaiters = []
        waiters.forEach { $0.resume(returning: point) }
    }
}

// MARK: - CLLocationManagerDelegate

extension GeofenceMonitor: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status != .authorizedAlways && status != .authorizedWhenInUse { self.resolveLocationWaiters(nil) }
            self.apply()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let point = GeoPoint(last)
        Task { @MainActor in
            self.location = point
            self.resolveLocationWaiters(point)
            // A significant change: with more places than iOS can watch, the nearest have moved.
            if self.candidates.count > GeofencePlan.regionLimit { self.apply() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.logger.error("location failed: \(error, privacy: .public)")
            self.resolveLocationWaiters(self.location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let identifier = region.identifier
        guard identifier.hasPrefix(GeofencePlan.regionPrefix) else { return }
        Task { @MainActor in await self.arrived(at: identifier) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?,
                                     withError error: Error) {
        let identifier = region?.identifier ?? "?"
        Task { @MainActor in
            self.logger.error("monitoring \(identifier, privacy: .public) failed: \(error, privacy: .public)")
        }
    }
}

private extension GeoPoint {
    init(_ location: CLLocation) {
        self.init(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                  radius: GeoPoint.minimumRadius)
    }
}
