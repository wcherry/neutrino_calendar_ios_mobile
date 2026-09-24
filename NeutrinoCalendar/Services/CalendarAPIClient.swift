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

/// Authorized reads from `/api/v1/calendar`.
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

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
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
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        logger.debug("--> GET \(path, privacy: .public)")
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
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            logger.error("decode error \(path, privacy: .public): \(error, privacy: .public)")
            throw CalendarAPIError.decodingError(String(describing: error))
        }
    }
}
