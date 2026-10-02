import SwiftUI

/// Creates or edits an event. The web's `NewEventModal`, less the reminders and attachments it
/// takes on create: on iOS those are added from the event's own screen once it exists.
struct EventEditorView: View {

    enum Mode: Identifiable {
        case create(day: Date)
        /// A new event filled in from a shared `.ics` file; see ICSImport.
        case imported(EventDraft)
        /// An edit of an occurrence, and, for a repeating event, which of its occurrences the edit
        /// is for; see RecurrenceScope.
        case edit(EventOccurrence, RecurrenceScope?)

        var id: String {
            switch self {
            case .create:                     return "new"
            case .imported:                   return "imported"
            case .edit(let occurrence, let scope): return "\(occurrence.id)-\(scope?.rawValue ?? "one-off")"
            }
        }
    }

    @EnvironmentObject var events: EventsService
    @EnvironmentObject var tasks: TasksService
    @EnvironmentObject var calendars: CalendarsService
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    /// Called after a save with the stored event, or with `nil` after a delete.
    var onSaved: (CalendarEvent?) -> Void = { _ in }

    @State private var draft: EventDraft
    @State private var original: EventDraft
    @State private var newGuest = ""
    @State private var isSaving = false
    @State private var error: String?
    @State private var confirmingDelete = false
    /// Which occurrences the edit is for; nil for a one-off event or a new one.
    private let scope: RecurrenceScope?
    @State private var conflict: EditConflict?

    init(mode: Mode, onSaved: @escaping (CalendarEvent?) -> Void = { _ in }) {
        self.mode = mode
        self.onSaved = onSaved
        let draft: EventDraft
        switch mode {
        case .create(let day): draft = EventDraft(newOn: day)
        case .imported(let d): draft = d
        case .edit(let occurrence, let scope): draft = EventDraft(editing: occurrence, scope: scope)
        }
        if case .edit(let occurrence, let scope) = mode {
            self.scope = EventDraft.effectiveScope(occurrence, scope)
        } else {
            self.scope = nil
        }
        _draft = State(initialValue: draft)
        _original = State(initialValue: draft)
    }

    private var occurrence: EventOccurrence? {
        if case .edit(let occurrence, _) = mode { return occurrence }
        return nil
    }

