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
            reminders = try await client.reminders()
            hasLoaded = true
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
    /// changed on another device in the meantime.
    func update(_ reminder: Reminder, title: String, due: Date, rule: String?) async throws {
        var request = UpdateReminderRequest()
        if title != reminder.title { request.title = title }
        if due != reminder.due { request.dueTime = ServerDate.format(due) }
        if rule != reminder.recurrenceRule { request.recurrenceRule = rule ?? "" }
        guard request != UpdateReminderRequest() else { return }
        replace(try await client.updateReminder(id: reminder.id, request))
    }

    /// Ticks a reminder off or back on. The zone goes with a completion so the server steps a
    /// recurring reminder in local time.
    func setCompleted(_ reminder: Reminder, _ completed: Bool) async {
        do {
            let request = UpdateReminderRequest(completed: completed,
                                                timezone: completed ? timeZone().identifier : nil)
            replace(try await client.updateReminder(id: reminder.id, request))
        } catch {
            logger.error("setCompleted failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    func delete(_ reminder: Reminder) async {
        do {
            try await client.deleteReminder(id: reminder.id)
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
