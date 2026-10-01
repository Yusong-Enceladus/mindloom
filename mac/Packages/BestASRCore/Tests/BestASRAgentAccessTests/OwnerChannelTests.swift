import BestASRAgentAccess
import BestASRDomain
import BestASREntries
import BestASRIntake
import Darwin
import Foundation
import MindloomAgentProtocol
import XCTest

/// V8 contract A3: the `mindloom` command line reaches the App over the
/// agents' private socket with the same owner check, counts as the owner's
/// own intake (no grant, no consent, no audit row), works only while the
/// owner switched it on, and an agent can never use it through the MCP
/// helper.
final class OwnerChannelTests: XCTestCase {
  /// What the App would do with the command line: the real intake path into
  /// a recording store, behind a switch.
  private actor FakeApp {
    var enabled = false
    var adds: [OwnerAddRequest] = []
    var dues: [Int] = []
    var stored: [UserItemDraft] = []

    func set(enabled: Bool) { self.enabled = enabled }
    func recordAdd(_ request: OwnerAddRequest) { adds.append(request) }
    func recordDue(_ days: Int) { dues.append(days) }
    func keep(_ drafts: [UserItemDraft]) { stored += drafts }
  }

  private final class Drafts: UserItemCommitting, @unchecked Sendable {
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

  private func channel(_ app: FakeApp, root: URL, drafts: Drafts) -> OwnerEntryChannel {
    let processor = IntakeProcessor(
      assetStore: IntakeAssetStore(assetRoot: root.appendingPathComponent("assets")),
      pathPolicy: .none)
    let committer = EntryCommitter(processor: processor, store: drafts)
    return OwnerEntryChannel(
      isEnabled: { kind in
        // The command line's own switch; the browser entry stays off here.
        guard kind == .commandLine else { return false }
        return await app.enabled
      },
      add: { request in
        await app.recordAdd(request)
        let (items, refused) = HandEntries.commandLine(request, at: Date())
        var summary = await committer.commit(items)
        summary.rejected = refused + summary.rejected
        guard summary.storedCount > 0 else {
          return .refused(summary.rejected.first ?? "没有可收进来的内容")
        }
        return .reply(
          OwnerReply(
            message: summary.confirmation(source: EntrySource.named(EntrySource.commandLine)),
            stored: summary.storedCount))
      },
      due: { days in
        await app.recordDue(days)
        return .reply(OwnerReply(message: "今天到期 1 件：", lines: ["· 10月1日 交初稿 — Twin-7 实验"]))
      })
  }

  private func service() throws -> (AgentAccessService, ScriptedOwner, MemoryAgentRecords) {
    let owner = ScriptedOwner()
    let records = MemoryAgentRecords()
    return (
      AgentAccessService(
        memory: FixedMemory(snapshot: try AgentFixture.snapshot()), records: records,
        secrets: MemoryAgentGrantSecretStore(), consent: owner, timeZone: AgentFixture.timeZone,
        clock: { AgentFixture.now }),
      owner, records
    )
  }

  private func send(_ descriptor: Int32, _ lines: [String]) {
    AgentSocketIO.writeAll(descriptor, Data(lines.map { $0 + "\n" }.joined().utf8))
  }

