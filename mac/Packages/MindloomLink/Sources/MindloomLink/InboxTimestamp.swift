import Foundation

/// `created_at`: ISO-8601 with the phone's local UTC offset, e.g.
/// `2026-09-30T09:15:02.345+08:00`. The Mac shows the item at this time.
public enum InboxTimestamp {
  /// Always an explicit `±HH:MM` offset (never `Z`), millisecond precision.
  public static func string(from date: Date, timeZone: TimeZone = .current) -> String {
    // Round to the nearest millisecond from the epoch value itself; calendar
    // nanoseconds can land one unit below because of binary fractions.
    let totalMillis = (date.timeIntervalSince1970 * 1000).rounded()
    let wholeSeconds = (totalMillis / 1000).rounded(.down)
    let millis = Int(totalMillis - wholeSeconds * 1000)
    let second = Date(timeIntervalSince1970: wholeSeconds)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: second)
    let offset = timeZone.secondsFromGMT(for: second)
    let sign = offset < 0 ? "-" : "+"
    let offsetMinutes = abs(offset) / 60
    return String(
      format: "%04d-%02d-%02dT%02d:%02d:%02d.%03d%@%02d:%02d",
      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, millis,
      sign, offsetMinutes / 60, offsetMinutes % 60)
  }

  /// Parses an ISO-8601 date-time that carries an explicit offset (`Z` or
  /// `±HH:MM`), with or without fractional seconds. Nil for anything else.
  public static func date(from text: String) -> Date? {
    guard text.utf8.count <= 40 else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: text) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: text)
  }
}
