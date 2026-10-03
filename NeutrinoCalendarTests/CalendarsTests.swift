import SwiftUI
import XCTest
@testable import NeutrinoCalendar

private func date(_ iso: String) -> Date { ServerDate.parse(iso)! }

/// Lets a task just started run up to its first suspension: for checking what an optimistic
/// change shows before the server answers.
@MainActor
private func settle(until condition: () -> Bool) async {
    for _ in 0..<50 where !condition() { await Task.yield() }
}

private func calendar(_ id: String, visible: Bool = true, readOnly: Bool = false, kind: UserCalendar.Kind = .local,
                      color: String = "#3b82f6", country: String? = nil, region: String? = nil,
                      observances: Bool = false, isDefault: Bool = false) -> UserCalendar {
    UserCalendar(id: id, name: id, color: color, visible: visible, readOnly: readOnly, kind: kind,
                 isDefault: isDefault, country: country, region: region, includeObservances: observances)
}

private func event(_ id: String, in calendarID: String?, source: EventSource = .local,
                   start: String = "2026-10-01T09:00:00Z", end: String = "2026-10-01T10:00:00Z") -> CalendarEvent {
    CalendarEvent(id: id, title: id, start: date(start), end: date(end), source: source, calendarId: calendarID)
}

// MARK: - Holidays

/// The same expectations as the web's `calendars.test.ts`, against the same `date-holidays`
/// rules, run by the bundled engine in JavaScriptCore.
final class HolidayEngineTests: XCTestCase {

    private let engine = HolidayEngine()
    private let us = calendar("us", readOnly: true, kind: .holidays, country: "US")

    private func holidays(_ calendar: UserCalendar, _ from: String, _ to: String) async throws -> [CalendarEvent] {
        let engine = engine
        var byYear: [Int: [HolidayEngine.Record]] = [:]
        for year in Int(from.prefix(4))!...Int(to.prefix(4))! {
            byYear[year] = try await engine.holidays(country: calendar.country!, region: calendar.region,
                                                     year: year, language: "en-US")
        }
        return Holidays.events(of: calendar, from: date(from), to: date(to)) { byYear[$0] ?? [] }
    }

    private func days(_ events: [CalendarEvent], _ title: String) -> [String] {
        events.filter { $0.title == title }.map { Holidays.dayString($0.start) }
    }

    func testThanksgivingIsTheFourthThursdayOfNovemberThisYearAndNext() async throws {
        let twoYears = try await holidays(us, "2026-01-01T00:00:00Z", "2027-12-31T23:59:59Z")
        XCTAssertEqual(days(twoYears, "Thanksgiving Day"), ["2026-11-26", "2027-11-25"])
    }

    func testLaborDayIsTheFirstMondayOfSeptemberThisYearAndNext() async throws {
        let twoYears = try await holidays(us, "2026-01-01T00:00:00Z", "2027-12-31T23:59:59Z")
        XCTAssertEqual(days(twoYears, "Labor Day"), ["2026-09-07", "2027-09-06"], "en-US says Labor, not Labour")
    }

    func testHolidaysAreAllDayEventsInTheirCalendar() async throws {
        let twoYears = try await holidays(us, "2026-01-01T00:00:00Z", "2027-12-31T23:59:59Z")
        let thanksgiving = try XCTUnwrap(twoYears.first { $0.title == "Thanksgiving Day" })
        XCTAssertTrue(thanksgiving.allDay)
        XCTAssertEqual(thanksgiving.start, date("2026-11-26T00:00:00Z"))
        XCTAssertEqual(thanksgiving.end, date("2026-11-26T23:59:59Z"))
        XCTAssertEqual(thanksgiving.calendarId, "us")
        XCTAssertEqual(thanksgiving.source, .holidays)
        XCTAssertTrue(CalendarRules([us]).isReadOnly(thanksgiving))
        XCTAssertFalse(CalendarRules([us]).isEditable(thanksgiving))
    }

