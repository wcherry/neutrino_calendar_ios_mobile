import Foundation

// MARK: - CalendarTask

/// One task from `GET /api/v1/calendar/tasks` (`TaskResponse` in
/// `neutrino/src/calendar/tasks/dto.rs`).
///
/// Tasks are one flat list in `position` order, as on the web. The server still has task *lists*,
/// but the web stopped grouping by them because they are being replaced by tags, so this app never
/// shows them either: a list picker for something on its way out would stand between the user and
/// typing a task.
struct CalendarTask: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let notes: String?
    let done: Bool
    /// A date, not an instant: the web stores `<date>T00:00:00Z` and reads the date part back, so
    /// it is shown in UTC and means the same day everywhere.
    let dueDate: Date?
    let position: Int
    /// The calendar event this task is scheduled as, if it is on the calendar.
    let eventId: String?
    /// `dueDate` is an instant ("^fri 3pm") rather than a `<day>T00:00:00Z` date.
    let dueHasTime: Bool
    /// 1 (high) to 3 (low).
    let priority: Int?
    /// Lowercase, without the `#`.
    let tags: [String]
    /// An RRULE body. Completing the task creates the next occurrence as a new task.
    let recurrenceRule: String?
    let repeatAfterCompletion: Bool
    let estimateMinutes: Int?
    let location: String?
    /// Where the task reminds you on arrival, if anywhere: a saved place, or a one-off point.
    /// `location` stays the text shown for it, so older clients still have something to show.
    let geofence: TaskGeofence?

    private enum CodingKeys: String, CodingKey {
        case id, title, notes, done, dueDate, position, eventId
        case dueHasTime, priority, tags, recurrenceRule, repeatAfterCompletion, estimateMinutes, location
        case geoPlaceId, geoLat, geoLng, geoRadiusM
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes).flatMap { $0.isEmpty ? nil : $0 }
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        dueDate = try c.decodeIfPresent(String.self, forKey: .dueDate).flatMap(ServerDate.parse)
        position = try c.decodeIfPresent(Int.self, forKey: .position) ?? 0
        eventId = try c.decodeIfPresent(String.self, forKey: .eventId)
        // Absent from servers older than Smart Add, so every one of these has a default.
        dueHasTime = try c.decodeIfPresent(Bool.self, forKey: .dueHasTime) ?? false
        priority = try c.decodeIfPresent(Int.self, forKey: .priority)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        recurrenceRule = try c.decodeIfPresent(String.self, forKey: .recurrenceRule)
        repeatAfterCompletion = try c.decodeIfPresent(Bool.self, forKey: .repeatAfterCompletion) ?? false
        estimateMinutes = try c.decodeIfPresent(Int.self, forKey: .estimateMinutes)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        // Absent from servers older than geofencing (wcherry/neutrino_calendar_ios_mobile#23).
        geofence = try Self.decodeGeofence(c)
    }

    /// A saved place wins over a point, though the server never stores both.
    private static func decodeGeofence(_ c: KeyedDecodingContainer<CodingKeys>) throws -> TaskGeofence? {
        if let id = try c.decodeIfPresent(String.self, forKey: .geoPlaceId) { return .place(id: id) }
        guard let lat = try c.decodeIfPresent(Double.self, forKey: .geoLat),
              let lng = try c.decodeIfPresent(Double.self, forKey: .geoLng) else { return nil }
        let radius = try c.decodeIfPresent(Int.self, forKey: .geoRadiusM) ?? GeoPoint.defaultRadius
        return .point(GeoPoint(latitude: lat, longitude: lng, radius: radius))
    }

    /// For tests and previews.
    init(id: String, title: String, notes: String? = nil, done: Bool = false, dueDate: Date? = nil,
         position: Int = 0, eventId: String? = nil, dueHasTime: Bool = false, priority: Int? = nil,
         tags: [String] = [], recurrenceRule: String? = nil, repeatAfterCompletion: Bool = false,
         estimateMinutes: Int? = nil, location: String? = nil, geofence: TaskGeofence? = nil) {
        self.id = id
        self.title = title
        self.notes = notes
        self.done = done
        self.dueDate = dueDate
        self.position = position
        self.eventId = eventId
        self.dueHasTime = dueHasTime
        self.priority = priority
        self.tags = tags
        self.recurrenceRule = recurrenceRule
        self.repeatAfterCompletion = repeatAfterCompletion
        self.estimateMinutes = estimateMinutes
        self.location = location
        self.geofence = geofence
    }

    /// This task with some fields changed: what an edit made offline shows until the server has it.
    func with(title: String? = nil, notes: String?? = nil, done: Bool? = nil,
              dueDate: Date?? = nil, dueHasTime: Bool? = nil, tags: [String]? = nil,
              location: String?? = nil, geofence: TaskGeofence?? = nil) -> CalendarTask {
        CalendarTask(id: id, title: title ?? self.title, notes: notes ?? self.notes, done: done ?? self.done,
                     dueDate: dueDate ?? self.dueDate, position: position, eventId: eventId,
                     dueHasTime: dueHasTime ?? self.dueHasTime, priority: priority, tags: tags ?? self.tags,
                     recurrenceRule: recurrenceRule, repeatAfterCompletion: repeatAfterCompletion,
                     estimateMinutes: estimateMinutes, location: location ?? self.location,
                     geofence: geofence ?? self.geofence)
    }

    /// The due date as the calendar day it names, formatted in UTC so it is the same day in every
    /// zone — or, for a timed due, the local date and time it is at.
    var dueDateText: String? {
        guard let dueDate else { return nil }
        if dueHasTime { return dueDate.formatted(date: .abbreviated, time: .shortened) }
        return dueDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
    }

    /// The due date as a local midnight, for a date picker: the same day, whatever the zone.
    func dueDay(in calendar: Calendar = .current) -> Date? {
        guard let dueDate else { return nil }
        // A timed due is an instant, so its day is the local one.
        if dueHasTime { return calendar.startOfDay(for: dueDate) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        return calendar.date(from: utc.dateComponents([.year, .month, .day], from: dueDate))
    }

    /// The wire form of a day picked in `calendar`: `2026-09-24T00:00:00Z`, as the web writes it.
    static func dueDateValue(for day: Date, in calendar: Calendar = .current) -> String {
        let d = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02dT00:00:00Z", d.year!, d.month!, d.day!)
    }
}

