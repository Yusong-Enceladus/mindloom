import Foundation
import MindloomIdentity

/// Identifiers shared by the app, the keyboard and the share extension
/// (PHONE-CONTRACT §1), and the layout of their shared container.
public enum PhoneAppGroup {
  /// The phone's identity. It is set by the build, not here: `iOS/project.yml` defines
  /// `MINDLOOM_PHONE_BUNDLE_ID` and `MINDLOOM_APP_GROUP` and writes them into each target's
  /// Info.plist (`MindloomAppBundleID`, `MindloomAppGroup`); the extensions are
  /// `<bundle id>.keyboard`, `.share` and `.live`.
  public struct Identity: Equatable, Sendable {
    public static let appBundleIDInfoKey = "MindloomAppBundleID"
    public static let appGroupInfoKey = "MindloomAppGroup"
    /// What a process without those keys uses (package tests): Mindloom's.
    public static let standard = Identity(
      appBundleID: MindloomIdentity.bundleID, appGroup: MindloomIdentity.appGroup)

    public let appBundleID: String
    public let appGroup: String

    public init(appBundleID: String, appGroup: String) {
      self.appBundleID = appBundleID
      self.appGroup = appGroup
    }

    /// The identity named in an Info dictionary. A missing, empty or unexpanded (`$(…)`) bundle
    /// id is `standard`'s; a missing group is `group.<bundle id>`, as in iOS/project.yml.
    public init(info: [String: Any]?) {
      func value(_ key: String) -> String? {
        guard let text = info?[key] as? String, !text.isEmpty, !text.contains("$(") else {
          return nil
        }
        return text
      }
      let appBundleID = value(Self.appBundleIDInfoKey) ?? Self.standard.appBundleID
      self.init(
        appBundleID: appBundleID, appGroup: value(Self.appGroupInfoKey) ?? "group." + appBundleID)
    }

    public var keyboardBundleID: String { appBundleID + ".keyboard" }
    public var shareBundleID: String { appBundleID + ".share" }
  }

  /// This build's identity (from the main bundle's Info.plist).
  public static let identity = Identity(info: Bundle.main.infoDictionary)
  public static let identifier = identity.appGroup
  public static let appBundleID = identity.appBundleID
  public static let keyboardBundleID = identity.keyboardBundleID
  public static let shareBundleID = identity.shareBundleID

  public enum AppGroupError: Error, Equatable, Sendable {
    /// The process has no App Group entitlement (for example a plain test).
    case containerUnavailable
  }

  /// The shared container. Nil when the entitlement is missing.
  public static func containerURL(fileManager: FileManager = .default) -> URL? {
    fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
  }

  /// Where the app keeps its outbox, voice files and pairing record.
  public struct StorageRoot: Equatable, Sendable {
    public let url: URL
    /// True for the App Group container. False for the app's own
    /// Application Support fallback, which the keyboard and the share
    /// extension cannot reach.
    public let isShared: Bool

    public init(url: URL, isShared: Bool) {
      self.url = url
      self.isShared = isShared
    }
  }

  /// The App Group container, or, when the process has no App Group
  /// entitlement, the app's own Application Support directory. A
  /// development build signed by a team without App Groups (a free Personal
  /// Team) still runs the app and its voice session; only the keyboard ↔ app
  /// files and the share extension's outbox are not shared.
  public static func storageRoot(fileManager: FileManager = .default) throws -> StorageRoot {
    try storageRoot(
      sharedContainer: containerURL(fileManager: fileManager),
      applicationSupport: {
        try fileManager.url(
          for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      })
  }

  /// `storageRoot(fileManager:)` with both locations injected (tests).
  /// `applicationSupport` is only asked when there is no shared container.
  public static func storageRoot(
    sharedContainer: URL?, applicationSupport: () throws -> URL
  ) throws -> StorageRoot {
    if let sharedContainer { return StorageRoot(url: sharedContainer, isShared: true) }
    return StorageRoot(url: try applicationSupport(), isShared: false)
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
  /// The keyboard's 「麦克风没有打开 去设置」: the app opens iOS Settings › Mindloom.
  public static let microphoneSettingsURL = URL(string: "mindloom://settings/microphone")!
  /// The keyboard without Full Access: the app opens its Mindloom 键盘 page (the steps).
  public static let keyboardSettingsURL = URL(string: "mindloom://settings/keyboard")!
}

/// Names the app and its extensions derive from this build's identity
/// (`<bundle id>.…`), so two identities on one phone never hear each other.
public enum PhoneNames {
  /// The unified log subsystems of the app, the keyboard and the share extension.
  public static let appLog = PhoneAppGroup.appBundleID
  public static let keyboardLog = PhoneAppGroup.keyboardBundleID
  public static let shareLog = PhoneAppGroup.shareBundleID
  /// The `BGAppRefreshTask` that sends the outbox (Info.plist:
  /// `$(MINDLOOM_PHONE_BUNDLE_ID).outbox-refresh`).
  public static let outboxRefreshTask = PhoneAppGroup.appBundleID + ".outbox-refresh"
  /// The keychain services of the voice link records, the pairing handed to
  /// the share extension, and the phone's SSH key.
  public static let linkService = PhoneAppGroup.appBundleID + ".phone.link"
  public static let shareService = PhoneAppGroup.appBundleID + ".phone.share"
  public static let pairingService = PhoneAppGroup.appBundleID + ".phone.pairing"

  public static func signal(_ name: String) -> String { PhoneAppGroup.appBundleID + "." + name }
  public static func queueLabel(_ name: String) -> String { PhoneAppGroup.appBundleID + "." + name }
}

/// Darwin notification names shared by the app and its extensions. They carry
/// no payload; the data is in the App Group files (PHONE-CONTRACT §2).
public enum PhoneSignal {
  public static let voiceStart = PhoneNames.signal("voice.start")
  public static let voiceStop = PhoneNames.signal("voice.stop")
  /// The keyboard's × (slide onto it, or tap it): the open utterance is dropped and nothing is
  /// written into the field. The app publishes an empty final for it, so numbering stays in order.
  public static let voiceCancel = PhoneNames.signal("voice.cancel")
  public static let voicePartial = PhoneNames.signal("voice.partial")
  public static let voiceFinal = PhoneNames.signal("voice.final")
  /// Posted by the keyboard after it rewrites `voice/ack` (a final inserted, or taken back).
  public static let voiceAck = PhoneNames.signal("voice.ack")
  /// The name whose notify state carries the input level in the keychain fallback.
  public static let voiceLevel = PhoneNames.signal("voice.level")
  /// Posted by the app whenever it rewrites `voice/state.json` (at least
  /// every few seconds while a session is alive).
  public static let voiceHeartbeat = PhoneNames.signal("voice.heartbeat")
  /// Posted by the keyboard and the share extension after adding to the
  /// outbox, so the app (alive during a voice session) sends right away.
  public static let outboxChanged = PhoneNames.signal("outbox.changed")

  public static let voiceNames = [
    voiceStart, voiceStop, voiceCancel, voicePartial, voiceFinal, voiceAck, voiceHeartbeat,
  ]

  /// Posted by the app after it changes a shared flag the keyboard shows (the microphone
  /// permission, 「键盘说的话也送到 Mac」), so a keyboard on screen re-reads `PhoneSettings`.
  public static let settingsChanged = PhoneNames.signal("settings.changed")
}
