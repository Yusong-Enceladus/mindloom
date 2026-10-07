import Foundation
import MindloomLibrary
import XCTest

@testable import bestASR

/// The owner's library at launch after the rename (review of 10-6): the
/// product's launch never moves bestASR's folder. While only that folder
/// holds the library (before the switch, or after a rollback) it refuses and
/// leaves both folders as they are, every time; a Mindloom folder without a
/// library does not open in its place.
final class MindloomLaunchTests: XCTestCase {
  private var support: URL!
  private var previous: URL { support.appendingPathComponent("bestASR", isDirectory: true) }
  private var current: URL { support.appendingPathComponent("Mindloom", isDirectory: true) }

  override func setUpWithError() throws {
    support = FileManager.default.temporaryDirectory
      .appendingPathComponent("mindloom-launch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: support)
  }

  private func makeLibrary(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Data("db".utf8).write(to: url.appendingPathComponent("history.sqlite"))
  }

  private func resolve(running: Bool = false) -> Result<LibraryLaunch, LibraryLaunchError> {
    MindloomLaunch.resolve(
      arguments: ["Mindloom"], flavor: .release, infoDictionary: [:], realLibrary: current,
      previousAppRunning: { running })
  }

  private func names() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: support.path).sorted()
  }

  func testOnlyBestASRsFolderIsRefusedAndNothingMoves() throws {
    try makeLibrary(previous)
    // The same on every launch: by hand, by the login item, after a rollback.
    for _ in 0..<2 {
      XCTAssertEqual(resolve(), .failure(.libraryAtPreviousLocation))
      XCTAssertEqual(try names(), ["bestASR"])
      XCTAssertTrue(LibraryFolderCarryOver.holdsLibrary(previous))
    }
    XCTAssertTrue(
      MindloomLaunch.refusalMessage(.libraryAtPreviousLocation).contains("bestASR 的文件夹"))
  }

  func testARunningBestASRIsNamed() throws {
    try makeLibrary(previous)
    XCTAssertEqual(resolve(running: true), .failure(.previousAppUsesLibrary))
    XCTAssertEqual(try names(), ["bestASR"])
  }

  func testMindloomsLibraryOpens() throws {
    try makeLibrary(current)
    XCTAssertEqual(resolve(), .success(LibraryLaunch(root: current, mode: .ownerLibrary)))
    // bestASR's folder made again beside it (bestASR opened from a backup):
    // Mindloom's still opens, bestASR's stays as it is.
    try makeLibrary(previous)
    XCTAssertEqual(resolve(), .success(LibraryLaunch(root: current, mode: .ownerLibrary)))
    XCTAssertEqual(try names(), ["Mindloom", "bestASR"])
  }

  /// An eval script's folder in …/Mindloom is no library: the owner's, in
  /// bestASR's folder, is not replaced by an empty one.
  func testAMindloomFolderWithoutALibraryDoesNotOpen() throws {
    try makeLibrary(previous)
    try FileManager.default.createDirectory(
      at: current.appendingPathComponent("eval"), withIntermediateDirectories: true)
    XCTAssertEqual(resolve(), .failure(.libraryAtPreviousLocation))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: current.appendingPathComponent("history.sqlite").path))
  }

  /// bestASR's settings come over once, and only into the team-signed
  /// product that opened the owner's library: not an ad hoc build with the
  /// same bundle id, not a launch refused because the library is still
  /// bestASR's, not a separate root.
  func testOnlyTheTeamSignedProductOnTheOwnersLibraryImportsSettings() {
    let owner: Result<LibraryLaunch, LibraryLaunchError> = .success(
      LibraryLaunch(root: current, mode: .ownerLibrary))
    XCTAssertTrue(
      CarryOverLaunch.mayImport(
        ownBundleID: "app.mindloom", signingTeam: "ABCDE12345", launch: owner))
    XCTAssertFalse(
      CarryOverLaunch.mayImport(ownBundleID: "app.mindloom", signingTeam: nil, launch: owner))
    XCTAssertFalse(
      CarryOverLaunch.mayImport(
        ownBundleID: "app.mindloom", signingTeam: "ABCDE12345",
        launch: .failure(.libraryAtPreviousLocation)))
    XCTAssertFalse(
      CarryOverLaunch.mayImport(
        ownBundleID: "app.mindloom", signingTeam: "ABCDE12345",
        launch: .success(LibraryLaunch(root: support, mode: .separateRoot))))
    XCTAssertFalse(
      CarryOverLaunch.mayImport(
        ownBundleID: "app.mindloom.debug", signingTeam: "ABCDE12345", launch: owner))
    // A verification copy (dry runs) imports only from the copy it is told
    // about (`CarryOverSource`), on its own root.
    XCTAssertTrue(
      CarryOverLaunch.mayImport(
        ownBundleID: "com.bestasr.mindloom.check.switch", signingTeam: nil,
        launch: .success(LibraryLaunch(root: support, mode: .separateRoot))))
  }

  func testANewOwnerStartsANewLibrary() throws {
    XCTAssertEqual(resolve(), .success(LibraryLaunch(root: current, mode: .ownerLibrary)))
  }
}
