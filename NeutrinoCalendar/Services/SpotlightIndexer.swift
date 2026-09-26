import CoreSpotlight
import Foundation
import UniformTypeIdentifiers
import os.log

/// Puts the coming weeks' events into Spotlight, so searching the phone for "dentist" finds the
/// appointment, and tapping it opens the event here.
///
/// Each event is indexed once, at its next occurrence, and the whole set is replaced on every
/// run, so an event deleted or moved elsewhere leaves nothing stale behind. It runs when the
/// calendar changes here or elsewhere (`CalendarSync.refresh`, `EventsService.generation`) and
/// from background refresh. The index lives on the device only; iOS's Settings › Calendar ›
/// Siri & Search is where a user turns it off.
@MainActor
final class SpotlightIndexer {
    nonisolated static let domain = "com.neutrino.calendar.events"
    /// How far ahead is indexed. Further out is what the calendar itself is for.
    static let horizonDays = 30

    private let events: EventsService
    private let index: CSSearchableIndex
    /// Checked again after the fetch: a run under way at sign-out must not put the old account's
    /// events back after `removeAll`.
    private let isSignedIn: () -> Bool
    private var isRunning = false
    private var runAgain = false

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoCalendar",
                                category: "SpotlightIndexer")

    init(events: EventsService, index: CSSearchableIndex = .default(), isSignedIn: @escaping () -> Bool) {
        self.events = events
        self.index = index
        self.isSignedIn = isSignedIn
    }

    /// Replaces what is indexed with what is coming up now. A call made while one runs runs
    /// again after it, so a change that lands mid-run is not missed. A failed fetch leaves the
    /// index as it was: stale results beat none.
    func reindex() async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        if isRunning {
            runAgain = true
            return
        }
        isRunning = true
        defer { isRunning = false }
        repeat {
            runAgain = false
            do {
                guard isSignedIn() else { return }
                let upcoming = try await events.upcoming(days: Self.horizonDays)
                guard isSignedIn() else { return }
                let items = Self.items(for: upcoming, calendar: events.calendar)
                try await index.deleteSearchableItems(withDomainIdentifiers: [Self.domain])
                try await index.indexSearchableItems(items)
                logger.debug("indexed \(items.count) event(s)")
            } catch {
                logger.error("reindex failed: \(error, privacy: .public)")
                return
            }
        } while runAgain
    }

    /// For sign-out: the next account must not find this one's events.
    func removeAll() async {
        do {
            try await index.deleteSearchableItems(withDomainIdentifiers: [Self.domain])
        } catch {
            logger.error("remove failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Items

    nonisolated static func items(for upcoming: [EventOccurrence], calendar: Calendar) -> [CSSearchableItem] {
        UpNext.firstOfEach(upcoming).map { item(for: $0, calendar: calendar) }
    }

    nonisolated static func item(for occurrence: EventOccurrence, calendar: Calendar) -> CSSearchableItem {
        let event = occurrence.event
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = event.title
        attributes.contentDescription = description(of: occurrence, calendar: calendar)
        attributes.startDate = occurrence.start
        attributes.endDate = occurrence.end
        attributes.allDay = NSNumber(value: event.allDay)
        if let location = event.location, !location.isEmpty { attributes.namedLocation = location }
        if let badge = event.source.badge { attributes.keywords = [badge] }

        let item = CSSearchableItem(uniqueIdentifier: EventLink(occurrence).string,
                                    domainIdentifier: domain, attributeSet: attributes)
        // Gone from Spotlight once it is over, even if nothing runs to take it out.
        item.expirationDate = occurrence.event.allDay
            ? calendar.date(byAdding: .day, value: 1, to: EventDayRange(occurrence, calendar: calendar).last)
            : occurrence.end
        return item
    }

    /// "Thu, Oct 1 · 9:00 AM – 10:00 AM · Room 4". The notes are left out: a search result is
    /// visible on the Lock Screen's search, and a title and a time are what finds an event.
    nonisolated static func description(of occurrence: EventOccurrence, calendar: Calendar) -> String {
        let first = EventDayRange(occurrence, calendar: calendar).first
        let day = first.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.abbreviated).month(.abbreviated).day())
        var parts = [day, EventFormatting.timeSummary(occurrence, timeZone: calendar.timeZone)]
        if let location = occurrence.event.location?.trimmingCharacters(in: .whitespacesAndNewlines),
           !location.isEmpty {
            parts.append(location)
        }
        return parts.joined(separator: " · ")
    }
}
