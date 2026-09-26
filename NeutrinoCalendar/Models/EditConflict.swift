import Foundation

// MARK: - EditConflict

/// Why a save stopped to ask before going ahead: the thing was changed, or deleted, on another
/// device or on the web after this device opened it.
///
/// An edit sends only the fields it changed, so a change made elsewhere to a *different* field
/// is never overwritten and is not a conflict. The save stops only when both sides changed the
/// same field to different values.
enum EditConflict: LocalizedError, Equatable {
    /// Both changed these fields, named for people ("title", "time").
    case changedElsewhere([String])
    case deletedElsewhere

    var errorDescription: String? {
        switch self {
        case .changedElsewhere(let fields):
            return "Someone changed the \(ListFormatter.localizedString(byJoining: fields)) on another device since you opened this."
        case .deletedElsewhere:
            return "This was deleted on another device."
        }
    }

    /// The fields that `mine` and `theirs` both change, to different values. Both are update
    /// requests measured from the same starting point, and an absent field means "unchanged".
    static func clashes(mine: some Encodable, theirs: some Encodable) -> [String] {
        guard let mine = fields(of: mine), let theirs = fields(of: theirs) else { return [] }
        var labels: [String] = []
        for key in mine.keys.sorted() {
            guard let their = theirs[key], !(their as AnyObject).isEqual(mine[key]) else { continue }
            let label = Self.label(key)
            if !labels.contains(label) { labels.append(label) }
        }
        return labels
    }

    private static func fields(of request: some Encodable) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The wire names of the three update requests, as the forms label them.
    private static func label(_ key: String) -> String {
        switch key {
        case "startTime", "endTime", "allDay": return "time"
        case "description", "notes":           return "notes"
        case "recurrenceRule":                 return "repeat"
        case "attendees":                      return "guests"
        case "timezone":                       return "time zone"
        case "dueTime", "dueDate", "dueHasTime": return "due date"
        default:                               return key
        }
    }
}
