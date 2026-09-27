import XCTest
@testable import NeutrinoCalendar

/// Epic 15: the widgets' snapshot, what a tap opens, and when the Live Activity shows.
@MainActor
final class WidgetTests: XCTestCase {

    private var calendar: Calendar!
    /// Tuesday, September 15, 2026, 12:00 in Los Angeles.
    private let now = ServerDate.parse("2026-09-15T19:00:00Z")!

    override func setUp() {
        super.setUp()
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.firstWeekday = 2
    }

    private func date(_ iso: String) -> Date { ServerDate.parse(iso)! }

    private func occurrence(_ id: String, _ start: String, _ end: String, allDay: Bool = false,
                            location: String? = nil, source: EventSource = .local) -> EventOccurrence {
        let event = CalendarEvent(id: id, title: id, start: date(start), end: date(end), allDay: allDay,
                                  location: location, source: source)
        return EventOccurrence(event: event, start: event.start, end: event.end)
    }

    private var sample: [EventOccurrence] {
        [
            occurrence("morning", "2026-09-15T16:00:00Z", "2026-09-15T17:00:00Z"),       // 9–10, over
            occurrence("lunch", "2026-09-15T19:30:00Z", "2026-09-15T20:30:00Z", location: "Cafe"),
            occurrence("holiday", "2026-09-15T00:00:00Z", "2026-09-15T23:59:59Z", allDay: true),
            occurrence("google", "2026-09-16T17:00:00Z", "2026-09-16T18:00:00Z", source: .google),
            occurrence("trip", "2026-09-27T00:00:00Z", "2026-10-01T23:59:59Z", allDay: true),
            occurrence("yesterday", "2026-09-14T16:00:00Z", "2026-09-14T17:00:00Z"),
            occurrence("far", "2026-10-20T16:00:00Z", "2026-10-20T17:00:00Z"),
        ]
    }

    // MARK: - Building

    func testTheHorizonEndsBeforeItsFourteenthDay() {
        let edge = occurrence("edge", "2026-09-29T16:00:00Z", "2026-09-29T17:00:00Z")
        let snapshot = WidgetSnapshotStore.build([edge], now: now, calendar: calendar, filter: .all)
        XCTAssertTrue(snapshot.events.isEmpty, "today and the 13 days after it")
        XCTAssertEqual(snapshot.busyDays, ["2026-09-29"], "the month grid still marks it")
    }

    func testTheSnapshotKeepsTodayOnwardWithinTheHorizon() {
        let snapshot = WidgetSnapshotStore.build(sample, now: now, calendar: calendar, filter: .all)
        XCTAssertTrue(snapshot.signedIn)
        XCTAssertEqual(snapshot.timeZone, "America/Los_Angeles")
        XCTAssertEqual(snapshot.firstWeekday, 2)
        XCTAssertEqual(snapshot.events.map(\.title), ["holiday", "morning", "lunch", "google", "trip"],
                       "the morning's events stay for Today; yesterday's and those past a fortnight don't")
        let lunch = snapshot.events[2]
        XCTAssertEqual(lunch.id, EventLink(sample[1]).string)
        XCTAssertEqual(lunch.location, "Cafe")
        XCTAssertEqual(lunch.firstDay, "2026-09-15")
        let trip = snapshot.events[4]
        XCTAssertEqual([trip.firstDay, trip.lastDay], ["2026-09-27", "2026-10-01"], "an all-day event is its dates")
    }

    func testBusyDaysCoverThisMonthAndNext() {
        let snapshot = WidgetSnapshotStore.build(sample, now: now, calendar: calendar, filter: .all)
        XCTAssertEqual(snapshot.busyDays, ["2026-09-14", "2026-09-15", "2026-09-16", "2026-09-27", "2026-09-28",
                                           "2026-09-29", "2026-09-30", "2026-10-01", "2026-10-20"])
    }

    func testTheFocusFilterAppliesToTheWidgets() {
        let snapshot = WidgetSnapshotStore.build(sample, now: now, calendar: calendar,
                                                 filter: SourceFilter(shown: [.neutrino]))
        XCTAssertFalse(snapshot.events.contains { $0.title == "google" })
        XCTAssertFalse(snapshot.busyDays.contains("2026-09-16"))
        XCTAssertEqual(snapshot.filterSummary, "Neutrino")
    }

    func testTheSnapshotHoldsNothingTheWidgetsDontDraw() throws {
        let event = CalendarEvent(id: "e", title: "Board", description: "secret notes",
                                  start: date("2026-09-15T20:00:00Z"), end: date("2026-09-15T21:00:00Z"),
                                  attendees: ["ceo@example.com"])
        let snapshot = WidgetSnapshotStore.build([EventOccurrence(event: event, start: event.start, end: event.end)],
                                                 now: now, calendar: calendar, filter: .all)
        let json = String(decoding: try snapshot.encoded(), as: UTF8.self)
        XCTAssertFalse(json.contains("secret"))
        XCTAssertFalse(json.contains("ceo@"))
        XCTAssertFalse(json.lowercased().contains("token"))
    }

    // MARK: - Reading

    private var snapshot: WidgetSnapshot {
        WidgetSnapshotStore.build(sample, now: now, calendar: calendar, filter: .all)
    }

