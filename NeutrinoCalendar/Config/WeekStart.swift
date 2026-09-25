import Foundation

/// The day weeks start on: in the month and year grids, the week view, and the date picker.
///
/// The same three choices, default and stored values as the web's Settings › Calendar
/// (`WEEK_START_OPTIONS`, stored as a JavaScript day number: 0 Sunday, 1 Monday, 6 Saturday), so
/// one account's calendar is laid out the same way on both. It is a per-device preference on
/// both, as on the web, where it lives in `localStorage`.
enum WeekStart: Int, CaseIterable, Identifiable {
    case sunday = 0
    case monday = 1
    case saturday = 6

    static let storageKey = "ncal.calendar.weekStart"

    /// The web's default.
    static let `default`: WeekStart = .sunday

    /// What is stored on this device, or the default.
    static var stored: WeekStart {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: storageKey) != nil else { return .default }
        return WeekStart(rawValue: defaults.integer(forKey: storageKey)) ?? .default
    }

    var id: Int { rawValue }

    /// `Calendar.firstWeekday`, which counts from 1 for Sunday where JavaScript counts from 0.
    var firstWeekday: Int { rawValue + 1 }

    var label: String {
        switch self {
        case .sunday:   return "Sunday"
        case .monday:   return "Monday"
        case .saturday: return "Saturday"
        }
    }
}
