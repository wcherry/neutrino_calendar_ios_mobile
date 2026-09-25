import Foundation

// MARK: - SmartAdd

/// RTM-style Smart Add: one typed line becomes a task and its fields.
///
///     Buy milk ^tomorrow 5pm !1 #errands *weekly =15min ~today @Safeway // semi-skimmed
///
/// `^date` due · `~date` start · `!1`–`!3` priority · `#word` tag · `*repeat` repeat ·
/// `=estimate` time estimate · `@place` location · `// text` note (rest of the line).
///
/// A date phrase with no `^` is also the due date — "call mom tomorrow 3pm", "pay rent by friday"
/// — as long as it reads unambiguously as a date: an abbreviation that is also a word ("tom",
/// "sat", "mon"), a bare ordinal or a slash date needs `^` or a leading on/by/due. Text in double
/// quotes is never parsed.
///
/// This is a port of the web's `smartAdd.ts` (`neutrino/web/apps/web/src/app/(apps)/calendar/`),
/// function for function, and both are tested against the same table:
/// `NeutrinoCalendarTests/Fixtures/smart_add_vectors.json`, a copy of the web's
/// `smartAddFixtures.json` refreshed by `scripts/sync_smart_add_vectors.sh`. Change the grammar in
/// both, and add the case to the web's table.
enum SmartAdd {

    /// What "today" and "now" are in the user's zone. Passed in so parsing is a pure function.
    struct Context: Equatable, Decodable {
        /// `YYYY-MM-DD`
        let today: String
        /// `HH:MM`
        let now: String

