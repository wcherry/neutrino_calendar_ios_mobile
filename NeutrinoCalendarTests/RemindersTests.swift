import XCTest
@testable import NeutrinoCalendar

// MARK: - Models

final class ReminderModelTests: XCTestCase {

    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    }

    private func date(_ iso: String) -> Date { ServerDate.parse(iso)! }

    func testDecodesTheServersShape() throws {
        let json = """
        {"id":"r1","title":"Call Mum","dueTime":"2026-09-24T17:00:00Z","completed":false,
         "recurrenceRule":"","linkedEventId":null,"linkedTaskId":"t1",
         "createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-01T00:00:00Z"}
        """
        let reminder = try JSONDecoder().decode(Reminder.self, from: Data(json.utf8))
        XCTAssertEqual(reminder.due, date("2026-09-24T17:00:00Z"))
        XCTAssertNil(reminder.recurrenceRule, "an empty rule is no rule")
        XCTAssertEqual(reminder.linkedTaskId, "t1")
    }

    /// The web's `reminderRangeEnd`: the end of the last day in local time, today counting as the
    /// first, so "7 days" from a Thursday runs to the end of Wednesday.
    func testRangeEndsAtTheEndOfItsLastLocalDay() {
        let thursdayMorning = date("2026-09-24T16:00:00Z") // 09:00 PDT
        // Within a microsecond: a millisecond less than midnight is not exact in floating point.
        XCTAssertEqual(ReminderRange.today.end(now: thursdayMorning, calendar: calendar)!.timeIntervalSince1970,
                       date("2026-09-25T06:59:59.999Z").timeIntervalSince1970, accuracy: 1e-6)
        XCTAssertEqual(ReminderRange.sevenDays.end(now: thursdayMorning, calendar: calendar)!.timeIntervalSince1970,
                       date("2026-10-01T06:59:59.999Z").timeIntervalSince1970, accuracy: 1e-6)
        XCTAssertNil(ReminderRange.all.end(now: thursdayMorning, calendar: calendar))
    }

    func testOverdueRemindersAreInEveryRange() {
        let now = date("2026-09-24T16:00:00Z")
        let yesterday = Reminder(id: "a", title: "a", due: date("2026-09-23T16:00:00Z"))
        let tomorrow = Reminder(id: "b", title: "b", due: date("2026-09-25T16:00:00Z"))
        for range in ReminderRange.allCases {
            XCTAssertTrue(range.contains(yesterday, now: now, calendar: calendar), "\(range)")
        }
        XCTAssertFalse(ReminderRange.today.contains(tomorrow, now: now, calendar: calendar))
        XCTAssertTrue(ReminderRange.threeDays.contains(tomorrow, now: now, calendar: calendar))
    }

    func testRepeatOptionsRoundTripTheWebsRules() {
        for option in RepeatOption.standard {
            XCTAssertEqual(RepeatOption(rule: option.rule), option)
        }
        XCTAssertEqual(RepeatOption(rule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"), .weekdays)
    }

    func testAnUnfamiliarRuleIsKeptVerbatim() {
        let option = RepeatOption(rule: "FREQ=MONTHLY;INTERVAL=3")
        XCTAssertEqual(option, .custom("FREQ=MONTHLY;INTERVAL=3"))
        XCTAssertEqual(option.rule, "FREQ=MONTHLY;INTERVAL=3")
        XCTAssertEqual(option.label, "Repeats every 3 months")
    }
}

// MARK: - Service

@MainActor
final class RemindersServiceTests: XCTestCase {

    private var service: RemindersService!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CalendarAPIClient(session: URLSession(configuration: config),
                                       baseURL: { "https://example.test" }, token: { "tok" })
        service = RemindersService(client: client, timeZone: { TimeZone(identifier: "America/New_York")! })
    }

    private func date(_ iso: String) -> Date { ServerDate.parse(iso)! }

    private func json(id: String, title: String = "Stretch", due: String, completed: Bool = false,
                      rule: String? = nil, event: String? = nil) -> String {
        let r = rule.map { "\"\($0)\"" } ?? "null"
        let e = event.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":"\(id)","title":"\(title)","dueTime":"\(due)","completed":\(completed),
         "recurrenceRule":\(r),"linkedEventId":\(e),"linkedTaskId":null,
         "createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-01T00:00:00Z"}
        """
    }

    private func load(_ items: [String]) async {
        MockURLProtocol.respond(status: 200, body: "{\"reminders\":[\(items.joined(separator: ","))]}")
        await service.reload()
    }

    func testReloadAndOrdering() async {
        await load([
            json(id: "late", due: "2026-09-26T17:00:00Z"),
            json(id: "done", due: "2026-09-20T17:00:00Z", completed: true),
            json(id: "soon", due: "2026-09-24T17:00:00Z"),
        ])
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/v1/calendar/reminders")
        let visible = service.visible(in: .all)
        XCTAssertEqual(visible.open.map(\.id), ["soon", "late"])
        XCTAssertEqual(visible.done.map(\.id), ["done"])
    }

    func testSearchAndHiddenCount() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        await load([
            json(id: "a", title: "Water plants", due: "2026-09-24T17:00:00Z"),
            json(id: "b", title: "Pay rent", due: "2026-10-01T17:00:00Z"),
        ])
        let now = date("2026-09-24T16:00:00Z")
        XCTAssertEqual(service.visible(in: .all, matching: "rent").open.map(\.id), ["b"])
        XCTAssertEqual(service.visible(in: .today, now: now, calendar: calendar).open.map(\.id), ["a"])
        XCTAssertEqual(service.hiddenCount(by: .today, now: now, calendar: calendar), 1)
    }

    func testEventRemindersAreFoundByEvent() async {
        await load([
            json(id: "e1", due: "2026-09-24T16:50:00Z", event: "ev"),
            json(id: "free", due: "2026-09-24T17:00:00Z"),
        ])
        XCTAssertEqual(service.reminders(forEvent: "ev").map(\.id), ["e1"])
    }

    /// The server moves a recurring reminder on completion; the list must show where it moved to,
    /// open, not a ticked-off copy of the old one.
    func testCompletingKeepsTheServersAnswerAndSendsTheZone() async throws {
        await load([json(id: "r", due: "2026-09-24T13:00:00Z", rule: "FREQ=DAILY")])
        MockURLProtocol.respond(status: 200, body: json(id: "r", due: "2026-09-25T13:00:00Z", rule: "FREQ=DAILY"))

        await service.setCompleted(try XCTUnwrap(service.reminders.first), true)

        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/api/v1/calendar/reminders/r")
        XCTAssertEqual(MockURLProtocol.lastJSON?["completed"] as? Bool, true)
        XCTAssertEqual(MockURLProtocol.lastJSON?["timezone"] as? String, "America/New_York")
        XCTAssertEqual(service.reminders.map(\.due), [date("2026-09-25T13:00:00Z")])
        XCTAssertEqual(service.reminders.first?.completed, false)
    }

    func testUncompletingSendsNoZone() async throws {
        await load([json(id: "r", due: "2026-09-24T13:00:00Z", completed: true)])
        MockURLProtocol.respond(status: 200, body: json(id: "r", due: "2026-09-24T13:00:00Z"))
        await service.setCompleted(try XCTUnwrap(service.reminders.first), false)
        XCTAssertEqual(MockURLProtocol.lastJSON?["completed"] as? Bool, false)
        XCTAssertNil(MockURLProtocol.lastJSON?["timezone"])
    }

    func testEditSendsOnlyWhatChangedAndClearsARuleWithAnEmptyString() async throws {
        await load([json(id: "r", title: "Stretch", due: "2026-09-24T13:00:00Z", rule: "FREQ=DAILY")])
        let reminder = try XCTUnwrap(service.reminders.first)
        MockURLProtocol.respond(status: 200, body: json(id: "r", title: "Stretch", due: "2026-09-24T13:00:00Z"))

        try await service.update(reminder, title: "Stretch", due: reminder.due, rule: nil)

        XCTAssertEqual(MockURLProtocol.lastJSON?.keys.sorted(), ["recurrenceRule"])
        XCTAssertEqual(MockURLProtocol.lastJSON?["recurrenceRule"] as? String, "")
        XCTAssertNil(service.reminders.first?.recurrenceRule)
    }

    func testAnUnchangedEditSendsNothing() async throws {
        await load([json(id: "r", due: "2026-09-24T13:00:00Z")])
        let reminder = try XCTUnwrap(service.reminders.first)
        MockURLProtocol.reset()
        try await service.update(reminder, title: reminder.title, due: reminder.due, rule: nil)
        XCTAssertNil(MockURLProtocol.lastRequest)
    }

    func testCreateLinksAndAppends() async throws {
        await load([])
        MockURLProtocol.respond(status: 201, body: json(id: "new", title: "Standup", due: "2026-09-24T15:50:00Z", event: "ev"))

        try await service.create(title: "Standup", due: date("2026-09-24T15:50:00Z"), rule: nil, eventID: "ev")

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(MockURLProtocol.lastJSON?["linkedEventId"] as? String, "ev")
        XCTAssertEqual(MockURLProtocol.lastJSON?["dueTime"] as? String, "2026-09-24T15:50:00Z")
        XCTAssertEqual(service.reminders(forEvent: "ev").map(\.id), ["new"])
    }

    func testDeleteAndReset() async throws {
        await load([json(id: "a", due: "2026-09-24T13:00:00Z"), json(id: "b", due: "2026-09-25T13:00:00Z")])
        MockURLProtocol.respond(status: 204, body: "")
        await service.delete(try XCTUnwrap(service.reminders.first { $0.id == "a" }))
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(service.reminders.map(\.id), ["b"])

        service.reset()
        XCTAssertTrue(service.reminders.isEmpty)
        XCTAssertFalse(service.hasLoaded)
    }

    func testAFailedCompletionIsReportedAndChangesNothing() async throws {
        await load([json(id: "r", due: "2026-09-24T13:00:00Z")])
        MockURLProtocol.respond(status: 500, body: "{}")
        await service.setCompleted(try XCTUnwrap(service.reminders.first), true)
        XCTAssertNotNil(service.error)
        XCTAssertEqual(service.reminders.first?.completed, false)
    }
}
