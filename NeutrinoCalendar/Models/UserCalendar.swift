import Foundation

// MARK: - UserCalendar

/// One of the user's calendars: `CalendarResponse` in
/// `neutrino/src/calendar/calendars/dto.rs`. Every event belongs to one. Named `UserCalendar`
/// because `Calendar` is Foundation's.
///
/// Hiding a calendar is applied here, when events are drawn, not by the server, which lists
/// hidden calendars' events like any other. See `neutrino/agent_docs/calendars.md`.
struct UserCalendar: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        /// Made in Neutrino.
        case local
        /// A connected Google, Outlook or iCloud calendar.
        case connection
        /// A country's public holidays, computed on the device (`HolidayEngine`).
        case holidays
    }

    let id: String
    var name: String
    /// `#rrggbb`.
    var color: String
    var visible: Bool
    let readOnly: Bool
    let kind: Kind
    let isDefault: Bool
    /// A connection calendar's provider: `google`, `outlook`, `apple`.
    let source: String?
    /// A holiday calendar's country, ISO 3166-1 alpha-2.
    let country: String?
    var region: String?
    var includeObservances: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, color, visible, readOnly, kind, isDefault, source, country, region, includeObservances
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? UserCalendar.palette[0]
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        // A kind added later reads as a plain calendar rather than failing the whole list.
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .local
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        source = try c.decodeIfPresent(String.self, forKey: .source)
        country = try c.decodeIfPresent(String.self, forKey: .country)
        region = try c.decodeIfPresent(String.self, forKey: .region)
        includeObservances = try c.decodeIfPresent(Bool.self, forKey: .includeObservances) ?? false
    }

    /// For tests and previews.
    init(id: String, name: String, color: String = UserCalendar.palette[0], visible: Bool = true,
         readOnly: Bool = false, kind: Kind = .local, isDefault: Bool = false, source: String? = nil,
         country: String? = nil, region: String? = nil, includeObservances: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.visible = visible
        self.readOnly = readOnly
        self.kind = kind
        self.isDefault = isDefault
        self.source = source
        self.country = country
        self.region = region
        self.includeObservances = includeObservances
    }

    /// The colours offered for a new calendar: the web's `CALENDAR_COLORS`.
    static let palette = ["#3b82f6", "#16a34a", "#f97316", "#8b5cf6", "#e11d48", "#0ea5e9", "#ca8a04", "#64748b"]

    /// The first palette colour no calendar in `calendars` uses, or the first one.
    static func unusedColor(among calendars: [UserCalendar]) -> String {
        let used = Set(calendars.map { $0.color.lowercased() })
        return palette.first { !used.contains($0) } ?? palette[0]
    }

    /// Whether it can be deleted from here: never the default calendar, and a provider's only
    /// once its account is disconnected, which the server enforces (409).
    var isDeletable: Bool { !isDefault && kind != .connection }
}

struct ListCalendarsResponse: Decodable {
    let calendars: [UserCalendar]
}

/// `POST /calendars`. Only the fields set are sent.
struct CreateCalendarRequest: Encodable, Equatable {
    var name: String?
    var color: String?
    var kind: String?
    var country: String?
    var region: String?
    var includeObservances: Bool?

    static func local(name: String, color: String) -> CreateCalendarRequest {
        CreateCalendarRequest(name: name, color: color)
    }

    static func holidays(country: String, name: String, color: String) -> CreateCalendarRequest {
        CreateCalendarRequest(name: name, color: color, kind: UserCalendar.Kind.holidays.rawValue, country: country)
    }
}

/// `PATCH /calendars/{id}`: settings, so a read-only calendar takes it too. An empty `region`
/// clears it.
struct UpdateCalendarRequest: Encodable, Equatable {
    var name: String?
    var color: String?
    var visible: Bool?
    var region: String?
    var includeObservances: Bool?
}

// MARK: - CalendarRules

/// What the user's calendars decide about an event: whether it is shown, whether it can be
/// changed, and its colour. The web's `visibleEvents`, `isReadOnlyEvent` and `writableCalendars`
/// (`calendar/calendars.ts`), which `CalendarRulesTests` pins to the same cases.
struct CalendarRules: Equatable {
    private let byID: [String: UserCalendar]

    init(_ calendars: [UserCalendar]) {
        byID = Dictionary(calendars.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static let none = CalendarRules([])

    func calendar(of event: CalendarEvent) -> UserCalendar? {
        event.calendarId.flatMap { byID[$0] }
    }

    func calendar(id: String?) -> UserCalendar? { id.flatMap { byID[$0] } }

    /// An event in no calendar this device knows of is shown, so nothing vanishes while the list
    /// is loading; one in a hidden calendar is not.
    func isShown(_ event: CalendarEvent) -> Bool {
        calendar(of: event)?.visible != false
    }

    /// A holiday, or anything in a read-only calendar. Synced provider events are also read-only
    /// on this device, by source, until the server can write back to the provider (Epic 17).
    func isReadOnly(_ event: CalendarEvent) -> Bool {
        event.source == .holidays || calendar(of: event)?.readOnly == true
    }

    /// Whether the event can be edited or deleted here.
    func isEditable(_ event: CalendarEvent) -> Bool {
        event.source == .local && !isReadOnly(event)
    }

    /// The calendar's colour, or nil for an event in no known calendar, which is drawn as every
    /// event was before calendars.
    func color(of event: CalendarEvent) -> String? {
        calendar(of: event)?.color
    }

    /// The calendars an event can be put in.
    static func writable(_ calendars: [UserCalendar]) -> [UserCalendar] {
        calendars.filter { !$0.readOnly }
    }
}

// MARK: - EventFilter

/// Everything that decides whether an event is drawn: the calendar it is in, and the Focus
/// filter. Both have to allow it; neither overrides the other.
struct EventFilter: Equatable {
    var rules: CalendarRules
    var focus: SourceFilter

    static let all = EventFilter(rules: .none, focus: .all)

    func shows(_ event: CalendarEvent) -> Bool {
        rules.isShown(event) && focus.shows(event.source)
    }

    /// What Spotlight goes by: a search is asked for, so a Focus doesn't narrow it, but a hidden
    /// calendar is hidden everywhere.
    var ignoringFocus: EventFilter { EventFilter(rules: rules, focus: .all) }
}
