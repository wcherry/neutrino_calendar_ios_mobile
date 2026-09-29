import SwiftUI

/// Creates or edits an event. The web's `NewEventModal`, less the reminders and attachments it
/// takes on create: on iOS those are added from the event's own screen once it exists.
struct EventEditorView: View {

    enum Mode: Identifiable {
        case create(day: Date)
        case edit(CalendarEvent)

        var id: String {
            switch self {
            case .create:          return "new"
            case .edit(let event): return event.id
            }
        }
    }

    @EnvironmentObject var events: EventsService
    @EnvironmentObject var tasks: TasksService
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
    @State private var conflict: EditConflict?

    init(mode: Mode, onSaved: @escaping (CalendarEvent?) -> Void = { _ in }) {
        self.mode = mode
        self.onSaved = onSaved
        let draft: EventDraft
        switch mode {
        case .create(let day): draft = EventDraft(newOn: day)
        case .edit(let event): draft = EventDraft(editing: event)
        }
        _draft = State(initialValue: draft)
        _original = State(initialValue: draft)
    }

    private var existing: CalendarEvent? {
        if case .edit(let event) = mode { return event }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $draft.title)
                    TextField("Location", text: $draft.location)
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
                    if existing?.recurrenceRule != nil {
                        Text("Changes apply to every occurrence. Editing one occurrence on its own isn't supported yet.")
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
                Button(deleteLabel, role: .destructive) { Task { await delete() } }
            } message: {
                if existing?.recurrenceRule != nil {
                    Text("This deletes every occurrence of the event.")
                }
            }
            .editConflictAlert($conflict,
                               overwrite: { Task { await save(overwrite: true) } },
                               discard: { Task { await discard() } })
        }
    }

    private var deleteLabel: String {
        existing?.recurrenceRule != nil ? "Delete All Occurrences" : "Delete Event"
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
            if let existing {
                saved = try await events.update(existing, from: original, to: draft, overwrite: overwrite)
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

    private func delete() async {
        guard let existing else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await events.delete(existing)
            // A task scheduled as this event is no longer on the calendar.
            if tasks.tasks.contains(where: { $0.eventId == existing.id }) { await tasks.reload() }
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
