import XCTest
@testable import NeutrinoCalendar

final class LayoutDensityTests: XCTestCase {

    /// The key is stored on real devices from the first build that ships it; renaming it would
    /// silently turn the setting off for everyone who had turned it on.
    func testTheKeyIsInTheAppsNamespace() {
        XCTAssertEqual(LayoutDensity.storageKey, "ncal.layout.compact")
    }

    /// Compact means less space than SwiftUI's defaults, never more.
    func testCompactValuesAreTighterThanTheDefaults() {
        XCTAssertLessThan(LayoutDensity.compactMinRowHeight, 44)
        XCTAssertLessThan(LayoutDensity.compactHorizontalMargin, 16)
        XCTAssertLessThan(LayoutDensity.compactRowInsets.top, 11)
    }
}
