import BestASREntries
import Foundation
import XCTest

@testable import MindloomTencentMeeting

/// The helper the key is handed to, the login folders, and the vendored
/// source the helper is built from (2026-10-06 review).
final class TencentMeetingSafetyTests: XCTestCase {
  var folder: URL!

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("tmeet-safety-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: folder)
  }

  @discardableResult
  func run(_ tool: String, _ arguments: [String], in directory: URL? = nil) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    if let directory { process.currentDirectoryURL = directory }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  func sign(_ url: URL, identifier: String? = nil) throws {
    var arguments = ["--force", "--sign", "-", "--options", "runtime"]
    if let identifier { arguments += ["--identifier", identifier] }
    XCTAssertEqual(try run("/usr/bin/codesign", arguments + [url.path]), 0, url.path)
  }

  /// An ad-hoc signed App with a helper at `Contents/Helpers/tmeet`, signed
  /// the way the App's build signs it, then the App sealed over it.
  func makeApp() throws -> (app: URL, helper: URL) {
    let app = folder.appendingPathComponent("Fixture.app", isDirectory: true)
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    for name in ["MacOS", "Helpers"] {
      try FileManager.default.createDirectory(
        at: contents.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let plist: [String: Any] = [
      "CFBundleIdentifier": "com.example.mindloom-fixture", "CFBundleExecutable": "Fixture",
      "CFBundlePackageType": "APPL", "CFBundleName": "Fixture",
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: contents.appendingPathComponent("Info.plist"))
    let main = contents.appendingPathComponent("MacOS/Fixture")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: main)
    let helper = contents.appendingPathComponent("Helpers/tmeet")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: helper)
    try sign(helper, identifier: "com.example.mindloom-fixture.tmeet")
    try sign(main, identifier: "com.example.mindloom-fixture")
    try sign(app)
    return (app, helper)
  }

  /// Only the helper the running App sealed gets the key: a file put in
  /// its place afterwards (signed ad hoc with the same identifier) fails,
  /// whether the hash was pinned before or not; so does an App signed
  /// again around it, which is not the App running.
  func testTheAppCheckTrustsOnlyTheHelperSealedIntoTheApp() throws {
    let (app, helper) = try makeApp()
    XCTAssertTrue(TencentMeetingHelperSignature.bundleIsSealed(app))
    let pin = TencentMeetingHelperPin(bundle: app, runningAppIsOnDisk: { true })
    XCTAssertTrue(pin.trusts(helper))
    XCTAssertTrue(pin.trusts(helper), "pinned")
    // Not the App's helper path.
    XCTAssertFalse(pin.trusts(URL(fileURLWithPath: "/usr/bin/true")))
    // The App on disk is not the App running.
    XCTAssertFalse(
      TencentMeetingHelperPin(bundle: app, runningAppIsOnDisk: { false }).trusts(helper))

    // Another program put in the helper's place.
    try FileManager.default.removeItem(at: helper)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: helper)
    try sign(helper, identifier: "com.example.mindloom-fixture.tmeet")
    XCTAssertFalse(TencentMeetingHelperSignature.bundleIsSealed(app))
    XCTAssertFalse(pin.trusts(helper), "a substituted helper passed the pinned check")
    XCTAssertFalse(
      TencentMeetingHelperPin(bundle: app, runningAppIsOnDisk: { true }).trusts(helper),
      "a substituted helper passed a first check")

