import Foundation
import XCTest

/// The Claude Code plugin's and the Claude Desktop extension's launchers
/// (2026-10-06): the product is found by its bundle id (`app.mindloom`), not
/// by its file name, its signature is checked before its helper runs,
/// nothing points at bestASR any more, and
/// Mindloom Preview comes only after every product copy (review v12-B #9:
/// the product's gate refuses the preview's helper, which looks like
/// 「Mindloom 没有在运行」). Each run has a home of its own with stand-in Apps
/// whose helpers only print who they are, and bundle ids of its own, so
/// LaunchServices knows none of them and the Apps on this Mac never answer.
final class AgentLauncherOrderTests: XCTestCase {
  private static var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }

  static let launchers = [
    "integrations/claude-code-plugin/bin/mindloom-mcp.sh",
    "integrations/claude-desktop/server/mindloom-mcp.sh",
  ]

  private var home: URL!
  private let product = "com.bestasr.test.product.\(UUID().uuidString.prefix(8))"
  private let preview = "com.bestasr.test.preview.\(UUID().uuidString.prefix(8))"

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory
      .appendingPathComponent("launcher-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let home { try? FileManager.default.removeItem(at: home) }
  }

  /// `~/Applications/<name>` with the bundle id `id` and, unless `helper` is
  /// false, a helper that prints `word`.
  private func standIn(_ name: String, id: String, says word: String, helper: Bool = true) throws {
    let contents = home.appendingPathComponent("Applications/\(name)/Contents")
    try FileManager.default.createDirectory(
      at: contents.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "stand-in"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: contents.appendingPathComponent("Info.plist"))
    guard helper else { return }
    let path = contents.appendingPathComponent("Helpers/mindloom-mcp")
    try Data("#!/bin/sh\necho \(word)\n".utf8).write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
  }

  private func remove(_ name: String) throws {
    try FileManager.default.removeItem(at: home.appendingPathComponent("Applications/\(name)"))
  }

  private func run(_ launcher: String, signatures: Bool = false, extra: [String: String] = [:])
    throws -> (output: String, status: Int32)
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [Self.repositoryRoot.appendingPathComponent(launcher).path]
    var environment = [
      "HOME": home.path, "PATH": "/usr/bin:/bin",
      "MINDLOOM_APP_ID": product, "MINDLOOM_PREVIEW_ID": preview,
    ]
    if !signatures { environment["MINDLOOM_MCP_SKIP_SIGNATURE"] = "1" }
    environment.merge(extra) { $1 }
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (text, process.terminationStatus)
  }

  private func assertEveryLauncherRuns(
    _ expected: String, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    for launcher in Self.launchers {
      XCTAssertEqual(try run(launcher).output, expected, launcher, file: file, line: line)
    }
  }

  /// After the switch: the product is Mindloom.app.
  func testTheProductInstalledAsMindloomIsFound() throws {
    try standIn("Mindloom.app", id: product, says: "product")
    try assertEveryLauncherRuns("product")
  }

  /// The preview at Mindloom.app and the product elsewhere (registered with
  /// LaunchServices only, which these runs cannot use): the preview's helper,
  /// as the last resort; the product found by name comes first.
  func testTheProductComesBeforeThePreviewWhateverTheirNames() throws {
    try standIn("Mindloom.app", id: preview, says: "preview")
    try assertEveryLauncherRuns("preview")
    try remove("Mindloom.app")
    try standIn("Mindloom.app", id: product, says: "product")
    try assertEveryLauncherRuns("product")
  }

  /// bestASR.app (any bundle id, even the product's) is no longer looked at.
  func testBestASRIsNotLookedAt() throws {
    try standIn("bestASR.app", id: product, says: "bestASR")
    for launcher in Self.launchers {
      let result = try run(launcher)
      XCTAssertNotEqual(result.status, 0, launcher)
      XCTAssertEqual(result.output, "", launcher)
    }
  }

  /// A bundle named like the product but with another bundle id is never run.
  func testALookalikeIsNotRun() throws {
    try standIn("Mindloom.app", id: "com.example.lookalike", says: "lookalike")
    for launcher in Self.launchers {
      let result = try run(launcher)
      XCTAssertNotEqual(result.status, 0, launcher)
      XCTAssertEqual(result.output, "", launcher)
    }
  }

  /// Without a developer signature (these stand-ins have none) nothing runs.
  func testAnUnsignedCopyIsNotRun() throws {
    try standIn("Mindloom.app", id: product, says: "product")
    for launcher in Self.launchers {
      let result = try run(launcher, signatures: true)
      XCTAssertNotEqual(result.status, 0, launcher)
      XCTAssertEqual(result.output, "", launcher)
    }
  }

  /// The owner's explicit path comes first.
  func testAnExplicitPathComesFirst() throws {
    try standIn("Mindloom.app", id: product, says: "product")
    try standIn("Elsewhere.app", id: "any", says: "chosen")
    let chosen = home.appendingPathComponent(
      "Applications/Elsewhere.app/Contents/Helpers/mindloom-mcp")
    for launcher in Self.launchers {
      XCTAssertEqual(try run(launcher, extra: ["MINDLOOM_MCP": chosen.path]).output, "chosen")
      // An explicit path that is not there falls back to the lookup.
      XCTAssertEqual(
        try run(launcher, extra: ["MINDLOOM_MCP": "/nonexistent/mindloom-mcp"]).output, "product")
    }
  }
}
