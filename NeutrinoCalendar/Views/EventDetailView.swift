import SwiftUI

/// One occurrence of an event, read-only. Editing is Epic 4.
struct EventDetailView: View {
    @EnvironmentObject var events: EventsService
    let occurrence: EventOccurrence

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

            attachmentsSection
        }
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: event.id) { await loadAttachments() }
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
