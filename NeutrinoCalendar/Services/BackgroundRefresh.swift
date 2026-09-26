import BackgroundTasks
import Foundation
import NeutrinoAuth

/// Re-syncs reminders and re-plans their notifications while the app is not open, so an alert
/// set on the web reaches the phone before it is due. iOS decides when a refresh actually runs;
/// this asks for one about every half hour.
enum BackgroundRefresh {
    /// Listed in `BGTaskSchedulerPermittedIdentifiers` in project.yml.
    static let identifier = "com.neutrino.calendar.refresh"
    static let interval: TimeInterval = 30 * 60

    /// Must run during launch, before the app finishes launching.
    @MainActor
    static func register(auth: AuthService, reminders: RemindersService, notifications: ReminderNotifications) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            // The next one is asked for first, so a refresh that fails doesn't end the chain.
            schedule()
            let work = Task { @MainActor in
                guard auth.isAuthenticated else {
                    task.setTaskCompleted(success: true)
                    return
                }
                await reminders.reload()
                if reminders.hasLoaded { await notifications.apply(reminders.reminders) }
                task.setTaskCompleted(success: reminders.error == nil)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        // Refused in the simulator and when Background App Refresh is off; nothing to do then.
        try? BGTaskScheduler.shared.submit(request)
    }
}
