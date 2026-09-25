import SwiftUI

/// A month grid with a dot under each day that has events, and the selected day's events below,
/// as the iPhone's Calendar shows a month. Tap a day to select it; swipe the grid sideways for
/// the next or previous month.
struct MonthView: View {
    @EnvironmentObject var events: EventsService
    @AppStorage(LayoutDensity.storageKey) private var compact = false

    private var calendar: Calendar { events.calendar }

    var body: some View {
        VStack(spacing: 0) {
            grid
                .padding(.horizontal, 8)
                .padding(.bottom, compact ? 4 : 8)
                .contentShape(Rectangle())
                .gesture(swipe)
            Divider()
            dayList
        }
    }

    // MARK: - Grid

    private var grid: some View {
        let days = CalendarGrid.monthDays(events.focus, calendar: calendar)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        return VStack(spacing: 2) {
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(Array(CalendarGrid.weekdaySymbols(calendar: calendar).enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
            }
            LazyVGrid(columns: columns, spacing: compact ? 2 : 6) {
                ForEach(days, id: \.self) { day in
                    MonthDayCell(day: day,
                                 inMonth: calendar.isDate(day, equalTo: events.focus, toGranularity: .month),
                                 isToday: day == events.today,
                                 isSelected: day == events.focus,
                                 eventCount: dots(for: day),
                                 compact: compact)
                        .onTapGesture { events.select(day) }
                }
            }
        }
    }

    /// How many dots to draw: the day's events, up to three. Days of the neighbouring months get
    /// none, since only this month is loaded.
    private func dots(for day: Date) -> Int {
        guard calendar.isDate(day, equalTo: events.focus, toGranularity: .month) else { return 0 }
        return min(events.occurrences(on: day).count, 3)
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    events.move(.month, by: value.translation.width < 0 ? 1 : -1)
                }
            }
    }

    // MARK: - Selected day

    @ViewBuilder
    private var dayList: some View {
        let occurrences = events.occurrences(on: events.focus)
        List {
            if let error = events.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Section {
                if occurrences.isEmpty {
                    Text(events.hasLoaded(events.month) ? "No Events" : "Loading…")
                        .foregroundStyle(.secondary)
                }
                ForEach(occurrences) { occurrence in
                    NavigationLink(value: occurrence) {
                        EventRowView(occurrence: occurrence)
                    }
                    .densityRow()
                }
            } header: {
                DayHeader(day: events.focus)
            }
        }
        .listStyle(.insetGrouped)
        .densityList()
        .refreshable { await events.reload(for: .month) }
    }
}

// MARK: - MonthDayCell

/// One day of the month grid: its number, circled when it is today or selected, and dots for
/// its events.
struct MonthDayCell: View {
    let day: Date
    let inMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let eventCount: Int
    let compact: Bool

    var body: some View {
        VStack(spacing: 3) {
            Text(day.formatted(.dateTime.day()))
                .font(.callout.weight(isToday || isSelected ? .semibold : .regular))
                .foregroundStyle(numberColor)
                .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
                .background {
                    if isSelected {
                        Circle().fill(isToday ? Color.accentColor : Color.primary)
                    }
                }
            HStack(spacing: 3) {
                ForEach(0..<eventCount, id: \.self) { _ in
                    Circle().fill(Color.secondary).frame(width: 5, height: 5)
                }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Selected wins over today, as it does on the iPhone: the number is white on its circle.
    private var numberColor: Color {
        if isSelected { return Color(.systemBackground) }
        if isToday { return .accentColor }
        return inMonth ? .primary : .secondary.opacity(0.6)
    }

    private var accessibilityText: String {
        var parts = [day.formatted(date: .complete, time: .omitted)]
        if isToday { parts.append("Today") }
        if eventCount > 0 { parts.append(eventCount == 3 ? "3 or more events" : "\(eventCount) event\(eventCount == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}
