import XCTest
@testable import NeutrinoCalendar

final class NotificationPlanTests: XCTestCase {

    private let now = ServerDate.parse("2026-09-25T17:00:00Z")!

    private func reminder(_ id: String, in minutes: Double, completed: Bool = false) -> Reminder {
        Reminder(id: id, title: id, due: now.addingTimeInterval(minutes * 60), completed: completed)
    }

    func testOnlyOpenFutureRemindersAreScheduledSoonestFirst() {
        let plan = NotificationPlan.plan([
            reminder("later", in: 120),
            reminder("done", in: 30, completed: true),
            reminder("overdue", in: -5),
            reminder("soon", in: 10),
        ], now: now)
        XCTAssertEqual(plan.map(\.reminderID), ["soon", "later"])
        XCTAssertEqual(plan.first?.fireDate, now.addingTimeInterval(600))
    }

    /// iOS keeps 64 pending per app; the nearest 60 are taken and the rest wait their turn.
    func testTheNearestSixtyAreKept() {
        let many = (0..<100).map { reminder("r\($0)", in: Double(100 - $0)) }
        let plan = NotificationPlan.plan(many, now: now)
        XCTAssertEqual(plan.count, NotificationPlan.limit)
        XCTAssertEqual(plan.first?.reminderID, "r99")
        XCTAssertEqual(plan.last?.reminderID, "r40")
    }

    /// A reminder moved to another time is another notification, so the old one goes.
    func testAMovedReminderReplacesItsNotification() {
        let before = NotificationPlan.plan([reminder("r", in: 10)], now: now)
        let after = NotificationPlan.plan([reminder("r", in: 20)], now: now)
        let changes = NotificationPlan.changes(pending: before.map(\.identifier), planned: after)
        XCTAssertEqual(changes.add.map(\.identifier), after.map(\.identifier))
        XCTAssertEqual(changes.remove, before.map(\.identifier))
    }

    func testAnUnchangedPlanChangesNothing() {
        let plan = NotificationPlan.plan([reminder("a", in: 10), reminder("b", in: 20)], now: now)
        let changes = NotificationPlan.changes(pending: plan.map(\.identifier), planned: plan)
        XCTAssertTrue(changes.add.isEmpty)
        XCTAssertTrue(changes.remove.isEmpty)
    }

    /// Snoozes and anything not this app's reminders are left alone.
    func testOnlyReminderNotificationsAreRemoved() {
        let changes = NotificationPlan.changes(pending: ["snooze.a", "something-else", "reminder.gone.1"],
                                               planned: [])
        XCTAssertEqual(changes.remove, ["reminder.gone.1"])
    }

    func testIdentifiersCarryTheDueTime() {
        XCTAssertEqual(NotificationPlan.identifier(reminderID: "abc", due: now), "reminder.abc.1790355600")
    }
}
