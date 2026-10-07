import Foundation

/// The line under 「最近」 (PHONE-SPEC §6.2), derived from plain facts so the rule order is testable.
enum HomeStatus: Equatable {
  /// 「已发送 · {H:mm}」: paired, online, nothing pending, at least one item.
  case sent(Date)
  /// 「已连接 {Mac 名称}」: paired, nothing pending, no items.
  case connected(String)
  /// 「{N} 条仍在 iPhone 上 · 正在发送」.
  case sending(Int)
  /// 「未连接 Mac」 (alert) [「 · {N} 条仍在 iPhone 上」].
  case unreachable(Int)
  /// 「尚未连接 Mac」 [「 · {N} 条仍在 iPhone 上」] + 「连接」.
  case neverPaired(Int)
  /// 「已与 Mac 断开」 [「 · {N} 条仍在 iPhone 上」] + 「重新连接」.
  case disconnected(Int)

  enum Pairing: Equatable {
    case never
    case paired(name: String)
    case disconnected
  }

  static func derive(
    pairing: Pairing, unreachable: Bool, pending: Int, itemCount: Int, lastSentAt: Date?
  ) -> HomeStatus {
    switch pairing {
    case .never: return .neverPaired(pending)
    case .disconnected: return .disconnected(pending)
    case .paired(let name):
      if unreachable { return .unreachable(pending) }
      if pending > 0 { return .sending(pending) }
      if itemCount > 0, let lastSentAt { return .sent(lastSentAt) }
      return .connected(name)
    }
  }

  /// The words, without the inline action.
  var lead: String {
    switch self {
    case .sent(let date): "已发送 · " + PhoneFormat.time(date)
    case .connected(let name): "已连接 " + name
    case .sending(let n): "\(n) 条仍在 iPhone 上 · 正在发送"
    case .unreachable: "未连接 Mac"
    case .neverPaired: "尚未连接 Mac"
    case .disconnected: "已与 Mac 断开"
    }
  }

  /// 「 · N 条仍在 iPhone 上」 after the lead, when there is one.
  var tail: String? {
    switch self {
    case .unreachable(let n), .neverPaired(let n), .disconnected(let n):
      n > 0 ? " · \(n) 条仍在 iPhone 上" : nil
    default: nil
    }
  }

  var leadIsAlert: Bool {
    if case .unreachable = self { return true }
    return false
  }

  /// 「连接」 / 「重新连接」.
  var action: String? {
    switch self {
    case .neverPaired: "连接"
    case .disconnected: "重新连接"
    default: nil
    }
  }

  /// The whole line, for accessibility and tests.
  var text: String { lead + (tail ?? "") }
}

/// Times and dates as the phone writes them (PHONE-SPEC §6.0): 24-hour `H:mm`, `M月d日`,
/// day headers 今天 / 昨天 / `M月d日 EEEE`.
enum PhoneFormat {
  static let locale = Locale(identifier: "zh_CN")

  static func time(_ date: Date, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
  }

  static func monthDay(_ date: Date, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.month, .day], from: date)
    return "\(c.month ?? 1)月\(c.day ?? 1)日"
  }

  static func dayHeader(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    if calendar.isDate(date, inSameDayAs: now) { return "今天" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
      calendar.isDate(date, inSameDayAs: yesterday)
    {
      return "昨天"
    }
    let weekday = calendar.component(.weekday, from: date)
    let names = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
    return monthDay(date, calendar: calendar) + " " + names[(weekday - 1) % 7]
  }

  /// 「今天 9:41」, 「昨天 18:02」, or 「9月29日 18:02」 (最近送出).
  static func dayAndTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String
  {
    let day: String
    if calendar.isDate(date, inSameDayAs: now) {
      day = "今天"
    } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
      calendar.isDate(date, inSameDayAs: yesterday)
    {
      day = "昨天"
    } else {
      day = monthDay(date, calendar: calendar)
    }
    return day + " " + time(date, calendar: calendar)
  }
}
