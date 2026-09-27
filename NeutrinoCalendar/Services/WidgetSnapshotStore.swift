import Foundation
import WidgetKit
import os.log

/// Writes the widgets' snapshot (`WidgetSnapshot`) into the App Group container and asks
/// WidgetKit to redraw, only when what the widgets would show has changed: iOS budgets widget
/// reloads, and a sync that changed nothing shouldn't spend one.
@MainActor
final class WidgetSnapshotStore {
    private let url: URL?
    private let reload: () -> Void
    /// What was last written, with `generatedAt` cleared so an unchanged calendar compares equal.
    private var last: WidgetSnapshot?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoCalendar",
                                category: "WidgetSnapshotStore")

    init(url: URL? = WidgetSnapshot.fileURL,
         reload: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }) {
        self.url = url
        self.reload = reload
        last = WidgetSnapshot.load(from: url).map(Self.comparable)
    }

    func write(_ snapshot: WidgetSnapshot) {
        guard let url else {
            logger.error("no App Group container; widgets can't be updated")
            return
        }
        let comparable = Self.comparable(snapshot)
        guard comparable != last else { return }
        do {
            // Readable while the phone is locked, which is when Lock Screen widgets draw.
            try snapshot.encoded().write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            last = comparable
            reload()
        } catch {
            logger.error("write failed: \(error, privacy: .public)")
        }
    }

    private static func comparable(_ snapshot: WidgetSnapshot) -> WidgetSnapshot {
        var copy = snapshot
        copy.generatedAt = .distantPast
        return copy
    }

    // MARK: - Building

    /// The snapshot for `occurrences`, fetched from the first of this month: what the Focus
    /// filter shows, from the start of today for `WidgetSnapshot.horizonDays`, plus the busy days
    /// of this month and next.
    static func build(_ occurrences: [EventOccurrence], now: Date, calendar: Calendar,
                      filter: SourceFilter, limit: Int = 100) -> WidgetSnapshot {
        let shown = occurrences.filter { filter.shows($0.event.source) }
        let today = calendar.startOfDay(for: now)
        let horizon = calendar.date(byAdding: .day, value: WidgetSnapshot.horizonDays, to: today)!

        // Everything not over by the start of today: the Today widget lists the morning's
        // events too, and each widget drops what is over at its own entry's time.
        let events = UpNext.upcoming(shown, now: today, calendar: calendar)
            .map { ($0, EventDayRange($0, calendar: calendar)) }
            .filter { $0.1.first < horizon }
            .prefix(limit)
            .map { occurrence, range in
                WidgetEvent(id: EventLink(occurrence).string, title: occurrence.event.title,
                            start: occurrence.start, end: occurrence.end, allDay: occurrence.event.allDay,
                            firstDay: WidgetSnapshot.dayKey(range.first, calendar: calendar),
                            lastDay: WidgetSnapshot.dayKey(range.last, calendar: calendar),
                            location: occurrence.event.location.flatMap { $0.isEmpty ? nil : $0 })
            }

        let firstOfMonth = EventsService.firstOfMonth(today, calendar: calendar)
        let afterNextMonth = calendar.date(byAdding: .month, value: 2, to: firstOfMonth)!
        var busy = Set<String>()
        for occurrence in shown {
            let range = EventDayRange(occurrence, calendar: calendar)
            var day = max(range.first, firstOfMonth)
            while day <= range.last && day < afterNextMonth {
                busy.insert(WidgetSnapshot.dayKey(day, calendar: calendar))
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            }
        }

        return WidgetSnapshot(signedIn: true, generatedAt: now, timeZone: calendar.timeZone.identifier,
                              firstWeekday: calendar.firstWeekday, events: Array(events), busyDays: busy,
                              filterSummary: filter.summary)
    }
}
