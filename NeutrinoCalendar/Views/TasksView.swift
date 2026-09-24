import SwiftUI

/// The Tasks tab: a box to type a task into, the open tasks in the order they were arranged, and
/// the done ones after. One flat list, as on the web; see `CalendarTask` for why there are no
/// task lists.
struct TasksView: View {
    @EnvironmentObject var tasks: TasksService

    @State private var newTitle = ""
    @State private var isAdding = false
    @State private var addError: String?
    @FocusState private var composerFocused: Bool

    var body: some View {
        List {
            Section {
                TextField("Add a task…", text: $newTitle)
                    .focused($composerFocused)
                    .submitLabel(.done)
                    .onSubmit { Task { await add() } }
                    .disabled(isAdding)
                if let addError {
                    Label(addError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            if let error = tasks.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if tasks.tasks.isEmpty {
                if tasks.isLoading && !tasks.hasLoaded {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("No tasks — type one above")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            if !tasks.open.isEmpty {
                Section {
                    ForEach(tasks.open) { row($0) }
                        .onMove(perform: move)
                }
            }
            if !tasks.done.isEmpty {
                Section("Done") {
                    ForEach(tasks.done) { row($0) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Tasks")
        .navigationDestination(for: TaskRoute.self) { TaskDetailView(taskID: $0.id) }
        .toolbar {
            if tasks.open.count > 1 {
                // Reordering is by drag in edit mode, which also keeps a scroll from moving a row.
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
        }
        .refreshable { await tasks.reload() }
        .task { await tasks.reload() }
    }

    private func row(_ task: CalendarTask) -> some View {
        NavigationLink(value: TaskRoute(id: task.id)) {
            TaskRow(task: task)
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ids = tasks.open.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        Task { await tasks.reorderOpen(to: ids) }
    }

    /// Adds the task and keeps the box focused, so the next one can be typed straight away. What
    /// was typed stays put if the add fails: retyping it because the network blinked is worse.
    private func add() async {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !isAdding else { return }
        isAdding = true
        addError = nil
        defer { isAdding = false }
        do {
            try await tasks.create(title: title)
            newTitle = ""
            composerFocused = true
        } catch {
            addError = "Couldn't add that task. Please try again."
        }
    }
}

/// A navigation value for a task. The detail screen looks the task up by id, so it always shows
/// what the service holds rather than a copy taken when the row was tapped.
struct TaskRoute: Hashable {
    let id: String
}

// MARK: - TaskRow

struct TaskRow: View {
    @EnvironmentObject var tasks: TasksService
    let task: CalendarTask

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                Task { await tasks.setDone(task, !task.done) }
            } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(task.done ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(task.done ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .strikethrough(task.done)
                    .foregroundStyle(task.done ? .secondary : .primary)
                badges
            }
        }
        .padding(.vertical, 2)
    }

    /// What a task carries that its title can't say, from the fields already on the row. As on
    /// the web, reminders and attachments aren't counted here: each would be a request per row.
    @ViewBuilder
    private var badges: some View {
        let parts: [(String, String)] = [
            task.dueDateText.map { ($0, "clock") },
            task.eventId == nil ? nil : ("On calendar", "calendar"),
            task.notes == nil ? nil : ("Notes", "doc.text"),
        ].compactMap { $0 }
        if !parts.isEmpty {
            HStack(spacing: 10) {
                ForEach(parts, id: \.0) { text, symbol in
                    Label(text, systemImage: symbol)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
    }
}
