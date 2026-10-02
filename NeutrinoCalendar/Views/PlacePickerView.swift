import MapKit
import SwiftUI

// MARK: - PlacePickerView

/// Picks where a task reminds you: one of your saved places, a place found on the map, or where
/// you are now, with the radius around it. A new spot can be saved as a place on the way.
struct PlacePickerView: View {
    @EnvironmentObject var places: PlacesService
    @EnvironmentObject var geofences: GeofenceMonitor
    @Environment(\.dismiss) private var dismiss

    /// What to show the task's location as, and its geofence.
    let onPick: (_ name: String, _ geofence: TaskGeofence) -> Void

    @State private var query = ""
    @State private var results: [PlaceSearchResult] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var draft: Draft?

    /// A spot picked from the map, being sized and maybe saved.
    struct Draft: Identifiable {
        let id = UUID()
        var name: String
        var detail: String
        var point: GeoPoint
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section {
                        Button {
                            Task { await useCurrentLocation() }
                        } label: {
                            Label("Current Location", systemImage: "location.fill")
                        }
                        .disabled(geofences.authorization == .denied || geofences.authorization == .restricted)
                    }
                    savedPlaces
                } else {
                    searchResults
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search for a place")
            .onSubmit(of: .search) { Task { await search() } }
            .task(id: query) {
                // Searches as you type, once you pause.
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                await search()
            }
            .navigationTitle("Remind Me At")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(item: $draft) { draft in
                PlaceDraftView(draft: draft) { name, geofence in
                    onPick(name, geofence)
                    dismiss()
                }
            }
            .task {
                geofences.requestWhenInUse()
                if !places.hasLoaded { await places.reload() }
            }
        }
    }

    @ViewBuilder
    private var savedPlaces: some View {
        Section {
            ForEach(places.places) { place in
                Button {
                    onPick(place.name, .place(id: place.id))
                    dismiss()
                } label: {
                    HStack {
                        Label(place.name, systemImage: "mappin.circle.fill")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(NearbyTasks.format(Double(place.point.radius)))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if places.places.isEmpty {
                Text(places.isSupported ? "No saved places yet. Search for one, then save it."
                                        : "This server doesn't support saved places yet.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Saved Places")
        } footer: {
            if places.unreadable > 0 {
                Text("\(places.unreadable) saved place(s) can't be opened on this iPhone. Add your encryption key in Settings › Encryption.")
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        Section {
            if isSearching && results.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else if let searchError {
                Label(searchError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if results.isEmpty {
                Text("No places found").foregroundStyle(.secondary)
            }
            ForEach(results) { result in
                Button {
                    draft = Draft(name: result.name, detail: result.detail, point: result.point)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.name).foregroundStyle(.primary)
                        if !result.detail.isEmpty {
                            Text(result.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        // Saved places that match come first: picking one of those needs no radius.
        let matching = places.places.filter { $0.name.localizedCaseInsensitiveContains(query) }
        if !matching.isEmpty {
            Section("Saved Places") {
                ForEach(matching) { place in
                    Button(place.name) {
                        onPick(place.name, .place(id: place.id))
                        dismiss()
                    }
                }
            }
        }
    }

    private func search() async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            return
        }
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        do {
            results = try await PlaceSearch.search(query, near: geofences.location)
        } catch {
            results = []
            // MapKit reports "no results" as an error too.
            if (error as? MKError)?.code != .placemarkNotFound {
                searchError = "Couldn't search the map. Check your connection."
            }
        }
    }

    private func useCurrentLocation() async {
        geofences.requestWhenInUse()
        guard let here = await geofences.currentLocation() else {
            searchError = "Your location isn't available."
            return
        }
        draft = Draft(name: "", detail: "Current location",
                      point: GeoPoint(latitude: here.latitude, longitude: here.longitude))
    }
}

// MARK: - PlaceDraftView

/// A spot on the map: how far around it counts as arriving, and whether to keep it as a place.
struct PlaceDraftView: View {
    @EnvironmentObject var places: PlacesService
    @Environment(\.dismiss) private var dismiss

    let onDone: (_ name: String, _ geofence: TaskGeofence) -> Void

    @State private var name: String
    @State private var radius: Double
    @State private var saveAsPlace = false
    @State private var isSaving = false
    @State private var error: String?
    private let detail: String
    private let point: GeoPoint

    init(draft: PlacePickerView.Draft, onDone: @escaping (_ name: String, _ geofence: TaskGeofence) -> Void) {
        self.onDone = onDone
        detail = draft.detail
        point = draft.point
        _name = State(initialValue: draft.name)
        _radius = State(initialValue: Double(draft.point.radius))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    GeofenceMapView(point: sized)
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets())
                    TextField("Name", text: $name)
                    if !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Slider(value: $radius, in: Double(GeoPoint.minimumRadius)...Double(GeoPoint.maximumRadius), step: 50) {
                        Text("Radius")
                    }
                } header: {
                    Text("Radius: \(NearbyTasks.format(radius))")
                } footer: {
                    Text("You're reminded when you arrive within this distance.")
                }
                Section {
                    Toggle("Save as a place", isOn: $saveAsPlace)
                        .disabled(!places.canSave)
                } footer: {
                    if !places.isSupported {
                        Text("This server doesn't support saved places yet.")
                    } else if !places.canSave {
                        Text("Saved places are end-to-end encrypted. Add your encryption key in Settings › Encryption to save one.")
                    } else {
                        Text("Saved places are end-to-end encrypted: only your devices know where they are.")
                    }
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Task { await done() } }
                        .disabled(trimmedName.isEmpty || isSaving)
                }
            }
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var sized: GeoPoint { GeoPoint(latitude: point.latitude, longitude: point.longitude, radius: Int(radius)) }

    private func done() async {
        guard !saveAsPlace else {
            isSaving = true
            defer { isSaving = false }
            do {
                let place = try await places.create(name: trimmedName, point: sized)
                onDone(place.name, .place(id: place.id))
                dismiss()
            } catch {
                self.error = "Couldn't save the place. \(error.localizedDescription)"
            }
            return
        }
        onDone(trimmedName, .point(sized))
        dismiss()
    }
}

// MARK: - GeofenceMapView

/// The circle on a map. MapKit's own view, because SwiftUI's `Map` draws no circles before iOS 17.
struct GeofenceMapView: UIViewRepresentable {
    let point: GeoPoint

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isRotateEnabled = false
        map.showsUserLocation = true
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let center = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })
        map.addOverlay(MKCircle(center: center, radius: CLLocationDistance(point.radius)))
        let pin = MKPointAnnotation()
        pin.coordinate = center
        map.addAnnotation(pin)
        let span = CLLocationDistance(point.radius) * 3
        map.setRegion(MKCoordinateRegion(center: center, latitudinalMeters: span, longitudinalMeters: span),
                      animated: context.coordinator.hasShown)
        context.coordinator.hasShown = true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var hasShown = false

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let circle = overlay as? MKCircle else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKCircleRenderer(circle: circle)
            renderer.fillColor = UIColor.tintColor.withAlphaComponent(0.15)
            renderer.strokeColor = UIColor.tintColor
            renderer.lineWidth = 1.5
            return renderer
        }
    }
}