        static func current(_ date: Date = Date(), calendar: Calendar = .current) -> Context {
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            return Context(today: String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!),
                           now: String(format: "%02d:%02d", c.hour!, c.minute!))
        }
    }

    // MARK: Parsing

    static func parse(_ text: String, context: Context = .current()) -> SmartAddResult {
        var result = SmartAddResult()

        // "// note" runs to the end of the line; a URL's "://" is not one.
        var body = text
        if let marker = text.range(of: #"(^|\s)//"#, options: .regularExpression),
           let slash = text.range(of: "//", range: marker.lowerBound..<text.endIndex) {
            let note = text[slash.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            result.note = note.isEmpty ? nil : note
            body = String(text[..<slash.lowerBound])
        }

        var words = tokenize(body)

        // The phrase a prefixed token reads: the rest of its own word, then the words after it.
        func phrase(_ i: Int) -> (w: [String], offset: Int) {
            let first = String(words[i].norm.dropFirst())
            let rest = words[(i + 1)...].map { $0.used || $0.quoted ? "\u{0}" : $0.norm }
            return first.isEmpty ? (Array(rest), 1) : ([first] + rest, 0)
        }
        func consume(_ i: Int, _ n: Int, _ offset: Int) {
            var k = i
            while k < i + n + offset && k < words.count {
                words[k].used = true
                k += 1
            }
        }

        // Pass 1: the prefixed tokens.
        for i in words.indices {
            let word = words[i]
            if word.used || word.quoted { continue }
            let sigil = word.norm.first

            if let m = firstMatch(#"^!([123])$"#, word.norm), let p = m[1], let priority = Int(p) {
                result.priority = priority
                words[i].used = true
            } else if sigil == "#", firstMatch(#"^#[\p{L}_][\p{L}\p{N}_\-/.]*$"#, word.norm) != nil {
                let tag = String(word.norm.dropFirst())
                if !result.tags.contains(tag) { result.tags.append(tag) }
                words[i].used = true
            } else if sigil == "@", word.norm.count > 1, !word.raw.dropFirst().contains("@") {
                result.location = String(word.raw.dropFirst())
                    .replacingOccurrences(of: #"[.,;:!?)]+$"#, with: "", options: .regularExpression)
                words[i].used = true
            } else if sigil == "^" || sigil == "~" {
                let (w, offset) = phrase(i)
                if let match = matchDate(w, 0, context, bare: false) {
                    if sigil == "^" { result.due = match.value } else { result.start = match.value }
                    consume(i, match.n, offset)
                    if offset == 0 { words[i].used = true }
                }
            } else if sigil == "*" {
                let (w, offset) = phrase(i)
                if let match = matchRepeat(w, 0) {
                    result.recurrenceRule = match.rule
                    result.repeatAfterCompletion = match.after
                    consume(i, match.n, offset)
                    words[i].used = true
                }
            } else if sigil == "=" {
                let (w, offset) = phrase(i)
                if let match = matchEstimate(w, 0) {
                    result.estimateMinutes = match.minutes
                    consume(i, match.n, offset)
                    words[i].used = true
                }
            }
        }

        // Pass 2: an un-prefixed date phrase, when there was no ^ — the first that reads as a date.
        if result.due == nil {
            for i in words.indices where !words[i].used && !words[i].quoted {
                // A run of free words: a date phrase must not reach across a token or into quotes.
                var end = i
                while end < words.count && !words[end].used && !words[end].quoted { end += 1 }
                let w = words[i..<end].map(\.norm)
                if let match = matchDate(Array(w), 0, context, bare: true) {
                    result.due = match.value
                    consume(i, match.n, 0)
                    break
                }
            }
        }

        // A repeat with no due date starts on its first occurrence.
        if let rule = result.recurrenceRule, result.due == nil {
            let today = YMD(context.today)
            var first = today
            if let m = firstMatch(#"BYDAY=([A-Z,]+)"#, rule), let byDay = m[1] {
                first = byDay.split(separator: ",")
                    .compactMap { rruleDays.firstIndex(of: String($0)) }
                    .map { onOrAfter(today, $0) }
                    .min() ?? today
            }
            result.due = SmartDate(date: first.formatted, time: nil)
        }

        result.title = words.filter { !$0.used }.map(\.raw).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return result
    }

    // MARK: Single fields

    /// "every other week", "after 2 weeks", "weekly" — with or without the `*`.
    static func parseRepeat(_ text: String) -> (rule: String, after: Bool)? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("*") { trimmed.removeFirst() }
        let w = trimmed.split(whereSeparator: \.isWhitespace).map { normalise(String($0)) }
        guard !w.isEmpty, let match = matchRepeat(w, 0), match.n == w.count else { return nil }
        return (match.rule, match.after)
    }

    /// "1h 30m", "45m", "2h".
    static func formatEstimate(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return [h > 0 ? "\(h)h" : "", m > 0 || h == 0 ? "\(m)m" : ""].filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A rule in the words Smart Add reads it from: "every 2 weeks", "every Mon, Thu", "after 6
    /// weeks". The web's `describeRepeat`.
    static func describeRepeat(_ rule: String, after: Bool) -> String {
        var parts: [String: String] = [:]
        for part in rule.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2, !kv[0].isEmpty, !kv[1].isEmpty { parts[kv[0]] = kv[1] }
        }
        let unitNames = ["DAILY": "day", "WEEKLY": "week", "MONTHLY": "month", "YEARLY": "year"]
        guard let freq = parts["FREQ"], let unit = unitNames[freq] else { return rule }
        let interval = parts["INTERVAL"].flatMap { Int($0) }.flatMap { $0 == 0 ? nil : $0 } ?? 1
        var text: String
        if let byDay = parts["BYDAY"] {
            let days = byDay.split(separator: ",").compactMap {
                rruleDays.firstIndex(of: String($0.filter { $0.isLetter && $0.isUppercase }))
            }
            let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let list = days == [1, 2, 3, 4, 5] ? "weekday"
                : days == [6, 0] ? "weekend"
                : days.map { names[$0] }.joined(separator: ", ")
            text = "every \(interval == 2 ? "other " : "")\(list)"
        } else {
            let every = interval == 1 ? unit
                : interval == 2 && !after ? "other \(unit)" : "\(interval) \(unit)s"
            text = "\(after ? "after" : "every") \(after && interval == 1 ? "a \(unit)" : every)"
        }
        if let count = parts["COUNT"] { text += " for \(count) times" }
        return text
    }

    // MARK: To the wire

    /// A parsed date as the server stores it: a date-only value is `<day>T00:00:00Z` (read back in
    /// UTC, so it names the same day everywhere), a timed one is the instant in `calendar`'s zone.
    static func wire(_ value: SmartDate, calendar: Calendar = .current) -> (iso: String, hasTime: Bool) {
        guard let time = value.time else { return ("\(value.date)T00:00:00Z", false) }
        let d = YMD(value.date)
        let hm = time.split(separator: ":").compactMap { Int($0) }
        let components = DateComponents(year: d.y, month: d.m, day: d.d, hour: hm[0], minute: hm[1])
        guard let instant = calendar.date(from: components) else { return ("\(value.date)T00:00:00Z", false) }
        return (ServerDate.format(instant), true)
    }

    /// The create request for a parsed line. Only what was typed is sent, so a plain title is
    /// still just `{ title }`.
    static func request(for result: SmartAddResult, calendar: Calendar = .current) -> CreateTaskRequest {
        var request = CreateTaskRequest(title: result.title)
        request.notes = result.note
        if let due = result.due {
            let (iso, hasTime) = wire(due, calendar: calendar)
            request.dueDate = iso
            request.dueHasTime = hasTime ? true : nil
        }
        if let start = result.start {
            let (iso, hasTime) = wire(start, calendar: calendar)
            request.startDate = iso
            request.startHasTime = hasTime ? true : nil
        }
        request.priority = result.priority
        request.tags = result.tags.isEmpty ? nil : result.tags
        if let rule = result.recurrenceRule {
            request.recurrenceRule = rule
            request.repeatAfterCompletion = result.repeatAfterCompletion ? true : nil
        }
        request.estimateMinutes = result.estimateMinutes
        request.location = result.location
        return request
    }
}

// MARK: - SmartDate / SmartAddResult

/// A calendar date (`YYYY-MM-DD`) in the user's zone, and a 24-hour `HH:MM` or none.
struct SmartDate: Equatable, Decodable {
    let date: String
    let time: String?
}

struct SmartAddResult: Equatable {
    var title = ""
    var due: SmartDate?
    var start: SmartDate?
    var priority: Int?
    /// Lowercase, without `#`, in the order typed, no repeats.
    var tags: [String] = []
    /// An RRULE body the server's `calendar::recurrence` steps, e.g. `FREQ=WEEKLY;BYDAY=MO,TH`.
    var recurrenceRule: String?
    var repeatAfterCompletion = false
    var estimateMinutes: Int?
    var location: String?
    var note: String?

    /// Whether anything besides the title was found — what decides if a preview is worth showing.
    var hasDetails: Bool {
        due != nil || start != nil || priority != nil || !tags.isEmpty || recurrenceRule != nil
            || estimateMinutes != nil || location != nil || note != nil
    }
}

// MARK: - Calendar arithmetic on plain dates

/// A date with no zone, done in days since 1970-01-01 — the web does the same through
/// `Date.UTC`, and neither may depend on the device's calendar.
private struct YMD: Comparable {
    var y: Int, m: Int, d: Int

    init(y: Int, m: Int, d: Int) { self.y = y; self.m = m; self.d = d }

    init(_ s: String) {
        let p = s.split(separator: "-").compactMap { Int($0) }
        self.init(y: p[0], m: p[1], d: p[2])
    }

    /// Howard Hinnant's `days_from_civil`.
    var days: Int {
        let y2 = m <= 2 ? y - 1 : y
        let era = (y2 >= 0 ? y2 : y2 - 399) / 400
        let yoe = y2 - era * 400
        let doy = (153 * ((m + 9) % 12) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    init(days: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        self.init(y: yoe + era * 400 + (m <= 2 ? 1 : 0), m: m, d: d)
    }

    /// 0 = Sunday … 6 = Saturday. 1970-01-01 was a Thursday.
    var weekday: Int { ((days % 7) + 7 + 4) % 7 }

    var formatted: String { String(format: "%04d-%02d-%02d", y, m, d) }

    static func < (a: YMD, b: YMD) -> Bool { (a.y, a.m, a.d) < (b.y, b.m, b.d) }
}

private func daysInMonth(_ y: Int, _ m: Int) -> Int {
    switch m {
    case 2: return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 29 : 28
    case 4, 6, 9, 11: return 30
    default: return 31
    }
}

private func addDays(_ x: YMD, _ n: Int) -> YMD { YMD(days: x.days + n) }

/// Months clamp to the end of a shorter month: Jan 31 + 1 month is Feb 28.
private func addMonths(_ x: YMD, _ n: Int) -> YMD {
    let total = x.y * 12 + (x.m - 1) + n
    let y = Int((Double(total) / 12).rounded(.down))
    let m = total - y * 12 + 1
    return YMD(y: y, m: m, d: min(x.d, daysInMonth(y, m)))
}

private func isValidDate(_ y: Int, _ m: Int, _ d: Int) -> Bool {
    m >= 1 && m <= 12 && d >= 1 && d <= daysInMonth(y, m)
}

/// The first `weekday` on or after `from`.
private func onOrAfter(_ from: YMD, _ weekday: Int) -> YMD {
    addDays(from, (weekday - from.weekday + 7) % 7)
}

private func pad(_ n: Int) -> String { String(format: "%02d", n) }

// MARK: - Vocabulary

/// Full names are unambiguous; the abbreviations are also words ("sat", "sun", "wed").
private let weekdays: [String: (day: Int, strong: Bool)] = [
    "sunday": (0, true), "sun": (0, false),
    "monday": (1, true), "mon": (1, false),
    "tuesday": (2, true), "tue": (2, false), "tues": (2, false),
    "wednesday": (3, true), "wed": (3, false),
    "thursday": (4, true), "thu": (4, false), "thur": (4, false), "thurs": (4, false),
    "friday": (5, true), "fri": (5, false),
    "saturday": (6, true), "sat": (6, false),
]

private let months: [String: Int] = [
    "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4,
    "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8, "september": 9,
    "sep": 9, "sept": 9, "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
]

private enum Unit { case minute, hour, day, week, month, year }

private let units: [String: Unit] = [
    "min": .minute, "mins": .minute, "minute": .minute, "minutes": .minute,
    "h": .hour, "hr": .hour, "hrs": .hour, "hour": .hour, "hours": .hour,
    "day": .day, "days": .day, "week": .week, "weeks": .week, "wk": .week, "wks": .week,
    "month": .month, "months": .month, "year": .year, "years": .year, "yr": .year, "yrs": .year,
]

private let rruleDays = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

/// Words that may introduce an un-prefixed date and are dropped from the title with it.
private let connectors: Set<String> = ["on", "by", "due"]

private extension Array where Element == String {
    subscript(safe i: Int) -> String? { i >= 0 && i < count ? self[i] : nil }
}

/// The capture groups of `pattern`'s first match in `s` (index 0 is the whole match), or nil.
private func firstMatch(_ pattern: String, _ s: String) -> [String?]? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
    return (0..<m.numberOfRanges).map { i in
        Range(m.range(at: i), in: s).map { String(s[$0]) }
    }
}

// MARK: - Date phrases

private struct DatePart {
    var ymd: YMD
    /// Set by "in 2 hours", which names a time as well as a date.
    var time: String?
    var n: Int
    var strong: Bool
}

private struct TimePart {
    var time: String
    var n: Int
    var strong: Bool
}

private func parseCount(_ word: String?) -> Int? {
    guard let word else { return nil }
    if word == "a" || word == "an" || word == "one" { return 1 }
    return firstMatch(#"^\d{1,4}$"#, word) != nil ? Int(word) : nil
}

private func parseOrdinal(_ word: String?) -> Int? {
    guard let word, let m = firstMatch(#"^(\d{1,2})(st|nd|rd|th)?$"#, word), let n = m[1] else { return nil }
    return Int(n)
}

/// Monday of the week after `today`'s (weeks start on Monday).
private func nextWeekStart(_ today: YMD) -> YMD {
    addDays(today, 7 - (today.weekday + 6) % 7)
}

private func endOfMonth(_ today: YMD) -> YMD {
    YMD(y: today.y, m: today.m, d: daysInMonth(today.y, today.m))
}

private func datePart(_ w: [String], _ j: Int, _ today: YMD, _ now: String) -> DatePart? {
    guard let a = w[safe: j] else { return nil }
    let b = w[safe: j + 1]

    switch a {
    case "today", "tonight": return DatePart(ymd: today, n: 1, strong: true)
    case "tod": return DatePart(ymd: today, n: 1, strong: false)
    case "tomorrow", "tmrw": return DatePart(ymd: addDays(today, 1), n: 1, strong: true)
    case "tom", "tmr": return DatePart(ymd: addDays(today, 1), n: 1, strong: false)
    case "eom": return DatePart(ymd: endOfMonth(today), n: 1, strong: true)
    default: break
    }
    if a == "day" && b == "after" && w[safe: j + 2] == "tomorrow" {
        return DatePart(ymd: addDays(today, 2), n: 3, strong: true)
    }
    if a == "end" && b == "of" {
        let k = w[safe: j + 2] == "the" ? j + 3 : j + 2
        if w[safe: k] == "month" { return DatePart(ymd: endOfMonth(today), n: k - j + 1, strong: true) }
    }

    if a == "this" || a == "next" {
        if let wd = b.flatMap({ weekdays[$0] }) {
            let ymd = a == "this"
                ? onOrAfter(today, wd.day)
                : addDays(nextWeekStart(today), (wd.day + 6) % 7)
            return DatePart(ymd: ymd, n: 2, strong: true)
        }
        if a == "next" {
            if b == "week" { return DatePart(ymd: addDays(today, 7), n: 2, strong: true) }
            if b == "month" { return DatePart(ymd: addMonths(today, 1), n: 2, strong: true) }
            if b == "year" { return DatePart(ymd: addMonths(today, 12), n: 2, strong: true) }
        }
        return nil
    }

    if let wd = weekdays[a] { return DatePart(ymd: onOrAfter(today, wd.day), n: 1, strong: wd.strong) }

    // "in 3 days", "in a week", "in 2 hours"; "3 days" without "in" only when prefixed.
    let hasIn = a == "in"
    if let count = parseCount(hasIn ? b : a),
       let unit = (hasIn ? w[safe: j + 2] : b).flatMap({ units[$0] }),
       hasIn || !["a", "an", "one"].contains(a) {
        let n = hasIn ? 3 : 2
        switch unit {
        case .day: return DatePart(ymd: addDays(today, count), n: n, strong: hasIn)
        case .week: return DatePart(ymd: addDays(today, 7 * count), n: n, strong: hasIn)
        case .month: return DatePart(ymd: addMonths(today, count), n: n, strong: hasIn)
        case .year: return DatePart(ymd: addMonths(today, 12 * count), n: n, strong: hasIn)
        case .hour, .minute:
            let hm = now.split(separator: ":").compactMap { Int($0) }
            let total = hm[0] * 60 + hm[1] + count * (unit == .hour ? 60 : 1)
            let rest = total % 1440
            return DatePart(ymd: addDays(today, total / 1440), time: "\(pad(rest / 60)):\(pad(rest % 60))",
                            n: n, strong: hasIn)
        }
    }

    // 2026-10-03
    if let m = firstMatch(#"^(\d{4})-(\d{1,2})-(\d{1,2})$"#, a),
       let y = Int(m[1]!), let mo = Int(m[2]!), let d = Int(m[3]!) {
        return isValidDate(y, mo, d) ? DatePart(ymd: YMD(y: y, m: mo, d: d), n: 1, strong: true) : nil
    }

    // 10/3, 10/3/27, 10/3/2027 — month first.
    if let m = firstMatch(#"^(\d{1,2})/(\d{1,2})(?:/(\d{2}|\d{4}))?$"#, a),
       let mo = Int(m[1]!), let d = Int(m[2]!) {
        let y = m[3].map { $0.count == 2 ? 2000 + Int($0)! : Int($0)! }
        return resolveMonthDay(mo, d, y, today).map { DatePart(ymd: $0, n: 1, strong: false) }
    }

    // "oct 3", "october 3rd", "oct 3 2027"
    if let month = months[a] {
        guard let d = parseOrdinal(b) else { return nil }
        let year = w[safe: j + 2].flatMap { firstMatch(#"^\d{4}$"#, $0) != nil ? Int($0) : nil }
        return resolveMonthDay(month, d, year, today)
            .map { DatePart(ymd: $0, n: year != nil ? 3 : 2, strong: true) }
    }

    // "3 oct", "3rd of october", "the 15th"
    let skipThe = a == "the" ? 1 : 0
    if let day = parseOrdinal(w[safe: j + skipThe]) {
        var k = j + skipThe + 1
        if w[safe: k] == "of" { k += 1 }
        if let m = w[safe: k].flatMap({ months[$0] }) {
            let year = w[safe: k + 1].flatMap { firstMatch(#"^\d{4}$"#, $0) != nil ? Int($0) : nil }
            return resolveMonthDay(m, day, year, today)
                .map { DatePart(ymd: $0, n: k - j + 1 + (year != nil ? 1 : 0), strong: true) }
        }
        // A day of the month on its own: this month's, or next month's once it has passed.
        if firstMatch(#"\d(st|nd|rd|th)$"#, w[j + skipThe]) != nil && day >= 1 && day <= 31 {
            for i in 0..<12 {
                let base = addMonths(YMD(y: today.y, m: today.m, d: 1), i)
                let candidate = YMD(y: base.y, m: base.m, d: day)
                if day <= daysInMonth(base.y, base.m) && !(candidate < today) {
                    return DatePart(ymd: candidate, n: skipThe + 1, strong: false)
                }
            }
            return nil
        }
    }

    return nil
}

/// A month and day with no year is the next one on or after today.
private func resolveMonthDay(_ m: Int, _ d: Int, _ y: Int?, _ today: YMD) -> YMD? {
    if let y { return isValidDate(y, m, d) ? YMD(y: y, m: m, d: d) : nil }
    for year in today.y...(today.y + 4) where isValidDate(year, m, d) && !(YMD(y: year, m: m, d: d) < today) {
        return YMD(y: year, m: m, d: d)
    }
    return nil
}

private func timePart(_ w: [String], _ j: Int) -> TimePart? {
    let hasAt = w[safe: j] == "at" || w[safe: j] == "@"
    let k = hasAt ? j + 1 : j
    guard let a = w[safe: k] else { return nil }
    let used = hasAt ? 2 : 1

    if a == "noon" { return TimePart(time: "12:00", n: used, strong: hasAt) }
    if a == "midnight" { return TimePart(time: "00:00", n: used, strong: hasAt) }

    func ampm(_ h: Int, _ mi: Int, _ suffix: String) -> String? {
        guard h >= 1 && h <= 12 && mi <= 59 else { return nil }
        return "\(pad(h % 12 + (suffix.hasPrefix("p") ? 12 : 0))):\(pad(mi))"
    }

    // 3pm, 3:30pm, 3p
    if let m = firstMatch(#"^(\d{1,2})(?::(\d{2}))?(am|pm|a|p)$"#, a) {
        return ampm(Int(m[1]!)!, m[2].flatMap { Int($0) } ?? 0, m[3]!)
            .map { TimePart(time: $0, n: used, strong: true) }
    }
    // 3 pm, 3:30 pm
    if let m = firstMatch(#"^(\d{1,2})(?::(\d{2}))?$"#, a), let next = w[safe: k + 1], next == "am" || next == "pm" {
        return ampm(Int(m[1]!)!, m[2].flatMap { Int($0) } ?? 0, next)
            .map { TimePart(time: $0, n: used + 1, strong: true) }
    }
    // 15:00
    if let m = firstMatch(#"^(\d{1,2}):(\d{2})$"#, a), let h = Int(m[1]!), let mi = Int(m[2]!) {
        return h <= 23 && mi <= 59 ? TimePart(time: "\(pad(h)):\(pad(mi))", n: used, strong: true) : nil
    }
    return nil
}

private struct DateMatch {
    var value: SmartDate
    var n: Int
}

/// The longest date phrase at `w[j]`: a date, a time, or both in either order. `bare` is for text
/// with no `^`, where every part must be unambiguous — unless an on/by/due introduced it.
private func matchDate(_ w: [String], _ j: Int, _ ctx: SmartAdd.Context, bare: Bool) -> DateMatch? {
    let today = YMD(ctx.today)
    let lead = connectors.contains(w[safe: j] ?? "") ? 1 : 0
    let start = j + lead
    func ok(_ strong: Bool) -> Bool { !bare || strong || lead == 1 }

    var candidates: [DateMatch] = []

    if let d = datePart(w, start, today, ctx.now), ok(d.strong) {
        let t = d.time == nil ? timePart(w, start + d.n) : nil
        let withTime = t.flatMap { ok($0.strong) ? $0 : nil }
        candidates.append(DateMatch(value: SmartDate(date: d.ymd.formatted, time: d.time ?? withTime?.time),
                                    n: lead + d.n + (withTime?.n ?? 0)))
    }

    if let t = timePart(w, start), ok(t.strong) {
        if let after = datePart(w, start + t.n, today, ctx.now), after.time == nil, ok(after.strong) {
            candidates.append(DateMatch(value: SmartDate(date: after.ymd.formatted, time: t.time),
                                        n: lead + t.n + after.n))
        } else {
            // A time on its own is today's, or tomorrow's once it has gone by.
            let date = t.time > ctx.now ? today : addDays(today, 1)
            candidates.append(DateMatch(value: SmartDate(date: date.formatted, time: t.time), n: lead + t.n))
        }
    }

    return candidates.reduce(nil as DateMatch?) { best, c in best.map { c.n > $0.n ? c : $0 } ?? c }
}

// MARK: - Repeat phrases

private struct RepeatMatch {
    var rule: String
    var after: Bool
    var n: Int
}

private func buildRule(_ freq: String, _ interval: Int, _ byDay: [Int]?, _ count: Int?) -> String {
    var parts = ["FREQ=\(freq)"]
    if interval > 1 { parts.append("INTERVAL=\(interval)") }
    if let byDay {
        var seen = Set<Int>()
        let days = byDay.filter { seen.insert($0).inserted }.sorted { ($0 + 6) % 7 < ($1 + 6) % 7 }
        parts.append("BYDAY=" + days.map { rruleDays[$0] }.joined(separator: ","))
    }
    if let count { parts.append("COUNT=\(count)") }
    return parts.joined(separator: ";")
}

/// "mon", "mon,wed", "mon and wed", "mon, wed and fri" — weekday names, any abbreviation.
private func weekdayList(_ w: [String], _ j: Int) -> (days: [Int], n: Int)? {
    func pieces(_ word: String) -> [String] { word.split(separator: ",").map(String.init) }
    var days: [Int] = []
    var k = j
    while k < w.count {
        let p = pieces(w[k])
        if p.isEmpty || !p.allSatisfy({ weekdays[$0] != nil }) { break }
        days += p.map { weekdays[$0]!.day }
        k += 1
        if w[safe: k] == "and", let next = w[safe: k + 1], !pieces(next).isEmpty,
           pieces(next).allSatisfy({ weekdays[$0] != nil }) {
            k += 1
        }
    }
    return days.isEmpty ? nil : (days, k - j)
}

private func matchRepeat(_ w: [String], _ j: Int) -> RepeatMatch? {
    guard let a = w[safe: j] else { return nil }
    var freq: String?
    var interval = 1
    var byDay: [Int]?
    var after = false
    var n = 0

    let simple: [String: (String, Int)] = [
        "daily": ("DAILY", 1), "weekly": ("WEEKLY", 1), "monthly": ("MONTHLY", 1),
        "yearly": ("YEARLY", 1), "annually": ("YEARLY", 1), "biweekly": ("WEEKLY", 2),
        "fortnightly": ("WEEKLY", 2),
    ]
    let freqs: [Unit: String] = [.day: "DAILY", .week: "WEEKLY", .month: "MONTHLY", .year: "YEARLY"]

    if let s = simple[a] {
        (freq, interval) = (s.0, s.1)
        n = 1
    } else if a == "weekdays" {
        freq = "WEEKLY"
        byDay = [1, 2, 3, 4, 5]
        n = 1
    } else if a == "every" || a == "after" {
        after = a == "after"
        var k = j + 1
        if !after && w[safe: k] == "other" {
            interval = 2
            k += 1
        } else if let count = parseCount(w[safe: k]), w[safe: k + 1].flatMap({ units[$0] }) != nil {
            interval = count
            k += 1
        }
        if let unit = w[safe: k].flatMap({ units[$0] }), let f = freqs[unit] {
            freq = f
            n = k - j + 1
        } else if !after && (w[safe: k] == "weekday" || w[safe: k] == "weekdays") && interval == 1 {
            freq = "WEEKLY"
            byDay = [1, 2, 3, 4, 5]
            n = k - j + 1
        } else if !after && (w[safe: k] == "weekend" || w[safe: k] == "weekends") && interval == 1 {
            freq = "WEEKLY"
            byDay = [6, 0]
            n = k - j + 1
        } else if !after, let list = weekdayList(w, k), interval == 1 || interval == 2 {
            freq = "WEEKLY"
            byDay = list.days
            n = k - j + list.n
        }
    }
    guard let freq else { return nil }

    // "for 5 times"
    var count: Int?
    if w[safe: j + n] == "for", let c = parseCount(w[safe: j + n + 1]), c > 0,
       w[safe: j + n + 2] == "times" || w[safe: j + n + 2] == "time" {
        count = c
        n += 3
    }
    return RepeatMatch(rule: buildRule(freq, interval, byDay, count), after: after, n: n)
}

// MARK: - Estimates

private let estimatePattern =
    #"^(?:(\d+(?:\.\d+)?)\s*(?:h|hr|hrs|hour|hours))?\s*(?:(\d+)\s*(?:m|min|mins|minute|minutes))?$"#

private func matchEstimate(_ w: [String], _ j: Int) -> (minutes: Int, n: Int)? {
    var len = min(4, w.count - j)
    while len >= 1 {
        let text = w[j..<(j + len)].joined(separator: " ")
        if let m = firstMatch(estimatePattern, text), m[1] != nil || m[2] != nil {
            let hours = m[1].flatMap { Double($0) } ?? 0
            let minutes = m[2].flatMap { Int($0) } ?? 0
            return (Int((hours * 60).rounded()) + minutes, len)
        }
        len -= 1
    }
    return nil
}

// MARK: - Words

private struct Word {
    var raw: String
    /// Lowercased, trailing punctuation removed — what the grammar reads.
    var norm: String
    /// Inside "double quotes": title text, never a token.
    var quoted: Bool
    var used = false
}

private func normalise(_ raw: String) -> String {
    raw.lowercased()
        .replacingOccurrences(of: #"[.,;:!?)]+$"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"^\(+"#, with: "", options: .regularExpression)
}

private func tokenize(_ text: String) -> [Word] {
    var words: [Word] = []
    var quoted = false
    for piece in text.split(whereSeparator: \.isWhitespace) {
        let raw = String(piece)
        let inQuote = quoted || raw.hasPrefix("\"")
        if raw.filter({ $0 == "\"" }).count % 2 == 1 { quoted.toggle() }
        words.append(Word(raw: raw, norm: normalise(raw), quoted: inQuote))
    }
    return words
}
