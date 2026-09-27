import ActivityKit
import SwiftUI
import WidgetKit

/// The next event on the Lock Screen and in the Dynamic Island: a countdown to its start, then
/// the time left. The app starts and ends it (`LiveActivities`); the timers here run on their own
/// in between.
struct EventLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: EventActivityAttributes.self) { context in
            LockScreenActivityView(state: context.state, phase: phase(context))
                .padding()
                .activityBackgroundTint(Color(.systemBackground).opacity(0.85))
                .widgetURL(WidgetLink.event(context.attributes.eventLink).url)
        } dynamicIsland: { context in
            let phase = phase(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Calendar", systemImage: "calendar")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(WidgetStyle.accent)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityTimer(state: context.state, phase: phase)
                        .font(.headline.monospacedDigit())
                        .frame(maxWidth: 80, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityDetails(state: context.state, phase: phase)
                }
            } compactLeading: {
                Image(systemName: "calendar")
                    .foregroundStyle(WidgetStyle.accent)
            } compactTrailing: {
                ActivityTimer(state: context.state, phase: phase)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "calendar")
                    .foregroundStyle(WidgetStyle.accent)
            }
            .widgetURL(WidgetLink.event(context.attributes.eventLink).url)
            .keylineTint(WidgetStyle.accent)
        }
    }

    private func phase(_ context: ActivityViewContext<EventActivityAttributes>) -> EventActivityAttributes.Phase {
        EventActivityAttributes.phase(context.state, isStale: context.isStale)
    }
}

/// Counts down to the start, then to the end.
struct ActivityTimer: View {
    let state: EventActivityAttributes.ContentState
    let phase: EventActivityAttributes.Phase

    var body: some View {
        switch phase {
        case .upcoming:
            Text(timerInterval: Date()...max(state.start, Date()), countsDown: true)
                .multilineTextAlignment(.trailing)
        case .inProgress:
            Text(timerInterval: min(state.start, state.end)...state.end, countsDown: true)
                .multilineTextAlignment(.trailing)
        case .ended:
            Text("Ended")
        }
    }
}

struct ActivityDetails: View {
    let state: EventActivityAttributes.ContentState
    let phase: EventActivityAttributes.Phase

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WidgetStyle.accent)
                Spacer()
                Text("\(state.start.formatted(date: .omitted, time: .shortened)) – \(state.end.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if phase != .upcoming, state.start < state.end {
                ProgressView(timerInterval: state.start...state.end, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .tint(WidgetStyle.accent)
            }
            if let location = state.location {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var label: String {
        switch phase {
        case .upcoming:   return "Starts soon"
        case .inProgress: return "Now"
        case .ended:      return "Ended"
        }
    }
}

struct LockScreenActivityView: View {
    let state: EventActivityAttributes.ContentState
    let phase: EventActivityAttributes.Phase

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(state.title, systemImage: "calendar")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                ActivityTimer(state: state, phase: phase)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(WidgetStyle.accent)
                    .frame(maxWidth: 90, alignment: .trailing)
            }
            ActivityDetails(state: state, phase: phase)
        }
    }
}
