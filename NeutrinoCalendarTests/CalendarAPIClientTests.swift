import XCTest
@testable import NeutrinoCalendar

@MainActor
final class CalendarAPIClientTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        MockURLProtocol.reset()
    }

    private func client(token: String? = "tok") -> CalendarAPIClient {
        CalendarAPIClient(session: session, baseURL: { "https://example.test" }, token: { token })
    }

    /// What `EventResponse` in the server's `events/dto.rs` actually serialises.
    static let serverEventsJSON = """
    {"events":[{"id":"ev-1","title":"Standup","description":null,
      "startTime":"2026-09-24T16:00:00Z","endTime":"2026-09-24T16:15:00Z","allDay":false,
      "location":"Room 4","recurrenceRule":"FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR",
      "attendees":["a@example.com"],"source":"google",
      "createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-02T00:00:00Z",
      "timezone":"America/New_York"}]}
    """

    func testEventsSendsTheRangeAndBearerTokenAndDecodes() async throws {
        MockURLProtocol.respond(status: 200, body: Self.serverEventsJSON)
        let from = try XCTUnwrap(ServerDate.parse("2026-09-01T07:00:00Z"))
        let to = try XCTUnwrap(ServerDate.parse("2026-10-01T06:59:59Z"))

        let events = try await client().events(from: from, to: to)

        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/api/v1/calendar/events")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "from" }?.value, "2026-09-01T07:00:00Z")
        XCTAssertEqual(query.first { $0.name == "to" }?.value, "2026-10-01T06:59:59Z")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")

        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.title, "Standup")
        XCTAssertEqual(event.start, ServerDate.parse("2026-09-24T16:00:00Z"))
        XCTAssertEqual(event.source, .google)
        XCTAssertEqual(event.source.badge, "Google")
        XCTAssertEqual(event.attendees, ["a@example.com"])
        XCTAssertEqual(event.timezone, "America/New_York")
    }

    func testDecodesWhatTheWebWritesBack() throws {
        // The web sends toISOString(), with milliseconds, and older rows may lack newer fields.
        let json = """
        {"id":"x","title":"t","startTime":"2026-09-24T16:00:00.000Z","endTime":"2026-09-24T17:00:00.000Z",
         "allDay":false,"source":"local"}
        """
        let event = try JSONDecoder().decode(CalendarEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.start, ServerDate.parse("2026-09-24T16:00:00Z"))
        XCTAssertEqual(event.attendees, [])
        XCTAssertNil(event.source.badge)
    }

    func testUnknownSourceIsKeptRatherThanRejected() throws {
        XCTAssertEqual(EventSource(rawValue: "caldav").badge, "Caldav")
    }

    func testAttachments() async throws {
        MockURLProtocol.respond(status: 200, body: """
        {"attachments":[{"id":"a1","eventId":"ev-1","fileId":"f1","name":"Agenda.pdf","note":null},
                        {"id":"a2","eventId":"ev-1","fileId":null,"name":null,"note":"Bring snacks"}]}
        """)
        let attachments = try await client().attachments(forEvent: "ev-1")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/v1/calendar/events/ev-1/attachments")
        XCTAssertEqual(attachments.map(\.id), ["a1", "a2"])
        XCTAssertEqual(attachments[1].note, "Bring snacks")
    }

    func testNoTokenFailsWithoutARequest() async {
        do {
            _ = try await client(token: nil).events(from: Date(), to: Date())
            XCTFail("expected notAuthenticated")
        } catch {
            XCTAssertEqual(error as? CalendarAPIError, .notAuthenticated)
            XCTAssertNil(MockURLProtocol.lastRequest)
        }
    }

    func testStatusCodesMapToErrors() async {
        for (status, expected) in [(401, CalendarAPIError.notAuthenticated),
                                   (500, CalendarAPIError.serverError(statusCode: 500))] {
            MockURLProtocol.respond(status: status, body: "{}")
            do {
                _ = try await client().events(from: Date(), to: Date())
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? CalendarAPIError, expected)
            }
        }
    }

    func testUnauthorizedEndsTheSessionButOtherFailuresDoNot() async {
        var signOuts = 0
        let client = CalendarAPIClient(session: session, baseURL: { "https://example.test" },
                                       token: { "tok" }, onUnauthorized: { signOuts += 1 })
        for status in [500, 404, 401] {
            MockURLProtocol.respond(status: status, body: "{}")
            _ = try? await client.events(from: Date(), to: Date())
        }
        XCTAssertEqual(signOuts, 1, "only a 401 means the session is over")
    }

    func testMalformedBodyIsADecodingError() async {
        MockURLProtocol.respond(status: 200, body: #"{"events":[{"id":1}]}"#)
        do {
            _ = try await client().events(from: Date(), to: Date())
            XCTFail("expected a decoding error")
        } catch {
            guard case .decodingError = error as? CalendarAPIError else {
                return XCTFail("expected decodingError, got \(error)")
            }
        }
    }
}

// MARK: - MockURLProtocol

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body = Data()

    static func reset() {
        lastRequest = nil
        status = 200
        body = Data()
    }


    static func respond(status: Int, body: String) {
        self.status = status
        self.body = Data(body.utf8)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
