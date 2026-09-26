import XCTest
@testable import NeutrinoCalendar

// MARK: - Helpers

@MainActor
private func mockClient() -> CalendarAPIClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return CalendarAPIClient(session: URLSession(configuration: config),
                             baseURL: { "https://example.test" }, token: { "tok" })
}

@MainActor
private func scratchQueue() -> PendingWrites {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("pending-\(UUID().uuidString).json")
    return PendingWrites(fileURL: url)
}

private func date(_ iso: String) -> Date { ServerDate.parse(iso)! }

private func eventJSON(_ id: String, title: String = "Review", start: String = "2026-09-16T17:00:00Z",
                       end: String = "2026-09-16T18:00:00Z", location: String? = nil,
                       rule: String? = nil) -> String {
    let loc = location.map { #""location":"\#($0)","# } ?? ""
    let rr = rule.map { #""recurrenceRule":"\#($0)","# } ?? ""
    return #"{"id":"\#(id)","title":"\#(title)","startTime":"\#(start)","endTime":"\#(end)",\#(loc)\#(rr)"allDay":false,"attendees":[],"source":"local","updatedAt":"2026-09-15T10:00:00Z"}"#
}

private func changes(_ events: [String] = [], deleted: [String] = [], cursor: String,
                     fullResync: Bool = false) -> String {
    let ids = deleted.map { "\"\($0)\"" }.joined(separator: ",")
    return #"{"events":[\#(events.joined(separator: ","))],"deletedIds":[\#(ids)],"cursor":"\#(cursor)","fullResyncRequired":\#(fullResync)}"#
}

// MARK: - Delta sync

@MainActor
final class EventsDeltaSyncTests: XCTestCase {

    private var calendar: Calendar!
    private var service: EventsService!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        service = EventsService(client: mockClient(), calendar: calendar,
                                now: { date("2026-09-15T19:00:00Z") })
    }

    private func ids(on day: String) -> [String] {
        service.occurrences(on: date(day)).map(\.event.id)
    }

    /// Loads September holding a one-off on the 16th and a weekly series.
    private func loadSeptember() async {
        MockURLProtocol.respondInSequence([
            (200, changes(cursor: "c1")),
            (200, #"{"events":[\#(eventJSON("one")),\#(eventJSON("wk", title: "Weekly", start: "2026-09-02T16:00:00Z", end: "2026-09-02T16:30:00Z", rule: "FREQ=WEEKLY"))]}"#),
        ])
        await service.ensureLoaded(for: .month)
        XCTAssertEqual(service.cursor, "c1", "the cursor is taken before the load")
        XCTAssertEqual(ids(on: "2026-09-16T19:00:00Z"), ["wk", "one"])
    }

    func testAPullAppliesChangesAndDeletionsToTheLoadedMonth() async throws {
        await loadSeptember()
        MockURLProtocol.respondInSequence([
            (200, changes([eventJSON("one", start: "2026-09-17T17:00:00Z", end: "2026-09-17T18:00:00Z"),
                           eventJSON("new", title: "New", start: "2026-09-16T20:00:00Z", end: "2026-09-16T21:00:00Z")],
                          deleted: ["wk"], cursor: "c2")),
        ])

        await service.pullChanges()

        let query = URLComponents(url: try XCTUnwrap(MockURLProtocol.lastRequest?.url), resolvingAgainstBaseURL: false)
        XCTAssertEqual(query?.path, "/api/v1/calendar/events/changes")
        XCTAssertEqual(query?.queryItems?.first { $0.name == "since" }?.value, "c1")
        XCTAssertEqual(ids(on: "2026-09-16T19:00:00Z"), ["new"], "moved off, series deleted, new one added")
        XCTAssertEqual(ids(on: "2026-09-17T19:00:00Z"), ["one"])
        XCTAssertEqual(ids(on: "2026-09-23T19:00:00Z"), [], "every occurrence of the deleted series is gone")
        XCTAssertEqual(service.cursor, "c2")
        XCTAssertEqual(service.generation, 0, "applied in place, no reload")
    }

    func testAnEventMovedOutOfAMonthLeavesIt() async {
        await loadSeptember()
        MockURLProtocol.respondInSequence([
            (200, changes([eventJSON("one", start: "2026-11-02T17:00:00Z", end: "2026-11-02T18:00:00Z")], cursor: "c2")),
        ])
        await service.pullChanges()
        XCTAssertEqual(ids(on: "2026-09-16T19:00:00Z"), ["wk"])
    }

    func testAStaleCursorThrowsTheCacheAway() async {
        await loadSeptember()
        MockURLProtocol.respondInSequence([(200, changes(cursor: "c9", fullResync: true))])
        await service.pullChanges()
        XCTAssertFalse(service.hasLoaded(service.month))
        XCTAssertNil(service.cursor)
        XCTAssertEqual(service.generation, 1)
    }

    func testNothingLoadedMeansNothingToPull() async {
        await service.pullChanges()
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)
    }

    func testAFailedPullKeepsWhatIsShownAndItsCursor() async {
        await loadSeptember()
        MockURLProtocol.respondInSequence([(MockURLProtocol.offline, "")])
        await service.pullChanges()
        XCTAssertEqual(service.cursor, "c1")
        XCTAssertEqual(ids(on: "2026-09-16T19:00:00Z"), ["wk", "one"])
    }

    /// The server's range test: starts by the end, and ends in the range or repeats.
    func testBelongsMatchesTheServersListFilter() {
        let from = date("2026-09-01T07:00:00Z"), to = date("2026-10-01T06:59:59Z")
        func event(_ start: String, _ end: String, rule: String? = nil) -> CalendarEvent {
            CalendarEvent(id: "e", title: "E", start: date(start), end: date(end), recurrenceRule: rule)
        }
        XCTAssertTrue(EventsService.belongs(event("2026-09-10T00:00:00Z", "2026-09-10T01:00:00Z"), from: from, to: to))
        XCTAssertTrue(EventsService.belongs(event("2026-08-31T00:00:00Z", "2026-09-02T00:00:00Z"), from: from, to: to))
        XCTAssertFalse(EventsService.belongs(event("2026-08-01T00:00:00Z", "2026-08-01T01:00:00Z"), from: from, to: to))
        XCTAssertTrue(EventsService.belongs(event("2026-08-01T00:00:00Z", "2026-08-01T01:00:00Z", rule: "FREQ=DAILY"),
                                            from: from, to: to))
        XCTAssertFalse(EventsService.belongs(event("2026-10-02T00:00:00Z", "2026-10-02T01:00:00Z", rule: "FREQ=DAILY"),
                                             from: from, to: to))
    }
}

// MARK: - Conflicts and offline edits

@MainActor
final class EventsConflictTests: XCTestCase {

    private var service: EventsService!
    private var event: CalendarEvent!
    private var original: EventDraft!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        service = EventsService(client: mockClient())
        event = try! JSONDecoder().decode(CalendarEvent.self, from: Data(eventJSON("e").utf8))
        original = EventDraft(editing: event)
    }

    private func retitled(_ title: String) -> EventDraft {
        var draft = original!
        draft.title = title
        return draft
    }

    func testTheSameFieldChangedElsewhereStopsTheSave() async {
        MockURLProtocol.respondInSequence([(200, eventJSON("e", title: "Their title"))])
        do {
            try await service.update(event, from: original, to: retitled("My title"))
            XCTFail("expected a conflict")
        } catch {
            XCTAssertEqual(error as? EditConflict, .changedElsewhere(["title"]))
        }
        XCTAssertEqual(MockURLProtocol.requests.map(\.httpMethod), ["GET"], "nothing was written")
    }

    func testADifferentFieldChangedElsewhereIsNoConflict() async throws {
        MockURLProtocol.respondInSequence([
            (200, eventJSON("e", location: "Room 4")),
            (200, eventJSON("e", title: "My title", location: "Room 4")),
        ])
        try await service.update(event, from: original, to: retitled("My title"))
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "PUT")
        XCTAssertEqual(MockURLProtocol.lastJSON?.keys.sorted(), ["title"], "their location is left alone")
    }

    func testTheSameChangeMadeOnBothSidesIsNoConflict() async throws {
        MockURLProtocol.respondInSequence([
            (200, eventJSON("e", title: "Agreed")),
            (200, eventJSON("e", title: "Agreed")),
        ])
        try await service.update(event, from: original, to: retitled("Agreed"))
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "PUT")
    }

    func testDeletedElsewhere() async {
        MockURLProtocol.respondInSequence([(404, "{}")])
        do {
            try await service.update(event, from: original, to: retitled("Mine"))
            XCTFail("expected a conflict")
        } catch {
            XCTAssertEqual(error as? EditConflict, .deletedElsewhere)
        }
    }

    func testOverwriteSkipsTheCheck() async throws {
        MockURLProtocol.respond(status: 200, body: eventJSON("e", title: "Mine"))
        try await service.update(event, from: original, to: retitled("Mine"), overwrite: true)
        XCTAssertEqual(MockURLProtocol.requests.map(\.httpMethod), ["PUT"])
    }

    func testOfflineTheEditIsQueuedAndShown() async throws {
        let queue = scratchQueue()
        service.pending = queue
        MockURLProtocol.respond(status: MockURLProtocol.offline, body: "")

        let shown = try await service.update(event, from: original, to: retitled("Offline title"))

        XCTAssertEqual(shown.title, "Offline title")
        XCTAssertEqual(queue.writes.map(\.method), ["PUT"])
        XCTAssertEqual(queue.writes.first?.path, "/api/v1/calendar/events/e")
        let body = try XCTUnwrap(queue.writes.first?.body)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["title"] as? String,
                       "Offline title")
    }

    func testOfflineWithNoQueueTheEditFails() async {
        MockURLProtocol.respond(status: MockURLProtocol.offline, body: "")
        do {
            try await service.update(event, from: original, to: retitled("Mine"))
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual((error as? CalendarAPIError)?.isNetwork, true)
        }
    }

    func testDeletingWhatIsAlreadyGoneIsFine() async throws {
        MockURLProtocol.respond(status: 404, body: "{}")
        try await service.delete(event)
        XCTAssertEqual(service.generation, 1)
    }

    func testEveryRequestNamesTheClient() async throws {
        MockURLProtocol.respond(status: 200, body: #"{"events":[]}"#)
        _ = try await mockClient().events(from: Date(), to: Date())
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Neutrino-Client-Id"),
                       CalendarAPIClient.clientID)
    }
}

