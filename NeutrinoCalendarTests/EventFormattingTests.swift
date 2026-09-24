import XCTest
@testable import NeutrinoCalendar

final class EventFormattingTests: XCTestCase {

    private let pacific = TimeZone(identifier: "America/Los_Angeles")!

    private func occurrence(_ start: String, _ end: String, allDay: Bool = false,
                            timezone: String? = nil) -> EventOccurrence {
        let event = CalendarEvent(id: "e", title: "e", start: ServerDate.parse(start)!,
                                  end: ServerDate.parse(end)!, allDay: allDay, timezone: timezone)
        return EventOccurrence(event: event, start: event.start, end: event.end)
    }

    func testAllDay() {
        XCTAssertEqual(EventFormatting.timeSummary(occurrence("2026-09-01T00:00:00Z", "2026-09-01T23:59:59Z",
                                                              allDay: true), timeZone: pacific), "All day")
    }

    func testOneDayTimedEventShowsTwoTimes() {
        let text = EventFormatting.timeSummary(occurrence("2026-09-01T16:00:00Z", "2026-09-01T17:30:00Z"),
                                               timeZone: pacific)
        XCTAssertTrue(text.hasPrefix("9:00"), text)
        XCTAssertTrue(text.contains("10:30"), text)
        XCTAssertFalse(text.contains("Sep"), "a same-day end needs no date: \(text)")
    }

    func testEventEndingAtMidnightStaysOneDay() {
        let text = EventFormatting.timeSummary(occurrence("2026-09-02T06:00:00Z", "2026-09-02T07:00:00Z"),
                                               timeZone: pacific)
        XCTAssertFalse(text.contains("Sep"), text)
    }

    func testOvernightEventNamesTheEndDay() {
        let text = EventFormatting.timeSummary(occurrence("2026-09-02T05:00:00Z", "2026-09-02T09:00:00Z"),
                                               timeZone: pacific)
        XCTAssertTrue(text.contains("Sep 2"), text)
    }

    func testAllDayDateIgnoresTheDevicesZone() {
        // All-day on Sept 1 is Sept 1 even in a zone where 00:00Z is still Aug 31.
        let text = EventFormatting.dateSummary(occurrence("2026-09-01T00:00:00Z", "2026-09-01T23:59:59Z",
                                                          allDay: true), timeZone: pacific)
        XCTAssertTrue(text.contains("September 1"), text)
    }

    func testOriginalZoneShownOnlyWhenItDiffers() {
        let east = occurrence("2026-09-01T16:00:00Z", "2026-09-01T17:00:00Z", timezone: "America/New_York")
        let summary = EventFormatting.originalTimeZoneSummary(east, deviceTimeZone: pacific)
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.hasPrefix("12:00") ?? false, summary ?? "")

        let local = occurrence("2026-09-01T16:00:00Z", "2026-09-01T17:00:00Z", timezone: "America/Los_Angeles")
        XCTAssertNil(EventFormatting.originalTimeZoneSummary(local, deviceTimeZone: pacific))
        XCTAssertNil(EventFormatting.originalTimeZoneSummary(
            occurrence("2026-09-01T16:00:00Z", "2026-09-01T17:00:00Z", timezone: "Not/AZone"),
            deviceTimeZone: pacific))
    }

    func testRecurrenceSummary() {
        XCTAssertEqual(EventFormatting.recurrenceSummary("FREQ=DAILY"), "Repeats daily")
        XCTAssertEqual(EventFormatting.recurrenceSummary("FREQ=MONTHLY;INTERVAL=3"), "Repeats every 3 months")
        XCTAssertTrue(EventFormatting.recurrenceSummary("FREQ=WEEKLY;BYDAY=MO,WE").hasPrefix("Repeats weekly on "))
        XCTAssertEqual(EventFormatting.recurrenceSummary("RRULE:FREQ=DAILY"), "Repeats (RRULE:FREQ=DAILY)")
    }
}
