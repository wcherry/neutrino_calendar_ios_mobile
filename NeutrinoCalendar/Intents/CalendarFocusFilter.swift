import AppIntents
import Foundation

extension CalendarSource: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Calendar"
    static var caseDisplayRepresentations: [CalendarSource: DisplayRepresentation] = [
        .neutrino: "Neutrino",
        .google: "Google",
        .outlook: "Outlook",
        .icloud: "iCloud",
    ]
}

/// A Focus filter (Settings › Focus › a Focus › Add Filter › Calendar): while the Focus is on,
/// the calendar and "What's next" show only the chosen calendars. iOS runs this when the Focus
/// turns on, and again with nothing chosen when it turns off, which clears the filter.
struct CalendarFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Set Calendar Filter"
    static var description = IntentDescription("Shows only the calendars you choose while this Focus is on.")

    @Parameter(title: "Show Calendars")
    var calendars: [CalendarSource]?

    private var filter: SourceFilter { SourceFilter(shown: calendars.map(Set.init)) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(filter.summary ?? "All calendars")")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        filter.save()
        AppServices.shared.events.setSourceFilter(filter)
        return .result()
    }
}
