import SwiftUI

/// Where the app is showing, for things outside the tab bar that need to move it: a tapped
/// notification opens the Reminders tab on its reminder, and a Spotlight result or a Shortcut
/// opens the Calendar tab on its event; an `.ics` file shared to the app opens the new-event form
/// filled in from it.
@MainActor
final class AppRouter: ObservableObject {
    @Published var tab: ContentView.Tab = .calendar
    /// A reminder to open for editing, taken by the Reminders tab once it is showing.
    @Published var openReminderID: String?

    /// A task to open, taken by the Tasks tab once it is showing: a tapped arrival alert.
    @Published var openTaskID: String?
    /// The Tasks tab's navigation, so an opened task replaces whatever task was showing.
    @Published var tasksPath = NavigationPath()

    /// An event to open, taken by the Calendar tab once it is showing.
    @Published var openEvent: EventLink?

    /// An event read from a shared `.ics` file, taken by the Calendar tab and shown in the new
    /// event form. Held here while the sign-in screen is up, so a file opened signed out still
    /// arrives once the calendar shows.
    @Published var importedEvent: EventDraft?

    func open(reminderID: String) {
        tab = .reminders
        openReminderID = reminderID
    }

    func open(taskID: String) {
        tab = .tasks
        openTaskID = taskID
    }

    func open(_ event: EventLink) {
        tab = .calendar
        openEvent = event
    }

    func open(importing draft: EventDraft) {
        tab = .calendar
        importedEvent = draft
    }
}
