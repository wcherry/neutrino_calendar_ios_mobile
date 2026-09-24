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

    private enum CodingKeys: String, CodingKey {
        case id, title, description, startTime, endTime, allDay, location, recurrenceRule
        case attendees, source, createdAt, updatedAt, timezone
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
    }

    /// For tests and previews.
    init(id: String, title: String, description: String? = nil, start: Date, end: Date,
         allDay: Bool = false, location: String? = nil, recurrenceRule: String? = nil,
         attendees: [String] = [], source: EventSource = .local, timezone: String? = nil) {
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
/// provider's name for synced ones (`src/calendar/connections/`).
enum EventSource: Hashable {
    case local, google, outlook, apple
    case other(String)

    init(rawValue: String) {
        switch rawValue.lowercased() {
        case "local":   self = .local
        case "google":  self = .google
        case "outlook": self = .outlook
        case "apple":   self = .apple
        default:        self = .other(rawValue)
        }
    }

    /// The badge shown on a synced event. `nil` for Neutrino's own events, which need none.
    var badge: String? {
        switch self {
        case .local:            return nil
        case .google:           return "Google"
        case .outlook:          return "Outlook"
        case .apple:            return "iCloud"
        case .other(let name):  return name.capitalized
        }
    }
}

// MARK: - EventAttachment

/// One row of `GET /api/v1/calendar/events/{id}/attachments`: either a Drive file or an inline
/// text note, never both.
struct EventAttachment: Decodable, Identifiable, Hashable {
    let id: String
    let fileId: String?
    let name: String?
    let note: String?
}

struct ListAttachmentsResponse: Decodable {
    let attachments: [EventAttachment]
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
