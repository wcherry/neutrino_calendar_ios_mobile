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

    private func service(body: String = #"{"events":[]}"#, status: Int = 200) -> EventsService {
        MockURLProtocol.respond(status: status, body: body)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CalendarAPIClient(session: URLSession(configuration: config),
                                       baseURL: { "https://example.test" }, token: { "tok" })
        return EventsService(client: client, calendar: calendar, now: { self.date("2026-09-15T19:00:00Z") })
    }

    /// Month loads, leaving out the changes-feed cursor each load may ask for first.
    private var listRequests: Int {
        MockURLProtocol.requests.filter { $0.url?.path == "/api/v1/calendar/events" }.count
    }

    private static let weekly = """
    {"events":[{"id":"w","title":"Weekly","startTime":"2026-09-02T17:00:00Z",
      "endTime":"2026-09-02T18:00:00Z","allDay":false,"recurrenceRule":"FREQ=WEEKLY",
      "attendees":[],"source":"local"}]}
    """

    func testLoadingTheMonthFetchesTheWebsRangeAndExpandsRecurrence() async throws {
        let service = service(body: Self.weekly)

        await service.ensureLoaded(for: .agenda)

        XCTAssertNil(service.error)
        XCTAssertFalse(service.isLoading)
        XCTAssertEqual(service.sections.map { ymd($0.day) },
                       ["2026-09-02", "2026-09-09", "2026-09-16", "2026-09-23", "2026-09-30"])
        let query = URLComponents(url: try XCTUnwrap(MockURLProtocol.lastRequest?.url),
                                  resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "from" }?.value, "2026-09-01T07:00:00Z")
        XCTAssertEqual(service.occurrences(on: date("2026-09-16T19:00:00Z")).map(\.event.id), ["w"])
    }

    func testALoadedMonthIsNotFetchedAgainButAReloadIs() async {
        let service = service()
        await service.ensureLoaded(for: .month)
        await service.ensureLoaded(for: .day)
        await service.ensureLoaded(for: .agenda)
        XCTAssertEqual(listRequests, 1, "the same month, three views, one request")

        await service.reload(for: .month)
        XCTAssertEqual(listRequests, 2)
    }

    /// A week that crosses a month end needs both months, each fetched with the web's range.
    func testAWeekAcrossAMonthEndLoadsBothMonths() async {
        let service = service()
        service.select(date("2026-09-30T19:00:00Z"))
        await service.ensureLoaded(for: .week)
        let froms = MockURLProtocol.requests.compactMap {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "from" }?.value
        }
        XCTAssertEqual(froms, ["2026-09-01T07:00:00Z", "2026-10-01T07:00:00Z"])
    }

    func testAYearNeedsNoEvents() {
        XCTAssertTrue(service().months(for: .year).isEmpty)
    }

    func testFailureIsReported() async {
        let service = service(body: "{}", status: 500)
        await service.ensureLoaded(for: .month)
        XCTAssertEqual(service.error, CalendarAPIError.serverError(statusCode: 500).localizedDescription)
        XCTAssertTrue(service.sections.isEmpty)
        XCTAssertFalse(service.hasLoaded(service.month))
    }

    func testInvalidateThrowsTheCacheAwayAndBumpsTheGeneration() async {
        let service = service(body: Self.weekly)
        await service.ensureLoaded(for: .month)
        XCTAssertTrue(service.hasLoaded(service.month))

        service.invalidate()

        XCTAssertFalse(service.hasLoaded(service.month))
        XCTAssertEqual(service.generation, 1)
    }

    func testResetForgetsTheAccountsEvents() async {
        let service = service(body: Self.weekly)
        service.move(.month, by: 1)
        await service.ensureLoaded(for: .month)
        XCTAssertTrue(service.hasLoaded(service.month))

        service.reset()

        XCTAssertTrue(service.byMonth.isEmpty)
        XCTAssertNil(service.error)
        XCTAssertEqual(ymd(service.focus), "2026-09-15")
    }

    // MARK: - Navigation

    /// Months and years land on the 1st, or on today in today's month, as the iPhone's Calendar
    /// does; days and weeks keep the weekday.
    func testNavigationStepsByTheModesUnit() {
        let service = service()
        XCTAssertEqual(ymd(service.focus), "2026-09-15")

        service.move(.month, by: 1)
        XCTAssertEqual(ymd(service.focus), "2026-10-01")
        service.move(.month, by: -1)
        XCTAssertEqual(ymd(service.focus), "2026-09-15", "back in today's month lands on today")

        service.move(.week, by: 1)
        XCTAssertEqual(ymd(service.focus), "2026-09-22")
        service.move(.day, by: -2)
        XCTAssertEqual(ymd(service.focus), "2026-09-20")
        service.move(.year, by: 1)
        XCTAssertEqual(ymd(service.focus), "2027-09-01")

        service.goToToday()
        XCTAssertEqual(ymd(service.focus), "2026-09-15")
    }

    func testTodayButtonState() {
        let service = service()
        XCTAssertTrue(service.isShowingToday(.day))
        XCTAssertTrue(service.isShowingToday(.month))

        service.select(date("2026-09-17T19:00:00Z"))
        XCTAssertTrue(service.isShowingToday(.week), "the 17th is in today's week")
        XCTAssertFalse(service.isShowingToday(.day))
        XCTAssertTrue(service.isShowingToday(.year))

        service.move(.week, by: 1)
        XCTAssertFalse(service.isShowingToday(.week))
    }
}
