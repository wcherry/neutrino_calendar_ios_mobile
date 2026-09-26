import CoreSpotlight
import SwiftUI
import NeutrinoCore
import NeutrinoAuth
import NeutrinoCrypto
import NeutrinoUI

@main
struct NeutrinoCalendarApp: App {
    // Built in `init()` rather than given a default value here: defaults are evaluated before the
    // initializer body runs, and the shared services resolve their Keychain namespace through
    // `NeutrinoApp.current` the moment they are constructed.
    @StateObject private var authService: AuthService
    @StateObject private var networkMonitor: NetworkMonitor
    @StateObject private var eventsService: EventsService
    @StateObject private var remindersService: RemindersService
    @StateObject private var tasksService: TasksService
    @StateObject private var notifications: ReminderNotifications
    @StateObject private var router: AppRouter
    @StateObject private var sync: CalendarSync
    @StateObject private var attachmentFiles: AttachmentFiles
    @StateObject private var keyProvisioning: KeyProvisioningService

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The services are shared with the App Intents, which can run with no scene; see
        // AppServices. Making them configures the `ncal.*` namespace, so it comes first.
        let services = AppServices.shared
        NeutrinoBrand.use(.calendar)

        _authService = StateObject(wrappedValue: services.auth)
        _networkMonitor = StateObject(wrappedValue: services.network)
        _eventsService = StateObject(wrappedValue: services.events)
        _remindersService = StateObject(wrappedValue: services.reminders)
        _tasksService = StateObject(wrappedValue: services.tasks)
        _notifications = StateObject(wrappedValue: services.notifications)
        _router = StateObject(wrappedValue: services.router)
        _sync = StateObject(wrappedValue: services.sync)
        _attachmentFiles = StateObject(wrappedValue: services.attachmentFiles)
        _keyProvisioning = StateObject(wrappedValue: services.keyProvisioning)

        // iOS only runs a background task registered before launch finishes.
        BackgroundRefresh.register(auth: services.auth, sync: services.sync, reminders: services.reminders,
                                   notifications: services.notifications)
    }

    var body: some Scene {
        WindowGroup {
            RootContentView()
                .environmentObject(authService)
                .environmentObject(networkMonitor)
                .environmentObject(eventsService)
                .environmentObject(remindersService)
                .environmentObject(tasksService)
                .environmentObject(notifications)
                .environmentObject(router)
                .environmentObject(sync)
                .environmentObject(sync.pending)
                .environmentObject(attachmentFiles)
                .environmentObject(keyProvisioning)
                // A Spotlight result opens its event.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                          let link = EventLink(string: id) else { return }
                    router.open(link)
                }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                // A Focus that changed while the app was away.
                eventsService.setSourceFilter(.load())
                // Reconnects the live signal and catches up on changes made elsewhere while the
                // app was away; the reminders reload re-plans the notifications.
                if authService.isAuthenticated { sync.start() }
            case .background:
                sync.suspend()
                BackgroundRefresh.schedule()
            default:
                break
            }
        }
    }
}

// MARK: - RootContentView

/// Switches between the sign-in screen and the app, and keeps the session alive across launches.
private struct RootContentView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var eventsService: EventsService
    @EnvironmentObject var remindersService: RemindersService
    @EnvironmentObject var tasksService: TasksService
    @EnvironmentObject var notifications: ReminderNotifications
    @EnvironmentObject var sync: CalendarSync
    @EnvironmentObject var attachmentFiles: AttachmentFiles

    var body: some View {
        Group {
            if authService.isAuthenticated {
                ContentView()
                    // Every date picker, sheets included, starts its weeks where the grids do.
                    .environment(\.calendar, eventsService.calendar)
            } else {
                LoginView()
            }
        }
        .task {
            if authService.isAuthenticated {
                await authService.refreshTokenIfNeeded()
                // Loads reminders at launch, not only when the Reminders tab opens: the
                // notifications are planned from that list.
                sync.start()
            }
        }
        // Every change to the list re-plans the notifications. Only once the list has loaded:
        // an empty list before the first load would otherwise unschedule every alert, and a
        // launch with no network would leave the phone with none.
        .onReceive(remindersService.$reminders) { reminders in
            guard authService.isAuthenticated, remindersService.hasLoaded else { return }
            Task { await notifications.apply(reminders) }
        }
        .onChange(of: authService.isAuthenticated) { isAuthenticated in
            if !isAuthenticated {
                sync.stop()
                // Decrypted attachments must not outlive the session that opened them.
                attachmentFiles.clearCache()
                eventsService.reset()
                remindersService.reset()
                tasksService.reset()
                // The next account must not be reminded of this one's reminders, or find its
                // events in Spotlight.
                Task { await notifications.removeAll() }
                Task { await AppServices.shared.spotlight.removeAll() }
            } else {
                sync.start()
            }
        }
    }
}
