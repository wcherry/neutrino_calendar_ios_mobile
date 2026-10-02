import SwiftUI

/// Settings › Saved Places: rename or delete the places tasks remind you at. Deleting one takes it
/// off every task that used it, on the server and here, and stops watching it.
struct SavedPlacesView: View {
    @EnvironmentObject var places: PlacesService
    @EnvironmentObject var tasks: TasksService

    @State private var renaming: TaskPlace?
    @State private var newName = ""
    @State private var deleting: TaskPlace?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                ForEach(places.places) { place in
                    HStack {
                        Label(place.name, systemImage: "mappin.circle.fill")
                        Spacer()
                        Text(usage(of: place)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        newName = place.name
                        renaming = place
                    }
                    .swipeActions {
                        Button(role: .destructive) { deleting = place } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                if places.hasLoaded && places.places.isEmpty {
                    Text(places.isSupported ? "No saved places. Save one when you pick a task's place."
                                            : "This server doesn't support saved places yet.")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Saved places are end-to-end encrypted: the server stores them, but only your devices can read where they are.")
                    if places.unreadable > 0 {
                        Text("\(places.unreadable) saved place(s) can't be opened on this iPhone. Add your encryption key in Settings › Encryption.")
                    }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        .navigationTitle("Saved Places")
        .refreshable { await places.reload() }
        .task { await places.reload() }
        .alert("Rename Place", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { Task { await rename() } }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Place", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Tasks at this place keep their location text but stop reminding you there.")
        }
    }

    private var deleteTitle: String { "Delete \(deleting?.name ?? "place")?" }

    private func usage(of place: TaskPlace) -> String {
        let count = tasks.tasks.filter { !$0.done && $0.geofence == .place(id: place.id) }.count
        return count == 0 ? "" : count == 1 ? "1 task" : "\(count) tasks"
    }

    private func rename() async {
        guard var place = renaming else { return }
        renaming = nil
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != place.name else { return }
        place.name = name
        do {
            try await places.update(place)
            error = nil
        } catch {
            self.error = "Couldn't rename the place. \(error.localizedDescription)"
        }
    }

    private func delete() async {
        guard let place = deleting else { return }
        deleting = nil
        do {
            try await places.delete(place)
            tasks.forgetPlace(id: place.id)
            error = nil
        } catch {
            self.error = "Couldn't delete the place. \(error.localizedDescription)"
        }
    }
}
