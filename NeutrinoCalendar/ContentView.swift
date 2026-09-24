import SwiftUI
import NeutrinoAuth

/// The tab shell from Epic 1. Each tab is an empty state that names the epic that fills it.
struct ContentView: View {
    @State private var selectedTab = Tab.calendar

    enum Tab: Hashable {
        case calendar, reminders, tasks, settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                CalendarHomeView()
            }
            .tabItem { Label("Calendar", systemImage: "calendar") }
            .tag(Tab.calendar)

            if FeatureFlags.reminders {
                NavigationStack {
                    RemindersView()
                }
                .tabItem { Label("Reminders", systemImage: "bell") }
                .tag(Tab.reminders)
            }

            if FeatureFlags.tasks {
                NavigationStack {
                    TasksView()
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
}
