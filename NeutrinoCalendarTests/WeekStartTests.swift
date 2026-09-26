import XCTest
@testable import NeutrinoCalendar

@MainActor
final class WeekStartTests: XCTestCase {

    /// The stored values are the web's: JavaScript day numbers, so a value means the same day on
    /// both clients.
    func testValuesAndDefaultMatchTheWeb() {
        XCTAssertEqual(WeekStart.allCases.map(\.rawValue), [0, 1, 6])
        XCTAssertEqual(WeekStart.default, .sunday)
        XCTAssertEqual(WeekStart.storageKey, "ncal.calendar.weekStart")
    }

    func testFirstWeekdayCountsFromOneForSunday() {
        XCTAssertEqual(WeekStart.sunday.firstWeekday, 1)
        XCTAssertEqual(WeekStart.monday.firstWeekday, 2)
        XCTAssertEqual(WeekStart.saturday.firstWeekday, 7)
    }

    func testNothingStoredMeansTheDefault() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: WeekStart.storageKey)
        defer { defaults.set(saved, forKey: WeekStart.storageKey) }

        defaults.removeObject(forKey: WeekStart.storageKey)
        XCTAssertEqual(WeekStart.stored, .sunday)
        defaults.set(6, forKey: WeekStart.storageKey)
        XCTAssertEqual(WeekStart.stored, .saturday)
        defaults.set(3, forKey: WeekStart.storageKey)
        XCTAssertEqual(WeekStart.stored, .sunday, "an unknown value falls back rather than failing")
    }

    /// The service's calendar, and so every grid, starts weeks on the chosen day, whatever the
    /// region's first weekday is.
    func testTheWeekFollowsTheSetting() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.firstWeekday = 2 // a region that starts on Monday
        let thursday = ServerDate.parse("2026-09-24T19:00:00Z")!
        let service = EventsService(client: CalendarAPIClient(token: { nil }), calendar: calendar,
                                    weekStart: .sunday, now: { thursday })
        let ymd = Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day()

        XCTAssertEqual(service.visibleDays(for: .week).first?.formatted(ymd), "2026-09-20")
        service.setWeekStart(.monday)
        XCTAssertEqual(service.visibleDays(for: .week).first?.formatted(ymd), "2026-09-21")
        service.setWeekStart(.saturday)
        XCTAssertEqual(service.visibleDays(for: .week).first?.formatted(ymd), "2026-09-19")
        XCTAssertEqual(CalendarGrid.weekdaySymbols(calendar: service.calendar).first, "S")
        XCTAssertEqual(service.visibleDays(for: .month).first?.formatted(ymd), "2026-08-29")
    }
}
