import SwiftUI
import NeutrinoCore

// MARK: - Edit conflict alert

extension View {
    /// Asks what to do when a save found the thing changed or deleted elsewhere
    /// (`EditConflict`): save over the other change, or drop this one. A deleted thing can only
    /// be dropped.
    func editConflictAlert(_ conflict: Binding<EditConflict?>,
                           overwrite: @escaping () -> Void,
                           discard: @escaping () -> Void) -> some View {
        alert(
            conflict.wrappedValue == .deletedElsewhere ? "Deleted Elsewhere" : "Changed Elsewhere",
            isPresented: Binding(get: { conflict.wrappedValue != nil },
                                 set: { if !$0 { conflict.wrappedValue = nil } }),
            presenting: conflict.wrappedValue
        ) { shown in
            if shown == .deletedElsewhere {
                Button("OK") { discard() }
            } else {
                Button("Save Mine Anyway", role: .destructive) { overwrite() }
                Button("Discard My Changes", role: .cancel) { discard() }
            }
        } message: { shown in
            if shown == .deletedElsewhere {
                Text("\(shown.localizedDescription) Your changes can't be saved.")
            } else {
                Text("\(shown.localizedDescription) Save yours over theirs, or keep theirs?")
            }
        }
    }
}

// MARK: - Pending writes notice

/// Why changes made offline were discarded, until dismissed. The queue itself — "2 changes
/// waiting to sync", offline, syncing — is the app-wide `ConnectivityBanner`'s.
struct PendingWritesBanner: View {
    @EnvironmentObject var pending: PendingWrites

    var body: some View {
        if let notice = pending.notice {
            HStack(alignment: .firstTextBaseline) {
                Label(notice, systemImage: "lock.fill")
                Spacer(minLength: 8)
                Button { pending.dismissNotice() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .padding(.horizontal)
            .background(.bar)
            .accessibilityIdentifier("pendingWritesNotice")
        }
    }
}

// MARK: - Connectivity banner

extension PendingWrites {
    /// The queue in the shared banner's terms.
    var activity: SyncActivity {
        if isReplaying { return .syncing(remaining: writes.count) }
        if let lastFailure, !writes.isEmpty { return .failed(lastFailure) }
        return .idle
    }
}

// MARK: - FocusFilterBanner

/// Says that a Focus is hiding some of the calendar, so a missing event doesn't read as a lost
/// one.
struct FocusFilterBanner: View {
    @EnvironmentObject var events: EventsService

    var body: some View {
        if let summary = events.sourceFilter.summary {
            Label("Focus: showing \(summary) only", systemImage: "moon.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(.bar)
                .accessibilityIdentifier("focusFilterBanner")
        }
    }
}
