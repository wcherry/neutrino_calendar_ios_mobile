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
                    .autocorrectionDisabled()
                if let parsed, parsed.hasDetails {
                    SmartAddPreview(parsed: parsed)
                } else if composerFocused && newTitle.isEmpty {
                    Text("Try ^fri 3pm #tag !1 *weekly")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        .densityList()
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
        .densityRow()
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ids = tasks.open.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        Task { await tasks.reorderOpen(to: ids) }
    }

    /// What Smart Add reads in the box, recomputed as it is typed so the preview is what Return
    /// will create.
    private var parsed: SmartAddResult? {
        let text = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : SmartAdd.parse(text)
    }

    /// Adds the task and keeps the box focused, so the next one can be typed straight away. What
    /// was typed stays put if the add fails: retyping it because the network blinked is worse.
    private func add() async {
        guard let parsed, !isAdding else { return }
        guard !parsed.title.isEmpty else {
            addError = "Add a title as well as the details."
            return
        }
        isAdding = true
        addError = nil
        defer { isAdding = false }
        do {
            try await tasks.create(parsed)
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
            task.priority.map { ("!\($0)", "flag.fill") },
            task.dueDateText.map { ($0, "clock") },
            task.recurrenceRule == nil ? nil : ("Repeats", "repeat"),
            task.location.map { ($0, "mappin") },
            task.eventId == nil ? nil : ("On calendar", "calendar"),
            task.notes == nil ? nil : ("Notes", "doc.text"),
        ].compactMap { $0 }
        if !parts.isEmpty || !task.tags.isEmpty {
            HStack(spacing: 10) {
                ForEach(parts, id: \.0) { text, symbol in
                    Label(text, systemImage: symbol)
                }
                if !task.tags.isEmpty {
                    Text(task.tags.map { "#\($0)" }.joined(separator: " "))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
    }
}

// MARK: - SmartAddPreview

/// One chip per field Smart Add found in the line being typed, so a date picked up from the title
/// is visible before Return commits it.
struct SmartAddPreview: View {
    let parsed: SmartAddResult

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chips) { chip in
                    Label(chip.text, systemImage: chip.symbol)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Smart Add will set " + chips.map(\.text).joined(separator: ", "))
    }

    private struct Chip: Identifiable {
        let text: String
        let symbol: String
        var id: String { symbol + text }
    }

    private var chips: [Chip] {
        var chips: [Chip] = []
        if let due = parsed.due { chips.append(Chip(text: Self.format(due), symbol: "calendar")) }
        if let start = parsed.start { chips.append(Chip(text: "starts \(Self.format(start))", symbol: "play.circle")) }
        if let priority = parsed.priority { chips.append(Chip(text: "Priority \(priority)", symbol: "flag.fill")) }
        chips += parsed.tags.map { Chip(text: "#\($0)", symbol: "tag") }
        if let rule = parsed.recurrenceRule {
            chips.append(Chip(text: SmartAdd.describeRepeat(rule, after: parsed.repeatAfterCompletion), symbol: "repeat"))
        }
        if let minutes = parsed.estimateMinutes { chips.append(Chip(text: SmartAdd.formatEstimate(minutes), symbol: "hourglass")) }
        if let location = parsed.location { chips.append(Chip(text: location, symbol: "mappin")) }
        if let note = parsed.note { chips.append(Chip(text: note, symbol: "note.text")) }
        return chips
    }

    /// "Fri, Oct 2" or "Fri, Oct 2, 3:00 PM", in this zone.
    static func format(_ value: SmartDate, calendar: Calendar = .current) -> String {
        let p = value.date.split(separator: "-").compactMap { Int($0) }
        let hm = value.time?.split(separator: ":").compactMap { Int($0) } ?? [0, 0]
        guard p.count == 3, hm.count == 2,
              let date = calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2],
                                                            hour: hm[0], minute: hm[1])) else {
            return value.date
        }
        var style = Date.FormatStyle(date: .omitted, time: .omitted).weekday(.abbreviated).month(.abbreviated).day()
        if value.time != nil { style = style.hour().minute() }
        return date.formatted(style)
    }
}
