import Foundation

// MARK: - TaskFilter

/// What the Tasks tab narrows its list to: words typed in the search field, plus the due range,
/// priority and tags picked from the filter menu. Applied on the device to the tasks already
/// loaded, as the server's task list takes no filter and is small enough to send whole.
struct TaskFilter: Equatable {

    enum Due: String, CaseIterable, Identifiable {
        case any, overdue, today, week, none

        var id: String { rawValue }

        var title: String {
            switch self {
            case .any:     return "Any date"
            case .overdue: return "Overdue"
            case .today:   return "Due today"
            case .week:    return "Next 7 days"
            case .none:    return "No due date"
            }
        }
    }

    /// Matched against the title, notes, location and tags, ignoring case and accents.
    var text = ""
    var due: Due = .any
    /// 1 (high) to 3 (low); nil is any priority.
    var priority: Int?
    /// A task matches if it carries any one of these.
    var tags: Set<String> = []
    var showDone = true
    /// Open tasks with a place within this range, nearest first. Needs the device's location and
    /// the decrypted places, so `NearbyTasks` applies it after `apply`, not `apply` itself.
    var nearby: NearbyTasks.Range?

    /// Anything other than the whole list, search included.
    var isActive: Bool { hasMenuFilters || !query.isEmpty }

    /// The filters picked from the menu, not counting the search field: what the menu's icon
    /// shows as on.
    var hasMenuFilters: Bool { self != TaskFilter(text: text) }

    private var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The tasks that pass, keeping the order they came in.
    func apply(to tasks: [CalendarTask], now: Date = .now, calendar: Calendar = .current) -> [CalendarTask] {
        let today = calendar.startOfDay(for: now)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return tasks.filter { task in
            if task.done && !showDone { return false }
            if let priority, task.priority != priority { return false }
            if !tags.isEmpty && tags.isDisjoint(with: task.tags) { return false }
            if !matches(task, due: today, weekEnd: weekEnd, calendar: calendar) { return false }
            return words.allSatisfy { Self.contains(task, $0) }
        }
    }

    /// A done task is never overdue: it was finished, whatever its date says.
    private func matches(_ task: CalendarTask, due today: Date, weekEnd: Date, calendar: Calendar) -> Bool {
        let day = task.dueDay(in: calendar)
        switch due {
        case .any:     return true
        case .none:    return day == nil
        case .overdue: return !task.done && day.map { $0 < today } ?? false
        case .today:   return day == today
        case .week:    return day.map { $0 >= today && $0 < weekEnd } ?? false
        }
    }

    /// `#errands` searches the tags alone; any other word may be anywhere in the task.
    private static func contains(_ task: CalendarTask, _ word: String) -> Bool {
        if word.hasPrefix("#") {
            let tag = word.drop(while: { $0 == "#" }).lowercased()
            return tag.isEmpty || task.tags.contains { $0.hasPrefix(tag) }
        }
        let fields = [task.title, task.notes, task.location].compactMap { $0 } + task.tags
        return fields.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
