import SwiftUI

/// One occurrence of an event, read-only. Editing is Epic 4.
struct EventDetailView: View {
    @EnvironmentObject var events: EventsService
    @EnvironmentObject var reminders: RemindersService
    let occurrence: EventOccurrence

    @State private var customReminder: ReminderEditorView.Mode?

    @State private var attachments: [EventAttachment] = []
    @State private var attachmentsState: LoadState = .loading

    private enum LoadState: Equatable {
        case loading, loaded, failed(String)
    }

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

            attachmentsSection
        }
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: event.id) { await loadAttachments() }
        .task { if !reminders.hasLoaded { await reminders.reload() } }
        .sheet(item: $customReminder) { ReminderEditorView(mode: $0) }
    }

    // MARK: - Reminders

    private var eventReminders: [Reminder] { reminders.reminders(forEvent: event.id) }

    /// The event's reminders, and the web's presets for adding one. A preset is timed from this
    /// occurrence's start, which is what the web does too: its detail panel is handed the expanded
    /// occurrence. Presets already used, or already in the past, are left out.
    private var remindersSection: some View {
        Section("Reminders") {
            ForEach(eventReminders) { reminder in
                ReminderRow(reminder: reminder)
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
                Button("Custom…") { customReminder = .create(eventID: event.id, due: occurrence.start) }
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

    @ViewBuilder
    private var attachmentsSection: some View {
        switch attachmentsState {
        case .loading:
            Section("Attachments") {
                ProgressView()
            }
        case .failed(let message):
            Section("Attachments") {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        case .loaded where attachments.isEmpty:
            EmptyView()
        case .loaded:
            Section("Attachments") {
                // Listed, not opened: previewing a Drive file means decrypting it on the device,
                // which is Epic 14.
                ForEach(attachments) { attachment in
                    if let note = attachment.note, attachment.fileId == nil {
                        Label(note, systemImage: "note.text")
                            .textSelection(.enabled)
                    } else {
                        Label(attachment.name ?? "Drive file", systemImage: "doc")
                    }
                }
            }
        }
    }

    private func loadAttachments() async {
        attachmentsState = .loading
        do {
            attachments = try await events.attachments(for: event)
            attachmentsState = .loaded
        } catch {
            attachmentsState = .failed(error.localizedDescription)
        }
    }
}
