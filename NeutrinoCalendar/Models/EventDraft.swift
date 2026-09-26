import Foundation

// MARK: - Requests

/// `CreateEventRequest` in `neutrino/src/calendar/events/dto.rs`.
struct CreateEventRequest: Encodable, Equatable {
    let title: String
    let description: String?
    let startTime: String
    let endTime: String
    let allDay: Bool
    let location: String?
    let recurrenceRule: String?
    let attendees: [String]
    let timezone: String?
}

/// `UpdateEventRequest`: every field optional, and an absent one is left alone.
///
/// The server cannot store NULL through an update, only a value, so a field being emptied is
/// sent as `""`: the app reads an empty location, note or rule as none, as the server's own
/// readers do. (The web sends `null` there, which the server ignores, so on the web a cleared
/// field quietly keeps its old value.)
struct UpdateEventRequest: Encodable, Equatable {
    var title: String?
    var description: String?
    var startTime: String?
    var endTime: String?
    var allDay: Bool?
    var location: String?
    var recurrenceRule: String?
    var attendees: [String]?
    var timezone: String?
}

// MARK: - EventDraft

/// The event form's state, and the requests it turns into. Kept out of the view so what gets
/// sent is testable in a fixed zone.
struct EventDraft: Equatable {
    var title = ""
    var location = ""
    var notes = ""
    var allDay = false
    /// For a timed event, the instants; for an all-day one, any time on the first and last days,
    /// read as dates in `timeZone`.
    var start: Date
    var end: Date
    /// The zone the start and end are entered in, and stored as the event's `timezone`.
    var timeZone: TimeZone
    var repeatOption: RepeatOption = .never
    var attendees: [String] = []

    /// An hour, the length a new event gets, as on the web.
    static let defaultLength: TimeInterval = 60 * 60

    /// A new event on `day`: at the top of the next hour when `day` is today, at 09:00 otherwise.
    init(newOn day: Date, now: Date = Date(), calendar: Calendar = .current) {
        let start: Date
        if calendar.isDate(day, inSameDayAs: now),
           let next = calendar.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) {
            start = next
        } else {
            start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        }
        self.start = start
        self.end = start.addingTimeInterval(Self.defaultLength)
        self.timeZone = calendar.timeZone
    }

    /// The form for editing `event`: the whole series for a repeating one, so its own start is
    /// shown, not the tapped occurrence's. Saving an occurrence's date as the start would move
    /// the series there and drop every occurrence before it.
    init(editing event: CalendarEvent, calendar: Calendar = .current) {
        title = event.title
        location = event.location ?? ""
        notes = event.description ?? ""
        allDay = event.allDay
        timeZone = event.timezone.flatMap(TimeZone.init(identifier:)) ?? calendar.timeZone
        if event.allDay {
            // An all-day event is dates: its first and last day, as local midnights.
            var local = calendar
            local.timeZone = timeZone
            let range = EventDayRange(start: event.start, end: event.end, allDay: true, calendar: local)
            start = range.first
            end = range.last
        } else {
            start = event.start
            end = event.end
        }
        repeatOption = RepeatOption(rule: event.recurrenceRule)
        attendees = event.attendees
    }

    /// Changes the zone and keeps the clock times, as the iPhone's Calendar does: picking New
    /// York for a 10:00 event means 10:00 in New York, not the same instant shown as 13:00.
    mutating func setTimeZone(_ zone: TimeZone) {
        guard zone.identifier != timeZone.identifier else { return }
        var from = Calendar(identifier: .gregorian)
        from.timeZone = timeZone
        var to = from
        to.timeZone = zone
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        start = to.date(from: from.dateComponents(fields, from: start)) ?? start
        end = to.date(from: from.dateComponents(fields, from: end)) ?? end
        timeZone = zone
    }

    // MARK: - Validation

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why the form can't be saved, or `nil` when it can.
    var problem: String? {
        if trimmedTitle.isEmpty { return "An event needs a title." }
        if allDay ? day(end) < day(start) : end < start { return "The event ends before it starts." }
        return nil
    }

    /// Adds a guest by email, ignoring case for duplicates. Returns whether it was added.
    @discardableResult
    mutating func addAttendee(_ raw: String) -> Bool {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeEmail(email),
              !attendees.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) else { return false }
        attendees.append(email)
        return true
    }

    /// The server takes any string; this only stops a typo like "ada" becoming a guest.
    static func looksLikeEmail(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !s.contains(" ")
    }

    // MARK: - Wire form

    /// The times as the web writes them: an all-day event is dates, `T00:00:00Z` to
    /// `T23:59:59Z` on its last day; a timed one is two instants.
    var wireTimes: (start: String, end: String) {
        if allDay { return ("\(day(start))T00:00:00Z", "\(day(end))T23:59:59Z") }
        return (ServerDate.format(start), ServerDate.format(end))
    }

    /// A timed event carries the zone it was entered in; an all-day one none, as on the web.
    var wireTimeZone: String? { allDay ? nil : timeZone.identifier }

    func createRequest() -> CreateEventRequest {
        let times = wireTimes
        return CreateEventRequest(
            title: trimmedTitle,
            description: nonEmpty(notes),
            startTime: times.start,
            endTime: times.end,
            allDay: allDay,
            location: nonEmpty(location),
            recurrenceRule: repeatOption.rule,
            attendees: attendees,
            timezone: wireTimeZone
        )
    }

    /// Only what changed since `original`. The three time fields travel together, since each
    /// means something only beside the others.
    func updateRequest(from original: EventDraft) -> UpdateEventRequest {
        var request = UpdateEventRequest()
        if trimmedTitle != original.trimmedTitle { request.title = trimmedTitle }
        if trimmed(notes) != trimmed(original.notes) { request.description = trimmed(notes) }
        if trimmed(location) != trimmed(original.location) { request.location = trimmed(location) }
        if wireTimes != original.wireTimes || allDay != original.allDay {
            let times = wireTimes
            request.startTime = times.start
            request.endTime = times.end
            request.allDay = allDay
        }
        if wireTimeZone != original.wireTimeZone { request.timezone = wireTimeZone ?? "" }
        if repeatOption != original.repeatOption { request.recurrenceRule = repeatOption.rule ?? "" }
        if attendees != original.attendees { request.attendees = attendees }
        return request
    }

    // MARK: - Helpers

    /// `yyyy-MM-dd` of `date` in the draft's zone.
    private func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let d = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", d.year!, d.month!, d.day!)
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func nonEmpty(_ s: String) -> String? { trimmed(s).isEmpty ? nil : trimmed(s) }
}

// MARK: - Local edits

extension CalendarEvent {
    /// `event` as `draft` would leave it: what an edit made offline shows until the server has
    /// it. Times are read back from the wire form, so an all-day event is its dates, as a loaded
    /// one is.
    init(_ event: CalendarEvent, editedTo draft: EventDraft) {
        let times = draft.wireTimes
        self.init(id: event.id,
                  title: draft.trimmedTitle,
                  description: draft.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draft.notes,
                  start: ServerDate.parse(times.start) ?? draft.start,
                  end: ServerDate.parse(times.end) ?? draft.end,
                  allDay: draft.allDay,
                  location: draft.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draft.location,
                  recurrenceRule: draft.repeatOption.rule,
                  attendees: draft.attendees,
                  source: event.source,
                  timezone: draft.wireTimeZone)
    }
}
