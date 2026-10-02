import SwiftUI

// MARK: - CalendarsSettingsView

/// Settings › Calendars: every calendar, shown or hidden at a tap, and holiday calendars by
/// country. The choices are calendars on the server, so they match the web on every device.
struct CalendarsSettingsView: View {
    @EnvironmentObject var calendars: CalendarsService
    @EnvironmentObject var events: EventsService

    @State private var adding = false
    @State private var addingCountry = false

    var body: some View {
        List {
            if let error = calendars.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Section {
                ForEach(calendars.ownCalendars) { calendar in
                    NavigationLink {
                        CalendarEditView(calendar: calendar)
                    } label: {
                        CalendarRow(calendar: calendar)
                    }
                }
                Button {
                    adding = true
                } label: {
                    Label("Add Calendar", systemImage: "plus")
                }
            } header: {
                Text("My Calendars")
            } footer: {
                Text("A hidden calendar's events don't show anywhere on this iPhone: the calendar, widgets, Spotlight and alerts. It's hidden on the web too.")
            }

            Section {
                ForEach(calendars.holidayCalendars) { calendar in
                    NavigationLink {
                        HolidayCalendarView(calendar: calendar)
                    } label: {
                        CalendarRow(calendar: calendar)
                    }
                }
                Button {
                    addingCountry = true
                } label: {
                    Label("Add Country", systemImage: "plus")
                }
            } header: {
                Text("Holidays")
            } footer: {
                Text("Public holidays are worked out on this iPhone, so the countries you pick never leave Neutrino. Holiday rules from date-holidays (CC BY-SA 3.0).")
            }
        }
        .navigationTitle("Calendars")
        .refreshable { await calendars.reload() }
        .task { await calendars.reload() }
        .sheet(isPresented: $adding) { NewCalendarView() }
        .sheet(isPresented: $addingCountry) { CountryPickerView() }
    }
}

// MARK: - CalendarRow

