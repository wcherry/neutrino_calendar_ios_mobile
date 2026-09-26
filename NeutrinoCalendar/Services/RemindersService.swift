import Foundation
import os.log

/// Every reminder the user has, and the changes made to them.
///
/// One list serves the Reminders tab and the event screens alike, so ticking a reminder off in
/// one place is ticked off in the other. After every change the server's answer replaces the
/// local copy rather than the change being applied locally: completing a recurring reminder comes
/// back open, at its next due time, and only the server knows which.
@MainActor
final class RemindersService: ObservableObject {

    @Published private(set) var reminders: [Reminder] = []
    /// Titles of the tasks reminders are linked to, keyed by task id, for labelling them.
    @Published private(set) var taskTitles: [String: String] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published var error: String?

    private let client: CalendarAPIClient
    private let timeZone: () -> TimeZone
    /// Where an edit, completion or delete goes when the server can't be reached.
    var pending: PendingWrites?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoCalendar",
                                category: "RemindersService")

    init(client: CalendarAPIClient, timeZone: @escaping () -> TimeZone = { .current }) {
        self.client = client
        self.timeZone = timeZone
    }

    // MARK: - Queries

    func reminders(forEvent eventID: String) -> [Reminder] {
        reminders.filter { $0.linkedEventId == eventID }.sorted(by: Self.byDue)
    }

    func reminders(forTask taskID: String) -> [Reminder] {
        reminders.filter { $0.linkedTaskId == taskID }.sorted(by: Self.byDue)
    }

    /// What the Reminders tab shows: open reminders first, soonest due first, then completed ones.
    ///
    /// Unlike the web's sidebar, which lists only unlinked reminders because an event's own appear
    /// in its detail panel, this includes linked ones. On a phone this list is where "what do I
    /// need to be reminded of" gets answered, and a reminder about a meeting is one of those.
    func visible(in range: ReminderRange, matching search: String = "",
                 now: Date = Date(), calendar: Calendar = .current) -> (open: [Reminder], done: [Reminder]) {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = reminders.filter {
            range.contains($0, now: now, calendar: calendar)
                && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))
        }
        return (shown.filter { !$0.completed }.sorted(by: Self.byDue),
                shown.filter(\.completed).sorted(by: Self.byDue))
    }

    /// How many open reminders a range is holding back, so an empty list can say why.
    func hiddenCount(by range: ReminderRange, now: Date = Date(), calendar: Calendar = .current) -> Int {
        reminders.filter { !$0.completed && !range.contains($0, now: now, calendar: calendar) }.count
    }

    private static func byDue(_ a: Reminder, _ b: Reminder) -> Bool {
        a.due != b.due ? a.due < b.due : a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    // MARK: - Loading

    func reload() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let loaded = try await client.reminders()
            // Loaded before the list is published: whatever reacts to the list (the notification
            // plan) checks this, and would otherwise see the first load as not loaded yet.
            hasLoaded = true
            reminders = loaded
        } catch {
            logger.error("reload failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
            return
        }
        // Task titles only label linked reminders; failing to get them is not worth an error.
        if reminders.contains(where: { $0.linkedTaskId != nil }),
           let tasks = try? await client.tasks() {
            taskTitles = Dictionary(tasks.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        }
    }

    func tasks() async throws -> [CalendarTask] {
        try await client.tasks()
    }

    /// Forgets everything, for sign-out.
    func reset() {
        reminders = []
        taskTitles = [:]
        hasLoaded = false
        error = nil
        isLoading = false
    }

    // MARK: - Changes

    @discardableResult
    func create(title: String, due: Date, rule: String?, eventID: String? = nil,
                task: CalendarTask? = nil) async throws -> Reminder {
        let created = try await client.createReminder(CreateReminderRequest(
            title: title, dueTime: ServerDate.format(due), recurrenceRule: rule,
            linkedEventId: eventID, linkedTaskId: task?.id
        ))
        reminders.append(created)
        if let task { taskTitles[task.id] = task.title }
        return created
    }

    /// Saves an edit. Only what changed is sent, so an edit never overwrites a field someone else
    /// changed on another device in the meantime, and unless `overwrite`, the save stops with
    /// `EditConflict` when someone changed one of the *same* fields. Offline, it is queued.
    func update(_ reminder: Reminder, title: String, due: Date, rule: String?,
                overwrite: Bool = false) async throws {
        let request = Self.request(from: reminder, title: title, due: due, rule: rule)
        guard request != UpdateReminderRequest() else { return }
        do {
            if !overwrite {
                let current: Reminder
                do {
                    current = try await client.reminder(id: reminder.id)
                } catch let error as CalendarAPIError where error.isNotFound {
                    reminders.removeAll { $0.id == reminder.id }
                    throw EditConflict.deletedElsewhere
                }
                let theirs = Self.request(from: reminder, title: current.title, due: current.due,
                                          rule: current.recurrenceRule)
                let clashes = EditConflict.clashes(mine: request, theirs: theirs)
                if !clashes.isEmpty { throw EditConflict.changedElsewhere(clashes) }
            }
            replace(try await client.updateReminder(id: reminder.id, request))
        } catch let error as CalendarAPIError where error.isNetwork && pending != nil {
            pending?.enqueue(PendingWrite(method: "PATCH", path: Self.path(reminder), json: request))
            replace(Reminder(id: reminder.id, title: title, due: due, completed: reminder.completed,
                             recurrenceRule: rule, linkedEventId: reminder.linkedEventId,
                             linkedTaskId: reminder.linkedTaskId))
        }
    }

    /// The fields that differ between `reminder` and the values given: an edit's request, or,
    /// given the server's current values, what was changed elsewhere.
    static func request(from reminder: Reminder, title: String, due: Date, rule: String?) -> UpdateReminderRequest {
        var request = UpdateReminderRequest()
        if title != reminder.title { request.title = title }
        if due != reminder.due { request.dueTime = ServerDate.format(due) }
        if rule != reminder.recurrenceRule { request.recurrenceRule = rule ?? "" }
        return request
    }

    private static func path(_ reminder: Reminder) -> String { "/api/v1/calendar/reminders/\(reminder.id)" }

    /// Ticks a reminder off or back on. The zone goes with a completion so the server steps a
    /// recurring reminder in local time.
    func setCompleted(_ reminder: Reminder, _ completed: Bool) async {
        do {
            let request = UpdateReminderRequest(completed: completed,
                                                timezone: completed ? timeZone().identifier : nil)
            do {
                replace(try await client.updateReminder(id: reminder.id, request))
            } catch let error as CalendarAPIError where error.isNetwork && pending != nil {
                pending?.enqueue(PendingWrite(method: "PATCH", path: Self.path(reminder), json: request))
                // A repeating one moves to its next time on the server; only a one-off can be
                // shown ticked off before then.
                if reminder.recurrenceRule == nil {
                    replace(Reminder(id: reminder.id, title: reminder.title, due: reminder.due,
                                     completed: completed, linkedEventId: reminder.linkedEventId,
                                     linkedTaskId: reminder.linkedTaskId))
                }
            }
        } catch {
            logger.error("setCompleted failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    func delete(_ reminder: Reminder) async {
        do {
            do {
                try await client.deleteReminder(id: reminder.id)
            } catch let error as CalendarAPIError where error.isNotFound {
                // Deleted elsewhere already.
            } catch let error as CalendarAPIError where error.isNetwork && pending != nil {
                pending?.enqueue(PendingWrite(method: "DELETE", path: Self.path(reminder)))
            }
            reminders.removeAll { $0.id == reminder.id }
        } catch {
            logger.error("delete failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    private func replace(_ updated: Reminder) {
        if let index = reminders.firstIndex(where: { $0.id == updated.id }) {
            reminders[index] = updated
        } else {
            reminders.append(updated)
        }
    }
}