    // An unsigned file.
    try FileManager.default.removeItem(at: helper)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: helper)
    XCTAssertEqual(try run("/usr/bin/codesign", ["--remove-signature", helper.path]), 0)
    XCTAssertFalse(
      TencentMeetingHelperPin(bundle: app, runningAppIsOnDisk: { true }).trusts(helper))

    // The whole App signed again around a new helper: its seal holds, but
    // it is not the App that is running.
    try sign(helper, identifier: "com.example.mindloom-fixture.tmeet")
    try sign(app)
    XCTAssertTrue(TencentMeetingHelperSignature.bundleIsSealed(app))
    XCTAssertFalse(
      TencentMeetingHelperPin(bundle: app, runningAppIsOnDisk: { false }).trusts(helper))
  }

  // MARK: Login folders

  func entries() throws -> (state: URL, new: URL) {
    let entries = folder.appendingPathComponent(EntryFolder.name, isDirectory: true)
    let state = entries.appendingPathComponent("tencent-meeting", isDirectory: true)
    let new = entries.appendingPathComponent("tencent-meeting-new", isDirectory: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: state.appendingPathComponent("login"))
    return (state, new)
  }

  /// Reconnecting before the old login ended: the new login is made beside
  /// it and replaces it only once allowed; cancelled, the old one stays.
  func testANewLoginReplacesTheOldOnlyOnceAllowed() throws {
    let (state, new) = try entries()
    // Cancelled (or expired): the old login is untouched.
    try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
    try Data("half".utf8).write(to: new.appendingPathComponent("login"))
    TencentMeetingLoginFolders.clearNewLogin(new)
    XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
    XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent("login")), Data("old".utf8))
    // Allowed: swapped in, the old one gone.
    try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
    try Data("new".utf8).write(to: new.appendingPathComponent("login"))
    try TencentMeetingLoginFolders.adopt(newLogin: new, into: state)
    XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent("login")), Data("new".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
    // A first connection: no old folder.
    try FileManager.default.removeItem(at: state)
    try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
    try TencentMeetingLoginFolders.adopt(newLogin: new, into: state)
    XCTAssertTrue(FileManager.default.fileExists(atPath: state.path))
    // Folders of other names are never moved.
    XCTAssertThrowsError(
      try TencentMeetingLoginFolders.adopt(
        newLogin: folder.appendingPathComponent("elsewhere"), into: state))
  }

  /// Switching off removes both folders (and nothing else), so a later
  /// launch has nothing left to finish.
  func testSwitchingOffRemovesBothLoginFolders() throws {
    let (state, new) = try entries()
    try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
    let other = state.deletingLastPathComponent().appendingPathComponent(
      "state-tencentMeeting.json")
    try Data("{}".utf8).write(to: other)
    XCTAssertTrue(TencentMeetingLoginFolders.exist(state, newLogin: new))
    TencentMeetingLoginFolders.removeAll(stateDirectory: state, newLogin: new)
    XCTAssertFalse(TencentMeetingLoginFolders.exist(state, newLogin: new))
    XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    // A folder that is not tmeet's is left alone.
    TencentMeetingLoginFolders.removeAll(
      stateDirectory: state.deletingLastPathComponent(), newLogin: nil)
    XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
  }

  // MARK: The vendored source

  /// The build refuses a vendored tree with a file the manifest does not
  /// list (Go would compile it), a link put in, or a file missing.
  func testTheBuildRefusesAVendoredTreeThatIsNotExactlyTheManifest() throws {
    var repository = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
    while repository.path != "/",
      !FileManager.default.fileExists(
        atPath: repository.appendingPathComponent("PRODUCT_REQUIREMENTS.md").path)
    {
      repository.deleteLastPathComponent()
    }
    let copy = folder.appendingPathComponent("repo", isDirectory: true)
    try FileManager.default.createDirectory(
      at: copy.appendingPathComponent("script"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: copy.appendingPathComponent("third_party"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: repository.appendingPathComponent("script/build_tmeet.sh"),
      to: copy.appendingPathComponent("script/build_tmeet.sh"))
    try FileManager.default.copyItem(
      at: repository.appendingPathComponent("third_party/tencentmeeting-cli"),
      to: copy.appendingPathComponent("third_party/tencentmeeting-cli"))
    let script = copy.appendingPathComponent("script/build_tmeet.sh").path
    let upstream = copy.appendingPathComponent("third_party/tencentmeeting-cli/upstream")
    func check() throws -> Int32 { try run("/bin/zsh", [script, "--check-only"]) }

    XCTAssertEqual(try check(), 0)
    let added = upstream.appendingPathComponent("internal/zz_added.go")
    try Data("package internal\n".utf8).write(to: added)
    XCTAssertEqual(try check(), 65, "an added file was accepted")
    try FileManager.default.removeItem(at: added)
    let link = upstream.appendingPathComponent("cmd/zz_link.go")
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
    XCTAssertEqual(try check(), 65, "a link was accepted")
    try FileManager.default.removeItem(at: link)
    let license = upstream.appendingPathComponent("LICENSE")
    let text = try Data(contentsOf: license)
    try FileManager.default.removeItem(at: license)
    XCTAssertEqual(try check(), 65, "a missing file was accepted")
    try text.write(to: license)
    XCTAssertEqual(try check(), 0)
  }
}
