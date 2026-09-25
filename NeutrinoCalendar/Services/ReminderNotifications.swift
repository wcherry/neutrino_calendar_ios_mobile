import Foundation
import UserNotifications
import os.log

/// Local notifications for reminders, and what happens when one is acted on.
///
/// The plan is made again whenever the reminder list changes, when the app comes forward, and
/// from background refresh, so an alert set on the web reaches the phone as long as the phone
/// has synced since. Actions: **Mark as Done** completes the reminder on the server, which moves
/// a repeating one to its next time; **Snooze** fires again in ten minutes, on this device only;
/// tapping the notification opens the reminder.
@MainActor
final class ReminderNotifications: NSObject, ObservableObject {

    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined

    /// Set once at launch.
    weak var reminders: RemindersService?
    /// Called with a reminder's id when its notification is tapped.
    var onOpen: ((String) -> Void)?

    static let enabledKey = "ncal.notifications.enabled"
    static let category = "REMINDER"
    static let snoozeAction = "SNOOZE"
    static let doneAction = "DONE"
    static let snoozeInterval: TimeInterval = 10 * 60

    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoCalendar",
                                category: "ReminderNotifications")

    /// The Settings switch. On by default: a reminder app that doesn't remind is the surprise.
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Must run during launch, so an action that launched the app is delivered here.
    func configure() {
        center.delegate = self
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "Snooze 10 Minutes",
                                          options: [])
        let done = UNNotificationAction(identifier: Self.doneAction, title: "Mark as Done", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [done, snooze],
                                   intentIdentifiers: [], options: []),
        ])
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    private var isAuthorized: Bool {
        [.authorized, .provisional, .ephemeral].contains(authorization)
    }

    // MARK: - Planning

    /// Brings the pending notifications in line with `reminders`. Asks for permission the first
    /// time there is something to remind about, which is when the question makes sense.
    func apply(_ reminders: [Reminder], now: Date = Date()) async {
        guard isEnabled else {
            await removeAll()
            return
        }
        let plan = NotificationPlan.plan(reminders, now: now)
        await refreshAuthorization()
        if authorization == .notDetermined, !plan.isEmpty {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
        }
        guard isAuthorized else { return }

        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let changes = NotificationPlan.changes(pending: pending, planned: plan)
        center.removePendingNotificationRequests(withIdentifiers: changes.remove)
        for alert in changes.add {
            await add(identifier: alert.identifier, reminderID: alert.reminderID, title: alert.title,
                      after: alert.fireDate.timeIntervalSince(now))
        }
        logger.debug("planned \(plan.count) alert(s): +\(changes.add.count) −\(changes.remove.count)")
    }

    /// Removes every notification this app scheduled, for sign-out and for the switch turned off.
    func removeAll() async {
        let ours = await center.pendingNotificationRequests().map(\.identifier).filter {
            $0.hasPrefix(NotificationPlan.reminderPrefix) || $0.hasPrefix(NotificationPlan.snoozePrefix)
        }
        center.removePendingNotificationRequests(withIdentifiers: ours)
        center.removeAllDeliveredNotifications()
    }

    /// A time-interval trigger rather than a calendar one: the reminder is an instant, and a
    /// calendar trigger would fire at the same wall-clock time in whatever zone the phone is in.
    private func add(identifier: String, reminderID: String, title: String, after interval: TimeInterval) async {
        guard interval > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = "Reminder"
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.userInfo = ["reminderID": reminderID]
        content.threadIdentifier = "reminders"
        let request = UNNotificationRequest(identifier: identifier, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
        do {
            try await center.add(request)
        } catch {
            logger.error("could not schedule \(identifier, privacy: .public): \(error, privacy: .public)")
        }
    }

    // MARK: - Actions

    fileprivate func handle(action: String, reminderID: String, title: String) async {
        switch action {
        case Self.doneAction:
            await markDone(reminderID)
        case Self.snoozeAction:
            await add(identifier: "\(NotificationPlan.snoozePrefix)\(reminderID)", reminderID: reminderID,
                      title: title, after: Self.snoozeInterval)
        default:
            onOpen?(reminderID)
        }
    }

    /// Completes the reminder on the server. The list may not be loaded when the app was launched
    /// by the action, so it is loaded first.
    private func markDone(_ reminderID: String) async {
        guard let reminders else { return }
        if !reminders.reminders.contains(where: { $0.id == reminderID }) { await reminders.reload() }
        guard let reminder = reminders.reminders.first(where: { $0.id == reminderID }),
              !reminder.completed else { return }
        await reminders.setCompleted(reminder, true)
    }
}

// MARK: - UNUserNotificationCenterDelegate

/// The completion-handler forms, not the `async` ones: an `async` implementation returns on a
/// background thread, and UIKit asserts that the completion runs on the main thread (it updates
/// the app's snapshot there), so the app crashed on the first notification tapped. Each handler
/// is called from the main actor instead.
extension ReminderNotifications: UNUserNotificationCenterDelegate {

    /// Shown as a banner even with the app open: the reminder is due whatever screen is showing.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                                @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in completionHandler([.banner, .list, .sound]) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let action = response.actionIdentifier
        let reminderID = content.userInfo["reminderID"] as? String
        let title = content.title
        Task { @MainActor in
            if let reminderID {
                await self.handle(action: action, reminderID: reminderID, title: title)
            }
            completionHandler()
        }
    }
}
