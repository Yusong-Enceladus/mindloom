import AppKit
import BestASRMemory
import BestASRRemoteOrganizer
import Foundation
import MindloomIdentity
import MindloomLibrary
import OSLog

/// The library this launch opens and how (v12 phase B), decided once from
/// the launch arguments (`LibraryLaunchSelection`):
///
/// - the product opens the owner's library unless told otherwise;
/// - Debug and every other development build refuse without
///   `-BestASRDataRoot <copy>` or an explicit `-BestASRUseRealLibrary YES`;
/// - `-MindloomDemoRoot <synthetic root>` opens demo mode in any build
///   (ALIGNMENT 根-10); Mindloom Preview always opens its synthetic root.
enum MindloomLaunch {
  /// Decided once, before anything opens the library. For the owner's
  /// library it refuses while bestASR's folder holds it and Mindloom's does
  /// not: only the switch script moves that folder (`LibraryFolderCarryOver`).
  static let current: Result<LibraryLaunch, LibraryLaunchError> = resolve(
    arguments: ProcessInfo.processInfo.arguments, flavor: MindloomBuild.flavor,
    infoDictionary: Bundle.main.infoDictionary ?? [:], previousAppRunning: previousAppRunning)

  static func resolve(
    arguments: [String], flavor: MindloomBuildFlavor, infoDictionary: [String: Any],
    realLibrary: URL? = BestASRDataRootSelection.ownerRealLibraryRoot(),
    previousAppRunning: () -> Bool = { false }
  ) -> Result<LibraryLaunch, LibraryLaunchError> {
    guard let realLibrary else { return .failure(.homeUnavailable) }
    let launch: LibraryLaunch
    do {
      launch = try LibraryLaunchSelection.resolve(
        arguments: arguments, flavor: flavor,
        previewDefaultRoot: infoDictionary["MindloomPreviewDataRoot"] as? String,
        realLibraryRoot: realLibrary)
    } catch let error as LibraryLaunchError {
      return .failure(error)
    } catch {
      return .failure(.homeUnavailable)
    }
    guard launch.mode == .ownerLibrary else { return .success(launch) }
    let outcome = LibraryFolderCarryOver.check(
      previous: LibraryFolderCarryOver.previousFolder(besides: launch.root), current: launch.root,
      previousAppRunning: previousAppRunning)
    let log = Logger(subsystem: MindloomIdentity.logSubsystem, category: "carry-over")
    switch outcome {
    case .ready:
      return .success(launch)
    case .bothPresent:
      log.notice("both library folders exist; opening Mindloom's, bestASR's left as it is")
      return .success(launch)
    case .previousAppRunning:
      return .failure(.previousAppUsesLibrary)
    case .atPreviousLocation:
      log.notice("the library is in bestASR's folder; nothing opened")
      return .failure(.libraryAtPreviousLocation)
    }
  }

  /// bestASR (or its development build) is running now.
  static func previousAppRunning() -> Bool {
    [MindloomIdentity.Previous.bundleID, MindloomIdentity.Previous.debugBundleID].contains {
      !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
    }
  }

  static var launch: LibraryLaunch? { try? current.get() }

  /// `-MindloomNoArm YES` (verification runs, any build): fn and the
  /// dictation shortcut stay unarmed.
  static let noArm = LibraryLaunchSelection.noArmRequested(
    arguments: ProcessInfo.processInfo.arguments)

  /// Demo mode: the root's own identity, time zone and Spark; dictation is
  /// typed into other Apps but not kept in the library.
  static var isDemo: Bool { launch?.isDemo ?? false }

  /// 「退出并重新打开 Mindloom」, or in demo mode 「退出并用演示方式重新打开
  /// Mindloom」: a demo launch lives in its arguments, and a plain reopen
  /// would put the owner's library on screen (review v12-B #7).
  static var reopenWords: String {
    isDemo ? "退出并用演示方式重新打开 Mindloom" : "退出并重新打开 Mindloom"
  }

  // MARK: Product time zone (ALIGNMENT 根-13)

  /// The library's product time zone (`library-settings.json`). With none
  /// stored, Mindloom Preview keeps its scenario's zone (Info.plist
  /// `MindloomPreviewTimeZone`); everything else uses Asia/Singapore.
  static func productTimeZone(
    root: URL?, flavor: MindloomBuildFlavor = MindloomBuild.flavor,
    infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
  ) -> TimeZone {
    let settings = root.map { LibrarySettingsFile(dataRoot: $0).load() } ?? LibrarySettings()
    let fallback =
      flavor == .preview ? infoDictionary["MindloomPreviewTimeZone"] as? String : nil
    return ProductTimeZone.resolve(settings, fallback: fallback)
  }

  /// Before the App starts: the process counts days in the product zone.
  /// A launch that opens no library (a refused development launch, the
  /// XCTest host) keeps the Mac's zone.
  static func applyProductTimeZone() {
    guard let launch else { return }
    let zone = productTimeZone(root: launch.root)
    ProductTimeZone.apply(zone)
    // 历史's day headers and search time words count days in it too.
    SearchClock.setProductTimeZone(zone)
    Logger(subsystem: MindloomIdentity.logSubsystem, category: "launch").notice(
      "product time zone \(zone.identifier, privacy: .public) demo=\(launch.isDemo, privacy: .public)")
  }

