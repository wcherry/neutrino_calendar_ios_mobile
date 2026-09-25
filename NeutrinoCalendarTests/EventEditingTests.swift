import XCTest
@testable import NeutrinoCalendar

// MARK: - Draft

final class EventDraftTests: XCTestCase {

    private var pacific: Calendar!

    override func setUp() {
        super.setUp()
        pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    }

    private func date(_ iso: String) -> Date { ServerDate.parse(iso)! }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    func testANewEventTodayStartsAtTheNextHourAndOtherDaysAtNine() {
        let now = date("2026-09-25T17:20:00Z") // 10:20 PDT
        let today = EventDraft(newOn: now, now: now, calendar: pacific)
        XCTAssertEqual(today.start, date("2026-09-25T18:00:00Z"))
        XCTAssertEqual(today.end, date("2026-09-25T19:00:00Z"))

        let later = EventDraft(newOn: date("2026-09-30T19:00:00Z"), now: now, calendar: pacific)
        XCTAssertEqual(later.start, date("2026-09-30T16:00:00Z"), "09:00 PDT")
        XCTAssertEqual(later.timeZone.identifier, "America/Los_Angeles")
    }

    /// Editing a repeating event edits the series, from its own start, whichever occurrence was
    /// tapped: saving an occurrence's date as the start would drop every occurrence before it.
    func testEditingSeedsFromTheEventNotTheOccurrence() {
        let series = CalendarEvent(id: "s", title: "Standup", start: date("2026-09-01T16:00:00Z"),
                                   end: date("2026-09-01T16:15:00Z"), recurrenceRule: "FREQ=DAILY",
                                   attendees: ["ada@example.com"], timezone: "America/New_York")
        let draft = EventDraft(editing: series, calendar: pacific)
        XCTAssertEqual(draft.start, series.start)
        XCTAssertEqual(draft.repeatOption, .daily)
        XCTAssertEqual(draft.timeZone.identifier, "America/New_York")
        XCTAssertEqual(draft.attendees, ["ada@example.com"])
    }

    func testAllDayIsWrittenAsDatesTheWebsWay() throws {
        let offsite = CalendarEvent(id: "o", title: "Offsite", start: date("2026-09-28T00:00:00Z"),
                                    end: date("2026-09-30T23:59:59Z"), allDay: true)
        let draft = EventDraft(editing: offsite, calendar: pacific)
        let body = try json(draft.createRequest())
        XCTAssertEqual(body["startTime"] as? String, "2026-09-28T00:00:00Z")
        XCTAssertEqual(body["endTime"] as? String, "2026-09-30T23:59:59Z")
        XCTAssertEqual(body["allDay"] as? Bool, true)
        XCTAssertNil(body["timezone"] as? String, "an all-day event carries no zone")
    }

    func testATimedEventCarriesItsZone() throws {
        var draft = EventDraft(newOn: date("2026-09-30T19:00:00Z"), calendar: pacific)
        draft.title = "Review"
        draft.timeZone = TimeZone(identifier: "America/New_York")!
        let body = try json(draft.createRequest())
        XCTAssertEqual(body["timezone"] as? String, "America/New_York")
        XCTAssertEqual(body["startTime"] as? String, ServerDate.format(draft.start))
        XCTAssertEqual(body["attendees"] as? [String], [])
        XCTAssertNil(body["location"] as? String, "an empty location is not sent on create")
    }

    func testAnEditSendsOnlyChangesAndClearsWithAnEmptyString() throws {
        let event = CalendarEvent(id: "e", title: "Review", description: "Bring notes",
                                  start: date("2026-09-30T18:00:00Z"), end: date("2026-09-30T19:00:00Z"),
                                  location: "Room 4", recurrenceRule: "FREQ=WEEKLY",
                                  timezone: "America/Los_Angeles")
        let original = EventDraft(editing: event, calendar: pacific)

        var draft = original
        XCTAssertEqual(draft.updateRequest(from: original), UpdateEventRequest(), "nothing changed")

        draft.location = "  "
        draft.repeatOption = .never
        let body = try json(draft.updateRequest(from: original))
        XCTAssertEqual(body.keys.sorted(), ["location", "recurrenceRule"])
        XCTAssertEqual(body["location"] as? String, "", "the server can't store NULL; empty means none")
        XCTAssertEqual(body["recurrenceRule"] as? String, "")
    }

