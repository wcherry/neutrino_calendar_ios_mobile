import AppIntents
import Foundation

// Siri and Shortcuts: "What's next", "Add event" and "Add reminder", plus an event entity that
// Shortcuts can pass along and open. They run in the app's process, usually with no scene, and
// use the same services as the app (`AppServices`), so what they add shows up at once and a
// new reminder's alert is planned straight away.

// MARK: - Errors

enum CalendarIntentError: Error, CustomLocalizedStringResourceConvertible {
    case signedOut
    case invalid(String)
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut:            return "Open Calendar and sign in to Neutrino first."
        case .invalid(let message): return LocalizedStringResource(stringLiteral: message)
        case .failed(let message):  return LocalizedStringResource(stringLiteral: "Couldn't reach Neutrino. \(message)")
        }
    }
}

@MainActor
enum IntentSupport {
    /// The app's services, once signed in.
    static func services() throws -> AppServices {
        let services = AppServices.shared
        guard services.auth.isAuthenticated else { throw CalendarIntentError.signedOut }
        return services
    }

    /// Runs a request, turning a failure into something Siri can say.
    static func reaching<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as CalendarIntentError {
            throw error
        } catch {
            throw CalendarIntentError.failed(error.localizedDescription)
        }
    }
}

// MARK: - EventEntity

/// One occurrence of an event, for Shortcuts. Its id is an `EventLink`, so a repeating event
/// keeps the occurrence that was found.
struct EventEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Event"
    static var defaultQuery = EventQuery()

    let id: String
    @Property(title: "Title") var title: String
    @Property(title: "Start") var start: Date
    @Property(title: "End") var end: Date
    @Property(title: "All Day") var isAllDay: Bool
    @Property(title: "Location") var location: String?
    private let when: String

    init(_ occurrence: EventOccurrence, calendar: Calendar) {
        id = EventLink(occurrence).string
        when = SpotlightIndexer.description(of: occurrence, calendar: calendar)
        title = occurrence.event.title
        start = occurrence.start
        end = occurrence.end
        isAllDay = occurrence.event.allDay
        location = occurrence.event.location
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(when)", image: .init(systemName: "calendar"))
    }
}

struct EventQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [EventEntity] {
        try await Self.lookUp(identifiers)
    }

    /// The coming week's events the Focus filter shows, for picking one in Shortcuts.
    func suggestedEntities() async throws -> [EventEntity] {
        try await Self.suggested()
    }

    @MainActor
    private static func lookUp(_ identifiers: [String]) async throws -> [EventEntity] {
        let services = try IntentSupport.services()
        var found: [EventEntity] = []
        for identifier in identifiers {
            // One deleted since is left out, not an error for the rest.
            guard let link = EventLink(string: identifier),
                  let event = try? await services.events.event(id: link.eventID) else { continue }
            found.append(EventEntity(link.occurrence(of: event), calendar: services.events.calendar))
        }
        return found
    }

    @MainActor
    private static func suggested() async throws -> [EventEntity] {
        let services = try IntentSupport.services()
        let events = services.events
        let upcoming = try await IntentSupport.reaching { try await events.upcoming(days: 7) }
        return upcoming
            .filter { events.sourceFilter.shows($0.event.source) }
            .prefix(20)
            .map { EventEntity($0, calendar: events.calendar) }
    }
}

// MARK: - What's Next

struct WhatsNextIntent: AppIntent {
    static var title: LocalizedStringResource = "What's Next"
    static var description = IntentDescription(
        "Tells you your next event, or the one under way. All-day events are left out, and so are calendars a Focus is hiding.")

    /// How far ahead to look.
    static let days = 7

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<EventEntity?> & ProvidesDialog {
        let services = try IntentSupport.services()
        let events = services.events
        let upcoming = try await IntentSupport.reaching { try await events.upcoming(days: Self.days) }
        let next = UpNext.next(upcoming, filter: events.sourceFilter)
        let sentence = UpNext.sentence(for: next, now: Date(), calendar: events.calendar, days: Self.days)
        return .result(value: next.map { EventEntity($0, calendar: events.calendar) },
                       dialog: "\(sentence)")
    }
}

