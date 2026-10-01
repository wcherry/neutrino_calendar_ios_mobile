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
                      notes: String? = nil, due: String? = nil, event: String? = nil,
                      tags: [String] = []) -> String {
        func q(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "null" }
        return """
        {"id":"\(id)","title":"\(title)","notes":\(q(notes)),"done":\(done),"dueDate":\(q(due)),
         "tags":[\(tags.map { q($0) }.joined(separator: ","))],
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
        XCTAssertEqual(MockURLProtocol.lastJSON?.keys.sorted(), ["done", "timezone"])
        XCTAssertEqual(service.done.map(\.id), ["a"])
    }

    func testEditSendsOnlyChangesAndClearsWithNull() async throws {
        await load([task("a", "Fans", notes: "Use the long duster", due: "2026-09-30T00:00:00Z")])
        let original = try XCTUnwrap(service.task(id: "a"))
        MockURLProtocol.respond(status: 200, body: task("a", "Fans"))

        // Past the conflict check (SyncTests covers it), to the request itself.
        try await service.update(original, title: "Fans", notes: "  ", dueDay: nil, calendar: pacific,
                                 overwrite: true)

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

    // MARK: Smart Add

    func testCompletingARepeatingTaskAddsTheNextOccurrence() async throws {
        await load([task("a", "Water plants")])
        let next = task("b", "Water plants", due: "2026-10-08T00:00:00Z")
        MockURLProtocol.respond(status: 200, body: """
        {"id":"a","title":"Water plants","notes":null,"done":true,"dueDate":null,"position":0,
         "listId":null,"eventId":null,"createdAt":"2026-09-01T00:00:00Z",
         "updatedAt":"2026-09-01T00:00:00Z","nextTask":\(next)}
        """)
        await service.setDone(try XCTUnwrap(service.task(id: "a")), true,
                              timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        XCTAssertEqual(MockURLProtocol.lastJSON?["timezone"] as? String, "America/Los_Angeles")
        XCTAssertEqual(service.done.map(\.id), ["a"])
        XCTAssertEqual(service.open.map(\.id), ["b"])
    }

    func testCreatingFromSmartAddSendsItsFields() async throws {
        MockURLProtocol.respond(status: 201, body: task("new", "Buy milk"))
        let context = SmartAdd.Context(today: "2026-09-25", now: "14:00")
        try await service.create(SmartAdd.parse("Buy milk ^tomorrow #errands !2", context: context))
        XCTAssertEqual(MockURLProtocol.lastJSON?["title"] as? String, "Buy milk")
        XCTAssertEqual(MockURLProtocol.lastJSON?["dueDate"] as? String, "2026-09-26T00:00:00Z")
        XCTAssertEqual(MockURLProtocol.lastJSON?["tags"] as? [String], ["errands"])
        XCTAssertEqual(MockURLProtocol.lastJSON?["priority"] as? Int, 2)
        XCTAssertEqual(service.tasks.map(\.id), ["new"])
    }

    func testDecodesTheSmartAddFields() throws {
        let json = """
        {"id":"a","title":"t","notes":null,"done":false,"dueDate":"2026-10-02T22:00:00Z",
         "position":0,"eventId":null,"dueHasTime":true,"priority":1,"tags":["home"],
         "recurrenceRule":"FREQ=DAILY","repeatAfterCompletion":true,"estimateMinutes":30,
         "location":"Shed"}
        """
        let decoded = try JSONDecoder().decode(CalendarTask.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.dueHasTime)
        XCTAssertEqual(decoded.priority, 1)
        XCTAssertEqual(decoded.tags, ["home"])
        XCTAssertEqual(decoded.recurrenceRule, "FREQ=DAILY")
        XCTAssertTrue(decoded.repeatAfterCompletion)
        XCTAssertEqual(decoded.estimateMinutes, 30)
        XCTAssertEqual(decoded.location, "Shed")
    }

    func testAllTagsAreMostUsedFirst() async {
        await load([task("a", tags: ["home", "work"]), task("b", tags: ["work"]), task("c", tags: ["errands"])])
        XCTAssertEqual(service.allTags, ["work", "errands", "home"])
    }

    func testEditingTagsSendsTheWholeSetNormalised() async throws {
        await load([task("a", "Fans", tags: ["home"])])
        let original = try XCTUnwrap(service.task(id: "a"))
        MockURLProtocol.respond(status: 200, body: task("a", "Fans", tags: ["home", "new"]))
        try await service.update(original, title: "Fans", notes: "", dueDay: nil, tags: ["home", "#New"],
                                 overwrite: true)
        XCTAssertEqual(MockURLProtocol.lastJSON?.keys.sorted(), ["tags"])
        XCTAssertEqual(MockURLProtocol.lastJSON?["tags"] as? [String], ["home", "new"])
        XCTAssertEqual(service.task(id: "a")?.tags, ["home", "new"])
    }

    func testRemovingEveryTagSendsAnEmptySet() async throws {
        await load([task("a", "Fans", tags: ["home"])])
        let original = try XCTUnwrap(service.task(id: "a"))
        MockURLProtocol.respond(status: 200, body: task("a", "Fans"))
        try await service.update(original, title: "Fans", notes: "", dueDay: nil, tags: [], overwrite: true)
        XCTAssertEqual(MockURLProtocol.lastJSON?["tags"] as? [String], [])
    }

    func testTheSameTagsInAnotherOrderAreNotAChange() async throws {
        await load([task("a", "Fans", tags: ["home", "work"])])
        let original = try XCTUnwrap(service.task(id: "a"))
        MockURLProtocol.reset()
        try await service.update(original, title: "Fans", notes: "", dueDay: nil, tags: ["work", "HOME"])
        XCTAssertNil(MockURLProtocol.lastRequest)
    }
}

// MARK: - Tags

final class TaskTagsTests: XCTestCase {

    func testSplitMatchesTheWebsTagField() {
        XCTAssertEqual(TaskTags.split("#Errands, home  ##work home"), ["errands", "home", "work"])
        XCTAssertEqual(TaskTags.split("  "), [])
    }

    func testNormalizeMatchesTheServer() {
        XCTAssertEqual(TaskTags.normalize(["Work", "#home", "work", " "]), ["home", "work"])
    }

    func testSuggestionsPutPrefixMatchesFirstAndSkipChosenOnes() {
        let known = ["homework", "work", "errands", "home"]
        XCTAssertEqual(TaskTags.suggestions(for: "ho", in: known, excluding: []), ["homework", "home"])
        XCTAssertEqual(TaskTags.suggestions(for: "#WO", in: known, excluding: []), ["work", "homework"])
        XCTAssertEqual(TaskTags.suggestions(for: "", in: known, excluding: ["work"]),
                       ["homework", "errands", "home"])
        XCTAssertEqual(TaskTags.suggestions(for: "zzz", in: known, excluding: []), [])
    }
}

// MARK: - Filter

final class TaskFilterTests: XCTestCase {

    private var pacific: Calendar!
    /// 10:00 PDT on Wednesday the 30th.
    private let now = ServerDate.parse("2026-09-30T17:00:00Z")!

    private lazy var tasks: [CalendarTask] = [
        CalendarTask(id: "late", title: "Taxes", dueDate: ServerDate.parse("2026-09-28T00:00:00Z"), priority: 1),
        CalendarTask(id: "today", title: "Call Mom", dueDate: ServerDate.parse("2026-09-30T00:00:00Z"),
                     tags: ["family"]),
        CalendarTask(id: "week", title: "Buy milk", notes: "Oat", dueDate: ServerDate.parse("2026-10-06T00:00:00Z"),
                     priority: 2, tags: ["errands"]),
        CalendarTask(id: "later", title: "Renew passport", dueDate: ServerDate.parse("2026-10-07T00:00:00Z")),
        CalendarTask(id: "undated", title: "Read", tags: ["home", "errands"], location: "Café Zoë"),
        CalendarTask(id: "doneLate", title: "Old bill", done: true, dueDate: ServerDate.parse("2026-09-01T00:00:00Z")),
    ]

    override func setUp() {
        super.setUp()
        pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    }

    private func ids(_ filter: TaskFilter) -> [String] {
        filter.apply(to: tasks, now: now, calendar: pacific).map(\.id)
    }

    func testAnEmptyFilterKeepsEverythingInOrder() {
        XCTAssertFalse(TaskFilter().isActive)
        XCTAssertEqual(ids(TaskFilter()), tasks.map(\.id))
        XCTAssertFalse(TaskFilter(text: "  ").isActive, "blank search is no search")
    }

    func testDueRanges() {
        XCTAssertEqual(ids(TaskFilter(due: .overdue)), ["late"], "a done task is never overdue")
        XCTAssertEqual(ids(TaskFilter(due: .today)), ["today"])
        XCTAssertEqual(ids(TaskFilter(due: .week)), ["today", "week"], "seven days from today, not eight")
        XCTAssertEqual(ids(TaskFilter(due: .none)), ["undated"])
    }

    func testPriorityTagsAndDone() {
        XCTAssertEqual(ids(TaskFilter(priority: 2)), ["week"])
        XCTAssertEqual(ids(TaskFilter(tags: ["family", "home"])), ["today", "undated"], "any picked tag")
        XCTAssertEqual(ids(TaskFilter(showDone: false)), ["late", "today", "week", "later", "undated"])
        XCTAssertTrue(TaskFilter(showDone: false).hasMenuFilters)
    }

    func testSearchEveryWordAcrossFieldsIgnoringCaseAndAccents() {
        XCTAssertEqual(ids(TaskFilter(text: "oat")), ["week"], "notes")
        XCTAssertEqual(ids(TaskFilter(text: "cafe zoe")), ["undated"], "location, accents ignored")
        XCTAssertEqual(ids(TaskFilter(text: "errands")), ["week", "undated"], "tags")
        XCTAssertEqual(ids(TaskFilter(text: "buy errands")), ["week"], "every word must match")
        XCTAssertEqual(ids(TaskFilter(text: "#err")), ["week", "undated"])
        XCTAssertEqual(ids(TaskFilter(text: "#milk")), [], "a # word searches tags only")
        XCTAssertTrue(TaskFilter(text: "x").isActive)
        XCTAssertFalse(TaskFilter(text: "x").hasMenuFilters)
    }

    func testFiltersCombine() {
        XCTAssertEqual(ids(TaskFilter(text: "read", tags: ["errands"])), ["undated"])
        XCTAssertEqual(ids(TaskFilter(due: .week, tags: ["family"])), ["today"])
    }
}
