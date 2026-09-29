import Foundation

/// Reads an `.ics` file shared from Mail, Files or another app into a new event's form. Nothing
/// is saved: the editor opens with the event filled in and the user adds it, as the web's
/// "Import .ics" does. There is no server import yet (`POST /events/import-ics` is designed, not
/// built), so the parsing is done here.
///
/// The web's `parseIcs` reads every time as UTC. This one honours `TZID`, floating times, the
/// exclusive `DTEND` of an all-day event and `DURATION`, so an invite from Outlook lands at the
/// hour it says rather than hours off.
///
/// One event is read: the first `VEVENT` that isn't an override of a single occurrence
/// (`RECURRENCE-ID`). `EXDATE`, alarms and attachments are not carried over.
enum ICSImport {

    enum Failure: LocalizedError, Equatable {
        case unreadable
        case noEvent
        case cancelled

        var errorDescription: String? {
            switch self {
            case .unreadable: return "That file couldn't be read as a calendar file."
            case .noEvent:    return "That calendar file has no event in it."
            case .cancelled:  return "That file cancels an event rather than adding one."
            }
        }
    }

    /// Reads the file at `url`, which may be outside the sandbox (a file opened in place from
    /// Files) or a copy iOS put in the app's `Inbox`.
    static func draft(contentsOf url: URL, calendar: Calendar = .current) throws -> EventDraft {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { throw Failure.unreadable }
        return try draft(from: text, calendar: calendar)
    }

    /// The event in `text` as a new event's form. `calendar` supplies the zone for floating
    /// times and all-day dates.
    static func draft(from text: String, calendar: Calendar = .current) throws -> EventDraft {
        let file = ICSFile(text)
        guard file.components.contains(where: { $0.name == "VCALENDAR" || $0.name == "VEVENT" }) else {
            throw Failure.unreadable
        }
        if file.method == "CANCEL" { throw Failure.cancelled }

        let events = file.components.filter { $0.name == "VEVENT" }
        guard let event = events.first(where: { $0["RECURRENCE-ID"] == nil }) ?? events.first,
              let dtstart = event["DTSTART"],
              let start = file.time(dtstart, calendar: calendar)
        else { throw Failure.noEvent }

        var draft = EventDraft(newOn: Date(), calendar: calendar)
        draft.title = event["SUMMARY"].map { unescape($0.value) } ?? ""
        draft.location = event["LOCATION"].map { unescape($0.value) } ?? ""
        draft.notes = event["DESCRIPTION"].map { unescape($0.value) } ?? ""
        draft.allDay = start.isDate
        draft.timeZone = start.isDate ? calendar.timeZone : start.zone

        let end: Date
        if let dtend = event["DTEND"], let parsed = file.time(dtend, calendar: calendar) {
            end = parsed.date
        } else if let duration = event["DURATION"].flatMap({ Self.duration($0.value) }) {
            end = start.date.addingTimeInterval(duration)
        } else {
            // RFC 5545 §3.6.1: no end is one day for a date, and no time at all for a date-time.
            end = start.isDate ? start.date.addingTimeInterval(86_400) : start.date
        }

        draft.start = start.date
        if start.isDate {
            // The form holds an all-day event's *last* day; the file gives the day after it.
            var local = calendar
            local.timeZone = draft.timeZone
            let last = local.date(byAdding: .day, value: -1, to: end) ?? end
            draft.end = max(last, start.date)
        } else {
            draft.end = max(end, start.date)
        }

        if let rule = event["RRULE"]?.value, !rule.isEmpty {
            draft.repeatOption = RepeatOption(rule: rule)
        }
        for attendee in event.all("ATTENDEE") {
            guard let range = attendee.value.range(of: "mailto:", options: [.caseInsensitive, .anchored]) else { continue }
            draft.addAttendee(String(attendee.value[range.upperBound...]))
        }
        return draft
    }

    // MARK: - Values

