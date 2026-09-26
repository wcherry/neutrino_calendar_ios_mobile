import SwiftUI
import NeutrinoCore
import NeutrinoAuth
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

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before anything else. Everything the shared package writes is namespaced `ncal.*`.
        NeutrinoApp.configure(.calendar)
        NeutrinoBrand.use(.calendar)

        let authService = AuthService()
        _authService = StateObject(wrappedValue: authService)
        let networkMonitor = NetworkMonitor()
        _networkMonitor = StateObject(wrappedValue: networkMonitor)
        let client = CalendarAPIClient(authService: authService)
        let events = EventsService(client: client)
        _eventsService = StateObject(wrappedValue: events)
        let tasks = TasksService(client: client)
        _tasksService = StateObject(wrappedValue: tasks)

        // Reminder notifications and their actions. Both registrations have to happen during
        // launch: a notification action can be what launched the app, and iOS only runs a
        // background task registered before launch finishes.
        let reminders = RemindersService(client: client)
        _remindersService = StateObject(wrappedValue: reminders)
        let router = AppRouter()
        _router = StateObject(wrappedValue: router)
        let notifications = ReminderNotifications()
        notifications.reminders = reminders
        notifications.onOpen = { [weak router] id in router?.open(reminderID: id) }
        notifications.configure()
        _notifications = StateObject(wrappedValue: notifications)

        // Live changes from the web and other devices, and edits made offline.
        let signals = CalendarSignalsClient(token: { [weak authService] in
            guard let authService else { return nil }
            await authService.refreshTokenIfNeeded()
            return authService.accessToken()
        })
        let sync = CalendarSync(client: client, signals: signals, pending: PendingWrites(),
                                events: events, reminders: reminders, tasks: tasks)
        sync.observe(networkMonitor)
        _sync = StateObject(wrappedValue: sync)

        BackgroundRefresh.register(auth: authService, sync: sync, reminders: reminders,
                                   notifications: notifications)
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
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
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

    var body: some View {
        Group {
            if authService.isAuthenticated {
                ContentView()
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
                eventsService.reset()
                remindersService.reset()
                tasksService.reset()
                // The next account must not be reminded of this one's reminders.
                Task { await notifications.removeAll() }
            } else {
                sync.start()
            }
        }
    }
}
