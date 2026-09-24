import Foundation

// MARK: - Reminder

/// One row of `GET /api/v1/calendar/reminders` (`ReminderResponse` in
/// `neutrino/src/calendar/reminders/dto.rs`).
///
/// A reminder belongs to at most one thing, an event or a task, and only at creation: the server's
/// update has no link fields, so a link can't be added, changed or removed later.
struct Reminder: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let due: Date
    let completed: Bool
    /// An RRULE body. Completing a reminder that has one moves it to its next occurrence on the
    /// server, rather than marking it done.
    let recurrenceRule: String?
    let linkedEventId: String?
    let linkedTaskId: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, dueTime, completed, recurrenceRule, linkedEventId, linkedTaskId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        let raw = try c.decode(String.self, forKey: .dueTime)
        guard let due = ServerDate.parse(raw) else {
            throw DecodingError.dataCorruptedError(forKey: .dueTime, in: c,
                                                   debugDescription: "Not an ISO 8601 instant: \(raw)")
        }
        self.due = due
        completed = try c.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        // The server stores an empty rule for a reminder whose rule was cleared before it learnt
        // to store NULL; both mean "doesn't repeat".
        recurrenceRule = try c.decodeIfPresent(String.self, forKey: .recurrenceRule).flatMap { $0.isEmpty ? nil : $0 }
        linkedEventId = try c.decodeIfPresent(String.self, forKey: .linkedEventId)
        linkedTaskId = try c.decodeIfPresent(String.self, forKey: .linkedTaskId)
    }

    /// For tests and previews.
    init(id: String, title: String, due: Date, completed: Bool = false, recurrenceRule: String? = nil,
         linkedEventId: String? = nil, linkedTaskId: String? = nil) {
        self.id = id
        self.title = title
        self.due = due
        self.completed = completed
        self.recurrenceRule = recurrenceRule
        self.linkedEventId = linkedEventId
        self.linkedTaskId = linkedTaskId
    }

    func isOverdue(now: Date = Date()) -> Bool { !completed && due < now }
}

struct ListRemindersResponse: Decodable {
    let reminders: [Reminder]
}

struct CreateReminderRequest: Encodable, Equatable {
    let title: String
    let dueTime: String
    let recurrenceRule: String?
    let linkedEventId: String?
    let linkedTaskId: String?
}

/// Only the fields being changed are sent; `nil` leaves a field alone.
struct UpdateReminderRequest: Encodable, Equatable {
    var title: String?
    var dueTime: String?
    var completed: Bool?
    /// An empty string removes the rule.
    var recurrenceRule: String?
    /// The zone the server steps a recurrence in when this completes it.
    var timezone: String?
}

// MARK: - CalendarTask

/// The part of `GET /api/v1/calendar/tasks` a reminder needs: enough to pick a task to link to and
/// to name it afterwards. Tasks proper are Epic 13.
struct CalendarTask: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let done: Bool
}

// MARK: - ReminderRange

/// The web's reminder filter (`REMINDER_RANGES` in `calendarHelpers.ts`).
///
/// A range is an upper bound only: a reminder that came due yesterday is still something to deal
/// with today, so an overdue reminder is in every range. A range ends at the end of its last day in
/// the device's zone, counting today as the first day, so "7 days" on a Monday runs to Sunday.
enum ReminderRange: String, CaseIterable, Identifiable {
    case today, threeDays, sevenDays, all

    var id: Self { self }

    var label: String {
        switch self {
        case .today:     return "Today"
        case .threeDays: return "3 days"
        case .sevenDays: return "7 days"
        case .all:       return "All"
        }
    }

    private var days: Int? {
        switch self {
        case .today:     return 1
        case .threeDays: return 3
        case .sevenDays: return 7
        case .all:       return nil
        }
    }

    /// The last instant the range includes, or `nil` for `.all`.
    func end(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard let days else { return nil }
        // `setHours(23, 59, 59, 999)`: the last millisecond of the last day.
        let dayAfter = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))!
        return dayAfter.addingTimeInterval(-0.001)
    }

    func contains(_ reminder: Reminder, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let end = end(now: now, calendar: calendar) else { return true }
        return reminder.due <= end
    }
}

// MARK: - RepeatOption

/// The repeat choices offered when editing a reminder, each an RRULE the web and the server both
/// read. A rule written elsewhere that isn't one of these is kept as `.custom` and saved back
/// untouched, so opening and saving a reminder never rewrites its rule.
enum RepeatOption: Hashable, Identifiable {
    case never, daily, weekdays, weekly, monthly, yearly
    case custom(String)

    static let standard: [RepeatOption] = [.never, .daily, .weekdays, .weekly, .monthly, .yearly]

    init(rule: String?) {
        switch rule {
        case nil, "":                                   self = .never
        case "FREQ=DAILY":                              self = .daily
        case "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR":        self = .weekdays
        case "FREQ=WEEKLY":                             self = .weekly
        case "FREQ=MONTHLY":                            self = .monthly
        case "FREQ=YEARLY":                             self = .yearly
        case let other?:                                self = .custom(other)
        }
    }

    var id: String { rule ?? "never" }

    /// The rule to store, `nil` for never. The web editor writes these same strings.
    var rule: String? {
        switch self {
        case .never:             return nil
        case .daily:             return "FREQ=DAILY"
        case .weekdays:          return "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
        case .weekly:            return "FREQ=WEEKLY"
        case .monthly:           return "FREQ=MONTHLY"
        case .yearly:            return "FREQ=YEARLY"
        case .custom(let rule):  return rule
        }
    }

    var label: String {
        switch self {
        case .never:    return "Never"
        case .daily:    return "Every Day"
        case .weekdays: return "Every Weekday"
        case .weekly:   return "Every Week"
        case .monthly:  return "Every Month"
        case .yearly:   return "Every Year"
        case .custom(let rule): return EventFormatting.recurrenceSummary(rule)
        }
    }
}

// MARK: - ReminderPreset

/// "10 minutes before" and friends, for a reminder on an event: the web's `REMINDER_PRESETS`.
struct ReminderPreset: Identifiable, Hashable {
    let label: String
    let minutes: Int

    var id: Int { minutes }

    static let all: [ReminderPreset] = [
        .init(label: "At time of event", minutes: 0),
        .init(label: "5 minutes before", minutes: 5),
        .init(label: "10 minutes before", minutes: 10),
        .init(label: "15 minutes before", minutes: 15),
        .init(label: "30 minutes before", minutes: 30),
        .init(label: "1 hour before", minutes: 60),
        .init(label: "2 hours before", minutes: 120),
        .init(label: "1 day before", minutes: 1440),
        .init(label: "2 days before", minutes: 2880),
        .init(label: "1 week before", minutes: 10080),
    ]
}
