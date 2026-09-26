import SwiftUI

/// One month as a list: the days with events, each event on every day it covers. The web's
/// Agenda view.
struct AgendaView: View {
    @EnvironmentObject var events: EventsService
    /// The month the list last jumped to today in, so a refresh doesn't yank the list back
    /// while someone is reading further down.
    @State private var scrolledToTodayIn: Date?
    /// Switching the density rebuilds the list, which puts it back at the 1st; this is watched so
    /// the rebuilt list jumps to today again.
    @AppStorage(LayoutDensity.storageKey) private var compactLayout = false

    var body: some View {
        content
            .refreshable { await events.refreshFromProviders(for: .agenda) }
            .onChange(of: compactLayout) { _ in scrolledToTodayIn = nil }
    }

    @ViewBuilder
    private var content: some View {
        if events.sections.isEmpty {
            if events.isLoading || !events.hasLoaded(events.month) && events.error == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = events.error {
                // Pull-to-refresh needs a scroll view to pull on.
                ScrollView {
                    EmptyStateView(systemImage: "exclamationmark.triangle", title: "Couldn't Load Events",
                                   message: error)
                    Button("Try Again") { Task { await events.reload(for: .agenda) } }
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
                                .densityRow()
                            }
                        } header: {
                            DayHeader(day: section.day)
                        }
                        .id(section.id)
                    }
                }
                .listStyle(.insetGrouped)
                .densityList()
                .onAppear { scrollToFocus(proxy) }
                .onChange(of: events.sections) { _ in scrollToFocus(proxy) }
                .onChange(of: events.focus) { _ in
                    scrolledToTodayIn = nil
                    scrollToFocus(proxy)
                }
            }
        }
    }

    /// Opens the month at the focused day (today, unless a date was picked), or at the next day
    /// with events, rather than at the 1st. Once per month, so a refresh doesn't move the list.
    private func scrollToFocus(_ proxy: ScrollViewProxy) {
        guard scrolledToTodayIn != events.month else { return }
        guard let target = events.sections.first(where: { $0.day >= events.focus }) else { return }
        scrolledToTodayIn = events.month
        proxy.scrollTo(target.id, anchor: .top)
    }
}
