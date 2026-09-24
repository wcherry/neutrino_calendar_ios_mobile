import XCTest
@testable import NeutrinoCalendar

/// `ReportBugButton.swift` is copied between the Neutrino apps, so the easy mistake is a copy
/// that still files reports against the app it came from.
final class BugReportTests: XCTestCase {

    func testReportsGoToThisRepository() {
        XCTAssertEqual(BugReport.repository, "wcherry/neutrino_calendar_ios_mobile")
        XCTAssertTrue(BugReport.issueURL.absoluteString
            .hasPrefix("https://github.com/wcherry/neutrino_calendar_ios_mobile/issues/new"))
    }
}
