import SwiftUI

/// The Tasks tab: a box to type a task into, the open tasks in the order they were arranged, and
/// the done ones after. One flat list, as on the web; see `CalendarTask` for why there are no
/// task lists. A search field and a filter menu narrow it; see `TaskFilter`.
struct TasksView: View {
    @EnvironmentObject var tasks: TasksService
    @EnvironmentObject var places: PlacesService
    @EnvironmentObject var geofences: GeofenceMonitor
    @EnvironmentObject var notifications: ReminderNotifications
    @EnvironmentObject var router: AppRouter

    @State private var newTitle = ""
    @State private var isAdding = false
    @State private var addError: String?
    @State private var filter = TaskFilter()
    /// Where you are, for Nearby; nil until it is known.
    @State private var here: GeoPoint?
    @State private var locating = false
    /// A map result for an `@place` that named no saved place, waiting for a yes.
    @State private var arrivalOffer: ArrivalOffer?
    @FocusState private var composerFocused: Bool

    struct ArrivalOffer: Equatable {
        let task: CalendarTask
        let result: PlaceSearchResult
    }

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
                    SmartAddPreview(parsed: parsed, place: parsed.location.flatMap(places.match)?.name)
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
                if let arrivalOffer {
                    offerRow(arrivalOffer)
                }
            }

            if let error = tasks.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if filter.isActive && !tasks.tasks.isEmpty {
                filterSummary
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

            if let range = filter.nearby {
                nearbySection(range)
            } else if !open.isEmpty {
                Section {
                    // Reordering sends the order of every open task, so it waits until they are
                    // all on screen.
                    ForEach(open) { row($0) }
                        .onMove(perform: filter.isActive ? nil : move)
                }
            }
            if !done.isEmpty && filter.nearby == nil {
                Section("Done") {
                    ForEach(done) { row($0) }
                }
            }
        }
        .searchable(text: $filter.text, prompt: "Search tasks")
        .listStyle(.insetGrouped)
        .densityList()
        .navigationTitle("Tasks")
        .navigationDestination(for: TaskRoute.self) { TaskDetailView(taskID: $0.id) }
        .toolbar {
            if tasks.open.count > 1 && !filter.isActive {
                // Reordering is by drag in edit mode, which also keeps a scroll from moving a row.
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
            if !tasks.tasks.isEmpty {
                ToolbarItem(placement: .primaryAction) { filterMenu }
            }
        }
        .refreshable { await tasks.reload() }
        .task {
            await tasks.reload()
            if !places.hasLoaded { await places.reload() }
            openRequested()
        }
        .task(id: filter.nearby) { await locate() }
        // A tapped arrival alert opens its task.
        .onChange(of: router.openTaskID) { _ in openRequested() }
    }

    private func openRequested() {
        guard let id = router.openTaskID, tasks.task(id: id) != nil else { return }
        router.openTaskID = nil
        router.tasksPath = NavigationPath([TaskRoute(id: id)])
    }

    // MARK: - Nearby

    private func locate() async {
        guard filter.nearby != nil else { return }
        geofences.requestWhenInUse()
        locating = true
        defer { locating = false }
        here = await geofences.currentLocation() ?? geofences.location
    }

    @ViewBuilder
    private func nearbySection(_ range: NearbyTasks.Range) -> some View {
        Section {
            if let here {
                let entries = NearbyTasks.list(filter.apply(to: tasks.tasks), places: places.places,
                                               from: here, within: range.meters)
                ForEach(entries, id: \.task.id) { entry in
                    NavigationLink(value: TaskRoute(id: entry.task.id)) {
                        TaskRow(task: entry.task, distance: entry.distance)
                    }
                    .densityRow()
                }
                if entries.isEmpty {
                    Text("No open tasks with a place \(range.title.lowercased())")
                        .foregroundStyle(.secondary)
                }
            } else if locating {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Text(geofences.authorization == .denied || geofences.authorization == .restricted
                     ? "Turn on location access for Calendar in Settings to see tasks near you."
                     : "Your location isn't available right now.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Nearby")
        } footer: {
            if places.unreadable > 0 {
                Text("Tasks at \(places.unreadable) saved place(s) this iPhone can't decrypt aren't shown.")
            }
        }
    }

    // MARK: - Smart Add places

    /// "Remind you at Safeway?" — the top map result for an `@place` that named no saved place.
    /// Never attached without this yes.
    private func offerRow(_ offer: ArrivalOffer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remind you when you arrive at \(offer.result.name)?")
                    if !offer.result.detail.isEmpty {
                        Text(offer.result.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "location.circle")
            }
            HStack {
                Button("Remind Me") { Task { await accept(offer) } }
                    .buttonStyle(.borderedProminent)
                Button("Not Now") { arrivalOffer = nil }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }

    private func accept(_ offer: ArrivalOffer) async {
        arrivalOffer = nil
        do {
            try await tasks.setGeofence(tasks.task(id: offer.task.id) ?? offer.task, .point(offer.result.point))
            askForAlerts()
        } catch {
            addError = "Couldn't add the place to that task."
        }
    }

    /// The first geofence is when Always location and notifications start to matter.
    private func askForAlerts() {
        geofences.requestAlways()
        Task { await notifications.requestAuthorizationIfNeeded() }
    }

    /// Looks up what `@text` names on the map, once the task exists. In the background, so a
    /// slow search never holds up typing the next task.
    private func offerPlace(for task: CalendarTask, named text: String) async {
        guard let result = try? await PlaceSearch.search(text, near: geofences.location).first else { return }
        arrivalOffer = ArrivalOffer(task: task, result: result)
    }

    private var shown: [CalendarTask] { filter.apply(to: tasks.tasks) }
    private var open: [CalendarTask] { shown.filter { !$0.done } }
    private var done: [CalendarTask] { shown.filter(\.done) }

    /// How much of the list the filter leaves, and the way back to all of it.
    private var filterSummary: some View {
        let count = shown.count
        return HStack {
            Text(count == 0 ? "No tasks match" : "Showing \(count) of \(tasks.tasks.count)")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clear") { filter = TaskFilter() }
                .buttonStyle(.borderless)
        }
        .font(.footnote)
    }

    private var filterMenu: some View {
        Menu {
            Picker("Due", selection: $filter.due) {
                ForEach(TaskFilter.Due.allCases) { Text($0.title).tag($0) }
            }
            Picker("Priority", selection: $filter.priority) {
                Text("Any priority").tag(Int?.none)
                Text("High").tag(Int?.some(1))
                Text("Medium").tag(Int?.some(2))
                Text("Low").tag(Int?.some(3))
            }
            .pickerStyle(.menu)
            // A tag picked and then removed from every task stays listed, so it can be unpicked.
            let tags = tasks.allTags + filter.tags.subtracting(tasks.allTags).sorted()
            if !tags.isEmpty {
                Menu("Tags") {
                    ForEach(tags, id: \.self) { tag in
                        Toggle("#\(tag)", isOn: Binding(
                            get: { filter.tags.contains(tag) },
                            set: { if $0 { filter.tags.insert(tag) } else { filter.tags.remove(tag) } }))
                    }
                }
            }
            Picker("Nearby", selection: $filter.nearby) {
                Text("Anywhere").tag(NearbyTasks.Range?.none)
                ForEach(NearbyTasks.Range.allCases) { Text($0.title).tag(NearbyTasks.Range?.some($0)) }
            }
            .pickerStyle(.menu)
            Toggle("Show done", isOn: $filter.showDone)
            if filter.hasMenuFilters {
                Button("Clear filters", role: .destructive) {
                    filter = TaskFilter(text: filter.text)
                }
            }
        } label: {
            Label("Filter", systemImage: filter.hasMenuFilters
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
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
        arrivalOffer = nil
        defer { isAdding = false }
        do {
            var request = SmartAdd.request(for: parsed)
            let place = parsed.location.flatMap(places.match)
            if let place { request.geoPlaceId = place.id }
            let created = try await tasks.create(request)
            if place != nil {
                askForAlerts()
            } else if let text = parsed.location {
                Task { await offerPlace(for: created, named: text) }
            }
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
    /// Metres away, in the Nearby list.
    var distance: Double?

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
            distance.map { (NearbyTasks.format($0), "location.fill") },
            task.location.map { ($0, task.geofence == nil ? "mappin" : "location.circle") }
                ?? (task.geofence == nil ? nil : ("Place", "location.circle")),
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
    /// The saved place `@place` matched, if one did: it will remind you there.
    var place: String?

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
        if let place {
            chips.append(Chip(text: place, symbol: "location.circle.fill"))
        } else if let location = parsed.location {
            chips.append(Chip(text: location, symbol: "mappin"))
        }
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