    /// TEXT unescaping, RFC 5545 §3.3.11.
    static func unescape(_ s: String) -> String {
        var out = ""
        var escaping = false
        for c in s {
            if escaping {
                switch c {
                case "n", "N": out.append("\n")
                default:       out.append(c)   // \\ \, \;
                }
                escaping = false
            } else if c == "\\" {
                escaping = true
            } else {
                out.append(c)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `P1W`, `P1D`, `PT1H30M`, `-PT15M`: a DURATION value in seconds.
    static func duration(_ s: String) -> TimeInterval? {
        var rest = Substring(s.uppercased())
        var sign = 1.0
        if rest.first == "-" { sign = -1; rest = rest.dropFirst() } else if rest.first == "+" { rest = rest.dropFirst() }
        guard rest.first == "P" else { return nil }
        rest = rest.dropFirst()
        var total = 0.0, number = "", sawUnit = false
        for c in rest {
            if c.isNumber { number.append(c); continue }
            if c == "T" { continue }
            guard let n = Double(number) else { return nil }
            switch c {
            case "W": total += n * 604_800
            case "D": total += n * 86_400
            case "H": total += n * 3_600
            case "M": total += n * 60
            case "S": total += n
            default:  return nil
            }
            number = ""
            sawUnit = true
        }
        return sawUnit && number.isEmpty ? sign * total : nil
    }
}

// MARK: - ICSFile

/// The components and properties of an iCalendar file, flattened: each component keeps only its
/// own properties, so a `VALARM`'s `DESCRIPTION` doesn't become the event's notes.
struct ICSFile {

    struct Property {
        let name: String
        let params: [String: String]
        let value: String
    }

    struct Component {
        let name: String
        var properties: [Property] = []

        subscript(name: String) -> Property? { properties.first { $0.name == name } }
        func all(_ name: String) -> [Property] { properties.filter { $0.name == name } }
    }

    /// A DTSTART or DTEND, read.
    struct Time {
        let date: Date
        let isDate: Bool
        let zone: TimeZone
    }

    private(set) var components: [Component] = []

    init(_ text: String) {
        var stack: [Component] = []
        for line in Self.unfold(text) {
            guard let property = Self.parse(line) else { continue }
            switch property.name {
            case "BEGIN":
                stack.append(Component(name: property.value.uppercased()))
            case "END":
                if let done = stack.popLast() { components.append(done) }
            default:
                if stack.isEmpty { continue }
                stack[stack.count - 1].properties.append(property)
            }
        }
    }

    /// `REQUEST`, `PUBLISH`, `CANCEL`… from the calendar object, uppercased.
    var method: String? {
        components.first { $0.name == "VCALENDAR" }?["METHOD"]?.value.uppercased()
    }

    func time(_ property: Property, calendar: Calendar) -> Time? {
        let raw = property.value.trimmingCharacters(in: .whitespaces)
        let isDate = property.params["VALUE"]?.uppercased() == "DATE" || raw.count == 8
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 8,
              let year = Int(digits.prefix(4)),
              let month = Int(digits.dropFirst(4).prefix(2)),
              let day = Int(digits.dropFirst(6).prefix(2)) else { return nil }

        var parts = DateComponents(year: year, month: month, day: day)
        let zone: TimeZone
        if isDate {
            zone = calendar.timeZone
        } else {
            guard digits.count >= 12 else { return nil }
            parts.hour = Int(digits.dropFirst(8).prefix(2))
            parts.minute = Int(digits.dropFirst(10).prefix(2))
            parts.second = digits.count >= 14 ? Int(digits.dropFirst(12).prefix(2)) : 0
            if raw.uppercased().hasSuffix("Z") {
                zone = TimeZone(identifier: "UTC")!
            } else if let tzid = property.params["TZID"] {
                zone = timeZone(tzid) ?? calendar.timeZone
            } else {
                zone = calendar.timeZone   // floating: the same clock time wherever it's opened
            }
        }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = zone
        guard let date = gregorian.date(from: parts) else { return nil }
        // A UTC time is shown in the device's zone; a zoned one keeps its own, as it was sent.
        let shown = raw.uppercased().hasSuffix("Z") ? calendar.timeZone : zone
        return Time(date: date, isDate: isDate, zone: shown)
    }

    /// A `TZID` as a zone: an IANA name, the `X-LIC-LOCATION` of its `VTIMEZONE`, or one of the
    /// Windows names Outlook and Exchange send.
    func timeZone(_ tzid: String) -> TimeZone? {
        let id = tzid.hasPrefix("/") ? String(tzid.dropFirst()) : tzid
        if let zone = TimeZone(identifier: id) { return zone }
        if let location = components.first(where: { $0.name == "VTIMEZONE" && $0["TZID"]?.value == tzid })?["X-LIC-LOCATION"],
           let zone = TimeZone(identifier: location.value) { return zone }
        return Self.windowsZones[id].flatMap(TimeZone.init(identifier:))
    }

    // MARK: - Lexing

    /// RFC 5545 §3.1: a line starting with a space or tab continues the one before.
    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                lines.append(raw)
            }
        }
        return lines
    }

