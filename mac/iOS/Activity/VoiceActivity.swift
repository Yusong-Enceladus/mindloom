import ActivityKit
import AppIntents
import Foundation

/// The voice session's Live Activity (PHONE-SPEC §5.14): the Dynamic Island and the Lock Screen
/// banner while voice is on. Compiled into the app (which starts, updates and ends it) and into
/// the widget extension (which draws it).
struct VoiceActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable, Sendable {
    /// When the session ends by itself; nil while it stays on for charging.
    var endsAt: Date?
    /// 「充电时保持开启」 applies now.
    var charging: Bool
    /// 「还剩 N 分钟」: N = max(1, ⌊seconds left / 60⌋), computed by the app when it updates.
    var minutesLeft: Int

    init(endsAt: Date?, charging: Bool, now: Date = Date()) {
      self.endsAt = endsAt
      self.charging = charging
      let seconds = endsAt.map { max(0, $0.timeIntervalSince(now)) } ?? 0
      self.minutesLeft = max(1, Int(seconds / 60))
    }

    /// The second line: 「还剩 N 分钟」 or 「充电时保持开启」. Words, never a clock-like time.
    var detail: String {
      charging || endsAt == nil ? "充电时保持开启" : "还剩 \(minutesLeft) 分钟"
    }
  }
}

/// 「结束」 on the island and the Lock Screen: ends the voice session in the app's process.
struct EndVoiceSessionIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "结束语音"
  static let description = IntentDescription("结束语音。")
  static let isDiscoverable = false

  init() {}

  func perform() async throws -> some IntentResult {
    await VoiceSessionEnding.end()
    return .result()
  }
}

/// Where the intent reaches the app's voice session (set by the app at launch; nil in the
/// widget process, where the intent never runs).
@MainActor
enum VoiceSessionEnding {
  static var handler: (@MainActor () async -> Void)?

  static func end() async {
    await handler?()
  }
}
