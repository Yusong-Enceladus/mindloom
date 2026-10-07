import CoreFoundation
import Foundation

/// What Mindloom (`app.mindloom`) carries over from the daily bestASR it
/// replaces (d54fb45, `com.bestasr.app`; owner's decisions of 10/5 and 10/6:
/// one App, a new identity). The library folder moves
/// (`LibraryFolderCarryOver`), the keychain items are handed over
/// (`MindloomCarryOver`), and the preferences are imported here from the old
/// domain on Mindloom's first launch. Every key d54 reads or writes is listed
/// with how Mindloom treats it, so a renamed key or a dropped one fails
/// `ProductCarryOverTests` instead of silently resetting a setting the owner
/// made (ALIGNMENT 根-9, switch 10-6).
public enum ProductCarryOver {
  /// How Mindloom treats one d54 preference key.
  public enum Disposition: Equatable, Sendable {
    /// Read and written under the same name with the same meaning and format;
    /// imported from bestASR's domain.
    case honored
    /// Read once and turned into another key (`migratePreferences`); imported
    /// first.
    case migrated(to: String)
    /// Mindloom reads and writes it under the same name, but bestASR's value
    /// describes bestASR itself (the system grants it was given), which a new
    /// identity does not have: not imported, so Mindloom asks for itself.
    case notCarried(String)
    /// Read by nothing any more; not imported (and left in bestASR's domain).
    case retired(String)
  }

  /// Every key d54fb45 reads or writes in its preferences domain (from its
  /// source: `UserDefaults`, `@AppStorage`, `LocalPreferenceStore`,
  /// `LocalModelLicenseReceipts`, the hotkey and permission-history stores),
  /// plus the keys older builds left there that d54 no longer reads.
  public static let d54Keys: [(key: String, disposition: Disposition)] = [
    // fn and the dictation shortcut (`UserDefaultsHotkeyConfigurationStore`,
    // the same JSON shape).
    ("dictation.hotkeys.v1", .honored),
    // The menu bar: d54 could record from its window, so its menu bar icon
    // could be off. In Mindloom the menu bar is where 开始记录会议 starts
    // (Settings › 入口 › 记录会议), so it starts on whatever bestASR's was
    // (review of 10-6).
    ("preferences.menu-bar-enabled", .notCarried(menuBarRecords)),
    // Interface language (both builds force zh-Hans).
    ("preferences.interface-language", .honored),
    // Translation targets of the 翻译 mode.
    ("preferences.translation-languages", .honored),
    // The floating capsule's live text: d54 could show it on hover only;
    // Mindloom has one switch, 「口述时显示文字」.
    ("preferences.capsule-subtitles-hover-only", .migrated(to: dictationCaptionsKey)),
    // Text handling.
    ("preferences.default-polish-enabled", .honored),
    ("preferences.default-polish-off-migration-v1", .honored),
    ("preferences.personal-cleanup-enabled", .honored),
    ("preferences.speaker-memory-enabled", .honored),
    ("preferences.app-text-policies.v1", .honored),
    // Models and updates.
    ("preferences.allow-model-downloads", .honored),
    ("preferences.automatic-model-updates", .honored),
    ("preferences.automatic-app-update-checks", .honored),
    ("model-license-receipt.automatic-speech-pack-v2", .honored),
    ("model-license-receipt.qwen3-1.7b-mlx-4bit", .honored),
    ("model-license-receipt.fluid-speaker-diarization-coreml", .honored),
    // Recording sources.
    ("preferences.room-microphone-uid", .honored),
    ("preferences.system-audio-source", .honored),
    ("preferences.system-audio-microphone-uid", .honored),
    ("preferences.system-audio-include-microphone", .honored),
    ("preferences.system-audio-microphone-overrides.v1", .honored),
    ("preferences.recent-system-audio-sources", .honored),
    // The owner's own person and this Mac's origin id.
    ("identity.local-self-person-id", .honored),
    ("bestASR.local-origin-device-id", .honored),
    // Onboarding (d54's Home setup cards).
    ("onboarding.practice-completed-v1", .honored),
    ("onboarding.practice-deferred-v1", .honored),
    (
      "onboarding.permissions-deferred-v1",
      .notCarried("bestASR's choice to set its own permissions up later; Mindloom asks for its own")
    ),
    ("onboarding.models-deferred-v1", .honored),
    ("onboarding.microphone-checked-v1", .honored),
    // Permission history (`UserDefaultsMacPermissionHistoryStore`): what
    // macOS granted bestASR. Imported, it would show Mindloom's never-asked
    // permissions as revoked or denied and skip the system's prompt.
    ("permissions.microphone-granted-v1", .notCarried(identityBoundGrant)),
    ("permissions.accessibility-requested-v1", .notCarried(identityBoundGrant)),
    ("permissions.accessibility-granted-v1", .notCarried(identityBoundGrant)),
    ("permissions.system-audio-requested-v1", .notCarried(identityBoundGrant)),
    ("permissions.system-audio-granted-v1", .notCarried(identityBoundGrant)),
    // Left by builds before d54; d54 itself no longer reads them.
    ("bestASR.applicationsExposingText", .retired("written by builds before d54; unused since")),
    ("bestASR.unverifiedPasteStreaks", .retired("written by builds before d54; unused since")),
    (
      "model-license-receipt.fluid-sensevoice-small-int8",
      .retired("the SenseVoice receipt before the automatic speech pack (v2)")
    ),
  ]

