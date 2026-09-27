import ActivityKit
import Foundation
import os.log

/// Keeps one Live Activity going for the next event, from an hour before it starts until it
/// ends, and none otherwise.
///
/// iOS only lets an app *start* an activity while it is in the foreground, and without push only
/// the app can change one, so: it is started when the app is open within the hour before an
/// event, and updated or ended whenever the app next runs, background refresh included. In
/// between, the activity's own timers and stale date carry it from countdown to progress (see
/// `EventActivityAttributes`).
@MainActor
final class LiveActivities {
    /// The Settings switch. On by default; iOS's own per-app switch overrides it.
    static let enabledKey = "ncal.liveActivities.enabled"
    /// How long before an event its activity starts.
    static let leadTime: TimeInterval = 60 * 60

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoCalendar",
                                category: "LiveActivities")

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// The occurrence to show: the next timed one the Focus filter shows, if it is under way or
    /// starts within `leadTime`. Anything in `upcoming` already over by `now` is skipped.
    static func candidate(_ upcoming: [EventOccurrence], now: Date, filter: SourceFilter) -> EventOccurrence? {
        guard let next = UpNext.next(upcoming.filter { $0.end > now }, filter: filter),
              next.start <= now.addingTimeInterval(leadTime) else { return nil }
        return next
    }

    /// Shows `occurrence`, or nothing when it is `nil` or the switch is off.
    func show(_ occurrence: EventOccurrence?, now: Date) async {
        guard #available(iOS 16.2, *) else { return }
        let wanted = isEnabled && ActivityAuthorizationInfo().areActivitiesEnabled ? occurrence : nil
        await apply(wanted, now: now)
    }

    func endAll() async {
        guard #available(iOS 16.2, *) else { return }
        for activity in Activity<EventActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    @available(iOS 16.2, *)
    private func apply(_ occurrence: EventOccurrence?, now: Date) async {
        let link = occurrence.map { EventLink($0).string }
        for activity in Activity<EventActivityAttributes>.activities
        where activity.attributes.eventLink != link || activity.activityState != .active {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        guard let occurrence, let link else { return }

        let state = Self.state(for: occurrence, now: now)
        let content = ActivityContent(state: state, staleDate: EventActivityAttributes.staleDate(state))
        if let current = Activity<EventActivityAttributes>.activities.first(where: {
            $0.attributes.eventLink == link && $0.activityState == .active
        }) {
            if current.content.state != state { await current.update(content) }
            return
        }
        do {
            _ = try Activity.request(attributes: EventActivityAttributes(eventLink: link), content: content,
                                     pushType: nil)
            logger.debug("started a Live Activity")
        } catch {
            // Expected from the background, where iOS refuses to start one.
            logger.debug("couldn't start a Live Activity: \(error, privacy: .public)")
        }
    }

    @available(iOS 16.2, *)
    static func state(for occurrence: EventOccurrence, now: Date) -> EventActivityAttributes.ContentState {
        let location = occurrence.event.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        return EventActivityAttributes.ContentState(
            title: occurrence.event.title, start: occurrence.start, end: occurrence.end,
            location: location?.isEmpty == false ? location : nil, hadStarted: occurrence.start <= now)
    }
}
