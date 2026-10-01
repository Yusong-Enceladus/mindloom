import BestASRAgentAccess
import BestASRDomain
import Darwin
import Foundation
import MindloomAgentProtocol
import XCTest

/// A short synthetic data root (a Unix socket path holds 103 bytes).
func makeSyntheticRoot() throws -> URL {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "ml-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
  try FileManager.default.createDirectory(
    at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  try Data("agent tests\n".utf8).write(to: root.appendingPathComponent("SYNTHETIC_DATA_ROOT"))
  return root
}

/// Reads one reply line from a connected socket, or nil at end of stream.
func readLine(_ descriptor: Int32, timeout: TimeInterval = 5) -> String? {
  var buffer = AgentLineBuffer()
  var chunk = [UInt8](repeating: 0, count: 65_536)
  var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    guard poll(&poller, 1, 100) > 0 else { continue }
    let count = read(descriptor, &chunk, chunk.count)
    guard count > 0 else { return nil }
    if let line = buffer.append(Data(chunk[0..<count])).first { return line }
  }
  return nil
}

final class AgentSocketTests: XCTestCase {
  func testThePeerOwnerCheckUsesKernelCredentialsAndLibproc() {
    XCTAssertTrue(AgentProcessInspector.peerIsOwner(AgentPeer(uid: getuid(), pid: getpid())))
    // Another user.
    XCTAssertFalse(AgentProcessInspector.peerIsOwner(AgentPeer(uid: getuid() + 1, pid: getpid())))
    // Credentials that claim this user for a process libproc says is root's.
    XCTAssertFalse(AgentProcessInspector.peerIsOwner(AgentPeer(uid: getuid(), pid: 1)))
    XCTAssertEqual(AgentProcessInspector.ownerUID(getpid()), getuid())
    XCTAssertEqual(AgentProcessInspector.parentPID(getpid()), getppid())
    XCTAssertNotNil(AgentProcessInspector.executablePath(getpid()))
  }

  private func service() throws -> (AgentAccessService, ScriptedOwner) {
    let owner = ScriptedOwner()
    return (
      AgentAccessService(
        memory: FixedMemory(snapshot: try AgentFixture.snapshot()), records: MemoryAgentRecords(),
        secrets: MemoryAgentGrantSecretStore(), consent: owner, timeZone: AgentFixture.timeZone,
        clock: { AgentFixture.now }),
      owner
    )
  }

  func testServerSocketIsPrivateAndServesAnOwnedPeer() async throws {
    let root = try makeSyntheticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (service, owner) = try service()
    let server = AgentSocketServer(dataRoot: root, service: service)
    try server.start()
    defer { server.stop() }
    var entry = stat()
    XCTAssertEqual(lstat(server.socketURL.path, &entry), 0)
    XCTAssertEqual(entry.st_mode & S_IFMT, S_IFSOCK)
    XCTAssertEqual(entry.st_mode & 0o777, 0o600)
    XCTAssertEqual(entry.st_uid, getuid())
    XCTAssertEqual(lstat(server.socketURL.deletingLastPathComponent().path, &entry), 0)
    XCTAssertEqual(entry.st_mode & 0o777, 0o700)

    let descriptor = try XCTUnwrap(
      AgentSocketClient.connectVerified(server.socketURL.path, log: { XCTFail($0) }))
    defer { close(descriptor) }
    await owner.queue(allowAll())
    AgentSocketIO.writeAll(
      descriptor,
      Data(
        (#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-code"}}}"#
          + "\n"
          + #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_recent","arguments":{}}}"#
          + "\n").utf8))
    let first = try JSONValue.parse(try XCTUnwrap(readLine(descriptor)))
    let second = try JSONValue.parse(try XCTUnwrap(readLine(descriptor)))
    XCTAssertEqual(first["id"], 1)
    XCTAssertEqual(second["id"], 2)
    XCTAssertEqual(second["result"]?["isError"], false)
    // The client is named by the process that started the peer (this test
    // runner's parent), read by the App from libproc, with its code
    // signature (V7-A3): the path is folded only for a signed parent.
    let request = await owner.consentRequests.first
    XCTAssertEqual(request?.client.name, "claude-code")
    let parentSigner = AgentCodeSigning.signer(pid: getppid())
    XCTAssertEqual(request?.client.signer, parentSigner)
    XCTAssertEqual(
      request?.client.path,
      AgentClientIdentity(
        name: "claude-code", path: AgentProcessInspector.executablePath(getppid()) ?? "",
        signer: parentSigner
      ).path)
    XCTAssertEqual(server.acceptedConnections, 1)
    XCTAssertEqual(server.rejectedConnections, 0)
  }

