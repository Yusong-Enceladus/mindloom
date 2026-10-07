import Foundation
import MindloomLink
import XCTest

@testable import MindloomPhoneKit

/// A build without the App Group kept the app's files in its own Application Support and the share
/// extension's in its own container; the first build with the group moves them in once
/// (`PhoneStorageMigration`). Synthetic data only.
final class PhoneStorageMigrationTests: XCTestCase {
  private var root: URL!
  private var legacy: URL!
  private var group: URL!
  private let fm = FileManager.default

  override func setUpWithError() throws {
    root = try makeTemporaryDirectory()
    legacy = root.appendingPathComponent("app/Library/Application Support", isDirectory: true)
    group = root.appendingPathComponent("group", isDirectory: true)
    try fm.createDirectory(at: group, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? fm.removeItem(at: root)
  }

  // MARK: - Helpers

  private func write(_ text: String, _ path: String, in base: URL) throws {
    let url = base.appendingPathComponent(path)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  private func read(_ path: String, in base: URL) -> String? {
    (try? Data(contentsOf: base.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
  }

  private func exists(_ path: String, in base: URL) -> Bool {
    fm.fileExists(atPath: base.appendingPathComponent(path).path)
  }

  private lazy var record: PairingRecord = try! syntheticPairing(macKey: testMacKey).record

  /// The app's whole fallback layout, written by the real stores.
  private func seedLegacyApp() throws -> (item: PhoneItem, queued: OutboxEntry, sent: OutboxEntry) {
    let outbox = try OutboxStore(root: PhoneAppGroup.outboxDirectory(in: legacy))
    let queued = try makeEntry("合成：排队中")
    let sent = try makeEntry("合成：已送出", at: 5)
    try outbox.add(queued)
    try outbox.add(sent)
    try outbox.markSent(id: sent.entryID, at: baseDate)
    let items = try PhoneItemStore(root: PhoneItemStore.directory(in: legacy))
    let item = PhoneItem(
      createdAt: baseDate, kind: .photos, source: .share, photoCount: 1, entryIDs: [queued.entryID])
    try items.save(item)
    try items.writePreview(Data([0xFF, 0xD8, 0x01]), id: item.id, index: 0)
    try PairingRecordStore(file: PhoneAppGroup.pairingRecordFile(in: legacy)).write(record)
    try write("{}", "keyboard.json", in: legacy)
    // Not moved: a stale send claim, staging, the transient voice records.
    try write("", "outbox/sending/\(queued.entryID)", in: legacy)
    try write("half", "outbox/tmp/x.tmp", in: legacy)
    try write("{\"seq\":3}", "voice/state.json", in: legacy)
    return (item, queued, sent)
  }

  // MARK: - Fresh install

  func testFreshInstallWritesOnlyTheMarker() throws {
    let report = try PhoneStorageMigration.migrateApp(from: legacy, to: group)
    XCTAssertEqual(report.moved + report.kept + report.failed + report.replaced, 0)
    XCTAssertFalse(report.alreadyDone)
    XCTAssertTrue(PhoneStorageMigration.isDone(from: legacy))
    XCTAssertFalse(exists("outbox", in: group), "nothing is created in the group for nothing")
    XCTAssertFalse(exists("pairing.json", in: group))
    XCTAssertTrue(try PhoneStorageMigration.migrateApp(from: legacy, to: group).alreadyDone)
  }

  func testProtectedDataProbeLeavesNothingBehind() throws {
    XCTAssertTrue(PhoneStorageMigration.canUseProtectedData(in: legacy))
    XCTAssertEqual(try fm.contentsOfDirectory(atPath: legacy.path), [])
    let unwritable = root.appendingPathComponent("unwritable")
    try fm.createDirectory(at: unwritable, withIntermediateDirectories: true)
    try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: unwritable.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unwritable.path) }
    XCTAssertFalse(PhoneStorageMigration.canUseProtectedData(in: unwritable))
  }

  // MARK: - Fallback only

  func testFallbackOnlyDataMovesIntoTheGroup() throws {
    let seeded = try seedLegacyApp()
    let report = try PhoneStorageMigration.migrateApp(from: legacy, to: group)
    XCTAssertEqual(report.failed, 0)
    XCTAssertEqual(report.kept, 0)
    XCTAssertTrue(PhoneStorageMigration.isDone(from: legacy))

    // The group's stores see everything.
    let outbox = try OutboxStore(root: PhoneAppGroup.outboxDirectory(in: group))
    XCTAssertEqual(try outbox.queued().map(\.entryID), [seeded.queued.entryID])
    XCTAssertEqual(try outbox.sent(now: baseDate).map(\.entryID), [seeded.sent.entryID])
    let items = try PhoneItemStore(root: PhoneItemStore.directory(in: group))
    XCTAssertEqual(items.all(), [seeded.item])
    XCTAssertTrue(fm.fileExists(atPath: items.previewURL(id: seeded.item.id, index: 0).path))
    XCTAssertEqual(
      PairingRecordStore(file: PhoneAppGroup.pairingRecordFile(in: group)).read(), record)
    XCTAssertTrue(exists("keyboard.json", in: group))

    // The old place keeps no data file; what is never moved stays.
    XCTAssertEqual(
      PhoneStorageMigration.regularFiles(
        under: PhoneAppGroup.outboxDirectory(in: legacy), fileManager: fm), [])
    XCTAssertFalse(exists("pairing.json", in: legacy))
    XCTAssertFalse(exists("items/\(seeded.item.id).json", in: legacy))
    XCTAssertTrue(exists("voice/state.json", in: legacy), "voice records are transient: not moved")
    XCTAssertFalse(exists("voice", in: group))
    XCTAssertFalse(exists("outbox/sending/\(seeded.queued.entryID)", in: group), "no stale claim")
    XCTAssertFalse(exists("outbox/tmp/x.tmp", in: group))
  }

  func testAcrossVolumesItCopiesThenRemoves() throws {
    let seeded = try seedLegacyApp()
    let report = try PhoneStorageMigration.migrateApp(from: legacy, to: group, forceCopy: true)
    XCTAssertEqual(report.failed, 0)
    XCTAssertGreaterThanOrEqual(report.moved, 6)
    let outbox = try OutboxStore(root: PhoneAppGroup.outboxDirectory(in: group))
    XCTAssertEqual(try outbox.queued().map(\.entryID), [seeded.queued.entryID])
    XCTAssertFalse(exists("pairing.json", in: legacy))
    XCTAssertEqual(
      try fm.contentsOfDirectory(atPath: group.appendingPathComponent("migration-staging-app").path),
      [], "no copy is left in staging")
  }

  // MARK: - Both present

  private func setModified(_ path: String, in base: URL, _ date: Date) throws {
    try fm.setAttributes(
      [.modificationDate: date], ofItemAtPath: base.appendingPathComponent(path).path)
  }

  /// What the run put under `migration-conflicts/<tag>-…/` (one run's folder), by path.
  private func conflicts(_ tag: String) -> [String: String] {
    let base = group.appendingPathComponent(PhoneStorageMigration.conflictsName)
    var found: [String: String] = [:]
    for run in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where run.hasPrefix(tag + "-") {
      let folder = base.appendingPathComponent(run)
      for path in PhoneStorageMigration.regularFiles(under: folder, fileManager: fm) {
        found[path] = read(path, in: folder)
      }
    }
    return found
  }

  func testGroupItemsWinAndTheOldCopyIsKeptAside() throws {
    try write("legacy item", "items/X.json", in: legacy)
    try write("group item", "items/X.json", in: group)
    try write("same bytes", "outbox/queued/A.json", in: legacy)
    try write("same bytes", "outbox/queued/A.json", in: group)
    try write("legacy only", "outbox/queued/B.json", in: legacy)
    // An older pairing in the old place: the group's (newer) stays current.
    try write("legacy pairing", "pairing.json", in: legacy)
    try write("group pairing", "pairing.json", in: group)
    try setModified("pairing.json", in: legacy, baseDate)
    try setModified("pairing.json", in: group, baseDate.addingTimeInterval(60))

    let report = try PhoneStorageMigration.migrateApp(from: legacy, to: group)
    XCTAssertEqual(report.kept, 2)
    XCTAssertEqual(report.superseded, 0)
    XCTAssertEqual(report.deduplicated, 1)
    XCTAssertEqual(report.moved, 1)
    XCTAssertEqual(report.failed, 0)
    XCTAssertEqual(read("items/X.json", in: group), "group item")
    XCTAssertEqual(read("pairing.json", in: group), "group pairing")
    XCTAssertFalse(exists("items/X.json", in: legacy))
    XCTAssertFalse(exists("pairing.json", in: legacy))
    XCTAssertEqual(
      conflicts("app"), ["items/X.json": "legacy item", "pairing.json": "legacy pairing"],
      "the losing copies are kept, never deleted")
    XCTAssertFalse(exists("outbox/queued/A.json", in: legacy), "an identical copy is let go")
    XCTAssertEqual(read("outbox/queued/A.json", in: group), "same bytes")
    XCTAssertEqual(read("outbox/queued/B.json", in: group), "legacy only")
    XCTAssertTrue(PhoneStorageMigration.isDone(from: legacy))
  }

  /// group → a build without the group (re-paired there: a newer pairing.json in the old place)
  /// → group again: the newer pairing is current, the older one is kept aside.
  func testAfterARoundTripTheNewerPairingWins() throws {
    try write("first pairing", "pairing.json", in: legacy)
    try write("{\"kb\":1}", "keyboard.json", in: legacy)
    XCTAssertEqual(try PhoneStorageMigration.migrateApp(from: legacy, to: group).moved, 2)
    try setModified("pairing.json", in: group, baseDate)
    try setModified("keyboard.json", in: group, baseDate.addingTimeInterval(500))

    // The build without the group: forgets the marker, pairs again, sends one more entry.
    PhoneStorageMigration.forget(legacy: legacy, defaults: nil)
    try write("second pairing", "pairing.json", in: legacy)
    try write("{\"kb\":0}", "keyboard.json", in: legacy)
    try write("sealed to the second Mac", "outbox/queued/N.json", in: legacy)
    try setModified("pairing.json", in: legacy, baseDate.addingTimeInterval(100))
    try setModified("keyboard.json", in: legacy, baseDate.addingTimeInterval(100))

    let report = try PhoneStorageMigration.migrateApp(from: legacy, to: group)
    XCTAssertEqual(report.failed, 0)
    XCTAssertEqual(report.superseded, 1)
    XCTAssertEqual(report.kept, 1)
    XCTAssertEqual(report.moved, 1)
    XCTAssertEqual(read("pairing.json", in: group), "second pairing")
    XCTAssertEqual(read("keyboard.json", in: group), "{\"kb\":1}", "the newer keyboard report stays")
    XCTAssertEqual(read("outbox/queued/N.json", in: group), "sealed to the second Mac")
    XCTAssertEqual(
      conflicts("app"), ["pairing.json": "first pairing", "keyboard.json": "{\"kb\":0}"])
    XCTAssertFalse(exists("pairing.json", in: legacy))
  }

  /// A file that cannot be read is a failure (retried, no marker), never a silent "different".
  func testAnUnreadableFileIsRetriedNotKept() throws {
    try write("legacy", "items/X.json", in: legacy)
    try write("group", "items/X.json", in: group)
    let locked = legacy.appendingPathComponent("items/X.json").path
    try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
    defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked) }

    let first = try PhoneStorageMigration.migrateApp(from: legacy, to: group)
    XCTAssertEqual(first.failed, 1)
    XCTAssertEqual(first.kept, 0)
    XCTAssertFalse(PhoneStorageMigration.isDone(from: legacy))
    XCTAssertTrue(exists("items/X.json", in: legacy))

    try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked)
    let second = try PhoneStorageMigration.migrateApp(from: legacy, to: group)
    XCTAssertEqual(second.failed, 0)
    XCTAssertEqual(second.kept, 1)
    XCTAssertTrue(PhoneStorageMigration.isDone(from: legacy))
  }

  // MARK: - Partial previous migration

  func testAnInterruptedRunIsFinishedWithoutLoss() throws {
    // The run that died had renamed A (but not yet removed it: crash between copy-rename and
    // removal), left a copy of B in staging, and not reached C.
    try write("A", "outbox/queued/A.json", in: legacy)
    try write("A", "outbox/queued/A.json", in: group)
    try write("B", "outbox/queued/B.json", in: legacy)
    try write("B (partial", "migration-staging-app/1234", in: group)
    try write("C", "items/C.json", in: legacy)
    XCTAssertFalse(PhoneStorageMigration.isDone(from: legacy))

    let report = try PhoneStorageMigration.migrateApp(from: legacy, to: group)
    XCTAssertEqual(report.failed, 0)
    XCTAssertEqual(report.deduplicated, 1)
    XCTAssertEqual(report.moved, 2)
    for (path, text) in [("outbox/queued/A.json", "A"), ("outbox/queued/B.json", "B"), ("items/C.json", "C")] {
      XCTAssertEqual(read(path, in: group), text)
      XCTAssertFalse(exists(path, in: legacy))
    }
    XCTAssertEqual(
      try fm.contentsOfDirectory(atPath: group.appendingPathComponent("migration-staging-app").path),
      [])
    XCTAssertTrue(PhoneStorageMigration.isDone(from: legacy))
  }

  func testAFailedFileLeavesNoMarkerAndIsRetried() throws {
    try write("pairing", "pairing.json", in: legacy)
    try write("B", "outbox/queued/B.json", in: legacy)
    // The group's `outbox` is a file, so nothing can go under it this time.
    try write("in the way", "outbox", in: group)

    let first = try PhoneStorageMigration.migrateApp(from: legacy, to: group)
    XCTAssertEqual(first.failed, 1)
    XCTAssertEqual(first.moved, 1)
    XCTAssertFalse(PhoneStorageMigration.isDone(from: legacy), "no marker after a failure")
    XCTAssertEqual(read("outbox/queued/B.json", in: legacy), "B", "the file stays where it was")

    try fm.removeItem(at: group.appendingPathComponent("outbox"))
    let second = try PhoneStorageMigration.migrateApp(from: legacy, to: group)
    XCTAssertEqual(second.failed, 0)
    XCTAssertEqual(second.moved, 1)
    XCTAssertEqual(read("outbox/queued/B.json", in: group), "B")
    XCTAssertEqual(read("pairing.json", in: group), "pairing")
    XCTAssertTrue(PhoneStorageMigration.isDone(from: legacy))
  }

  // MARK: - Repeated launches

  func testRepeatedLaunchesChangeNothingUntilTheOldPlaceIsUsedAgain() throws {
    try write("A", "outbox/queued/A.json", in: legacy)
    XCTAssertEqual(try PhoneStorageMigration.migrateApp(from: legacy, to: group).moved, 1)

    // Written after the marker by this (group) build: not looked at again.
    try write("late", "outbox/queued/L.json", in: legacy)
    for _ in 0..<3 {
      let again = try PhoneStorageMigration.migrateApp(from: legacy, to: group)
      XCTAssertTrue(again.alreadyDone)
      XCTAssertEqual(again.moved, 0)
    }
    XCTAssertFalse(exists("outbox/queued/L.json", in: group))

    // A build without the group ran in between (a renewal without an Apple ID): it forgets the
    // marker, and the next build with the group moves what it wrote.
    PhoneStorageMigration.forget(legacy: legacy, defaults: nil)
    let after = try PhoneStorageMigration.migrateApp(from: legacy, to: group)
    XCTAssertEqual(after.moved, 1)
    XCTAssertEqual(read("outbox/queued/L.json", in: group), "late")
    XCTAssertEqual(read("outbox/queued/A.json", in: group), "A")
  }

  // MARK: - The share extension

  func testShareItemsReplaceTheAppsMirrorsOnly() throws {
    let share = root.appendingPathComponent("share/Library/Application Support/share")
    let entry = try makeEntry("合成：分享")
    let real = PhoneItem(
      createdAt: baseDate, kind: .link, source: .share, link: .init(url: "https://example.com"),
      entryIDs: [entry.entryID])
    try PhoneItemStore(root: PhoneItemStore.directory(in: share)).save(real)
    try OutboxStore(root: PhoneAppGroup.outboxDirectory(in: share)).add(entry)
    try write("handed-over copy", "pairing.json", in: share)
    // The app saved a mirror of the same item from the keychain handoff (and migrated it).
    var mirror = real
    mirror.entryIDs = []
    mirror.sharedOnPhone = true
    let groupItems = try PhoneItemStore(root: PhoneItemStore.directory(in: group))
    try groupItems.save(mirror)
    // An unrelated item in the group with the same id as nothing in the share: untouched.
    let own = PhoneItem(createdAt: baseDate, kind: .text, source: .keyboard, text: "合成")
    try groupItems.save(own)

    let report = try PhoneStorageMigration.migrateShare(from: share, to: group)
    XCTAssertEqual(report.failed, 0)
    XCTAssertEqual(report.replaced, 1)
    XCTAssertEqual(groupItems.item(id: real.id), real, "the real item, with its entries")
    XCTAssertEqual(groupItems.item(id: own.id), own)
    let outbox = try OutboxStore(root: PhoneAppGroup.outboxDirectory(in: group))
    XCTAssertEqual(try outbox.queued().map(\.entryID), [entry.entryID])
    XCTAssertFalse(exists("pairing.json", in: group), "the handed-over pairing stays behind")
    XCTAssertTrue(PhoneStorageMigration.isDone(from: share))
    XCTAssertTrue(try PhoneStorageMigration.migrateShare(from: share, to: group).alreadyDone)
  }

  func testAShareItemNeverReplacesTheGroupsOwnItem() throws {
    let share = root.appendingPathComponent("share-container/share")
    let item = PhoneItem(createdAt: baseDate, kind: .text, source: .share, text: "合成：分享里的")
    try PhoneItemStore(root: PhoneItemStore.directory(in: share)).save(item)
    var newer = item
    newer.note = "加一句"
    try PhoneItemStore(root: PhoneItemStore.directory(in: group)).save(newer)

    let report = try PhoneStorageMigration.migrateShare(from: share, to: group)
    XCTAssertEqual(report.kept, 1)
    XCTAssertEqual(report.replaced, 0)
    XCTAssertEqual(try PhoneItemStore(root: PhoneItemStore.directory(in: group)).item(id: item.id), newer)
  }

  /// The app moves its mirror of a shared item into the group while the share extension is
  /// between its existence check and its rename: the real item still replaces the mirror.
  func testAMirrorThatLandsDuringTheShareRunIsStillReplaced() throws {
    let share = root.appendingPathComponent("share-race/share")
    let entry = try makeEntry("合成：分享")
    let real = PhoneItem(
      createdAt: baseDate, kind: .text, source: .share, text: "合成：分享", entryIDs: [entry.entryID])
    try PhoneItemStore(root: PhoneItemStore.directory(in: share)).save(real)
    var mirror = real
    mirror.entryIDs = []
    mirror.sharedOnPhone = true
    let groupItems = try PhoneItemStore(root: PhoneItemStore.directory(in: group))
    let itemPath = "items/\(real.id).json"

    let report = try PhoneStorageMigration.migrate(
      tag: "share", from: share, entries: PhoneStorageMigration.shareEntries, to: group,
      fileManager: fm, forceCopy: false, replaces: PhoneStorageMigration.isShareMirror(_:),
      beforeExclusivePlace: { to in
        if to.path.hasSuffix(itemPath) { try? groupItems.save(mirror) }
      })
    XCTAssertEqual(report.failed, 0)
    XCTAssertEqual(report.replaced, 1)
    XCTAssertEqual(report.kept, 0)
    XCTAssertEqual(groupItems.item(id: real.id), real, "the real item, with its entries")
    XCTAssertFalse(exists(itemPath, in: share))
  }

  /// Shared before the app first ran with the group (or kept unsealed by the share extension
  /// while it had no pairing): the item waits for pairing in the group although the app is
  /// paired. The app's launch seals it (`sealAwaitingItems`), so it leaves.
  func testAnUnsealedShareItemIsSealedOnceInTheGroup() throws {
    let share = root.appendingPathComponent("share-unsealed/share")
    let shareItems = try PhoneItemStore(root: PhoneItemStore.directory(in: share))
    let shareCollector = PhoneItemCollector(
      items: shareItems, outbox: try OutboxStore(root: PhoneAppGroup.outboxDirectory(in: share)),
      pairing: PairingRecordStore(file: share.appendingPathComponent("pairing.json")),
      signaling: nil)
    let waiting = try shareCollector.collect(
      PhoneItem(createdAt: baseDate, kind: .text, source: .share, text: "合成：等配对"),
      payloads: [try InboxItemPayload.text("合成：等配对", source: .share, createdAt: baseDate)])
    XCTAssertTrue(waiting.awaitingPairing)
    // The app's migration already put its pairing into the group.
    try PairingRecordStore(file: PhoneAppGroup.pairingRecordFile(in: group)).write(record)

    XCTAssertEqual(try PhoneStorageMigration.migrateShare(from: share, to: group).failed, 0)
    let collector = PhoneItemCollector(
      items: try PhoneItemStore(root: PhoneItemStore.directory(in: group)),
      outbox: try OutboxStore(root: PhoneAppGroup.outboxDirectory(in: group)),
      pairing: PairingRecordStore(file: PhoneAppGroup.pairingRecordFile(in: group)),
      signaling: nil)
    XCTAssertTrue(try XCTUnwrap(collector.items.item(id: waiting.id)).awaitingPairing)
    XCTAssertEqual(try collector.sealAwaitingItems(), 1)
    let sealed = try XCTUnwrap(collector.items.item(id: waiting.id))
    XCTAssertFalse(sealed.awaitingPairing)
    XCTAssertEqual(sealed.entryIDs.count, 1)
    XCTAssertEqual(try collector.outbox.queued().map(\.entryID), sealed.entryIDs)
    XCTAssertNil(collector.items.unsealed(id: waiting.id))
    XCTAssertEqual(try collector.sealAwaitingItems(), 0, "idempotent")
  }

  /// With the group the app keeps reading the list a build without it left in the keychain
  /// (until the share extension moves its items): it updates mirrors, never the real item.
  func testTheLeftoverShareListNeverOverwritesTheRealItem() throws {
    let records = try FileRecords(directory: root.appendingPathComponent("records"))
    let handoff = ShareHandoff(records: records)
    XCTAssertFalse(handoff.hasItems)
    let entry = try makeEntry("合成：分享")
    let real = PhoneItem(
      createdAt: baseDate, kind: .text, source: .share, text: "合成：分享", entryIDs: [entry.entryID])
    let other = PhoneItem(createdAt: baseDate, kind: .text, source: .share, text: "合成：另一条")
    try handoff.writeItems([.init(item: real, onPhone: true), .init(item: other, onPhone: true)])
    XCTAssertTrue(handoff.hasItems)
    let store = try PhoneItemStore(root: PhoneItemStore.directory(in: group))
    try store.save(real)

    XCTAssertEqual(handoff.importItems(into: store), 1)
    XCTAssertEqual(store.item(id: real.id), real, "the moved real item keeps its entries")
    XCTAssertEqual(store.item(id: other.id)?.sharedOnPhone, true, "a mirror for the other")
    try handoff.writeItems([.init(item: other, onPhone: false)])
    XCTAssertEqual(handoff.importItems(into: store), 1)
    XCTAssertEqual(store.item(id: other.id)?.sharedOnPhone, false)
  }

  // MARK: - Settings

  func testSettingsMoveOnceAndAfterARoundTripTheNewerWins() throws {
    let legacyName = "mindloom-tests-legacy-\(UUID().uuidString)"
    let groupName = "mindloom-tests-group-\(UUID().uuidString)"
    let old = try XCTUnwrap(UserDefaults(suiteName: legacyName))
    let shared = try XCTUnwrap(UserDefaults(suiteName: groupName))
    defer {
      old.removePersistentDomain(forName: legacyName)
      shared.removePersistentDomain(forName: groupName)
    }
    let oldSettings = PhoneSettings(defaults: old, isShared: false)
    oldSettings.welcomeDone = true
    oldSettings.idleMinutes = 30
    oldSettings.sendKeyboardSpeech = false
    oldSettings.debugKeyboardScreen = "kb-listen"
    let groupSettings = PhoneSettings(defaults: shared, isShared: true)
    groupSettings.idleMinutes = 5

    XCTAssertEqual(PhoneStorageMigration.migrateSettings(from: old, to: shared), 2)
    XCTAssertTrue(groupSettings.welcomeDone)
    XCTAssertFalse(groupSettings.sendKeyboardSpeech)
    XCTAssertEqual(groupSettings.idleMinutes, 5, "the first time, the group's own value wins")
    XCTAssertNil(groupSettings.debugKeyboardScreen, "a DEBUG screenshot state never moves")
    XCTAssertNil(old.object(forKey: "app.welcome_done"), "moved out of the old defaults")
    XCTAssertNil(old.object(forKey: "voice.idle_minutes"))

    oldSettings.disconnected = true
    XCTAssertEqual(PhoneStorageMigration.migrateSettings(from: old, to: shared), 0, "once")
    XCTAssertFalse(groupSettings.disconnected)

    // A build without the group ran in between and changed two switches there.
    PhoneStorageMigration.forget(legacy: nil, defaults: old)
    oldSettings.idleMinutes = 30
    XCTAssertEqual(PhoneStorageMigration.migrateSettings(from: old, to: shared), 2)
    XCTAssertTrue(groupSettings.disconnected)
    XCTAssertEqual(groupSettings.idleMinutes, 30, "after a round trip the newer value wins")
    XCTAssertTrue(groupSettings.welcomeDone, "untouched in between: the group's stays")
    XCTAssertFalse(groupSettings.sendKeyboardSpeech)
  }

  /// Defaults that could not be read (before first unlock) look empty: no marker, so the next
  /// launch looks again.
  func testUnreadableSettingsAreLookedAtAgain() throws {
    let legacyName = "mindloom-tests-legacy-\(UUID().uuidString)"
    let groupName = "mindloom-tests-group-\(UUID().uuidString)"
    let old = try XCTUnwrap(UserDefaults(suiteName: legacyName))
    let shared = try XCTUnwrap(UserDefaults(suiteName: groupName))
    defer {
      old.removePersistentDomain(forName: legacyName)
      shared.removePersistentDomain(forName: groupName)
    }
    XCTAssertEqual(
      PhoneStorageMigration.migrateSettings(from: old, to: shared, legacyDomain: legacyName), 0)
    XCTAssertFalse(old.bool(forKey: PhoneStorageMigration.settingsMarkerKey))

    PhoneSettings(defaults: old, isShared: false).welcomeDone = true
    XCTAssertEqual(
      PhoneStorageMigration.migrateSettings(from: old, to: shared, legacyDomain: legacyName), 1)
    XCTAssertTrue(old.bool(forKey: PhoneStorageMigration.settingsMarkerKey))
    XCTAssertTrue(PhoneSettings(defaults: shared, isShared: true).welcomeDone)
  }
}
