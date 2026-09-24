import XCTest
@testable import NeutrinoCalendar

// MARK: - Models

final class TaskModelTests: XCTestCase {

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    func testDecodesTheServersShape() throws {
        let body = """
        {"id":"t1","title":"Clean ceiling fans","notes":"","done":false,"dueDate":"2026-09-30T00:00:00Z",
         "position":2,"listId":null,"eventId":"ev","createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-01T00:00:00Z"}
        """
        let task = try JSONDecoder().decode(CalendarTask.self, from: Data(body.utf8))
        XCTAssertNil(task.notes, "empty notes are no notes")
        XCTAssertEqual(task.position, 2)
        XCTAssertEqual(task.eventId, "ev")
        XCTAssertEqual(task.dueDate, ServerDate.parse("2026-09-30T00:00:00Z"))
    }

    /// A due date is a day: stored as UTC midnight, it is the 30th in Los Angeles too, where that
    /// instant is still the 29th.
    func testDueDateIsTheSameDayInEveryZone() {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let task = CalendarTask(id: "t", title: "t", dueDate: ServerDate.parse("2026-09-30T00:00:00Z"))

        let day = task.dueDay(in: pacific)!
        XCTAssertEqual(pacific.component(.day, from: day), 30)
        XCTAssertEqual(CalendarTask.dueDateValue(for: day, in: pacific), "2026-09-30T00:00:00Z")
        XCTAssertTrue(task.dueDateText?.contains("30") ?? false, task.dueDateText ?? "")
    }

    func testAnUntouchedFieldIsOmittedAndAClearedOneIsNull() throws {
        let body = try json(UpdateTaskRequest(title: "New", notes: .clear, dueDate: .set("2026-10-01T00:00:00Z")))
        XCTAssertEqual(body["title"] as? String, "New")
        XCTAssertTrue(body["notes"] is NSNull, "a cleared field must be sent as null")
        XCTAssertEqual(body["dueDate"] as? String, "2026-10-01T00:00:00Z")
        XCTAssertNil(body["done"])

        XCTAssertTrue(try json(UpdateTaskRequest(done: true)).keys.sorted() == ["done"])
    }

    func testScheduleRequestShapes() throws {
        let pacific = TimeZone(identifier: "America/Los_Angeles")!
        // 18:00 PDT on the 30th is already the 1st in UTC; an all-day slot is still the 30th.
        let start = ServerDate.parse("2026-10-01T01:00:00Z")!
        let allDay = try json(ScheduleTaskRequest(start: start, end: start, allDay: true, timeZone: pacific))
        XCTAssertEqual(allDay["startTime"] as? String, "2026-09-30T00:00:00Z")
        XCTAssertEqual(allDay["endTime"] as? String, "2026-09-30T23:59:59Z")
        XCTAssertTrue(allDay["timezone"] is NSNull || allDay["timezone"] == nil)

        let timed = try json(ScheduleTaskRequest(start: start, end: start.addingTimeInterval(3600),
                                                 allDay: false, timeZone: pacific))
        XCTAssertEqual(timed["startTime"] as? String, "2026-10-01T01:00:00Z")
        XCTAssertEqual(timed["endTime"] as? String, "2026-10-01T02:00:00Z")
        XCTAssertEqual(timed["timezone"] as? String, "America/Los_Angeles")
    }
}

// MARK: - Service

@MainActor
final class TasksServiceTests: XCTestCase {

