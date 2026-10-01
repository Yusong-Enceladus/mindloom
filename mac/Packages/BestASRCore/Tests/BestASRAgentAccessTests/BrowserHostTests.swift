import BestASRAgentAccess
import BestASRDomain
import BestASREntries
import BestASRIntake
import Darwin
import Foundation
import MindloomAgentProtocol
import XCTest

/// The entries' switches, as the App keeps them.
actor BrowserSwitches {
  var on: Set<EntryKind> = []
  func set(_ kinds: Set<EntryKind>) { on = kinds }
  func isOn(_ kind: EntryKind) -> Bool { on.contains(kind) }
}

/// The library's commit side, in memory.
final class BrowserDrafts: UserItemCommitting, @unchecked Sendable {
  private let lock = NSLock()
  private var drafts: [UserItemDraft] = []
  var all: [UserItemDraft] { lock.withLock { drafts } }
  func createUserItem(_ draft: UserItemDraft) async throws {
    lock.withLock { drafts.append(draft) }
  }
  func existingSessionIDs(among candidates: [SessionID]) async throws -> Set<SessionID> {
    lock.withLock { Set(candidates).intersection(drafts.map(\.id)) }
  }
}

/// The App's side of the browser entry: the real intake path into a
/// recording store, behind the entries' switches.
func browserApp(_ switches: BrowserSwitches, root: URL, drafts: BrowserDrafts) -> OwnerEntryChannel
{
  let processor = IntakeProcessor(
    assetStore: IntakeAssetStore(assetRoot: root.appendingPathComponent("assets")),
    pathPolicy: .none)
  let committer = EntryCommitter(processor: processor, store: drafts)
  return OwnerEntryChannel(
    isEnabled: { await switches.isOn($0) },
    add: { _ in .refused("命令行不在这个测试里") },
    due: { _ in .refused("命令行不在这个测试里") },
    browserAdd: { request in
      let summary = await committer.commit(HandEntries.browser(request, at: Date()))
      guard summary.storedCount > 0 else {
        return .refused(summary.rejected.first ?? "没有可收进来的内容")
      }
      return .reply(
        OwnerReply(
          message: summary.confirmation(source: EntrySource.named(EntrySource.browser)),
          stored: summary.storedCount))
    })
}

/// The App's socket on a synthetic root, with the browser owner channel.
func browserServer(root: URL, owner: OwnerEntryChannel) throws -> (
  AgentSocketServer, ScriptedOwner, MemoryAgentRecords
) {
  let consent = ScriptedOwner()
  let records = MemoryAgentRecords()
  let service = AgentAccessService(
    memory: FixedMemory(snapshot: try AgentFixture.snapshot()), records: records,
    secrets: MemoryAgentGrantSecretStore(), consent: consent, timeZone: AgentFixture.timeZone,
    clock: { AgentFixture.now })
  return (AgentSocketServer(dataRoot: root, service: service, owner: owner), consent, records)
}

/// The helper built next to the tests (or `MINDLOOM_MCP_HELPER`, e.g. the
/// one inside a built App).
func mindloomHelperBinary() throws -> URL {
  if let path = ProcessInfo.processInfo.environment["MINDLOOM_MCP_HELPER"] {
    return URL(fileURLWithPath: path)
  }
  let url = Bundle(for: BrowserHostTests.self).bundleURL.deletingLastPathComponent()
    .appendingPathComponent("mindloom-mcp")
  guard FileManager.default.isExecutableFile(atPath: url.path) else {
    throw XCTSkip("mindloom-mcp is not built next to the tests")
  }
  return url
}

/// V8 contract A6: the bundled helper is the Chrome extension's native
/// messaging host. Chrome starts it with the extension's origin and speaks
/// length-prefixed JSON over stdio; each message becomes one owner request
/// over the App's private socket and lands on the same intake path as a
/// paste, labelled Chrome. Only our extension's origin is served, only while
/// the owner switched the entry on, and an agent can never use the method.
final class BrowserHostTests: XCTestCase {
  override func setUp() {
    super.setUp()
    // The host may exit before reading what the test writes.
    signal(SIGPIPE, SIG_IGN)
  }

