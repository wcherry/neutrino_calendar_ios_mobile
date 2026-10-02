import Foundation
import os.log

/// The user's calendars: what decides which events are drawn, in which colour, and which can be
/// changed. Includes holiday calendars, whose days `HolidayEngine` computes.
///
/// Calendars aren't in the events changes feed, so the list is fetched again on launch, on
/// coming to the foreground and after every sync (`CalendarSync`). There are only a few. The last
/// list is kept on disk, so colours, hidden calendars and holidays hold with no network.
@MainActor
final class CalendarsService: ObservableObject {

    /// Default first, then the server's order.
    @Published private(set) var calendars: [UserCalendar]
    @Published private(set) var hasLoaded = false
    @Published var error: String?

    private let client: CalendarAPIClient
    private let cacheURL: URL
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoCalendar",
                                category: "CalendarsService")

    init(client: CalendarAPIClient, cacheURL: URL = CalendarsService.defaultCacheURL) {
        self.client = client
        self.cacheURL = cacheURL
        calendars = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode([UserCalendar].self, from: $0) } ?? []
    }

    nonisolated static var defaultCacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("calendars.json")
    }

    var rules: CalendarRules { CalendarRules(calendars) }
    var defaultCalendar: UserCalendar? { calendars.first(where: \.isDefault) ?? writable.first }
    var writable: [UserCalendar] { CalendarRules.writable(calendars) }
    var holidayCalendars: [UserCalendar] { calendars.filter { $0.kind == .holidays } }
    /// Everything but holidays, which Settings lists in a section of their own.
    var ownCalendars: [UserCalendar] { calendars.filter { $0.kind != .holidays } }

    func calendar(id: String?) -> UserCalendar? { id.flatMap { id in calendars.first { $0.id == id } } }

    // MARK: - Loading

    func reload() async {
        do {
            set(try await client.calendars())
            hasLoaded = true
            error = nil
        } catch let error as CalendarAPIError where error.isNotFound {
            // A server older than calendars: everything is in one calendar it doesn't name.
            set([])
            hasLoaded = true
        } catch {
            logger.error("reload failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    /// Sign-out: the next account must not see this one's calendars.
    func reset() {
        calendars = []
        hasLoaded = false
        error = nil
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: - Changes

    @discardableResult
    func create(_ request: CreateCalendarRequest) async throws -> UserCalendar {
        let created = try await client.createCalendar(request)
        set(calendars + [created])
        return created
    }

    /// Shows or hides a calendar at once, and puts it back if the server refuses.
    func setVisible(_ calendar: UserCalendar, _ visible: Bool) async {
        guard calendar.visible != visible else { return }
        var changed = calendar
        changed.visible = visible
        replace(changed)
        do {
            replace(try await client.updateCalendar(id: calendar.id, UpdateCalendarRequest(visible: visible)))
        } catch {
            logger.error("setVisible failed: \(error, privacy: .public)")
            replace(calendar)
            self.error = "Couldn't \(visible ? "show" : "hide") \(calendar.name). \(error.localizedDescription)"
        }
    }

    /// Name, colour, and a holiday calendar's region and observances: what changed is sent.
    @discardableResult
    func update(_ calendar: UserCalendar, to edited: UserCalendar) async throws -> UserCalendar {
        var request = UpdateCalendarRequest()
        if edited.name != calendar.name { request.name = edited.name }
        if edited.color.lowercased() != calendar.color.lowercased() { request.color = edited.color }
        if edited.region != calendar.region { request.region = edited.region ?? "" }
        if edited.includeObservances != calendar.includeObservances { request.includeObservances = edited.includeObservances }
        guard request != UpdateCalendarRequest() else { return calendar }
        let updated = try await client.updateCalendar(id: calendar.id, request)
        replace(updated)
        return updated
    }

    /// Deletes the calendar and every event in it. The caller reloads the events.
    func delete(_ calendar: UserCalendar) async throws {
        try await client.deleteCalendar(id: calendar.id)
        set(calendars.filter { $0.id != calendar.id })
    }

    // MARK: - Helpers

    private func replace(_ calendar: UserCalendar) {
        set(calendars.map { $0.id == calendar.id ? calendar : $0 })
    }

    private func set(_ list: [UserCalendar]) {
        // The default first, as the server sends it; kept so after a local change too.
        calendars = list.filter(\.isDefault) + list.filter { !$0.isDefault }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(calendars).write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            logger.error("cache write failed: \(error, privacy: .public)")
        }
    }
}