    private var service: TasksService!
    private var pacific: Calendar!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CalendarAPIClient(session: URLSession(configuration: config),
                                       baseURL: { "https://example.test" }, token: { "tok" })
        service = TasksService(client: client)
        pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    }

    private func task(_ id: String, _ title: String = "Task", done: Bool = false, position: Int = 0,
                      notes: String? = nil, due: String? = nil, event: String? = nil) -> String {
        func q(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "null" }
        return """
        {"id":"\(id)","title":"\(title)","notes":\(q(notes)),"done":\(done),"dueDate":\(q(due)),
         "position":\(position),"listId":null,"eventId":\(q(event)),
         "createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-01T00:00:00Z"}
        """
    }

    private func load(_ items: [String]) async {
        MockURLProtocol.respond(status: 200, body: "[\(items.joined(separator: ","))]")
        await service.reload()
    }

    /// The server's order is kept as it is: it breaks position ties by creation time, which the
    /// client can't see, so re-sorting would disagree with the web.
    func testReloadKeepsTheServersOrderAndSplitsOpenFromDone() async {
        await load([task("z", position: 0), task("a", position: 0), task("b", done: true, position: 1)])
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/v1/calendar/tasks")
        XCTAssertEqual(service.open.map(\.id), ["z", "a"])
        XCTAssertEqual(service.done.map(\.id), ["b"])
    }

    func testCreateAppends() async throws {
        await load([task("a")])
        MockURLProtocol.respond(status: 201, body: task("new", "Buy duster", position: 1))
        try await service.create(title: "Buy duster")
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(MockURLProtocol.lastJSON?["title"] as? String, "Buy duster")
        XCTAssertEqual(service.open.map(\.id), ["a", "new"])
    }

    func testTickingOffMovesItToDone() async throws {
        await load([task("a")])
        MockURLProtocol.respond(status: 200, body: task("a", done: true))
        await service.setDone(try XCTUnwrap(service.task(id: "a")), true)
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "PATCH")
        XCTAssertEqual(MockURLProtocol.lastJSON?.keys.sorted(), ["done"])
        XCTAssertEqual(service.done.map(\.id), ["a"])
    }

    func testEditSendsOnlyChangesAndClearsWithNull() async throws {
        await load([task("a", "Fans", notes: "Use the long duster", due: "2026-09-30T00:00:00Z")])
        let original = try XCTUnwrap(service.task(id: "a"))
        MockURLProtocol.respond(status: 200, body: task("a", "Fans"))

        try await service.update(original, title: "Fans", notes: "  ", dueDay: nil, calendar: pacific)

        XCTAssertEqual(MockURLProtocol.lastJSON?.keys.sorted(), ["dueDate", "notes"])
        XCTAssertTrue(MockURLProtocol.lastJSON?["notes"] is NSNull)
        XCTAssertTrue(MockURLProtocol.lastJSON?["dueDate"] is NSNull)
    }

    func testAnUnchangedEditSendsNothing() async throws {
        await load([task("a", "Fans", due: "2026-09-30T00:00:00Z")])
        let original = try XCTUnwrap(service.task(id: "a"))
        MockURLProtocol.reset()
        try await service.update(original, title: "Fans", notes: "", dueDay: original.dueDay(in: pacific),
                                 calendar: pacific)
        XCTAssertNil(MockURLProtocol.lastRequest, "the same due day in another zone is not a change")
    }

    func testReorderMovesOpenTasksAndKeepsDoneAfter() async {
        await load([task("a", position: 0), task("b", position: 1), task("done", done: true, position: 2)])
        MockURLProtocol.respond(status: 200, body: "")
        await service.reorderOpen(to: ["b", "a"])
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/v1/calendar/tasks/reorder")
        XCTAssertEqual(MockURLProtocol.lastJSON?["taskIds"] as? [String], ["b", "a"])
        XCTAssertEqual(service.tasks.map(\.id), ["b", "a", "done"])
        XCTAssertNil(service.error)
    }

    /// The schedule endpoint answers with the event, so the task is read again for its eventId.
    func testSchedulingRereadsTheTask() async throws {
        await load([task("a", "Fans")])
        MockURLProtocol.respondInSequence([
            (200, """
            {"id":"ev","title":"Fans","startTime":"2026-09-30T16:00:00Z","endTime":"2026-09-30T17:00:00Z",
             "allDay":false,"attendees":[],"source":"local"}
            """),
            (200, "[\(task("a", "Fans", event: "ev"))]"),
        ])
        let start = try XCTUnwrap(ServerDate.parse("2026-09-30T16:00:00Z"))
        try await service.schedule(try XCTUnwrap(service.task(id: "a")), start: start,
                                   end: start.addingTimeInterval(3600), allDay: false)
        XCTAssertEqual(MockURLProtocol.requests.suffix(2).map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" },
                       ["POST /api/v1/calendar/tasks/a/event", "GET /api/v1/calendar/tasks"])
        XCTAssertEqual(service.task(id: "a")?.eventId, "ev")
    }

    func testUnschedulingTakesTheServersTask() async throws {
        await load([task("a", event: "ev")])
        MockURLProtocol.respond(status: 200, body: task("a"))
        try await service.unschedule(try XCTUnwrap(service.task(id: "a")))
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/v1/calendar/tasks/a/event")
        XCTAssertNil(service.task(id: "a")?.eventId)
    }

    func testNotes() async throws {
        await load([task("a")])
        let t = try XCTUnwrap(service.task(id: "a"))
        MockURLProtocol.respond(status: 201, body: #"{"id":"n1","taskId":"a","fileId":null,"name":null,"note":"Ladder in the garage"}"#)
        let note = try await service.addNote("Ladder in the garage", to: t)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/v1/calendar/tasks/a/attachments")
        XCTAssertEqual(MockURLProtocol.lastJSON?["note"] as? String, "Ladder in the garage")

        MockURLProtocol.respond(status: 204, body: "")
        try await service.deleteAttachment(note, from: t)
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/v1/calendar/tasks/a/attachments/n1")
    }

    func testReset() async {
        await load([task("a")])
        service.reset()
        XCTAssertTrue(service.tasks.isEmpty)
        XCTAssertFalse(service.hasLoaded)
    }
}
