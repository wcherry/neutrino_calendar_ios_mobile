import Foundation

// MARK: - EventLink

/// One occurrence of an event, as a string that survives outside the app: a Spotlight item's
/// identifier and a Shortcuts entity's id. `<event id>@<start, in seconds since 1970>`, so a
/// repeating event opens on the occurrence that was found, not on its first.
struct EventLink: Hashable {
    let eventID: String
    let start: Date

    init(eventID: String, start: Date) {
        self.eventID = eventID
        self.start = start
    }

    init(_ occurrence: EventOccurrence) {
        self.init(eventID: occurrence.event.id, start: occurrence.start)
    }

    init?(string: String) {
        guard let at = string.lastIndex(of: "@"),
              let seconds = TimeInterval(string[string.index(after: at)...]) else { return nil }
        let id = String(string[..<at])
        guard !id.isEmpty else { return nil }
        self.init(eventID: id, start: Date(timeIntervalSince1970: seconds))
    }

    var string: String { "\(eventID)@\(Int(start.timeIntervalSince1970.rounded()))" }

    /// The occurrence of `event` this link names: the event's own length, from the linked start.
    /// When the event has since moved, that is where it is shown, not where it was.
    func occurrence(of event: CalendarEvent) -> EventOccurrence {
        guard event.recurrenceRule != nil else {
            return EventOccurrence(event: event, start: event.start, end: event.end)
        }
        return EventOccurrence(event: event, start: start, end: start.addingTimeInterval(event.end.timeIntervalSince(event.start)))
    }
}

// MARK: - UpNext

/// What is coming up: the answer to "What's next" and what Spotlight indexes.
enum UpNext {

    /// The occurrences not over yet, soonest first. A timed one is over at its end; an all-day
    /// one at the end of its last day, read as dates the way the grids read it.
    static func upcoming(_ occurrences: [EventOccurrence], now: Date, calendar: Calendar) -> [EventOccurrence] {
        let today = calendar.startOfDay(for: now)
        return occurrences
            .filter { $0.event.allDay ? EventDayRange($0, calendar: calendar).last >= today : $0.end > now }
            .sorted { a, b in
                let (x, y) = (sortStart(a, calendar), sortStart(b, calendar))
                if x != y { return x < y }
                return a.event.title.localizedStandardCompare(b.event.title) == .orderedAscending
            }
    }

    /// An all-day event starts at local midnight of its first date, not at the UTC instant it
    /// is stored as.
    private static func sortStart(_ occurrence: EventOccurrence, _ calendar: Calendar) -> Date {
        occurrence.event.allDay ? EventDayRange(occurrence, calendar: calendar).first : occurrence.start
    }

    /// Each event once, at its first upcoming occurrence: a daily stand-up is one search result,
    /// not thirty.
    static func firstOfEach(_ upcoming: [EventOccurrence]) -> [EventOccurrence] {
        var seen = Set<String>()
        return upcoming.filter { seen.insert($0.event.id).inserted }
    }

    /// The next timed event the filter shows, including one already under way. All-day events
    /// aren't "next": they are the day, not a thing in it.
    static func next(_ upcoming: [EventOccurrence], filter: SourceFilter) -> EventOccurrence? {
        upcoming.first { !$0.event.allDay && filter.shows($0.event.source) }
    }

    /// Siri's answer: "Stand-up is on now, until 10:30 AM." or "Next is Stand-up, tomorrow at
    /// 9:00 AM, at Room 4."
    static func sentence(for occurrence: EventOccurrence?, now: Date, calendar: Calendar,
                         days: Int) -> String {
        guard let occurrence else {
            return "There's nothing on your calendar in the next \(days) days."
        }
        let title = occurrence.event.title
        let place = occurrence.event.location.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : ", at \($0)" } ?? ""
        if occurrence.start <= now {
            let time = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone)
            return "\(title) is on now, until \(occurrence.end.formatted(time))\(place)."
        }
        return "Next is \(title), \(at(occurrence.start, now: now, calendar: calendar))\(place)."
    }

    /// "today", "tomorrow", "on Thursday" within the week, or "on Oct 3".
    static func when(_ date: Date, now: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0:  return "today"
        case 1:  return "tomorrow"
        case 2..<7:
            return "on \(date.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.wide)))"
        default:
            return "on \(date.formatted(Date.FormatStyle(timeZone: calendar.timeZone).month(.abbreviated).day()))"
        }
    }
}

// MARK: - Confirmations

extension UpNext {
    /// What Siri says after adding an event: "Added Dentist, tomorrow at 9:00 AM." or, for an
    /// all-day one, "Added Holiday, on Oct 3, all day."
    static func added(_ occurrence: EventOccurrence, now: Date, calendar: Calendar) -> String {
        let title = occurrence.event.title
        if occurrence.event.allDay {
            let first = EventDayRange(occurrence, calendar: calendar).first
            return "Added \(title), \(when(first, now: now, calendar: calendar)), all day."
        }
        return "Added \(title), \(at(occurrence.start, now: now, calendar: calendar))."
    }

    /// "I'll remind you about Call the bank today at 5:00 PM."
    static func willRemind(_ title: String, due: Date, now: Date, calendar: Calendar) -> String {
        "I'll remind you about \(title) \(at(due, now: now, calendar: calendar))."
    }

    /// "tomorrow at 9:00 AM"
    private static func at(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone)
        return "\(when(date, now: now, calendar: calendar)) at \(date.formatted(time))"
    }
}