  /// A frame as Chrome writes it, built by hand (not with the code under test).
  private func chromeFrame(_ json: String) -> Data {
    let payload = Data(json.utf8)
    var length = UInt32(payload.count).littleEndian
    var data = Data(bytes: &length, count: 4)
    data.append(payload)
    return data
  }

  /// Reads Chrome-style frames by hand.
  private func replies(_ data: Data) throws -> [JSONValue] {
    var rest = data
    var values: [JSONValue] = []
    while !rest.isEmpty {
      guard rest.count >= 4 else {
        XCTFail("a cut-off length")
        break
      }
      let length = Int(
        UInt32(littleEndian: rest.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
      guard rest.count >= 4 + length else {
        XCTFail("a cut-off frame")
        break
      }
      let start = rest.startIndex + 4
      values.append(try JSONValue.parse(Data(rest[start..<(start + length)])))
      rest = Data(rest[(start + length)...])
    }
    return values
  }

  private struct HostRun {
    let status: Int32
    let replies: [JSONValue]
    let error: String
  }

  /// Starts the helper the way Chrome does (origin as the first argument),
  /// writes `input`, closes stdin and collects the replies.
  private func host(
    _ binary: URL, origin: String = BrowserExtension.origin, root: URL, input: Data
  ) throws -> HostRun {
    let process = Process()
    process.executableURL = binary
    process.arguments = [origin]
    var environment = ProcessInfo.processInfo.environment
    environment[AgentSocketLocation.dataRootEnvironmentKey] = root.path
    process.environment = environment
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    _ = AgentSocketIO.writeAll(stdin.fileHandleForWriting.fileDescriptor, input)
    try? stdin.fileHandleForWriting.close()
    let out = stdout.fileHandleForReading.readDataToEndOfFile()
    let err = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return HostRun(
      status: process.terminationStatus, replies: try replies(out),
      error: String(decoding: err, as: UTF8.self))
  }

  private let selection = #"""
    {"type":"add","kind":"selection","text":"周三组会改到下午三点\n带上 Twin-7 的曲线","url":"https://example.test/notes/7","title":"实验记录"}
    """#
  private let page =
    #"{"type":"add","kind":"page","url":"https://example.test/plan","title":"十月计划"}"#

  func testTheHostSpeaksChromesFramingAndHandsTheSelectionToTheApp() async throws {
    let binary = try mindloomHelperBinary()
    let root = try makeSyntheticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let switches = BrowserSwitches()
    let drafts = BrowserDrafts()
    let (server, consent, records) = try browserServer(
      root: root, owner: browserApp(switches, root: root, drafts: drafts))

    // The App is not running: answered, nothing kept anywhere.
    var run = try host(binary, root: root, input: chromeFrame(selection))
    XCTAssertEqual(run.status, 0, run.error)
    XCTAssertEqual(run.replies.count, 1)
    XCTAssertEqual(run.replies[0]["ok"], false)
    XCTAssertEqual(run.replies[0]["reason"], "notRunning")
    XCTAssertEqual(run.replies[0]["message"]?.stringValue, AgentCopy.notRunning)

    try server.start()
    defer { server.stop() }
    // Running, but the owner has not switched the browser entry on; the
    // command line being on does not let it in.
    for kinds: Set<EntryKind> in [[], [.commandLine]] {
      await switches.set(kinds)
      run = try host(binary, root: root, input: chromeFrame(selection))
      XCTAssertEqual(run.replies.map { $0["reason"] }, ["disabled"])
      XCTAssertEqual(run.replies[0]["message"]?.stringValue, OwnerChannel.browserDisabledMessage)
    }
    XCTAssertEqual(drafts.all.count, 0)

    // On: several messages in one session, each answered in order.
    await switches.set([.browserExtension])
    run = try host(
      binary, root: root,
      input: chromeFrame(selection) + chromeFrame(page)
        + chromeFrame(#"{"type":"add","kind":"screenshot","url":"https://example.test"}"#)
        + chromeFrame(#"{"type":"add","kind":"selection","text":"   "}"#)
        + chromeFrame("not json"))
    XCTAssertEqual(run.status, 0, run.error)
    XCTAssertEqual(
      run.replies.map { $0["ok"] }, [true, true, false, false, false])
    XCTAssertEqual(
      run.replies.map { $0["reason"] }, [nil, nil, "malformed", "empty", "malformed"])
    XCTAssertEqual(run.replies[0]["message"]?.stringValue, "已收进来 · 来自 Chrome")
    XCTAssertEqual(run.replies[0]["stored"]?.intValue, 1)
    XCTAssertEqual(run.replies[3]["message"]?.stringValue, BrowserCopy.empty)
    XCTAssertEqual(
      drafts.all.map(\.text),
      [
        "周三组会改到下午三点\n带上 Twin-7 的曲线\n\n实验记录\nhttps://example.test/notes/7",
        "十月计划\nhttps://example.test/plan",
      ])
    XCTAssertEqual(Set(drafts.all.compactMap(\.source?.name)), ["Chrome"])
    XCTAssertEqual(
      drafts.all.map(\.extractor), [EntryExtractor.browserSelection, EntryExtractor.browserPage])
    // The host says nothing about content on stderr.
    XCTAssertFalse(run.error.contains("组会"))
    XCTAssertFalse(run.error.contains("example.test"))

    // The owner's own intake: no consent sheet, no audit row.
    let asked = await consent.consentRequests.count
    XCTAssertEqual(asked, 0)
    let audit = try await records.agentAudit(clientKey: nil, limit: 100)
    XCTAssertEqual(audit.count, 0)
  }

  func testAnyOtherOriginIsRefusedAndNothingIsForwarded() async throws {
    let binary = try mindloomHelperBinary()
    let root = try makeSyntheticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let switches = BrowserSwitches()
    await switches.set([.browserExtension])
    let drafts = BrowserDrafts()
    let (server, _, _) = try browserServer(
      root: root, owner: browserApp(switches, root: root, drafts: drafts))
    try server.start()
    defer { server.stop() }

    for origin in [
      "chrome-extension://abcdefghijklmnopabcdefghijklmnop/",
      // Our ID without the trailing slash Chrome always sends.
      "chrome-extension://\(BrowserExtension.extensionID)",
      "chrome-extension://\(BrowserExtension.extensionID)/../abcdefghijklmnopabcdefghijklmnop/",
    ] {
      let run = try host(binary, origin: origin, root: root, input: chromeFrame(selection))
      XCTAssertEqual(run.status, 2, origin)
      XCTAssertEqual(run.replies.count, 1, origin)
      XCTAssertEqual(run.replies[0]["reason"], "origin", origin)
      XCTAssertEqual(run.replies[0]["message"]?.stringValue, BrowserCopy.notOurExtension)
    }
    XCTAssertEqual(drafts.all.count, 0, "nothing from another extension was taken in")

    // Our own origin, same message: taken.
    let ours = try host(binary, root: root, input: chromeFrame(selection))
    XCTAssertEqual(ours.replies.map { $0["ok"] }, [true])
    XCTAssertEqual(drafts.all.count, 1)
  }

  func testAnOversizedFrameIsRefusedAndTheHostStops() async throws {
    let binary = try mindloomHelperBinary()
    let root = try makeSyntheticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var length = UInt32(NativeMessaging.maximumIncomingBytes + 1).littleEndian
    let header = Data(bytes: &length, count: 4)
    let run = try host(binary, root: root, input: header + chromeFrame(page))
    XCTAssertEqual(run.status, 2)
    XCTAssertEqual(run.replies.map { $0["reason"] }, ["tooLong"])
  }

  /// Chrome starts a host in the host's own folder (inside the signed App
  /// bundle); the host moves to the temporary folder at once, so nothing it
  /// or its runtime writes can land in the bundle (a debug build's coverage
  /// file once did and broke the bundle's seal).
  func testTheHostNeverWorksInsideTheFolderItWasStartedIn() throws {
    let binary = try mindloomHelperBinary()
    let root = try makeSyntheticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let helpers = root.appendingPathComponent("Helpers", isDirectory: true)
    try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = binary
    process.arguments = [BrowserExtension.origin]
    process.currentDirectoryURL = helpers
    var environment = ProcessInfo.processInfo.environment
    environment[AgentSocketLocation.dataRootEnvironmentKey] = root.path
    process.environment = environment
    let stdin = Pipe()
    process.standardInput = stdin
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      try? stdin.fileHandleForWriting.close()
      process.waitUntilExit()
    }
    var directory: String?
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      directory = Self.workingDirectory(of: process.processIdentifier)
      if let directory, !directory.hasSuffix("/Helpers") { break }
      usleep(20_000)
    }
    let current = try XCTUnwrap(directory)
    let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
    XCTAssertFalse(current.hasSuffix("/Helpers"), current)
    XCTAssertEqual(URL(fileURLWithPath: current).resolvingSymlinksInPath().path, temporary)
  }

  private static func workingDirectory(of pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
  }

  func testAnAgentCanNeverUseTheBrowserMethod() async throws {
    let binary = try mindloomHelperBinary()
    let root = try makeSyntheticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let switches = BrowserSwitches()
    await switches.set(Set(EntryKind.allCases))
    let drafts = BrowserDrafts()
    let (server, _, _) = try browserServer(
      root: root, owner: browserApp(switches, root: root, drafts: drafts))
    try server.start()
    defer { server.stop() }
    let request =
      #"{"jsonrpc":"2.0","id":7,"method":"mindloom/owner.browserAdd","params":{"kind":"page","url":"https://example.test/x"}}"#

    // Started by an agent as its MCP server: the helper never forwards it.
    let agent = Process()
    agent.executableURL = binary
    var environment = ProcessInfo.processInfo.environment
    environment[AgentSocketLocation.dataRootEnvironmentKey] = root.path
    agent.environment = environment
    let input = Pipe()
    let output = Pipe()
    agent.standardInput = input
    agent.standardOutput = output
    agent.standardError = FileHandle.nullDevice
    try agent.run()
    _ = AgentSocketIO.writeAll(
      input.fileHandleForWriting.fileDescriptor, Data((request + "\n").utf8))
    let reply = try XCTUnwrap(readLine(output.fileHandleForReading.fileDescriptor, timeout: 10))
    try? input.fileHandleForWriting.close()
    agent.waitUntilExit()
    XCTAssertEqual(
      try JSONValue.parse(reply)["error"]?["code"]?.intValue, Int64(MCPErrorCode.methodNotFound))

    // Inside an MCP session on the socket itself: not found either.
    let descriptor = try XCTUnwrap(
      AgentSocketClient.connectVerified(server.socketURL.path, log: { XCTFail($0) }))
    defer { close(descriptor) }
    let lines = [
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-code"}}}"#,
      request,
    ]
    _ = AgentSocketIO.writeAll(descriptor, Data(lines.map { $0 + "\n" }.joined().utf8))
    _ = readLine(descriptor)
    let smuggled = try JSONValue.parse(try XCTUnwrap(readLine(descriptor)))
    XCTAssertEqual(smuggled["error"]?["code"]?.intValue, Int64(MCPErrorCode.methodNotFound))
    XCTAssertEqual(drafts.all.count, 0)
  }
}