    func testObservancesOnlyWhenAskedFor() async throws {
        let year = try await holidays(us, "2026-01-01T00:00:00Z", "2027-12-31T23:59:59Z")
        XCTAssertEqual(days(year, "Mother's Day"), [])
        let withObservances = try await holidays(calendar("us", readOnly: true, kind: .holidays, country: "US", observances: true),
                                                 "2026-01-01T00:00:00Z", "2026-12-31T23:59:59Z")
        XCTAssertEqual(days(withObservances, "Mother's Day"), ["2026-05-10"])
        XCTAssertEqual(days(withObservances, "Halloween"), ["2026-10-31"])
    }

    func testOnlyTheDaysInTheRange() async throws {
        let november = try await holidays(us, "2026-11-01T00:00:00Z", "2026-11-30T23:59:59Z")
        XCTAssertTrue(november.allSatisfy { Holidays.dayString($0.start).hasPrefix("2026-11") })
        XCTAssertEqual(days(november, "Thanksgiving Day"), ["2026-11-26"])
    }

    func testARegionAddsItsOwnHolidays() async throws {
        let de = calendar("de", readOnly: true, kind: .holidays, country: "DE")
        let nationwide = try await holidays(de, "2026-01-01T00:00:00Z", "2026-12-31T23:59:59Z")
        let bavaria = try await holidays(calendar("de", readOnly: true, kind: .holidays, country: "DE", region: "BY"),
                                         "2026-01-01T00:00:00Z", "2026-12-31T23:59:59Z")
        XCTAssertGreaterThan(bavaria.count, nationwide.count)
    }

    func testNothingForACalendarThatIsntAHolidayCalendar() async throws {
        let plain = calendar("mine", country: "US")
        XCTAssertEqual(Holidays.events(of: plain, from: date("2026-01-01T00:00:00Z"),
                                       to: date("2026-12-31T23:59:59Z")) { _ in [] }, [])
    }

    func testEachCountryInItsOwnCalendarAndHidingOneHidesOnlyIt() async {
        let ca = calendar("ca", readOnly: true, kind: .holidays, color: "#e11d48", country: "CA")
        let both = await engine.occurrences(for: [us, ca], from: date("2026-07-01T00:00:00Z"),
                                            to: date("2026-07-31T23:59:59Z"), language: "en-US")
        XCTAssertEqual(both.first { $0.event.title == "Independence Day" }?.event.calendarId, "us")
        XCTAssertEqual(both.first { $0.event.title == "Canada Day" }?.event.calendarId, "ca")

        var hiddenUS = us
        hiddenUS.visible = false
        let filter = EventFilter(rules: CalendarRules([hiddenUS, ca]), focus: .all)
        let shown = both.filter { filter.shows($0.event) }.map(\.event.title)
        XCTAssertFalse(shown.contains("Independence Day"))
        XCTAssertTrue(shown.contains("Canada Day"))
    }

    func testListsCountriesAndRegions() async throws {
        let countries = try await engine.countries(language: "en-US")
        XCTAssertGreaterThan(countries.count, 150)
        XCTAssertTrue(countries.contains { $0.code == "US" })
        let states = try await engine.regions(country: "US", language: "en-US")
        XCTAssertTrue(states.contains { $0.code == "CA" })
    }

    /// The bundle is the web's: same version as the web locks, whenever the sibling checkout is
    /// here. Run `scripts/sync_date_holidays.sh` when this fails.
    func testBundleIsTheWebsVersion() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let ours = try String(contentsOf: repo.appendingPathComponent("NeutrinoCalendar/Resources/DateHolidays/VERSION"),
                              encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let web = repo.deletingLastPathComponent().appendingPathComponent("neutrino/web/apps/web/package.json")
        guard let data = try? Data(contentsOf: web),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let wanted = (json["dependencies"] as? [String: String])?["date-holidays"] else {
            throw XCTSkip("no sibling neutrino checkout")
        }
        // "^3.37.0": the bundle must be at least that, and the same major.
        let floor = wanted.trimmingCharacters(in: CharacterSet(charactersIn: "^~"))
        XCTAssertEqual(ours.split(separator: ".").first, floor.split(separator: ".").first)
        XCTAssertNotEqual(ours.compare(floor, options: .numeric), .orderedAscending, "bundle \(ours) is older than the web's \(wanted)")
    }
}

