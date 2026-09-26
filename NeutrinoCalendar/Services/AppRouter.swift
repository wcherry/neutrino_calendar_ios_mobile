import Foundation

/// Where the app is showing, for things outside the tab bar that need to move it: a tapped
/// notification opens the Reminders tab on its reminder, and a Spotlight result or a Shortcut
/// opens the Calendar tab on its event.
@MainActor
final class AppRouter: ObservableObject {
    @Published var tab: ContentView.Tab = .calendar
    /// A reminder to open for editing, taken by the Reminders tab once it is showing.
    @Published var openReminderID: String?

    /// An event to open, taken by the Calendar tab once it is showing.
    @Published var openEvent: EventLink?

    func open(reminderID: String) {
        tab = .reminders
        openReminderID = reminderID
    }

    func open(_ event: EventLink) {
        tab = .calendar
        openEvent = event
    }
}
