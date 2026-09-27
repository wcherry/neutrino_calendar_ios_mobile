import SwiftUI
import WidgetKit

/// The next event, or the one under way: on the Home Screen (small, medium) and the Lock Screen
/// (rectangular, inline, circular). Tapping opens it.
struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UpNext", provider: CalendarProvider()) { entry in
            UpNextView(entry: entry)
        }
        .configurationDisplayName("Up Next")
        .description("Your next event, or the one under way.")
        .supportedFamilies([.systemSmall, .systemMedium,
                            .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

struct UpNextView: View {
    let entry: CalendarEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: WidgetSnapshot? { entry.snapshot?.signedIn == true ? entry.snapshot : nil }
    private var next: WidgetEvent? { snapshot?.next(at: entry.date) }

    var body: some View {
        content
            .widgetURL(next.map { WidgetLink.event($0.id).url })
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryInline:      inline
        case .accessoryCircular:    circular
        case .accessoryRectangular: rectangular
        case .systemMedium:         medium.widgetBackground()
        default:                    small.widgetBackground()
        }
    }

    // MARK: - Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if let snapshot, let next {
                Spacer(minLength: 0)
                Text(next.title)
                    .font(.headline)
                    .lineLimit(3)
                Text(WidgetFormat.time(next, at: entry.date, calendar: snapshot.calendar))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let location = next.location {
                    Label(location, systemImage: "mappin")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Spacer(minLength: 0)
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.date.formatted(.dateTime.weekday(.wide)).uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(WidgetStyle.accent)
                Text(entry.date.formatted(.dateTime.day()))
                    .font(.system(size: 40, weight: .semibold))
                Spacer(minLength: 0)
                if let summary = snapshot?.filterSummary {
                    Label(summary, systemImage: "moon.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(width: 90, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                if let snapshot {
                    let upcoming = Array(snapshot.upcoming(at: entry.date).prefix(3))
                    if upcoming.isEmpty { empty }
                    ForEach(upcoming) { event in
                        Link(destination: WidgetLink.event(event.id).url) {
                            EventLine(event: event, date: entry.date, calendar: snapshot.calendar,
                                      showsLocation: upcoming.count < 3)
                        }
                    }
                    Spacer(minLength: 0)
                } else {
                    WidgetMessage(snapshot: entry.snapshot)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        Label("Up Next", systemImage: "calendar")
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(WidgetStyle.accent)
    }

    @ViewBuilder
    private var empty: some View {
        if snapshot == nil {
            WidgetMessage(snapshot: entry.snapshot)
        } else {
            Text("Nothing coming up")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Lock Screen

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let snapshot, let next {
                Text(next.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(WidgetFormat.time(next, at: entry.date, calendar: snapshot.calendar))
                    .lineLimit(1)
                if let location = next.location {
                    Text(location).lineLimit(1)
                }
            } else {
                Label("Calendar", systemImage: "calendar").font(.headline)
                Text(snapshot == nil ? "Open Calendar" : "Nothing coming up")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetAccentable()
    }

    @ViewBuilder
    private var inline: some View {
        if let next {
            if next.start <= entry.date {
                Text("\(next.title) until \(next.end.formatted(date: .omitted, time: .shortened))")
            } else {
                Text("\(next.start.formatted(date: .omitted, time: .shortened)) \(next.title)")
            }
        } else {
            Label("No upcoming events", systemImage: "calendar")
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "calendar")
                    .font(.caption2)
                if let next {
                    Text(next.start <= entry.date ? next.end : next.start, format: .dateTime.hour().minute())
                        .font(.system(size: 11, weight: .semibold))
                        .minimumScaleFactor(0.6)
                } else {
                    Text("—").font(.caption)
                }
            }
            .padding(4)
        }
        .widgetAccentable()
    }
}
