import SwiftUI

/// Days as columns over a 24-hour grid: seven for the week view, one for the day view.
///
/// Timed events are blocks placed by `TimeGridLayout`; all-day ones sit in a row above the grid.
/// Hours outside 08:00–20:00 are dimmed, as on the web, and the grid opens at 08:00, or an hour
/// before now on a day that includes today. Today's column carries a line at the current time.
struct TimeGridView: View {
    @EnvironmentObject var events: EventsService
    @AppStorage(LayoutDensity.storageKey) private var compact = false

    let days: [Date]
    /// Called when a day's header is tapped in the week view, to open that day.
    let onSelectDay: ((Date) -> Void)?

    /// The web's working day, drawn at full strength.
    static let dayStartHour = 8
    static let dayEndHour = 20

    private var hourHeight: CGFloat { compact ? 44 : 56 }
    private let gutter: CGFloat = 44
    private var calendar: Calendar { events.calendar }

    var body: some View {
        VStack(spacing: 0) {
            if days.count > 1 { header }
            allDayRow
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    grid
                }
                .onAppear { scrollToStart(proxy) }
            }
            // A fresh scroll view per day or week, so moving to another one opens it at its own
            // starting hour. Scrolling the same view on change of `days` did not take effect.
            .id(days.first)
            .refreshable { await events.reload(for: days.count > 1 ? .week : .day) }
        }
    }

    // MARK: - Header and all-day row

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            ForEach(days, id: \.self) { day in
                let isToday = day == events.today
                Button { onSelectDay?(day) } label: {
                    VStack(spacing: 2) {
                        Text(day.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(day.formatted(.dateTime.day()))
                            .font(.subheadline.weight(isToday ? .bold : .regular))
                            .foregroundStyle(isToday ? Color(.systemBackground) : .primary)
                            .frame(width: 28, height: 28)
                            .background { if isToday { Circle().fill(Color.accentColor) } }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var allDayRow: some View {
        let perDay = days.map { TimeGridLayout.allDay(events.occurrences(on: $0), on: $0, calendar: calendar) }
        if perDay.contains(where: { !$0.isEmpty }) {
            HStack(alignment: .top, spacing: 0) {
                Text("all-day")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: gutter, alignment: .trailing)
                    .padding(.trailing, 4)
                ForEach(Array(zip(days, perDay)), id: \.0) { _, occurrences in
                    VStack(spacing: 2) {
                        ForEach(occurrences.prefix(2)) { occurrence in
                            NavigationLink(value: occurrence) {
                                Text(occurrence.event.title)
                                    .font(.caption2.weight(.medium))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                        }
                        if occurrences.count > 2 {
                            Text("+\(occurrences.count - 2)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 1)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Grid

    private var grid: some View {
        HStack(alignment: .top, spacing: 0) {
            hourLabels
            ForEach(days, id: \.self) { day in
                DayColumn(day: day,
                          placed: TimeGridLayout.layout(events.occurrences(on: day), on: day, calendar: calendar),
                          hourHeight: hourHeight,
                          calendar: calendar,
                          showsTime: days.count == 1)
            }
        }
        .frame(height: hourHeight * 24)
        .background(alignment: .topLeading) { hourLines }
    }

    /// The hour labels, each also a scroll target for opening the grid at a given hour.
    private var hourLabels: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(hour == 0 ? "" : Self.hourLabel(hour, calendar: calendar))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: gutter - 6, height: hourHeight, alignment: .topTrailing)
                    .offset(y: -6)
                    .id(hour)
            }
        }
        .padding(.trailing, 6)
    }

    private var hourLines: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                let dimmed = hour < Self.dayStartHour || hour >= Self.dayEndHour
                VStack(spacing: 0) {
                    Divider()
                    Spacer(minLength: 0)
                }
                .frame(height: hourHeight)
                .background(dimmed ? Color.secondary.opacity(0.06) : Color.clear)
            }
        }
        .padding(.leading, gutter)
    }

    static func hourLabel(_ hour: Int, calendar: Calendar) -> String {
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
        return date.formatted(.dateTime.hour())
    }

    /// An hour before now on a view that includes today, so the current time is near the top;
    /// the start of the working day otherwise.
    private func scrollToStart(_ proxy: ScrollViewProxy) {
        var hour = Self.dayStartHour
        if days.contains(events.today) {
            hour = max(0, calendar.component(.hour, from: Date()) - 1)
        }
        proxy.scrollTo(min(hour, 23), anchor: .top)
    }
}

// MARK: - DayColumn

private struct DayColumn: View {
    let day: Date
    let placed: [TimeGridLayout.Placed]
    let hourHeight: CGFloat
    let calendar: Calendar
    let showsTime: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.clear)
                ForEach(placed) { block in
                    let columnWidth = width / CGFloat(block.columns)
                    NavigationLink(value: block.occurrence) {
                        EventBlock(occurrence: block.occurrence,
                                   height: height(block),
                                   showsTime: showsTime)
                    }
                    .buttonStyle(.plain)
                    .frame(width: max(columnWidth - 2, 1), height: height(block))
                    .offset(x: columnWidth * CGFloat(block.column) + 1,
                            y: CGFloat(block.startMinute) / 60 * hourHeight)
                }
                NowLine(day: day, hourHeight: hourHeight, calendar: calendar)
            }
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: 0.5)
        }
    }

    private func height(_ block: TimeGridLayout.Placed) -> CGFloat {
        CGFloat(block.endMinute - block.startMinute) / 60 * hourHeight - 1
    }
}

// MARK: - EventBlock

private struct EventBlock: View {
    let occurrence: EventOccurrence
    let height: CGFloat
    let showsTime: Bool

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color.accentColor).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(occurrence.event.title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(height > 40 ? 2 : 1)
                if showsTime && height > 30 {
                    Text(EventFormatting.timeSummary(occurrence))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.accentColor.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - NowLine

/// A red line at the current time across today's column, moved once a minute.
private struct NowLine: View {
    let day: Date
    let hourHeight: CGFloat
    let calendar: Calendar

    var body: some View {
        TimelineView(.everyMinute) { context in
            if let minute = TimeGridLayout.nowMinute(context.date, on: day, calendar: calendar) {
                HStack(spacing: 0) {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                    Rectangle().fill(Color.red).frame(height: 1.5)
                }
                .offset(x: -3.5, y: CGFloat(minute) / 60 * hourHeight - 3.5)
                .accessibilityHidden(true)
            }
        }
    }
}
