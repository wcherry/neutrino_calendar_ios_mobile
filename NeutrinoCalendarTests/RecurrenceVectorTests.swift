import XCTest
@testable import NeutrinoCalendar

/// Holds the iOS expansion to the web's, case by case.
///
/// `Fixtures/recurrence_vectors.json` is not written by hand: `scripts/generate_recurrence_vectors.mjs`
/// runs the web client's own `expandRecurringEvents` and `eventDayRange` and records what they
/// return. A failure here means the two clients would draw the same event on different days.
/// If the web's code changed, regenerate the fixture; if this code changed, it has drifted.
final class RecurrenceVectorTests: XCTestCase {

    private struct Fixture: Decodable {
        let timeZone: String
        let expansions: [Expansion]
        let dayRanges: [DayRangeCase]
    }

    private struct Expansion: Decodable {
        let name: String
        let event: CalendarEvent
        let from: String
        let to: String
        let occurrences: [Occurrence]
    }

    private struct Occurrence: Decodable {
        let startTime: String
        let endTime: String
    }

    private struct DayRangeCase: Decodable {
        let name: String
        let event: CalendarEvent
        let first: String
        let last: String
    }

    private var fixture: Fixture!
    private var calendar: Calendar!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "recurrence_vectors", withExtension: "json"),
                                "the fixture is missing from the test bundle")
        fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: fixture.timeZone))
    }

    func testFixtureCoversTheCases() {
        XCTAssertGreaterThanOrEqual(fixture.expansions.count, 19)
        XCTAssertGreaterThanOrEqual(fixture.dayRanges.count, 8)
    }

    func testExpansionMatchesTheWeb() throws {
        for case_ in fixture.expansions {
            let from = try XCTUnwrap(ServerDate.parse(case_.from))
            let to = try XCTUnwrap(ServerDate.parse(case_.to))
            let actual = RecurrenceExpander.expand([case_.event], from: from, to: to, calendar: calendar)
                .map { "\(ServerDate.format($0.start)) → \(ServerDate.format($0.end))" }
            let expected = try case_.occurrences.map {
                "\(ServerDate.format(try XCTUnwrap(ServerDate.parse($0.startTime)))) → "
                    + ServerDate.format(try XCTUnwrap(ServerDate.parse($0.endTime)))
            }
            // Order too: the web's order is the order it pushes occurrences in, and matching it
            // is the cheapest proof the loop is the same loop.
            XCTAssertEqual(actual, expected, case_.name)
        }
    }

    func testDayRangesMatchTheWeb() {
        let ymd = Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day()

        for case_ in fixture.dayRanges {
            let range = EventDayRange(start: case_.event.start, end: case_.event.end,
                                      allDay: case_.event.allDay, calendar: calendar)
            XCTAssertEqual(range.first.formatted(ymd), case_.first, "\(case_.name): first day")
            XCTAssertEqual(range.last.formatted(ymd), case_.last, "\(case_.name): last day")
        }
    }
}
