import ActivityKit
import Foundation

// Compiled into both the app, which starts, updates and ends the activity, and the widget
// extension, which draws it. See project.yml.

/// The Live Activity for the next event: a countdown to its start, then its progress until it
/// ends, on the Lock Screen and in the Dynamic Island.
///
/// There is no push, so nothing can update the activity at the moment the event starts. Instead
/// each update carries a stale date, the next moment the picture changes, and iOS redraws the
/// activity then with `isStale` set: an upcoming event that has gone stale has started, and one
/// under way that has gone stale has ended. See `phase(_:isStale:)`.
@available(iOS 16.2, *)
struct EventActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var start: Date
        var end: Date
        var location: String?
        /// Whether the event had started when this state was sent.
        var hadStarted: Bool
    }

    /// The occurrence, as an `EventLink` string: what a tap opens, and how the app tells
    /// whether the activity already on screen is for the event it wants to show.
    var eventLink: String

    enum Phase: Equatable {
        case upcoming, inProgress, ended
    }

    static func phase(_ state: ContentState, isStale: Bool) -> Phase {
        switch (state.hadStarted, isStale) {
        case (false, false): return .upcoming
        case (false, true):  return .inProgress
        case (true, false):  return .inProgress
        case (true, true):   return .ended
        }
    }

    /// When the picture next changes: the start for an event yet to start, the end otherwise.
    static func staleDate(_ state: ContentState) -> Date {
        state.hadStarted ? state.end : state.start
    }
}
