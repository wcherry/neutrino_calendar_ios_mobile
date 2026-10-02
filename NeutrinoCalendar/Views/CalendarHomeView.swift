import SwiftUI

/// The Calendar tab: the same events as Day, Week, Month, Year or Agenda, with arrows that step by
/// the view's own unit, a Today button, and a date picker behind the title for jumping anywhere.
///
/// The mode is remembered per device. Each mode's view reads what it needs from `EventsService`,
/// which loads the months the mode covers and keeps them, so switching modes over the same weeks
/// costs no requests.
struct CalendarHomeView: View {
    @EnvironmentObject var events: EventsService
    @EnvironmentObject var router: AppRouter
    @AppStorage(CalendarMode.storageKey) private var mode: CalendarMode = .month
    @State private var jumping = false
    @State private var creating: EventEditorView.Mode?
    /// An event opened from Spotlight or a Shortcut rather than tapped in a view.
    @State private var opened: EventOccurrence?

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            // A task drawn on the calendar opens the task, not an event it doesn't have.
            .navigationDestination(for: EventOccurrence.self) { occurrence in
                if let task = occurrence.task {
                    TaskDetailView(taskID: task.id)
                } else {
                    EventDetailView(occurrence: occurrence)
                }
            }
            .sheet(isPresented: $jumping) { JumpToDateSheet() }
            .sheet(item: $creating) { EventEditorView(mode: $0) }
            // Loads whatever the mode now covers: a new mode, a new focus, or a cache thrown away
            // after an edit elsewhere.
            .task(id: LoadKey(mode: mode, focus: events.focus, generation: events.generation)) {
                await events.ensureLoaded(for: mode)
            }
            .navigationDestination(isPresented: Binding(get: { opened != nil },
                                                        set: { if !$0 { opened = nil } })) {
                if let opened { EventDetailView(occurrence: opened) }
            }
            .task { await openRequested() }
            .onChange(of: router.openEvent) { _ in Task { await openRequested() } }
            .onAppear(perform: showImported)
            .onChange(of: router.importedEvent) { _ in showImported() }
    }

    /// Opens the event a Spotlight result or a Shortcut asked for, on the day it falls on. It is
    /// read from the server, so what opens is the event as it is now.
    private func openRequested() async {
        guard let link = router.openEvent else { return }
        router.openEvent = nil
        // A holiday (from a widget) has no event on the server: its day is what opens.
        if link.eventID.hasPrefix("holiday:") {
            events.select(EventDayRange(start: link.start, end: link.start, allDay: true, calendar: events.calendar).first)
            return
        }
        do {
            let event = try await events.event(id: link.eventID)
            // An occurrence changed on its own is its exception; it opens as part of its series.
            var series: CalendarEvent?
            if let id = event.recurringEventId { series = try await events.event(id: id) }
            let occurrence = link.occurrence(of: event, series: series)
            events.select(EventDayRange(occurrence, calendar: events.calendar).first)
            opened = occurrence
        } catch let error as CalendarAPIError where error.isNotFound {
            events.error = "That event has been deleted."
        } catch {
            events.error = error.localizedDescription
        }
    }

    /// Opens the new-event form on an event read from a shared `.ics` file, on the day it starts.
    private func showImported() {
        guard let draft = router.importedEvent else { return }
        router.importedEvent = nil
        events.select(draft.start)
        creating = .imported(draft)
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

    /// Today on the left; the arrows either side of the title, which opens the date picker; new
    /// event and the view menu on the right. Five controls across the leading and trailing
    /// groups left the title no room, so the arrows travel with it.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Today") { events.goToToday() }
                .disabled(events.isShowingToday(mode))
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: 0) {
                Button { events.move(mode, by: -1) } label: {
                    Label("Previous", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                        .padding(.horizontal, 4)
                }
                // The title is the way to any date, as the month name is in the iPhone's Calendar.
                Button { jumping = true } label: {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                }
                .accessibilityLabel("\(title), choose a date")
                Button { events.move(mode, by: 1) } label: {
                    Label("Next", systemImage: "chevron.right")
                        .labelStyle(.iconOnly)
                        .padding(.horizontal, 4)
                }
            }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
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

/// One occurrence in a list: a bar in its calendar's colour, or a checkbox for a task on the
/// calendar, then the title, time and place.
struct EventRowView: View {
    @EnvironmentObject var events: EventsService
    let occurrence: EventOccurrence

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let task = occurrence.task {
                TaskCheckbox(task: task)
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(EventStyle.color(of: occurrence, rules: events.rules))
                    .frame(width: 4)
                    .padding(.vertical, 2)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(occurrence.event.title)
                        .font(.body.weight(.medium))
                        .strikethrough(occurrence.task?.done == true)
                        .foregroundStyle(occurrence.task?.done == true ? .secondary : .primary)
                        .lineLimit(2)
                    if occurrence.isRepeating {
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
                Text(occurrence.task == nil ? EventFormatting.timeSummary(occurrence)
                                            : EventStyle.taskTimeSummary(occurrence))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let location = occurrence.event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - EventStyle

/// How events and tasks look on the calendar: an event in its calendar's colour, a task in a
/// colour of its own that no calendar is offered (the web uses its warning amber), so the two
/// never read as one another.
enum EventStyle {
    static let taskColor = Color(red: 0.96, green: 0.62, blue: 0.04) // #f59e0b

    static func color(of occurrence: EventOccurrence, rules: CalendarRules) -> Color {
        if occurrence.task != nil { return taskColor }
        return Color(hex: rules.color(of: occurrence.event)) ?? .accentColor
    }

    /// A task's row in a list sits on its own tint.
    static func rowBackground(_ occurrence: EventOccurrence) -> Color? {
        occurrence.task == nil ? nil : taskColor.opacity(0.12)
    }

    /// "Task due" or "Due 3:00 PM".
    static func taskTimeSummary(_ occurrence: EventOccurrence) -> String {
        if occurrence.event.allDay { return "Task due" }
        return "Due \(occurrence.start.formatted(date: .omitted, time: .shortened))"
    }
}

// MARK: - TaskCheckbox

/// Ticks a task done, or open again, straight from the calendar. The tick shows at once and is
/// taken back if the server refuses (`TasksService.setDone`); the task stays on the calendar,
/// struck through, so it doesn't vanish from under the finger.
struct TaskCheckbox: View {
    @EnvironmentObject var tasks: TasksService
    let task: CalendarTask
    var size: Font = .title3

    var body: some View {
        // The live copy, so a tick made elsewhere shows here too.
        let current = tasks.task(id: task.id) ?? task
        Button {
            Task { await tasks.setDone(current, !current.done) }
        } label: {
            Image(systemName: current.done ? "checkmark.circle.fill" : "circle")
                .font(size)
                .foregroundStyle(EventStyle.taskColor)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(current.done ? "Mark \(task.title) as not done" : "Mark \(task.title) as done")
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