// MARK: - EditConflict

final class EditConflictTests: XCTestCase {

    func testClashesAreSharedFieldsWithDifferentValuesNamedForPeople() {
        let mine = UpdateEventRequest(title: "A", startTime: "s1", endTime: "e1", allDay: false, location: "X")
        let theirs = UpdateEventRequest(title: "B", startTime: "s2", endTime: "e1", allDay: false, location: "X",
                                        attendees: ["ada@example.com"])
        XCTAssertEqual(EditConflict.clashes(mine: mine, theirs: theirs), ["time", "title"])
    }

    func testClearingOnBothSidesIsNoClash() {
        let mine = UpdateTaskRequest(notes: .clear)
        XCTAssertEqual(EditConflict.clashes(mine: mine, theirs: UpdateTaskRequest(notes: .clear)), [])
        XCTAssertEqual(EditConflict.clashes(mine: mine, theirs: UpdateTaskRequest(notes: .set("theirs"))), ["notes"])
    }

    func testMessages() {
        XCTAssertEqual(EditConflict.changedElsewhere(["title", "time"]).errorDescription,
                       "Someone changed the title and time on another device since you opened this.")
        XCTAssertEqual(EditConflict.deletedElsewhere.errorDescription, "This was deleted on another device.")
    }
}

// MARK: - PendingWrites

