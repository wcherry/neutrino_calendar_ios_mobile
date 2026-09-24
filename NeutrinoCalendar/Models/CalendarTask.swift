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

    private enum CodingKeys: String, CodingKey {
        case id, title, notes, done, dueDate, position, eventId
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
    }

    /// For tests and previews.
    init(id: String, title: String, notes: String? = nil, done: Bool = false, dueDate: Date? = nil,
         position: Int = 0, eventId: String? = nil) {
        self.id = id
        self.title = title
        self.notes = notes
        self.done = done
        self.dueDate = dueDate
        self.position = position
        self.eventId = eventId
    }

    /// The due date as the calendar day it names, formatted in UTC so it is the same day in every
    /// zone.
    var dueDateText: String? {
        dueDate?.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
    }

    /// The due date as a local midnight, for a date picker: the same day, whatever the zone.
    func dueDay(in calendar: Calendar = .current) -> Date? {
        guard let dueDate else { return nil }
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

struct CreateTaskRequest: Encodable, Equatable {
    let title: String
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

    private enum CodingKeys: String, CodingKey { case title, notes, done, dueDate }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(done, forKey: .done)
        for (patch, key) in [(notes, CodingKeys.notes), (dueDate, CodingKeys.dueDate)] {
            switch patch {
            case .keep:           break
            case .set(let value): try c.encode(value, forKey: key)
            case .clear:          try c.encodeNil(forKey: key)
            }
        }
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
