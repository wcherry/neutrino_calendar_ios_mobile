import Foundation

// MARK: - EventOccurrence

/// One appearance of an event on the calendar. A plain event has one; a recurring one has one per
/// repetition, each sharing the event's id, so the id alone cannot key a list row.
struct EventOccurrence: Identifiable, Hashable {
    let event: CalendarEvent
    let start: Date
    let end: Date

    var id: String { "\(event.id)@\(start.timeIntervalSince1970)" }
}

// MARK: - RecurrenceExpander

/// Turns events and their RRULEs into the occurrences inside a range.
///
/// **A port of the web's `expandRecurringEvents`, not an RFC 5545 implementation.** The two
/// clients show one calendar, so they have to agree on where a repeating event falls, and today
/// that means agreeing with `calendarHelpers.ts` where it departs from the RFC. Each departure is
/// kept on purpose and pinned by `RecurrenceVectorTests`, whose expected values are produced by
/// running the web's own code (`scripts/generate_recurrence_vectors.mjs`):
///
/// - Repetitions step in the *viewer's* time zone, keeping the wall-clock time across DST. The
///   event's own `timezone` is ignored.
/// - MONTHLY and YEARLY overflow instead of clamping: Jan 31 → Mar 3, Feb 29 → Mar 1, and every
///   later repetition keeps the drifted day.
/// - COUNT counts FREQ steps, not occurrences, so `FREQ=WEEKLY;BYDAY=TU,TH;COUNT=2` gives four.
/// - BYDAY applies to WEEKLY only, and reaches forward from each step's date, never back.
/// - A date-only UNTIL (`UNTIL=20260930`) is unreadable to the web and so is ignored.
/// - A rule that does not parse (an `RRULE:` prefix, an unknown FREQ) shows the event once, as
///   written.
/// - Expansion gives up after 1000 steps from the first occurrence, so a daily event that began
///   three years ago shows nothing.
/// - An occurrence belongs to the range when it *starts* inside it.
///
/// Fixing any of these means fixing both clients together, with the vectors regenerated.
enum RecurrenceExpander {

    /// The web's `MAX_OCCURRENCES`, which bounds FREQ steps rather than occurrences.
    static let maxSteps = 1000

    static func expand(_ events: [CalendarEvent], from: Date, to: Date,
                       calendar: Calendar = .current) -> [EventOccurrence] {
        var result: [EventOccurrence] = []
        for event in events {
            guard let raw = event.recurrenceRule, !raw.isEmpty, let rule = Rule(parsing: raw) else {
                result.append(EventOccurrence(event: event, start: event.start, end: event.end))
                continue
            }
            result += occurrences(of: event, rule: rule, from: from, to: to, calendar: calendar)
        }
        return result
    }

    private static func occurrences(of event: CalendarEvent, rule: Rule, from: Date, to: Date,
                                    calendar: Calendar) -> [EventOccurrence] {
        let dtStart = event.start
        let duration = event.end.timeIntervalSince(event.start)
        var result: [EventOccurrence] = []
        var current = dtStart
        var steps = 0

        while current <= to && steps < maxSteps {
            if let count = rule.count, steps >= count { break }
            if let until = rule.until, current > until { break }

            let weekday = calendar.jsDay(of: current)
            let targets = rule.freq == .weekly ? (rule.byDay ?? [weekday]) : [weekday]
            for target in targets {
                let occurrence = calendar.shifting(current, .day, by: ((target - weekday) + 7) % 7)
                if occurrence < dtStart { continue }
                if occurrence > to { continue }
                if let until = rule.until, occurrence > until { continue }
                if occurrence >= from {
                    result.append(EventOccurrence(event: event, start: occurrence,
                                                  end: occurrence.addingTimeInterval(duration)))
                }
            }

            // An INTERVAL the web's `parseInt` cannot read turns its date invalid here, which
            // ends the loop after this first pass.
            guard let interval = rule.interval else { break }
            current = calendar.shifting(current, rule.freq.component, by: rule.freq.multiplier * interval)
            steps += 1
        }
        return result
    }

    // MARK: - Rule

    enum Frequency: String {
        case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY"

        var component: Calendar.Component {
            switch self {
            case .daily, .weekly: return .day
            case .monthly:        return .month
            case .yearly:         return .year
            }
        }

