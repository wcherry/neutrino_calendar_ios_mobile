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

    private enum CodingKeys: String, CodingKey {
        case id, title, notes, done, dueDate, position, eventId
        case dueHasTime, priority, tags, recurrenceRule, repeatAfterCompletion, estimateMinutes, location
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
    }

    /// For tests and previews.
    init(id: String, title: String, notes: String? = nil, done: Bool = false, dueDate: Date? = nil,
         position: Int = 0, eventId: String? = nil, dueHasTime: Bool = false, priority: Int? = nil,
         tags: [String] = [], recurrenceRule: String? = nil, repeatAfterCompletion: Bool = false,
         estimateMinutes: Int? = nil, location: String? = nil) {
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

    private enum CodingKeys: String, CodingKey { case title, notes, done, dueDate, dueHasTime, timezone }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(done, forKey: .done)
        try c.encodeIfPresent(dueHasTime, forKey: .dueHasTime)
        try c.encodeIfPresent(timezone, forKey: .timezone)
        for (patch, key) in [(notes, CodingKeys.notes), (dueDate, CodingKeys.dueDate)] {
            switch patch {
            case .keep:           break
            case .set(let value): try c.encode(value, forKey: key)
            case .clear:          try c.encodeNil(forKey: key)
            }
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

// MARK: - Attachments

/// One row of `GET /api/v1/calendar/tasks/{id}/attachments`: a Drive file or an inline note.
struct TaskAttachment: Decodable, Identifiable, Hashable {
    let id: String
    let fileId: String?
    let name: String?
    let note: String?
}

struct ListTaskAttachmentsResponse: Decodable {
    let attachments: [TaskAttachment]
}

struct CreateTaskAttachmentRequest: Encodable, Equatable {
    let note: String
}
