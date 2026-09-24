import Foundation

/// The first and last local day an occurrence covers, both inclusive, as midnights. A port of the
/// web's `eventDayRange` (`calendarHelpers.ts`), pinned by the same generated vectors as the
/// recurrence expansion.
///
/// Two rules carry the weight:
///
/// - **An all-day event is a date, not an instant.** Its days are the UTC date parts of its start
///   and end, taken as local dates, so an all-day event on the 1st is on the 1st in every zone.
/// - **An end exactly at midnight belongs to the day before.** That is what an `.ics` all-day
///   `DTEND` means, being exclusive, and a timed event ending at 00:00 has nothing on that day.
struct EventDayRange: Equatable {
    let first: Date
    let last: Date

    init(start: Date, end: Date, allDay: Bool, calendar: Calendar = .current) {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!

        /// Local midnight of an instant's UTC date: the web's `dateOnly(iso)`.
        func dateOnly(_ date: Date) -> Date {
            let parts = utc.dateComponents([.year, .month, .day], from: date)
            return calendar.date(from: parts)!
        }

        let endsAtMidnight: Bool
        if allDay {
            let t = utc.dateComponents([.hour, .minute, .second], from: end)
            endsAtMidnight = t.hour == 0 && t.minute == 0 && t.second == 0
        } else {
            let t = calendar.dateComponents([.hour, .minute, .second], from: end)
            endsAtMidnight = t.hour == 0 && t.minute == 0 && t.second == 0
        }

        let first = allDay ? dateOnly(start) : calendar.startOfDay(for: start)
        var last = allDay ? dateOnly(end) : calendar.startOfDay(for: end)
        if last > first && endsAtMidnight { last = calendar.date(byAdding: .day, value: -1, to: last)! }
        if last < first { last = first }
        self.first = first
        self.last = last
    }

    init(_ occurrence: EventOccurrence, calendar: Calendar = .current) {
        self.init(start: occurrence.start, end: occurrence.end, allDay: occurrence.event.allDay,
                  calendar: calendar)
    }

    func contains(day: Date, calendar: Calendar = .current) -> Bool {
        let midnight = calendar.startOfDay(for: day)
        return midnight >= first && midnight <= last
    }
}
