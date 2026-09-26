import Foundation
import NeutrinoCore
import NeutrinoAuth
import NeutrinoCrypto

/// The app's services, made once per process and shared by the SwiftUI scene and the App
/// Intents, which Siri, Shortcuts and Focus can run with no scene at all. Two sets would mean two
/// sessions refreshing one token and two notification plans fighting over the same alerts.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let auth: AuthService
    let network: NetworkMonitor
    let events: EventsService
    let reminders: RemindersService
    let tasks: TasksService
    let notifications: ReminderNotifications
    let router: AppRouter
    let sync: CalendarSync
    let attachmentFiles: AttachmentFiles
    let keyProvisioning: KeyProvisioningService
    let spotlight: SpotlightIndexer

    private init() {
        // Before anything else. Everything the shared package writes is namespaced `ncal.*`, and
        // the services resolve that namespace the moment they are constructed.
        NeutrinoApp.configure(.calendar)

        auth = AuthService()
        network = NetworkMonitor()
        let client = CalendarAPIClient(authService: auth)
        events = EventsService(client: client)
        tasks = TasksService(client: client)
        attachmentFiles = AttachmentFiles(client: client)
        keyProvisioning = KeyProvisioningService(authService: auth)
        spotlight = SpotlightIndexer(events: events, isSignedIn: { [weak auth] in auth?.isAuthenticated == true })

        // Reminder notifications and their actions. Registered during launch: a notification
        // action can be what launched the app.
        reminders = RemindersService(client: client)
        router = AppRouter()
        notifications = ReminderNotifications()
        notifications.reminders = reminders
        notifications.onOpen = { [weak router] id in router?.open(reminderID: id) }
        notifications.configure()

        // Live changes from the web and other devices, and edits made offline.
        let signals = CalendarSignalsClient(token: { [weak auth] in
            guard let auth else { return nil }
            await auth.refreshTokenIfNeeded()
            return auth.accessToken()
        })
        sync = CalendarSync(client: client, signals: signals, pending: PendingWrites(),
                            events: events, reminders: reminders, tasks: tasks, spotlight: spotlight)
        sync.observe(network)
    }
}