    func testMovingTheTimeSendsAllThreeTimeFields() throws {
        let event = CalendarEvent(id: "e", title: "Review", start: date("2026-09-30T18:00:00Z"),
                                  end: date("2026-09-30T19:00:00Z"), timezone: "America/Los_Angeles")
        let original = EventDraft(editing: event, calendar: pacific)
        var draft = original
        draft.start = draft.start.addingTimeInterval(3600)
        draft.end = draft.end.addingTimeInterval(3600)
        let body = try json(draft.updateRequest(from: original))
        XCTAssertEqual(body.keys.sorted(), ["allDay", "endTime", "startTime"])
        XCTAssertEqual(body["startTime"] as? String, "2026-09-30T19:00:00Z")
    }

    func testChangingTheZoneKeepsTheClockTime() {
        var draft = EventDraft(newOn: date("2026-09-30T19:00:00Z"), calendar: pacific)
        XCTAssertEqual(draft.start, date("2026-09-30T16:00:00Z"), "09:00 PDT")
        draft.setTimeZone(TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(draft.start, date("2026-09-30T13:00:00Z"), "09:00 EDT")
        XCTAssertEqual(draft.end.timeIntervalSince(draft.start), EventDraft.defaultLength)
        XCTAssertEqual(draft.timeZone.identifier, "America/New_York")
    }

    func testGuestsAreCheckedAndNotDuplicated() {
        var draft = EventDraft(newOn: Date(), calendar: pacific)
        XCTAssertTrue(draft.addAttendee(" ada@example.com "))
        XCTAssertFalse(draft.addAttendee("ADA@example.com"), "case-insensitive duplicate")
        XCTAssertFalse(draft.addAttendee("ada"))
        XCTAssertFalse(draft.addAttendee("ada@localhost"))
        XCTAssertEqual(draft.attendees, ["ada@example.com"])
    }

    func testProblems() {
        var draft = EventDraft(newOn: date("2026-09-30T19:00:00Z"), calendar: pacific)
        XCTAssertEqual(draft.problem, "An event needs a title.")
        draft.title = "Review"
        XCTAssertNil(draft.problem)
        draft.end = draft.start.addingTimeInterval(-60)
        XCTAssertEqual(draft.problem, "The event ends before it starts.")
        // An all-day event may end on the day it starts.
        draft.allDay = true
        draft.end = draft.start
        XCTAssertNil(draft.problem)
    }
}

// MARK: - Service

@MainActor
final class EventEditingServiceTests: XCTestCase {

    private var service: EventsService!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CalendarAPIClient(session: URLSession(configuration: config),
                                       baseURL: { "https://example.test" }, token: { "tok" })
        service = EventsService(client: client)
    }

    private static let stored = """
    {"id":"e","title":"Review","startTime":"2026-09-30T18:00:00Z","endTime":"2026-09-30T19:00:00Z",
     "allDay":false,"attendees":[],"source":"local"}
    """

    func testCreatePostsAndThrowsTheCacheAway() async throws {
        MockURLProtocol.respond(status: 201, body: Self.stored)
        var draft = EventDraft(newOn: Date())
        draft.title = "Review"
        let created = try await service.create(draft)
        XCTAssertEqual(created.id, "e")
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/v1/calendar/events")
        XCTAssertEqual(service.generation, 1)
    }

    func testUpdatePutsOnlyChangesAndAnUnchangedOneSendsNothing() async throws {
        let event = CalendarEvent(id: "e", title: "Review", start: Date(), end: Date().addingTimeInterval(3600))
        let original = EventDraft(editing: event)

        try await service.update(event, from: original, to: original)
        XCTAssertNil(MockURLProtocol.lastRequest)
        XCTAssertEqual(service.generation, 0)

        var draft = original
        draft.title = "Design review"
        MockURLProtocol.respond(status: 200, body: Self.stored)
        try await service.update(event, from: original, to: draft)
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "PUT")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/v1/calendar/events/e")
        XCTAssertEqual(MockURLProtocol.lastJSON?.keys.sorted(), ["title"])
        XCTAssertEqual(service.generation, 1)
    }

    func testDelete() async throws {
        MockURLProtocol.respond(status: 204, body: "")
        let event = CalendarEvent(id: "e", title: "Review", start: Date(), end: Date())
        try await service.delete(event)
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/v1/calendar/events/e")
        XCTAssertEqual(service.generation, 1)
    }
}
