import SwiftUI

/// One occurrence of an event. Neutrino's own events can be edited and deleted from here;
/// events synced from Google, Outlook or iCloud are read-only until the server can write back to
/// the provider (Epic 17).
struct EventDetailView: View {
    @EnvironmentObject var events: EventsService
    @EnvironmentObject var reminders: RemindersService
    @Environment(\.dismiss) private var dismiss

    /// Held as state so an edit can show its result here without a round trip.
    @State private var occurrence: EventOccurrence
    @State private var editing: EventEditorView.Mode?

    init(occurrence: EventOccurrence) {
        _occurrence = State(initialValue: occurrence)
    }

    @State private var customReminder: ReminderEditorView.Mode?
    @StateObject private var attachmentsPresenter = AttachmentsPresenter()


    private var event: CalendarEvent { occurrence.event }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(event.title)
                            .font(.title2.weight(.semibold))
                        Spacer(minLength: 0)
                        if let badge = event.source.badge {
                            SourceBadge(text: badge)
                        }
                    }
                    Text(EventFormatting.dateSummary(occurrence))
                    Text(EventFormatting.timeSummary(occurrence))
                        .foregroundStyle(.secondary)
                    if let original = EventFormatting.originalTimeZoneSummary(occurrence) {
                        Text(original)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let rule = event.recurrenceRule, !rule.isEmpty {
                        Label(EventFormatting.recurrenceSummary(rule), systemImage: "repeat")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                if let badge = event.source.badge {
                    Text("Synced from \(badge). Edit it there: changes can't be sent back to \(badge) yet.")
                }
            }

            if let location = event.location, !location.isEmpty {
                Section("Location") {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .textSelection(.enabled)
                }
            }

            if let description = event.description, !description.isEmpty {
                Section("Notes") {
                    Text(description)
                        .textSelection(.enabled)
                }
            }

            if !event.attendees.isEmpty {
                Section("Guests (\(event.attendees.count))") {
                    ForEach(event.attendees, id: \.self) { email in
                        Label(email, systemImage: "person.circle")
                            .textSelection(.enabled)
                    }
                }
            }

            remindersSection

            AttachmentsSection(owner: events.attachmentOwner(event), presenter: attachmentsPresenter)
        }
        .densityList()
        .attachmentPresentations(attachmentsPresenter)
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
        .task { if !reminders.hasLoaded { await reminders.reload() } }
        .sheet(item: $customReminder) { ReminderEditorView(mode: $0) }
        .sheet(item: $editing) { mode in
            EventEditorView(mode: mode) { saved in applyEdit(saved) }
        }
        .toolbar {
            if event.source == .local {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = .edit(event) }
                }
            }
        }
    }

    /// Shows an edit's result. A one-off event is followed to its new time; a repeating one
    /// can't be, since which occurrence this was is gone once the series moves, so the screen
    /// closes and the calendar shows the new series. A deleted event closes it too.
    private func applyEdit(_ saved: CalendarEvent?) {
        guard let saved, saved.recurrenceRule?.isEmpty ?? true, event.recurrenceRule?.isEmpty ?? true else {
            dismiss()
            return
        }
        occurrence = EventOccurrence(event: saved, start: saved.start, end: saved.end)
    }

    // MARK: - Reminders

    private var eventReminders: [Reminder] { reminders.reminders(forEvent: event.id) }

    /// The event's reminders, and the web's presets for adding one. A preset is timed from this
    /// occurrence's start, which is what the web does too: its detail panel is handed the expanded
    /// occurrence. Presets already used, or already in the past, are left out.
    private var remindersSection: some View {
        Section("Reminders") {
            ForEach(eventReminders) { reminder in
                ReminderRow(reminder: reminder, showsLink: false)
                    .densityRow()
                    .swipeActions {
                        Button(role: .destructive) { Task { await reminders.delete(reminder) } } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
            Menu {
                ForEach(availablePresets) { preset in
                    Button(preset.label) { Task { await add(preset) } }
                }
                Divider()
                Button("Custom…") { customReminder = .create(link: .event(event.id), due: occurrence.start) }
            } label: {
                // Full width: a menu in a list row answers only on its label, so without this a
                // tap on the empty right-hand side of the row does nothing.
                Label("Add Reminder", systemImage: "bell.badge")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
        }
    }

    private var availablePresets: [ReminderPreset] {
        let taken = Set(eventReminders.map(\.due))
        let now = Date()
        return ReminderPreset.all.filter { preset in
            let due = dueTime(for: preset)
            return due > now && !taken.contains(due)
        }
    }

    private func dueTime(for preset: ReminderPreset) -> Date {
        occurrence.start.addingTimeInterval(-TimeInterval(preset.minutes * 60))
    }

    private func add(_ preset: ReminderPreset) async {
        do {
            // Titled after the event, as the web titles the reminders it makes for one.
            try await reminders.create(title: event.title, due: dueTime(for: preset), rule: nil, eventID: event.id)
        } catch {
            reminders.error = error.localizedDescription
        }
    }
}