        var multiplier: Int { self == .weekly ? 7 : 1 }
    }

    /// The web's `parseRRule`, including what it tolerates and what it silently drops.
    struct Rule: Equatable {
        let freq: Frequency
        /// `nil` when INTERVAL is present but not a number.
        let interval: Int?
        /// `nil` when absent *or* unreadable: the web compares against NaN, which never stops it.
        let count: Int?
        let until: Date?
        /// Days 0 (Sunday) to 6 (Saturday); `nil` when BYDAY is absent.
        let byDay: [Int]?

        private static let dayNumbers = ["SU": 0, "MO": 1, "TU": 2, "WE": 3, "TH": 4, "FR": 5, "SA": 6]

        init?(parsing rrule: String) {
            var parts: [String: String] = [:]
            for part in rrule.components(separatedBy: ";") {
                // `const [k, v] = part.split('=')`: the value is the text up to a second '=', if
                // there is one, and a part with no '=' at all is skipped.
                let pieces = part.components(separatedBy: "=")
                guard pieces.count >= 2, !pieces[0].isEmpty else { continue }
                parts[pieces[0].uppercased()] = pieces[1]
            }

            guard let freq = parts["FREQ"].flatMap(Frequency.init(rawValue:)) else { return nil }
            self.freq = freq
            // The web tests each value for truthiness first, so `INTERVAL=` or `BYDAY=` count as
            // absent rather than as unreadable.
            parts = parts.filter { !$0.value.isEmpty }
            interval = parts["INTERVAL"].map(Self.jsParseInt) ?? 1
            count = parts["COUNT"].flatMap(Self.jsParseInt)
            until = parts["UNTIL"].flatMap(Self.parseUntil)
            byDay = parts["BYDAY"].map { value in
                value.components(separatedBy: ",").compactMap { token in
                    Self.dayNumbers[token.filter { !"+-0123456789".contains($0) }]
                }
            }
        }

        /// JavaScript's `parseInt(s, 10)`: leading whitespace, an optional sign, then as many
        /// digits as there are. `"2abc"` is 2; `"abc"` is nil, standing in for NaN.
        static func jsParseInt(_ s: String) -> Int? {
            var rest = Substring(s.drop(while: { $0.isWhitespace }))
            var sign = 1
            if let first = rest.first, first == "+" || first == "-" {
                sign = first == "-" ? -1 : 1
                rest = rest.dropFirst()
            }
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
            return Int(digits).map { sign * $0 }
        }

        /// The web strips every `T` and `Z`, then only reads the result when it is fourteen digits
        /// — a UTC date-time. Anything else, a bare date included, becomes an invalid Date, which
        /// never compares greater than anything and so never stops the expansion.
        static func parseUntil(_ value: String) -> Date? {
            let digits = value.filter { $0 != "T" && $0 != "Z" }
            guard digits.count == 14, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            let n = Array(digits)
            func field(_ r: Range<Int>) -> Int { Int(String(n[r]))! }
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            return utc.date(from: DateComponents(year: field(0..<4), month: field(4..<6), day: field(6..<8),
                                                 hour: field(8..<10), minute: field(10..<12),
                                                 second: field(12..<14)))
        }
    }
}

// MARK: - JavaScript Date arithmetic

extension Calendar {

    /// `Date.getDay()`: 0 for Sunday through 6 for Saturday, in this calendar's time zone.
    func jsDay(of date: Date) -> Int {
        component(.weekday, from: date) - 1
    }

    /// `setDate(getDate() + n)`, `setMonth(…)` and `setFullYear(…)`: change one wall-clock field
    /// and let the rest normalise.
    ///
    /// Not `date(byAdding:)`, which clamps Jan 31 + 1 month to Feb 28 where JavaScript overflows
    /// to Mar 3. Rebuilding from components overflows exactly as JavaScript does, including
    /// through DST gaps and overlaps; `RecurrenceVectorTests` holds it to that.
    func shifting(_ date: Date, _ component: Calendar.Component, by value: Int) -> Date {
        var parts = dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        switch component {
        case .day:   parts.day! += value
        case .month: parts.month! += value
        case .year:  parts.year! += value
        default:     preconditionFailure("only day, month and year steps exist in an RRULE expansion")
        }
        return self.date(from: parts) ?? date
    }
}