  func testAPeerFailingTheOwnerCheckGetsNothing() async throws {
    let root = try makeSyntheticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (service, owner) = try service()
    let server = AgentSocketServer(dataRoot: root, service: service, peerCheck: { _ in false })
    try server.start()
    defer { server.stop() }
    let descriptor = try AgentSocketIO.connect(path: server.socketURL.path)
    defer { close(descriptor) }
    AgentSocketIO.writeAll(
      descriptor, Data((#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"# + "\n").utf8))
    XCTAssertNil(readLine(descriptor, timeout: 2))
    XCTAssertEqual(server.rejectedConnections, 1)
    XCTAssertEqual(server.acceptedConnections, 0)
    let asked = await owner.consentRequests.count
    XCTAssertEqual(asked, 0)
  }

  func testAnExistingOpenFolderIsTightened() throws {
    let root = try makeSyntheticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = AgentSocketLocation.directory(dataRoot: root)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    let (service, _) = try service()
    let server = AgentSocketServer(dataRoot: root, service: service)
    try server.start()
    server.stop()
    var entry = stat()
    XCTAssertEqual(lstat(folder.path, &entry), 0)
    XCTAssertEqual(entry.st_mode & 0o777, 0o700)
    XCTAssertFalse(FileManager.default.fileExists(atPath: server.socketURL.path))
  }

  func testTheHelperRefusesASocketThatIsNotPrivate() throws {
    let root = try makeSyntheticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("open", isDirectory: true)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    let path = folder.appendingPathComponent("s.sock").path
    let listener = try AgentSocketIO.listen(path: path)
    defer {
      close(listener)
      unlink(path)
    }
    var reasons: [String] = []
    XCTAssertNil(AgentSocketClient.connectVerified(path, log: { reasons.append($0) }))
    chmod(folder.path, 0o700)
    chmod(path, 0o666)
    XCTAssertNil(AgentSocketClient.connectVerified(path, log: { reasons.append($0) }))
    // Another user's socket is refused too (checked against a different uid).
    chmod(path, 0o600)
    XCTAssertNil(
      AgentSocketClient.connectVerified(path, uid: getuid() + 1, log: { reasons.append($0) }))
    XCTAssertEqual(reasons.count, 3)
    let ok = AgentSocketClient.connectVerified(path, log: { XCTFail($0) })
    XCTAssertNotNil(ok)
    ok.map { _ = close($0) }
  }

  func testNothingListeningMeansNotRunning() throws {
    let root = try makeSyntheticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertNil(
      AgentSocketClient.connectVerified(
        AgentSocketLocation.socketURL(dataRoot: root).path, log: { _ in }))
    XCTAssertEqual(
      AgentSocketLocation.dataRoot(environment: ["MINDLOOM_DATA_ROOT": root.path])?.path, root.path)
    XCTAssertNil(AgentSocketLocation.dataRoot(environment: ["MINDLOOM_DATA_ROOT": "relative/path"]))
    XCTAssertTrue(
      AgentSocketLocation.dataRoot(environment: [:])?.path.hasSuffix(
        "Library/Application Support/bestASR") ?? false)
  }
}
