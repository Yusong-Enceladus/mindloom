import Foundation
import XCTest

@testable import MindloomLibrary

/// The switch (ALIGNMENT 根-9; 10/5–10/6): Mindloom (`app.mindloom`) replaces
/// the daily bestASR (d54fb45, `com.bestasr.app`). Every d54 key is imported
/// into Mindloom's domain and keeps working, is turned into Mindloom's, or is
/// left behind for a reason; 「登录时打开」 follows the App to its new path
/// and from bestASR's identity to Mindloom's.
final class ProductCarryOverTests: XCTestCase {
  private var suite: String!
  private var defaults: UserDefaults!

  override func setUpWithError() throws {
    suite = "mindloom.tests.carry-over.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
  }

  override func tearDownWithError() throws {
    defaults?.removePersistentDomain(forName: suite)
  }

  private static var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }

  /// Every Swift file Mindloom is built from (the App and the packages),
  /// without tests and without this table itself.
  private static func productSources() throws -> String {
    let root = repositoryRoot
    var text = ""
    for folder in ["App", "Packages/BestASRCore/Sources", "Packages/MindloomLink/Sources"] {
      let base = root.appendingPathComponent(folder)
      let walker = try XCTUnwrap(
        FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
      for case let url as URL in walker where url.pathExtension == "swift" {
        if url.lastPathComponent == "ProductCarryOver.swift" { continue }
        text += try String(contentsOf: url, encoding: .utf8)
      }
    }
    return text
  }

  // MARK: Preferences

  /// Each key d54 kept that Mindloom honors is still read by Mindloom under
  /// the same name; a rename fails here instead of resetting the setting.
  func testEveryHonoredD54KeyIsStillReadByMindloom() throws {
    let sources = try Self.productSources()
    let honored = ProductCarryOver.d54Keys.filter { $0.disposition == .honored }.map(\.key)
    // 34 d54 keys read or written: 26 honored, 1 migrated, 7 not carried (bestASR's grants
    // and its menu bar switch).
    XCTAssertGreaterThanOrEqual(honored.count, 26)
    for key in honored {
      XCTAssertTrue(sources.contains("\"\(key)\""), "\(key) is no longer read by Mindloom")
    }
  }

  /// A migrated key's target is a key Mindloom reads; a retired key is read
  /// by nothing (so leaving it in place changes nothing).
  func testMigratedAndRetiredKeysAreWhatTheySay() throws {
    let sources = try Self.productSources()
    for (key, disposition) in ProductCarryOver.d54Keys {
      switch disposition {
      case .honored: break
      case .migrated(let target):
        XCTAssertTrue(sources.contains("\"\(target)\""), "\(key) → \(target), which nothing reads")
        XCTAssertFalse(sources.contains("\"\(key)\""), "\(key) is migrated but still read")
      case .notCarried:
        XCTAssertTrue(sources.contains("\"\(key)\""), "\(key) is not carried and not read")
      case .retired:
        XCTAssertFalse(sources.contains("\"\(key)\""), "\(key) is retired but still read")
      }
    }
    XCTAssertEqual(Set(ProductCarryOver.d54Keys.map(\.key)).count, ProductCarryOver.d54Keys.count)
  }

  /// The keys the owner's own domain held on 10-6 (names only, listed by a
  /// script that printed no value) are all accounted for, window frames aside.
  func testTheOwnersKeysOnTheSwitchDayAreAllAccountedFor() {
    let listed = Set(ProductCarryOver.d54Keys.map(\.key))
    let ownersKeys = [
      "bestASR.applicationsExposingText", "bestASR.local-origin-device-id",
      "bestASR.unverifiedPasteStreaks", "dictation.hotkeys.v1", "identity.local-self-person-id",
      "model-license-receipt.fluid-sensevoice-small-int8",
      "model-license-receipt.fluid-speaker-diarization-coreml",
      "model-license-receipt.qwen3-1.7b-mlx-4bit", "onboarding.microphone-checked-v1",
      "onboarding.models-deferred-v1", "onboarding.permissions-deferred-v1",
      "onboarding.practice-completed-v1", "onboarding.practice-deferred-v1",
      "permissions.accessibility-granted-v1", "permissions.microphone-granted-v1",
      "permissions.system-audio-granted-v1", "preferences.default-polish-enabled",
      "preferences.default-polish-off-migration-v1", "preferences.interface-language",
      "preferences.menu-bar-enabled", "preferences.recent-system-audio-sources",
      "preferences.system-audio-include-microphone",
      "preferences.system-audio-microphone-overrides.v1", "preferences.system-audio-source",
      "preferences.translation-languages",
    ]
    for key in ownersKeys { XCTAssertTrue(listed.contains(key), key) }
  }

  // MARK: Import from bestASR's domain

  private func bestASRDomain(_ values: [String: Any]) -> (String) -> Any? {
    { values[$0] }
  }

  /// Every honored and migrated key comes over with its value and type; the
  /// grants macOS gave bestASR and the retired keys do not.
  func testBestASRsSettingsAreImportedOnce() {
    let hotkeys = Data(#"{"fn":true}"#.utf8)
    var old: [String: Any] = [
      "dictation.hotkeys.v1": hotkeys,
      "preferences.menu-bar-enabled": false,
      "preferences.translation-languages": ["en", "ja"],
      "identity.local-self-person-id": "7D0F3A52-9C1E-4B5A-8F00-1234567890AB",
      "bestASR.local-origin-device-id": "0E7A3C9D-5B2F-4A61-9D8E-ABCDEFABCDEF",
      "preferences.capsule-subtitles-hover-only": true,
      "preferences.app-text-policies.v1": ["com.tencent.xinWeChat": "plain"],
      "permissions.accessibility-granted-v1": true,
      "permissions.microphone-granted-v1": true,
      "onboarding.permissions-deferred-v1": true,
      "bestASR.unverifiedPasteStreaks": ["x": 1],
    ]
    old["onboarding.practice-completed-v1"] = true
    let count = ProductCarryOver.importPreferences(into: defaults, read: bestASRDomain(old))
    XCTAssertEqual(count, 7)
    XCTAssertEqual(defaults.data(forKey: "dictation.hotkeys.v1"), hotkeys)
    // bestASR's menu bar switch stays bestASR's: Mindloom records from its
    // menu bar, which starts on (review of 10-6).
    XCTAssertNil(defaults.object(forKey: "preferences.menu-bar-enabled"))
    XCTAssertEqual(defaults.stringArray(forKey: "preferences.translation-languages"), ["en", "ja"])
    XCTAssertEqual(
      defaults.string(forKey: "identity.local-self-person-id"),
      "7D0F3A52-9C1E-4B5A-8F00-1234567890AB")
    XCTAssertEqual(
      defaults.dictionary(forKey: "preferences.app-text-policies.v1") as? [String: String],
      ["com.tencent.xinWeChat": "plain"])
    XCTAssertEqual(defaults.object(forKey: "onboarding.practice-completed-v1") as? Bool, true)
    // bestASR's grants and its setup deferral are its own: Mindloom asks again.
    XCTAssertNil(defaults.object(forKey: "permissions.accessibility-granted-v1"))
    XCTAssertNil(defaults.object(forKey: "permissions.microphone-granted-v1"))
    XCTAssertNil(defaults.object(forKey: "onboarding.permissions-deferred-v1"))
    XCTAssertNil(defaults.object(forKey: "bestASR.unverifiedPasteStreaks"))
    XCTAssertTrue(defaults.bool(forKey: ProductCarryOver.cameFromBestASRKey))
    // Then the hover-only subtitles become Mindloom's setting.
    ProductCarryOver.migratePreferences(defaults)
    XCTAssertEqual(defaults.object(forKey: ProductCarryOver.dictationCaptionsKey) as? Bool, false)
    // Once: a later change in bestASR's domain is not taken again.
    old["preferences.translation-languages"] = ["fr"]
    XCTAssertEqual(ProductCarryOver.importPreferences(into: defaults, read: bestASRDomain(old)), 0)
    XCTAssertEqual(defaults.stringArray(forKey: "preferences.translation-languages"), ["en", "ja"])
  }

  func testMindloomsOwnValuesAreNeverOverwritten() {
    defaults.set(true, forKey: "preferences.speaker-memory-enabled")
    ProductCarryOver.importPreferences(
      into: defaults, read: bestASRDomain(["preferences.speaker-memory-enabled": false]))
    XCTAssertEqual(defaults.object(forKey: "preferences.speaker-memory-enabled") as? Bool, true)
  }

  /// A Mac without bestASR: nothing imported, Welcome says nothing about it.
  func testNoBestASRNoImport() {
    XCTAssertEqual(ProductCarryOver.importPreferences(into: defaults, read: { _ in nil }), 0)
    XCTAssertTrue(defaults.bool(forKey: ProductCarryOver.importDoneKey))
    XCTAssertFalse(defaults.bool(forKey: ProductCarryOver.cameFromBestASRKey))
  }

  /// The organizing link's settings are never imported, whatever a list says,
  /// so no carried setting switches an old DGX Spark link on.
  func testTheOrganizingLinksSettingsAreNeverImported() {
    for key in [
      "preferences.spark-organizer-host", "preferences.spark-organizer-socket-path",
      "preferences.spark-organizer-token-path", "preferences.spark-organizer-inbox-command",
      "remote-organizer.enabled", "link-on-x", "spaces.enabled",
    ] {
      XCTAssertTrue(ProductCarryOver.neverImported(key), key)
    }
    XCTAssertTrue(ProductCarryOver.importedKeys.allSatisfy { !ProductCarryOver.neverImported($0) })
    XCTAssertEqual(
      Set(ProductCarryOver.importedKeys).count, ProductCarryOver.importedKeys.count)
    // 26 honored and 1 migrated (bestASR's menu bar switch stays its own).
    XCTAssertGreaterThanOrEqual(ProductCarryOver.importedKeys.count, 27)
    XCTAssertFalse(ProductCarryOver.importedKeys.contains("preferences.menu-bar-enabled"))
  }

  /// d54 showed the capsule's live text on hover only: Mindloom keeps it off.
  func testHoverOnlySubtitlesBecomeNoCaptionsOnce() {
    defaults.set(true, forKey: "preferences.capsule-subtitles-hover-only")
    ProductCarryOver.migratePreferences(defaults)
    XCTAssertEqual(defaults.object(forKey: ProductCarryOver.dictationCaptionsKey) as? Bool, false)
    // The old key stays for the old App.
    XCTAssertEqual(
      defaults.object(forKey: "preferences.capsule-subtitles-hover-only") as? Bool, true)
    // The owner turns captions on in Mindloom: a later launch keeps that.
    defaults.set(true, forKey: ProductCarryOver.dictationCaptionsKey)
    ProductCarryOver.migratePreferences(defaults)
    XCTAssertEqual(defaults.object(forKey: ProductCarryOver.dictationCaptionsKey) as? Bool, true)
  }

  func testAlwaysShownSubtitlesKeepMindloomsDefault() {
    defaults.set(false, forKey: "preferences.capsule-subtitles-hover-only")
    ProductCarryOver.migratePreferences(defaults)
    XCTAssertNil(defaults.object(forKey: ProductCarryOver.dictationCaptionsKey))
    XCTAssertTrue(defaults.bool(forKey: ProductCarryOver.carryOverDoneKey))
  }

  func testMindloomsOwnCaptionsChoiceIsNeverOverwritten() {
    defaults.set(true, forKey: "preferences.capsule-subtitles-hover-only")
    defaults.set(true, forKey: ProductCarryOver.dictationCaptionsKey)
    ProductCarryOver.migratePreferences(defaults)
    XCTAssertEqual(defaults.object(forKey: ProductCarryOver.dictationCaptionsKey) as? Bool, true)
  }

  // MARK: Login item

  private final class FakeLoginItems: LoginItemService {
    var status: LoginItemRepair.Status
    var registerFails = false
    var calls: [String] = []
    init(_ status: LoginItemRepair.Status) { self.status = status }
    func register() throws {
      calls.append("register")
      if registerFails { throw CocoaError(.featureUnsupported) }
      status = .enabled
    }
    func unregister() throws {
      calls.append("unregister")
      status = .notRegistered
    }
  }

  private let mindloom = "/Users/owner/Applications/Mindloom.app"
  private let bestASR = "/Users/owner/Applications/bestASR.app"

  func testThePlanForEachState() {
    typealias P = LoginItemRepair
    // bestASR registered it (it kept no path): register again from here.
    XCTAssertEqual(P.plan(status: .enabled, recordedPath: nil, currentPath: mindloom), .reregister)
    XCTAssertEqual(
      P.plan(status: .enabled, recordedPath: bestASR, currentPath: mindloom), .reregister)
    XCTAssertEqual(P.plan(status: .enabled, recordedPath: mindloom, currentPath: mindloom), .keep)
    XCTAssertEqual(
      P.plan(status: .enabled, recordedPath: mindloom + "/", currentPath: mindloom), .keep)
    // Turned off in System Settings: the owner's choice.
    XCTAssertEqual(
      P.plan(status: .requiresApproval, recordedPath: bestASR, currentPath: mindloom), .keep)
    // Never on here.
    XCTAssertEqual(P.plan(status: .notRegistered, recordedPath: nil, currentPath: mindloom), .keep)
    XCTAssertEqual(P.plan(status: .notFound, recordedPath: nil, currentPath: mindloom), .keep)
    // On before the App moved: the item went with the old bundle.
    XCTAssertEqual(
      P.plan(status: .notRegistered, recordedPath: bestASR, currentPath: mindloom), .reregister)
    // Removed by the owner where it was.
    XCTAssertEqual(
      P.plan(status: .notRegistered, recordedPath: mindloom, currentPath: mindloom), .forget)
  }

  /// The switch: bestASR had 「登录时打开」 on; Mindloom's first launch makes
  /// the item open Mindloom.app and remembers where.
  func testTheFirstLaunchAfterBestASRRegistersFromTheNewApp() {
    let items = FakeLoginItems(.enabled)
    let after = LoginItemRepair.repair(service: items, defaults: defaults, currentPath: mindloom)
    XCTAssertEqual(items.calls, ["unregister", "register"])
    XCTAssertEqual(after, .enabled)
    XCTAssertEqual(defaults.string(forKey: LoginItemRepair.registeredPathKey), mindloom)
    // The next launch leaves it alone.
    items.calls = []
    LoginItemRepair.repair(service: items, defaults: defaults, currentPath: mindloom)
    XCTAssertEqual(items.calls, [])
  }

  /// A failed register is tried again on the next launch, not lost.
  func testAFailedRegisterIsTriedAgainNextLaunch() {
    let items = FakeLoginItems(.enabled)
    items.registerFails = true
    XCTAssertEqual(
      LoginItemRepair.repair(service: items, defaults: defaults, currentPath: mindloom),
      .notRegistered)
    XCTAssertEqual(
      defaults.string(forKey: LoginItemRepair.registeredPathKey), LoginItemRepair.earlierAppMarker)
    items.registerFails = false
    items.calls = []
    XCTAssertEqual(
      LoginItemRepair.repair(service: items, defaults: defaults, currentPath: mindloom), .enabled)
    XCTAssertEqual(items.calls, ["unregister", "register"])
    XCTAssertEqual(defaults.string(forKey: LoginItemRepair.registeredPathKey), mindloom)
  }

  func testOffStaysOffAndARemovalIsForgotten() {
    let off = FakeLoginItems(.notRegistered)
    LoginItemRepair.repair(service: off, defaults: defaults, currentPath: mindloom)
    XCTAssertEqual(off.calls, [])
    XCTAssertNil(defaults.string(forKey: LoginItemRepair.registeredPathKey))
    defaults.set(mindloom, forKey: LoginItemRepair.registeredPathKey)
    LoginItemRepair.repair(service: off, defaults: defaults, currentPath: mindloom)
    XCTAssertEqual(off.calls, [])
    XCTAssertNil(defaults.string(forKey: LoginItemRepair.registeredPathKey))
    let approval = FakeLoginItems(.requiresApproval)
    defaults.set(bestASR, forKey: LoginItemRepair.registeredPathKey)
    LoginItemRepair.repair(service: approval, defaults: defaults, currentPath: mindloom)
    XCTAssertEqual(approval.calls, [])
  }

  /// bestASR had 「登录时打开」 on (the switch's helper says so): Mindloom turns
  /// its own on, from where it runs, and remembers where.
  func testBestASRsLoginItemBecomesMindloomsOwn() {
    let items = FakeLoginItems(.notRegistered)
    XCTAssertTrue(
      LoginItemRepair.adoptPreviousApp(service: items, defaults: defaults, currentPath: mindloom))
    XCTAssertEqual(items.calls, ["register"])
    XCTAssertEqual(defaults.string(forKey: LoginItemRepair.registeredPathKey), mindloom)
    // The next launch leaves it alone.
    items.calls = []
    LoginItemRepair.repair(service: items, defaults: defaults, currentPath: mindloom)
    XCTAssertEqual(items.calls, [])
    // A refused register is said, and nothing recorded.
    let refusing = FakeLoginItems(.notRegistered)
    refusing.registerFails = true
    defaults.removeObject(forKey: LoginItemRepair.registeredPathKey)
    XCTAssertFalse(
      LoginItemRepair.adoptPreviousApp(service: refusing, defaults: defaults, currentPath: mindloom)
    )
    XCTAssertNil(defaults.string(forKey: LoginItemRepair.registeredPathKey))
  }

  func testTheSettingsSwitchIsRecorded() {
    LoginItemRepair.recordChoice(
      on: true, status: .enabled, defaults: defaults, currentPath: mindloom)
    XCTAssertEqual(defaults.string(forKey: LoginItemRepair.registeredPathKey), mindloom)
    LoginItemRepair.recordChoice(
      on: false, status: .notRegistered, defaults: defaults, currentPath: mindloom)
    XCTAssertNil(defaults.string(forKey: LoginItemRepair.registeredPathKey))
  }
}
