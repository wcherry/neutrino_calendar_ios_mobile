import XCTest
@testable import NeutrinoCalendar

@MainActor
final class EventsServiceTests: XCTestCase {

    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        MockURLProtocol.reset()
    }

    private func date(_ iso: String) -> Date { ServerDate.parse(iso)! }

    private func ymd(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day())
    }

    // MARK: - Month range

    func testMonthRangeMatchesTheWebsMonthRange() {
        // monthRange(new Date(2026, 8, 15)) in America/Los_Angeles.
        let range = EventsService.monthRange(date("2026-09-15T19:00:00Z"), calendar: calendar)
        XCTAssertEqual(ServerDate.format(range.from), "2026-09-01T07:00:00Z")
        XCTAssertEqual(ServerDate.format(range.to), "2026-10-01T06:59:59Z")
    }

    // MARK: - Layout

    func testMultiDayEventAppearsOnEachOfItsDays() {
        let trip = CalendarEvent(id: "trip", title: "Trip", start: date("2026-09-01T00:00:00Z"),
                                 end: date("2026-09-03T23:59:59Z"), allDay: true)
        let sections = EventsService.layout([EventOccurrence(event: trip, start: trip.start, end: trip.end)],
                                            in: date("2026-09-15T19:00:00Z"), calendar: calendar)
        XCTAssertEqual(sections.map { ymd($0.day) }, ["2026-09-01", "2026-09-02", "2026-09-03"])
    }

    func testLayoutKeepsOnlyTheMonthsOwnDays() {
        let late = CalendarEvent(id: "late", title: "Late", start: date("2026-09-30T20:00:00Z"),
                                 end: date("2026-10-02T20:00:00Z"))
        let sections = EventsService.layout([EventOccurrence(event: late, start: late.start, end: late.end)],
                                            in: date("2026-09-15T19:00:00Z"), calendar: calendar)
        XCTAssertEqual(sections.map { ymd($0.day) }, ["2026-09-30"])
    }

    func testWithinADayAllDayComesFirstThenStartThenTitle() {
        func occ(_ id: String, _ start: String, allDay: Bool = false) -> EventOccurrence {
            let s = date(start)
            let e = CalendarEvent(id: id, title: id, start: s,
                                  end: allDay ? date("2026-09-10T23:59:59Z") : s.addingTimeInterval(1800),
                                  allDay: allDay)
            return EventOccurrence(event: e, start: e.start, end: e.end)
        }
        let sections = EventsService.layout([
            occ("b-late", "2026-09-10T20:00:00Z"),
            occ("b-early", "2026-09-10T16:00:00Z"),
            occ("a-early", "2026-09-10T16:00:00Z"),
            occ("holiday", "2026-09-10T00:00:00Z", allDay: true),
        ], in: date("2026-09-15T19:00:00Z"), calendar: calendar)
        XCTAssertEqual(sections.first?.occurrences.map(\.event.id), ["holiday", "a-early", "b-early", "b-late"])
    }

    // MARK: - Loading

    func testReloadFetchesTheMonthAndExpandsRecurrence() async throws {
        MockURLProtocol.respond(status: 200, body: """
        {"events":[{"id":"w","title":"Weekly","startTime":"2026-09-02T17:00:00Z",
          "endTime":"2026-09-02T18:00:00Z","allDay":false,"recurrenceRule":"FREQ=WEEKLY",
          "attendees":[],"source":"local"}]}
        """)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CalendarAPIClient(session: URLSession(configuration: config),
                                       baseURL: { "https://example.test" }, token: { "tok" })
        let service = EventsService(client: client, calendar: calendar, now: { self.date("2026-09-15T19:00:00Z") })

        await service.reload()

        XCTAssertNil(service.error)
        XCTAssertFalse(service.isLoading)
        XCTAssertEqual(service.sections.map { ymd($0.day) },
                       ["2026-09-02", "2026-09-09", "2026-09-16", "2026-09-23", "2026-09-30"])
        let query = URLComponents(url: try XCTUnwrap(MockURLProtocol.lastRequest?.url),
                                  resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "from" }?.value, "2026-09-01T07:00:00Z")
    }

    func testReloadFailureIsReportedAndKeepsTheMonth() async {
        MockURLProtocol.respond(status: 500, body: "{}")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CalendarAPIClient(session: URLSession(configuration: config),
                                       baseURL: { "https://example.test" }, token: { "tok" })
        let service = EventsService(client: client, calendar: calendar, now: { self.date("2026-09-15T19:00:00Z") })

        await service.reload()

        XCTAssertEqual(service.error, CalendarAPIError.serverError(statusCode: 500).localizedDescription)
        XCTAssertTrue(service.sections.isEmpty)
        XCTAssertTrue(service.isShowingCurrentMonth)
    }

    func testResetForgetsTheAccountsEvents() async {
        MockURLProtocol.respond(status: 200, body: """
        {"events":[{"id":"a","title":"A","startTime":"2026-09-10T17:00:00Z","endTime":"2026-09-10T18:00:00Z",
          "allDay":false,"attendees":[],"source":"local"}]}
        """)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CalendarAPIClient(session: URLSession(configuration: config),
                                       baseURL: { "https://example.test" }, token: { "tok" })
        let service = EventsService(client: client, calendar: calendar, now: { self.date("2026-09-15T19:00:00Z") })
        await service.showNextMonth()
        await service.showPreviousMonth()
        XCTAssertFalse(service.sections.isEmpty)

        await service.showNextMonth()
        service.reset()

        XCTAssertTrue(service.sections.isEmpty)
        XCTAssertNil(service.error)
        XCTAssertTrue(service.isShowingCurrentMonth)
    }

    func testMonthNavigation() async {
        MockURLProtocol.respond(status: 200, body: #"{"events":[]}"#)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CalendarAPIClient(session: URLSession(configuration: config),
                                       baseURL: { "https://example.test" }, token: { "tok" })
        let service = EventsService(client: client, calendar: calendar, now: { self.date("2026-09-15T19:00:00Z") })

        await service.showNextMonth()
        XCTAssertEqual(ymd(service.month), "2026-10-01")
        XCTAssertFalse(service.isShowingCurrentMonth)
        await service.showPreviousMonth()
        await service.showPreviousMonth()
        XCTAssertEqual(ymd(service.month), "2026-08-01")
        await service.showToday()
        XCTAssertEqual(ymd(service.month), "2026-09-01")
    }
}
