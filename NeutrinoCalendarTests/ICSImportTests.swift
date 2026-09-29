import XCTest
@testable import NeutrinoCalendar

final class ICSImportTests: XCTestCase {

    private var pacific: Calendar!

    override func setUp() {
        super.setUp()
        pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    }

    private func date(_ iso: String) -> Date { ServerDate.parse(iso)! }

    private func ics(_ lines: String...) -> String {
        (["BEGIN:VCALENDAR", "VERSION:2.0"] + lines + ["END:VCALENDAR"]).joined(separator: "\r\n")
    }

    func testAZonedInviteKeepsItsZoneAndText() throws {
        let draft = try ICSImport.draft(from: ics(
            "METHOD:REQUEST",
            "BEGIN:VEVENT",
            "SUMMARY:Design review\\, round 2",
            "LOCATION:Room 4\\; east wing",
            "DESCRIPTION:Agenda:\\n1. Mocks\\n2. Copy",
            "DTSTART;TZID=America/New_York:20261005T100000",
            "DTEND;TZID=America/New_York:20261005T113000",
            "ATTENDEE;CN=\"Lovelace, Ada\";ROLE=REQ-PARTICIPANT:mailto:ada@example.com",
            "ATTENDEE:MAILTO:grace@example.com",
            "BEGIN:VALARM",
            "DESCRIPTION:Reminder",
            "TRIGGER:-PT15M",
            "END:VALARM",
            "END:VEVENT"), calendar: pacific)

        XCTAssertEqual(draft.title, "Design review, round 2")
        XCTAssertEqual(draft.location, "Room 4; east wing")
        XCTAssertEqual(draft.notes, "Agenda:\n1. Mocks\n2. Copy", "the alarm's DESCRIPTION is not the event's")
        XCTAssertEqual(draft.start, date("2026-10-05T14:00:00Z"))
        XCTAssertEqual(draft.end, date("2026-10-05T15:30:00Z"))
        XCTAssertEqual(draft.timeZone.identifier, "America/New_York")
        XCTAssertFalse(draft.allDay)
        XCTAssertEqual(draft.attendees, ["ada@example.com", "grace@example.com"])
        XCTAssertEqual(draft.repeatOption, .never)
    }

    func testUTCAndFloatingTimesAndDuration() throws {
        let utc = try ICSImport.draft(from: ics(
            "BEGIN:VEVENT", "SUMMARY:Call", "DTSTART:20261005T170000Z", "DURATION:PT45M", "END:VEVENT"),
            calendar: pacific)
        XCTAssertEqual(utc.start, date("2026-10-05T17:00:00Z"))
        XCTAssertEqual(utc.end, date("2026-10-05T17:45:00Z"))
        XCTAssertEqual(utc.timeZone.identifier, "America/Los_Angeles", "shown in the device's zone")

        let floating = try ICSImport.draft(from: ics(
            "BEGIN:VEVENT", "SUMMARY:Lunch", "DTSTART:20261005T120000", "DTEND:20261005T130000", "END:VEVENT"),
            calendar: pacific)
        XCTAssertEqual(floating.start, date("2026-10-05T19:00:00Z"), "12:00 wherever it's opened")
    }

    /// DTEND of an all-day event is the day after its last; the form holds the last day.
    func testAllDayEndIsExclusive() throws {
        let draft = try ICSImport.draft(from: ics(
            "BEGIN:VEVENT", "SUMMARY:Offsite",
            "DTSTART;VALUE=DATE:20261012", "DTEND;VALUE=DATE:20261014", "END:VEVENT"), calendar: pacific)
        XCTAssertTrue(draft.allDay)
        XCTAssertEqual(draft.wireTimes.start, "2026-10-12T00:00:00Z")
        XCTAssertEqual(draft.wireTimes.end, "2026-10-13T23:59:59Z")

        let oneDay = try ICSImport.draft(from: ics(
            "BEGIN:VEVENT", "SUMMARY:Holiday", "DTSTART;VALUE=DATE:20261012", "END:VEVENT"), calendar: pacific)
        XCTAssertEqual(oneDay.wireTimes.end, "2026-10-12T23:59:59Z")
    }

    func testOutlookWindowsZoneAndFoldedLines() throws {
        let draft = try ICSImport.draft(from: ics(
            "BEGIN:VEVENT",
            "SUMMARY:Quarterly planning with the whole",
            "  team",
            "DTSTART;TZID=W. Europe Standard Time:20261005T090000",
            "DTEND;TZID=W. Europe Standard Time:20261005T100000",
            "RRULE:FREQ=WEEKLY;BYDAY=MO",
            "END:VEVENT"), calendar: pacific)
        XCTAssertEqual(draft.title, "Quarterly planning with the whole team")
        XCTAssertEqual(draft.timeZone.identifier, "Europe/Berlin")
        XCTAssertEqual(draft.start, date("2026-10-05T07:00:00Z"))
        XCTAssertEqual(draft.repeatOption, .custom("FREQ=WEEKLY;BYDAY=MO"))
    }

    func testTheSeriesIsReadNotAnOverride() throws {
        let draft = try ICSImport.draft(from: ics(
            "BEGIN:VEVENT", "SUMMARY:Moved one", "RECURRENCE-ID:20261012T170000Z",
            "DTSTART:20261013T170000Z", "END:VEVENT",
            "BEGIN:VEVENT", "SUMMARY:Standup", "RRULE:FREQ=DAILY",
            "DTSTART:20261005T170000Z", "END:VEVENT"), calendar: pacific)
        XCTAssertEqual(draft.title, "Standup")
        XCTAssertEqual(draft.repeatOption, .daily)
    }

    func testFailures() {
        XCTAssertThrowsError(try ICSImport.draft(from: "not a calendar")) {
            XCTAssertEqual($0 as? ICSImport.Failure, .unreadable)
        }
        XCTAssertThrowsError(try ICSImport.draft(from: ics("BEGIN:VTODO", "SUMMARY:x", "END:VTODO"))) {
            XCTAssertEqual($0 as? ICSImport.Failure, .noEvent)
        }
        XCTAssertThrowsError(try ICSImport.draft(from: ics(
            "METHOD:CANCEL", "BEGIN:VEVENT", "SUMMARY:x", "DTSTART:20261005T170000Z", "END:VEVENT"))) {
            XCTAssertEqual($0 as? ICSImport.Failure, .cancelled)
        }
    }

    func testDuration() {
        XCTAssertEqual(ICSImport.duration("PT1H30M"), 5_400)
        XCTAssertEqual(ICSImport.duration("P1D"), 86_400)
        XCTAssertEqual(ICSImport.duration("P1W"), 604_800)
        XCTAssertEqual(ICSImport.duration("-PT15M"), -900)
        XCTAssertNil(ICSImport.duration("1H"))
    }
}
