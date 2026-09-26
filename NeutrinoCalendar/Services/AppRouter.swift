import Foundation

/// Where the app is showing, for things outside the tab bar that need to move it: a tapped
/// notification opens the Reminders tab on its reminder.
@MainActor
final class AppRouter: ObservableObject {
    @Published var tab: ContentView.Tab = .calendar
    /// A reminder to open for editing, taken by the Reminders tab once it is showing.
    @Published var openReminderID: String?

    func open(reminderID: String) {
        tab = .reminders
        openReminderID = reminderID
    }
}
