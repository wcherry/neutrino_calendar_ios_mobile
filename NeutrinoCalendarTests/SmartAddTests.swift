import XCTest
@testable import NeutrinoCalendar

/// Holds `SmartAdd.swift` to the web's `smartAdd.ts`, case by case.
///
/// `Fixtures/smart_add_vectors.json` is a copy of the web's `smartAddFixtures.json`, which the web
/// tests run too, so a case that passes there and fails here means the two clients would create
/// different tasks from the same line. Add cases on the web and run
/// `scripts/sync_smart_add_vectors.sh`.
final class SmartAddTests: XCTestCase {

    private struct Fixture: Decodable {
        let context: SmartAdd.Context
        let cases: [Case]
    }

    private struct Case: Decodable {
        let input: String
        let expect: Expected
    }

    /// Only the fields a case sets; everything else must come back empty.
    private struct Expected: Decodable {
        let title: String?
        let due: SmartDate?
        let start: SmartDate?
        let priority: Int?
        let tags: [String]?
        let recurrenceRule: String?
        let repeatAfterCompletion: Bool?
        let estimateMinutes: Int?
        let location: String?
        let note: String?

        func result(for input: String) -> SmartAddResult {
            SmartAddResult(title: title ?? input, due: due, start: start, priority: priority,
                           tags: tags ?? [], recurrenceRule: recurrenceRule,
                           repeatAfterCompletion: repeatAfterCompletion ?? false,
                           estimateMinutes: estimateMinutes, location: location, note: note)
        }
    }

    private static let fixtureURL = Bundle(for: SmartAddTests.self)
        .url(forResource: "smart_add_vectors", withExtension: "json")

    private var fixture: Fixture!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Self.fixtureURL, "the fixture is missing from the test bundle")
        fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testFixtureCoversTheCases() {
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 70)
    }

    func testEveryCaseMatchesTheWeb() {
        for c in fixture.cases {
            XCTAssertEqual(SmartAdd.parse(c.input, context: fixture.context), c.expect.result(for: c.input),
                           c.input)
        }
    }

    /// The copy here is the web's, byte for byte. Skipped when the sibling checkout isn't there,
    /// as on a machine that only builds this app.
    func testFixtureIsTheWebsCopy() throws {
        let web = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("neutrino/web/apps/web/src/app/(apps)/calendar/smartAddFixtures.json")
        guard let webData = try? Data(contentsOf: web) else {
            throw XCTSkip("no sibling neutrino checkout at \(web.path)")
        }
        let ours = try Data(contentsOf: XCTUnwrap(Self.fixtureURL))
        XCTAssertEqual(ours, webData, "run scripts/sync_smart_add_vectors.sh")
    }

    func testRepeatDescriptionsParseBack() {
        let rules = fixture.cases.compactMap { c in
            c.expect.recurrenceRule.map { ($0, c.expect.repeatAfterCompletion ?? false) }
        }
        XCTAssertFalse(rules.isEmpty)
        for (rule, after) in rules {
            let parsed = SmartAdd.parseRepeat(SmartAdd.describeRepeat(rule, after: after))
            XCTAssertEqual(parsed?.rule, rule, rule)
            XCTAssertEqual(parsed?.after, after, rule)
        }
    }

    // MARK: To the wire

    func testADateWithNoTimeIsThatDayAtUTCMidnight() {
        let wire = SmartAdd.wire(SmartDate(date: "2026-10-03", time: nil))
        XCTAssertEqual(wire.iso, "2026-10-03T00:00:00Z")
        XCTAssertFalse(wire.hasTime)
    }

    func testATimedDateIsTheInstantInTheUsersZone() {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let wire = SmartAdd.wire(SmartDate(date: "2026-10-03", time: "17:30"), calendar: pacific)
        XCTAssertEqual(wire.iso, "2026-10-04T00:30:00Z")
        XCTAssertTrue(wire.hasTime)
    }

    func testAPlainTitleSendsOnlyTheTitle() throws {
        let request = SmartAdd.request(for: SmartAdd.parse("Clean ceiling fans", context: fixture.context))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        XCTAssertEqual(json?.keys.sorted(), ["title"])
    }

    func testEverySmartAddFieldReachesTheRequest() throws {
        let parsed = SmartAdd.parse("Buy milk ^2026-10-03 ~2026-10-01 !1 #errands *after 2 weeks =15min @Safeway // skimmed",
                                    context: fixture.context)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(SmartAdd.request(for: parsed))) as? [String: Any])
        XCTAssertEqual(json["title"] as? String, "Buy milk")
        XCTAssertEqual(json["notes"] as? String, "skimmed")
        XCTAssertEqual(json["dueDate"] as? String, "2026-10-03T00:00:00Z")
        XCTAssertNil(json["dueHasTime"], "a date-only due is the default and isn't sent")
        XCTAssertEqual(json["startDate"] as? String, "2026-10-01T00:00:00Z")
        XCTAssertEqual(json["priority"] as? Int, 1)
        XCTAssertEqual(json["tags"] as? [String], ["errands"])
        XCTAssertEqual(json["recurrenceRule"] as? String, "FREQ=WEEKLY;INTERVAL=2")
        XCTAssertEqual(json["repeatAfterCompletion"] as? Bool, true)
        XCTAssertEqual(json["estimateMinutes"] as? Int, 15)
        XCTAssertEqual(json["location"] as? String, "Safeway")
    }
}