@MainActor
final class PendingWritesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    func testTheQueueSurvivesARelaunch() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pw-\(UUID().uuidString).json")
        let first = PendingWrites(fileURL: url)
        first.enqueue(PendingWrite(method: "PATCH", path: "/api/v1/calendar/tasks/t", json: ["done": true]))
        XCTAssertEqual(PendingWrites(fileURL: url).writes, first.writes)
    }

    func testADeleteSupersedesQueuedEditsOfTheSameThing() {
        let queue = scratchQueue()
        queue.enqueue(PendingWrite(method: "PUT", path: "/api/v1/calendar/events/a"))
        queue.enqueue(PendingWrite(method: "PUT", path: "/api/v1/calendar/events/b"))
        queue.enqueue(PendingWrite(method: "DELETE", path: "/api/v1/calendar/events/a"))
        XCTAssertEqual(queue.writes.map(\.path), ["/api/v1/calendar/events/b", "/api/v1/calendar/events/a"])
        XCTAssertEqual(queue.writes.last?.method, "DELETE")
    }

    func testReplaySendsInOrderDropsTheGoneAndStopsWhileOffline() async {
        let queue = scratchQueue()
        for id in ["a", "b", "c"] {
            queue.enqueue(PendingWrite(method: "PATCH", path: "/api/v1/calendar/reminders/\(id)", json: ["completed": true]))
        }
        MockURLProtocol.respondInSequence([(200, "{}"), (404, "{}"), (MockURLProtocol.offline, "")])

        let finished = await queue.replay(using: mockClient())

        XCTAssertEqual(finished, 2, "sent one, dropped one deleted elsewhere")
        XCTAssertEqual(queue.writes.map(\.path), ["/api/v1/calendar/reminders/c"])
        XCTAssertEqual(MockURLProtocol.requests.map { $0.url!.path },
                       ["/api/v1/calendar/reminders/a", "/api/v1/calendar/reminders/b", "/api/v1/calendar/reminders/c"])
        XCTAssertEqual(MockURLProtocol.lastJSON?["completed"] as? Bool, true, "the body goes as it was queued")
    }

    func testAWriteTheServerKeepsFailingIsDroppedInTheEnd() async {
        let queue = scratchQueue()
        queue.enqueue(PendingWrite(method: "DELETE", path: "/api/v1/calendar/events/a"))
        MockURLProtocol.respond(status: 500, body: "{}")
        for _ in 1..<PendingWrites.maxAttempts {
            await queue.replay(using: mockClient())
            XCTAssertEqual(queue.writes.count, 1)
        }
        await queue.replay(using: mockClient())
        XCTAssertTrue(queue.isEmpty)
    }

    func testClearForgetsEverything() {
        let queue = scratchQueue()
        queue.enqueue(PendingWrite(method: "DELETE", path: "/x"))
        queue.clear()
        XCTAssertTrue(queue.isEmpty)
    }
}