// MARK: - Open Event

struct OpenEventIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open Event"
    static var description = IntentDescription("Opens an event in Calendar.")

    @Parameter(title: "Event")
    var target: EventEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        if let link = EventLink(string: target.id) { AppServices.shared.router.open(link) }
        return .result()
    }
}

// MARK: - Add Event

struct AddEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Event"
    static var description = IntentDescription("Adds an event to your Neutrino calendar.")

    @Parameter(title: "Title", requestValueDialog: "What's the event called?")
    var title: String

    @Parameter(title: "Start", requestValueDialog: "When does it start?")
    var start: Date

    @Parameter(title: "End", description: "An hour after the start when left empty.")
    var end: Date?

    @Parameter(title: "All Day", default: false)
    var allDay: Bool

    @Parameter(title: "Location")
    var location: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$title) at \(\.$start)") {
            \.$end
            \.$allDay
            \.$location
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<EventEntity> & ProvidesDialog {
        let services = try IntentSupport.services()
        let events = services.events
        let draft = EventDraft(title: title, start: start, end: end, allDay: allDay, location: location,
                               calendar: events.calendar)
        if let problem = draft.problem { throw CalendarIntentError.invalid(problem) }
        let created = try await IntentSupport.reaching { try await events.create(draft) }
        let occurrence = EventOccurrence(event: created, start: created.start, end: created.end)
        let sentence = UpNext.added(occurrence, now: Date(), calendar: events.calendar)
        return .result(value: EventEntity(occurrence, calendar: events.calendar), dialog: "\(sentence)")
    }
}

// MARK: - Add Reminder

struct AddReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Reminder"
    static var description = IntentDescription("Adds a reminder to Neutrino, alerting on this device when it's due.")

    @Parameter(title: "Title", requestValueDialog: "What should I remind you about?")
    var title: String

    @Parameter(title: "Due", requestValueDialog: "When should I remind you?")
    var due: Date

    static var parameterSummary: some ParameterSummary {
        Summary("Remind me about \(\.$title) at \(\.$due)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = try IntentSupport.services()
        let reminders = services.reminders
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CalendarIntentError.invalid("A reminder needs a title.") }
        _ = try await IntentSupport.reaching { try await reminders.create(title: trimmed, due: due, rule: nil) }

        // Plans the alert now: with no scene there is nothing watching the list to do it. The
        // whole list is needed for that, and a plan made from part of it would drop the rest.
        if !reminders.hasLoaded { await reminders.reload() }
        if reminders.hasLoaded { await services.notifications.apply(reminders.reminders) }

        let sentence = UpNext.willRemind(trimmed, due: due, now: Date(), calendar: services.events.calendar)
        return .result(dialog: "\(sentence)")
    }
}

// MARK: - App Shortcuts

/// The phrases Siri knows without any setup. "Calendar" is also Apple's app's name, so the
/// phrases work with "Neutrino" and "Neutrino Calendar" too (`INAlternativeAppNames`).
struct CalendarShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WhatsNextIntent(), phrases: [
            "What's next in \(.applicationName)",
            "What's next on \(.applicationName)",
            "What's my next event in \(.applicationName)",
        ], shortTitle: "What's Next", systemImageName: "calendar.badge.clock")
        AppShortcut(intent: AddEventIntent(), phrases: [
            "Add an event in \(.applicationName)",
            "Add an event to \(.applicationName)",
            "New \(.applicationName) event",
        ], shortTitle: "Add Event", systemImageName: "calendar.badge.plus")
        AppShortcut(intent: AddReminderIntent(), phrases: [
            "Add a reminder in \(.applicationName)",
            "Add a reminder to \(.applicationName)",
            "Remind me in \(.applicationName)",
        ], shortTitle: "Add Reminder", systemImageName: "bell.badge")
    }
}
