import SwiftUI

/// The focused year as twelve small months, as the iPhone's Calendar shows a year. Tap a month to
/// open it; today is circled. No events are loaded here: at this size a dot per day says little
/// and would cost a request per month.
struct YearView: View {
    @EnvironmentObject var events: EventsService
    let onSelectMonth: (Date) -> Void

    private var calendar: Calendar { events.calendar }

    var body: some View {
        let year = calendar.dateComponents([.year], from: events.focus)
        let firstMonth = calendar.date(from: year)!
        let months = (0..<12).map { calendar.date(byAdding: .month, value: $0, to: firstMonth)! }
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3),
                      spacing: 18) {
                ForEach(months, id: \.self) { month in
                    Button {
                        let isThisMonth = calendar.isDate(month, equalTo: events.today, toGranularity: .month)
                        onSelectMonth(isThisMonth ? events.today : month)
                    } label: {
                        MiniMonth(month: month, today: events.today, calendar: calendar)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .gesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                events.move(.year, by: value.translation.width < 0 ? 1 : -1)
            }
        )
    }
}

// MARK: - MiniMonth

private struct MiniMonth: View {
    let month: Date
    let today: Date
    let calendar: Calendar

    var body: some View {
        let isThisMonth = calendar.isDate(month, equalTo: today, toGranularity: .month)
        VStack(alignment: .leading, spacing: 4) {
            Text(month.formatted(.dateTime.month(.abbreviated)))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isThisMonth ? Color.accentColor : .primary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(CalendarGrid.monthDays(month, calendar: calendar), id: \.self) { day in
                    let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
                    let isToday = inMonth && day == today
                    Text(inMonth ? day.formatted(.dateTime.day()) : "")
                        .font(.system(size: 8, weight: isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? Color(.systemBackground) : .primary)
                        .frame(width: 12, height: 12)
                        .background { if isToday { Circle().fill(Color.accentColor) } }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(month.formatted(.dateTime.month(.wide).year()))
        .accessibilityAddTraits(.isButton)
    }
}