    /// `NAME;PARAM=a;PARAM="b:c":value`. The value starts at the first colon outside quotes, so a
    /// quoted `CN="Doe, Jane"` or `DELEGATED-FROM="mailto:…"` doesn't split it early.
    static func parse(_ line: String) -> Property? {
        var inQuotes = false
        var head = ""
        var valueStart: String.Index?
        for i in line.indices {
            let c = line[i]
            if c == "\"" { inQuotes.toggle() }
            if c == ":" && !inQuotes { valueStart = line.index(after: i); break }
            head.append(c)
        }
        guard let valueStart else { return nil }
        let pieces = head.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let name = pieces.first?.uppercased(), !name.isEmpty else { return nil }
        var params: [String: String] = [:]
        for piece in pieces.dropFirst() {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            let value = piece[piece.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            params[piece[..<eq].uppercased()] = value
        }
        return Property(name: name, params: params, value: String(line[valueStart...]))
    }

    /// The Windows zone names Exchange writes as `TZID`, to their IANA zones (CLDR
    /// `windowsZones.xml`, territory "001"). The common ones; anything else falls back to the
    /// device's zone, and the editor shows the time before anything is saved.
    static let windowsZones: [String: String] = [
        "Dateline Standard Time": "Etc/GMT+12",
        "Hawaiian Standard Time": "Pacific/Honolulu",
        "Alaskan Standard Time": "America/Anchorage",
        "Pacific Standard Time": "America/Los_Angeles",
        "US Mountain Standard Time": "America/Phoenix",
        "Mountain Standard Time": "America/Denver",
        "Central Standard Time": "America/Chicago",
        "Central America Standard Time": "America/Guatemala",
        "Canada Central Standard Time": "America/Regina",
        "Central Standard Time (Mexico)": "America/Mexico_City",
        "Eastern Standard Time": "America/New_York",
        "US Eastern Standard Time": "America/Indianapolis",
        "Atlantic Standard Time": "America/Halifax",
        "Newfoundland Standard Time": "America/St_Johns",
        "SA Pacific Standard Time": "America/Bogota",
        "E. South America Standard Time": "America/Sao_Paulo",
        "Argentina Standard Time": "America/Buenos_Aires",
        "UTC": "Etc/UTC",
        "GMT Standard Time": "Europe/London",
        "Greenwich Standard Time": "Atlantic/Reykjavik",
        "W. Europe Standard Time": "Europe/Berlin",
        "Central Europe Standard Time": "Europe/Budapest",
        "Romance Standard Time": "Europe/Paris",
        "Central European Standard Time": "Europe/Warsaw",
        "E. Europe Standard Time": "Europe/Chisinau",
        "FLE Standard Time": "Europe/Kiev",
        "GTB Standard Time": "Europe/Bucharest",
        "Israel Standard Time": "Asia/Jerusalem",
        "South Africa Standard Time": "Africa/Johannesburg",
        "Egypt Standard Time": "Africa/Cairo",
        "Turkey Standard Time": "Europe/Istanbul",
        "Russian Standard Time": "Europe/Moscow",
        "Arabian Standard Time": "Asia/Dubai",
        "Pakistan Standard Time": "Asia/Karachi",
        "India Standard Time": "Asia/Calcutta",
        "SE Asia Standard Time": "Asia/Bangkok",
        "China Standard Time": "Asia/Shanghai",
        "Singapore Standard Time": "Asia/Singapore",
        "Taipei Standard Time": "Asia/Taipei",
        "Tokyo Standard Time": "Asia/Tokyo",
        "Korea Standard Time": "Asia/Seoul",
        "W. Australia Standard Time": "Australia/Perth",
        "Cen. Australia Standard Time": "Australia/Adelaide",
        "AUS Eastern Standard Time": "Australia/Sydney",
        "E. Australia Standard Time": "Australia/Brisbane",
        "New Zealand Standard Time": "Pacific/Auckland",
    ]
}
