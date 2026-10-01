import BestASRAgentAccess
import BestASRDomain
import BestASRPersistence
import Foundation
import GRDB
import MindloomAgentProtocol
import XCTest

/// AGENT-CONTRACT §4, end to end: the real `mindloom-mcp` binary built from
/// this package, a synthetic data root, the App's socket server, service and
/// library store, and an MCP client (this test) over the helper's stdio. The
/// Python client in `script/agent_e2e/` drives the same binary from outside.
final class AgentHelperEndToEndTests: XCTestCase {
  private final class Helper: @unchecked Sendable {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    private var buffer = AgentLineBuffer()
    private var nextID = 0

    init(binary: URL, dataRoot: URL) throws {
      process.executableURL = binary
      var environment = ProcessInfo.processInfo.environment
      environment[AgentSocketLocation.dataRootEnvironmentKey] = dataRoot.path
      process.environment = environment
      process.standardInput = input
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      try process.run()
    }

    func send(_ value: JSONValue) {
      input.fileHandleForWriting.write(Data((value.serialized + "\n").utf8))
    }

    func request(_ method: String, _ params: JSONValue? = nil) throws -> JSONValue {
      nextID += 1
      let id = JSONValue.int(Int64(nextID))
      send(MCPMessage.request(id: id, method: method, params: params))
      let descriptor = output.fileHandleForReading.fileDescriptor
      let deadline = Date().addingTimeInterval(20)
      var chunk = [UInt8](repeating: 0, count: 65_536)
      while Date() < deadline {
        var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, 100) > 0 else { continue }
        let count = read(descriptor, &chunk, chunk.count)
        guard count > 0 else { break }
        for line in buffer.append(Data(chunk[0..<count])) {
          let value = try JSONValue.parse(line)
          if value["id"] == id { return value }
        }
      }
      throw CocoaError(.fileReadUnknown)
    }

    func call(_ tool: String, _ arguments: JSONValue = [:]) throws -> JSONValue {
      try request("tools/call", ["name": .string(tool), "arguments": arguments])["result"] ?? .null
    }

    func close() {
      input.fileHandleForWriting.closeFile()
      process.waitUntilExit()
    }
  }

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

  func testRealHelperOverStdioAgainstASyntheticRoot() async throws {
    let binary = try helperBinary()
    let root = try makeSyntheticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    let owner = ScriptedOwner()
    let service = AgentAccessService(
      memory: FixedMemory(snapshot: try AgentFixture.snapshot()), records: store,
      secrets: try FileAgentGrantSecretStore(dataRoot: root), consent: owner,
      configuration: .init(consentTimeout: .seconds(5)), timeZone: AgentFixture.timeZone,
      clock: { AgentFixture.now })
    let server = AgentSocketServer(dataRoot: root, service: service)

    // The App is not running.
    let helper = try Helper(binary: binary, dataRoot: root)
    defer { helper.close() }
    let initialize = try helper.request(
      "initialize",
      [
        "protocolVersion": "2025-06-18", "capabilities": [:],
        "clientInfo": ["name": "claude-code", "version": "e2e"],
      ])
    XCTAssertEqual(initialize["result"]?["serverInfo"]?["name"], "mindloom")
    helper.send(MCPMessage.notification(method: "notifications/initialized"))
    XCTAssertEqual(try helper.request("tools/list")["result"]?["tools"]?.arrayValue?.count, 6)
    let offline = try helper.call("search_matters", ["query": "Twin"])
    XCTAssertEqual(offline.text, AgentCopy.notRunning)
    XCTAssertTrue(offline.isErrorResult)

    // The App starts: the same helper connects, replays the handshake, and
    // the owner is asked once.
    try server.start()
    await owner.queue(allowAll())
    let found = try helper.call("search_matters", ["query": "Twin"])
    XCTAssertEqual(found.matterIDs, [AgentFixture.twin, AgentFixture.openDay], found.text)
    let requests = await owner.consentRequests
    XCTAssertEqual(requests.map(\.client.displayName), ["Claude Code"])
    let matter = try helper.call("get_matter", ["id": .string(AgentFixture.twin)])
    XCTAssertTrue(matter.text.contains(AgentCopy.dataHeader))
    XCTAssertFalse(matter.serialized.contains(AgentFixture.phone))
    XCTAssertEqual(
      try helper.call("get_matter", ["id": .string(AgentFixture.labWeekly)]).errorCode, "not_found")
    XCTAssertEqual(try helper.call("add_to_inbox", ["text": "建议"]).errorCode, "read_only")
    let resources = try helper.request("resources/list")["result"]?["resources"]?.arrayValue
    XCTAssertEqual(resources?.count, 3)

    // The App quits mid-session, then comes back: the grant holds.
    server.stop()
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(try helper.call("list_recent").text, AgentCopy.notRunning)
    try server.start()
    let back = try helper.call("list_recent", ["days": 14])
    XCTAssertFalse(back.isErrorResult, back.text)
    let asked = await owner.consentRequests.count
    XCTAssertEqual(asked, 1)
    server.stop()

    // Audit rows for every call, none holding content; nothing filed.
    let audit = try await store.agentAudit(clientKey: nil, limit: 100)
    XCTAssertEqual(audit.count, 6)
    let dump = audit.map { "\($0.clientName)|\($0.tool)|\($0.outcome)|\($0.matterIDs)" }.joined()
    for content in ["Twin", "真机", AgentFixture.phone, "建议"] {
      XCTAssertFalse(dump.contains(content), content)
    }
    try await store.checkpointAndClose()
    let queue = try DatabaseQueue(path: root.appendingPathComponent("history.sqlite").path)
    let sessions = try await queue.read {
      try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sessions")
    }
    XCTAssertEqual(sessions, 0)
  }
}
