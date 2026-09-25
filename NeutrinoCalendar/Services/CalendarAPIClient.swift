import Foundation
import os.log
import NeutrinoCore
import NeutrinoAuth

// MARK: - CalendarAPIError

enum CalendarAPIError: LocalizedError, Equatable {
    case notAuthenticated
    case networkError(String)
    case serverError(statusCode: Int)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:           return "You are not signed in."
        case .networkError:               return "A network error occurred. Please check your connection."
        case .serverError(let code):      return "Server error (\(code))."
        case .decodingError:              return "The server sent something this version of Calendar can't read."
        }
    }
}

// MARK: - CalendarAPIClient

/// Authorized requests to `/api/v1/calendar`.
///
/// Shaped like the Notes app's service helpers: refresh the token if it is about to expire, attach
/// it, send, and map anything outside 2xx onto one error type. The session and the token source
/// are injected so tests can run against `MockURLProtocol` without a Keychain.
@MainActor
final class CalendarAPIClient {

    private let session: URLSession
    private let baseURL: () -> String
    private let token: () async -> String?
    private let onUnauthorized: () -> Void

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoCalendar",
                                category: "CalendarAPIClient")

    init(session: URLSession = .shared,
         baseURL: @escaping () -> String = { NeutrinoStorage.serverHost },
         token: @escaping () async -> String?,
         onUnauthorized: @escaping () -> Void = {}) {
        self.session = session
        self.baseURL = baseURL
        self.token = token
        self.onUnauthorized = onUnauthorized
    }

    /// The client the app uses: the configured server, and `authService`'s token, refreshed first.
    ///
    /// A 401 signs the user out, as `AuthService.loadProfile` does. The token was refreshed just
    /// before the request, so a rejection means the session is over, not stale. It also covers a
    /// reinstall: iOS keeps an app's Keychain items when the app is deleted but not its
    /// UserDefaults, so a reinstalled app can wake up holding a token for one server while
    /// pointed at another. Without this it would look signed in and fail every request.
    convenience init(authService: AuthService) {
        self.init(token: { [weak authService] in
            guard let authService else { return nil }
            await authService.refreshTokenIfNeeded()
            return authService.accessToken()
        }, onUnauthorized: { [weak authService] in
            authService?.logout()
        })
    }

    // MARK: - Endpoints

    /// Events overlapping `[from, to]`, plus every recurring event that starts by `to` — the
    /// server returns recurring masters whatever their end, since their later occurrences may fall
    /// in the range. Expansion is the caller's job.
    func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        let response: ListEventsResponse = try await get("/api/v1/calendar/events", query: [
            URLQueryItem(name: "from", value: ServerDate.format(from)),
            URLQueryItem(name: "to", value: ServerDate.format(to)),
        ])
        return response.events
    }

    func attachments(forEvent eventID: String) async throws -> [EventAttachment] {
        let response: ListAttachmentsResponse = try await get("/api/v1/calendar/events/\(eventID)/attachments")
        return response.attachments
    }

    /// Every reminder the user has, linked or not. The server can filter by `eventId` or `taskId`,
    /// but one list is what the Reminders tab and the event screens both draw from.
    func reminders() async throws -> [Reminder] {
        let response: ListRemindersResponse = try await get("/api/v1/calendar/reminders")
        return response.reminders
    }

    func createReminder(_ request: CreateReminderRequest) async throws -> Reminder {
        try decode(try await send("POST", "/api/v1/calendar/reminders", body: request), path: "reminders")
    }

    /// The server's answer, not the request, is the new state: completing a recurring reminder
    /// comes back open, at its next due time.
    func updateReminder(id: String, _ request: UpdateReminderRequest) async throws -> Reminder {
        try decode(try await send("PATCH", "/api/v1/calendar/reminders/\(id)", body: request), path: "reminders/{id}")
    }

    func deleteReminder(id: String) async throws {
        _ = try await send("DELETE", "/api/v1/calendar/reminders/\(id)")
    }

    func event(id: String) async throws -> CalendarEvent {
        try await get("/api/v1/calendar/events/\(id)")
    }

    // MARK: - Tasks

    /// Every task, in `position` order. A bare array, unlike the other list endpoints.
    func tasks() async throws -> [CalendarTask] {
        try await get("/api/v1/calendar/tasks")
    }

    func createTask(_ request: CreateTaskRequest) async throws -> CalendarTask {
        try decode(try await send("POST", "/api/v1/calendar/tasks", body: request), path: "tasks")
    }

    func updateTask(id: String, _ request: UpdateTaskRequest) async throws -> CalendarTask {
        try await updateTaskReportingNext(id: id, request).task
    }

    /// `updateTask`, keeping the `nextTask` the server creates when this completes a repeating task.
    func updateTaskReportingNext(id: String, _ request: UpdateTaskRequest) async throws -> UpdatedTask {
        try decode(try await send("PATCH", "/api/v1/calendar/tasks/\(id)", body: request), path: "tasks/{id}")
    }

    /// Sets the order of the tasks named, first to last. The web sends only the open tasks, and so
    /// does this: done tasks keep whatever positions they had.
    func reorderTasks(ids: [String]) async throws {
        _ = try await send("POST", "/api/v1/calendar/tasks/reorder", body: ReorderTasksRequest(taskIds: ids))
    }

    /// Puts the task on the calendar, or moves the event it is already on; answers with the event.
    @discardableResult
    func scheduleTask(id: String, _ request: ScheduleTaskRequest) async throws -> CalendarEvent {
        try decode(try await send("POST", "/api/v1/calendar/tasks/\(id)/event", body: request),
                   path: "tasks/{id}/event")
    }

    /// Takes the task off the calendar, deleting its event; answers with the task.
    func unscheduleTask(id: String) async throws -> CalendarTask {
        try decode(try await send("DELETE", "/api/v1/calendar/tasks/\(id)/event"), path: "tasks/{id}/event")
    }

    func taskAttachments(taskID: String) async throws -> [TaskAttachment] {
        let response: ListTaskAttachmentsResponse = try await get("/api/v1/calendar/tasks/\(taskID)/attachments")
        return response.attachments
    }

    func addTaskNote(taskID: String, note: String) async throws -> TaskAttachment {
        try decode(try await send("POST", "/api/v1/calendar/tasks/\(taskID)/attachments",
                                  body: CreateTaskAttachmentRequest(note: note)),
                   path: "tasks/{id}/attachments")
    }

    func deleteTaskAttachment(taskID: String, attachmentID: String) async throws {
        _ = try await send("DELETE", "/api/v1/calendar/tasks/\(taskID)/attachments/\(attachmentID)")
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try decode(try await send("GET", path, query: query), path: path)
    }

    private func decode<T: Decodable>(_ data: Data, path: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            logger.error("decode error \(path, privacy: .public): \(error, privacy: .public)")
            throw CalendarAPIError.decodingError(String(describing: error))
        }
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [],
                      body: (any Encodable)? = nil) async throws -> Data {
        guard var components = URLComponents(string: baseURL() + path) else {
            throw CalendarAPIError.serverError(statusCode: 0)
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw CalendarAPIError.serverError(statusCode: 0) }

        guard let token = await token() else {
            logger.error("no access token; the user must sign in again")
            throw CalendarAPIError.notAuthenticated
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        logger.debug("--> \(method, privacy: .public) \(path, privacy: .public)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.error("network error \(path, privacy: .public): \(error, privacy: .public)")
            throw CalendarAPIError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CalendarAPIError.serverError(statusCode: 0)
        }
        logger.debug("<-- \(http.statusCode) \(path, privacy: .public) (\(data.count) bytes)")
        if http.statusCode == 401 {
            logger.error("401 from \(path, privacy: .public); ending the session")
            onUnauthorized()
            throw CalendarAPIError.notAuthenticated
        }
        guard (200...299).contains(http.statusCode) else {
            throw CalendarAPIError.serverError(statusCode: http.statusCode)
        }
        return data
    }
}