    /// The event the edit changes: the series for "all events", otherwise what was tapped.
    private var existing: CalendarEvent? {
        guard let occurrence else { return nil }
        return scope == .all ? occurrence.series : occurrence.event
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $draft.title)
                    TextField("Location", text: $draft.location)
                }

                // One occurrence can't move calendar on its own, so a "This event" edit has none.
                if scope != .this, calendars.writable.count > 1 {
                    Section {
                        Picker("Calendar", selection: calendarBinding) {
                            ForEach(calendars.writable) { calendar in
                                Label {
                                    Text(calendar.name)
                                } icon: {
                                    Image(systemName: "circle.fill")
                                        .foregroundStyle(Color(hex: calendar.color) ?? .accentColor)
                                }
                                .tag(Optional(calendar.id))
                            }
                        }
                    } footer: {
                        switch scope {
                        case .all?:       Text("Moving it moves every event in the series.")
                        case .following?: Text("Moving it moves this event and every one after it.")
                        default:          EmptyView()
                        }
                    }
                }

                Section {
                    Toggle("All day", isOn: Binding(get: { draft.allDay },
                                                    set: { on in withAnimation { draft.setAllDay(on) } }))
                    DatePicker("Starts", selection: startBinding,
                               displayedComponents: draft.allDay ? .date : [.date, .hourAndMinute])
                    DatePicker("Ends", selection: $draft.end, in: draft.start...,
                               displayedComponents: draft.allDay ? .date : [.date, .hourAndMinute])
                    if !draft.allDay {
                        NavigationLink {
                            TimeZonePickerView(selection: Binding(get: { draft.timeZone },
                                                                  set: { draft.setTimeZone($0) }))
                        } label: {
                            LabeledContent("Time Zone", value: TimeZonePickerView.name(for: draft.timeZone))
                        }
                    }
                }
                // Times are entered in the event's zone, so 09:00 in New York is 09:00 there.
                .environment(\.timeZone, draft.timeZone)

                if scope == .this {
                    Section {
                        Label(RecurrenceScope.this.label(.event), systemImage: "repeat")
                            .foregroundStyle(.secondary)
                    } footer: {
                        Text("Changes apply to this event only. The rest of the series stays as it is.")
                    }
                } else {
                    Section {
                        Picker("Repeat", selection: presetBinding) {
                            ForEach(repeatChoices) { Text($0.label).tag($0) }
                        }
                        if let rule = draft.repeatRule {
                            Stepper(value: Binding(get: { rule.interval },
                                                   set: { draft.repeatRule?.interval = $0 }),
                                    in: 1...RepeatRule.maxNumber) {
                                Text("Every \(rule.interval) \(rule.frequency.unit(rule.interval))")
                            }
                            Picker("End Repeat", selection: endKindBinding) {
                                ForEach(EndKind.allCases) { Text($0.label).tag($0) }
                            }
                            switch rule.end {
                            case .never:
                                EmptyView()
                            case .on:
                                DatePicker("End Date", selection: endDateBinding,
                                           in: RepeatRule.Day(draft.start, in: draft.timeZone).date(in: draft.timeZone)...,
                                           displayedComponents: .date)
                                    .environment(\.timeZone, draft.timeZone)
                            case .after(let count):
                                Stepper(value: Binding(get: { count },
                                                       set: { draft.repeatRule?.end = .after($0) }),
                                        in: 1...RepeatRule.maxNumber) {
                                    Text("After \(count) \(count == 1 ? "time" : "times")")
                                }
                            }
                        }
                    } footer: {
                        switch scope {
                        case .following?: Text("Changes apply to this event and every one after it.")
                        case .all?:       Text("Changes apply to every event in the series.")
                        default:          EmptyView()
                        }
                    }
                }

                Section {
                    ForEach(draft.attendees, id: \.self) { email in
                        Label(email, systemImage: "person.circle")
                    }
                    .onDelete { draft.attendees.remove(atOffsets: $0) }
                    TextField("Add guest email", text: $newGuest)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(addGuest)
                } header: {
                    Text("Guests")
                } footer: {
                    Text("Guests are saved with the event, but aren't invited or notified yet.")
                }

                Section("Notes") {
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...10)
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                if existing != nil {
                    Section {
                        Button(deleteLabel, role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .densityList()
            .navigationTitle(existing == nil ? "New Event" : "Edit Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Add" : "Save") { Task { await save() } }
                        .disabled(draft.trimmedTitle.isEmpty || isSaving)
                }
            }
            .confirmationDialog(deleteLabel, isPresented: $confirmingDelete, titleVisibility: .visible) {
                if occurrence?.isRepeating == true {
                    ForEach(RecurrenceScope.allCases) { choice in
                        Button("Delete \(choice.label(.event))", role: .destructive) { Task { await delete(choice) } }
                    }
                } else {
                    Button(deleteLabel, role: .destructive) { Task { await delete(nil) } }
                }
            } message: {
                if occurrence?.isRepeating == true {
                    Text("This is a repeating event.")
                }
            }
            .editConflictAlert($conflict,
                               overwrite: { Task { await save(overwrite: true) } },
                               discard: { Task { await discard() } })
        }
    }

    private var deleteLabel: String { "Delete Event" }

    /// The draft's calendar, or the default one for a new event, which is where the server puts
    /// an event that names none.
    private var calendarBinding: Binding<String?> {
        Binding(get: { draft.calendarId ?? calendars.defaultCalendar?.id },
                set: { draft.calendarId = $0 })
    }

    /// The standard choices, plus the event's own rule when the form can't show it, so it is kept.
    private var repeatChoices: [RepeatOption] {
        var choices = RepeatOption.standard
        if case .custom = original.repeatOption, original.repeatRule == nil { choices.append(original.repeatOption) }
        return choices
    }

    /// The rule's choice, or the stored rule the form can't show. Picking another keeps the
    /// interval and end; see RepeatRule.with.
    private var presetBinding: Binding<RepeatOption> {
        Binding(get: { draft.repeatRule?.preset ?? draft.repeatOption }, set: { choice in
            if case .custom = choice {
                draft.repeatOption = choice
            } else {
                draft.repeatRule = RepeatRule.with(choice, from: draft.repeatRule)
            }
        })
    }

    enum EndKind: String, CaseIterable, Identifiable {
        case never, on, after
        var id: String { rawValue }
        var label: String {
            switch self {
            case .never: return "Never"
            case .on:    return "On Date"
            case .after: return "After"
            }
        }
    }

    private var endKindBinding: Binding<EndKind> {
        Binding(get: {
            switch draft.repeatRule?.end {
            case .on?:    return .on
            case .after?: return .after
            default:      return .never
            }
        }, set: { kind in
            guard let rule = draft.repeatRule else { return }
            switch kind {
            case .never: draft.repeatRule?.end = .never
            case .after: draft.repeatRule?.end = .after(10)
            case .on:
                let start = RepeatRule.Day(draft.start, in: draft.timeZone)
                draft.repeatRule?.end = .on(RepeatRule.defaultEndDay(after: start, frequency: rule.frequency))
            }
        })
    }

    /// The end day, shown in the event's zone, as the start and end are.
    private var endDateBinding: Binding<Date> {
        Binding(get: {
            if case .on(let day)? = draft.repeatRule?.end { return day.date(in: draft.timeZone) }
            return draft.start
        }, set: { date in
            draft.repeatRule?.end = .on(RepeatRule.Day(date, in: draft.timeZone))
        })
    }

    /// Moving the start keeps the event's length rather than inverting it, as on the web.
    private var startBinding: Binding<Date> {
        Binding(get: { draft.start }, set: { newStart in
            let length = draft.end.timeIntervalSince(draft.start)
            draft.start = newStart
            draft.end = newStart.addingTimeInterval(max(length, 0))
        })
    }

    private func addGuest() {
        if draft.addAttendee(newGuest) {
            newGuest = ""
        } else if !newGuest.trimmingCharacters(in: .whitespaces).isEmpty {
            error = "“\(newGuest)” isn't an email address, or is already a guest."
        }
    }

    private func save(overwrite: Bool = false) async {
        if let problem = draft.problem {
            error = problem
            return
        }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let saved: CalendarEvent
            if let occurrence {
                saved = try await events.update(occurrence, scope: scope, from: original, to: draft, overwrite: overwrite)
            } else {
                saved = try await events.create(draft)
            }
            onSaved(saved)
            dismiss()
        } catch let conflict as EditConflict {
            self.conflict = conflict
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Drops this edit for the change made elsewhere, and shows that; nil closes the event's
    /// screen when it was deleted.
    private func discard() async {
        guard let existing else { return dismiss() }
        let current = try? await events.event(id: existing.id)
        // Updated in place, not thrown away: a calendar emptied here would have to reload, and
        // might not be able to.
        await events.pullChanges()
        onSaved(current)
        dismiss()
    }

    /// Deletes the occurrences `scope` names, of a repeating event; the event, of a one-off.
    private func delete(_ scope: RecurrenceScope?) async {
        guard let occurrence else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await events.delete(occurrence, scope: scope)
            // A task scheduled as this event is no longer on the calendar.
            let id = occurrence.series?.id ?? occurrence.event.id
            if tasks.tasks.contains(where: { $0.eventId == id }) { await tasks.reload() }
            onSaved(nil)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - TimeZonePickerView

/// Every zone the device knows, searchable by city or region.
struct TimeZonePickerView: View {
    @Binding var selection: TimeZone
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    /// "New York (GMT-4)", from the zone's identifier and its offset now.
    static func name(for zone: TimeZone) -> String {
        let city = zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") }
            ?? zone.identifier
        let seconds = zone.secondsFromGMT()
        let hours = seconds / 3600, minutes = abs(seconds / 60 % 60)
        let offset = minutes == 0 ? String(format: "%+d", hours) : String(format: "%+d:%02d", hours, minutes)
        return seconds == 0 ? "\(city) (GMT)" : "\(city) (GMT\(offset))"
    }

    private var zones: [TimeZone] {
        let all = TimeZone.knownTimeZoneIdentifiers.compactMap(TimeZone.init(identifier:))
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.identifier.replacingOccurrences(of: "_", with: " ").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List(zones, id: \.identifier) { zone in
            Button {
                selection = zone
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.name(for: zone)).foregroundStyle(.primary)
                        Text(zone.identifier).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if zone.identifier == selection.identifier {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "City or region")
        .navigationTitle("Time Zone")
        .navigationBarTitleDisplayMode(.inline)
    }
}
