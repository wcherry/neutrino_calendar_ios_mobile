import Foundation

/// The strings the event views show, kept out of the views so they can be tested in a fixed zone.
enum EventFormatting {

    /// "All day", or "9:00 AM – 10:00 AM" in `timeZone`. A timed event that ends on a later day
    /// names the end day too, since the time alone would read as a negative duration.
    static func timeSummary(_ occurrence: EventOccurrence, timeZone: TimeZone = .current) -> String {
        if occurrence.event.allDay { return "All day" }
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        let time = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone)
        let start = occurrence.start.formatted(time)
        // `EventDayRange` already treats an end at midnight as the day before, so 23:00–00:00
        // stays a one-day event here too.
        guard EventDayRange(occurrence, calendar: calendar).last > calendar.startOfDay(for: occurrence.start) else {
            return "\(start) – \(occurrence.end.formatted(time))"
        }
        let dayAndTime = Date.FormatStyle(timeZone: timeZone).month(.abbreviated).day().hour().minute()
        return "\(start) – \(occurrence.end.formatted(dayAndTime))"
    }

    /// The date line of the detail view: "Thursday, September 24, 2026", or a range for an event
    /// covering several days. All-day dates come from `EventDayRange`, so an all-day event keeps
    /// its date whatever zone the device is in.
    static func dateSummary(_ occurrence: EventOccurrence, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        let range = EventDayRange(occurrence, calendar: calendar)
        let full = Date.FormatStyle(date: .complete, time: .omitted, timeZone: timeZone)
        if range.first == range.last { return range.first.formatted(full) }
        let short = Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: timeZone)
        return "\(range.first.formatted(short)) – \(range.last.formatted(short))"
    }

    /// The event's times in the zone it was created in, when that is not the device's zone:
    /// "12:00 PM – 1:00 PM New York time". `nil` for all-day events, for events with no zone,
    /// and when the zones agree at the event's start.
    static func originalTimeZoneSummary(_ occurrence: EventOccurrence,
                                        deviceTimeZone: TimeZone = .current) -> String? {
        guard !occurrence.event.allDay,
              let identifier = occurrence.event.timezone,
              let zone = TimeZone(identifier: identifier),
              zone.secondsFromGMT(for: occurrence.start) != deviceTimeZone.secondsFromGMT(for: occurrence.start)
        else { return nil }
        let times = timeSummary(occurrence, timeZone: zone)
        let name = zone.localizedName(for: .generic, locale: .current) ?? identifier
        return "\(times) \(name)"
    }

    /// "Repeats weekly on Mon, Tue, Wed, Thu, Fri" for the rules the web editor writes and those
    /// shaped like them. A rule the expander cannot read is shown as written: this is a label,
    /// and a label that hides a rule is worse than one that looks technical.
    static func recurrenceSummary(_ rrule: String) -> String {
        guard let rule = RecurrenceExpander.Rule(parsing: rrule) else { return "Repeats (\(rrule))" }
        let interval = rule.interval ?? 1
        let unit: String
        switch rule.freq {
        case .daily:   unit = interval == 1 ? "daily" : "every \(interval) days"
        case .weekly:  unit = interval == 1 ? "weekly" : "every \(interval) weeks"
        case .monthly: unit = interval == 1 ? "monthly" : "every \(interval) months"
        case .yearly:  unit = interval == 1 ? "yearly" : "every \(interval) years"
        }
        var text = "Repeats \(unit)"
        if rule.freq == .weekly, let days = rule.byDay, !days.isEmpty {
            let symbols = Calendar.current.shortWeekdaySymbols
            text += " on " + days.map { symbols[$0] }.joined(separator: ", ")
        }
        if let count = rule.count { text += ", \(count) times" }
        if let until = rule.until {
            text += ", until " + until.formatted(date: .abbreviated, time: .omitted)
        }
        return text
    }
}
