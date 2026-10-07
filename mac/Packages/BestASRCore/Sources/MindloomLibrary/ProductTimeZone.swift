import Darwin
import Foundation

/// The one time zone the product counts days in (ALIGNMENT 根-13): Home's
/// 今天 and 已过期, due dates, and time words in search all use it, whatever
/// zone the Mac is set to. It is stored in the library (`LibrarySettings`),
/// so a demo root carries its own.
public enum ProductTimeZone {
  /// This owner's zone (decided 10/5).
  public static let defaultIdentifier = "Asia/Singapore"

  /// The library's zone; else `fallback`; else the default. An identifier
  /// the system does not know falls through to the next one.
  public static func resolve(
    _ settings: LibrarySettings, fallback: String? = nil
  ) -> TimeZone {
    for identifier in [settings.timeZoneIdentifier, fallback, defaultIdentifier] {
      if let identifier, let zone = zone(identifier) { return zone }
    }
    return TimeZone(secondsFromGMT: 8 * 3600)!
  }

  /// An IANA zone the system knows, by its region name ("Asia/Singapore",
  /// or an alias such as "Asia/Kolkata"); not an abbreviation like "PST",
  /// not a bare offset.
  public static func zone(_ identifier: String) -> TimeZone? {
    guard TimeZone.knownTimeZoneIdentifiers.contains(identifier)
      || (identifier.contains("/") && !identifier.hasPrefix("Etc/"))
    else { return nil }
    return TimeZone(identifier: identifier)
  }

  /// A Gregorian calendar that counts days in `zone`.
  public static func calendar(_ zone: TimeZone, locale: Locale = Locale(identifier: "zh-Hans"))
    -> Calendar
  {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    calendar.locale = locale
    return calendar
  }

  /// What `apply` replaced, for putting it back (tests).
  public struct ProcessZone: Equatable, Sendable {
    public let environmentTZ: String?
  }

  /// Makes `zone` the process's own (as `TZ` does at launch): every
  /// `Calendar.current`, `TimeZone.current`, `.autoupdatingCurrent`, date
  /// formatter and `Date.formatted` then uses it. Call on the main thread
  /// before the App starts, and when the owner changes the setting.
  @discardableResult
  public static func apply(_ zone: TimeZone) -> ProcessZone {
    let previous = ProcessZone(environmentTZ: getenv("TZ").map { String(cString: $0) })
    setenv("TZ", zone.identifier, 1)
    tzset()
    NSTimeZone.resetSystemTimeZone()
    return previous
  }

  /// A change while the App runs (Settings › 通用 › 时区): `Calendar.current`
  /// and new date formatters follow at once, through Foundation's default
  /// zone, and the pages read the product zone explicitly. The process's
  /// `TZ` is left alone: changing the environment while capture, the
  /// database and inference threads read it is not safe (review v12-B #14).
  /// The rest follows at the next launch, when `apply` sets `TZ` before
  /// anything else runs.
  public static func applyWhileRunning(_ zone: TimeZone) {
    NSTimeZone.default = zone
  }

  /// Puts back what `apply` replaced.
  public static func restore(_ previous: ProcessZone) {
    if let value = previous.environmentTZ {
      setenv("TZ", value, 1)
    } else {
      unsetenv("TZ")
    }
    tzset()
    NSTimeZone.resetSystemTimeZone()
  }

  /// The zones Settings offers: the current one, the Mac's, and the places
  /// this owner's work happens in, each once.
  public static func choices(current: TimeZone, mac: TimeZone) -> [TimeZone] {
    let common = [
      "Asia/Singapore", "Asia/Shanghai", "Asia/Hong_Kong", "Asia/Taipei", "Asia/Tokyo",
      "Australia/Sydney", "Europe/London", "Europe/Berlin", "America/New_York",
      "America/Chicago", "America/Los_Angeles",
    ]
    var seen = Set<String>()
    return ([current.identifier, mac.identifier] + common)
      .compactMap { zone($0) }
      .filter { seen.insert($0.identifier).inserted }
  }

  /// 「新加坡时间（GMT+8）」.
  public static func label(
    _ zone: TimeZone, now: Date = Date(), locale: Locale = Locale(identifier: "zh-Hans")
  ) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = zone
    formatter.dateFormat = "VVVV"
    let place = formatter.string(from: now)
    return "\(place)（\(offset(zone, at: now))）"
  }

  /// 「GMT+8」, 「GMT-7」, 「GMT+5:30」.
  public static func offset(_ zone: TimeZone, at date: Date) -> String {
    let seconds = zone.secondsFromGMT(for: date)
    let sign = seconds < 0 ? "-" : "+"
    let hours = abs(seconds) / 3600
    let minutes = abs(seconds) % 3600 / 60
    return minutes == 0
      ? "GMT\(sign)\(hours)" : "GMT\(sign)\(hours):\(String(format: "%02d", minutes))"
  }
}
