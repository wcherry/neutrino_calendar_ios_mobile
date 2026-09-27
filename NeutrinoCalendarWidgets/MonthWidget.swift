import SwiftUI
import WidgetKit

/// This month as a grid, today ringed and busy days dotted. The medium size adds what's next.
struct MonthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Month", provider: CalendarProvider()) { entry in
            MonthWidgetView(entry: entry)
                .widgetBackground()
        }
        .configurationDisplayName("Month")
        .description("This month at a glance, with the days that have events marked.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct MonthWidgetView: View {
    let entry: CalendarEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let snapshot = entry.snapshot?.signedIn == true ? entry.snapshot : nil
        let calendar = snapshot?.calendar ?? .current
        HStack(alignment: .top, spacing: 12) {
            MonthGrid(date: entry.date, calendar: calendar, busyDays: snapshot?.busyDays ?? [],
                      linksDays: family != .systemSmall)
            if family == .systemMedium {
                VStack(alignment: .leading, spacing: 6) {
                    if let snapshot {
                        let upcoming = Array(snapshot.upcoming(at: entry.date).prefix(3))
                        if upcoming.isEmpty {
                            Text("Nothing coming up").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(upcoming) { event in
                            Link(destination: WidgetLink.event(event.id).url) {
                                EventLine(event: event, date: entry.date, calendar: calendar)
                            }
                        }
                    } else {
                        WidgetMessage(snapshot: entry.snapshot)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .widgetURL(WidgetLink.day(WidgetSnapshot.dayKey(entry.date, calendar: calendar)).url)
    }
}

struct MonthGrid: View {
    let date: Date
    let calendar: Calendar
    let busyDays: Set<String>
    /// Each day a link to itself; only medium and large widgets can have links.
    let linksDays: Bool

    var body: some View {
        let today = WidgetSnapshot.dayKey(date, calendar: calendar)
        VStack(alignment: .leading, spacing: 3) {
            Text(date.formatted(Date.FormatStyle(timeZone: calendar.timeZone).month(.wide)).uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(WidgetStyle.accent)
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    ForEach(Array(Self.weekdaySymbols(calendar).enumerated()), id: \.offset) { _, symbol in
                        Text(symbol)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(Array(Self.weeks(of: date, calendar: calendar).enumerated()), id: \.offset) { _, week in
                    GridRow {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            if let day {
                                cell(day, today: today)
                            } else {
                                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ day: Date, today: String) -> some View {
        let key = WidgetSnapshot.dayKey(day, calendar: calendar)
        let label = VStack(spacing: 0) {
            Text(day.formatted(Date.FormatStyle(timeZone: calendar.timeZone).day()))
                .font(.system(size: 10, weight: key == today ? .bold : .regular))
                .foregroundStyle(key == today ? Color.white : (key < today ? Color.secondary : Color.primary))
                .frame(width: 16, height: 16)
                .background(Circle().fill(key == today ? WidgetStyle.accent : .clear))
            Circle()
                .fill(busyDays.contains(key) && key != today ? WidgetStyle.accent : .clear)
                .frame(width: 3, height: 3)
        }
        .frame(maxWidth: .infinity)
        if linksDays {
            Link(destination: WidgetLink.day(key).url) { label }
        } else {
            label
        }
    }

    /// One-letter weekday names, starting on the calendar's first weekday.
    static func weekdaySymbols(_ calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// The month's days in weeks, with `nil` before the 1st and after the last.
    static func weeks(of date: Date, calendar: Calendar) -> [[Date?]] {
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
        let count = calendar.range(of: .day, in: .month, for: first)!.count
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: lead)
        cells += (0..<count).map { calendar.date(byAdding: .day, value: $0, to: first) }
        cells += Array(repeating: nil, count: (7 - cells.count % 7) % 7)
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }
}
