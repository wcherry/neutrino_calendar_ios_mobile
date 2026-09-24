import SwiftUI

/// The task editor: the one place a task is more than a line of text. The web's `TaskDetailModal`.
///
/// Save applies the task row and the calendar slot. Reminders and notes are written the moment
/// they are added or removed, because each needs the task to exist already, and it always does.
struct TaskDetailView: View {
    @EnvironmentObject var tasks: TasksService
    @EnvironmentObject var reminders: RemindersService
    @EnvironmentObject var events: EventsService
    @Environment(\.dismiss) private var dismiss

    let taskID: String

    @State private var title = ""
    @State private var notes = ""
    @State private var hasDue = false
    @State private var due = Date()

    @State private var onCalendar = false
    @State private var allDay = false
    @State private var start = Date()
    @State private var end = Date()
    /// The slot as it was when the screen opened, so Save only moves the event if it changed.
    @State private var original: Slot?

    @State private var attachments: [TaskAttachment] = []
    @State private var newNote = ""
    @State private var newReminder: ReminderEditorView.Mode?

    @State private var seeded = false
    @State private var isSaving = false
    @State private var error: String?

    /// An hour, the length a task gets when it is first put on the calendar, as on the web.
    private static let defaultSlot: TimeInterval = 60 * 60

    struct Slot: Equatable {
        var start: Date
        var end: Date
        var allDay: Bool
    }

    private var task: CalendarTask? { tasks.task(id: taskID) }

    var body: some View {
        Form {
            if let task {
                content(task)
            } else {
                Text("This task is no longer available.")
                    .foregroundStyle(.secondary)
            }
        }
        .densityList()
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isSaving || task == nil)
            }
        }
        .sheet(item: $newReminder) { ReminderEditorView(mode: $0) }
        .task(id: taskID) { await seed() }
    }

    @ViewBuilder
    private func content(_ task: CalendarTask) -> some View {
        Section {
            TextField("Title", text: $title)
            TextField("Notes", text: $notes, axis: .vertical)
                .lineLimit(3...8)
        }

        Section {
            Toggle("Due date", isOn: $hasDue.animation())
            if hasDue {
                DatePicker("Date", selection: $due, displayedComponents: .date)
            }
        }

        Section {
            Toggle("Add to calendar", isOn: $onCalendar.animation())
            if onCalendar {
                Toggle("All day", isOn: $allDay)
                DatePicker("Starts", selection: startBinding,
                           displayedComponents: allDay ? .date : [.date, .hourAndMinute])
                DatePicker("Ends", selection: $end, in: start...,
                           displayedComponents: allDay ? .date : [.date, .hourAndMinute])
            }
        } footer: {
            if task.eventId != nil && !onCalendar {
                Text("Saving takes it off the calendar and deletes its event.")
            }
        }

        if let error {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }

        Section("Reminders") {
            ForEach(reminders.reminders(forTask: task.id)) { reminder in
                ReminderRow(reminder: reminder, showsLink: false)
                    .densityRow()
                    .swipeActions {
                        Button(role: .destructive) { Task { await reminders.delete(reminder) } } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
            Button {
                newReminder = .create(link: .task(task), due: suggestedReminderTime)
            } label: {
                Label("Add Reminder", systemImage: "bell.badge")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
        }

        Section {
            ForEach(attachments) { attachment in
                Group {
                    if let note = attachment.note, attachment.fileId == nil {
                        Label(note, systemImage: "note.text").textSelection(.enabled)
                    } else {
                        // Opening a Drive file means decrypting it on the device: Epic 14.
                        Label(attachment.name ?? "Drive file", systemImage: "doc")
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { Task { await delete(attachment, from: task) } } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            TextField("Add a note", text: $newNote)
                .submitLabel(.done)
                .onSubmit { Task { await addNote(to: task) } }
        } header: {
            Text("Attachments")
        } footer: {
            Text("Attaching a Drive file isn't available on iPhone yet.")
        }
    }

    /// Moving the start keeps the slot's length rather than inverting it, as on the web.
    private var startBinding: Binding<Date> {
        Binding(get: { start }, set: { newStart in
            let length = end.timeIntervalSince(start)
            start = newStart
            end = newStart.addingTimeInterval(length > 0 ? length : Self.defaultSlot)
        })
    }

    /// A reminder for a task defaults to 09:00 on its due day, or the top of the next hour.
    private var suggestedReminderTime: Date {
        if hasDue, let morning = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: due),
           morning > Date() {
            return morning
        }
        return Self.nextHour()
    }

    // MARK: - Loading

    /// Fills the form once. Without seeding the slot from the event, the form would open on a
    /// default slot and Save would move the event to it: a screen changing what it describes just
    /// by being opened.
    private func seed() async {
        guard !seeded, let task else { return }
        seeded = true
        title = task.title
        notes = task.notes ?? ""
        if let day = task.dueDay() {
            hasDue = true
            due = day
        }
        let defaultStart = defaultStart(for: task)
        start = defaultStart
        end = defaultStart.addingTimeInterval(Self.defaultSlot)
        onCalendar = task.eventId != nil

        async let attachmentsLoad = tasks.attachments(for: task)
        if !reminders.hasLoaded { await reminders.reload() }
        if let event = try? await tasks.event(for: task) {
            allDay = event.allDay
            if event.allDay {
                let range = EventDayRange(start: event.start, end: event.end, allDay: true)
                start = range.first
                end = range.last
            } else {
                start = event.start
                end = event.end
            }
            original = Slot(start: start, end: end, allDay: allDay)
        }
        attachments = (try? await attachmentsLoad) ?? []
    }

    /// 09:00 on the due day, or the top of the next hour: the web's `defaultStart`.
    private func defaultStart(for task: CalendarTask) -> Date {
        if let day = task.dueDay(),
           let morning = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day) {
            return morning
        }
        return Self.nextHour()
    }

    private static func nextHour() -> Date {
        Calendar.current.nextDate(after: Date(), matching: DateComponents(minute: 0),
                                  matchingPolicy: .nextTime) ?? Date()
    }

    // MARK: - Saving

    private func save() async {
        guard let task else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            // The row first: the event carries the task's title, and the server reads it from
            // the stored row when scheduling.
            let saved = try await tasks.update(task, title: title.trimmingCharacters(in: .whitespaces),
                                               notes: notes, dueDay: hasDue ? due : nil)
            let slot = Slot(start: start, end: end, allDay: allDay)
            var calendarChanged = false
            if onCalendar, saved.eventId == nil || slot != original {
                try await tasks.schedule(saved, start: start, end: end, allDay: allDay)
                calendarChanged = true
            } else if !onCalendar, saved.eventId != nil {
                try await tasks.unschedule(saved)
                calendarChanged = true
            } else if saved.eventId != nil, saved.title != task.title {
                // A rename retitles the event server-side.
                calendarChanged = true
            }
            if calendarChanged { await events.reload() }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Attachments

    private func addNote(to task: CalendarTask) async {
        let note = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        do {
            attachments.append(try await tasks.addNote(note, to: task))
            newNote = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ attachment: TaskAttachment, from task: CalendarTask) async {
        do {
            try await tasks.deleteAttachment(attachment, from: task)
            attachments.removeAll { $0.id == attachment.id }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
