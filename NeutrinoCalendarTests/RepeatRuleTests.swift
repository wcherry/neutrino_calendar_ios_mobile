import XCTest
@testable import NeutrinoCalendar

/// Holds `RepeatRule` to the web's `repeatRule.ts`, case by case, through the fixture table the
/// two share (`scripts/sync_repeat_rule_vectors.sh`).
final class RepeatRuleTests: XCTestCase {

    private struct Fixture: Decodable {
        let parse: [ParseCase]
        let build: [BuildCase]
    }

    private struct ParseCase: Decodable {
        let name: String
        let rule: String
        let allDay: Bool
        let timeZone: String
        let expected: FixtureRule?
        let rebuilt: String?
    }

    private struct BuildCase: Decodable {
        let name: String
        let rule: FixtureRule
        let allDay: Bool
        let timeZone: String
        let expected: String
    }

    private struct FixtureRule: Decodable {
        struct End: Decodable { let kind: String; let date: String?; let count: Int? }
        let freq: String
        let interval: Int
        let byDay: String?
        let end: End
        let extra: [String]

        var rule: RepeatRule {
            let end: RepeatRule.End
            switch self.end.kind {
            case "on":
                let p = self.end.date!.split(separator: "-").map { Int($0)! }
                end = .on(.init(year: p[0], month: p[1], day: p[2]))
            case "after":
                end = .after(self.end.count!)
            default:
                end = .never
            }
            return RepeatRule(frequency: .init(rawValue: freq)!, interval: interval, byDay: byDay, end: end, extra: extra)
        }
    }

    private static let fixtureURL = Bundle(for: RepeatRuleTests.self).url(forResource: "repeat_rule_vectors", withExtension: "json")

    private var fixture: Fixture!

    override func setUpWithError() throws {
        fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: XCTUnwrap(Self.fixtureURL)))
    }

    private func context(_ allDay: Bool, _ zone: String) -> RepeatRule.Context {
        .init(allDay: allDay, timeZone: TimeZone(identifier: zone)!)
    }

    func testFixtureIsTheWebsCopy() throws {
        let web = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("neutrino/web/apps/web/src/app/(apps)/calendar/repeatRuleFixtures.json")
        guard let webData = try? Data(contentsOf: web) else {
            throw XCTSkip("no sibling neutrino checkout at \(web.path)")
        }
        let ours = try Data(contentsOf: XCTUnwrap(Self.fixtureURL))
        XCTAssertEqual(ours, webData, "run scripts/sync_repeat_rule_vectors.sh")
    }

    func testParsesAsTheWebDoes() {
        XCTAssertGreaterThanOrEqual(fixture.parse.count, 17)
        for c in fixture.parse {
            let ctx = context(c.allDay, c.timeZone)
            let parsed = RepeatRule(parsing: c.rule, context: ctx)
            XCTAssertEqual(parsed, c.expected?.rule, c.name)
            if let parsed { XCTAssertEqual(parsed.rule(context: ctx), c.rebuilt, c.name) }
        }
    }

    func testBuildsAsTheWebDoes() {
        XCTAssertGreaterThanOrEqual(fixture.build.count, 5)
        for c in fixture.build {
            XCTAssertEqual(c.rule.rule.rule(context: context(c.allDay, c.timeZone)), c.expected, c.name)
        }
    }

    // MARK: - The form's choices

    func testEveryStandardChoiceShowsUnderItself() {
        let ctx = context(false, "UTC")
        for option in RepeatOption.standard where option != .never {
            XCTAssertEqual(RepeatRule(parsing: option.rule!, context: ctx)?.preset, option)
        }
    }

    func testChangingFrequencyKeepsIntervalAndEnd() {
        let ctx = context(false, "UTC")
        let rule = RepeatRule(parsing: "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TU,WE,TH,FR;COUNT=5", context: ctx)!
        XCTAssertEqual(RepeatRule.with(.weekdays, from: rule), rule)
        XCTAssertEqual(RepeatRule.with(.daily, from: rule)?.rule(context: ctx), "FREQ=DAILY;INTERVAL=2;COUNT=5")
        XCTAssertNil(RepeatRule.with(.never, from: rule))

        let smartAdd = RepeatRule(parsing: "FREQ=WEEKLY;BYDAY=MO,TH", context: ctx)!
        XCTAssertEqual(smartAdd.preset, .weekly)
        XCTAssertEqual(RepeatRule.with(.weekly, from: smartAdd), smartAdd, "its days are kept")
    }

    func testDefaultEndDay() {
        let start = RepeatRule.Day(year: 2026, month: 1, day: 31)
        XCTAssertEqual(RepeatRule.defaultEndDay(after: start, frequency: .daily).string, "2026-02-28")
        XCTAssertEqual(RepeatRule.defaultEndDay(after: start, frequency: .yearly).string, "2027-01-31")
    }

    // MARK: - In the draft

    private var pacific: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    func testTheDraftWritesIntervalAndEnd() {
        var draft = EventDraft(newOn: ServerDate.parse("2026-10-05T16:00:00Z")!, calendar: pacific)
        draft.title = "Water plants"
        draft.repeatRule = RepeatRule.with(.daily, from: nil)
        draft.repeatRule?.interval = 3
        draft.repeatRule?.end = .on(.init(year: 2026, month: 12, day: 31))
        XCTAssertEqual(draft.createRequest().recurrenceRule, "FREQ=DAILY;INTERVAL=3;UNTIL=20270101T075959Z")

        // All-day writes the same day differently.
        draft.setAllDay(true)
        XCTAssertEqual(draft.createRequest().recurrenceRule, "FREQ=DAILY;INTERVAL=3;UNTIL=20261231T235959Z")
        draft.setAllDay(false)
        draft.setTimeZone(TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertEqual(draft.createRequest().recurrenceRule, "FREQ=DAILY;INTERVAL=3;UNTIL=20261231T145959Z")
    }

    func testARuleWithoutAnEndDateIsLeftAsWritten() {
        var draft = EventDraft(newOn: Date(), calendar: pacific)
        draft.repeatOption = RepeatOption(rule: "FREQ=DAILY;INTERVAL=1")
        draft.setAllDay(true)
        XCTAssertEqual(draft.repeatOption.rule, "FREQ=DAILY;INTERVAL=1")
    }

    func testAnEndBeforeTheStartIsAProblem() {
        var draft = EventDraft(newOn: ServerDate.parse("2026-10-05T16:00:00Z")!, calendar: pacific)
        draft.title = "x"
        draft.repeatRule = RepeatRule(frequency: .daily, end: .on(.init(year: 2026, month: 10, day: 4)))
        XCTAssertEqual(draft.problem, "The event stops repeating before it starts.")
        draft.repeatRule?.end = .on(.init(year: 2026, month: 10, day: 5))
        XCTAssertNil(draft.problem)
    }

    func testTheSummaryReadsTheInterval() {
        XCTAssertEqual(EventFormatting.recurrenceSummary("FREQ=WEEKLY;INTERVAL=4;COUNT=3"), "Repeats every 4 weeks, 3 times")
    }
}
