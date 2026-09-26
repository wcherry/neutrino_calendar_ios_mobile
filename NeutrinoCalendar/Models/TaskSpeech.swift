import Foundation

/// Tasks by voice: what Siri's Add Task sends, and what What's Due Today says.
enum TaskSpeech {

    // MARK: - Add Task

    /// The create request for what was said. It goes through Smart Add, the same parser as the
    /// quick-add box, so "buy milk tomorrow at 5pm" is a task due tomorrow at 5 PM. A due date
    /// given separately (the Shortcuts field) wins over one in the words: midnight means the day,
    /// any other time means that time. `nil` when nothing is left for a title.
    static func request(for text: String, due: Date?, now: Date, calendar: Calendar) -> CreateTaskRequest? {
        let parsed = SmartAdd.parse(text, context: .current(now, calendar: calendar))
        let title = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        var request = SmartAdd.request(for: parsed, calendar: calendar)
        request.title = title
        if let due {
            let time = calendar.dateComponents([.hour, .minute], from: due)
            if time.hour == 0 && time.minute == 0 {
                request.dueDate = CalendarTask.dueDateValue(for: due, in: calendar)
                request.dueHasTime = nil
            } else {
                request.dueDate = ServerDate.format(due)
                request.dueHasTime = true
            }
        }
        return request
    }

    /// "Added Buy milk, due tomorrow at 5:00 PM." or "Added Buy milk."
    static func added(_ task: CalendarTask, now: Date, calendar: Calendar) -> String {
        guard let due = dueText(task, now: now, calendar: calendar) else { return "Added \(task.title)." }
        return "Added \(task.title), due \(due)."
    }

    // MARK: - What's Due Today

    /// The open tasks due by the end of today in `calendar`: those overdue, oldest first, and
    /// those due today, a timed one by its time and the rest in the list's own order after them.
    static func dueToday(_ tasks: [CalendarTask], now: Date,
                         calendar: Calendar) -> (overdue: [CalendarTask], today: [CalendarTask]) {
        let today = calendar.startOfDay(for: now)
        let open = tasks.enumerated().compactMap { index, task -> (Int, CalendarTask, Date)? in
            guard !task.done, let day = task.dueDay(in: calendar), day <= today else { return nil }
            return (index, task, day)
        }
        let overdue = open.filter { $0.2 < today }
            .sorted { ($0.2, $0.0) < ($1.2, $1.0) }
            .map(\.1)
        let dueToday = open.filter { $0.2 == today }
            .sorted { a, b in
                switch (a.1.dueHasTime ? a.1.dueDate : nil, b.1.dueHasTime ? b.1.dueDate : nil) {
                case let (x?, y?): return x != y ? x < y : a.0 < b.0
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil):   return a.0 < b.0
                }
            }
            .map(\.1)
        return (overdue, dueToday)
    }

    /// "You have 2 tasks due today: Call mom at 3:00 PM and Buy milk. 1 is overdue: Taxes."
    /// Names at most `limit` of each, then says how many more.
    static func sentence(overdue: [CalendarTask], today: [CalendarTask], calendar: Calendar,
                         limit: Int = 5) -> String {
        if overdue.isEmpty && today.isEmpty { return "Nothing's due today." }
        let time = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone)
        func names(_ tasks: [CalendarTask]) -> String {
            var shown = tasks.prefix(limit).map { task -> String in
                guard task.dueHasTime, let due = task.dueDate else { return task.title }
                return "\(task.title) at \(due.formatted(time))"
            }
            if tasks.count > limit { shown.append("\(tasks.count - limit) more") }
            return ListFormatter.localizedString(byJoining: shown)
        }
        var parts: [String] = []
        if today.isEmpty {
            parts.append("Nothing's due today.")
        } else {
            let count = today.count == 1 ? "1 task" : "\(today.count) tasks"
            parts.append("You have \(count) due today: \(names(today)).")
        }
        if !overdue.isEmpty {
            parts.append("\(overdue.count) \(overdue.count == 1 ? "is" : "are") overdue: \(names(overdue)).")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Helpers

    /// "tomorrow", "tomorrow at 5:00 PM", "on Oct 3"; `nil` with no due date.
    static func dueText(_ task: CalendarTask, now: Date, calendar: Calendar) -> String? {
        guard let due = task.dueDate, let day = task.dueDay(in: calendar) else { return nil }
        let when = UpNext.when(day, now: now, calendar: calendar)
        guard task.dueHasTime else { return when }
        let time = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone)
        return "\(when) at \(due.formatted(time))"
    }
}
