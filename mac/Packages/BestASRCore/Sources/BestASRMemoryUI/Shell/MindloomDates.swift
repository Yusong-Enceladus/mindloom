import BestASRMemory
import Foundation

/// Day words the pages share (VOCABULARY §2): 「9月20日 周日」, 「9月20日」.
public enum MindloomDates {
  static let weekdays = ["日", "一", "二", "三", "四", "五", "六"]

  /// 「9月20日 周日」.
  public static func dayTitle(_ date: Date, calendar: Calendar) -> String {
    monthDay(date, calendar: calendar) + " 周" + weekdays[calendar.component(.weekday, from: date) - 1]
  }

  /// 「9月20日」.
  public static func monthDay(_ date: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.month, .day], from: date)
    return "\(parts.month ?? 0)月\(parts.day ?? 0)日"
  }

  /// 「22:40」 (24-hour, tabular in views).
  public static func clock(_ date: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%d:%02d", parts.hour ?? 0, parts.minute ?? 0)
  }

  /// 「今天」 / 「明天」 for a date today or tomorrow, else nil.
  public static func dueWord(_ date: Date, today: Date, calendar: Calendar) -> String? {
    switch MemoryDigest.days(from: today, to: date, calendar: calendar) {
    case 0: "今天"
    case 1: "明天"
    default: nil
    }
  }
}
