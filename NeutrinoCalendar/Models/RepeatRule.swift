import Foundation

/// An event's RRULE as the event form edits it: how often (FREQ and INTERVAL — "every 3 days")
/// and when it stops (never, on a date, or after a number of occurrences).
///
/// **A port of the web's `repeatRule.ts`**, held to the same `repeatRuleFixtures.json`
/// (`scripts/sync_repeat_rule_vectors.sh` copies it here): each client expands the rules the
/// other writes, so they must write the same strings.
///
///     FREQ=WEEKLY[;INTERVAL=n][;BYDAY=…][;any other part, as it was][;COUNT=n | ;UNTIL=…]
///
/// - INTERVAL only when it isn't 1, so the plain choices stay the strings `RepeatOption` has.
/// - UNTIL is always a UTC date-time: every expander in the platform (both clients and the
///   server's `calendar::recurrence`) ignores a bare date. For a timed event it is the last second
///   of the chosen day in the event's zone; for an all-day event it is `T235959Z`, the form the
///   all-day end itself is stored in.
/// - A rule this can't represent faithfully — no or unknown FREQ, a part without `=`, an INTERVAL
///   or COUNT that isn't a positive number, both COUNT and UNTIL — doesn't parse, and the form
///   leaves it exactly as it was.
struct RepeatRule: Equatable {

    enum Frequency: String, CaseIterable {
        case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY"

        /// "day" or "days", for "Every 3 days".
        func unit(_ interval: Int) -> String {
            let unit: String
            switch self {
            case .daily:   unit = "day"
            case .weekly:  unit = "week"
            case .monthly: unit = "month"
            case .yearly:  unit = "year"
            }
            return interval == 1 ? unit : unit + "s"
        }
    }

    /// A calendar date with no zone: the last day a repeat may fall on.
    struct Day: Hashable, Comparable {
        let year: Int, month: Int, day: Int

        init(year: Int, month: Int, day: Int) {
            self.year = year; self.month = month; self.day = day
        }

        /// The day `date` falls on in `timeZone`.
        init(_ date: Date, in timeZone: TimeZone) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let d = calendar.dateComponents([.year, .month, .day], from: date)
            self.init(year: d.year!, month: d.month!, day: d.day!)
        }

