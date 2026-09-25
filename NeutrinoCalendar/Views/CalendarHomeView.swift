import SwiftUI

/// The Calendar tab: the same events as Day, Week, Month, Year or Agenda, with arrows that step by
/// the view's own unit, a Today button, and a date picker behind the title for jumping anywhere.
///
/// The mode is remembered per device. Each mode's view reads what it needs from `EventsService`,
/// which loads the months the mode covers and keeps them, so switching modes over the same weeks
/// costs no requests.
struct CalendarHomeView: View {
    @EnvironmentObject var events: EventsService
    @AppStorage(CalendarMode.storageKey) private var mode: CalendarMode = .month
    @State private var jumping = false
    @State private var creating: EventEditorView.Mode?

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .navigationDestination(for: EventOccurrence.self) { EventDetailView(occurrence: $0) }
            .sheet(isPresented: $jumping) { JumpToDateSheet() }
            .sheet(item: $creating) { EventEditorView(mode: $0) }
            // Loads whatever the mode now covers: a new mode, a new focus, or a cache thrown away
            // after an edit elsewhere.
            .task(id: LoadKey(mode: mode, focus: events.focus, generation: events.generation)) {
                await events.ensureLoaded(for: mode)
            }
    }

    private struct LoadKey: Hashable {
        let mode: CalendarMode
        let focus: Date
        let generation: Int
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .day:    TimeGridView(days: [events.focus], onSelectDay: nil)
        case .week:   TimeGridView(days: events.visibleDays(for: .week)) { day in
                          events.select(day)
                          mode = .day
                      }
        case .month:  MonthView()
        case .year:   YearView { month in
                          events.select(month)
                          mode = .month
                      }
        case .agenda: AgendaView()
        }
    }

    private var title: String {
        let focus = events.focus
        switch mode {
        case .day:
            return focus.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .week:
            let days = events.visibleDays(for: .week)
            return Self.span(days.first!, days.last!, calendar: events.calendar)
        case .month, .agenda:
            return focus.formatted(.dateTime.month(.wide).year())
        case .year:
            return focus.formatted(.dateTime.year())
        }
    }

    /// "Sep 20 – 26" or, across a month end, "Sep 27 – Oct 3".
    static func span(_ first: Date, _ last: Date, calendar: Calendar) -> String {
        let sameMonth = calendar.isDate(first, equalTo: last, toGranularity: .month)
        let end = sameMonth ? last.formatted(.dateTime.day()) : last.formatted(.dateTime.month(.abbreviated).day())
        return "\(first.formatted(.dateTime.month(.abbreviated).day())) – \(end)"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarLeading) {
            Button { events.move(mode, by: -1) } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            Button { events.move(mode, by: 1) } label: {
                Label("Next", systemImage: "chevron.right")
            }
        }
        ToolbarItem(placement: .principal) {
            // The title is the way to any date, as the month name is in the iPhone's Calendar.
            Button { jumping = true } label: {
                HStack(spacing: 4) {
                    Text(title).font(.headline)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.primary)
            }
            .accessibilityLabel("\(title), choose a date")
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button("Today") { events.goToToday() }
                .disabled(events.isShowingToday(mode))
            // A new event starts on the day in view: the selected day in month view, the day in
            // day view, the focused day otherwise.
            Button { creating = .create(day: events.focus) } label: {
                Label("New Event", systemImage: "plus")
            }
            Menu {
                Picker("View", selection: $mode) {
                    ForEach(CalendarMode.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
            } label: {
                Label("View: \(mode.label)", systemImage: mode.symbol)
            }
        }
    }
}

// MARK: - JumpToDateSheet

/// A calendar to pick any day from, for dates the arrows would take a while to reach.
struct JumpToDateSheet: View {
    @EnvironmentObject var events: EventsService
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            DatePicker("Date", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Go to Date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Go") {
                            events.select(date)
                            dismiss()
                        }
                    }
                }
                .onAppear { date = events.focus }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - DayHeader

struct DayHeader: View {
    let day: Date

    var body: some View {
        let isToday = Calendar.current.isDateInToday(day)
        HStack(spacing: 6) {
            Text(day.formatted(.dateTime.weekday(.abbreviated)))
            Text(day.formatted(.dateTime.day()))
                .fontWeight(.semibold)
            if isToday {
                Text("Today")
            }
        }
        .foregroundStyle(isToday ? Color.accentColor : .secondary)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - EventRowView

struct EventRowView: View {
    let occurrence: EventOccurrence

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(occurrence.event.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                if occurrence.event.recurrenceRule != nil {
                    Image(systemName: "repeat")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Repeats")
                }
                Spacer(minLength: 0)
                if let badge = occurrence.event.source.badge {
                    SourceBadge(text: badge)
                }
            }
            Text(EventFormatting.timeSummary(occurrence))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let location = occurrence.event.location, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - SourceBadge

/// Marks an event synced from Google, Outlook or iCloud. Those are read-only on this device until
/// the server can write back to the provider (Epic 17), so the badge is also the reason an edit
/// button will be missing.
struct SourceBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
            .accessibilityLabel("From \(text)")
    }
}
