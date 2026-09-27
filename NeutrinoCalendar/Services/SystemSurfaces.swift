import Combine
import Foundation
import os.log

/// Everything iOS shows of the calendar outside the app: Spotlight, the widgets and the Live
/// Activity. One fetch feeds all three, whenever the calendar changes here or elsewhere
/// (`CalendarSync`), and from background refresh.
///
/// The fetch runs from the first of this month, which the month widget needs, to the end of
/// next month or 30 days out, whichever is later. A change that needs no network (the Focus
/// filter, the week start, the Live Activities switch) redraws from the last fetch.
@MainActor
final class SystemSurfaces {
    let spotlight: SpotlightIndexer
    let widgets: WidgetSnapshotStore
    let liveActivities: LiveActivities

    private let events: EventsService
    /// Checked again after the fetch: a run under way at sign-out must not put the old account's
    /// events back.
    private let isSignedIn: () -> Bool
    /// The last fetch, expanded, for redrawing without the network.
    private var fetched: [EventOccurrence]?
    private var isRunning = false
    private var runAgain = false
    private var cancellables: Set<AnyCancellable> = []

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoCalendar",
                                category: "SystemSurfaces")

    init(events: EventsService, isSignedIn: @escaping () -> Bool,
         spotlight: SpotlightIndexer? = nil, widgets: WidgetSnapshotStore? = nil,
         liveActivities: LiveActivities? = nil) {
        self.events = events
        self.isSignedIn = isSignedIn
        self.spotlight = spotlight ?? SpotlightIndexer()
        self.widgets = widgets ?? WidgetSnapshotStore()
        self.liveActivities = liveActivities ?? LiveActivities()

        events.$sourceFilter.dropFirst().removeDuplicates().map { _ in () }
            .merge(with: events.$weekStart.dropFirst().removeDuplicates().map { _ in () })
            .sink { [weak self] in Task { await self?.redraw() } }
            .store(in: &cancellables)
    }

    /// Fetches and updates everything. A call made while one runs runs again after it, so a
    /// change that lands mid-run is not missed. A failed fetch leaves everything as it was: a
    /// slightly stale widget beats an empty one.
    func refresh() async {
        if isRunning {
            runAgain = true
            return
        }
        isRunning = true
        defer { isRunning = false }
        repeat {
            runAgain = false
            guard isSignedIn() else { return }
            do {
                let range = fetchRange()
                let occurrences = try await events.occurrences(from: range.from, to: range.to)
                guard isSignedIn() else { return }
                fetched = occurrences
                await publish(occurrences, spotlight: true)
            } catch {
                logger.error("refresh failed: \(error, privacy: .public)")
                return
            }
        } while runAgain
    }

    /// Redraws the widgets and the Live Activity from the last fetch.
    func redraw() async {
        guard isSignedIn(), let fetched else { return }
        await publish(fetched, spotlight: false)
    }

    /// Signed out, or never signed in: nothing of an account may be left on show.
    func signOut() async {
        fetched = nil
        widgets.write(.signedOut())
        await liveActivities.endAll()
        await spotlight.removeAll()
    }

    private func fetchRange() -> (from: Date, to: Date) {
        let calendar = events.calendar
        let today = calendar.startOfDay(for: events.currentDate)
        let firstOfMonth = EventsService.firstOfMonth(today, calendar: calendar)
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: firstOfMonth)!
        let endOfNextMonth = EventsService.monthRange(nextMonth, calendar: calendar).to
        let spotlightEnd = calendar.date(byAdding: .day, value: SpotlightIndexer.horizonDays, to: today)!
        return (firstOfMonth, max(endOfNextMonth, spotlightEnd))
    }

    private func publish(_ occurrences: [EventOccurrence], spotlight indexSpotlight: Bool) async {
        let now = events.currentDate
        let calendar = events.calendar
        let filter = events.sourceFilter
        let upcoming = UpNext.upcoming(occurrences, now: now, calendar: calendar)

        widgets.write(WidgetSnapshotStore.build(occurrences, now: now, calendar: calendar, filter: filter))
        await liveActivities.show(LiveActivities.candidate(upcoming, now: now, filter: filter), now: now)
        if indexSpotlight {
            // Spotlight ignores the Focus filter: a search is asked for, not shown unasked.
            let end = calendar.date(byAdding: .day, value: SpotlightIndexer.horizonDays,
                                    to: calendar.startOfDay(for: now))!
            await spotlight.index(upcoming.filter { $0.start < end }, calendar: calendar)
        }
    }
}
