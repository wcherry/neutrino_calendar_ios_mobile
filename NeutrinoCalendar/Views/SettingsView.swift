import SwiftUI
import NeutrinoCore
import NeutrinoAuth
import NeutrinoCrypto

struct SettingsView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var notifications: ReminderNotifications
    @EnvironmentObject var remindersService: RemindersService
    @EnvironmentObject var geofences: GeofenceMonitor
    @AppStorage(ReminderNotifications.enabledKey) private var alertsEnabled = true
    @AppStorage(LayoutDensity.storageKey) private var compactLayout = false
    @AppStorage(LiveActivities.enabledKey) private var liveActivitiesEnabled = true
    @EnvironmentObject var keyProvisioning: KeyProvisioningService
    @State private var encryptionFlow: EncryptionFlow?
    @State private var encryptionRevision = 0
    @EnvironmentObject var events: EventsService
    @AppStorage(WeekStart.storageKey) private var weekStart = WeekStart.default.rawValue

    private var locationAccess: String {
        switch geofences.authorization {
        case .authorizedAlways:    return "Always"
        case .authorizedWhenInUse: return "While Using"
        case .denied, .restricted: return "Off"
        default:                   return "Not asked"
        }
    }

    var body: some View {
        List {
            Section("Account") {
                LabeledContent("Server", value: NeutrinoStorage.serverHost)
            }

            Section {
                Toggle("Reminder alerts", isOn: $alertsEnabled)
                if alertsEnabled && notifications.authorization == .denied {
                    Button("Allow Notifications in Settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text(notificationsFooter)
            }
            .onChange(of: alertsEnabled) { _ in
                Task { await notifications.apply(remindersService.reminders) }
            }
            .task { await notifications.refreshAuthorization() }

            if FeatureFlags.tasks {
                Section {
                    NavigationLink("Saved Places") { SavedPlacesView() }
                    LabeledContent("Location access", value: locationAccess)
                    if geofences.authorization != .authorizedAlways && geofences.authorization != .notDetermined {
                        Button("Change in Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                } header: {
                    Text("Places")
                } footer: {
                    Text("A task with a place reminds you when you arrive there, which needs location access set to Always. This iPhone watches for arrivals itself: your location is never sent to the server.")
                }
            }

            Section {
                Toggle("Live Activities", isOn: $liveActivitiesEnabled)
            } header: {
                Text("Lock Screen")
            } footer: {
                Text("Shows your next event on the Lock Screen and in the Dynamic Island, from an hour before it starts until it ends. It starts when Calendar is open in that hour.")
            }
            .onChange(of: liveActivitiesEnabled) { _ in
                Task { await AppServices.shared.surfaces.redraw() }
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

            EncryptionSection(flow: $encryptionFlow, revision: encryptionRevision)

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
        .encryptionFlows($encryptionFlow, provisioning: keyProvisioning) { encryptionRevision += 1 }
    }

    private var notificationsFooter: String {
        if !alertsEnabled { return "No reminder will alert on this device." }
        switch notifications.authorization {
        case .denied:
            return "Notifications are off for Calendar, so reminders can't alert. Turn them on in Settings."
        case .notDetermined:
            return "You'll be asked the first time a reminder is coming up."
        default:
            return "Reminders alert on this device at their due time, with Mark as Done and Snooze. "
                + "They are scheduled from what was last synced, so a reminder added elsewhere alerts "
                + "once this device has caught up."
        }
    }
}
