import CoreSpotlight
import XCTest
@testable import NeutrinoCalendar

/// Epic 16: the Focus filter, "What's next", the Add Event draft, and what Spotlight indexes.
@MainActor
final class SiriSpotlightTests: XCTestCase {

    private var calendar: Calendar!
    /// Tuesday, September 15, 2026, 12:00 in Los Angeles.
    private let now = ServerDate.parse("2026-09-15T19:00:00Z")!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        MockURLProtocol.reset()
    }

    private func date(_ iso: String) -> Date { ServerDate.parse(iso)! }

    private func occurrence(_ id: String, _ start: String, _ end: String, allDay: Bool = false,
                            location: String? = nil, source: EventSource = .local,
                            rule: String? = nil) -> EventOccurrence {
        let event = CalendarEvent(id: id, title: id, start: date(start), end: date(end), allDay: allDay,
                                  location: location, recurrenceRule: rule, source: source)
        return EventOccurrence(event: event, start: event.start, end: event.end)
    }

    // MARK: - SourceFilter

    func testNoFilterShowsEverySource() {
        for source in [EventSource.local, .google, .outlook, .apple, .other("caldav")] {
            XCTAssertTrue(SourceFilter.all.shows(source))
        }
        XCTAssertFalse(SourceFilter.all.isActive)
        XCTAssertNil(SourceFilter.all.summary)
    }

    func testAFilterShowsOnlyTheChosenSources() {
        let work = SourceFilter(shown: [.neutrino, .outlook])
        XCTAssertTrue(work.shows(.local))
        XCTAssertTrue(work.shows(.outlook))
        XCTAssertFalse(work.shows(.google))
        XCTAssertFalse(work.shows(.apple))
        XCTAssertFalse(work.shows(.other("caldav")), "a source nothing chose is hidden")
    }

    func testChoosingNothingIsNoFilter() {
        XCTAssertEqual(SourceFilter(shown: []), .all)
    }

    func testSummaryListsTheSourcesInOrder() {
        XCTAssertEqual(SourceFilter(shown: [.google, .neutrino]).summary, "Neutrino and Google")
    }

    func testTheFilterSurvivesARelaunchAndClears() {
        let defaults = UserDefaults(suiteName: "SiriSpotlightTests")!
        defaults.removePersistentDomain(forName: "SiriSpotlightTests")
        XCTAssertEqual(SourceFilter.load(from: defaults), .all)

        SourceFilter(shown: [.icloud]).save(to: defaults)
        XCTAssertEqual(SourceFilter.load(from: defaults), SourceFilter(shown: [.icloud]))

        SourceFilter.all.save(to: defaults)
        XCTAssertNil(defaults.object(forKey: SourceFilter.storageKey))
        XCTAssertEqual(SourceFilter.load(from: defaults), .all)
    }

    // MARK: - EventsService

    private func service(body: String) -> EventsService {
        MockURLProtocol.respond(status: 200, body: body)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CalendarAPIClient(session: URLSession(configuration: config),
                                       baseURL: { "https://example.test" }, token: { "tok" })
        return EventsService(client: client, calendar: calendar, weekStart: .sunday, sourceFilter: .all,
                             now: { self.now })
    }

    private static let mixed = """
    {"events":[
      {"id":"mine","title":"Mine","startTime":"2026-09-15T20:00:00Z","endTime":"2026-09-15T21:00:00Z",
       "allDay":false,"attendees":[],"source":"local"},
      {"id":"theirs","title":"Theirs","startTime":"2026-09-15T22:00:00Z","endTime":"2026-09-15T23:00:00Z",
       "allDay":false,"attendees":[],"source":"google"},
      {"id":"done","title":"Done","startTime":"2026-09-15T15:00:00Z","endTime":"2026-09-15T16:00:00Z",
       "allDay":false,"attendees":[],"source":"local"},
      {"id":"daily","title":"Daily","startTime":"2026-09-10T23:30:00Z","endTime":"2026-09-10T23:45:00Z",
       "allDay":false,"recurrenceRule":"FREQ=DAILY","attendees":[],"source":"local"}
    ]}
    """

    func testTheFocusFilterHidesEventsFromEveryViewWithoutAReload() async {
        let service = service(body: Self.mixed)
        await service.ensureLoaded(for: .day)
        let requests = MockURLProtocol.requests.count
        XCTAssertTrue(service.occurrences(on: now).map(\.event.id).contains("theirs"))

        service.setSourceFilter(SourceFilter(shown: [.neutrino]))
        XCTAssertFalse(service.occurrences(on: now).map(\.event.id).contains("theirs"))
        XCTAssertFalse(service.sections.flatMap(\.occurrences).map(\.event.id).contains("theirs"))

        service.setSourceFilter(.all)
        XCTAssertTrue(service.occurrences(on: now).map(\.event.id).contains("theirs"))
        XCTAssertEqual(MockURLProtocol.requests.count, requests, "filtering is local")
    }

    func testUpcomingAsksFromTheStartOfTodayAndDropsWhatIsOver() async throws {
        let service = service(body: Self.mixed)
        let upcoming = try await service.upcoming(days: 7)

        let query = URLComponents(url: try XCTUnwrap(MockURLProtocol.lastRequest?.url),
                                  resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "from" }?.value, "2026-09-15T07:00:00Z")
        XCTAssertEqual(query.first { $0.name == "to" }?.value, "2026-09-22T07:00:00Z")
        XCTAssertFalse(upcoming.contains { $0.event.id == "done" })
        XCTAssertEqual(Array(upcoming.prefix(3).map(\.event.id)), ["mine", "theirs", "daily"])
        XCTAssertEqual(upcoming.filter { $0.event.id == "daily" }.count, 7, "every day of the week ahead")
    }

    // MARK: - UpNext

    func testAnEventUnderWayIsStillUpcoming() {
        let upcoming = UpNext.upcoming([
            occurrence("later", "2026-09-15T21:00:00Z", "2026-09-15T22:00:00Z"),
            occurrence("now", "2026-09-15T18:30:00Z", "2026-09-15T19:30:00Z"),
            occurrence("over", "2026-09-15T17:00:00Z", "2026-09-15T19:00:00Z"),
        ], now: now, calendar: calendar)
        XCTAssertEqual(upcoming.map(\.event.id), ["now", "later"], "an event ending now is over")
    }

    func testAnAllDayEventLastsItsWholeDateInTheLocalZone() {
        // Stored as UTC 23:59:59 on the 15th, which is 16:59 in Los Angeles: still today there.
        let upcoming = UpNext.upcoming([
            occurrence("today", "2026-09-15T00:00:00Z", "2026-09-15T23:59:59Z", allDay: true),
            occurrence("yesterday", "2026-09-14T00:00:00Z", "2026-09-14T23:59:59Z", allDay: true),
            occurrence("timed", "2026-09-15T20:00:00Z", "2026-09-15T21:00:00Z"),
        ], now: date("2026-09-16T01:00:00Z"), calendar: calendar)
        XCTAssertEqual(upcoming.map(\.event.id), ["today"], "18:00 in LA: the timed event is over, the date is not")
    }

    func testNextSkipsAllDayEventsAndHiddenSources() {
        let upcoming = UpNext.upcoming([
            occurrence("holiday", "2026-09-15T00:00:00Z", "2026-09-15T23:59:59Z", allDay: true),
            occurrence("google", "2026-09-15T20:00:00Z", "2026-09-15T21:00:00Z", source: .google),
            occurrence("mine", "2026-09-15T22:00:00Z", "2026-09-15T23:00:00Z"),
        ], now: now, calendar: calendar)
        XCTAssertEqual(UpNext.next(upcoming, filter: .all)?.event.id, "google")
        XCTAssertEqual(UpNext.next(upcoming, filter: SourceFilter(shown: [.neutrino]))?.event.id, "mine")
        XCTAssertNil(UpNext.next([upcoming[0]], filter: .all))
    }

    func testFirstOfEachKeepsOneOccurrencePerEvent() {
        let daily = occurrence("daily", "2026-09-15T20:00:00Z", "2026-09-15T21:00:00Z", rule: "FREQ=DAILY")
        let tomorrow = EventOccurrence(event: daily.event, start: daily.start.addingTimeInterval(86_400),
                                       end: daily.end.addingTimeInterval(86_400))
        let other = occurrence("other", "2026-09-15T22:00:00Z", "2026-09-15T23:00:00Z")
        XCTAssertEqual(UpNext.firstOfEach([daily, other, tomorrow]), [daily, other])
    }

    func testSentences() {
        let under = occurrence("Stand-up", "2026-09-15T18:45:00Z", "2026-09-15T19:30:00Z")
        let text = UpNext.sentence(for: under, now: now, calendar: calendar, days: 7)
        XCTAssertTrue(text.hasPrefix("Stand-up is on now, until 12:30"), text)

        let tomorrow = occurrence("Dentist", "2026-09-16T16:00:00Z", "2026-09-16T17:00:00Z", location: "Main St")
        let next = UpNext.sentence(for: tomorrow, now: now, calendar: calendar, days: 7)
        XCTAssertTrue(next.hasPrefix("Next is Dentist, tomorrow at 9:00"), next)
        XCTAssertTrue(next.hasSuffix(", at Main St."), next)

        XCTAssertEqual(UpNext.sentence(for: nil, now: now, calendar: calendar, days: 7),
                       "There's nothing on your calendar in the next 7 days.")
    }

    func testWhenNamesTheDay() {
        XCTAssertEqual(UpNext.when(date("2026-09-15T23:00:00Z"), now: now, calendar: calendar), "today")
        // 01:00 UTC on the 16th is still the 15th in Los Angeles.
        XCTAssertEqual(UpNext.when(date("2026-09-16T01:00:00Z"), now: now, calendar: calendar), "today")
        XCTAssertEqual(UpNext.when(date("2026-09-16T19:00:00Z"), now: now, calendar: calendar), "tomorrow")
        XCTAssertEqual(UpNext.when(date("2026-09-18T19:00:00Z"), now: now, calendar: calendar), "on Friday")
        XCTAssertEqual(UpNext.when(date("2026-10-03T19:00:00Z"), now: now, calendar: calendar), "on Oct 3")
    }

    func testConfirmations() {
        let timed = occurrence("Lunch", "2026-09-15T19:30:00Z", "2026-09-15T20:30:00Z")
        XCTAssertTrue(UpNext.added(timed, now: now, calendar: calendar).hasPrefix("Added Lunch, today at 12:30"))
        let holiday = occurrence("Holiday", "2026-10-03T00:00:00Z", "2026-10-03T23:59:59Z", allDay: true)
        XCTAssertEqual(UpNext.added(holiday, now: now, calendar: calendar), "Added Holiday, on Oct 3, all day.")
        let remind = UpNext.willRemind("Call the bank", due: date("2026-09-16T00:00:00Z"), now: now, calendar: calendar)
        XCTAssertTrue(remind.hasPrefix("I'll remind you about Call the bank today at 5:00"), remind)
    }

    // MARK: - EventLink

    func testALinkRoundTrips() {
        let link = EventLink(eventID: "3f2a-uuid", start: date("2026-09-15T20:00:00Z"))
        XCTAssertEqual(link.string, "3f2a-uuid@1789502400")
        XCTAssertEqual(EventLink(string: link.string), link)
        XCTAssertNil(EventLink(string: "no-start"))
        XCTAssertNil(EventLink(string: "@1789502400"))
        XCTAssertNil(EventLink(string: "id@soon"))
    }

    func testALinkOpensTheOccurrenceItNames() {
        let weekly = occurrence("w", "2026-09-01T17:00:00Z", "2026-09-01T18:30:00Z", rule: "FREQ=WEEKLY").event
        let third = EventLink(eventID: "w", start: date("2026-09-15T17:00:00Z")).occurrence(of: weekly)
        XCTAssertEqual(third.start, date("2026-09-15T17:00:00Z"))
        XCTAssertEqual(third.end, date("2026-09-15T18:30:00Z"), "the event's own length")

        // A one-off that moved since it was indexed opens where it is now.
        let moved = occurrence("m", "2026-09-20T17:00:00Z", "2026-09-20T18:00:00Z").event
        let opened = EventLink(eventID: "m", start: date("2026-09-15T17:00:00Z")).occurrence(of: moved)
        XCTAssertEqual(opened.start, moved.start)
    }

    // MARK: - Add Event

    func testAnEventFromSiriIsAnHourLongByDefault() {
        let draft = EventDraft(title: " Lunch ", start: date("2026-09-15T19:00:00Z"), end: nil, allDay: false,
                               location: "Cafe", calendar: calendar)
        XCTAssertNil(draft.problem)
        let request = draft.createRequest()
        XCTAssertEqual(request.title, "Lunch")
        XCTAssertEqual(request.startTime, "2026-09-15T19:00:00Z")
        XCTAssertEqual(request.endTime, "2026-09-15T20:00:00Z")
        XCTAssertEqual(request.location, "Cafe")
        XCTAssertEqual(request.timezone, "America/Los_Angeles")
    }

    func testAnAllDayEventFromSiriIsItsDay() {
        // 20:00 on the 15th in Los Angeles is already the 16th in UTC; the date is the local one.
        let draft = EventDraft(title: "Off", start: date("2026-09-16T03:00:00Z"), end: nil, allDay: true,
                               location: nil, calendar: calendar)
        let request = draft.createRequest()
        XCTAssertEqual(request.startTime, "2026-09-15T00:00:00Z")
        XCTAssertEqual(request.endTime, "2026-09-15T23:59:59Z")
        XCTAssertNil(request.timezone)
        XCTAssertNil(request.location)
    }

    func testAnEventFromSiriEndingBeforeItStartsIsRefused() {
        let draft = EventDraft(title: "Oops", start: date("2026-09-15T19:00:00Z"),
                               end: date("2026-09-15T18:00:00Z"), allDay: false, location: nil, calendar: calendar)
        XCTAssertEqual(draft.problem, "The event ends before it starts.")
        XCTAssertNotNil(EventDraft(title: "  ", start: now, end: nil, allDay: false, location: nil,
                                   calendar: calendar).problem)
    }

    // MARK: - Spotlight

    func testSpotlightIndexesEachEventOnceAtItsNextOccurrence() {
        let daily = occurrence("daily", "2026-09-15T20:00:00Z", "2026-09-15T20:15:00Z",
                               location: "Room 4", rule: "FREQ=DAILY")
        let tomorrow = EventOccurrence(event: daily.event, start: daily.start.addingTimeInterval(86_400),
                                       end: daily.end.addingTimeInterval(86_400))
        let items = SpotlightIndexer.items(for: [daily, tomorrow], calendar: calendar)

        XCTAssertEqual(items.count, 1)
        let item = items[0]
        XCTAssertEqual(item.uniqueIdentifier, EventLink(daily).string)
        XCTAssertEqual(item.domainIdentifier, SpotlightIndexer.domain)
        XCTAssertEqual(item.attributeSet.title, "daily")
        XCTAssertEqual(item.attributeSet.startDate, daily.start)
        XCTAssertEqual(item.attributeSet.namedLocation, "Room 4")
        XCTAssertEqual(item.expirationDate, daily.end, "gone once it is over")
        let description = item.attributeSet.contentDescription ?? ""
        XCTAssertTrue(description.hasPrefix("Tue, Sep 15 · 1:00"), description)
        XCTAssertTrue(description.hasSuffix(" · Room 4"), description)
    }

    func testAnAllDayItemExpiresAfterItsLastLocalDay() {
        let trip = occurrence("trip", "2026-09-15T00:00:00Z", "2026-09-17T23:59:59Z", allDay: true, source: .apple)
        let item = SpotlightIndexer.item(for: trip, calendar: calendar)
        XCTAssertEqual(item.expirationDate, date("2026-09-18T07:00:00Z"), "midnight after the 17th in LA")
        XCTAssertEqual(item.attributeSet.keywords, ["iCloud"])
        XCTAssertEqual(item.attributeSet.allDay, true)
    }
}