        /// Midnight starting the day in `timeZone`.
        func date(in timeZone: TimeZone) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return calendar.date(from: DateComponents(year: year, month: month, day: day))!
        }

        func adding(_ component: Calendar.Component, _ n: Int) -> Day {
            let utc = TimeZone(identifier: "UTC")!
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = utc
            return Day(calendar.date(byAdding: component, value: n, to: date(in: utc))!, in: utc)
        }

        /// `yyyy-MM-dd`.
        var string: String { String(format: "%04d-%02d-%02d", year, month, day) }

        static func < (a: Day, b: Day) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
    }

    enum End: Equatable {
        case never
        /// The last day an occurrence may fall on, inclusive.
        case on(Day)
        case after(Int)
    }

    /// Whether the event is all-day, and the zone its times are entered in.
    struct Context {
        let allDay: Bool
        let timeZone: TimeZone
    }

    static let weekdaysByDay = "MO,TU,WE,TH,FR"
    static let maxNumber = 999

    var frequency: Frequency
    var interval = 1
    /// BYDAY as written, e.g. `MO,TU,WE,TH,FR`.
    var byDay: String?
    var end: End = .never
    /// Every other part (BYMONTHDAY, WKST…), as written, in order.
    var extra: [String] = []

    init(frequency: Frequency, interval: Int = 1, byDay: String? = nil, end: End = .never, extra: [String] = []) {
        self.frequency = frequency
        self.interval = interval
        self.byDay = byDay
        self.end = end
        self.extra = extra
    }

    init?(parsing rule: String, context: Context) {
        var frequency: Frequency?
        var interval = 1
        var byDay: String?
        var count: Int?
        var until: Day?
        var extra: [String] = []

        for part in rule.components(separatedBy: ";") where !part.isEmpty {
            guard let eq = part.firstIndex(of: "="), eq != part.startIndex else { return nil }
            let key = part[..<eq].uppercased()
            let value = String(part[part.index(after: eq)...])
            switch key {
            case "FREQ":
                guard let f = Frequency(rawValue: value.uppercased()) else { return nil }
                frequency = f
            case "INTERVAL":
                guard let n = Self.positive(value) else { return nil }
                interval = n
            case "COUNT":
                guard let n = Self.positive(value) else { return nil }
                count = n
            case "UNTIL":
                guard let day = Self.untilDay(value, context: context) else { return nil }
                until = day
            case "BYDAY":
                byDay = value.uppercased()
            default:
                extra.append(part)
            }
        }
        guard let frequency, count == nil || until == nil else { return nil }
        self.frequency = frequency
        self.interval = interval
        self.byDay = byDay
        self.extra = extra
        if let count { end = .after(count) } else if let until { end = .on(until) } else { end = .never }
    }

    func rule(context: Context) -> String {
        var parts = ["FREQ=\(frequency.rawValue)"]
        if interval > 1 { parts.append("INTERVAL=\(interval)") }
        if let byDay, !byDay.isEmpty { parts.append("BYDAY=\(byDay)") }
        parts += extra
        switch end {
        case .never:            break
        case .after(let count): parts.append("COUNT=\(count)")
        case .on(let day):      parts.append("UNTIL=\(Self.untilValue(day, context: context))")
        }
        return parts.joined(separator: ";")
    }

    // MARK: - The form's choices

    /// The `RepeatOption` a rule is shown under: its FREQ, or Every Weekday. A weekly rule on other
    /// days ("every Mon and Thu", from Smart Add) shows as Weekly and keeps its days.
    var preset: RepeatOption {
        switch frequency {
        case .daily:   return .daily
        case .weekly:  return byDay == Self.weekdaysByDay ? .weekdays : .weekly
        case .monthly: return .monthly
        case .yearly:  return .yearly
        }
    }

    /// `rule` after picking `preset`. Picking the choice it already shows changes nothing; picking
    /// another keeps the interval and the end, and drops the days and any other parts, which
    /// belonged to the old frequency.
    static func with(_ preset: RepeatOption, from rule: RepeatRule?) -> RepeatRule? {
        let frequency: Frequency
        switch preset {
        case .never, .custom:     return nil
        case .daily:              frequency = .daily
        case .weekdays, .weekly:  frequency = .weekly
        case .monthly:            frequency = .monthly
        case .yearly:             frequency = .yearly
        }
        if let rule, rule.preset == preset { return rule }
        return RepeatRule(frequency: frequency, interval: rule?.interval ?? 1,
                          byDay: preset == .weekdays ? weekdaysByDay : nil, end: rule?.end ?? .never)
    }

    /// A sensible end date to offer when the user picks "On Date": a month or a year after `start`.
    static func defaultEndDay(after start: Day, frequency: Frequency) -> Day {
        frequency == .monthly || frequency == .yearly ? start.adding(.year, 1) : start.adding(.month, 1)
    }

    // MARK: - UNTIL

    private static func positive(_ s: String) -> Int? {
        guard !s.isEmpty, s.allSatisfy(\.isASCII), s.allSatisfy(\.isNumber), let n = Int(s), n >= 1 else { return nil }
        return n
    }

    /// An UNTIL value as the day it ends on, or nil when it isn't one.
    private static func untilDay(_ value: String, context: Context) -> Day? {
        let v = value.uppercased()
        let digits = v.filter(\.isNumber)
        let shapeOK = (v.count == 8 && digits.count == 8)
            || (digits.count == 14 && v.count >= 15 && v.count <= 16 && Array(v)[8] == "T" && (v.count == 15 || v.hasSuffix("Z")))
        guard shapeOK else { return nil }
        let n = digits.map { Int(String($0))! }
        func num(_ from: Int, _ len: Int) -> Int { n[from..<(from + len)].reduce(0) { $0 * 10 + $1 } }
        let day = Day(year: num(0, 4), month: num(4, 2), day: num(6, 2))
        // A bare date, a floating date-time, or an all-day event: the day as written.
        guard v.hasSuffix("Z"), !context.allDay else { return day }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let instant = utc.date(from: DateComponents(year: day.year, month: day.month, day: day.day,
                                                    hour: num(8, 2), minute: num(10, 2), second: num(12, 2)))!
        return Day(instant, in: context.timeZone)
    }

    private static func untilValue(_ day: Day, context: Context) -> String {
        let compact = String(format: "%04d%02d%02d", day.year, day.month, day.day)
        if context.allDay { return compact + "T235959Z" }
        // The last second of the day in the event's zone.
        let last = day.adding(.day, 1).date(in: context.timeZone).addingTimeInterval(-1)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: last)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }
}
