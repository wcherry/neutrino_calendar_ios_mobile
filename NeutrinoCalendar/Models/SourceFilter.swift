import Foundation

// MARK: - CalendarSource

/// The calendars a Focus filter can choose between. Neutrino has no calendars of its own yet, only
/// where an event came from, so these are the sources: Neutrino's own events and each provider
/// the server syncs from.
enum CalendarSource: String, CaseIterable, Identifiable, Sendable {
    case neutrino, google, outlook, icloud

    var id: Self { self }

    /// `nil` for a source the server names but the app doesn't know, which no filter chooses.
    init?(_ source: EventSource) {
        switch source {
        case .local:   self = .neutrino
        case .google:  self = .google
        case .outlook: self = .outlook
        case .apple:   self = .icloud
        case .other:   return nil
        }
    }

    var label: String {
        switch self {
        case .neutrino: return "Neutrino"
        case .google:   return "Google"
        case .outlook:  return "Outlook"
        case .icloud:   return "iCloud"
        }
    }
}

// MARK: - SourceFilter

/// Which sources' events the calendar shows, set by a Focus filter (`CalendarFocusFilter`) and
/// cleared when the Focus ends. Everything is shown when no filter is set.
///
/// Stored per device in UserDefaults: a Focus is this device's state, not the account's.
struct SourceFilter: Equatable {
    static let storageKey = "ncal.focus.sources"

    /// `nil` shows everything.
    let shown: Set<CalendarSource>?

    static let all = SourceFilter(shown: nil)

    /// No sources chosen means no filter, rather than an empty calendar: that is what a Focus
    /// filter left with nothing ticked most plausibly means.
    init(shown: Set<CalendarSource>?) {
        self.shown = shown?.isEmpty == true ? nil : shown
    }

    var isActive: Bool { shown != nil }

    /// An event from a source the app doesn't know is hidden by any filter: nothing chose it.
    func shows(_ source: EventSource) -> Bool {
        guard let shown else { return true }
        guard let known = CalendarSource(source) else { return false }
        return shown.contains(known)
    }

    /// "Neutrino and Google", in the order the sources are listed; `nil` when not filtering.
    var summary: String? {
        guard let shown else { return nil }
        let names = CalendarSource.allCases.filter(shown.contains).map(\.label)
        return ListFormatter.localizedString(byJoining: names)
    }

    // MARK: - Storage

    static func load(from defaults: UserDefaults = .standard) -> SourceFilter {
        guard let raw = defaults.stringArray(forKey: storageKey) else { return .all }
        return SourceFilter(shown: Set(raw.compactMap(CalendarSource.init(rawValue:))))
    }

    func save(to defaults: UserDefaults = .standard) {
        if let shown {
            defaults.set(CalendarSource.allCases.filter(shown.contains).map(\.rawValue), forKey: Self.storageKey)
        } else {
            defaults.removeObject(forKey: Self.storageKey)
        }
    }
}
