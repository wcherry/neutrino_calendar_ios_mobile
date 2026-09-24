import SwiftUI

/// The Calendar tab: one month as an agenda, days with events only, each event on every day it
/// covers. Month, week and day grids are Epic 5; this is the web's Agenda view.
struct CalendarHomeView: View {
    @EnvironmentObject var events: EventsService
    /// The month the list last jumped to today in, so a refresh doesn't yank the list back
    /// while someone is reading further down.
    @State private var scrolledToTodayIn: Date?

    var body: some View {
        content
            .navigationTitle(events.month.formatted(.dateTime.month(.wide).year()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .navigationDestination(for: EventOccurrence.self) { EventDetailView(occurrence: $0) }
            .refreshable { await events.reload() }
            .task { await events.reload() }
    }

    @ViewBuilder
    private var content: some View {
        if events.sections.isEmpty {
            if events.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = events.error {
                // Pull-to-refresh needs a scroll view to pull on.
                ScrollView {
                    EmptyStateView(systemImage: "exclamationmark.triangle", title: "Couldn't Load Events",
                                   message: error)
                    Button("Try Again") { Task { await events.reload() } }
                }
            } else {
                ScrollView {
                    EmptyStateView(systemImage: "calendar", title: "No Events",
                                   message: "Nothing is scheduled this month.")
                }
            }
        } else {
            ScrollViewReader { proxy in
                List {
                    if let error = events.error {
                        // Keep what is already on screen and say the refresh failed, rather than
                        // replacing a usable list with an error.
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    ForEach(events.sections) { section in
                        Section {
                            ForEach(section.occurrences) { occurrence in
                                NavigationLink(value: occurrence) {
                                    EventRowView(occurrence: occurrence)
                                }
                            }
                        } header: {
                            DayHeader(day: section.day)
                        }
                        .id(section.id)
                    }
                }
                .listStyle(.insetGrouped)
                .onAppear { scrollToToday(proxy) }
                .onChange(of: events.sections) { _ in scrollToToday(proxy) }
            }
        }
    }

    /// Opens the current month at today, or at the next day with events, rather than at the 1st.
    /// Other months open at their start, as the web does.
    private func scrollToToday(_ proxy: ScrollViewProxy) {
        guard events.isShowingCurrentMonth, scrolledToTodayIn != events.month else { return }
        let today = Calendar.current.startOfDay(for: Date())
        guard let target = events.sections.first(where: { $0.day >= today }) else { return }
        scrolledToTodayIn = events.month
        proxy.scrollTo(target.id, anchor: .top)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarLeading) {
            Button { Task { await events.showPreviousMonth() } } label: {
                Label("Previous Month", systemImage: "chevron.left")
            }
            Button { Task { await events.showNextMonth() } } label: {
                Label("Next Month", systemImage: "chevron.right")
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button("Today") { Task { await events.showToday() } }
                .disabled(events.isShowingCurrentMonth)
        }
    }
}

// MARK: - DayHeader

private struct DayHeader: View {
    let day: Date

    var body: some View {
        let isToday = Calendar.current.isDateInToday(day)
        HStack(spacing: 6) {
            Text(day.formatted(.dateTime.weekday(.abbreviated)))
            Text(day.formatted(.dateTime.day()))
                .fontWeight(.semibold)
            if isToday {
                Text("Today")
            }
        }
        .foregroundStyle(isToday ? Color.accentColor : .secondary)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - EventRowView

struct EventRowView: View {
    let occurrence: EventOccurrence

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(occurrence.event.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                if occurrence.event.recurrenceRule != nil {
                    Image(systemName: "repeat")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Repeats")
                }
                Spacer(minLength: 0)
                if let badge = occurrence.event.source.badge {
                    SourceBadge(text: badge)
                }
            }
            Text(EventFormatting.timeSummary(occurrence))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let location = occurrence.event.location, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - SourceBadge

/// Marks an event synced from Google, Outlook or iCloud. Those are read-only on this device until
/// the server can write back to the provider (Epic 17), so the badge is also the reason an edit
/// button will be missing.
struct SourceBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
            .accessibilityLabel("From \(text)")
    }
}