/// A calendar's colour and name, and the switch that shows or hides it, which applies at once.
private struct CalendarRow: View {
    @EnvironmentObject var calendars: CalendarsService
    let calendar: UserCalendar

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color(hex: calendar.color) ?? .accentColor).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(calendar.name)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("Show \(calendar.name)", isOn: Binding(
                get: { calendars.calendar(id: calendar.id)?.visible ?? calendar.visible },
                set: { visible in Task { await calendars.setVisible(calendar, visible) } }))
                .labelsHidden()
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if calendar.isDefault { parts.append("Default") }
        if let source = calendar.source, calendar.kind == .connection { parts.append(EventSource(rawValue: source).badge ?? source) }
        if calendar.readOnly { parts.append("Read-only") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - ColorPalette

/// The web's eight calendar colours.
private struct ColorPalette: View {
    @Binding var selection: String

    var body: some View {
        HStack {
            ForEach(UserCalendar.palette, id: \.self) { hex in
                Button {
                    selection = hex
                } label: {
                    Circle()
                        .fill(Color(hex: hex) ?? .accentColor)
                        .frame(width: 28, height: 28)
                        .overlay {
                            if hex.lowercased() == selection.lowercased() {
                                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.name(hex))
                .accessibilityAddTraits(hex.lowercased() == selection.lowercased() ? .isSelected : [])
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }

    private static func name(_ hex: String) -> String {
        ["#3b82f6": "Blue", "#16a34a": "Green", "#f97316": "Orange", "#8b5cf6": "Purple",
         "#e11d48": "Red", "#0ea5e9": "Sky", "#ca8a04": "Yellow", "#64748b": "Grey"][hex] ?? hex
    }
}

// MARK: - NewCalendarView

private struct NewCalendarView: View {
    @EnvironmentObject var calendars: CalendarsService
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = UserCalendar.palette[0]
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Name", text: $name) }
                Section("Colour") { ColorPalette(selection: $color) }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            .navigationTitle("New Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await add() } }
                        .disabled(trimmed.isEmpty || isSaving)
                }
            }
            .onAppear { color = UserCalendar.unusedColor(among: calendars.calendars) }
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func add() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await calendars.create(.local(name: trimmed, color: color))
            dismiss()
        } catch {
            self.error = "Couldn't add the calendar. \(error.localizedDescription)"
        }
    }
}

// MARK: - CalendarEditView

/// Rename, recolour or delete a calendar. A read-only one takes a new name and colour too: those
/// are settings, not its events. The default calendar can't be deleted, nor a provider's while
/// its account is connected.
private struct CalendarEditView: View {
    @EnvironmentObject var calendars: CalendarsService
    @EnvironmentObject var events: EventsService
    @Environment(\.dismiss) private var dismiss

    let calendar: UserCalendar
    @State private var name = ""
    @State private var color = ""
    @State private var confirmingDelete = false
    @State private var error: String?

    var body: some View {
        Form {
            Section { TextField("Name", text: $name) }
            Section("Colour") { ColorPalette(selection: $color) }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if calendar.isDeletable {
                Section {
                    Button("Delete Calendar", role: .destructive) { confirmingDelete = true }
                } footer: {
                    Text("Deletes the calendar and every event in it, on every device.")
                }
            } else if calendar.isDefault {
                Section {} footer: { Text("This is your default calendar: new events go here, and it can't be deleted.") }
            }
        }
        .navigationTitle(calendar.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = calendar.name
            color = calendar.color
        }
        // Saved on the way out, as the iPhone's own settings are.
        .onDisappear { Task { await save() } }
        .confirmationDialog("Delete \(calendar.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Calendar and Its Events", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Every event in it is deleted too. This can't be undone.")
        }
    }

    private func save() async {
        guard let current = calendars.calendar(id: calendar.id) else { return }
        var edited = current
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { edited.name = trimmed }
        edited.color = color
        do {
            try await calendars.update(current, to: edited)
        } catch {
            calendars.error = "Couldn't save \(current.name). \(error.localizedDescription)"
        }
    }

    private func delete() async {
        do {
            try await calendars.delete(calendar)
            // Its events went with it.
            events.invalidate()
            dismiss()
        } catch let error as CalendarAPIError where error == .serverError(statusCode: 409) {
            self.error = "Disconnect this account on the web first, then delete its calendar."
        } catch {
            self.error = "Couldn't delete the calendar. \(error.localizedDescription)"
        }
    }
}

// MARK: - HolidayCalendarView

/// One country's holidays: its region, where the rules have any, observances (off by default),
/// colour, and removing it.
private struct HolidayCalendarView: View {
    @EnvironmentObject var calendars: CalendarsService
    @Environment(\.dismiss) private var dismiss

    let calendar: UserCalendar
    @State private var regions: [HolidayEngine.Place] = []
    @State private var region: String = ""
    @State private var observances = false
    @State private var color = ""
    @State private var confirmingRemove = false
    @State private var error: String?

    var body: some View {
        Form {
            if !regions.isEmpty {
                Section {
                    Picker("Region", selection: $region) {
                        Text("Nationwide only").tag("")
                        ForEach(regions) { Text($0.name).tag($0.code) }
                    }
                } footer: {
                    Text("Adds the region's own holidays to the nationwide ones.")
                }
            }
            Section {
                Toggle("Include observances", isOn: $observances)
            } footer: {
                Text("Days that are marked but aren't days off, such as Mother's Day or Halloween.")
            }
            Section("Colour") { ColorPalette(selection: $color) }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Section {
                Button("Remove \(calendar.name)", role: .destructive) { confirmingRemove = true }
            }
        }
        .navigationTitle(calendar.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            region = calendar.region ?? ""
            observances = calendar.includeObservances
            color = calendar.color
            if let country = calendar.country {
                regions = (try? await HolidayEngine.shared.regions(country: country, language: HolidayEngine.deviceLanguage)) ?? []
            }
        }
        .onDisappear { Task { await save() } }
        .confirmationDialog("Remove \(calendar.name)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove Holidays", role: .destructive) { Task { await remove() } }
        }
    }

    private func save() async {
        guard let current = calendars.calendar(id: calendar.id) else { return }
        var edited = current
        edited.region = region.isEmpty ? nil : region
        edited.includeObservances = observances
        edited.color = color
        do {
            try await calendars.update(current, to: edited)
        } catch {
            calendars.error = "Couldn't save \(current.name). \(error.localizedDescription)"
        }
    }

    private func remove() async {
        do {
            try await calendars.delete(calendar)
            dismiss()
        } catch {
            self.error = "Couldn't remove it. \(error.localizedDescription)"
        }
    }
}

// MARK: - CountryPickerView

/// Every country the holiday rules know, searchable, those already added left out.
private struct CountryPickerView: View {
    @EnvironmentObject var calendars: CalendarsService
    @Environment(\.dismiss) private var dismiss
    @State private var countries: [HolidayEngine.Place] = []
    @State private var query = ""
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(shown) { country in
                    Button(country.name) { Task { await add(country) } }
                        .foregroundStyle(.primary)
                }
            }
            .searchable(text: $query, prompt: "Search countries")
            .navigationTitle("Add Holidays")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                defer { loading = false }
                do {
                    countries = try await HolidayEngine.shared.countries(language: HolidayEngine.deviceLanguage)
                } catch {
                    self.error = "The holiday rules couldn't be loaded."
                }
            }
        }
    }

    private var shown: [HolidayEngine.Place] {
        let added = Set(calendars.holidayCalendars.compactMap(\.country))
        let open = countries.filter { !added.contains($0.code) }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return open }
        return open.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.code.caseInsensitiveCompare(q) == .orderedSame }
    }

    private func add(_ country: HolidayEngine.Place) async {
        do {
            try await calendars.create(.holidays(country: country.code, name: country.name,
                                                 color: UserCalendar.unusedColor(among: calendars.calendars)))
            dismiss()
        } catch let error as CalendarAPIError where error == .serverError(statusCode: 409) {
            // Added on another device meanwhile.
            await calendars.reload()
            dismiss()
        } catch {
            self.error = "Couldn't add \(country.name). \(error.localizedDescription)"
        }
    }
}
