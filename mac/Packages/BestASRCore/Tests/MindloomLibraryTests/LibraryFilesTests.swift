import Foundation
import XCTest

@testable import MindloomLibrary

/// v12 phase B: the product time zone stored in the library (根-13), the
/// demo root's own identity (根-10), and the ledger of demo dictations.
final class LibraryFilesTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("library-files-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  // MARK: Product time zone

  /// Review v12-B #14 (regression): changing the zone while the App runs
  /// never touches the process's environment (other threads read it);
  /// Foundation's default zone follows at once.
  func testAZoneChangedWhileRunningLeavesTheEnvironmentAlone() throws {
    let before = getenv("TZ").map { String(cString: $0) }
    let defaultBefore = NSTimeZone.default
    defer { NSTimeZone.default = defaultBefore }
    let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
    ProductTimeZone.applyWhileRunning(tokyo)
    XCTAssertEqual(getenv("TZ").map { String(cString: $0) }, before)
    XCTAssertEqual(NSTimeZone.default.identifier, "Asia/Tokyo")
    XCTAssertEqual(Calendar.current.timeZone.identifier, "Asia/Tokyo")
  }

  func testTheDefaultProductTimeZoneIsSingapore() {
    let file = LibrarySettingsFile(dataRoot: root)
    XCTAssertEqual(file.load(), LibrarySettings())
    XCTAssertEqual(ProductTimeZone.resolve(file.load()).identifier, "Asia/Singapore")
  }

  func testTheLibraryKeepsItsOwnTimeZone() throws {
    let file = LibrarySettingsFile(dataRoot: root)
    try file.save(LibrarySettings(timeZoneIdentifier: "Asia/Shanghai"))
    XCTAssertEqual(file.load().timeZoneIdentifier, "Asia/Shanghai")
    XCTAssertEqual(ProductTimeZone.resolve(file.load()).identifier, "Asia/Shanghai")
    let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  /// v12 F1: 允许其他 App 读 is off unless this library says on; changing the
  /// time zone keeps it.
  func testOtherAppsReadOnlyWhenTheLibrarySaysSo() throws {
    let file = LibrarySettingsFile(dataRoot: root)
    XCTAssertFalse(file.load().otherAppsCanRead)
    var settings = file.load()
    settings.otherAppsCanRead = true
    try file.save(settings)
    var zone = file.load()
    zone.timeZoneIdentifier = "Asia/Tokyo"
    try file.save(zone)
    XCTAssertTrue(file.load().otherAppsCanRead)
    XCTAssertEqual(file.load().timeZoneIdentifier, "Asia/Tokyo")
    try Data(#"{"time_zone":"Asia/Tokyo","other_apps_can_read":"yes"}"#.utf8).write(to: file.url)
    XCTAssertFalse(file.load().otherAppsCanRead, "anything but true is off")
    XCTAssertEqual(file.load().timeZoneIdentifier, "Asia/Tokyo")
  }

  func testUnknownOrDamagedSettingsFallBack() throws {
    let file = LibrarySettingsFile(dataRoot: root)
    for unknown in ["PST", "GMT+8", "Etc/GMT-8", "Mars/Olympus_Mons"] {
      try Data(#"{"time_zone":"\#(unknown)"}"#.utf8).write(to: file.url)
      XCTAssertEqual(ProductTimeZone.resolve(file.load()).identifier, "Asia/Singapore", unknown)
    }
    XCTAssertEqual(
      ProductTimeZone.resolve(file.load(), fallback: "Asia/Shanghai").identifier, "Asia/Shanghai")
    try Data("not json".utf8).write(to: file.url)
    XCTAssertEqual(file.load(), LibrarySettings())
  }

  /// The case that made 根-13: an item due 「今天」 in Singapore is already
  /// due while the Mac's own zone (Los Angeles) is still on the day before.
  func testDaysAreCountedInTheProductZoneNotTheMacs() throws {
    let moment = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-05T17:30:00Z"))
    let singapore = ProductTimeZone.calendar(try XCTUnwrap(ProductTimeZone.zone("Asia/Singapore")))
    let losAngeles = ProductTimeZone.calendar(
      try XCTUnwrap(ProductTimeZone.zone("America/Los_Angeles")))
    XCTAssertEqual(singapore.component(.day, from: moment), 6)
    XCTAssertEqual(losAngeles.component(.day, from: moment), 5)
  }

  func testApplyingTheZoneChangesTheProcessCalendarsAndCanBeUndone() throws {
    let tokyo = try XCTUnwrap(ProductTimeZone.zone("Asia/Tokyo"))
    let before = TimeZone.current.identifier
    let previous = ProductTimeZone.apply(tokyo)
    XCTAssertEqual(TimeZone.current.identifier, "Asia/Tokyo")
    XCTAssertEqual(Calendar.current.timeZone.identifier, "Asia/Tokyo")
    XCTAssertEqual(TimeZone.autoupdatingCurrent.identifier, "Asia/Tokyo")
    ProductTimeZone.restore(previous)
    XCTAssertEqual(TimeZone.current.identifier, before)
  }

  func testSettingsOffersEachZoneOnceWithAPlainLabel() throws {
    let singapore = try XCTUnwrap(ProductTimeZone.zone("Asia/Singapore"))
    let mac = try XCTUnwrap(ProductTimeZone.zone("America/Los_Angeles"))
    let choices = ProductTimeZone.choices(current: singapore, mac: mac)
    XCTAssertEqual(choices.first?.identifier, "Asia/Singapore")
    XCTAssertEqual(choices.dropFirst().first?.identifier, "America/Los_Angeles")
    XCTAssertEqual(Set(choices.map(\.identifier)).count, choices.count)
    let moment = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-05T00:00:00Z"))
    XCTAssertEqual(ProductTimeZone.label(singapore, now: moment), "新加坡时间（GMT+8）")
    XCTAssertEqual(ProductTimeZone.offset(mac, at: moment), "GMT-7")
    let kolkata = try XCTUnwrap(ProductTimeZone.zone("Asia/Kolkata"))
    XCTAssertEqual(ProductTimeZone.offset(kolkata, at: moment), "GMT+5:30")
  }

  // MARK: Demo profile

  func testADemoRootGetsItsOwnIdentityOnFirstUse() throws {
    let file = DemoProfileFile(dataRoot: root)
    XCTAssertNil(file.load())
    let first = file.loadEnsuringIdentity()
    let selfID = try XCTUnwrap(first.selfPersonID)
    XCTAssertNotNil(first.originDeviceID)
    // Saved: the next launch has the same 「我」.
    XCTAssertEqual(file.loadEnsuringIdentity().selfPersonID, selfID)
    XCTAssertEqual(file.load()?.selfPersonID, selfID)
  }

  func testAnOlderIdentityIsKeptWhenTheRootHasNone() {
    let older = UUID()
    let profile = DemoProfileFile(dataRoot: root).loadEnsuringIdentity(existingSelf: older)
    XCTAssertEqual(profile.selfPersonID, older)
  }

  func testTheProfileCarriesOwnerNamesAndTheOrganizingDevice() throws {
    let file = DemoProfileFile(dataRoot: root)
    let json = """
      {"owner_names": ["林知远", "知远"],
       "organizer": {"host": "spark-demo", "socket_path": "/srv/organizer.sock",
                     "token_path": "/srv/link_token", "inbox_command": "/srv/bin/inbox"}}
      """
    try Data(json.utf8).write(to: file.url)
    let profile = try XCTUnwrap(file.load())
    XCTAssertEqual(profile.ownerNames, ["林知远", "知远"])
    XCTAssertEqual(
      profile.organizer,
      DemoProfile.Organizer(
        host: "spark-demo", socketPath: "/srv/organizer.sock", tokenPath: "/srv/link_token",
        inboxCommand: "/srv/bin/inbox"))
    // A blank host is no organizing device.
    try Data(#"{"organizer": {"host": "  "}}"#.utf8).write(to: file.url)
    XCTAssertNil(file.load()?.organizer)
  }

  func testAProfileThatIsALinkIsNotRead() throws {
    let elsewhere = root.appendingPathComponent("elsewhere.json")
    try Data(#"{"owner_names": ["x"]}"#.utf8).write(to: elsewhere)
    let file = DemoProfileFile(dataRoot: root)
    try FileManager.default.createSymbolicLink(at: file.url, withDestinationURL: elsewhere)
    XCTAssertNil(file.load())
  }

  // MARK: Demo dictations

  func testTheLedgerRemembersDictationsUntilTheyAreGone() throws {
    let ledger = DemoDictationLedger(dataRoot: root)
    XCTAssertEqual(ledger.pending(), [])
    let first = UUID()
    let second = UUID()
    try ledger.add(first)
    try ledger.add(second)
    try ledger.add(first)
    XCTAssertEqual(ledger.pending(), [first, second])
    ledger.remove(first)
    XCTAssertEqual(DemoDictationLedger(dataRoot: root).pending(), [second])
  }
}
