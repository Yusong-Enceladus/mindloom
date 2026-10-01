import BestASRDomain
import BestASRIntake
import CryptoKit
import EventKit
import Foundation

/// Calendar (V8 contract A5), off by default and behind the system's
/// permission. The owner chooses which calendars are read; each event in the
/// window becomes an item with source 日历: its title, time, attendee names
/// and notes (never attendee e-mail addresses). Nothing is ever written to a
/// calendar: the reader below has no write call, and Reminders write-back is
/// a separate type used only by the owner's click.
public struct CalendarEventSnapshot: Equatable, Sendable {
  /// The event and the occurrence (a repeating event is one item per
  /// occurrence).
  public let key: String
  public let calendarID: String
  public let calendarTitle: String
  public let title: String
  public let start: Date
  public let end: Date
  public let isAllDay: Bool
  public let attendeeNames: [String]
  public let notes: String?

  public init(
    key: String, calendarID: String, calendarTitle: String = "", title: String, start: Date,
    end: Date, isAllDay: Bool = false, attendeeNames: [String] = [], notes: String? = nil
  ) {
    self.key = key
    self.calendarID = calendarID
    self.calendarTitle = calendarTitle
    self.title = title
    self.start = start
    self.end = end
    self.isAllDay = isAllDay
    self.attendeeNames = attendeeNames
    self.notes = notes
  }

  /// Changes when anything the item shows changes.
  public var fingerprint: String {
    let parts = [
      title, "\(start.timeIntervalSince1970)", "\(end.timeIntervalSince1970)", "\(isAllDay)",
      attendeeNames.joined(separator: "\u{1F}"), notes ?? "",
    ]
    let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1E}").utf8))
    return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
  }
}

public struct CalendarInfo: Equatable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let source: String

  public init(id: String, title: String, source: String) {
    self.id = id
    self.title = title
    self.source = source
  }
}

public enum CalendarAccess: Equatable, Sendable {
  case granted
  case notDetermined
  case denied
}

/// Reading calendars. Read-only by construction: there is no call here that
/// could save, change or remove an event.
public protocol CalendarReading: Sendable {
  func access() -> CalendarAccess
  func requestAccess() async -> Bool
  func calendars() -> [CalendarInfo]
  func events(from start: Date, to end: Date, calendarIDs: [String]) -> [CalendarEventSnapshot]
}

/// What has been taken: event key → the fingerprint taken.
public struct CalendarSyncState: Codable, Equatable, Sendable {
  public var taken: [String: String] = [:]

  public init() {}
}

public enum CalendarSync {
  /// Events from a week back to a month ahead.
  public static let pastDays = 7
  public static let futureDays = 30

  public static func window(now: Date, calendar: Calendar = .current) -> (Date, Date) {
    let start = calendar.date(byAdding: .day, value: -pastDays, to: now) ?? now
    let end = calendar.date(byAdding: .day, value: futureDays, to: now) ?? now
    return (start, end)
  }

  /// The items for events not taken yet, or taken with different details (a
  /// moved meeting becomes a new item that says so; the earlier one stays
  /// as it was). Only events of the chosen calendars.
  public static func plan(
    _ events: [CalendarEventSnapshot], chosen: [String], state: inout CalendarSyncState, now: Date,
    timeZone: TimeZone = .current
  ) -> [EntryIntakeItem] {
    let chosenSet = Set(chosen)
    var items: [EntryIntakeItem] = []
    for event in events.sorted(by: { ($0.start, $0.key) < ($1.start, $1.key) })
    where chosenSet.contains(event.calendarID) {
      let fingerprint = event.fingerprint
      let previous = state.taken[event.key]
      guard previous != fingerprint else { continue }
      state.taken[event.key] = fingerprint
      let text = CalendarItemText.text(event, changed: previous != nil, timeZone: timeZone)
      items.append(
        EntryIntakeItem(
          candidate: .text(text, extractor: EntryExtractor.calendarEvent),
          source: EntrySource.named(EntrySource.calendar),
          // An event that already happened keeps its own time; a future one
          // is taken in now (its time is in the text).
          capturedAt: min(event.start, now),
          id: EntryIdentity.itemID(.calendar, key: "\(event.key)|\(fingerprint)")))
    }
    // Forget events long gone, so the state stays small.
    let horizon = now.addingTimeInterval(-Double(pastDays + 30) * 86_400)
    let current = Set(events.map(\.key))
    state.taken = state.taken.filter { key, _ in
      current.contains(key) || (CalendarItemText.occurrenceDate(key).map { $0 > horizon } ?? true)
    }
    return items
  }
}

