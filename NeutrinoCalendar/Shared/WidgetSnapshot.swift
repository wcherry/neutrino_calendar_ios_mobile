import Foundation

// Compiled into both the app and the widget extension (see project.yml). The app writes the
// snapshot; the widgets only read it. Keep this file Foundation-only.

// MARK: - WidgetEvent

/// One occurrence as the widgets show it, already expanded and filtered by the app.
struct WidgetEvent: Codable, Hashable, Identifiable {
    /// An `EventLink` string, which is what a tap on it opens.
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    /// The first and last local days it covers, as `yyyy-MM-dd`: an all-day event is dates, and
    /// the widget has no `EventDayRange` to work them out.
    let firstDay: String
    let lastDay: String
    let location: String?
    /// Its calendar's colour, `#rrggbb`; nil draws it in the accent colour. Absent from a
    /// snapshot written before calendars, which still decodes.
    var color: String? = nil
}

// MARK: - WidgetSnapshot

/// What the widgets and nothing else know about the calendar: the coming fortnight's events, the
/// days of this month and next that have any, and the week start. Written by the app into the App
/// Group container whenever the calendar changes.
///
/// **Never tokens, and nothing the widgets don't draw.** No notes, no attendees, no ids beyond
/// what a tap needs. The extension has no Keychain access and no network: it can only show
/// what the app last wrote.
struct WidgetSnapshot: Codable, Equatable {
    static let appGroup = "group.com.neutrino.calendar"
    static let fileName = "widget-snapshot.json"
    /// How far ahead `events` reaches.
    static let horizonDays = 14

    var signedIn: Bool
    var generatedAt: Date
    /// The zone the day keys were worked out in.
    var timeZone: String
    /// 1 = Sunday, as `Calendar.firstWeekday`.
    var firstWeekday: Int
    /// From the start of the day it was written, soonest first.
    var events: [WidgetEvent]
    /// `yyyy-MM-dd` of every day this month and next with at least one event, for the month grid.
    var busyDays: Set<String>
    /// Set when a Focus is hiding some calendars: "Neutrino and Google".
    var filterSummary: String?

    static func signedOut(now: Date = Date()) -> WidgetSnapshot {
        WidgetSnapshot(signedIn: false, generatedAt: now, timeZone: TimeZone.current.identifier,
                       firstWeekday: 1, events: [], busyDays: [], filterSummary: nil)
    }

    /// The calendar the day keys were written in.
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    // MARK: - Queries

    /// Not over at `date`, soonest first: a timed event until its end, an all-day one until the
    /// end of its last day.
    func upcoming(at date: Date) -> [WidgetEvent] {
        let today = Self.dayKey(date, calendar: calendar)
        return events.filter { $0.allDay ? $0.lastDay >= today : $0.end > date }
    }

    /// The next timed event, or the one under way. All-day events are the day, not a thing in it.
    func next(at date: Date) -> WidgetEvent? {
        upcoming(at: date).first { !$0.allDay }
    }

    /// Everything on the day of `date`, all-day first, then by start.
    func events(on date: Date) -> [WidgetEvent] {
        let day = Self.dayKey(date, calendar: calendar)
        return events
            .filter { $0.firstDay <= day && day <= $0.lastDay }
            .sorted { a, b in a.allDay != b.allDay ? a.allDay : a.start < b.start }
    }

    /// The moments a widget's content changes over the next day: each start and end, and
    /// midnight. The first is `now`.
    func entryDates(from now: Date, limit: Int = 40) -> [Date] {
        let calendar = calendar
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let changes = events.filter { !$0.allDay }.flatMap { [$0.start, $0.end] }
            .filter { $0 > now && $0 <= midnight }
        return Array(([now, midnight] + changes).reduce(into: Set<Date>()) { $0.insert($1) }.sorted().prefix(limit))
    }

    // MARK: - Days

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let d = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", d.year!, d.month!, d.day!)
    }

    static func day(fromKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    // MARK: - Storage

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName)
    }

    static func load(from url: URL? = fileURL) -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    func encoded() throws -> Data { try Self.encoder.encode(self) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = .sortedKeys
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

// MARK: - WidgetLink

/// What a tap on a widget or Live Activity opens: `neutrinocalendar://event/<EventLink>` or
/// `neutrinocalendar://day/<yyyy-MM-dd>`. The scheme is registered in project.yml.
enum WidgetLink: Equatable {
    case event(String)
    case day(String)

    static let scheme = "neutrinocalendar"

    var url: URL {
        switch self {
        case .event(let link):
            let escaped = link.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? link
            return URL(string: "\(Self.scheme)://event/\(escaped)")!
        case .day(let key):
            return URL(string: "\(Self.scheme)://day/\(key)")!
        }
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        // `path` is already percent-decoded.
        let value = String(url.path.dropFirst())
        guard !value.isEmpty else { return nil }
        switch url.host {
        case "event": self = .event(value)
        case "day":   self = .day(value)
        default:      return nil
        }
    }
}
