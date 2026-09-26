import SwiftUI
import NeutrinoAuth

/// The tab shell from Epic 1. Each tab is an empty state that names the epic that fills it.
struct ContentView: View {
    @EnvironmentObject var router: AppRouter

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
                NavigationStack {
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
        .environmentObject(PendingWrites(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-pending.json")))
}
