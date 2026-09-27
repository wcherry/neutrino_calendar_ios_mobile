import CoreSpotlight
import Foundation
import UniformTypeIdentifiers
import os.log

/// Puts the coming weeks' events into Spotlight, so searching the phone for "dentist" finds the
/// appointment, and tapping it opens the event here.
///
/// Each event is indexed once, at its next occurrence, and the whole set is replaced each time,
/// so an event deleted or moved elsewhere leaves nothing stale behind. `SystemSurfaces` hands it
/// what is coming up whenever the calendar changes. The index lives on the device only; iOS's
/// Settings › Calendar › Siri & Search is where a user turns it off.
@MainActor
final class SpotlightIndexer {
    nonisolated static let domain = "com.neutrino.calendar.events"
    /// How far ahead is indexed. Further out is what the calendar itself is for.
    static let horizonDays = 30

    private let index: CSSearchableIndex

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoCalendar",
                                category: "SpotlightIndexer")

    init(index: CSSearchableIndex = .default()) {
        self.index = index
    }

    /// Replaces what is indexed with `upcoming`.
    func index(_ upcoming: [EventOccurrence], calendar: Calendar) async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let items = Self.items(for: upcoming, calendar: calendar)
        do {
            try await index.deleteSearchableItems(withDomainIdentifiers: [Self.domain])
            try await index.indexSearchableItems(items)
            logger.debug("indexed \(items.count) event(s)")
        } catch {
            logger.error("index failed: \(error, privacy: .public)")
        }
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