  static let identityBoundGrant = "a grant macOS gave bestASR; Mindloom is a new App to macOS"
  static let menuBarRecords =
    "bestASR's menu bar was optional beside a window that could record; Mindloom records from it"

  /// Mindloom's 「口述时显示文字」 (Settings › 入口; default on).
  public static let dictationCaptionsKey = "preferences.dictation-captions"
  static let capsuleHoverOnlyKey = "preferences.capsule-subtitles-hover-only"
  /// Set once the carry-over has run in a preferences domain.
  public static let carryOverDoneKey = "preferences.d54-carry-over-v1"
  /// Set once bestASR's preferences were imported into Mindloom's domain.
  public static let importDoneKey = "preferences.bestasr-import-v1"
  /// Set when that import found bestASR's settings: Welcome then says the
  /// permissions are asked again.
  public static let cameFromBestASRKey = "preferences.came-from-bestasr"

  /// The keys imported from bestASR's domain: honored and migrated ones.
  public static var importedKeys: [String] {
    d54Keys.compactMap { key, disposition in
      switch disposition {
      case .honored, .migrated: neverImported(key) ? nil : key
      case .notCarried, .retired: nil
      }
    }
  }

  /// The organizing link's settings (DGX Spark host, socket, token, inbox)
  /// and its state: never imported, whatever a list says, so a carried
  /// setting can never switch an old link on.
  public static func neverImported(_ key: String) -> Bool {
    let lowered = key.lowercased()
    return ["spark", "organizer", "remote", "link-on", "space"].contains { lowered.contains($0) }
  }

  /// Copies bestASR's settings into Mindloom's domain, once per domain, before
  /// anything reads them. A value Mindloom already has is never overwritten;
  /// nothing is written to bestASR's domain. `read` is
  /// `CFPreferencesCopyAppValue(key, previousDomain)` (the App is not
  /// sandboxed, so it may read another App's domain of the same user).
  /// Returns how many keys were imported.
  @discardableResult
  public static func importPreferences(
    into defaults: UserDefaults, read: (String) -> Any?
  ) -> Int {
    guard !defaults.bool(forKey: importDoneKey) else { return 0 }
    var imported = 0
    for key in importedKeys where defaults.object(forKey: key) == nil {
      guard let value = read(key),
        PropertyListSerialization.propertyList(
          value, isValidFor: .binary)
      else { continue }
      defaults.set(value, forKey: key)
      imported += 1
    }
    defaults.set(true, forKey: importDoneKey)
    if imported > 0 { defaults.set(true, forKey: cameFromBestASRKey) }
    return imported
  }

  /// `importPreferences` from another App's domain of this user.
  @discardableResult
  public static func importPreferences(fromDomain domain: String, into defaults: UserDefaults)
    -> Int
  {
    importPreferences(into: defaults) { key in
      CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }
  }

  /// Turns d54-only settings into Mindloom's, once per preferences domain,
  /// before anything reads them. Never removes a key and never overwrites a
  /// value Mindloom itself already stored.
  public static func migratePreferences(_ defaults: UserDefaults) {
    guard !defaults.bool(forKey: carryOverDoneKey) else { return }
    // d54 showed the capsule's live text only under the pointer: the closest
    // Mindloom setting is the text not shown while dictating.
    if defaults.object(forKey: dictationCaptionsKey) == nil,
      defaults.object(forKey: capsuleHoverOnlyKey) != nil,
      defaults.bool(forKey: capsuleHoverOnlyKey)
    {
      defaults.set(false, forKey: dictationCaptionsKey)
    }
    defaults.set(true, forKey: carryOverDoneKey)
  }
}

