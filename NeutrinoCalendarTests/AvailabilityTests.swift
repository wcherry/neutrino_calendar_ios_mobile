import XCTest
@testable import NeutrinoCalendar

/// Busy, free, tentative or away: what the server sends, and what the form sends back.
final class AvailabilityTests: XCTestCase {

    private func date(_ iso: String) -> Date { ServerDate.parse(iso)! }

    private func decode(_ extra: String) throws -> CalendarEvent {
        let json = """
        {"id":"e","title":"Lunch","startTime":"2026-11-20T20:00:00Z","endTime":"2026-11-20T21:00:00Z",
         "allDay":false,"attendees":[],"source":"local"\(extra)}
        """
        return try JSONDecoder().decode(CalendarEvent.self, from: Data(json.utf8))
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private var lunch: CalendarEvent {
        CalendarEvent(id: "e", title: "Lunch", start: date("2026-11-20T20:00:00Z"),
                      end: date("2026-11-20T21:00:00Z"), availability: .tentative)
    }

    func testDecodesEachKindAndReadsAnOlderServerOrAnUnknownValueAsBusy() throws {
        XCTAssertEqual(try decode(#","availability":"tentative""#).availability, .tentative)
        XCTAssertEqual(try decode(#","availability":"away""#).availability, .away)
        XCTAssertEqual(try decode("").availability, .busy, "a server older than availability")
        XCTAssertEqual(try decode(#","availability":"oof""#).availability, .busy)
    }

    func testANewBusyEventDoesNotSendItButAnyOtherDoes() throws {
        var draft = EventDraft(newOn: date("2026-11-20T20:00:00Z"))
        draft.title = "Gym"
        XCTAssertNil(try json(draft.createRequest())["availability"], "busy is the server's default")
        draft.availability = .free
        XCTAssertEqual(try json(draft.createRequest())["availability"] as? String, "free")
    }

    func testAnEditStartsFromTheEventsAndSendsItOnlyWhenChanged() throws {
        let original = EventDraft(editing: lunch)
        XCTAssertEqual(original.availability, .tentative)

        var draft = original
        draft.title = "Long lunch"
        XCTAssertNil(try json(draft.updateRequest(from: original))["availability"])

        draft.availability = .busy
        XCTAssertEqual(try json(draft.updateRequest(from: original))["availability"] as? String, "busy")
    }

    func testAnOccurrenceAndALocalEditKeepIt() {
        let occurrence = CalendarEvent(lunch, start: date("2026-11-27T20:00:00Z"),
                                       end: date("2026-11-27T21:00:00Z"), recurrenceRule: nil)
        XCTAssertEqual(occurrence.availability, .tentative)

        var draft = EventDraft(editing: lunch)
        draft.availability = .away
        XCTAssertEqual(CalendarEvent(lunch, editedTo: draft).availability, .away)
    }

    func testAChangeToAvailabilityOnBothDevicesIsAConflict() {
        XCTAssertEqual(EditConflict.clashes(mine: UpdateEventRequest(availability: .free),
                                            theirs: UpdateEventRequest(availability: .away)),
                       ["availability"])
        XCTAssertEqual(EditConflict.clashes(mine: UpdateEventRequest(availability: .free),
                                            theirs: UpdateEventRequest(title: "Gym")), [])
    }

    func testICalMatchesTheServer() {
        XCTAssertEqual(EventAvailability.fromICal(transp: nil, busyStatus: nil), .busy)
        XCTAssertEqual(EventAvailability.fromICal(transp: "TRANSPARENT", busyStatus: nil), .free)
        XCTAssertEqual(EventAvailability.fromICal(transp: nil, busyStatus: "free"), .free)
        XCTAssertEqual(EventAvailability.fromICal(transp: "OPAQUE", busyStatus: "TENTATIVE"), .tentative)
        XCTAssertEqual(EventAvailability.fromICal(transp: nil, busyStatus: "OOF"), .away)
        XCTAssertEqual(EventAvailability.fromICal(transp: "OPAQUE", busyStatus: "FREE"), .busy,
                       "Apple left Outlook's status behind")
        XCTAssertEqual(EventAvailability.fromICal(transp: "TRANSPARENT", busyStatus: "OOF"), .free)
    }

    func testAnICSFileCarriesIt() throws {
        let ics = ["BEGIN:VCALENDAR", "VERSION:2.0", "BEGIN:VEVENT", "SUMMARY:Holiday",
                   "DTSTART:20261123T090000Z", "DTEND:20261123T170000Z", "X-MICROSOFT-CDO-BUSYSTATUS:OOF",
                   "END:VEVENT", "END:VCALENDAR"].joined(separator: "\r\n")
        XCTAssertEqual(try ICSImport.draft(from: ics).availability, .away)
    }
}
