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

    /// The events each loaded month was answered with, before expansion: what a change from the
    /// changes feed is applied to.
    private var rawByMonth: [Date: [CalendarEvent]] = [:]
    /// Where the changes feed picks up. Taken before the first month loads, so a change made
    /// during a load is still reported; nil when nothing is loaded.
    private(set) var cursor: String?
    private var isPulling = false
    private var pullAgain = false

    private let client: CalendarAPIClient
    /// Where an edit or delete goes when the server can't be reached. Without one, it fails.
    var pending: PendingWrites?
    let calendar: Calendar
    private let now: () -> Date

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoCalendar",
                                category: "EventsService")

    init(client: CalendarAPIClient, calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.calendar = calendar
        self.now = now
        self.focus = calendar.startOfDay(for: now())
    }

    // MARK: - Queries

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

    /// Loads `mode`'s months again.
    func reload(for mode: CalendarMode) async {
        for month in months(for: mode) { await load(month) }
    }

    /// Pull-to-refresh: asks the server to pull from Google, Outlook and Apple first, then
    /// reloads. A provider that fails to sync is not worth an error; what is stored still loads.
    func refreshFromProviders(for mode: CalendarMode) async {
        do {
            try await client.triggerProviderSync()
        } catch {
            logger.error("provider sync failed: \(error, privacy: .public)")
        }
        await reload(for: mode)
    }

    /// Drops every loaded month, for after a change made elsewhere in the app, such as a task put
    /// on the calendar: the event may be in any month, and the cache must not keep a stale copy of
    /// one that is not on screen. The calendar reloads what it shows the next time it appears.
    func invalidate() {
        byMonth = [:]
        rawByMonth = [:]
        cursor = nil
        generation += 1
    }

    private func load(_ month: Date) async {
        let range = Self.monthRange(month, calendar: calendar)
        loadingMonths.insert(month)
        error = nil
        defer { loadingMonths.remove(month) }
        do {
            // Best effort: without a cursor, the next pull reloads the loaded months instead.
            if cursor == nil { cursor = try? await client.eventChanges(since: nil).cursor }
            let events = try await client.events(from: range.from, to: range.to)
            rawByMonth[month] = events
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
        rawByMonth = [:]
        cursor = nil
        loadingMonths = []
        error = nil
        focus = today
    }

    // MARK: - Changes made elsewhere

    /// Brings the loaded months up to date with the changes feed: an event changed or deleted on
    /// the web or another device. Called on a live signal, on coming back to the foreground, and
    /// from background refresh. A call made while one is running runs again after it, so a signal
    /// that lands mid-pull is not lost.
    func pullChanges() async {
        guard !byMonth.isEmpty else { return } // nothing held; the next load starts fresh
        if isPulling {
            pullAgain = true
            return
        }
        isPulling = true
        defer { isPulling = false }
        repeat {
            pullAgain = false
            guard let since = cursor else {
                // The cursor could not be had when the months loaded; load them again.
                for month in Array(byMonth.keys) { await load(month) }
                continue
            }
            do {
                let changes = try await client.eventChanges(since: since)
                if changes.fullResyncRequired {
                    invalidate()
                    return
                }
                apply(changed: changes.events, deleted: changes.deletedIds)
                cursor = changes.cursor
            } catch {
                logger.error("pull failed: \(error, privacy: .public)")
                return
            }
        } while pullAgain
    }

    /// Puts changed events into, and takes deleted ones out of, every loaded month, and expands
    /// again the months that changed.
    private func apply(changed: [CalendarEvent], deleted: [String]) {
        guard !changed.isEmpty || !deleted.isEmpty else { return }
        for (month, held) in rawByMonth {
            let range = Self.monthRange(month, calendar: calendar)
            let merged = Self.merge(held, changed: changed, deleted: Set(deleted), from: range.from, to: range.to)
            guard merged != held else { continue }
            rawByMonth[month] = merged
            byMonth[month] = RecurrenceExpander.expand(merged, from: range.from, to: range.to, calendar: calendar)
        }
        logger.debug("applied \(changed.count) change(s), \(deleted.count) deletion(s)")
    }

    /// `held` with every event in `changed` or `deleted` taken out, and those of `changed` that
    /// belong to the range put back in.
    static func merge(_ held: [CalendarEvent], changed: [CalendarEvent], deleted: Set<String>,
                      from: Date, to: Date) -> [CalendarEvent] {
        let touched = deleted.union(changed.map(\.id))
        return held.filter { !touched.contains($0.id) }
            + changed.filter { belongs($0, from: from, to: to) }
    }

    /// The server's own test for listing an event in a range (`find_by_user` in
    /// `events/repository.rs`): it starts by the range's end, and ends in it or repeats.
    static func belongs(_ event: CalendarEvent, from: Date, to: Date) -> Bool {
        event.start <= to && (event.end >= from || event.recurrenceRule != nil)
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
    ///
    /// Unless `overwrite`, it first checks the event as the server has it now, and throws
    /// `EditConflict` if the event was deleted, or one of the fields being saved was changed,
    /// somewhere else since `original` was read. Offline, the edit is queued and shown at once.
    @discardableResult
    func update(_ event: CalendarEvent, from original: EventDraft, to draft: EventDraft,
                overwrite: Bool = false) async throws -> CalendarEvent {
        let request = draft.updateRequest(from: original)
        guard request != UpdateEventRequest() else { return event }
        do {
            if !overwrite { try await checkForConflict(event, from: original, saving: request) }
            let updated = try await client.updateEvent(id: event.id, request)
            invalidate()
            return updated
        } catch let error as CalendarAPIError where error.isNetwork && pending != nil {
            pending?.enqueue(PendingWrite(method: "PUT", path: "/api/v1/calendar/events/\(event.id)", json: request))
            let local = CalendarEvent(event, editedTo: draft)
            apply(changed: [local], deleted: [])
            return local
        }
    }

    private func checkForConflict(_ event: CalendarEvent, from original: EventDraft,
                                  saving request: UpdateEventRequest) async throws {
        let current: CalendarEvent
        do {
            current = try await client.event(id: event.id)
        } catch let error as CalendarAPIError where error.isNotFound {
            throw EditConflict.deletedElsewhere
        }
        // What was changed elsewhere, measured from the same starting point as this edit.
        let theirs = EventDraft(editing: current, calendar: calendar).updateRequest(from: original)
        let clashes = EditConflict.clashes(mine: request, theirs: theirs)
        if !clashes.isEmpty { throw EditConflict.changedElsewhere(clashes) }
    }

    /// Deleting something already deleted elsewhere is not an error. Offline, the delete is queued
    /// and the event goes at once.
    func delete(_ event: CalendarEvent) async throws {
        do {
            try await client.deleteEvent(id: event.id)
            invalidate()
        } catch let error as CalendarAPIError where error.isNotFound {
            invalidate()
        } catch let error as CalendarAPIError where error.isNetwork && pending != nil {
            pending?.enqueue(PendingWrite(method: "DELETE", path: "/api/v1/calendar/events/\(event.id)"))
            apply(changed: [], deleted: [event.id])
        }
    }

    /// The event as the server has it now.
    func event(id: String) async throws -> CalendarEvent {
        try await client.event(id: id)
    }

    func attachments(for event: CalendarEvent) async throws -> [EventAttachment] {
        try await client.attachments(forEvent: event.id)
    }

    func addAttachment(_ request: CreateAttachmentRequest, to event: CalendarEvent) async throws -> Attachment {
        try await client.addEventAttachment(eventID: event.id, request)
    }

    func deleteAttachment(_ attachment: Attachment, from event: CalendarEvent) async throws {
        try await client.deleteEventAttachment(eventID: event.id, attachmentID: attachment.id)
    }

    /// The attachments of `event`, for `AttachmentsSection`.
    func attachmentOwner(_ event: CalendarEvent) -> AttachmentOwner {
        AttachmentOwner(id: "event-\(event.id)",
                        load: { try await self.attachments(for: event) },
                        add: { try await self.addAttachment($0, to: event) },
                        delete: { try await self.deleteAttachment($0, from: event) })
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