  /// What a refused launch says (the window shows it instead of the library).
  static func refusalMessage(_ error: LibraryLaunchError) -> String {
    switch error {
    case .developmentBuildNeedsLibrary:
      "这是开发版，打开时要指定资料库：用 -BestASRDataRoot 加资料库副本的路径启动；要打开你自己的资料库，加 -BestASRUseRealLibrary YES。"
    case .demoRootNotSynthetic:
      "演示方式要打开演示资料库，这个文件夹里没有演示资料的标记。"
    case .conflictingArguments:
      "启动参数指定了两个不同的资料库，移除其中一个再打开。"
    case .malformedArgument(let key):
      "启动参数 -\(key) 后面要跟一个以 / 开头的完整路径（或 YES），并且只写一次。"
    case .invalidRoot:
      "指定的资料库不能用：要写完整路径，并且不能是你自己的资料库或包含它的文件夹。"
    case .previewRootNotConfigured:
      "这个版本没有设定演示资料库；用 -MindloomDemoRoot 加演示资料库的路径启动。"
    case .homeUnavailable:
      "找不到你的用户文件夹，资料库没有打开。"
    case .previousAppUsesLibrary:
      "bestASR 正在使用你的资料库。请退出 bestASR，然后重新打开 Mindloom。"
    case .libraryAtPreviousLocation:
      "你的资料库还在 bestASR 的文件夹中，Mindloom 没有打开它。请继续使用 bestASR。"
    }
  }
}

/// Who this library belongs to. Normally the owner's identity in the App's
/// preferences; in demo mode the demo root's own `demo-profile.json`, and
/// the App's preferences for these keys are neither read nor written
/// (ALIGNMENT 根-10). Mindloom Preview, whose preferences are its own,
/// fills what the profile leaves out from them as before.
enum LibraryIdentity {
  static let selfPersonKey = "identity.local-self-person-id"
  static let originDeviceKey = "bestASR.local-origin-device-id"
  static let ownerNamesKey = "preferences.owner-names"
  static let organizerHostKey = "preferences.spark-organizer-host"
  static let organizerSocketKey = "preferences.spark-organizer-socket-path"
  static let organizerTokenKey = "preferences.spark-organizer-token-path"
  static let organizerInboxKey = "preferences.spark-organizer-inbox-command"

  /// The demo root's profile (made with its own 「我」 on first use), or nil
  /// outside demo mode.
  static let demoProfile: DemoProfile? = {
    guard let launch = MindloomLaunch.launch, launch.isDemo else { return nil }
    let preview = MindloomBuild.isPreview
    let defaults = UserDefaults.standard
    return DemoProfileFile(dataRoot: launch.root).loadEnsuringIdentity(
      existingSelf: preview ? defaults.string(forKey: selfPersonKey).flatMap(UUID.init) : nil,
      existingDevice: preview ? defaults.string(forKey: originDeviceKey).flatMap(UUID.init) : nil)
  }()

  /// Mindloom Preview may fall back to its own preferences; demo mode in
  /// any other build may not.
  private static var usesOwnPreferences: Bool {
    demoProfile == nil || MindloomBuild.isPreview
  }

  static var localSelfPersonID: UUID {
    if let id = demoProfile?.selfPersonID { return id }
    return storedUUID(selfPersonKey)
  }

  static var originDeviceID: UUID {
    if let id = demoProfile?.originDeviceID { return id }
    return storedUUID(originDeviceKey)
  }

  /// Other spellings of the owner's name: the profile's in demo mode
  /// (Mindloom Preview: else its Info.plist's `MindloomPreviewOwnerNames`);
  /// otherwise `preferences.owner-names` and the Mac user's full name.
  static func ownerNames(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:])
    -> [String]
  {
    var names: [String]
    if let profile = demoProfile {
      names = profile.ownerNames
      if names.isEmpty, MindloomBuild.isPreview,
        let preview = infoDictionary["MindloomPreviewOwnerNames"] as? String
      {
        names = preview.split(separator: ",").map { String($0) }
      }
    } else {
      names = (UserDefaults.standard.string(forKey: ownerNamesKey) ?? "")
        .split(separator: ",").map { String($0) }
      names.append(NSFullUserName())
    }
    var seen = Set<String>()
    return names.map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { $0.count >= 2 && seen.insert($0).inserted }
  }

  /// The UUID stored under `key` in the App's own preferences, made on
  /// first use (never called in demo mode outside Mindloom Preview).
  private static func storedUUID(_ key: String) -> UUID {
    let defaults = UserDefaults.standard
    if let value = defaults.string(forKey: key), let id = UUID(uuidString: value) { return id }
    let id = UUID()
    defaults.set(id.uuidString, forKey: key)
    return id
  }

  /// The organizing device's ssh host (nil: none named).
  static var organizerHost: String? {
    if let organizer = demoProfile?.organizer { return organizer.host }
    guard usesOwnPreferences else { return nil }
    return UserDefaults.standard.string(forKey: organizerHostKey)
  }

  static func organizerSocketPath(default fallback: String) -> String {
    organizerValue(\.socketPath, key: organizerSocketKey) ?? fallback
  }

  static func organizerTokenPath(default fallback: String) -> String {
    organizerValue(\.tokenPath, key: organizerTokenKey) ?? fallback
  }

  static func organizerInboxCommand(default fallback: String) -> String {
    organizerValue(\.inboxCommand, key: organizerInboxKey) ?? fallback
  }

  private static func organizerValue(
    _ path: KeyPath<DemoProfile.Organizer, String?>, key: String
  ) -> String? {
    if let organizer = demoProfile?.organizer { return organizer[keyPath: path] }
    guard usesOwnPreferences else { return nil }
    return UserDefaults.standard.string(forKey: key)
  }
}
