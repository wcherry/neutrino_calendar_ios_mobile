import SwiftUI

/// The Reminders tab: open reminders soonest first, completed ones after, filtered by the web's
/// Today / 3 days / 7 days / All and by search.
struct RemindersView: View {
    @EnvironmentObject var reminders: RemindersService
    @EnvironmentObject var router: AppRouter

    /// All by default, as on the web: a filter should not open by hiding what was there last time.
    @State private var range: ReminderRange = .all
    @State private var search = ""
    @State private var editing: ReminderEditorView.Mode?

    var body: some View {
        let visible = reminders.visible(in: range, matching: search)
        List {
            Section {
                Picker("Due", selection: $range) {
                    ForEach(ReminderRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if let error = reminders.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if visible.open.isEmpty && visible.done.isEmpty {
                if reminders.isLoading && !reminders.hasLoaded {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text(emptyMessage)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            if !visible.open.isEmpty {
                Section {
                    ForEach(visible.open) { row($0) }
                }
            }
            if !visible.done.isEmpty {
                Section("Completed") {
                    ForEach(visible.done) { row($0) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .densityList()
        .navigationTitle("Reminders")
        .searchable(text: $search)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = .create(link: .none, due: nil) } label: {
                    Label("New Reminder", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editing) { mode in
            ReminderEditorView(mode: mode)
        }
        .refreshable { await reminders.reload() }
        .task {
            await reminders.reload()
            openRequested()
        }
        // A tapped notification opens its reminder.
        .onChange(of: router.openReminderID) { _ in openRequested() }
    }

    private func row(_ reminder: Reminder) -> some View {
        ReminderRow(reminder: reminder, taskTitle: reminder.linkedTaskId.flatMap { reminders.taskTitles[$0] })
            .densityRow()
            .contentShape(Rectangle())
            .onTapGesture { editing = .edit(reminder) }
            .swipeActions {
                Button(role: .destructive) { Task { await reminders.delete(reminder) } } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    private func openRequested() {
        guard let id = router.openReminderID,
              let reminder = reminders.reminders.first(where: { $0.id == id }) else { return }
        router.openReminderID = nil
        editing = .edit(reminder)
    }

    /// The web's wording: a range that hides everything says how much it is hiding, so it doesn't
    /// read as an empty account.
    private var emptyMessage: String {
        if !search.isEmpty { return "No matches" }
        let hidden = reminders.hiddenCount(by: range)
        if hidden > 0 { return "Nothing due — \(hidden) later \(hidden == 1 ? "reminder" : "reminders")" }
        return "No reminders"
    }
}

// MARK: - ReminderRow

struct ReminderRow: View {
    @EnvironmentObject var reminders: RemindersService
    let reminder: Reminder
    var taskTitle: String? = nil
    /// Off inside an event's or a task's own screen, where saying what it belongs to is noise.
    var showsLink = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                Task { await reminders.setCompleted(reminder, !reminder.completed) }
            } label: {
                Image(systemName: reminder.completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(reminder.completed ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(reminder.completed ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(reminder.title)
                        .strikethrough(reminder.completed)
                        .foregroundStyle(reminder.completed ? .secondary : .primary)
                    if reminder.recurrenceRule != nil {
                        Image(systemName: "repeat")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Repeats")
                    }
                }
                if !reminder.completed {
                    Text(dueText)
                        .font(.subheadline)
                        .foregroundStyle(reminder.isOverdue() ? .red : .secondary)
                }
                if showsLink, let link = linkText {
                    Label(link.text, systemImage: link.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var dueText: String {
        let when = reminder.due.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return reminder.isOverdue() ? "Overdue · \(when)" : when
    }

    private var linkText: (text: String, symbol: String)? {
        if reminder.linkedEventId != nil { return ("Event reminder", "calendar") }
        if reminder.linkedTaskId != nil { return (taskTitle ?? "Task", "checklist") }
        return nil
    }
}
