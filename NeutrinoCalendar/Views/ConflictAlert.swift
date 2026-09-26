import SwiftUI

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

// MARK: - Pending writes banner

/// "2 changes waiting to sync", while edits made offline are queued.
struct PendingWritesBanner: View {
    @EnvironmentObject var pending: PendingWrites

    var body: some View {
        if !pending.isEmpty {
            let count = pending.writes.count
            Label(count == 1 ? "1 change waiting to sync" : "\(count) changes waiting to sync",
                  systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(.bar)
                .accessibilityIdentifier("pendingWritesBanner")
        }
    }
}
