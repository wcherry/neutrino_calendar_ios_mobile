import Foundation

// MARK: - RecurrenceScope

/// Which occurrences of a repeating event or reminder an edit or delete is for, as Google and
/// Outlook ask. See `neutrino/agent_docs/recurrence-exceptions.md`.
///
/// A repeating reminder is one row at its next occurrence, earlier ones gone once completed, so
/// for a reminder `.following` does what `.all` does. It is offered anyway, so reminders read like
/// events.
enum RecurrenceScope: String, CaseIterable, Identifiable {
    case this, following, all

    var id: Self { self }

    /// "This Event", "This and Following Events", "All Events".
    func label(_ kind: Kind) -> String {
        switch self {
        case .this:      return "This \(kind.noun)"
        case .following: return "This and Following \(kind.noun)s"
        case .all:       return "All \(kind.noun)s"
        }
    }

    enum Kind {
        case event, reminder

        var noun: String { self == .event ? "Event" : "Reminder" }
    }
}

// MARK: - Requests

/// "This and following": `POST /events/{id}/split`. The new series' changes from the occurrence,
/// flattened beside the occurrence's start as the server reads them.
struct SplitEventRequest: Encodable, Equatable {
    let originalStartTime: String
    let changes: UpdateEventRequest

    private enum CodingKeys: String, CodingKey { case originalStartTime }

    func encode(to encoder: Encoder) throws {
        try changes.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(originalStartTime, forKey: .originalStartTime)
    }
}

/// "Delete this reminder" for a repeating one: `POST /reminders/{id}/skip`.
struct SkipReminderRequest: Encodable, Equatable {
    let timezone: String
}

struct SkipReminderResponse: Decodable {
    /// The reminder at its next occurrence, or nil once its rule ran out and it was deleted.
    let series: Reminder?
}

/// "Edit this reminder" for a repeating one: `POST /reminders/{id}/occurrence`.
struct ReminderOccurrenceRequest: Encodable, Equatable {
    var title: String?
    var dueTime: String?
    let timezone: String
}

struct ReminderOccurrenceResponse: Decodable {
    /// The one-off reminder the occurrence became.
    let reminder: Reminder
    /// The repeating reminder at its next occurrence, or nil once its rule ran out.
    let series: Reminder?
}
