import XCTest
@testable import NeutrinoCalendar

/// Siri's Add Task and What's Due Today.
final class TaskSpeechTests: XCTestCase {

    private var calendar: Calendar!
    /// Tuesday, September 15, 2026, 12:00 in Los Angeles.
    private let now = ServerDate.parse("2026-09-15T19:00:00Z")!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    }

    private func date(_ iso: String) -> Date { ServerDate.parse(iso)! }

    private func task(_ title: String, due: String? = nil, hasTime: Bool = false, done: Bool = false) -> CalendarTask {
        CalendarTask(id: title, title: title, done: done, dueDate: due.map(date), dueHasTime: hasTime)
    }

    // MARK: - Add Task

    func testWhatIsSaidGoesThroughSmartAdd() throws {
        let request = try XCTUnwrap(TaskSpeech.request(for: "Buy milk tomorrow 5pm #errands", due: nil,
                                                       now: now, calendar: calendar))
        XCTAssertEqual(request.title, "Buy milk")
        XCTAssertEqual(request.dueDate, "2026-09-17T00:00:00Z", "5 PM on the 16th in Los Angeles")
        XCTAssertEqual(request.dueHasTime, true)
        XCTAssertEqual(request.tags, ["errands"])
    }

    func testADayWithNoTimeIsADate() throws {
        let request = try XCTUnwrap(TaskSpeech.request(for: "pay rent by friday", due: nil, now: now, calendar: calendar))
        XCTAssertEqual(request.title, "pay rent")
        XCTAssertEqual(request.dueDate, "2026-09-18T00:00:00Z")
        XCTAssertNil(request.dueHasTime)
    }

    func testAPlainTitleIsJustATitle() throws {
        let request = try XCTUnwrap(TaskSpeech.request(for: "  Water the plants ", due: nil, now: now, calendar: calendar))
        XCTAssertEqual(request, CreateTaskRequest(title: "Water the plants"))
    }

    func testAGivenDueDateWins() throws {
        // Local midnight on the 20th: the day.
        let midnight = date("2026-09-20T07:00:00Z")
        let day = try XCTUnwrap(TaskSpeech.request(for: "Taxes tomorrow", due: midnight, now: now, calendar: calendar))
        XCTAssertEqual(day.dueDate, "2026-09-20T00:00:00Z")
        XCTAssertNil(day.dueHasTime)

        let timed = try XCTUnwrap(TaskSpeech.request(for: "Taxes", due: date("2026-09-20T16:30:00Z"),
                                                     now: now, calendar: calendar))
        XCTAssertEqual(timed.dueDate, "2026-09-20T16:30:00Z")
        XCTAssertEqual(timed.dueHasTime, true)
    }

    func testNothingToCallTheTaskIsRefused() {
        XCTAssertNil(TaskSpeech.request(for: "   ", due: nil, now: now, calendar: calendar))
    }

    func testAddedSentences() {
        XCTAssertEqual(TaskSpeech.added(task("Buy milk"), now: now, calendar: calendar), "Added Buy milk.")
        XCTAssertEqual(TaskSpeech.added(task("Buy milk", due: "2026-09-16T00:00:00Z"), now: now, calendar: calendar),
                       "Added Buy milk, due tomorrow.")
        let timed = TaskSpeech.added(task("Call", due: "2026-09-16T00:00:00Z", hasTime: true), now: now, calendar: calendar)
        XCTAssertTrue(timed.hasPrefix("Added Call, due today at 5:00"), "00:00 UTC is 17:00 the day before in LA: \(timed)")
    }

    // MARK: - What's Due Today

    func testDueTodayTakesOpenTasksDueByTheEndOfToday() {
        let tasks = [
            task("later", due: "2026-09-16T00:00:00Z"),
            task("today-b", due: "2026-09-15T00:00:00Z"),
            task("done", due: "2026-09-15T00:00:00Z", done: true),
            task("undated"),
            task("overdue-new", due: "2026-09-14T00:00:00Z"),
            task("today-3pm", due: "2026-09-15T22:00:00Z", hasTime: true),
            task("overdue-old", due: "2026-09-01T00:00:00Z"),
            task("today-a", due: "2026-09-15T00:00:00Z"),
            task("today-9am", due: "2026-09-15T16:00:00Z", hasTime: true),
        ]
        let due = TaskSpeech.dueToday(tasks, now: now, calendar: calendar)
        XCTAssertEqual(due.overdue.map(\.id), ["overdue-old", "overdue-new"])
        XCTAssertEqual(due.today.map(\.id), ["today-9am", "today-3pm", "today-b", "today-a"],
                       "timed ones by time, then the list's own order")
    }

    func testAnUntimedDueDateIsTheSameDayEverywhere() {
        // 00:00 UTC on the 16th is the 16th, not 17:00 on the 15th in Los Angeles.
        let due = TaskSpeech.dueToday([task("tomorrow", due: "2026-09-16T00:00:00Z")], now: now, calendar: calendar)
        XCTAssertTrue(due.today.isEmpty)
    }

    func testDueTodaySentences() {
        XCTAssertEqual(TaskSpeech.sentence(overdue: [], today: [], calendar: calendar), "Nothing's due today.")
        XCTAssertEqual(TaskSpeech.sentence(overdue: [], today: [task("Buy milk")], calendar: calendar),
                       "You have 1 task due today: Buy milk.")
        XCTAssertEqual(TaskSpeech.sentence(overdue: [task("Taxes")], today: [], calendar: calendar),
                       "Nothing's due today. 1 is overdue: Taxes.")

        let timed = TaskSpeech.sentence(overdue: [task("A"), task("B")],
                                        today: [task("Call", due: "2026-09-15T22:00:00Z", hasTime: true), task("Milk")],
                                        calendar: calendar)
        XCTAssertTrue(timed.hasPrefix("You have 2 tasks due today: Call at 3:00"), timed)
        XCTAssertTrue(timed.hasSuffix("and Milk. 2 are overdue: A and B."), timed)
    }

    func testALongListNamesAFewAndCountsTheRest() {
        let many = (1...7).map { task("T\($0)") }
        XCTAssertEqual(TaskSpeech.sentence(overdue: [], today: many, calendar: calendar, limit: 3),
                       "You have 7 tasks due today: T1, T2, T3, and 4 more.")
    }
}