public enum CalendarItemText {
  public static func text(
    _ event: CalendarEventSnapshot, changed: Bool = false, timeZone: TimeZone = .current
  ) -> String {
    var lines = ["日程：\(oneLine(event.title).isEmpty ? "（无标题）" : oneLine(event.title))"]
    lines.append("时间：\(time(event, timeZone: timeZone))")
    let names = event.attendeeNames.map(oneLine).filter { !$0.isEmpty }
    if !names.isEmpty { lines.append("参与人：\(names.joined(separator: "、"))") }
    if !event.calendarTitle.isEmpty { lines.append("日历：\(oneLine(event.calendarTitle))") }
    if changed { lines.append("（这条日程有改动，之前收进过一次）") }
    if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
      lines.append("备注：")
      lines.append(notes)
    }
    return lines.joined(separator: "\n")
  }

  static func time(_ event: CalendarEventSnapshot, timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let day = DateFormatter()
    day.calendar = calendar
    day.timeZone = timeZone
    day.locale = Locale(identifier: "zh_CN")
    day.dateFormat = "yyyy-MM-dd EEE"
    let clock = DateFormatter()
    clock.calendar = calendar
    clock.timeZone = timeZone
    clock.dateFormat = "HH:mm"
    if event.isAllDay {
      // EventKit's all-day end is the next midnight.
      let last = calendar.date(byAdding: .second, value: -1, to: event.end) ?? event.end
      return calendar.isDate(event.start, inSameDayAs: last)
        ? "\(day.string(from: event.start))（全天）"
        : "\(day.string(from: event.start)) – \(day.string(from: last))（全天）"
    }
    if calendar.isDate(event.start, inSameDayAs: event.end) {
      return
        "\(day.string(from: event.start)) \(clock.string(from: event.start))–\(clock.string(from: event.end))"
    }
    return
      "\(day.string(from: event.start)) \(clock.string(from: event.start)) – \(day.string(from: event.end)) \(clock.string(from: event.end))"
  }

  static func oneLine(_ text: String) -> String {
    text.components(separatedBy: .newlines).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The occurrence start encoded in a key (`<event id>@<unix seconds>`).
  static func occurrenceDate(_ key: String) -> Date? {
    guard let at = key.lastIndex(of: "@"), let seconds = Double(key[key.index(after: at)...])
    else { return nil }
    return Date(timeIntervalSince1970: seconds)
  }

  public static func key(eventID: String, occurrence: Date) -> String {
    "\(eventID)@\(Int(occurrence.timeIntervalSince1970))"
  }
}

/// EventKit, read-only. It asks for the system's calendar permission only
/// when the owner switches the calendar entry on.
public final class EventKitCalendarReader: CalendarReading, @unchecked Sendable {
  private let store = EKEventStore()

  public init() {}

  public func access() -> CalendarAccess {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess: .granted
    case .notDetermined: .notDetermined
    default: .denied
    }
  }

  public func requestAccess() async -> Bool {
    (try? await store.requestFullAccessToEvents()) ?? false
  }

  public func calendars() -> [CalendarInfo] {
    guard access() == .granted else { return [] }
    return store.calendars(for: .event).map {
      CalendarInfo(id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "")
    }.sorted { ($0.source, $0.title) < ($1.source, $1.title) }
  }

  public func events(from start: Date, to end: Date, calendarIDs: [String])
    -> [CalendarEventSnapshot]
  {
    guard access() == .granted, !calendarIDs.isEmpty else { return [] }
    let wanted = Set(calendarIDs)
    let calendars = store.calendars(for: .event).filter {
      wanted.contains($0.calendarIdentifier)
    }
    guard !calendars.isEmpty else { return [] }
    store.refreshSourcesIfNecessary()
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
    return store.events(matching: predicate).compactMap { event in
      guard let identifier = event.eventIdentifier, let startDate = event.startDate,
        let endDate = event.endDate
      else { return nil }
      let occurrence = event.occurrenceDate ?? startDate
      return CalendarEventSnapshot(
        key: CalendarItemText.key(eventID: identifier, occurrence: occurrence),
        calendarID: event.calendar?.calendarIdentifier ?? "",
        calendarTitle: event.calendar?.title ?? "", title: event.title ?? "", start: startDate,
        end: endDate, isAllDay: event.isAllDay,
        // Names only; e-mail addresses (the participant URL) are never read.
        attendeeNames: (event.attendees ?? []).compactMap(\.name), notes: event.notes)
    }
  }
}
