import Foundation

/// Tasks with a due date, drawn on the calendar beside events, with a checkbox to complete them:
/// the web's `taskEvents` (`calendar/calendarTasks.ts`). Not events: nothing is stored, the views
/// just draw them, each as an occurrence of a made-up event with `source: .task` carrying its
/// task.
enum TaskOccurrences {
    /// How long a task due at a time is drawn on the time grid, unless it has an estimate.
    static let defaultMinutes = 30

    /// The tasks due from `from` to `to` (inclusive). A task due on a date is all-day on that date,
    /// written as every all-day event is (`T00:00:00Z` to `T23:59:59Z`, read by its date); one due
    /// at a time starts then and lasts its estimate, or half an hour.
    ///
    /// A task scheduled onto the calendar (`eventId`) is left out: its event is already drawn.
    /// Done tasks stay, ticked, so completing one doesn't make it vanish from under a finger.
    static func occurrences(_ tasks: [CalendarTask], from: Date, to: Date) -> [EventOccurrence] {
        let first = Holidays.dayString(from), last = Holidays.dayString(to)
        return tasks.compactMap { task in
            guard let due = task.dueDate, task.eventId == nil else { return nil }
            let start: Date, end: Date
            if task.dueHasTime {
                guard due >= from, due <= to else { return nil }
                let minutes = (task.estimateMinutes ?? 0) > 0 ? task.estimateMinutes! : defaultMinutes
                (start, end) = (due, due.addingTimeInterval(TimeInterval(minutes * 60)))
            } else {
                let day = Holidays.dayString(due)
                guard day >= first, day <= last,
                      let s = ServerDate.parse("\(day)T00:00:00Z"),
                      let e = ServerDate.parse("\(day)T23:59:59Z") else { return nil }
                (start, end) = (s, e)
            }
            let event = CalendarEvent(id: "task:\(task.id)", title: task.title, description: task.notes,
                                      start: start, end: end, allDay: !task.dueHasTime, location: task.location,
                                      source: .task)
            return EventOccurrence(event: event, start: start, end: end, task: task)
        }
    }
}
