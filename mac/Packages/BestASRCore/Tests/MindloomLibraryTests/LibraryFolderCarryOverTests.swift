import Darwin
import Foundation
import MindloomIdentity
import XCTest

@testable import MindloomLibrary

/// The library folder after the rename (2026-10-06): only the switch script
/// moves bestASR's folder to Mindloom's. The App reads both folders and never
/// changes either (review of 10-6: a move by the App had no backup and no
/// record a rollback could follow); a folder is a library only when it holds
/// `history.sqlite`.
final class LibraryFolderCarryOverTests: XCTestCase {
  private var support: URL!
  private var previous: URL { support.appendingPathComponent("bestASR", isDirectory: true) }
  private var current: URL { support.appendingPathComponent("Mindloom", isDirectory: true) }

  override func setUpWithError() throws {
    support = FileManager.default.temporaryDirectory
      .appendingPathComponent("library-carry-over-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: support)
  }

  private func makeLibrary(_ url: URL, marker: String) throws {
    try FileManager.default.createDirectory(
      at: url.appendingPathComponent("assets/sessions"), withIntermediateDirectories: true)
    try Data(marker.utf8).write(to: url.appendingPathComponent("history.sqlite"))
  }

  private func marker(_ url: URL) -> String? {
    (try? Data(contentsOf: url.appendingPathComponent("history.sqlite")))
      .map { String(decoding: $0, as: UTF8.self) }
  }

  private func check(running: Bool = false) -> LibraryFolderCarryOver.Outcome {
    LibraryFolderCarryOver.check(
      previous: previous, current: current, previousAppRunning: { running })
  }

  /// Every entry under `support`, with its inode: nothing renamed, made or
  /// removed by a check.
  private func tree() -> [String: Int] {
    var result: [String: Int] = [:]
    let enumerator = FileManager.default.enumerator(atPath: support.path)
    while let path = enumerator?.nextObject() as? String {
      let attributes = try? FileManager.default.attributesOfItem(
        atPath: support.appendingPathComponent(path).path)
      result[path] = attributes?[.systemFileNumber] as? Int ?? -1
    }
    return result
  }

  func testThePreviousFolderIsBestASRsBesideMindloomsOwn() {
    XCTAssertEqual(LibraryFolderCarryOver.previousFolder(besides: current).path, previous.path)
    XCTAssertEqual(current.lastPathComponent, MindloomIdentity.libraryFolderName)
  }

  /// Before the switch and after a rollback: refused, every time, and the
  /// folder stays exactly where and as it is.
  func testOnlyBestASRsFolderIsNeverMoved() throws {
    try makeLibrary(previous, marker: "owner")
    let before = tree()
    XCTAssertEqual(check(), .atPreviousLocation)
    XCTAssertEqual(check(), .atPreviousLocation)
    XCTAssertEqual(tree(), before)
    XCTAssertEqual(marker(previous), "owner")
    XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
  }

  func testARunningBestASRIsNamed() throws {
    try makeLibrary(previous, marker: "owner")
    XCTAssertEqual(check(running: true), .previousAppRunning)
    XCTAssertEqual(marker(previous), "owner")
    XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
  }

  func testOnlyTheTeamSignedProductImportsBestASRsSettings() {
    XCTAssertTrue(
      LibraryFolderCarryOver.isTeamSignedProduct(
        bundleID: "app.mindloom", signingTeam: "ABCDE12345"))
    // An ad hoc build of the product (no team), another build, bestASR, nothing.
    XCTAssertFalse(
      LibraryFolderCarryOver.isTeamSignedProduct(bundleID: "app.mindloom", signingTeam: nil))
    XCTAssertFalse(
      LibraryFolderCarryOver.isTeamSignedProduct(bundleID: "app.mindloom", signingTeam: ""))
    XCTAssertFalse(
      LibraryFolderCarryOver.isTeamSignedProduct(
        bundleID: "app.mindloom.debug", signingTeam: "ABCDE12345"))
    XCTAssertFalse(
      LibraryFolderCarryOver.isTeamSignedProduct(
        bundleID: "com.bestasr.app", signingTeam: "ABCDE12345"))
    XCTAssertFalse(
      LibraryFolderCarryOver.isTeamSignedProduct(
        bundleID: "com.bestasr.mindloom.check.switch", signingTeam: "ABCDE12345"))
    XCTAssertFalse(
      LibraryFolderCarryOver.isTeamSignedProduct(bundleID: nil, signingTeam: "ABCDE12345"))
  }

  func testANewLibraryOrAMovedOneIsReady() throws {
    XCTAssertEqual(check(), .ready)
    XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
    try makeLibrary(current, marker: "mindloom")
    XCTAssertEqual(check(), .ready)
  }

  /// Both with a library: Mindloom's opens; bestASR's stays exactly as it is.
  func testTwoLibrariesAreNeverMerged() throws {
    try makeLibrary(previous, marker: "owner")
    try makeLibrary(current, marker: "mindloom")
    let before = tree()
    XCTAssertEqual(check(), .bothPresent)
    XCTAssertEqual(tree(), before)
  }

  /// A Mindloom folder without `history.sqlite` (an eval script's folder, an
  /// empty one) is no library: the owner's stays where it is and nothing
  /// opens in its place; nothing is removed from either folder.
  func testAMindloomFolderWithoutALibraryIsNoLibrary() throws {
    try makeLibrary(previous, marker: "owner")
    try FileManager.default.createDirectory(
      at: current.appendingPathComponent("eval"), withIntermediateDirectories: true)
    try Data().write(to: current.appendingPathComponent(".DS_Store"))
    let before = tree()
    XCTAssertEqual(check(), .atPreviousLocation)
    XCTAssertEqual(tree(), before)
    // A folder named history.sqlite is not a database either.
    try FileManager.default.createDirectory(
      at: current.appendingPathComponent("history.sqlite"), withIntermediateDirectories: true)
    XCTAssertFalse(LibraryFolderCarryOver.holdsLibrary(current))
    XCTAssertEqual(check(), .atPreviousLocation)
  }

  /// bestASR's folder without a database (nothing but stray files): a new
  /// owner, so a new library.
  func testABestASRFolderWithoutALibraryIsNoLibrary() throws {
    try FileManager.default.createDirectory(
      at: previous.appendingPathComponent("eval"), withIntermediateDirectories: true)
    XCTAssertEqual(check(), .ready)
  }

  /// A library kept elsewhere through a link counts where the link is.
  func testALinkedLibraryCountsAsTheLinksFolder() throws {
    let elsewhere = support.appendingPathComponent("external/library", isDirectory: true)
    try makeLibrary(elsewhere, marker: "owner")
    try FileManager.default.createSymbolicLink(at: previous, withDestinationURL: elsewhere)
    XCTAssertEqual(check(), .atPreviousLocation)
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: previous.path), elsewhere.path)
  }
}
