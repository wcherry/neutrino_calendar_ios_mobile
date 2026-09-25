import Foundation
import os.log

// MARK: - DaySection

/// One day of the agenda and every occurrence on it, multi-day events included on each of their
/// days.
struct DaySection: Identifiable, Equatable {
    let day: Date
    let occurrences: [EventOccurrence]

    var id: Date { day }
}

// MARK: - EventsService

/// Loads events a month at a time, expands the recurring ones, and answers "what is on this day"
/// for every view.
///
/// The month is the unit because it is the web's: `monthRange` in `calendarHelpers.ts` asks for
/// local midnight on the 1st through 23:59:59 on the last day, and expands over the same span.
/// Asking for the same ranges is what keeps an occurrence near a month boundary on the same side
/// of it in both clients. A week that crosses a month end simply loads both months; each day is
/// answered from its own month's load, which the server fills with every event overlapping it.
@MainActor
final class EventsService: ObservableObject {

    /// The day the views are centred on: the selected day in month view, the day in day view, a
    /// day of the week in week view. Always a local midnight.
    @Published private(set) var focus: Date
    /// Occurrences by the first of the month they were loaded for.
    @Published private(set) var byMonth: [Date: [EventOccurrence]] = [:]
    @Published private(set) var loadingMonths: Set<Date> = []
    @Published var error: String?
    /// Bumped whenever the cache is thrown away, so a view that loads on change of it loads again.
    @Published private(set) var generation = 0

