import SwiftUI
import NeutrinoAuth
import NeutrinoCore
import NeutrinoUI

/// The tab shell from Epic 1. Each tab is an empty state that names the epic that fills it.
struct ContentView: View {
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var network: NetworkMonitor
    @EnvironmentObject var sync: CalendarSync
    @EnvironmentObject var pending: PendingWrites

    enum Tab: Hashable {
        case calendar, reminders, tasks, settings
    }

    var body: some View {
        TabView(selection: $router.tab) {
            NavigationStack {
                CalendarHomeView()
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 0) {
                            FocusFilterBanner()
                            PendingWritesBanner()
                        }
                    }
            }
            .tabItem { Label("Calendar", systemImage: "calendar") }
            .tag(Tab.calendar)

            if FeatureFlags.reminders {
                NavigationStack {
                    RemindersView()
                    .safeAreaInset(edge: .bottom, spacing: 0) { PendingWritesBanner() }
                }
                .tabItem { Label("Reminders", systemImage: "bell") }
                .tag(Tab.reminders)
            }

            if FeatureFlags.tasks {
                NavigationStack(path: $router.tasksPath) {
                    TasksView()
                    .safeAreaInset(edge: .bottom, spacing: 0) { PendingWritesBanner() }
                }
                .tabItem { Label("Tasks", systemImage: "checklist") }
                .tag(Tab.tasks)
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gear") }
            .tag(Tab.settings)
        }
        .connectivityBanner(isOnline: network.isOnline,
                            pendingChanges: pending.writes.count,
                            activity: pending.activity,
                            onRetry: { Task { await sync.catchUp() } })
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthService())
        .environmentObject(EventsService(client: CalendarAPIClient(token: { nil })))
        .environmentObject(RemindersService(client: CalendarAPIClient(token: { nil })))
        .environmentObject(TasksService(client: CalendarAPIClient(token: { nil })))
        .environmentObject(ReminderNotifications())
        .environmentObject(AppRouter())
        .environmentObject(CalendarsService(client: CalendarAPIClient(token: { nil }),
                                            cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-calendars.json")))
        .environmentObject(PlacesService(client: CalendarAPIClient(token: { nil })))
        .environmentObject(GeofenceMonitor())
        .environmentObject(NetworkMonitor(autoStart: false))
        .environmentObject(PendingWrites(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-pending.json")))
}
