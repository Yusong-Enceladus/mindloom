import Foundation

/// The switches and small flags the app, the keyboard and the share extension share (PHONE-SPEC §7.6,
/// §8 `VoiceSettings`, `KeyboardFlags`), in the App Group's defaults. All of them apply at once and
/// persist. No content is ever stored here.
public struct PhoneSettings: @unchecked Sendable {
  /// The idle times 自动结束 offers, in minutes.
  public static let idleChoices = [5, 10, 30]

  enum Key {
    static let idleMinutes = "voice.idle_minutes"
    static let stayOnWhileCharging = "voice.stay_on_while_charging"
    static let sendKeyboardSpeech = "keyboard.send_to_mac"
    static let bounceTipsShown = "voice.bounce_tips_shown"
    static let disconnected = "pairing.disconnected"
    static let pairedAt = "pairing.paired_at"
    static let lastSentAt = "delivery.last_sent_at"
    static let welcomeDone = "app.welcome_done"
    static let microphoneDenied = "voice.microphone_denied"
    static let debugKeyboardScreen = "debug.keyboard_screen"

    /// What `PhoneStorageMigration.migrateSettings` brings from the app's own defaults into the
    /// App Group's (everything but the DEBUG screenshot state).
    static let migrated = [
      idleMinutes, stayOnWhileCharging, sendKeyboardSpeech, bounceTipsShown, disconnected,
      pairedAt, lastSentAt, welcomeDone, microphoneDenied,
    ]
  }

  public let defaults: UserDefaults
  /// True when the defaults are the App Group's (the keyboard sees the same values).
  public let isShared: Bool

  public init(defaults: UserDefaults, isShared: Bool) {
    self.defaults = defaults
    self.isShared = isShared
  }

  /// The App Group's defaults, or the process's own when the build has no App Group.
  public static func shared() -> PhoneSettings {
    if PhoneAppGroup.containerURL() != nil,
      let group = UserDefaults(suiteName: PhoneAppGroup.identifier)
    {
      return PhoneSettings(defaults: group, isShared: true)
    }
    return PhoneSettings(defaults: .standard, isShared: false)
  }

  /// 自动结束: 5, 10 (default) or 30 minutes of no use.
  public var idleMinutes: Int {
    get {
      let value = defaults.integer(forKey: Key.idleMinutes)
      return Self.idleChoices.contains(value) ? value : 10
    }
    nonmutating set {
      defaults.set(Self.idleChoices.contains(newValue) ? newValue : 10, forKey: Key.idleMinutes)
    }
  }

  /// 充电时保持开启 (default on).
  public var stayOnWhileCharging: Bool {
    get { defaults.object(forKey: Key.stayOnWhileCharging) as? Bool ?? true }
    nonmutating set { defaults.set(newValue, forKey: Key.stayOnWhileCharging) }
  }

  /// 键盘说的话也送到 Mac (default on): when off, keyboard speech only goes into the host field.
  public var sendKeyboardSpeech: Bool {
    get { defaults.object(forKey: Key.sendKeyboardSpeech) as? Bool ?? true }
    nonmutating set { defaults.set(newValue, forKey: Key.sendKeyboardSpeech) }
  }

  /// How many times the bounce tip (「语音已开启 / 回到信息，按住说话就行」) was shown; it shows the first 3.
  public var bounceTipsShown: Int {
    get { defaults.integer(forKey: Key.bounceTipsShown) }
    nonmutating set { defaults.set(newValue, forKey: Key.bounceTipsShown) }
  }

  /// The user disconnected the Mac (「已与 Mac 断开」 rather than 「还没连接 Mac」).
  public var disconnected: Bool {
    get { defaults.bool(forKey: Key.disconnected) }
    nonmutating set { defaults.set(newValue, forKey: Key.disconnected) }
  }

  /// 连接于.
  public var pairedAt: Date? {
    get { defaults.object(forKey: Key.pairedAt) as? Date }
    nonmutating set { defaults.set(newValue, forKey: Key.pairedAt) }
  }

  /// 最近送出 and 「已安全送出 · H:mm」.
  public var lastSentAt: Date? {
    get { defaults.object(forKey: Key.lastSentAt) as? Date }
    nonmutating set { defaults.set(newValue, forKey: Key.lastSentAt) }
  }

  /// The app last found the microphone turned off in iOS Settings: the keyboard reads
  /// 「麦克风没有打开 去设置」 and offers no session (PHONE-SPEC §7.2).
  public var microphoneDenied: Bool {
    get { defaults.bool(forKey: Key.microphoneDenied) }
    nonmutating set { defaults.set(newValue, forKey: Key.microphoneDenied) }
  }

  /// DEBUG builds only: a PHONE-SPEC keyboard state id (`kb-listen`, `kb-saved-t5.6`, …) the
  /// keyboard shows frozen, for the screenshot harness. Release builds never write or read it.
  public var debugKeyboardScreen: String? {
    get { defaults.string(forKey: Key.debugKeyboardScreen) }
    nonmutating set { defaults.set(newValue, forKey: Key.debugKeyboardScreen) }
  }

  /// The first-run Welcome was answered (连接 Mac or 稍后).
  public var welcomeDone: Bool {
    get { defaults.bool(forKey: Key.welcomeDone) }
    nonmutating set { defaults.set(newValue, forKey: Key.welcomeDone) }
  }
}

/// The text rules the app and the keyboard share (PHONE-SPEC §7.1 commit).
public enum PhoneTextRules {
  /// Appends 「。」 unless the text already ends in 。！？，,.!? ; empty when nothing was heard.
  public static func finalized(_ recognized: String) -> String {
    let trimmed = tidy(recognized).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let last = trimmed.last else { return "" }
    return "。！？，,.!?".contains(last) ? trimmed : trimmed + "。"
  }

  /// The recognizer's segments joined as Chinese is written: no space before a full-width
  /// 「，。！？、；：」 or a closing bracket, none after an opening one, and no doubled 「。。」
  /// (SpeechTranscriber starts a segment with 「 ，」 and may end two with 「。」). Spaces between
  /// Latin words and around numbers stay.
  public static func tidy(_ text: String) -> String {
    var out: [Character] = []
    out.reserveCapacity(text.count)
    for character in text {
      if closing.contains(character) {
        while let last = out.last, last == " " { out.removeLast() }
        if let last = out.last, last == character, "。！？，、".contains(character) { continue }
      } else if character == " ", let last = out.last, opening.contains(last) || closing.contains(last)
      {
        continue
      }
      out.append(character)
    }
    return String(out)
  }

  // copy-guard: characters
  private static let closing: Set<Character> = Set("，。！？、；：）」』》】")
  // copy-guard: characters
  private static let opening: Set<Character> = Set("（「『《【")
}