    func testUpcomingAndNextAtAnEntrysTime() {
        XCTAssertEqual(snapshot.upcoming(at: now).map(\.title), ["holiday", "lunch", "google", "trip"])
        XCTAssertEqual(snapshot.next(at: now)?.title, "lunch")
        XCTAssertEqual(snapshot.next(at: date("2026-09-15T19:45:00Z"))?.title, "lunch", "under way")
        XCTAssertEqual(snapshot.next(at: date("2026-09-15T21:00:00Z"))?.title, "google")
    }

    func testEventsOnADayPutAllDayFirst() {
        XCTAssertEqual(snapshot.events(on: now).map(\.title), ["holiday", "morning", "lunch"])
        XCTAssertEqual(snapshot.events(on: date("2026-10-01T19:00:00Z")).map(\.title), ["trip"])
    }

    func testEntriesChangeAtEachStartAndEndAndAtMidnight() {
        XCTAssertEqual(snapshot.entryDates(from: now), [
            now,
            date("2026-09-15T19:30:00Z"),
            date("2026-09-15T20:30:00Z"),
            date("2026-09-16T07:00:00Z"),
        ])
    }

    func testTheSnapshotRoundTripsThroughAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try snapshot.encoded().write(to: url)
        XCTAssertEqual(WidgetSnapshot.load(from: url), snapshot)
        XCTAssertNil(WidgetSnapshot.load(from: url.appendingPathExtension("missing")))
    }

    // MARK: - Writing

    func testAnUnchangedCalendarDoesNotSpendAWidgetReload() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var reloads = 0
        let store = WidgetSnapshotStore(url: url, reload: { reloads += 1 })

        store.write(snapshot)
        XCTAssertEqual(reloads, 1)
        var later = snapshot
        later.generatedAt = now.addingTimeInterval(600)
        store.write(later)
        XCTAssertEqual(reloads, 1, "only the time written differs")

        store.write(.signedOut(now: now))
        XCTAssertEqual(reloads, 2)
        XCTAssertEqual(WidgetSnapshot.load(from: url)?.signedIn, false)

        // A new store (a relaunch) compares with what is on disk.
        let relaunched = WidgetSnapshotStore(url: url, reload: { reloads += 1 })
        relaunched.write(.signedOut(now: now.addingTimeInterval(60)))
        XCTAssertEqual(reloads, 2)
    }

    // MARK: - Links

    func testWidgetLinksRoundTrip() {
        let event = WidgetLink.event("3f2a-uuid@1789502400")
        XCTAssertEqual(event.url.absoluteString, "neutrinocalendar://event/3f2a-uuid@1789502400")
        XCTAssertEqual(WidgetLink(url: event.url), event)
        let day = WidgetLink.day("2026-09-15")
        XCTAssertEqual(WidgetLink(url: day.url), day)
        XCTAssertNil(WidgetLink(url: URL(string: "https://example.com/event/x")!))
        XCTAssertNil(WidgetLink(url: URL(string: "neutrinocalendar://other/x")!))
        XCTAssertNil(WidgetLink(url: URL(string: "neutrinocalendar://event/")!))
    }

    func testDayKeysRoundTrip() {
        let day = WidgetSnapshot.day(fromKey: "2026-09-15", calendar: calendar)
        XCTAssertEqual(day, calendar.startOfDay(for: now))
        XCTAssertEqual(WidgetSnapshot.dayKey(day!, calendar: calendar), "2026-09-15")
        XCTAssertNil(WidgetSnapshot.day(fromKey: "soon", calendar: calendar))
    }

    // MARK: - Live Activity

    func testTheActivityIsForTheNextEventWithinTheHour() {
        let upcoming = UpNext.upcoming(sample, now: now, calendar: calendar)
        XCTAssertEqual(LiveActivities.candidate(upcoming, now: now, filter: .all)?.event.id, "lunch",
                       "30 minutes away")
        XCTAssertNil(LiveActivities.candidate(upcoming, now: date("2026-09-15T20:45:00Z"), filter: .all),
                     "the next is tomorrow")
        XCTAssertEqual(LiveActivities.candidate(upcoming, now: date("2026-09-16T16:30:00Z"), filter: .all)?.event.id,
                       "google")
        XCTAssertNil(LiveActivities.candidate(upcoming, now: date("2026-09-16T16:30:00Z"),
                                              filter: SourceFilter(shown: [.neutrino])))
    }

    @available(iOS 16.2, *)
    func testTheActivityGoesStaleWhenItsPictureChanges() {
        let lunch = sample[1]
        let before = LiveActivities.state(for: lunch, now: now)
        XCTAssertFalse(before.hadStarted)
        XCTAssertEqual(before.location, "Cafe")
        XCTAssertEqual(EventActivityAttributes.staleDate(before), lunch.start)
        XCTAssertEqual(EventActivityAttributes.phase(before, isStale: false), .upcoming)
        XCTAssertEqual(EventActivityAttributes.phase(before, isStale: true), .inProgress, "stale at its start")

        let during = LiveActivities.state(for: lunch, now: lunch.start.addingTimeInterval(60))
        XCTAssertTrue(during.hadStarted)
        XCTAssertEqual(EventActivityAttributes.staleDate(during), lunch.end)
        XCTAssertEqual(EventActivityAttributes.phase(during, isStale: false), .inProgress)
        XCTAssertEqual(EventActivityAttributes.phase(during, isStale: true), .ended, "stale at its end")
    }
}