// MARK: - Calendar rules

/// The web's `visibleEvents`, `isReadOnlyEvent` and `writableCalendars` cases.
final class CalendarRulesTests: XCTestCase {

    func testHiddenCalendarsEventsAreDroppedAndUnknownOnesKept() {
        let rules = CalendarRules([calendar("shown"), calendar("hidden", visible: false)])
        let events = [event("a", in: "shown"), event("b", in: "hidden"), event("c", in: nil), event("d", in: "unknown")]
        XCTAssertEqual(events.filter(rules.isShown).map(\.id), ["a", "c", "d"])
    }

    func testReadOnlyInAReadOnlyCalendarAndForAHoliday() {
        let rules = CalendarRules([calendar("mine"), calendar("us", readOnly: true, kind: .holidays, country: "US")])
        XCTAssertFalse(rules.isReadOnly(event("a", in: "mine")))
        XCTAssertTrue(rules.isReadOnly(event("b", in: "us")))
        XCTAssertTrue(rules.isReadOnly(event("c", in: nil, source: .holidays)))
        XCTAssertFalse(rules.isReadOnly(event("d", in: nil)))
    }

    /// Synced events stay read-only here, by source, until the server writes back (Epic 17).
    func testOnlyNeutrinosOwnEventsInAWritableCalendarAreEditable() {
        let rules = CalendarRules([calendar("mine"), calendar("work", readOnly: true)])
        XCTAssertTrue(rules.isEditable(event("a", in: "mine")))
        XCTAssertFalse(rules.isEditable(event("b", in: "work")))
        XCTAssertFalse(rules.isEditable(event("c", in: "mine", source: .google)))
        XCTAssertFalse(rules.isEditable(event("d", in: nil, source: .task)))
    }

    func testOnlyWritableCalendarsAreOffered() {
        let us = calendar("us", readOnly: true, kind: .holidays, country: "US")
        XCTAssertEqual(CalendarRules.writable([calendar("mine"), us]).map(\.id), ["mine"])
    }

    func testColourComesFromTheCalendar() {
        let rules = CalendarRules([calendar("red", color: "#e11d48")])
        XCTAssertEqual(rules.color(of: event("a", in: "red")), "#e11d48")
        XCTAssertNil(rules.color(of: event("b", in: nil)))
        XCTAssertNotNil(Color(hex: "#e11d48"))
        XCTAssertNil(Color(hex: "red"))
    }

    /// The Focus filter and the calendars combine: an event shows only if both allow it.
    func testFocusAndVisibilityBothHaveToAllowIt() {
        let rules = CalendarRules([calendar("shown"), calendar("hidden", visible: false)])
        let work = EventFilter(rules: rules, focus: SourceFilter(shown: [.neutrino]))
        XCTAssertTrue(work.shows(event("a", in: "shown")))
        XCTAssertFalse(work.shows(event("b", in: "hidden")), "hidden even though the Focus allows Neutrino")
        XCTAssertFalse(work.shows(event("c", in: "shown", source: .google)), "the Focus hides Google")
        XCTAssertTrue(work.shows(event("d", in: nil, source: .holidays)), "holidays are Neutrino's own")
        XCTAssertTrue(work.ignoringFocus.shows(event("e", in: "shown", source: .google)))
        XCTAssertFalse(work.ignoringFocus.shows(event("f", in: "hidden")))
    }

