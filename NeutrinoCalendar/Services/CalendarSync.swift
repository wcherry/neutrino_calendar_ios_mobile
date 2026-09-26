import Combine
import Foundation
import os.log
import NeutrinoCore

// MARK: - CalendarSignal

/// The server's "your calendar changed" signal, on the per-user notification socket
/// (`src/shared/drive_events/` in `neutrino`): `{"type":"calendar.changed","originClientId":…}`.
///
/// A doorbell, not a delivery: it says only that something changed, and the app pulls the
/// changes itself. The same socket carries `drive.changed` signals and inbox records, which
/// carry no `type`; both are ignored here.
enum CalendarSignal {
    static let type = "calendar.changed"

    /// Whether `text` is a calendar signal for a change some *other* client made. A signal the
    /// server attributes to no one (a batch from several clients) counts as someone else's.
    static func isRemoteChange(_ text: String, ownClientID: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == type else { return false }
        return json["originClientId"] as? String != ownClientID
    }

    /// `https://host` -> `wss://host/api/v1/drive/notifications/ws?token=…`, and `http` -> `ws`.
    static func socketURL(baseURL: String, token: String) -> URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http":  components.scheme = "ws"
        default:      return nil
        }
        components.path = "/api/v1/drive/notifications/ws"
        // Already encoded on purpose: the server slices the token out of the raw query and never
        // percent-decodes it. A JWT is base64url, so nothing in it needs escaping.
        components.percentEncodedQuery = "token=\(token)"
        return components.url
    }
}

// MARK: - CalendarSignalsClient

/// Holds the notification socket open while the app is in the foreground, and calls
/// `onRemoteChange` for each calendar signal from another client. Reconnects with backoff, and
/// calls `onReconnect` once a dropped socket is open again, since signals sent while it was
/// down are lost.
@MainActor
final class CalendarSignalsClient {

    var onRemoteChange: (() -> Void)?
    var onReconnect: (() -> Void)?

    private let token: () async -> String?
    private let baseURL: () -> String
    private var task: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    private var attempt = 0
    private var isRunning = false
    private var hasConnectedBefore = false

    private static let baseBackoff: UInt64 = 2_000_000_000     // 2s
    private static let maximumBackoff: UInt64 = 60_000_000_000 // 60s

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoCalendar",
                                category: "CalendarSignals")

    init(token: @escaping () async -> String?, baseURL: @escaping () -> String = { NeutrinoStorage.serverHost }) {
        self.token = token
        self.baseURL = baseURL
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        attempt = 0
        open()
    }

    /// Closes the socket. For leaving the foreground, where iOS would tear it down anyway, and
    /// for sign-out.
    func stop() {
        isRunning = false
        hasConnectedBefore = false
        reconnectTask?.cancel()
        reconnectTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func open() {
        Task { [weak self] in
            guard let self, self.isRunning else { return }
            guard let token = await self.token(),
                  let url = CalendarSignal.socketURL(baseURL: self.baseURL(), token: token) else {
                self.logger.error("no token or bad URL; not connecting")
                return
            }
            guard self.isRunning, self.task == nil else { return }
            let task = URLSession.shared.webSocketTask(with: url)
            self.task = task
            task.resume()
            self.receive(on: task)
            // The server sends nothing on connect, so a ping is what proves the handshake.
            task.sendPing { [weak self] error in
                Task { @MainActor in
                    guard let self, self.task === task, error == nil else { return }
                    self.attempt = 0
                    if self.hasConnectedBefore { self.onReconnect?() }
                    self.hasConnectedBefore = true
                }
            }
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message,
                       CalendarSignal.isRemoteChange(text, ownClientID: CalendarAPIClient.clientID) {
                        self.onRemoteChange?()
                    }
                    self.receive(on: task)
                case .failure(let error):
                    guard self.isRunning else { return }
                    self.logger.debug("socket closed: \(error, privacy: .public)")
                    self.task = nil
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard isRunning, reconnectTask == nil else { return }
        let delay = min(Self.baseBackoff << UInt64(min(attempt, 5)), Self.maximumBackoff)
        attempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.reconnectTask = nil
            self.open()
        }
    }
}

// MARK: - CalendarSync

/// Keeps what the app shows in step with changes made on the web and other devices, and gets
/// changes made offline to the server.
///
/// * A live signal pulls event changes (`EventsService.pullChanges`) and reloads reminders and
///   tasks, which are small whole lists.
/// * Coming back to the foreground, reconnecting, and getting back online all do the same, after
///   sending whatever writes were queued offline (`PendingWrites`).
@MainActor
final class CalendarSync: ObservableObject {

    let pending: PendingWrites
    private let client: CalendarAPIClient
    private let signals: CalendarSignalsClient
    private let events: EventsService
    private let reminders: RemindersService
    private let tasks: TasksService
    private var cancellables: Set<AnyCancellable> = []
    private var wasOnline = true
    private var isStarted = false

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoCalendar",
                                category: "CalendarSync")

    init(client: CalendarAPIClient, signals: CalendarSignalsClient, pending: PendingWrites,
         events: EventsService, reminders: RemindersService, tasks: TasksService) {
        self.client = client
        self.signals = signals
        self.pending = pending
        self.events = events
        self.reminders = reminders
        self.tasks = tasks
        events.pending = pending
        reminders.pending = pending
        tasks.pending = pending
        signals.onRemoteChange = { [weak self] in Task { await self?.refresh() } }
        signals.onReconnect = { [weak self] in Task { await self?.catchUp() } }
    }

    /// Replays queued writes whenever the network comes back.
    func observe(_ network: NetworkMonitor) {
        network.$isOnline
            .removeDuplicates()
            .sink { [weak self] online in
                guard let self else { return }
                defer { self.wasOnline = online }
                if online && !self.wasOnline { Task { await self.catchUp() } }
            }
            .store(in: &cancellables)
    }

    /// Signed in and in the foreground. Safe to call again; only the first call after a
    /// `suspend` does anything.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        signals.start()
        Task { await catchUp() }
    }

    /// Leaving the foreground.
    func suspend() {
        isStarted = false
        signals.stop()
    }

    /// Signed out: the next account must not receive this one's signals or send its edits.
    func stop() {
        suspend()
        pending.clear()
    }

    /// Sends queued writes, then brings everything up to date.
    func catchUp() async {
        if !pending.isEmpty {
            let sent = await pending.replay(using: client)
            logger.info("replayed \(sent) queued write(s), \(self.pending.writes.count) left")
            if sent > 0 {
                // The queued edits were shown locally; reload so the server's version is shown.
                events.invalidate()
            }
        }
        await refresh()
    }

    /// Something changed elsewhere.
    func refresh() async {
        await events.pullChanges()
        await reminders.reload()
        if tasks.hasLoaded { await tasks.reload() }
    }
}
