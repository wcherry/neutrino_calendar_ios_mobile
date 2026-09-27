import SwiftUI
import WidgetKit

/// Today's events, all-day first, those already over dimmed.
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Today", provider: CalendarProvider()) { entry in
            TodayView(entry: entry)
                .widgetBackground()
        }
        .configurationDisplayName("Today")
        .description("Everything on your calendar today.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct TodayView: View {
    let entry: CalendarEntry
    @Environment(\.widgetFamily) private var family

    private var capacity: Int { family == .systemLarge ? 8 : 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.date.formatted(.dateTime.weekday(.wide)))
                    .font(.headline)
                    .foregroundStyle(WidgetStyle.accent)
                Text(entry.date.formatted(.dateTime.month(.wide).day()))
                    .font(.headline)
                Spacer()
                if entry.snapshot?.filterSummary != nil {
                    Image(systemName: "moon.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Focus filter on")
                }
            }

            if let snapshot = entry.snapshot, snapshot.signedIn {
                let events = snapshot.events(on: entry.date)
                if events.isEmpty {
                    Spacer()
                    Text("Nothing on your calendar today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ForEach(shown(events)) { event in
                        Link(destination: WidgetLink.event(event.id).url) {
                            EventLine(event: event, date: entry.date, calendar: snapshot.calendar,
                                      showsLocation: family == .systemLarge)
                        }
                    }
                    if events.count > capacity {
                        Text("+\(events.count - capacity) more")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                WidgetMessage(snapshot: entry.snapshot)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(entry.snapshot.map { WidgetLink.day(WidgetSnapshot.dayKey(entry.date, calendar: $0.calendar)).url })
    }

    /// Those still to come before those already over, so a busy morning doesn't push the
    /// afternoon out of a small widget.
    private func shown(_ events: [WidgetEvent]) -> [WidgetEvent] {
        guard events.count > capacity else { return events }
        let over = { (e: WidgetEvent) in !e.allDay && e.end <= entry.date }
        return Array((events.filter { !over($0) } + events.filter(over)).prefix(capacity))
            .sorted { a, b in a.allDay != b.allDay ? a.allDay : a.start < b.start }
    }
}
