import BestASREntries
import Foundation
import XCTest

/// Settings → 入口 (V8 contract §A): every entry is listed with a switch;
/// nothing that captures in the background is on until the owner turns it
/// on; the file is private and never turns anything on by itself.
final class EntrySettingsTests: XCTestCase {
  func testEveryEntryIsListedAndBackgroundEntriesAreOffByDefault() {
    XCTAssertEqual(Set(EntryKind.settingsOrder), Set(EntryKind.allCases))
    XCTAssertEqual(EntryKind.settingsOrder.count, EntryKind.allCases.count)
    let defaults = EntrySettings.defaults
    for kind in EntryKind.allCases where kind.capturesInBackground {
      XCTAssertFalse(defaults.isOn(kind), "\(kind) must be off until the owner turns it on")
    }
    // The command line is off by default too: an agent in a terminal runs as the owner.
    XCTAssertFalse(defaults.isOn(.commandLine))
    XCTAssertTrue(defaults.isOn(.shareSheet))
    // Review V8R-17: any app can invoke a Services item, so it waits for the owner.
    XCTAssertFalse(defaults.isOn(.services))
    XCTAssertTrue(defaults.isOn(.shortcuts))
    for kind in EntryKind.allCases {
      XCTAssertFalse(kind.title.isEmpty)
      XCTAssertFalse(kind.detail.isEmpty)
    }
    XCTAssertTrue(EntryKind.calendar.detail.contains("从不写日历"))
    XCTAssertTrue(EntryKind.git.detail.contains("从不读取文件内容"))
    XCTAssertTrue(EntryKind.shareSheet.detail.contains("不会打开"))
  }

  func testSettingsRoundTripPrivatelyAndUnknownFieldsTurnNothingOn() throws {
    let root = try temporaryRoot()
    let folder = EntryFolder(dataRoot: root)
    XCTAssertEqual(folder.loadSettings(), .defaults)
    var settings = EntrySettings.defaults
    settings.set(.folderWatch, on: true)
    settings.folders = [WatchedFolder(path: "/tmp/screens", exclusions: ["*.mov"])]
    settings.calendarIDs = ["cal-1"]
    try folder.save(settings)
    XCTAssertEqual(folder.loadSettings(), settings)
    let attributes = try FileManager.default.attributesOfItem(atPath: folder.settingsURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    let folderAttributes = try FileManager.default.attributesOfItem(atPath: folder.url.path)
    XCTAssertEqual((folderAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

    // A file from another version: unknown switches are dropped, bad fields default.
    try Data(#"{"switches":{"calendar":true,"teleport":true},"folders":"nope"}"#.utf8)
      .write(to: folder.settingsURL)
    let read = folder.loadSettings()
    XCTAssertTrue(read.isOn(.calendar))
    XCTAssertEqual(read.switches.keys.sorted(), ["calendar"])
    XCTAssertEqual(read.folders, [])
    XCTAssertFalse(read.isOn(.git))
  }

  func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mindloom-entries-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
}
