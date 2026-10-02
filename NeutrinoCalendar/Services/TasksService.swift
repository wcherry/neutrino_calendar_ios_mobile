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
    /// Where an edit or completion goes when the server can't be reached.
    var pending: PendingWrites?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoCalendar",
                                category: "TasksService")

    init(client: CalendarAPIClient) {
        self.client = client
    }

    var open: [CalendarTask] { tasks.filter { !$0.done } }
    var done: [CalendarTask] { tasks.filter(\.done) }

    func task(id: String) -> CalendarTask? { tasks.first { $0.id == id } }

    /// Every tag in use, most used first: what the task editor offers as the user types.
    var allTags: [String] { TaskTags.all(in: tasks) }

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
        try await create(CreateTaskRequest(title: title))
    }

    /// Creates the task a Smart Add line describes: "Buy milk ^tomorrow #errands !1".
    @discardableResult
    func create(_ parsed: SmartAddResult, calendar: Calendar = .current) async throws -> CalendarTask {
        try await create(SmartAdd.request(for: parsed, calendar: calendar))
    }

    @discardableResult
    func create(_ request: CreateTaskRequest) async throws -> CalendarTask {
        let created = try await client.createTask(request)
        tasks.append(created)
        return created
    }

    /// Completing a repeating task leaves it done and the server creates the next occurrence as a
    /// new task, which is added to the list here rather than waiting for a reload.
    func setDone(_ task: CalendarTask, _ done: Bool, timeZone: TimeZone = .current) async {
        let request = UpdateTaskRequest(done: done, timezone: timeZone.identifier)
        do {
            let result = try await client.updateTaskReportingNext(id: task.id, request)
            replace(result.task)
            if let next = result.nextTask { replace(next) }
        } catch let error as CalendarAPIError where error.isNetwork && pending != nil {
            // The next occurrence of a repeating task arrives with the reload after the replay.
            pending?.enqueue(PendingWrite(method: "PATCH", path: Self.path(task), json: request))
            replace(task.with(done: done))
        } catch {
            logger.error("setDone failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    /// Saves the task row. Only what changed is sent, and a field emptied is sent as a clear.
    /// `tags` is the whole new tag set; nil leaves the tags alone. `geofence` and `location` are
    /// the same: nil leaves them alone, `.some(nil)` clears them.
    ///
    /// Unless `overwrite`, the save stops with `EditConflict` when the task was deleted, or one of
    /// the same fields changed, somewhere else since `task` was read. Offline, it is queued.
    @discardableResult
    func update(_ task: CalendarTask, title: String, notes: String, dueDay: Date?, tags: [String]? = nil,
                geofence: TaskGeofence?? = nil, location: String?? = nil,
                calendar: Calendar = .current, overwrite: Bool = false) async throws -> CalendarTask {
        let request = Self.request(from: task, title: title, notes: notes, dueDay: dueDay, tags: tags,
                                   geofence: geofence, location: location, calendar: calendar)
        guard request != UpdateTaskRequest() else { return task }
        do {
            if !overwrite {
                // There is no single-task read; the list is small.
                guard let current = try await client.tasks().first(where: { $0.id == task.id }) else {
                    tasks.removeAll { $0.id == task.id }
                    throw EditConflict.deletedElsewhere
                }
                let theirs = Self.request(from: task, title: current.title, notes: current.notes ?? "",
                                          dueDay: current.dueDay(in: calendar),
                                          tags: tags == nil ? nil : current.tags,
                                          geofence: geofence == nil ? nil : .some(current.geofence),
                                          location: location == nil ? nil : .some(current.location),
                                          calendar: calendar)
                let clashes = EditConflict.clashes(mine: request, theirs: theirs)
                if !clashes.isEmpty { throw EditConflict.changedElsewhere(clashes) }
            }
            let updated = try await client.updateTask(id: task.id, request)
            replace(updated)
            return updated
        } catch let error as CalendarAPIError where error.isNetwork && pending != nil {
            pending?.enqueue(PendingWrite(method: "PATCH", path: Self.path(task), json: request))
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let local = task.with(title: title, notes: .some(trimmedNotes.isEmpty ? nil : trimmedNotes),
                                  dueDate: .some(dueDay.flatMap { ServerDate.parse(CalendarTask.dueDateValue(for: $0, in: calendar)) }),
                                  dueHasTime: request.dueHasTime, tags: request.tags,
                                  location: request.location == .keep ? nil : .some(location ?? nil),
                                  geofence: request.geoPlaceId == .keep ? nil : .some(geofence ?? nil))
            replace(local)
            return local
        }
    }

    /// Attaches, replaces or removes the task's arrival geofence, and sets the text shown for it
    /// to `location` when one is given. What Smart Add's confirmation sends; the editor goes
    /// through `update`.
    @discardableResult
    func setGeofence(_ task: CalendarTask, _ geofence: TaskGeofence?, location: String? = nil) async throws -> CalendarTask {
        var request = UpdateTaskRequest()
        request.setGeofence(geofence)
        if let location, location != task.location { request.location = .set(location) }
        do {
            let updated = try await client.updateTask(id: task.id, request)
            replace(updated)
            return updated
        } catch let error as CalendarAPIError where error.isNetwork && pending != nil {
            pending?.enqueue(PendingWrite(method: "PATCH", path: Self.path(task), json: request))
            let local = task.with(location: location.map { .some($0) }, geofence: .some(geofence))
            replace(local)
            return local
        }
    }

    /// Takes a deleted saved place off the tasks that used it, as the server just did, so the
    /// list and the region planner don't wait for a reload.
    func forgetPlace(id: String) {
        for task in tasks where task.geofence == .place(id: id) {
            replace(task.with(geofence: .some(nil)))
        }
    }

    /// The fields that differ between `task` and the values given: an edit's request, or, given
    /// the server's current values, what was changed elsewhere.
    static func request(from task: CalendarTask, title: String, notes: String, dueDay: Date?,
                        tags: [String]? = nil, geofence: TaskGeofence?? = nil, location: String?? = nil,
                        calendar: Calendar) -> UpdateTaskRequest {
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
            // A day picked here is a day: a due time set by Smart Add goes with the old date.
            if newDue != nil && task.dueHasTime { request.dueHasTime = false }
        }
        if let tags {
            let newTags = TaskTags.normalize(tags)
            if newTags != TaskTags.normalize(task.tags) { request.tags = newTags }
        }
        if let geofence, geofence != task.geofence { request.setGeofence(geofence) }
        if let location {
            let trimmed = location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed != (task.location ?? "") { request.location = trimmed.isEmpty ? .clear : .set(trimmed) }
        }
        return request
    }

    private static func path(_ task: CalendarTask) -> String { "/api/v1/calendar/tasks/\(task.id)" }

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

    /// The attachments of the task with `taskID`, for `AttachmentsSection`.
    func attachmentOwner(taskID: String) -> AttachmentOwner {
        AttachmentOwner(id: "task-\(taskID)",
                        load: { try await self.client.taskAttachments(taskID: taskID) },
                        add: { try await self.client.addTaskAttachment(taskID: taskID, $0) },
                        delete: { try await self.client.deleteTaskAttachment(taskID: taskID, attachmentID: $0.id) })
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
