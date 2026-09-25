import SwiftUI
import NeutrinoCore
import NeutrinoAuth

struct SettingsView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var events: EventsService
    @AppStorage(LayoutDensity.storageKey) private var compactLayout = false
    @AppStorage(WeekStart.storageKey) private var weekStart = WeekStart.default.rawValue

    var body: some View {
        List {
            Section("Account") {
                LabeledContent("Server", value: NeutrinoStorage.serverHost)
            }

            Section {
                Picker("Week starts on", selection: $weekStart) {
                    ForEach(WeekStart.allCases) { Text($0.label).tag($0.rawValue) }
                }
            } header: {
                Text("Calendar")
            } footer: {
                Text("Used by the month, week and year views and every date picker, as on the web.")
            }
            .onChange(of: weekStart) { raw in
                events.setWeekStart(WeekStart(rawValue: raw) ?? .default)
            }

            Section {
                Toggle("Compact layout", isOn: $compactLayout)
            } header: {
                Text("Display")
            } footer: {
                Text("Less space around rows, sections and the edges of the screen, so more fits at once.")
            }

            // Filled by Epic 17: Google and Outlook over OAuth, iCloud over CalDAV.
            Section("Connected Calendars") {
                Text("Connect Google, Outlook or iCloud from the web app for now.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: BugReport.appVersion)
                ReportBugButton()
            }

            Section {
                Button(role: .destructive) {
                    authService.logout()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .densityList()
        .navigationTitle("Settings")
    }
}