// MARK: - Reminders and tasks

@MainActor
final class ListConflictTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    private func reminderJSON(title: String) -> String {
        #"{"id":"r","title":"\#(title)","dueTime":"2026-09-20T16:00:00Z","completed":false}"#
    }

    func testAReminderRetitledElsewhereStopsARetitle() async throws {
        let service = RemindersService(client: mockClient())
        let reminder = Reminder(id: "r", title: "Stretch", due: date("2026-09-20T16:00:00Z"))
        MockURLProtocol.respondInSequence([(200, reminderJSON(title: "Theirs"))])
        do {
            try await service.update(reminder, title: "Mine", due: reminder.due, rule: nil)
            XCTFail("expected a conflict")
        } catch {
            XCTAssertEqual(error as? EditConflict, .changedElsewhere(["title"]))
        }
    }

    func testAReminderDeletedOfflineGoesAtOnceAndIsQueued() async {
        let service = RemindersService(client: mockClient())
        let queue = scratchQueue()
        service.pending = queue
        MockURLProtocol.respondInSequence([(200, #"{"reminders":[\#(reminderJSON(title: "Stretch"))]}"#)])
        await service.reload()
        MockURLProtocol.respond(status: MockURLProtocol.offline, body: "")

        await service.delete(service.reminders[0])

        XCTAssertTrue(service.reminders.isEmpty)
        XCTAssertNil(service.error)
        XCTAssertEqual(queue.writes.map(\.method), ["DELETE"])
    }

    func testATaskEditMeasuresTheirChangesFromTheSameStart() async throws {
        let service = TasksService(client: mockClient())
        let task = CalendarTask(id: "t", title: "Buy milk", notes: "2%")
        // They changed the notes; this edit changes the title. No clash, and only the title goes.
        MockURLProtocol.respondInSequence([
            (200, #"[{"id":"t","title":"Buy milk","notes":"oat"}]"#),
            (200, #"{"id":"t","title":"Buy oat milk","notes":"oat"}"#),
        ])
        let saved = try await service.update(task, title: "Buy oat milk", notes: "2%", dueDay: nil)
        XCTAssertEqual(saved.notes, "oat")
        XCTAssertEqual(MockURLProtocol.lastJSON?.keys.sorted(), ["title"])
    }

    func testATaskDeletedElsewhere() async {
        let service = TasksService(client: mockClient())
        MockURLProtocol.respondInSequence([(200, "[]")])
        do {
            try await service.update(CalendarTask(id: "t", title: "Old"), title: "New", notes: "", dueDay: nil)
            XCTFail("expected a conflict")
        } catch {
            XCTAssertEqual(error as? EditConflict, .deletedElsewhere)
        }
    }

    func testATaskTickedOffOfflineShowsDone() async {
        let service = TasksService(client: mockClient())
        service.pending = scratchQueue()
        MockURLProtocol.respondInSequence([(200, #"[{"id":"t","title":"Buy milk"}]"#)])
        await service.reload()
        MockURLProtocol.respond(status: MockURLProtocol.offline, body: "")

        await service.setDone(service.tasks[0], true)

        XCTAssertEqual(service.tasks.first?.done, true)
        XCTAssertEqual(service.pending?.writes.first?.method, "PATCH")
    }
}

// MARK: - Live signal

final class CalendarSignalTests: XCTestCase {

    func testOnlyAnotherClientsCalendarSignalCounts() {
        XCTAssertTrue(CalendarSignal.isRemoteChange(#"{"type":"calendar.changed","originClientId":"web-tab"}"#, ownClientID: "me"))
        XCTAssertTrue(CalendarSignal.isRemoteChange(#"{"type":"calendar.changed","originClientId":null}"#, ownClientID: "me"),
                      "a batch from several clients is somebody else's")
        XCTAssertFalse(CalendarSignal.isRemoteChange(#"{"type":"calendar.changed","originClientId":"me"}"#, ownClientID: "me"),
                       "the echo of this app's own write")
        XCTAssertFalse(CalendarSignal.isRemoteChange(#"{"type":"drive.changed","originClientId":null}"#, ownClientID: "me"))
        XCTAssertFalse(CalendarSignal.isRemoteChange(#"{"id":"n1","eventType":"file_shared"}"#, ownClientID: "me"),
                       "an inbox record")
        XCTAssertFalse(CalendarSignal.isRemoteChange("not json", ownClientID: "me"))
    }

    func testSocketURL() {
        XCTAssertEqual(CalendarSignal.socketURL(baseURL: "https://getneutrino.app", token: "a.b-c_d")?.absoluteString,
                       "wss://getneutrino.app/api/v1/drive/notifications/ws?token=a.b-c_d")
        XCTAssertEqual(CalendarSignal.socketURL(baseURL: "http://localhost:8181", token: "t")?.absoluteString,
                       "ws://localhost:8181/api/v1/drive/notifications/ws?token=t")
        XCTAssertNil(CalendarSignal.socketURL(baseURL: "ftp://x", token: "t"))
    }
}
