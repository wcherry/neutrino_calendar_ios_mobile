import XCTest
@testable import NeutrinoCalendar

final class CalendarGridTests: XCTestCase {

    private func calendar(firstWeekday: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        c.firstWeekday = firstWeekday
        return c
    }

    private func date(_ iso: String) -> Date { ServerDate.parse(iso)! }

    private func ymd(_ date: Date, _ c: Calendar) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: c.timeZone).year().month().day())
    }

    // MARK: - Month grid

    func testSeptember2026FromSundayIsFiveWeeksStartingAug30() {
        let c = calendar(firstWeekday: 1)
        let days = CalendarGrid.monthDays(date("2026-09-15T19:00:00Z"), calendar: c)
        XCTAssertEqual(days.count, 35)
        XCTAssertEqual(ymd(days.first!, c), "2026-08-30")
        XCTAssertEqual(ymd(days.last!, c), "2026-10-03")
    }

    func testAMondayStartShiftsTheGrid() {
        let c = calendar(firstWeekday: 2)
        let days = CalendarGrid.monthDays(date("2026-09-15T19:00:00Z"), calendar: c)
        XCTAssertEqual(ymd(days.first!, c), "2026-08-31")
        XCTAssertEqual(CalendarGrid.weekdaySymbols(calendar: c).first, "M")
    }

    func testAMonthCanNeedSixRows() {
        // August 2026 starts on a Saturday and has 31 days.
        let c = calendar(firstWeekday: 1)
        XCTAssertEqual(CalendarGrid.monthDays(date("2026-08-15T19:00:00Z"), calendar: c).count, 42)
    }

    func testWeekDaysAndTheMonthsTheyCover() {
        let c = calendar(firstWeekday: 1)
        let week = CalendarGrid.weekDays(containing: date("2026-10-01T19:00:00Z"), calendar: c)
        XCTAssertEqual(week.map { ymd($0, c) }.first, "2026-09-27")
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(CalendarGrid.months(covering: week, calendar: c).map { ymd($0, c) },
                       ["2026-09-01", "2026-10-01"])
    }

    // MARK: - Time grid

    private func occurrence(_ id: String, _ start: String, _ end: String, allDay: Bool = false) -> EventOccurrence {
        let e = CalendarEvent(id: id, title: id, start: date(start), end: date(end), allDay: allDay)
        return EventOccurrence(event: e, start: e.start, end: e.end)
    }

    private let day = ServerDate.parse("2026-09-24T19:00:00Z")!

    func testATimedEventIsPlacedByLocalMinutes() {
        let c = calendar(firstWeekday: 1)
        let placed = TimeGridLayout.layout([occurrence("a", "2026-09-24T16:00:00Z", "2026-09-24T17:30:00Z")],
                                           on: day, calendar: c)
        XCTAssertEqual(placed.first?.startMinute, 9 * 60)
        XCTAssertEqual(placed.first?.endMinute, 10.5 * 60)
        XCTAssertEqual(placed.first?.columns, 1)
    }

    func testOverlapsSitSideBySideAndAChainSharesColumns() {
        let c = calendar(firstWeekday: 1)
        let placed = TimeGridLayout.layout([
            occurrence("a", "2026-09-24T16:00:00Z", "2026-09-24T18:00:00Z"), // 9–11
            occurrence("b", "2026-09-24T17:00:00Z", "2026-09-24T19:00:00Z"), // 10–12, overlaps a
            occurrence("c", "2026-09-24T18:30:00Z", "2026-09-24T19:30:00Z"), // 11:30–12:30, overlaps b, reuses a's column
            occurrence("d", "2026-09-24T21:00:00Z", "2026-09-24T22:00:00Z"), // 14–15, alone
        ], on: day, calendar: c)
        let byID = Dictionary(uniqueKeysWithValues: placed.map { ($0.occurrence.event.id, $0) })
        XCTAssertEqual(byID["a"]?.column, 0)
        XCTAssertEqual(byID["b"]?.column, 1)
        XCTAssertEqual(byID["c"]?.column, 0)
        XCTAssertEqual(Set(["a", "b", "c"].compactMap { byID[$0]?.columns }), [2])
        XCTAssertEqual(byID["d"]?.columns, 1)
    }

    func testAnEventAcrossMidnightIsClampedToEachDay() {
        let c = calendar(firstWeekday: 1)
        let overnight = occurrence("n", "2026-09-25T05:00:00Z", "2026-09-25T09:00:00Z") // 22:00–02:00
        let first = TimeGridLayout.layout([overnight], on: day, calendar: c).first
        XCTAssertEqual(first?.startMinute, 22 * 60)
        XCTAssertEqual(first?.endMinute, 24 * 60)
        let next = TimeGridLayout.layout([overnight], on: date("2026-09-25T19:00:00Z"), calendar: c).first
        XCTAssertEqual(next?.startMinute, 0)
        XCTAssertEqual(next?.endMinute, 2 * 60)
    }

    func testAShortEventGetsTheMinimumHeightWithoutLeavingTheDay() {
        let c = calendar(firstWeekday: 1)
        let placed = TimeGridLayout.layout([
            occurrence("s", "2026-09-24T16:00:00Z", "2026-09-24T16:05:00Z"),
            occurrence("late", "2026-09-25T06:55:00Z", "2026-09-25T06:59:00Z"), // 23:55–23:59
        ], on: day, calendar: c)
        let byID = Dictionary(uniqueKeysWithValues: placed.map { ($0.occurrence.event.id, $0) })
        XCTAssertEqual(byID["s"]!.endMinute - byID["s"]!.startMinute, TimeGridLayout.minimumMinutes)
        XCTAssertEqual(byID["late"]?.endMinute, 24 * 60)
    }

    func testAllDayEventsAreKeptOffTheGrid() {
        let c = calendar(firstWeekday: 1)
        let offsite = occurrence("o", "2026-09-24T00:00:00Z", "2026-09-24T23:59:59Z", allDay: true)
        XCTAssertTrue(TimeGridLayout.layout([offsite], on: day, calendar: c).isEmpty)
        XCTAssertEqual(TimeGridLayout.allDay([offsite], on: day, calendar: c).map(\.event.id), ["o"])
    }

    func testNowLineOnlyOnToday() {
        let c = calendar(firstWeekday: 1)
        let now = date("2026-09-24T21:30:00Z") // 14:30 PDT
        XCTAssertEqual(TimeGridLayout.nowMinute(now, on: day, calendar: c), 14.5 * 60)
        XCTAssertNil(TimeGridLayout.nowMinute(now, on: date("2026-09-25T19:00:00Z"), calendar: c))
    }
}
