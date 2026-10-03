import Foundation
import JavaScriptCore
import os.log

// MARK: - HolidayEngine

/// The days of holiday calendars, computed on the device by the web's own rules engine.
///
/// The web computes holidays with `date-holidays` (`holidaysOf` in `calendar/calendars.ts`). This
/// runs the very same library, its self-contained UMD build bundled at the version the web locks
/// (`scripts/sync_date_holidays.sh`), in JavaScriptCore. A port of its rule engine would have to
/// track every country's rules by hand; running the bundle keeps both clients on the same days,
/// for about 1.5 MB. Nothing leaves the device: a user's countries are never sent to a feed.
///
/// An actor so the 1.5 MB script is evaluated off the main thread, once, the first time a holiday
/// calendar is shown; each country's year is then cached.
actor HolidayEngine {
    static let shared = HolidayEngine()

    /// One holiday as the library gives it.
    struct Record: Decodable, Equatable {
        /// Local to the country: `YYYY-MM-DD hh:mm:ss`.
        let date: String
        let start: Date
        let end: Date
        let name: String
        /// `public`, `bank`, `school`, `optional` or `observance`.
        let type: String

        private enum CodingKeys: String, CodingKey { case date, start, end, name, type }

        init(date: String, start: Date, end: Date, name: String, type: String) {
            self.date = date
            self.start = start
            self.end = end
            self.name = name
            self.type = type
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            date = try c.decode(String.self, forKey: .date)
            start = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .start) / 1000)
            end = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .end) / 1000)
            name = try c.decode(String.self, forKey: .name)
            type = try c.decode(String.self, forKey: .type)
        }
    }

    struct Place: Equatable, Identifiable, Decodable {
        let code: String
        let name: String
        var id: String { code }
    }

    enum Failure: Error { case unavailable }

    private let scriptURL: URL?
    private var context: JSContext?
    private var failed = false
    private var cache: [String: [Record]] = [:]
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoCalendar",
                                category: "HolidayEngine")

    init(scriptURL: URL? = Bundle.main.url(forResource: "date-holidays.umd.min", withExtension: "js")) {
        self.scriptURL = scriptURL
    }

    /// The language holiday names are given in: the device's full locale, not just its language,
    /// since `en-US` names a US holiday "Labor Day" where `en` says "Labour Day".
    static var deviceLanguage: String {
        Locale.preferredLanguages.first ?? Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
    }

    /// The holidays of `country` (and `region`) in `year`, of every type.
    func holidays(country: String, region: String?, year: Int, language: String) throws -> [Record] {
        let key = "\(country)|\(region ?? "")|\(year)|\(language)"
        if let cached = cache[key] { return cached }
        let records: [Record] = try call("__neutrinoHolidays", [country, region ?? NSNull(), year, language])
        cache[key] = records
        return records
    }

    /// Every country the rules know, sorted by name in `language`.
    func countries(language: String) throws -> [Place] {
        let places: [Place] = try call("__neutrinoCountries", [language])
        return places.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The regions of `country` with holidays of their own; empty when it has none.
    func regions(country: String, language: String) throws -> [Place] {
        let places: [Place] = try call("__neutrinoRegions", [country, language])
        return places.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - JavaScript

    /// Calls one of the helpers below, which answer in JSON so nothing but strings crosses over.
    private func call<T: Decodable>(_ function: String, _ arguments: [Any]) throws -> T {
        let context = try loaded()
        guard let result = context.objectForKeyedSubscript(function)?.call(withArguments: arguments),
              context.exception == nil, let json = result.toString(), let data = json.data(using: .utf8) else {
            let message = context.exception?.toString() ?? "no result"
            context.exception = nil
            logger.error("\(function, privacy: .public) failed: \(message, privacy: .public)")
            throw Failure.unavailable
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func loaded() throws -> JSContext {
        if let context { return context }
        guard !failed, let scriptURL, let script = try? String(contentsOf: scriptURL, encoding: .utf8),
              let context = JSContext() else {
            failed = true
            throw Failure.unavailable
        }
        // The UMD wrapper reads `self`, as a browser would give it.
        context.evaluateScript("var self = this;")
        context.evaluateScript(script, withSourceURL: scriptURL)
        context.evaluateScript(Self.helpers)
        guard context.exception == nil, context.objectForKeyedSubscript("Holidays")?.isUndefined == false else {
            logger.error("date-holidays didn't load: \(context.exception?.toString() ?? "", privacy: .public)")
            failed = true
            throw Failure.unavailable
        }
        self.context = context
        return context
    }

    private static let helpers = """
    var __H = self.Holidays.default || self.Holidays;
    function __places(names) {
      return JSON.stringify(Object.keys(names || {}).map(function (code) { return { code: code, name: names[code] }; }));
    }
    function __neutrinoHolidays(country, region, year, lang) {
      var rules = region ? new __H(country, region) : new __H(country);
      return JSON.stringify((rules.getHolidays(year, lang) || []).map(function (h) {
        return { date: h.date, start: h.start.getTime(), end: h.end.getTime(), name: h.name, type: h.type };
      }));
    }
    function __neutrinoCountries(lang) { return __places(new __H().getCountries(lang)); }
    function __neutrinoRegions(country, lang) { return __places(new __H().getStates(country, lang)); }
    """
}

// MARK: - Holidays

/// A holiday calendar's days as all-day events: the web's `holidaysOf`, line for line, over the
/// records `HolidayEngine` gives. Pure, so it is tested against the web's own expectations.
enum Holidays {
    /// Shown always; observances add the rest but school holidays.
    static let publicTypes: Set<String> = ["public", "bank"]
    static let observanceTypes: Set<String> = ["optional", "observance"]

    /// The holidays of `calendar` from `from` to `to` (inclusive), each an all-day event dated by
    /// its UTC date, `T00:00:00Z` to `T23:59:59Z` of its last day, as every all-day event is.
    /// `records` gives a year's records.
    static func events(of calendar: UserCalendar, from: Date, to: Date,
                       records: (Int) throws -> [HolidayEngine.Record]) rethrows -> [CalendarEvent] {
        guard calendar.kind == .holidays, calendar.country != nil else { return [] }
        let first = dayString(from), last = dayString(to)
        var events: [CalendarEvent] = []
        var seen = Set<String>()
        for year in (Int(first.prefix(4)) ?? 0)...(Int(last.prefix(4)) ?? 0) {
            for record in try records(year) {
                let shown = publicTypes.contains(record.type)
                    || (calendar.includeObservances && observanceTypes.contains(record.type))
                guard shown else { continue }
                let day = String(record.date.prefix(10))
                // Most holidays are a day; an evening one (Halloween's starts at 18:00) is still its day.
                let days = max(1, Int((record.end.timeIntervalSince(record.start) / 86_400).rounded()))
                let lastDay = addDays(day, days - 1)
                guard lastDay >= first, day <= last else { continue }
                let id = "holiday:\(calendar.id):\(day):\(record.name)"
                guard seen.insert(id).inserted,
                      let start = ServerDate.parse("\(day)T00:00:00Z"),
                      let end = ServerDate.parse("\(lastDay)T23:59:59Z") else { continue }
                events.append(CalendarEvent(id: id, title: record.name, start: start, end: end, allDay: true,
                                            source: .holidays, calendarId: calendar.id))
            }
        }
        return events
    }

    /// `yyyy-MM-dd` of an instant in UTC, as the web's `from.slice(0, 10)` reads its ISO strings.
    static func dayString(_ date: Date) -> String {
        String(ServerDate.format(date).prefix(10))
    }

    private static func addDays(_ day: String, _ n: Int) -> String {
        guard n != 0, let date = ServerDate.parse("\(day)T00:00:00Z") else { return day }
        return dayString(date.addingTimeInterval(TimeInterval(n) * 86_400))
    }
}

extension HolidayEngine {
    /// Every shown or hidden holiday calendar's days in the range, as occurrences. Hidden ones
    /// are computed too and left for `EventFilter` to hide, so showing one again needs nothing.
    /// A calendar the engine can't compute is skipped rather than failing the rest.
    func occurrences(for calendars: [UserCalendar], from: Date, to: Date,
                     language: String = HolidayEngine.deviceLanguage) -> [EventOccurrence] {
        calendars.filter { $0.kind == .holidays }.flatMap { calendar -> [EventOccurrence] in
            guard let country = calendar.country else { return [] }
            let events = (try? Holidays.events(of: calendar, from: from, to: to) { year in
                try holidays(country: country, region: calendar.region, year: year, language: language)
            }) ?? []
            return events.map { EventOccurrence(event: $0, start: $0.start, end: $0.end) }
        }
    }
}