  func testOwnerConnectionsAreTheOwnersIntakeAndNeverAnAgentSession() async throws {
    let root = try makeSyntheticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (service, owner, records) = try service()
    let app = FakeApp()
    let drafts = Drafts()
    let server = AgentSocketServer(
      dataRoot: root, service: service, owner: channel(app, root: root, drafts: drafts))
    try server.start()
    defer { server.stop() }
    let add = #"{"jsonrpc":"2.0","id":1,"method":"mindloom/owner.add","params":{"text":"终端里的一句话"}}"#

    // Off by default: refused, nothing taken.
    var descriptor = try XCTUnwrap(
      AgentSocketClient.connectVerified(server.socketURL.path, log: { XCTFail($0) }))
    send(descriptor, [add])
    let off = try JSONValue.parse(try XCTUnwrap(readLine(descriptor)))
    close(descriptor)
    XCTAssertEqual(off["error"]?["code"]?.intValue, Int64(OwnerChannel.ErrorCode.disabled))
    XCTAssertEqual(off["error"]?["message"]?.stringValue, OwnerChannel.disabledMessage)
    XCTAssertEqual(drafts.all.count, 0)

    // Switched on: taken as the owner's own item, source 命令行.
    await app.set(enabled: true)
    descriptor = try XCTUnwrap(
      AgentSocketClient.connectVerified(server.socketURL.path, log: { XCTFail($0) }))
    send(descriptor, [add, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#])
    let on = try JSONValue.parse(try XCTUnwrap(readLine(descriptor)))
    // An MCP method on an owner connection is not served.
    let mcp = try JSONValue.parse(try XCTUnwrap(readLine(descriptor)))
    close(descriptor)
    XCTAssertEqual(on["result"]?["message"]?.stringValue, "已收进来 · 来自 命令行")
    XCTAssertEqual(on["result"]?["stored"]?.intValue, 1)
    XCTAssertEqual(mcp["error"]?["code"]?.intValue, Int64(MCPErrorCode.methodNotFound))
    XCTAssertEqual(drafts.all.map(\.source?.name), ["命令行"])
    XCTAssertEqual(drafts.all.map(\.text), ["终端里的一句话"])

    // An MCP session cannot call an owner method.
    descriptor = try XCTUnwrap(
      AgentSocketClient.connectVerified(server.socketURL.path, log: { XCTFail($0) }))
    send(
      descriptor,
      [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-code"}}}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"mindloom/owner.add","params":{"text":"冒充主人"}}"#,
      ])
    _ = readLine(descriptor)
    let smuggled = try JSONValue.parse(try XCTUnwrap(readLine(descriptor)))
    close(descriptor)
    XCTAssertEqual(smuggled["error"]?["code"]?.intValue, Int64(MCPErrorCode.methodNotFound))
    XCTAssertEqual(drafts.all.count, 1)

    // The owner's calls never asked for consent nor wrote an audit row.
    let asked = await owner.consentRequests.count
    XCTAssertEqual(asked, 0)
    let audit = try await records.agentAudit(clientKey: nil, limit: 100)
    XCTAssertEqual(audit.count, 0)
  }

  func testWithoutAnOwnerChannelTheAppRefuses() async throws {
    let root = try makeSyntheticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (service, _, _) = try service()
    let server = AgentSocketServer(dataRoot: root, service: service)
    try server.start()
    defer { server.stop() }
    let descriptor = try XCTUnwrap(
      AgentSocketClient.connectVerified(server.socketURL.path, log: { XCTFail($0) }))
    defer { close(descriptor) }
    send(descriptor, [#"{"jsonrpc":"2.0","id":9,"method":"mindloom/owner.due","params":{}}"#])
    let reply = try JSONValue.parse(try XCTUnwrap(readLine(descriptor)))
    XCTAssertEqual(reply["error"]?["code"]?.intValue, Int64(OwnerChannel.ErrorCode.disabled))
  }

  // MARK: The real helper binary

  private func helperBinary() throws -> URL {
    if let path = ProcessInfo.processInfo.environment["MINDLOOM_MCP_HELPER"] {
      return URL(fileURLWithPath: path)
    }
    let url = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("mindloom-mcp")
    guard FileManager.default.isExecutableFile(atPath: url.path) else {
      throw XCTSkip("mindloom-mcp is not built next to the tests")
    }
    return url
  }

  private struct Run {
    let status: Int32
    let output: String
    let error: String
  }

  private func run(
    _ binary: URL, _ arguments: [String], root: URL, input: String? = nil,
    directory: URL? = nil
  ) throws -> Run {
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment[AgentSocketLocation.dataRootEnvironmentKey] = root.path
    process.environment = environment
    if let directory { process.currentDirectoryURL = directory }
    let output = Pipe()
    let error = Pipe()
    let stdin = Pipe()
    process.standardOutput = output
    process.standardError = error
    process.standardInput = stdin
    try process.run()
    if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
    stdin.fileHandleForWriting.closeFile()
    let out = output.fileHandleForReading.readDataToEndOfFile()
    let err = error.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Run(
      status: process.terminationStatus, output: String(decoding: out, as: UTF8.self),
      error: String(decoding: err, as: UTF8.self))
  }

  func testTheBundledHelperIsTheCommandLineAndRefusesOwnerCallsFromAgents() async throws {
    let binary = try helperBinary()
    let root = try makeSyntheticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (service, owner, _) = try service()
    let app = FakeApp()
    let drafts = Drafts()
    let server = AgentSocketServer(
      dataRoot: root, service: service, owner: channel(app, root: root, drafts: drafts))

    // The App is not running.
    let offline = try run(binary, ["add", "一句话"], root: root)
    XCTAssertEqual(offline.status, 1)
    XCTAssertTrue(offline.error.contains(AgentCopy.notRunning))

    try server.start()
    defer { server.stop() }
    // Running, but the owner has not switched the command line on.
    let disabled = try run(binary, ["add", "一句话"], root: root)
    XCTAssertEqual(disabled.status, 3)
    XCTAssertTrue(disabled.error.contains("设置 → 入口"))

    await app.set(enabled: true)
    let added = try run(binary, ["add", "下午", "三点", "组会"], root: root)
    XCTAssertEqual(added.status, 0, added.error)
    XCTAssertEqual(added.output, "已收进来 · 来自 命令行\n")
    // Piped text, and a file given by a relative path.
    let piped = try run(binary, ["add"], root: root, input: "从管道收进来的纪要\n第二行")
    XCTAssertEqual(piped.status, 0, piped.error)
    let work = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try Data("# 周报\n本周完成了 Twin-7 第二轮".utf8).write(to: work.appendingPathComponent("周报.md"))
    let file = try run(binary, ["add", "--file", "周报.md"], root: root, directory: work)
    XCTAssertEqual(file.status, 0, file.error)
    let missing = try run(binary, ["add", "--file", "nope.pdf"], root: root, directory: work)
    XCTAssertEqual(missing.status, 2)
    let due = try run(binary, ["due"], root: root)
    XCTAssertEqual(due.status, 0, due.error)
    XCTAssertEqual(due.output, "今天到期 1 件：\n· 10月1日 交初稿 — Twin-7 实验\n")
    let dueJSON = try run(binary, ["due", "--days", "3", "--json"], root: root)
    XCTAssertEqual(try JSONValue.parse(dueJSON.output)["lines"]?.arrayValue?.count, 1)
    let usage = try run(binary, ["add", "--bogus"], root: root)
    XCTAssertEqual(usage.status, 64)

    let texts = drafts.all.map(\.text)
    XCTAssertEqual(texts.count, 3)
    XCTAssertEqual(texts[0], "下午 三点 组会")
    XCTAssertEqual(texts[1], "从管道收进来的纪要\n第二行")
    XCTAssertTrue(texts[2].contains("Twin-7 第二轮"))
    XCTAssertEqual(Set(drafts.all.compactMap(\.source?.name)), ["命令行"])
    let requests = await app.adds
    XCTAssertEqual(
      requests[2].filePaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
      [work.appendingPathComponent("周报.md").resolvingSymlinksInPath().path])
    let dues = await app.dues
    XCTAssertEqual(dues, [0, 3])

    // Started by an agent as its MCP server, the helper never forwards an
    // owner method, whatever the agent sends.
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
    input.fileHandleForWriting.write(
      Data(
        (#"{"jsonrpc":"2.0","id":7,"method":"mindloom/owner.add","params":{"text":"冒充主人"}}"#
          + "\n").utf8))
    let reply = try XCTUnwrap(readLine(output.fileHandleForReading.fileDescriptor, timeout: 10))
    input.fileHandleForWriting.closeFile()
    agent.waitUntilExit()
    let value = try JSONValue.parse(reply)
    XCTAssertEqual(value["id"], 7)
    XCTAssertEqual(value["error"]?["code"]?.intValue, Int64(MCPErrorCode.methodNotFound))
    XCTAssertEqual(drafts.all.count, 3, "nothing from the agent was taken in")
    let consent = await owner.consentRequests.count
    XCTAssertEqual(consent, 0)
  }
}