    func testDecodesTheServersShapes() throws {
        let body = #"""
        {"calendars":[{"id":"c1","name":"Personal","color":"#16a34a","visible":false,"readOnly":false,
          "kind":"local","isDefault":true,"source":null,"country":null,"region":null,"includeObservances":false,
          "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"},
         {"id":"c2","name":"United States","color":"#3b82f6","visible":true,"readOnly":true,"kind":"holidays",
          "isDefault":false,"country":"US","region":"CA","includeObservances":true},
         {"id":"c3","name":"Later","kind":"something-new"}]}
        """#
        let list = try JSONDecoder().decode(ListCalendarsResponse.self, from: Data(body.utf8)).calendars
        XCTAssertEqual(list.map(\.id), ["c1", "c2", "c3"])
        XCTAssertFalse(list[0].visible)
        XCTAssertTrue(list[0].isDefault)
        XCTAssertEqual(list[1].kind, .holidays)
        XCTAssertEqual(list[1].region, "CA")
        XCTAssertTrue(list[1].includeObservances)
        XCTAssertEqual(list[2].kind, .local, "an unknown kind doesn't fail the list")

        let withCalendar = try JSONDecoder().decode(CalendarEvent.self, from: Data(#"""
        {"id":"e","title":"t","startTime":"2026-10-01T09:00:00Z","endTime":"2026-10-01T10:00:00Z","calendarId":"c1"}
        """#.utf8))
        XCTAssertEqual(withCalendar.calendarId, "c1")
        let older = try JSONDecoder().decode(CalendarEvent.self, from: Data(#"""
        {"id":"e","title":"t","startTime":"2026-10-01T09:00:00Z","endTime":"2026-10-01T10:00:00Z"}
        """#.utf8))
        XCTAssertNil(older.calendarId)
    }
}

// MARK: - Event requests

final class EventCalendarRequestTests: XCTestCase {

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    func testANewEventNamesItsCalendarOnlyWhenOneWasPicked() throws {
        var draft = EventDraft(newOn: date("2026-10-05T00:00:00Z"))
        draft.title = "Dentist"
        XCTAssertNil(try json(draft.createRequest())["calendarId"], "the server's default")
        draft.calendarId = "work"
        XCTAssertEqual(try json(draft.createRequest())["calendarId"] as? String, "work")
    }

    func testAnEditSendsTheCalendarOnlyWhenItChanged() throws {
        let original = EventDraft(editing: event("e", in: "home"))
        var draft = original
        draft.title = "Renamed"
        XCTAssertNil(try json(draft.updateRequest(from: original))["calendarId"])
        draft.calendarId = "work"
        XCTAssertEqual(try json(draft.updateRequest(from: original))["calendarId"] as? String, "work")
    }

    func testMovedOnBothSidesIsAConflictAboutTheCalendar() {
        XCTAssertEqual(EditConflict.clashes(mine: UpdateEventRequest(calendarId: "a"),
                                            theirs: UpdateEventRequest(calendarId: "b")), ["calendar"])
    }
}

// MARK: - Tasks on the calendar

/// The web's `taskEvents` (`calendarTasks.ts`).
final class TaskOccurrencesTests: XCTestCase {

    private let october = (date("2026-10-01T00:00:00Z"), date("2026-10-31T23:59:59Z"))

    func testADatedTaskIsAllDayAndATimedOneLastsItsEstimate() throws {
        let tasks = [
            CalendarTask(id: "d", title: "Pay rent", dueDate: date("2026-10-05T00:00:00Z")),
            CalendarTask(id: "t", title: "Call", dueDate: date("2026-10-06T15:00:00Z"), dueHasTime: true, estimateMinutes: 45),
            CalendarTask(id: "n", title: "No estimate", dueDate: date("2026-10-07T09:00:00Z"), dueHasTime: true),
        ]
        let occurrences = TaskOccurrences.occurrences(tasks, from: october.0, to: october.1)
        let byID = Dictionary(uniqueKeysWithValues: occurrences.map { ($0.task!.id, $0) })

        let dated = try XCTUnwrap(byID["d"])
        XCTAssertTrue(dated.event.allDay)
        XCTAssertEqual(dated.start, date("2026-10-05T00:00:00Z"))
        XCTAssertEqual(dated.end, date("2026-10-05T23:59:59Z"))
        XCTAssertEqual(dated.event.source, .task)
        XCTAssertEqual(dated.event.id, "task:d")

        XCTAssertEqual(byID["t"]?.end, date("2026-10-06T15:45:00Z"))
        XCTAssertEqual(byID["n"]?.end, date("2026-10-07T09:30:00Z"), "half an hour without an estimate")
    }

    func testScheduledUndatedAndOutOfRangeTasksAreLeftOutAndDoneOnesStay() {
        let tasks = [
            CalendarTask(id: "scheduled", title: "On the calendar", dueDate: date("2026-10-05T00:00:00Z"), eventId: "ev"),
            CalendarTask(id: "undated", title: "Someday"),
            CalendarTask(id: "november", title: "Later", dueDate: date("2026-11-02T00:00:00Z")),
            CalendarTask(id: "done", title: "Done", done: true, dueDate: date("2026-10-09T00:00:00Z")),
        ]
        let ids = TaskOccurrences.occurrences(tasks, from: october.0, to: october.1).map { $0.task!.id }
        XCTAssertEqual(ids, ["done"])
    }
}

// MARK: - EventsService

@MainActor
final class EventsCalendarsTests: XCTestCase {

    private var service: EventsService!
    private var pacific: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CalendarAPIClient(session: URLSession(configuration: config),
                                       baseURL: { "https://example.test" }, token: { "tok" })
        service = EventsService(client: client, calendar: pacific, weekStart: .sunday, sourceFilter: .all,
                                holidays: HolidayEngine(), now: { date("2026-11-20T18:00:00Z") })
    }

    private func respond(_ events: [String]) {
        MockURLProtocol.respondInSequence([(200, #"{"cursor":"c1","events":[],"deletedIds":[]}"#),
                                           (200, #"{"events":[\#(events.joined(separator: ","))]}"#)])
    }

    private func json(_ id: String, calendar: String?, start: String, end: String) -> String {
        let c = calendar.map { "\"\($0)\"" } ?? "null"
        return #"{"id":"\#(id)","title":"\#(id)","startTime":"\#(start)","endTime":"\#(end)","calendarId":\#(c)}"#
    }

    func testHiddenCalendarsEventsLeaveEveryViewAndComeBack() async {
        await service.setCalendars([calendar("home"), calendar("work", visible: false)])
        respond([json("dinner", calendar: "home", start: "2026-11-21T02:00:00Z", end: "2026-11-21T03:00:00Z"),
                 json("standup", calendar: "work", start: "2026-11-20T17:00:00Z", end: "2026-11-20T17:30:00Z")])
        await service.ensureLoaded(for: .month)
        let day = pacific.startOfDay(for: date("2026-11-20T18:00:00Z"))
        XCTAssertEqual(service.occurrences(on: day).map(\.event.id), ["dinner"])
        XCTAssertTrue(service.isInHiddenCalendar(eventID: "standup"))

        await service.setCalendars([calendar("home"), calendar("work")])
        XCTAssertEqual(Set(service.occurrences(on: day).map(\.event.id)), ["dinner", "standup"], "no reload needed")
        XCTAssertFalse(service.isInHiddenCalendar(eventID: "standup"))
    }

    func testHolidaysShowOfflineAndTasksShowWhateverIsHidden() async {
        await service.setCalendars([calendar("us", readOnly: true, kind: .holidays, country: "US")])
        service.setTasks([CalendarTask(id: "t", title: "Buy turkey", dueDate: date("2026-11-26T00:00:00Z"))])
        MockURLProtocol.respond(status: MockURLProtocol.offline, body: "")
        await service.ensureLoaded(for: .month)

        let thanksgiving = pacific.date(from: DateComponents(year: 2026, month: 11, day: 26))!
        let titles = service.occurrences(on: thanksgiving).map(\.event.title)
        XCTAssertTrue(titles.contains("Buy turkey"))
        XCTAssertTrue(titles.contains { $0.hasPrefix("Thanksgiving") }, "\(titles)")

        // Hiding the holidays hides them, not the task.
        await service.setCalendars([calendar("us", visible: false, readOnly: true, kind: .holidays, country: "US")])
        XCTAssertEqual(service.occurrences(on: thanksgiving).map(\.event.title), ["Buy turkey"])
    }

    func testATaskOnTheCalendarIsOnItsDayOnly() async {
        MockURLProtocol.respond(status: MockURLProtocol.offline, body: "")
        service.setTasks([CalendarTask(id: "t", title: "Pay rent", dueDate: date("2026-11-30T00:00:00Z"))])
        await service.ensureLoaded(for: .month)
        let last = pacific.date(from: DateComponents(year: 2026, month: 11, day: 30))!
        let before = pacific.date(from: DateComponents(year: 2026, month: 11, day: 29))!
        XCTAssertEqual(service.occurrences(on: last).compactMap(\.task?.id), ["t"], "a date, not a UTC instant")
        XCTAssertTrue(service.occurrences(on: before).isEmpty)
    }
}

// MARK: - Surfaces

@MainActor
final class CalendarSurfacesTests: XCTestCase {

    func testWidgetsLeaveOutHiddenCalendarsAndCarryColours() {
        var zone = Calendar(identifier: .gregorian)
        zone.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = date("2026-09-15T16:00:00Z")
        let occurrences = [event("home", in: "home", start: "2026-09-15T18:00:00Z", end: "2026-09-15T19:00:00Z"),
                           event("work", in: "work", start: "2026-09-15T20:00:00Z", end: "2026-09-15T21:00:00Z")]
            .map { EventOccurrence(event: $0, start: $0.start, end: $0.end) }
        let filter = EventFilter(rules: CalendarRules([calendar("home", color: "#e11d48"), calendar("work", visible: false)]),
                                 focus: .all)
        let snapshot = WidgetSnapshotStore.build(occurrences, now: now, calendar: zone, filter: filter)
        XCTAssertEqual(snapshot.events.map(\.title), ["home"])
        XCTAssertEqual(snapshot.events.first?.color, "#e11d48")
        XCTAssertNil(LiveActivities.candidate(UpNext.upcoming(Array(occurrences.suffix(1)), now: now, calendar: zone),
                                              now: date("2026-09-15T19:30:00Z"), filter: filter))
    }

    /// A snapshot written before calendars still decodes.
    func testAnOldSnapshotStillReads() throws {
        let old = #"{"signedIn":true,"generatedAt":0,"timeZone":"UTC","firstWeekday":1,"busyDays":[],"events":[{"id":"e@0","title":"t","start":0,"end":60,"allDay":false,"firstDay":"1970-01-01","lastDay":"1970-01-01"}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let snapshot = try decoder.decode(WidgetSnapshot.self, from: Data(old.utf8))
        XCTAssertNil(snapshot.events.first?.color)
    }
}

// MARK: - Services

@MainActor
final class CalendarsServiceTests: XCTestCase {

    private var cacheURL: URL!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("calendars-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheURL)
        super.tearDown()
    }

    private func makeService() -> CalendarsService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return CalendarsService(client: CalendarAPIClient(session: URLSession(configuration: config),
                                                          baseURL: { "https://example.test" }, token: { "tok" }),
                                cacheURL: cacheURL)
    }

    private let list = ##"{"calendars":[{"id":"w","name":"Work","color":"#16a34a","visible":true,"readOnly":false,"kind":"local","isDefault":false},{"id":"p","name":"Personal","color":"#3b82f6","visible":true,"readOnly":false,"kind":"local","isDefault":true}]}"##

    func testTheListIsKeptForOfflineAndDefaultComesFirst() async {
        MockURLProtocol.respond(status: 200, body: list)
        let service = makeService()
        await service.reload()
        XCTAssertEqual(service.calendars.map(\.id), ["p", "w"])
        XCTAssertEqual(service.defaultCalendar?.id, "p")

        // A launch with no network still knows them.
        XCTAssertEqual(makeService().calendars.map(\.id), ["p", "w"])
    }

    func testHidingShowsAtOnceAndRollsBackOnError() async {
        MockURLProtocol.respond(status: 200, body: list)
        let service = makeService()
        await service.reload()
        let work = service.calendar(id: "w")!

        MockURLProtocol.respond(status: 500, body: "")
        let hiding = Task { await service.setVisible(work, false) }
        await settle { service.calendar(id: "w")?.visible == false }
        // Applied before the request answers.
        XCTAssertEqual(service.calendar(id: "w")?.visible, false)
        await hiding.value
        XCTAssertEqual(service.calendar(id: "w")?.visible, true, "put back when the server refused")
        XCTAssertNotNil(service.error)
        XCTAssertEqual(MockURLProtocol.lastJSON?["visible"] as? Bool, false)
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "PATCH")
    }

    func testAddingACountrysHolidays() async throws {
        MockURLProtocol.respond(status: 201, body: ##"{"id":"h","name":"United States","color":"#f97316","visible":true,"readOnly":true,"kind":"holidays","isDefault":false,"country":"US"}"##)
        let service = makeService()
        try await service.create(.holidays(country: "US", name: "United States", color: "#f97316"))
        let body = try XCTUnwrap(MockURLProtocol.lastJSON)
        XCTAssertEqual(body["kind"] as? String, "holidays")
        XCTAssertEqual(body["country"] as? String, "US")
        XCTAssertEqual(service.holidayCalendars.map(\.id), ["h"])
    }

    func testSignOutForgetsTheCache() async {
        MockURLProtocol.respond(status: 200, body: list)
        let service = makeService()
        await service.reload()
        service.reset()
        XCTAssertTrue(makeService().calendars.isEmpty)
    }
}

@MainActor
final class ReadOnlyWritesTests: XCTestCase {

    /// A queued edit the server now refuses as read-only is dropped, and the user is told.
    func testAForbiddenReplayIsDroppedWithANotice() async {
        MockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CalendarAPIClient(session: URLSession(configuration: config),
                                       baseURL: { "https://example.test" }, token: { "tok" })
        let pending = PendingWrites(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("pw-\(UUID().uuidString).json"))
        pending.enqueue(PendingWrite(method: "PUT", path: "/api/v1/calendar/events/e", json: ["title": "x"]))
        MockURLProtocol.respond(status: 403, body: #"{"error":"This calendar is read-only"}"#)
        let done = await pending.replay(using: client)
        XCTAssertEqual(done, 1)
        XCTAssertTrue(pending.isEmpty, "not retried")
        XCTAssertNotNil(pending.notice)
        pending.dismissNotice()
        XCTAssertNil(pending.notice)
    }

    /// Ticked at once from the calendar, and unticked when the server refuses.
    func testATickIsUndoneWhenTheServerRefuses() async {
        MockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let tasks = TasksService(client: CalendarAPIClient(session: URLSession(configuration: config),
                                                           baseURL: { "https://example.test" }, token: { "tok" }))
        MockURLProtocol.respond(status: 200, body: #"[{"id":"t","title":"Pay rent","done":false}]"#)
        await tasks.reload()
        MockURLProtocol.respond(status: 500, body: "")
        let ticking = Task { await tasks.setDone(tasks.tasks[0], true) }
        await settle { tasks.task(id: "t")?.done == true }
        XCTAssertEqual(tasks.task(id: "t")?.done, true, "ticked before the answer")
        await ticking.value
        XCTAssertEqual(tasks.task(id: "t")?.done, false)
        XCTAssertEqual(MockURLProtocol.lastJSON?["done"] as? Bool, true)
        XCTAssertNotNil(MockURLProtocol.lastJSON?["timezone"] as? String)
    }
}