/// 「登录时打开」 after the App moved (ALIGNMENT 根-9). Mindloom registers its
/// own login item again from where it now runs, once, so the item opens this
/// App and not a copy kept in a backup folder. bestASR's login item belongs
/// to another identity: when it was on, the switch's helper says so, Mindloom
/// turns its own on (`adoptPreviousApp`) and the helper removes bestASR's.
public enum LoginItemRepair {
  /// `SMAppService.Status`, without importing ServiceManagement here.
  public enum Status: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
  }

  public enum Plan: Equatable, Sendable {
    /// Nothing to do.
    case keep
    /// Unregister and register again from this bundle, then remember it.
    case reregister
    /// The owner removed the item (in System Settings) where it was: forget
    /// the path and leave it off.
    case forget
  }

  /// The bundle path the login item was last registered from by this App.
  public static let registeredPathKey = "preferences.login-item-bundle-path"

  /// - `status`: the system's status for this App's login item, now.
  /// - `recordedPath`: where this App last registered it (nil: never, for
  ///   example the first launch after bestASR, which kept no such record).
  /// - `currentPath`: this bundle's path.
  public static func plan(status: Status, recordedPath: String?, currentPath: String) -> Plan {
    let moved = recordedPath.map { !samePath($0, currentPath) } ?? true
    switch status {
    case .enabled:
      // On, but registered from another bundle (or by bestASR): register
      // again from here so the item opens this App.
      return moved ? .reregister : .keep
    case .requiresApproval:
      // The owner turned it off in System Settings; that stays their choice.
      return .keep
    case .notRegistered, .notFound:
      // Never registered by this App: off is what the owner chose (or what
      // bestASR's item, if any, left behind; see the switch summary).
      guard recordedPath != nil else { return .keep }
      // Mindloom had it on and the App moved since: the system's item went
      // with the old bundle. Put it back for this one. Not moved: the owner
      // removed it in System Settings, and it stays off.
      return moved ? .reregister : .forget
    }
  }

  static func samePath(_ a: String, _ b: String) -> Bool {
    URL(fileURLWithPath: a).standardizedFileURL.resolvingSymlinksInPath().path
      == URL(fileURLWithPath: b).standardizedFileURL.resolvingSymlinksInPath().path
  }
}

/// The system's login item for this App (`SMAppService.mainApp` in the App).
public protocol LoginItemService {
  var status: LoginItemRepair.Status { get }
  func register() throws
  func unregister() throws
}

extension LoginItemRepair {
  /// Stands for 「registered by an App before this one recorded where」 while a
  /// re-registration is under way, so a failed `register()` is tried again on
  /// the next launch instead of leaving the item off for good.
  static let earlierAppMarker = "(registered by an earlier App)"

  /// Runs once per launch, before Settings shows 「登录时打开」. Returns the
  /// status afterwards.
  @discardableResult
  public static func repair(
    service: some LoginItemService, defaults: UserDefaults, currentPath: String
  ) -> Status {
    let recorded = defaults.string(forKey: registeredPathKey)
    switch plan(status: service.status, recordedPath: recorded, currentPath: currentPath) {
    case .keep:
      break
    case .forget:
      defaults.removeObject(forKey: registeredPathKey)
    case .reregister:
      defaults.set(recorded ?? earlierAppMarker, forKey: registeredPathKey)
      // The old item may already be gone; registering is what matters.
      try? service.unregister()
      if (try? service.register()) != nil {
        defaults.set(currentPath, forKey: registeredPathKey)
      }
    }
    return service.status
  }

  /// bestASR's 「登录时打开」 was on: Mindloom turns its own on from here and
  /// remembers where. Returns whether it is on now.
  @discardableResult
  public static func adoptPreviousApp(
    service: some LoginItemService, defaults: UserDefaults, currentPath: String
  ) -> Bool {
    if service.status != .enabled {
      try? service.register()
    }
    let on = service.status == .enabled
    if on { defaults.set(currentPath, forKey: registeredPathKey) }
    return on
  }

  /// The owner switched 「登录时打开」 in Settings.
  public static func recordChoice(
    on: Bool, status: Status, defaults: UserDefaults, currentPath: String
  ) {
    if on, status == .enabled || status == .requiresApproval {
      defaults.set(currentPath, forKey: registeredPathKey)
    } else if !on {
      defaults.removeObject(forKey: registeredPathKey)
    }
  }
}
