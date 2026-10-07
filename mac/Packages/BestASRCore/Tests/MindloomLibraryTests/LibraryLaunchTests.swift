import BestASRRemoteOrganizer
import Foundation
import XCTest

@testable import MindloomLibrary

/// v12 phase B: which library a launch opens. Development builds never open
/// the real library by default; demo mode needs a synthetic root.
final class LibraryLaunchTests: XCTestCase {
  private var base: URL!
  private var real: URL!
  private var demo: URL!
  private var plain: URL!

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory
      .appendingPathComponent("library-launch-\(UUID().uuidString)", isDirectory: true)
    real = base.appendingPathComponent("Library/Application Support/Mindloom", isDirectory: true)
    demo = base.appendingPathComponent("demo-root", isDirectory: true)
    plain = base.appendingPathComponent("rehearsal-copy", isDirectory: true)
    for folder in [real!, demo!, plain!] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    try Data("Synthetic.\n".utf8).write(
      to: demo.appendingPathComponent(RemoteOrganizerDataProvenance.syntheticMarkerFileName))
  }

  override func tearDownWithError() throws {
    if let base { try? FileManager.default.removeItem(at: base) }
  }

  private func resolve(
    _ arguments: [String], _ flavor: MindloomBuildFlavor, preview: String? = nil
  ) throws -> LibraryLaunch {
    try LibraryLaunchSelection.resolve(
      arguments: ["/Applications/x.app/Contents/MacOS/x"] + arguments, flavor: flavor,
      previewDefaultRoot: preview, realLibraryRoot: real)
  }

  private func assertRefused(
    _ arguments: [String], _ flavor: MindloomBuildFlavor, preview: String? = nil,
    _ expected: LibraryLaunchError, line: UInt = #line
  ) {
    XCTAssertThrowsError(try resolve(arguments, flavor, preview: preview), line: line) {
      XCTAssertEqual($0 as? LibraryLaunchError, expected, line: line)
    }
  }

  func testReleaseOpensTheOwnerLibraryByDefault() throws {
    let launch = try resolve([], .release)
    XCTAssertEqual(launch, LibraryLaunch(root: real, mode: .ownerLibrary))
    XCTAssertFalse(launch.isDemo)
  }

  /// bestASR's folder beside the owner's library (where the library was
  /// before 2026-10-06, and is again after a rollback) is never a separate
  /// or demo root either.
  func testBestASRsFolderIsNeverASeparateRoot() throws {
    let previous = real.deletingLastPathComponent().appendingPathComponent("bestASR")
    try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
    assertRefused(
      ["-BestASRDataRoot", previous.path], .release, .invalidRoot(.insideRealLibrary))
    assertRefused(
      ["-BestASRDataRoot", previous.appendingPathComponent("copy").path], .release,
      .invalidRoot(.insideRealLibrary))
    assertRefused(
      ["-MindloomDemoRoot", previous.path], .release, .invalidRoot(.insideRealLibrary))
    assertRefused(
      ["-BestASRDataRoot", real.deletingLastPathComponent().path], .release,
      .invalidRoot(.containsRealLibrary))
    // A sibling whose name only starts the same is another folder.
    let sibling = real.deletingLastPathComponent().appendingPathComponent("bestASR-copy")
    XCTAssertEqual(
      try resolve(["-BestASRDataRoot", sibling.path], .release).mode, .separateRoot)
  }

  func testDevelopmentRefusesWithoutAnExplicitLibrary() {
    assertRefused([], .development, .developmentBuildNeedsLibrary)
    // Unrelated arguments change nothing.
    assertRefused(["-MindloomNoArm", "YES"], .development, .developmentBuildNeedsLibrary)
  }

  func testDevelopmentOpensTheOwnerLibraryOnlyWhenAskedExplicitly() throws {
    XCTAssertEqual(
      try resolve(["-BestASRUseRealLibrary", "YES"], .development),
      LibraryLaunch(root: real, mode: .ownerLibrary))
    assertRefused(["-BestASRUseRealLibrary", "NO"], .development, .developmentBuildNeedsLibrary)
    assertRefused(
      ["-BestASRUseRealLibrary", "yes"], .development, .malformedArgument("BestASRUseRealLibrary"))
    assertRefused(
      ["--BestASRUseRealLibrary", "YES"], .development,
      .malformedArgument("BestASRUseRealLibrary"))
    assertRefused(["-BestASRUseRealLibrary"], .development, .malformedArgument("BestASRUseRealLibrary"))
  }

  func testASeparateRootOpensInEveryBuild() throws {
    for flavor in [MindloomBuildFlavor.release, .development] {
      XCTAssertEqual(
        try resolve(["-BestASRDataRoot", plain.path], flavor),
        LibraryLaunch(root: plain, mode: .separateRoot))
    }
    // Review v12-B #12 (regression): the product on a root marked
    // synthetic is demo mode, as Mindloom Preview's is (the root's own 「我」,
    // names, Spark and link state, never the owner's). A development build
    // keeps a separate root (its preferences are its own domain).
    XCTAssertEqual(
      try resolve(["-BestASRDataRoot", demo.path], .release),
      LibraryLaunch(root: demo, mode: .demo))
    XCTAssertEqual(try resolve(["-BestASRDataRoot", demo.path], .development).mode, .separateRoot)
  }

  func testTheRealLibraryCannotBeNamedAsASeparateOrDemoRoot() {
    assertRefused(["-BestASRDataRoot", real.path], .development, .invalidRoot(.insideRealLibrary))
    assertRefused(["-MindloomDemoRoot", real.path], .release, .invalidRoot(.insideRealLibrary))
    assertRefused(["-MindloomDemoRoot", base.path], .release, .invalidRoot(.containsRealLibrary))
    assertRefused(["-MindloomDemoRoot", "relative/root"], .release, .invalidRoot(.notAbsolute))
  }

  func testDemoModeNeedsASyntheticRoot() throws {
    for flavor in [MindloomBuildFlavor.release, .development, .preview] {
      let launch = try resolve(["-MindloomDemoRoot", demo.path], flavor)
      XCTAssertEqual(launch, LibraryLaunch(root: demo, mode: .demo))
      XCTAssertTrue(launch.isDemo)
    }
    assertRefused(["-MindloomDemoRoot", plain.path], .release, .demoRootNotSynthetic)
    // A marker that is a link does not count.
    let linked = base.appendingPathComponent("linked-root", isDirectory: true)
    try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: linked.appendingPathComponent(RemoteOrganizerDataProvenance.syntheticMarkerFileName),
      withDestinationURL: demo.appendingPathComponent(
        RemoteOrganizerDataProvenance.syntheticMarkerFileName))
    assertRefused(["-MindloomDemoRoot", linked.path], .release, .demoRootNotSynthetic)
  }

  func testDemoRootMayBeRepeatedAsTheDataRootButNotContradicted() throws {
    XCTAssertEqual(
      try resolve(["-BestASRDataRoot", demo.path, "-MindloomDemoRoot", demo.path], .development),
      LibraryLaunch(root: demo, mode: .demo))
    assertRefused(
      ["-BestASRDataRoot", plain.path, "-MindloomDemoRoot", demo.path], .release,
      .conflictingArguments)
    assertRefused(
      ["-MindloomDemoRoot", demo.path, "-BestASRUseRealLibrary", "YES"], .development,
      .conflictingArguments)
    assertRefused(
      ["-MindloomDemoRoot", demo.path, "-MindloomDemoRoot", demo.path], .release,
      .malformedArgument("MindloomDemoRoot"))
    assertRefused(["-mindloomdemoroot", demo.path], .release, .malformedArgument("MindloomDemoRoot"))
  }

  func testNoArmIsReadFromTheLaunchArgumentsAndFailsSafe() {
    let app = "/Applications/x.app/Contents/MacOS/x"
    XCTAssertFalse(LibraryLaunchSelection.noArmRequested(arguments: [app]))
    XCTAssertTrue(LibraryLaunchSelection.noArmRequested(arguments: [app, "-MindloomNoArm", "YES"]))
    XCTAssertTrue(LibraryLaunchSelection.noArmRequested(arguments: [app, "-MindloomNoArm", "1"]))
    XCTAssertTrue(LibraryLaunchSelection.noArmRequested(arguments: [app, "-MindloomNoArm"]))
    XCTAssertFalse(LibraryLaunchSelection.noArmRequested(arguments: [app, "-MindloomNoArm", "NO"]))
  }

  func testPreviewOpensItsOwnRootAndNeverTheRealLibrary() throws {
    XCTAssertEqual(
      try resolve([], .preview, preview: demo.path), LibraryLaunch(root: demo, mode: .demo))
    // An unmarked root is opened as before, as a separate root.
    XCTAssertEqual(
      try resolve(["-BestASRDataRoot", plain.path], .preview, preview: demo.path),
      LibraryLaunch(root: plain, mode: .separateRoot))
    assertRefused([], .preview, preview: nil, .previewRootNotConfigured)
    assertRefused([], .preview, preview: "$(MINDLOOM_PREVIEW_DATA_ROOT)", .previewRootNotConfigured)
    assertRefused([], .preview, preview: real.path, .invalidRoot(.insideRealLibrary))
    assertRefused(
      ["-BestASRUseRealLibrary", "YES"], .preview, preview: demo.path, .conflictingArguments)
  }
}
