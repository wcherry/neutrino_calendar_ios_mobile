import Foundation

/// Which reminders get a local notification, and what has to change among those already
/// scheduled. Pure, so the rules are testable without a notification center.
///
/// The server can't push yet (its reminder engine only logs), so the device is the alarm: every
/// open reminder due in the future is scheduled here, event alerts included, since an event's
/// alert is a reminder linked to it.
enum NotificationPlan {

    /// iOS keeps at most 64 pending notifications per app. The nearest 60 are scheduled, leaving
    /// room for snoozes, and the rest are picked up as the nearer ones fire and the plan is made
    /// again.
    static let limit = 60

    /// Every identifier this app schedules starts with one of these, so a plan never touches a
    /// notification it didn't make.
    static let reminderPrefix = "reminder."
    static let snoozePrefix = "snooze."

    struct Alert: Equatable {
        let identifier: String
        let reminderID: String
        let fireDate: Date
        let title: String
    }

    /// The identifier carries the due time, so a reminder moved to another time is a different
    /// notification: the old one is removed and the new one added, rather than left at the old
    /// time.
    static func identifier(reminderID: String, due: Date) -> String {
        "\(reminderPrefix)\(reminderID).\(Int(due.timeIntervalSince1970))"
    }

    /// Open reminders due after `now`, soonest first, at most `limit`.
    static func plan(_ reminders: [Reminder], now: Date, limit: Int = limit) -> [Alert] {
        reminders
            .filter { !$0.completed && $0.due > now }
            .sorted { $0.due < $1.due }
            .prefix(limit)
            .map { Alert(identifier: identifier(reminderID: $0.id, due: $0.due),
                         reminderID: $0.id, fireDate: $0.due, title: $0.title) }
    }

    /// What to add and what to remove, given the identifiers already pending. Only reminder
    /// notifications are considered: a snooze stays until it fires.
    static func changes(pending: [String], planned: [Alert]) -> (add: [Alert], remove: [String]) {
        let ours = Set(pending.filter { $0.hasPrefix(reminderPrefix) })
        let wanted = Set(planned.map(\.identifier))
        return (planned.filter { !ours.contains($0.identifier) },
                ours.subtracting(wanted).sorted())
    }
}
