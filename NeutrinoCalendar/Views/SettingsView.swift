import SwiftUI
import NeutrinoCore
import NeutrinoAuth

struct SettingsView: View {
    @EnvironmentObject var authService: AuthService

    var body: some View {
        List {
            Section("Account") {
                LabeledContent("Server", value: NeutrinoStorage.serverHost)
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
        .navigationTitle("Settings")
    }
}
