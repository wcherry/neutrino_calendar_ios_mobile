import XCTest
@testable import NeutrinoCalendar

/// Parsing details the generated vectors don't reach one by one.
final class RecurrenceRuleTests: XCTestCase {

    private typealias Rule = RecurrenceExpander.Rule

    func testParsesTheWebEditorsRules() throws {
        let weekdays = try XCTUnwrap(Rule(parsing: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"))
        XCTAssertEqual(weekdays.freq, .weekly)
        XCTAssertEqual(weekdays.interval, 1)
        XCTAssertEqual(weekdays.byDay, [1, 2, 3, 4, 5])
        XCTAssertNil(weekdays.count)
        XCTAssertNil(weekdays.until)
    }

    func testFreqValueIsCaseSensitiveButKeysAreNot() {
        XCTAssertNotNil(Rule(parsing: "freq=DAILY"))
        XCTAssertNil(Rule(parsing: "FREQ=daily"), "the web compares the value as written")
    }

    func testBydayDropsOrdinalsAndUnknownDays() {
        XCTAssertEqual(Rule(parsing: "FREQ=WEEKLY;BYDAY=+1MO,-1FR,XX")?.byDay, [1, 5])
    }

    func testEmptyValuesCountAsAbsent() throws {
        let rule = try XCTUnwrap(Rule(parsing: "FREQ=WEEKLY;INTERVAL=;BYDAY="))
        XCTAssertEqual(rule.interval, 1)
        XCTAssertNil(rule.byDay)
    }

    func testIntervalFollowsParseInt() {
        XCTAssertEqual(Rule(parsing: "FREQ=DAILY;INTERVAL=2abc")?.interval, 2)
        XCTAssertNil(Rule(parsing: "FREQ=DAILY;INTERVAL=abc")?.interval ?? nil)
        XCTAssertEqual(Rule.jsParseInt("  -3"), -3)
    }

    func testUntilOnlyReadsUTCDateTimes() {
        XCTAssertEqual(Rule.parseUntil("20260904T170000Z"), ServerDate.parse("2026-09-04T17:00:00Z"))
        XCTAssertNil(Rule.parseUntil("20260904"), "a bare date is an invalid Date on the web")
    }

    /// The consequence of an unreadable INTERVAL in the web's loop: the first pass runs, then
    /// the date goes invalid and the loop stops.
    func testUnreadableIntervalYieldsOnlyTheFirstOccurrence() throws {
        let start = try XCTUnwrap(ServerDate.parse("2026-09-01T17:00:00Z"))
        let event = CalendarEvent(id: "e", title: "e", start: start, end: start.addingTimeInterval(3600),
                                  recurrenceRule: "FREQ=DAILY;INTERVAL=abc")
        let occurrences = RecurrenceExpander.expand([event], from: start.addingTimeInterval(-86_400),
                                                    to: start.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(occurrences.map(\.start), [start])
    }
}
