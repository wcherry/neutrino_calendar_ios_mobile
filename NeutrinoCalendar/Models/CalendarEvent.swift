import Foundation

// MARK: - CalendarEvent

/// One row of `GET /api/v1/calendar/events`, as `EventResponse` in
/// `neutrino/src/calendar/events/dto.rs` serialises it.
///
/// Times arrive as UTC instants (`2026-09-24T17:00:00Z`). An all-day event is the exception in
/// meaning if not in shape: the web writes it as `<date>T00:00:00Z` to `<last date>T23:59:59Z`
/// and reads the date part back without converting it, so an all-day event is a *date*, the same
/// date in every time zone. `EventDayRange` is where that difference is honoured.
struct CalendarEvent: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let description: String?
    let start: Date
    let end: Date
    let allDay: Bool
    let location: String?
    /// An RFC 5545 RRULE body such as `FREQ=WEEKLY;BYDAY=MO,WE`, stored as written. Expanded on
    /// the device by `RecurrenceExpander`; the server never expands it.
    let recurrenceRule: String?
    let attendees: [String]
    let source: EventSource
    let createdAt: Date?
    let updatedAt: Date?
    /// The IANA zone the event was created in, for a timed event. Display only: times are
    /// instants, and the web ignores this when placing an event on the calendar.
    let timezone: String?
    /// Set on an exception: the repeating event whose occurrence this row stands in for. See
    /// `neutrino/agent_docs/recurrence-exceptions.md`.
    let recurringEventId: String?
    /// Set on an exception: the occurrence's start in its series, before any edit. Its key.
    let originalStart: Date?
    /// An exception that deletes its occurrence.
    let cancelled: Bool
    /// The calendar it is in (`UserCalendar`). Nil from a server older than calendars, which
    /// puts everything in the default calendar.
    let calendarId: String?

    /// Whether this is a series: an event with a rule. An exception is never one.
    var isRecurring: Bool { !(recurrenceRule ?? "").isEmpty }

    private enum CodingKeys: String, CodingKey {
        case id, title, description, startTime, endTime, allDay, location, recurrenceRule
        case attendees, source, createdAt, updatedAt, timezone
        case recurringEventId, originalStartTime, cancelled, calendarId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        start = try Self.decodeDate(c, .startTime)
        end = try Self.decodeDate(c, .endTime)
        allDay = try c.decodeIfPresent(Bool.self, forKey: .allDay) ?? false
        location = try c.decodeIfPresent(String.self, forKey: .location)
        recurrenceRule = try c.decodeIfPresent(String.self, forKey: .recurrenceRule)
        attendees = try c.decodeIfPresent([String].self, forKey: .attendees) ?? []
        source = EventSource(rawValue: try c.decodeIfPresent(String.self, forKey: .source) ?? "local")
        createdAt = (try? c.decodeIfPresent(String.self, forKey: .createdAt)).flatMap(ServerDate.parse)
        updatedAt = (try? c.decodeIfPresent(String.self, forKey: .updatedAt)).flatMap(ServerDate.parse)
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone)
        recurringEventId = try c.decodeIfPresent(String.self, forKey: .recurringEventId)
        originalStart = (try? c.decodeIfPresent(String.self, forKey: .originalStartTime)).flatMap(ServerDate.parse)
        cancelled = try c.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
        calendarId = try c.decodeIfPresent(String.self, forKey: .calendarId)
    }

    /// For tests and previews.
    init(id: String, title: String, description: String? = nil, start: Date, end: Date,
         allDay: Bool = false, location: String? = nil, recurrenceRule: String? = nil,
         attendees: [String] = [], source: EventSource = .local, timezone: String? = nil,
         recurringEventId: String? = nil, originalStart: Date? = nil, cancelled: Bool = false,
         calendarId: String? = nil) {
        self.id = id
        self.title = title
        self.description = description
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
        self.recurrenceRule = recurrenceRule
        self.attendees = attendees
        self.source = source
        self.createdAt = nil
        self.updatedAt = nil
        self.timezone = timezone
        self.recurringEventId = recurringEventId
        self.originalStart = originalStart
        self.cancelled = cancelled
        self.calendarId = calendarId
    }

    /// `event` with other times and rule: an occurrence of it, or the series as it runs from one.
    init(_ event: CalendarEvent, start: Date, end: Date, recurrenceRule: String?) {
        self.init(id: event.id, title: event.title, description: event.description, start: start, end: end,
                  allDay: event.allDay, location: event.location, recurrenceRule: recurrenceRule,
                  attendees: event.attendees, source: event.source, timezone: event.timezone,
                  recurringEventId: event.recurringEventId, originalStart: event.originalStart,
                  cancelled: event.cancelled, calendarId: event.calendarId)
    }

    private static func decodeDate(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Date {
        let raw = try c.decode(String.self, forKey: key)
        guard let date = ServerDate.parse(raw) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c,
                                                   debugDescription: "Not an ISO 8601 instant: \(raw)")
        }
        return date
    }
}

struct ListEventsResponse: Decodable {
    let events: [CalendarEvent]
}

// MARK: - EventSource

/// Where an event came from. The server writes `local` for events made in Neutrino and the
/// provider's name for synced ones (`src/calendar/connections/`). Two are never stored: a
/// holiday, computed on the device (`HolidayEngine`), and a task drawn on the calendar
/// (`TaskOccurrences`). The web uses the same names (`HOLIDAY_SOURCE`, `TASK_SOURCE`).
enum EventSource: Hashable {
    case local, google, outlook, apple
    case holidays, task
    case other(String)

    init(rawValue: String) {
        switch rawValue.lowercased() {
        case "local":    self = .local
        case "google":   self = .google
        case "outlook":  self = .outlook
        case "apple":    self = .apple
        case "holidays": self = .holidays
        case "task":     self = .task
        default:         self = .other(rawValue)
        }
    }

    /// Computed on the device, with no server row behind it: nothing to fetch, edit, delete,
    /// remind about or attach to.
    var isComputed: Bool { self == .holidays || self == .task }

    /// The badge shown on a synced event. `nil` for Neutrino's own events, which need none.
    var badge: String? {
        switch self {
        case .local, .holidays, .task: return nil
        case .google:           return "Google"
        case .outlook:          return "Outlook"
        case .apple:            return "iCloud"
        case .other(let name):  return name.capitalized
        }
    }
}

// MARK: - ServerDate

/// The server writes `%Y-%m-%dT%H:%M:%SZ`; the web writes back `toISOString()`, which adds
/// milliseconds. Both have to read.
enum ServerDate {
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ string: String) -> Date? {
        plain.date(from: string) ?? fractional.date(from: string)
    }

    static func format(_ date: Date) -> String {
        plain.string(from: date)
    }
}
