import Foundation

// MARK: - CalendarMode

/// The five ways the Calendar tab can show time. Remembered per device.
enum CalendarMode: String, CaseIterable, Identifiable {
    case day, week, month, year, agenda

    var id: Self { self }

    static let storageKey = "ncal.calendar.mode"

    var label: String {
        switch self {
        case .day:    return "Day"
        case .week:   return "Week"
        case .month:  return "Month"
        case .year:   return "Year"
        case .agenda: return "Agenda"
        }
    }

    var symbol: String {
        switch self {
        case .day:    return "calendar.day.timeline.left"
        case .week:   return "calendar"
        case .month:  return "square.grid.3x3"
        case .year:   return "square.grid.4x3.fill"
        case .agenda: return "list.bullet"
        }
    }

    /// The step the previous/next arrows take. The agenda is a month, as it is on the web.
    var step: Calendar.Component {
        switch self {
        case .day:            return .day
        case .week:           return .weekOfYear
        case .month, .agenda: return .month
        case .year:           return .year
        }
    }
}

// MARK: - CalendarGrid

/// The dates behind the month, week and year layouts. Pure arithmetic over a `Calendar`, so the
/// first weekday, the zone and DST all come from the calendar passed in.
enum CalendarGrid {

    /// The days of `month` laid out in whole weeks, starting on the calendar's first weekday and
    /// padded with the neighbouring months' days: five or six rows, as the month needs.
    static func monthDays(_ month: Date, calendar: Calendar) -> [Date] {
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month))!
        let dayCount = calendar.range(of: .day, in: .month, for: first)!.count
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let rows = Int((Double(lead + dayCount) / 7).rounded(.up))
        let start = calendar.date(byAdding: .day, value: -lead, to: first)!
        return (0..<(rows * 7)).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }

    /// The seven days of the week containing `date`, from the calendar's first weekday.
    static func weekDays(containing date: Date, calendar: Calendar) -> [Date] {
        let day = calendar.startOfDay(for: date)
        let back = (calendar.component(.weekday, from: day) - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -back, to: day)!
        return (0..<7).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }

    /// The very short weekday symbols ("S", "M", …) in the calendar's order.
    static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// The first of each month containing any of `days`, in order: what has to be loaded to show
    /// them.
    static func months(covering days: [Date], calendar: Calendar) -> [Date] {
        var seen: [Date] = []
        for day in days {
            let month = calendar.date(from: calendar.dateComponents([.year, .month], from: day))!
            if !seen.contains(month) { seen.append(month) }
        }
        return seen
    }
}

// MARK: - TimeGridLayout

/// Where each timed occurrence sits in one day's column of the week or day view.
///
/// Positions are minutes from the day's local midnight, as the web's `getEventDayBounds` works
/// them out: an occurrence is clamped to the day, so one that runs past midnight fills the rest
/// of this column and the top of the next, and a short one is drawn at least `minimumMinutes`
/// tall so it can be read and tapped. Unlike the web, overlapping occurrences sit side by side
/// rather than on top of each other.
enum TimeGridLayout {

    struct Placed: Identifiable, Equatable {
        let occurrence: EventOccurrence
        /// Minutes from the day's start to the top of the block, 0–1440.
        let startMinute: Double
        /// Minutes from the day's start to the bottom of the block, after the minimum height.
        let endMinute: Double
        /// Which of `columns` side-by-side slots this block takes, from 0.
        let column: Int
        let columns: Int

        var id: String { occurrence.id }
    }

    /// The web's minimum: 24 px against a 60 px hour.
    static let minimumMinutes: Double = 24

    /// Every timed occurrence that touches `day`, positioned. All-day occurrences are left out:
    /// they go in the row above the grid.
    static func layout(_ occurrences: [EventOccurrence], on day: Date, calendar: Calendar) -> [Placed] {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let dayLength = dayEnd.timeIntervalSince(dayStart) / 60

        // Clamp to the day, then give short blocks their minimum, without running off the bottom.
        let spans: [(EventOccurrence, Double, Double)] = occurrences
            .filter { !$0.event.allDay && $0.start < dayEnd && $0.end > dayStart }
            .map { occurrence in
                let start = max(occurrence.start, dayStart).timeIntervalSince(dayStart) / 60
                let end = min(occurrence.end, dayEnd).timeIntervalSince(dayStart) / 60
                let shown = min(max(end, start + minimumMinutes), dayLength)
                return (occurrence, min(start, dayLength - minimumMinutes), shown)
            }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                if a.2 != b.2 { return a.2 > b.2 }
                return a.0.event.title.localizedStandardCompare(b.0.event.title) == .orderedAscending
            }

        // Group occurrences that overlap, directly or through a chain, then give each the first
        // column free at its start. Every block in a group shares the group's column count, so
        // their widths line up.
        var placed: [Placed] = []
        var group: [(EventOccurrence, Double, Double, Int)] = []
        var groupEnd = -Double.infinity

        func flush() {
            let columns = (group.map(\.3).max() ?? -1) + 1
            placed += group.map { Placed(occurrence: $0.0, startMinute: $0.1, endMinute: $0.2,
                                         column: $0.3, columns: columns) }
            group = []
        }

        for (occurrence, start, end) in spans {
            if start >= groupEnd { flush(); groupEnd = -.infinity }
            let busy = Set(group.filter { $0.2 > start }.map(\.3))
            let column = (0...).first { !busy.contains($0) }!
            group.append((occurrence, start, end, column))
            groupEnd = max(groupEnd, end)
        }
        flush()
        return placed
    }

    /// The all-day occurrences on `day`, for the row above the grid.
    static func allDay(_ occurrences: [EventOccurrence], on day: Date, calendar: Calendar) -> [EventOccurrence] {
        occurrences
            .filter { $0.event.allDay && EventDayRange($0, calendar: calendar).contains(day: day, calendar: calendar) }
            .sorted { $0.event.title.localizedStandardCompare($1.event.title) == .orderedAscending }
    }

    /// Minutes since the start of `day` for `now`, or `nil` when `now` is another day.
    static func nowMinute(_ now: Date, on day: Date, calendar: Calendar) -> Double? {
        guard calendar.isDate(now, inSameDayAs: day) else { return nil }
        return now.timeIntervalSince(calendar.startOfDay(for: day)) / 60
    }
}
