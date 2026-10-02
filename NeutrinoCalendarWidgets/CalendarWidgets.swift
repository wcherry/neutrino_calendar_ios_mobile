import SwiftUI
import WidgetKit

// The widget extension: Up Next, Today and Month on the Home Screen, Up Next on the Lock Screen,
// and the Live Activity. It has no network and no Keychain: everything it shows comes from the
// snapshot the app writes into the App Group container (`WidgetSnapshot`).

@main
struct CalendarWidgets: WidgetBundle {
    var body: some Widget {
        UpNextWidget()
        TodayWidget()
        MonthWidget()
        EventLiveActivity()
    }
}

// MARK: - Timeline

struct CalendarEntry: TimelineEntry {
    let date: Date
    /// `nil` before the app has written anything.
    let snapshot: WidgetSnapshot?
}

/// One entry for now, then one at each start and end over the next day and at midnight, so Up
/// Next rolls on and Today turns over without the app running. The app asks for a new timeline
/// whenever the calendar changes.
struct CalendarProvider: TimelineProvider {
    func placeholder(in context: Context) -> CalendarEntry {
        CalendarEntry(date: Date(), snapshot: .sample())
    }

    func getSnapshot(in context: Context, completion: @escaping (CalendarEntry) -> Void) {
        let stored = WidgetSnapshot.load()
        // The widget gallery shows the real calendar when there is one, and a sample otherwise.
        let snapshot = context.isPreview && stored?.signedIn != true ? .sample() : stored
        completion(CalendarEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CalendarEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshot.load()
        let dates = snapshot?.entryDates(from: now) ?? [now]
        let entries = dates.map { CalendarEntry(date: $0, snapshot: snapshot) }
        // Without a snapshot there is nothing to roll over; the app reloads once it writes one.
        completion(Timeline(entries: entries, policy: snapshot == nil ? .never : .atEnd))
    }
}

// MARK: - Shared pieces

enum WidgetStyle {
    /// The Calendar brand: purple into pink.
    static let accent = Color.pink
    static let gradient = LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension View {
    /// iOS 17 draws the widget's background itself and asks for it here; iOS 16 needs the
    /// padding and background the view would otherwise lack.
    @ViewBuilder
    func widgetBackground() -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            containerBackground(for: .widget) { Color(.systemBackground) }
        } else {
            padding().background(Color(.systemBackground))
        }
    }
}

/// What a widget shows when there is no calendar to show.
struct WidgetMessage: View {
    let snapshot: WidgetSnapshot?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.title2)
                .foregroundStyle(WidgetStyle.accent)
            Text(snapshot == nil ? "Open Calendar to see your events here." : "Sign in to Neutrino Calendar.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum WidgetFormat {
    /// "9:00 AM – 10:00 AM", "All day", "Until 10:00 AM" for one that began yesterday, or for a
    /// later day "Tomorrow, 9:00 AM" and "Thu, Oct 1, all day".
    static func time(_ event: WidgetEvent, at date: Date, calendar: Calendar) -> String {
        let clock = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone)
        let today = WidgetSnapshot.dayKey(date, calendar: calendar)
        if event.allDay {
            return event.firstDay <= today ? "All day" : "\(day(event.firstDay, from: date, calendar: calendar)), all day"
        }
        let startDay = WidgetSnapshot.dayKey(event.start, calendar: calendar)
        if startDay == today { return "\(event.start.formatted(clock)) – \(event.end.formatted(clock))" }
        if startDay < today { return "Until \(event.end.formatted(clock))" }
        return "\(day(startDay, from: date, calendar: calendar)), \(event.start.formatted(clock))"
    }

    /// "Tomorrow", or "Thu, Oct 1", for a `yyyy-MM-dd` day key.
    static func day(_ key: String, from date: Date, calendar: Calendar) -> String {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: date)!
        if key == WidgetSnapshot.dayKey(tomorrow, calendar: calendar) { return "Tomorrow" }
        guard let day = WidgetSnapshot.day(fromKey: key, calendar: calendar) else { return key }
        return day.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.abbreviated).month(.abbreviated).day())
    }
}

/// One event in a list: a bar in its calendar's colour, the title, and its time.
struct EventLine: View {
    let event: WidgetEvent
    let date: Date
    let calendar: Calendar
    var showsLocation = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(hex: event.color) ?? WidgetStyle.accent)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(WidgetFormat.time(event, at: date, calendar: calendar))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if showsLocation, let location = event.location {
                    Text(location)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .opacity(!event.allDay && event.end <= date ? 0.45 : 1)
    }
}

// MARK: - Sample

extension WidgetSnapshot {
    /// For the widget gallery and placeholders, before the app has written anything.
    static func sample(now: Date = Date()) -> WidgetSnapshot {
        let calendar = Calendar.current
        let hour = calendar.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime)!
        let today = WidgetSnapshot.dayKey(now, calendar: calendar)
        func event(_ title: String, _ offset: TimeInterval, _ length: TimeInterval, _ location: String? = nil) -> WidgetEvent {
            WidgetEvent(id: title, title: title, start: hour.addingTimeInterval(offset),
                        end: hour.addingTimeInterval(offset + length), allDay: false,
                        firstDay: today, lastDay: today, location: location)
        }
        return WidgetSnapshot(signedIn: true, generatedAt: now, timeZone: calendar.timeZone.identifier,
                              firstWeekday: calendar.firstWeekday,
                              events: [event("Design review", 0, 3600, "Room 4"),
                                       event("Lunch with Sam", 7200, 3600, "Cafe"),
                                       event("Dentist", 14400, 1800)],
                              busyDays: [today], filterSummary: nil)
    }
}
