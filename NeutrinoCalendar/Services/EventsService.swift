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

/// Loads a month of events, expands the recurring ones, and lays them out by day.
///
/// The month is the unit because it is the web's: `monthRange` in `calendarHelpers.ts` asks for
/// local midnight on the 1st through 23:59:59 on the last day, and expands over the same span. Asking
/// for the same range is what keeps an occurrence near a month boundary on the same side of it in
/// both clients.
@MainActor
final class EventsService: ObservableObject {

    /// Midnight on the first of the month being shown.
    @Published private(set) var month: Date
    /// Days of `month` that have at least one occurrence, in order.
    @Published private(set) var sections: [DaySection] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

    private let client: CalendarAPIClient
    private let calendar: Calendar
    private let now: () -> Date
    /// Which month the newest request was for, so a slow response for a month the user has
    /// already paged past is dropped instead of overwriting the one on screen.
    private var requestedMonth: Date?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoCalendar",
                                category: "EventsService")

    init(client: CalendarAPIClient, calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.calendar = calendar
        self.now = now
        self.month = Self.firstOfMonth(now(), calendar: calendar)
    }

    // MARK: - Navigation

    func showPreviousMonth() async { await show(month: calendar.date(byAdding: .month, value: -1, to: month)!) }
    func showNextMonth() async { await show(month: calendar.date(byAdding: .month, value: 1, to: month)!) }
    func showToday() async { await show(month: Self.firstOfMonth(now(), calendar: calendar)) }

    var isShowingCurrentMonth: Bool {
        month == Self.firstOfMonth(now(), calendar: calendar)
    }

    private func show(month newMonth: Date) async {
        if newMonth != month {
            month = newMonth
            sections = []
        }
        await reload()
    }

    // MARK: - Loading

    func reload() async {
        let shown = month
        let range = Self.monthRange(shown, calendar: calendar)
        requestedMonth = shown
        isLoading = true
        error = nil
        defer { if requestedMonth == shown { isLoading = false } }

        do {
            let events = try await client.events(from: range.from, to: range.to)
            guard requestedMonth == shown else { return }
            let occurrences = RecurrenceExpander.expand(events, from: range.from, to: range.to,
                                                        calendar: calendar)
            sections = Self.layout(occurrences, in: shown, calendar: calendar)
            logger.debug("loaded \(events.count) event(s), \(occurrences.count) occurrence(s)")
        } catch {
            guard requestedMonth == shown else { return }
            logger.error("reload failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    /// Forgets everything loaded, for sign-out: the next account must never see this one's events,
    /// not even behind a failed first load.
    func reset() {
        requestedMonth = nil
        sections = []
        error = nil
        isLoading = false
        month = Self.firstOfMonth(now(), calendar: calendar)
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

    /// Every day of `month` with its occurrences, empty days dropped — the web's `AgendaView`
    /// over the month's own days.
    ///
    /// Within a day: all-day first, then by start, then by title, so a list that refreshes does
    /// not reshuffle events that share a start time.
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
                .sorted { a, b in
                    if a.event.allDay != b.event.allDay { return a.event.allDay }
                    if a.start != b.start { return a.start < b.start }
                    return a.event.title.localizedStandardCompare(b.event.title) == .orderedAscending
                }
            return onDay.isEmpty ? nil : DaySection(day: day, occurrences: onDay)
        }
    }
}