// MARK: - Tags

/// Tag rules shared by the task editor and the requests it sends.
enum TaskTags {
    /// What the server stores: trimmed, lowercase, without a leading `#`, de-duplicated and
    /// sorted (`normalize_tags` in `neutrino/src/calendar/tasks/service.rs`). Whitespace and
    /// commas separate tags, as in the web's tag field, so "#errands home" is two.
    static func normalize(_ tags: [String]) -> [String] {
        Array(Set(tags.flatMap(split))).sorted()
    }

    /// "#Errands, home" → ["errands", "home"], in the order typed.
    static func split(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { $0.drop(while: { $0 == "#" }).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Every tag on `tasks`, most used first, then alphabetically.
    static func all(in tasks: [CalendarTask]) -> [String] {
        var counts: [String: Int] = [:]
        for tag in tasks.flatMap(\.tags) { counts[tag, default: 0] += 1 }
        return counts.keys.sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
    }

    /// The tags in `known` worth offering for `query`, leaving out those already `chosen`: those
    /// starting with it first, then those containing it, each keeping `known`'s order. An empty
    /// query offers everything.
    static func suggestions(for query: String, in known: [String], excluding chosen: [String]) -> [String] {
        let q = split(query).last ?? ""
        let open = known.filter { !chosen.contains($0) }
        guard !q.isEmpty else { return open }
        return open.filter { $0.hasPrefix(q) } + open.filter { !$0.hasPrefix(q) && $0.contains(q) }
    }
}

// MARK: - Requests

/// Only the fields that are set are encoded, so a plain title is still just `{"title": …}`.
struct CreateTaskRequest: Encodable, Equatable {
    var title: String
    var notes: String?
    var dueDate: String?
    var dueHasTime: Bool?
    var startDate: String?
    var startHasTime: Bool?
    var priority: Int?
    var tags: [String]?
    var recurrenceRule: String?
    var repeatAfterCompletion: Bool?
    var estimateMinutes: Int?
    var location: String?
    var geoPlaceId: String?
    var geoLat: Double?
    var geoLng: Double?
    var geoRadiusM: Int?

    init(title: String) {
        self.title = title
    }
}

/// A field that can be left alone, set, or cleared.
///
/// The server's update reads an *absent* field as "leave it alone" and a JSON `null` as "clear
/// it", so emptying the notes has to send `null` and an untouched field has to send nothing. An
/// optional can only say one of those.
enum Patch<Value: Encodable & Equatable>: Equatable {
    case keep
    case set(Value)
    case clear
}

struct UpdateTaskRequest: Encodable, Equatable {
    var title: String?
    var notes: Patch<String> = .keep
    var done: Bool?
    var dueDate: Patch<String> = .keep
    /// Sent with a new `dueDate`: a date picked on this screen is a day, never a time.
    var dueHasTime: Bool?
    /// The zone a repeating task is stepped in when this completes it, so a 9am task comes round
    /// at 9am after a DST change. The server reads it only then.
    var timezone: String?
    /// The task's whole tag set, replacing the old one; absent leaves the tags alone.
    var tags: [String]?
    var location: Patch<String> = .keep
    /// Setting one kind of geofence clears the other; see `setGeofence`.
    var geoPlaceId: Patch<String> = .keep
    var geoLat: Patch<Double> = .keep
    var geoLng: Patch<Double> = .keep
    var geoRadiusM: Patch<Int> = .keep

    /// Sets, replaces or clears the task's arrival geofence. All four fields are sent, so a saved
    /// place replacing a point clears the point and the other way round.
    mutating func setGeofence(_ geofence: TaskGeofence?) {
        switch geofence {
        case .place(let id)?:
            geoPlaceId = .set(id)
            geoLat = .clear; geoLng = .clear; geoRadiusM = .clear
        case .point(let point)?:
            geoPlaceId = .clear
            geoLat = .set(point.latitude); geoLng = .set(point.longitude); geoRadiusM = .set(point.radius)
        case nil:
            geoPlaceId = .clear
            geoLat = .clear; geoLng = .clear; geoRadiusM = .clear
        }
    }

    private enum CodingKeys: String, CodingKey {
        case title, notes, done, dueDate, dueHasTime, timezone, tags
        case location, geoPlaceId, geoLat, geoLng, geoRadiusM
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(done, forKey: .done)
        try c.encodeIfPresent(dueHasTime, forKey: .dueHasTime)
        try c.encodeIfPresent(timezone, forKey: .timezone)
        try c.encodeIfPresent(tags, forKey: .tags)
        try c.encode(notes, forKey: .notes)
        try c.encode(dueDate, forKey: .dueDate)
        try c.encode(location, forKey: .location)
        try c.encode(geoPlaceId, forKey: .geoPlaceId)
        try c.encode(geoLat, forKey: .geoLat)
        try c.encode(geoLng, forKey: .geoLng)
        try c.encode(geoRadiusM, forKey: .geoRadiusM)
    }
}

private extension KeyedEncodingContainer {
    /// Nothing for `.keep`, the value for `.set`, and a JSON `null` for `.clear`.
    mutating func encode<Value>(_ patch: Patch<Value>, forKey key: Key) throws {
        switch patch {
        case .keep:           break
        case .set(let value): try encode(value, forKey: key)
        case .clear:          try encodeNil(forKey: key)
        }
    }
}

/// The answer to completing a task: the task itself, and — for a repeating one — the task the
/// server created for its next occurrence, as `nextTask`.
struct UpdatedTask: Decodable {
    let task: CalendarTask
    let nextTask: CalendarTask?

    private enum CodingKeys: String, CodingKey { case nextTask }

    init(from decoder: Decoder) throws {
        task = try CalendarTask(from: decoder)
        nextTask = try decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent(CalendarTask.self, forKey: .nextTask)
    }
}

struct ReorderTasksRequest: Encodable, Equatable {
    let taskIds: [String]
}

/// Puts a task on the calendar, or moves the event it is already on.
struct ScheduleTaskRequest: Encodable, Equatable {
    let startTime: String
    let endTime: String
    let allDay: Bool
    let timezone: String?

    /// The web's shapes: an all-day slot is dates, `T00:00:00Z` to `T23:59:59Z` on the last day,
    /// as an all-day event is everywhere; a timed one is two instants and the zone it was set in.
    init(start: Date, end: Date, allDay: Bool, timeZone: TimeZone = .current) {
        if allDay {
            var local = Calendar(identifier: .gregorian)
            local.timeZone = timeZone
            func day(_ date: Date) -> String {
                let d = local.dateComponents([.year, .month, .day], from: date)
                return String(format: "%04d-%02d-%02d", d.year!, d.month!, d.day!)
            }
            startTime = "\(day(start))T00:00:00Z"
            endTime = "\(day(end))T23:59:59Z"
            timezone = nil
        } else {
            startTime = ServerDate.format(start)
            endTime = ServerDate.format(end)
            timezone = timeZone.identifier
        }
        self.allDay = allDay
    }
}
