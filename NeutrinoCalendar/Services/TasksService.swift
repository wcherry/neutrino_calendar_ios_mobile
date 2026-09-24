import Foundation
import os.log

/// Every task the user has, in the order they arranged them, and the changes made to them.
///
/// Like `RemindersService`, the server's answer to each change replaces the local copy: what the
/// server stored is what the list shows, including the `eventId` scheduling sets or clears.
@MainActor
final class TasksService: ObservableObject {

    /// All tasks, open and done, in the server's order.
    @Published private(set) var tasks: [CalendarTask] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published var error: String?

    private let client: CalendarAPIClient
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoCalendar",
                                category: "TasksService")

    init(client: CalendarAPIClient) {
        self.client = client
    }

    var open: [CalendarTask] { tasks.filter { !$0.done } }
    var done: [CalendarTask] { tasks.filter(\.done) }

    func task(id: String) -> CalendarTask? { tasks.first { $0.id == id } }

    // MARK: - Loading

    func reload() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            // In the server's order, not re-sorted: it orders by position and then by creation,
            // and tasks made without a position all share 0, so a client-side tie-break would
            // show a different order from the web's.
            tasks = try await client.tasks()
            hasLoaded = true
        } catch {
            logger.error("reload failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    func reset() {
        tasks = []
        hasLoaded = false
        error = nil
        isLoading = false
    }

    // MARK: - Changes

    @discardableResult
    func create(title: String) async throws -> CalendarTask {
        let created = try await client.createTask(CreateTaskRequest(title: title))
        tasks.append(created)
        return created
    }

    func setDone(_ task: CalendarTask, _ done: Bool) async {
        do {
            replace(try await client.updateTask(id: task.id, UpdateTaskRequest(done: done)))
        } catch {
            logger.error("setDone failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    /// Saves the task row. Only what changed is sent, and a field emptied is sent as a clear.
    @discardableResult
    func update(_ task: CalendarTask, title: String, notes: String, dueDay: Date?,
                calendar: Calendar = .current) async throws -> CalendarTask {
        var request = UpdateTaskRequest()
        if title != task.title { request.title = title }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedNotes != (task.notes ?? "") {
            request.notes = trimmedNotes.isEmpty ? .clear : .set(trimmedNotes)
        }
        let newDue = dueDay.map { CalendarTask.dueDateValue(for: $0, in: calendar) }
        let oldDue = task.dueDay(in: calendar).map { CalendarTask.dueDateValue(for: $0, in: calendar) }
        if newDue != oldDue {
            request.dueDate = newDue.map(Patch.set) ?? .clear
        }
        guard request != UpdateTaskRequest() else { return task }
        let updated = try await client.updateTask(id: task.id, request)
        replace(updated)
        return updated
    }

    /// Moves open tasks. `ids` is the new order of the open tasks only, as the web sends it; done
    /// tasks keep their positions and stay listed after the open ones.
    ///
    /// Applied locally first, so the row stays where it was dropped, and not rolled back on
    /// failure: the next reload reconciles with the server, as on the web.
    func reorderOpen(to ids: [String]) async {
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let reordered = ids.compactMap { byID[$0] }
        tasks = reordered + tasks.filter { !ids.contains($0.id) }
        do {
            try await client.reorderTasks(ids: ids)
        } catch {
            logger.error("reorder failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    /// Puts a task on the calendar at `start`–`end`, or moves it there if it is already on it.
    func schedule(_ task: CalendarTask, start: Date, end: Date, allDay: Bool) async throws {
        let event = try await client.scheduleTask(id: task.id,
                                                  ScheduleTaskRequest(start: start, end: end, allDay: allDay))
        if task.eventId != event.id {
            // The schedule endpoint answers with the event, not the task, so the task is re-read
            // for its new `eventId` rather than guessed at.
            await refresh(task)
        }
    }

    func unschedule(_ task: CalendarTask) async throws {
        replace(try await client.unscheduleTask(id: task.id))
    }

    func event(for task: CalendarTask) async throws -> CalendarEvent? {
        guard let id = task.eventId else { return nil }
        return try await client.event(id: id)
    }

    // MARK: - Attachments

    func attachments(for task: CalendarTask) async throws -> [TaskAttachment] {
        try await client.taskAttachments(taskID: task.id)
    }

    func addNote(_ note: String, to task: CalendarTask) async throws -> TaskAttachment {
        try await client.addTaskNote(taskID: task.id, note: note)
    }

    func deleteAttachment(_ attachment: TaskAttachment, from task: CalendarTask) async throws {
        try await client.deleteTaskAttachment(taskID: task.id, attachmentID: attachment.id)
    }

    // MARK: - Helpers

    private func refresh(_ task: CalendarTask) async {
        if let fresh = try? await client.tasks().first(where: { $0.id == task.id }) {
            replace(fresh)
        }
    }

    private func replace(_ updated: CalendarTask) {
        if let index = tasks.firstIndex(where: { $0.id == updated.id }) {
            tasks[index] = updated
        } else {
            tasks.append(updated)
        }
    }
}