    private let client: CalendarAPIClient
    /// The day weeks start on. Set from Settings; every grid reads it through `calendar`.
    @Published private(set) var weekStart: WeekStart
    private let baseCalendar: Calendar
    private let now: () -> Date

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoCalendar",
                                category: "EventsService")

    init(client: CalendarAPIClient, calendar: Calendar = .current, weekStart: WeekStart = .stored,
         now: @escaping () -> Date = Date.init) {
        self.client = client
        self.baseCalendar = calendar
        self.weekStart = weekStart
        self.now = now
        self.focus = calendar.startOfDay(for: now())
    }

    // MARK: - Queries

    /// The device's calendar with the chosen first weekday, rather than the region's.
    var calendar: Calendar {
        var calendar = baseCalendar
        calendar.firstWeekday = weekStart.firstWeekday
        return calendar
    }

    func setWeekStart(_ weekStart: WeekStart) {
        self.weekStart = weekStart
    }

    var today: Date { calendar.startOfDay(for: now()) }

    /// The first of the focused month.
    var month: Date { Self.firstOfMonth(focus, calendar: calendar) }

    var isLoading: Bool { !loadingMonths.isEmpty }

    func hasLoaded(_ month: Date) -> Bool { byMonth[month] != nil }

    /// The agenda: the focused month's days that have occurrences.
    var sections: [DaySection] {
        Self.layout(byMonth[month] ?? [], in: month, calendar: calendar)
    }

    /// Everything on `day`, all-day first, then by start, then by title. Empty until the day's
    /// month has loaded.
    func occurrences(on day: Date) -> [EventOccurrence] {
        let month = Self.firstOfMonth(day, calendar: calendar)
        return (byMonth[month] ?? [])
            .filter { EventDayRange($0, calendar: calendar).contains(day: day, calendar: calendar) }
            .sorted(by: Self.dayOrder)
    }

    /// The days `mode` shows around the focus, which decides what has to be loaded.
    func visibleDays(for mode: CalendarMode) -> [Date] {
        switch mode {
        case .day:    return [focus]
        case .week:   return CalendarGrid.weekDays(containing: focus, calendar: calendar)
        case .month:  return CalendarGrid.monthDays(focus, calendar: calendar)
        case .agenda: return [month]
        case .year:   return []
        }
    }

    /// The months `mode` needs. The month grid shows its neighbours' days greyed and without
    /// events, as the iPhone's Calendar does, so it needs only its own month.
    func months(for mode: CalendarMode) -> [Date] {
        mode == .month ? [month] : CalendarGrid.months(covering: visibleDays(for: mode), calendar: calendar)
    }

    // MARK: - Navigation

    /// Steps by the mode's unit. A step of a month or a year lands on the 1st, or on today when
    /// it arrives in today's month, as the iPhone's Calendar does; a day or week keeps the weekday.
    func move(_ mode: CalendarMode, by steps: Int) {
        let moved = calendar.date(byAdding: mode.step, value: steps, to: focus)!
        switch mode.step {
        case .month, .year:
            let first = Self.firstOfMonth(moved, calendar: calendar)
            focus = first == Self.firstOfMonth(today, calendar: calendar) ? today : first
        default:
            focus = calendar.startOfDay(for: moved)
        }
    }

    func goToToday() { focus = today }

    func select(_ day: Date) { focus = calendar.startOfDay(for: day) }

    /// Whether `mode` already shows today, which is when the Today button has nothing to do.
    func isShowingToday(_ mode: CalendarMode) -> Bool {
        switch mode {
        case .day:            return focus == today
        case .week:           return visibleDays(for: .week).contains(today)
        case .month, .agenda: return focus == today
        case .year:           return calendar.isDate(focus, equalTo: today, toGranularity: .year)
        }
    }

    // MARK: - Loading

    /// Loads whichever of `mode`'s months are not loaded yet.
    func ensureLoaded(for mode: CalendarMode) async {
        for month in months(for: mode) where byMonth[month] == nil && !loadingMonths.contains(month) {
            await load(month)
        }
    }

    /// Loads `mode`'s months again, for pull-to-refresh.
    func reload(for mode: CalendarMode) async {
        for month in months(for: mode) { await load(month) }
    }

    /// Drops every loaded month, for after a change made elsewhere in the app, such as a task put
    /// on the calendar: the event may be in any month, and the cache must not keep a stale copy of
    /// one that is not on screen. The calendar reloads what it shows the next time it appears.
    func invalidate() {
        byMonth = [:]
        generation += 1
    }

    private func load(_ month: Date) async {
        let range = Self.monthRange(month, calendar: calendar)
        loadingMonths.insert(month)
        error = nil
        defer { loadingMonths.remove(month) }
        do {
            let events = try await client.events(from: range.from, to: range.to)
            byMonth[month] = RecurrenceExpander.expand(events, from: range.from, to: range.to,
                                                       calendar: calendar)
            logger.debug("loaded \(events.count) event(s) for a month")
        } catch {
            logger.error("load failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    /// Forgets everything loaded, for sign-out: the next account must never see this one's events.
    func reset() {
        byMonth = [:]
        loadingMonths = []
        error = nil
        focus = today
    }

    // MARK: - Changes

    /// Each change throws the cache away, so every view reloads what it shows: an event can move
    /// to any month, and a repeating one reaches every month.
    @discardableResult
    func create(_ draft: EventDraft) async throws -> CalendarEvent {
        let created = try await client.createEvent(draft.createRequest())
        invalidate()
        return created
    }

    /// Saves what changed between `original` and `draft`; returns the event unchanged when
    /// nothing did.
    @discardableResult
    func update(_ event: CalendarEvent, from original: EventDraft, to draft: EventDraft) async throws -> CalendarEvent {
        let request = draft.updateRequest(from: original)
        guard request != UpdateEventRequest() else { return event }
        let updated = try await client.updateEvent(id: event.id, request)
        invalidate()
        return updated
    }

    func delete(_ event: CalendarEvent) async throws {
        try await client.deleteEvent(id: event.id)
        invalidate()
    }

    func attachments(for event: CalendarEvent) async throws -> [EventAttachment] {
        try await client.attachments(forEvent: event.id)
    }

    // MARK: - Layout

    static func firstOfMonth(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
    }

    /// The web's `monthRange`: local midnight on the 1st through 23:59:59 on the last day.
    static func monthRange(_ month: Date, calendar: Calendar) -> (from: Date, to: Date) {
        let first = firstOfMonth(month, calendar: calendar)
        let next = calendar.date(byAdding: .month, value: 1, to: first)!
        let lastDay = calendar.date(byAdding: .day, value: -1, to: next)!
        let to = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: lastDay)!
        return (first, to)
    }

    /// All-day first, then by start, then by title, so a list that refreshes does not reshuffle
    /// events that share a start time.
    static func dayOrder(_ a: EventOccurrence, _ b: EventOccurrence) -> Bool {
        if a.event.allDay != b.event.allDay { return a.event.allDay }
        if a.start != b.start { return a.start < b.start }
        return a.event.title.localizedStandardCompare(b.event.title) == .orderedAscending
    }

    /// Every day of `month` with its occurrences, empty days dropped: the web's `AgendaView` over
    /// the month's own days.
    static func layout(_ occurrences: [EventOccurrence], in month: Date,
                       calendar: Calendar) -> [DaySection] {
        let ranges = occurrences.map { ($0, EventDayRange($0, calendar: calendar)) }
        let first = firstOfMonth(month, calendar: calendar)
        let dayCount = calendar.range(of: .day, in: .month, for: first)!.count

        return (0..<dayCount).compactMap { offset -> DaySection? in
            let day = calendar.date(byAdding: .day, value: offset, to: first)!
            let onDay = ranges
                .filter { $0.1.contains(day: day, calendar: calendar) }
                .map(\.0)
                .sorted(by: dayOrder)
            return onDay.isEmpty ? nil : DaySection(day: day, occurrences: onDay)
        }
    }
}
