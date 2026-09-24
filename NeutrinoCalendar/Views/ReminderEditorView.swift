import SwiftUI

/// Creates or edits one reminder.
struct ReminderEditorView: View {

    /// What a new reminder belongs to. Fixed for its lifetime: the server's update has no link
    /// fields.
    enum ReminderLink {
        case none
        case event(String)
        case task(CalendarTask)

        var eventID: String? { if case .event(let id) = self { return id }; return nil }
        var task: CalendarTask? { if case .task(let task) = self { return task }; return nil }
    }

    enum Mode: Identifiable {
        case create(link: ReminderLink, due: Date?)
        case edit(Reminder)

        var id: String {
            switch self {
            case .create:             return "new"
            case .edit(let reminder): return reminder.id
            }
        }
    }

    @EnvironmentObject var reminders: RemindersService
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    @State private var title = ""
    @State private var due = Date()
    @State private var repeatOption: RepeatOption = .never
    @State private var task: CalendarTask?
    @State private var tasks: [CalendarTask] = []
    @State private var isSaving = false
    @State private var error: String?

    private var existing: Reminder? {
        if case .edit(let reminder) = mode { return reminder }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    DatePicker("Due", selection: $due)
                }

                Section {
                    Picker("Repeat", selection: $repeatOption) {
                        ForEach(repeatChoices) { Text($0.label).tag($0) }
                    }
                } footer: {
                    if repeatOption != .never {
                        Text("Completing it moves it to the next time it's due.")
                    }
                }

                linkSection

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                if let existing {
                    Section {
                        Button("Delete Reminder", role: .destructive) {
                            Task {
                                await reminders.delete(existing)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .densityList()
            .navigationTitle(existing == nil ? "New Reminder" : "Edit Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Add" : "Save") { Task { await save() } }
                        .disabled(trimmedTitle.isEmpty || isSaving)
                }
            }
            .onAppear(perform: fill)
            .task { await loadTasksIfLinkable() }
        }
    }

    /// Links are set once, at creation: the server's update has no link fields. So a new
    /// reminder offers the choice and an existing one only says what it belongs to.
    @ViewBuilder
    private var linkSection: some View {
        switch mode {
        case .create(.event, _):
            EmptyView()
        case .create(.task(let task), _):
            Section { Label(task.title, systemImage: "checklist") }
        case .create(.none, _):
            if !tasks.isEmpty {
                Section {
                    Picker("Task", selection: $task) {
                        Text("None").tag(CalendarTask?.none)
                        ForEach(tasks.filter { !$0.done }) { Text($0.title).tag(CalendarTask?.some($0)) }
                    }
                } footer: {
                    Text("A reminder can't be moved to a different task later.")
                }
            }
        case .edit(let reminder):
            if reminder.linkedEventId != nil {
                Section { Label("On an event", systemImage: "calendar") }
            } else if let taskID = reminder.linkedTaskId {
                Section {
                    Label(reminders.taskTitles[taskID] ?? "On a task", systemImage: "checklist")
                }
            }
        }
    }

    /// The standard choices, plus the reminder's own rule when it is one of none of them, so it
    /// can be kept.
    private var repeatChoices: [RepeatOption] {
        var choices = RepeatOption.standard
        if case .custom = RepeatOption(rule: existing?.recurrenceRule) {
            choices.append(RepeatOption(rule: existing?.recurrenceRule))
        }
        return choices
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fill() {
        switch mode {
        case .edit(let reminder):
            title = reminder.title
            due = reminder.due
            repeatOption = RepeatOption(rule: reminder.recurrenceRule)
        case .create(let link, let suggested):
            // The web titles a task's reminder after the task when none is given.
            if let task = link.task { title = task.title }
            // The web's default: the top of the next hour.
            due = suggested ?? Calendar.current.nextDate(after: Date(), matching: DateComponents(minute: 0),
                                                         matchingPolicy: .nextTime) ?? Date()
        }
    }

    private func loadTasksIfLinkable() async {
        guard case .create(.none, _) = mode else { return }
        tasks = (try? await reminders.tasks()) ?? []
    }

    private func save() async {
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            switch mode {
            case .create(let link, _):
                try await reminders.create(title: trimmedTitle, due: due, rule: repeatOption.rule,
                                           eventID: link.eventID, task: link.task ?? task)
            case .edit(let reminder):
                try await reminders.update(reminder, title: trimmedTitle, due: due, rule: repeatOption.rule)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
