import Foundation

/// Identifiers shared by the app, the keyboard and the share extension
/// (PHONE-CONTRACT §1), and the layout of their shared container.
public enum PhoneAppGroup {
  public static let identifier = "group.com.bestasr.phone"
  public static let appBundleID = "com.bestasr.phone"
  public static let keyboardBundleID = "com.bestasr.phone.keyboard"
  public static let shareBundleID = "com.bestasr.phone.share"

  public enum AppGroupError: Error, Equatable, Sendable {
    /// The process has no App Group entitlement (for example a plain test).
    case containerUnavailable
  }

  /// The shared container. Nil when the entitlement is missing.
  public static func containerURL(fileManager: FileManager = .default) -> URL? {
    fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
  }

  /// `<container>/outbox`: the durable outbox (`OutboxStore`).
  public static func outboxDirectory(in container: URL) -> URL {
    container.appendingPathComponent("outbox", isDirectory: true)
  }

  /// `<container>/voice`: the keyboard ↔ app voice files (§2).
  public static func voiceDirectory(in container: URL) -> URL {
    container.appendingPathComponent("voice", isDirectory: true)
  }

  /// `<container>/pairing.json`: the pairing without its private key
  /// (`PairingRecord`), readable by both extensions so they can seal.
  public static func pairingRecordFile(in container: URL) -> URL {
    container.appendingPathComponent("pairing.json", isDirectory: false)
  }

  /// `<container>/keyboard.json`: what the keyboard last saw of itself
  /// (full access on or off), so the app's setup guide can say whether the
  /// keyboard is ready. No content.
  public static func keyboardStatusFile(in container: URL) -> URL {
    container.appendingPathComponent("keyboard.json", isDirectory: false)
  }

  /// The app's URL scheme. `mindloom://voice/start` opens the app and starts
  /// the voice session (the keyboard's "打开织机开始语音").
  public static let urlScheme = "mindloom"
  public static let startVoiceURL = URL(string: "mindloom://voice/start")!
}

/// Darwin notification names shared by the app and its extensions. They carry
/// no payload; the data is in the App Group files (PHONE-CONTRACT §2).
public enum PhoneSignal {
  public static let voiceStart = "com.bestasr.phone.voice.start"
  public static let voiceStop = "com.bestasr.phone.voice.stop"
  public static let voicePartial = "com.bestasr.phone.voice.partial"
  public static let voiceFinal = "com.bestasr.phone.voice.final"
  /// Posted by the app whenever it rewrites `voice/state.json` (at least
  /// every few seconds while a session is alive).
  public static let voiceHeartbeat = "com.bestasr.phone.voice.heartbeat"
  /// Posted by the keyboard and the share extension after adding to the
  /// outbox, so the app (alive during a voice session) sends right away.
  public static let outboxChanged = "com.bestasr.phone.outbox.changed"

  public static let voiceNames = [voiceStart, voiceStop, voicePartial, voiceFinal, voiceHeartbeat]
}
