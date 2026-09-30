import XCTest
@testable import NeutrinoCalendar

/// "This event / this and following / all events" (neutrino/agent_docs/recurrence-exceptions.md).
///
/// The expansion cases are the web's `recurrenceExceptions.test.ts`, so both clients put an
/// exception on the same occurrence. The rest checks what each scope sends.
@MainActor
final class RecurrenceExceptionTests: XCTestCase {

    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        MockURLProtocol.reset()
    }

    private func date(_ iso: String) -> Date { ServerDate.parse(iso)! }

    /// Daily at 09:00 UTC from Monday 4 January 2027, five times.
    private func standup(_ rule: String = "FREQ=DAILY;COUNT=5", start: String = "2027-01-04T09:00:00Z") -> CalendarEvent {
        CalendarEvent(id: "series", title: "Standup", start: date(start),
                      end: date(start).addingTimeInterval(1800), recurrenceRule: rule)
    }

    private func exception(_ id: String, _ original: String, title: String = "Standup", start: String? = nil,
                           cancelled: Bool = false, series: String = "series") -> CalendarEvent {
        let at = date(start ?? original)
        return CalendarEvent(id: id, title: title, start: at, end: at.addingTimeInterval(1800),
                             recurringEventId: series, originalStart: date(original), cancelled: cancelled)
    }

    private func january(_ events: [CalendarEvent]) -> [EventOccurrence] {
        RecurrenceExpander.expand(events, from: date("2027-01-01T00:00:00Z"), to: date("2027-01-31T23:59:59Z"),
                                  calendar: calendar)
    }

    /// Sorted: occurrences come out series by series, and the views sort them by start.
    private func summary(_ events: [CalendarEvent]) -> [String] {
        january(events).map { "\(ServerDate.format($0.start).dropFirst(5).prefix(11)) \($0.event.title)" }.sorted()
    }

    // MARK: - Expansion

    func testEveryOccurrenceCarriesItsSeriesAndItsStartInIt() {
        let first = january([standup()])[0]
        XCTAssertEqual(first.series?.id, "series")
        XCTAssertEqual(first.originalStart, date("2027-01-04T09:00:00Z"))
        XCTAssertTrue(first.isRepeating)
    }

    func testAnEditedOccurrenceReplacesTheOneItStandsFor() {
        XCTAssertEqual(summary([standup(), exception("ex", "2027-01-05T09:00:00Z", title: "Planning",
                                                     start: "2027-01-05T14:00:00Z")]),
                       ["01-04T09:00 Standup", "01-05T14:00 Planning", "01-06T09:00 Standup",
                        "01-07T09:00 Standup", "01-08T09:00 Standup"])
    }

    func testAnEditedOccurrenceKeepsItsSeriesAndOriginalStartForTheNextEdit() throws {
        let shown = try XCTUnwrap(january([standup(), exception("ex", "2027-01-05T09:00:00Z", title: "Planning")])
            .first { $0.event.title == "Planning" })
        XCTAssertEqual(shown.event.id, "ex")
        XCTAssertEqual(shown.series?.id, "series")
        XCTAssertEqual(shown.originalStart, date("2027-01-05T09:00:00Z"))
    }

    func testACancelledOccurrenceGoesAndStillCountsTowardsCount() {
        XCTAssertEqual(summary([standup(), exception("ex", "2027-01-06T09:00:00Z", cancelled: true)]),
                       ["01-04T09:00 Standup", "01-05T09:00 Standup", "01-07T09:00 Standup", "01-08T09:00 Standup"])
    }

    func testAnExceptionMatchesUpToTwoHoursAwayAsAViewerInAnotherZoneSeesIt() {
        XCTAssertFalse(summary([standup(), exception("ex", "2027-01-06T08:00:00Z", cancelled: true)])
            .contains("01-06T09:00 Standup"))
        XCTAssertTrue(summary([standup(), exception("ex", "2027-01-06T06:00:00Z", cancelled: true)])
            .contains("01-06T09:00 Standup"))
    }

    func testAnOccurrenceMovedInFromOutsideTheRangeShowsAndOneMovedOutDoesNot() {
        let series = standup("FREQ=WEEKLY", start: "2026-12-28T09:00:00Z")
        XCTAssertEqual(summary([
            series,
            exception("in", "2026-12-28T09:00:00Z", title: "Moved in", start: "2027-01-02T09:00:00Z"),
            exception("out", "2027-01-25T09:00:00Z", title: "Moved out", start: "2027-02-02T09:00:00Z"),
        ]), ["01-02T09:00 Moved in", "01-04T09:00 Standup", "01-11T09:00 Standup", "01-18T09:00 Standup"])
    }

    func testAnExceptionWhoseOccurrenceTheSeriesNoLongerHasIsNotShown() {
        XCTAssertFalse(summary([standup(), exception("orphan", "2027-01-20T09:00:00Z", title: "Orphan")])
            .contains("01-20T09:00 Orphan"))
    }

    func testOtherSeriesExceptionsAreIgnored() {
        XCTAssertEqual(summary([standup(), exception("ex", "2027-01-05T09:00:00Z", cancelled: true, series: "other")]).count, 5)
    }

    func testThisAndFollowingTakesTheOccurrencesBeforeOffCount() {
        XCTAssertEqual(RecurrenceExpander.rule(of: standup(), from: date("2027-01-06T09:00:00Z"), calendar: calendar),
                       "FREQ=DAILY;COUNT=3")
        XCTAssertEqual(RecurrenceExpander.rule(of: standup("FREQ=WEEKLY;BYDAY=MO"), from: date("2027-01-11T09:00:00Z"),
                                               calendar: calendar),
                       "FREQ=WEEKLY;BYDAY=MO")
    }

    // MARK: - The form

    private func occurrence(on day: String) -> EventOccurrence {
        january([standup()]).first { ServerDate.format($0.start).hasPrefix(day) }!
    }

    func testTheFormForEachScope() {
        let third = occurrence(on: "2027-01-06")

        let this = EventDraft(editing: third, scope: .this, calendar: calendar)
        XCTAssertEqual(this.start, date("2027-01-06T09:00:00Z"))

        let following = EventDraft(editing: third, scope: .following, calendar: calendar)
        XCTAssertEqual(following.start, date("2027-01-06T09:00:00Z"))
        XCTAssertEqual(following.repeatOption.rule, "FREQ=DAILY;COUNT=3")

        let all = EventDraft(editing: third, scope: .all, calendar: calendar)
        XCTAssertEqual(all.start, date("2027-01-04T09:00:00Z"), "the series, from its own start")
    }

    func testThisAndFollowingFromTheFirstOccurrenceIsTheWholeSeries() {
        let first = occurrence(on: "2027-01-04")
        XCTAssertEqual(EventDraft.effectiveScope(first, .following), .all)
        XCTAssertEqual(EventDraft.effectiveScope(occurrence(on: "2027-01-05"), .following), .following)
        let oneOff = EventOccurrence(event: standup(""), start: date("2027-01-04T09:00:00Z"), end: date("2027-01-04T09:30:00Z"))
        XCTAssertNil(EventDraft.effectiveScope(oneOff, .this))
    }

    // MARK: - What each scope sends

    private func service() -> EventsService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CalendarAPIClient(session: URLSession(configuration: config),
                                       baseURL: { "https://example.test" }, token: { "tok" })
        return EventsService(client: client, calendar: calendar, weekStart: .sunday,
                             now: { self.date("2027-01-01T00:00:00Z") })
    }

    private static let saved = #"{"id":"new","title":"Standup","startTime":"2027-01-06T09:00:00Z","endTime":"2027-01-06T09:30:00Z","allDay":false,"source":"local"}"#

    private func edit(_ scope: RecurrenceScope, change: (inout EventDraft) -> Void) async throws -> URLRequest {
        MockURLProtocol.respond(status: 200, body: Self.saved)
        let third = occurrence(on: "2027-01-06")
        let original = EventDraft(editing: third, scope: scope, calendar: calendar)
        var draft = original
        change(&draft)
        try await service().update(third, scope: scope, from: original, to: draft)
        return try XCTUnwrap(MockURLProtocol.requests.last)
    }

    func testThisEventEditsTheOccurrenceOnly() async throws {
        let request = try await edit(.this) { $0.title = "Planning" }
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/api/v1/calendar/events/series/occurrences/2027-01-06T09:00:00Z")
        XCTAssertEqual(MockURLProtocol.lastJSON?["title"] as? String, "Planning")
        XCTAssertNil(MockURLProtocol.lastJSON?["recurrenceRule"], "one occurrence can't repeat")
    }

    func testThisAndFollowingSplitsTheSeriesSendingTheRuleLeft() async throws {
        let request = try await edit(.following) { $0.location = "Room 2" }
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/calendar/events/series/split")
        let json = try XCTUnwrap(MockURLProtocol.lastJSON)
        XCTAssertEqual(json["originalStartTime"] as? String, "2027-01-06T09:00:00Z")
        XCTAssertEqual(json["location"] as? String, "Room 2")
        XCTAssertEqual(json["recurrenceRule"] as? String, "FREQ=DAILY;COUNT=3")
        XCTAssertNil(json["startTime"], "it starts where the occurrence did")
    }

    func testAllEventsEditsTheSeries() async throws {
        // The conflict check reads the series first.
        MockURLProtocol.respondInSequence([
            (200, #"{"id":"series","title":"Standup","startTime":"2027-01-04T09:00:00Z","endTime":"2027-01-04T09:30:00Z","allDay":false,"recurrenceRule":"FREQ=DAILY;COUNT=5","source":"local"}"#),
            (200, Self.saved),
        ])
        let third = occurrence(on: "2027-01-06")
        let original = EventDraft(editing: third, scope: .all, calendar: calendar)
        var draft = original
        draft.title = "Daily sync"
        try await service().update(third, scope: .all, from: original, to: draft)

        let request = try XCTUnwrap(MockURLProtocol.requests.last)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/api/v1/calendar/events/series")
        XCTAssertEqual(MockURLProtocol.lastJSON?["title"] as? String, "Daily sync")
    }

    func testEachDeleteScopeSendsItsOwnRequest() async throws {
        let third = occurrence(on: "2027-01-06")
        let expected: [(RecurrenceScope, String, String?)] = [
            (.this, "/api/v1/calendar/events/series/occurrences/2027-01-06T09:00:00Z", nil),
            (.following, "/api/v1/calendar/events/series", "fromOccurrence=2027-01-06T09:00:00Z"),
            (.all, "/api/v1/calendar/events/series", nil),
        ]
        for (scope, path, query) in expected {
            MockURLProtocol.reset()
            MockURLProtocol.respond(status: 204, body: "")
            try await service().delete(third, scope: scope)
            let request = try XCTUnwrap(MockURLProtocol.lastRequest)
            XCTAssertEqual(request.httpMethod, "DELETE", "\(scope)")
            XCTAssertEqual(request.url?.path, path, "\(scope)")
            XCTAssertEqual(request.url?.query, query, "\(scope)")
        }
    }

    func testListsAndTheChangesFeedAskForExceptions() async throws {
        MockURLProtocol.respond(status: 200, body: #"{"events":[]}"#)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CalendarAPIClient(session: URLSession(configuration: config),
                                       baseURL: { "https://example.test" }, token: { "tok" })
        _ = try await client.events(from: date("2027-01-01T00:00:00Z"), to: date("2027-01-31T00:00:00Z"))
        XCTAssertTrue(MockURLProtocol.lastRequest?.url?.query?.contains("exceptions=true") == true)

        MockURLProtocol.respond(status: 200, body: #"{"events":[],"deletedIds":[],"cursor":"c","fullResyncRequired":false}"#)
        _ = try await client.eventChanges(since: "c0")
        XCTAssertTrue(MockURLProtocol.lastRequest?.url?.query?.contains("exceptions=true") == true)
    }

    func testDecodesAnException() throws {
        let json = #"{"id":"ex","title":"t","startTime":"2027-01-05T14:00:00Z","endTime":"2027-01-05T14:30:00Z","allDay":false,"source":"local","recurringEventId":"series","originalStartTime":"2027-01-05T09:00:00Z","cancelled":true}"#
        let event = try JSONDecoder().decode(CalendarEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.recurringEventId, "series")
        XCTAssertEqual(event.originalStart, date("2027-01-05T09:00:00Z"))
        XCTAssertTrue(event.cancelled)
    }

    // MARK: - The changes feed

    func testAnExceptionIsHeldWithItsSeriesAndGoesWithIt() {
        let range = (from: date("2027-01-01T00:00:00Z"), to: date("2027-01-31T23:59:59Z"))
        let ex = exception("ex", "2027-01-05T09:00:00Z", title: "Planning")
        let held = EventsService.merge([standup()], changed: [ex], deleted: [], from: range.from, to: range.to)
        XCTAssertEqual(held.map(\.id).sorted(), ["ex", "series"])

        let unrelated = exception("other-ex", "2027-01-05T09:00:00Z", series: "elsewhere")
        XCTAssertEqual(EventsService.merge(held, changed: [unrelated], deleted: [], from: range.from, to: range.to)
            .map(\.id).sorted(), ["ex", "series"], "its series isn't held in this month")

        XCTAssertEqual(EventsService.merge(held, changed: [], deleted: ["series"], from: range.from, to: range.to), [])
    }

    // MARK: - Reminders

    private func reminders() -> RemindersService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CalendarAPIClient(session: URLSession(configuration: config),
                                       baseURL: { "https://example.test" }, token: { "tok" })
        return RemindersService(client: client, timeZone: { TimeZone(identifier: "Europe/London")! })
    }

    private let vitamins = Reminder(id: "r1", title: "Vitamins", due: ServerDate.parse("2027-01-04T09:00:00Z")!,
                                    recurrenceRule: "FREQ=DAILY")

    func testDeletingThisReminderSkipsTheSeriesOn() async throws {
        MockURLProtocol.respond(status: 200, body: #"{"series":{"id":"r1","title":"Vitamins","dueTime":"2027-01-05T09:00:00Z","completed":false,"recurrenceRule":"FREQ=DAILY"}}"#)
        let service = reminders()
        await service.delete(vitamins, scope: .this)

        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/v1/calendar/reminders/r1/skip")
        XCTAssertEqual(MockURLProtocol.lastJSON?["timezone"] as? String, "Europe/London")
        XCTAssertEqual(service.reminders.map(\.due), [date("2027-01-05T09:00:00Z")])
    }

    func testEditingThisReminderMakesAOneOffAndMovesTheSeriesOn() async throws {
        MockURLProtocol.respond(status: 200, body: """
        {"reminder":{"id":"one","title":"Vitamins with food","dueTime":"2027-01-04T12:00:00Z","completed":false},
         "series":null}
        """)
        let service = reminders()
        try await service.update(vitamins, scope: .this, title: "Vitamins with food",
                                 due: date("2027-01-04T12:00:00Z"), rule: "FREQ=DAILY")

        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/v1/calendar/reminders/r1/occurrence")
        let json = try XCTUnwrap(MockURLProtocol.lastJSON)
        XCTAssertEqual(json["title"] as? String, "Vitamins with food")
        XCTAssertEqual(json["dueTime"] as? String, "2027-01-04T12:00:00Z")
        XCTAssertEqual(service.reminders.map(\.id), ["one"], "the series ran out and went")
    }

    func testThisAndFollowingRemindersEditTheSeries() async throws {
        MockURLProtocol.respondInSequence([
            (200, #"{"id":"r1","title":"Vitamins","dueTime":"2027-01-04T09:00:00Z","completed":false,"recurrenceRule":"FREQ=DAILY"}"#),
            (200, #"{"id":"r1","title":"Pills","dueTime":"2027-01-04T09:00:00Z","completed":false,"recurrenceRule":"FREQ=DAILY"}"#),
        ])
        try await reminders().update(vitamins, scope: .following, title: "Pills", due: vitamins.due, rule: "FREQ=DAILY")
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "PATCH")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/v1/calendar/reminders/r1")
    }
}
