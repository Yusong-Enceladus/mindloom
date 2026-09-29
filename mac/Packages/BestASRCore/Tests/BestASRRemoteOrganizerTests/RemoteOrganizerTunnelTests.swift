import BestASRRemoteOrganizer
import Darwin
import Foundation
import XCTest

final class RemoteOrganizerTunnelTests: XCTestCase {
  func testConfigurationRejectsOptionAndShellInjection() throws {
    let defaults = try RemoteOrganizerLinkConfiguration(host: "spark-xxxx")
    XCTAssertEqual(defaults.host, "spark-xxxx")
    XCTAssertEqual(defaults.remoteSocketPath, "~/hack/organizer-data/organizer.sock")
    XCTAssertEqual(defaults.remoteTokenPath, "~/hack/organizer-data/link_token")
    for host in ["-oProxyCommand=evil", "spark;rm", "spark xxxx", "", "spark$(id)"] {
      XCTAssertThrowsError(try RemoteOrganizerLinkConfiguration(host: host), host)
    }
    for path in ["~/x;id", "$(id)", "~/../etc/passwd", "-rf", "a b", "`id`"] {
      XCTAssertThrowsError(
        try RemoteOrganizerLinkConfiguration(host: "spark-xxxx", remoteTokenPath: path), path)
      XCTAssertThrowsError(
        try RemoteOrganizerLinkConfiguration(host: "spark-xxxx", remoteSocketPath: path), path)
    }
    // A socket path must be absolute or home-relative, name a file, and fit
    // the Unix socket limit.
    for path in [
      "relative.sock", "~/dir/", "/" + String(repeating: "a", count: 100), "127.0.0.1:8765",
    ] {
      XCTAssertThrowsError(
        try RemoteOrganizerLinkConfiguration(host: "spark-xxxx", remoteSocketPath: path), path)
    }
    XCTAssertNoThrow(
      try RemoteOrganizerLinkConfiguration(host: "spark-xxxx", remoteSocketPath: "/srv/org/o.sock"))
  }

  func testForwardCommandIsHardenedAndLoopbackOnly() {
    let arguments = RemoteOrganizerSSHCommand.forwardArguments(
      host: "spark-xxxx", localPort: 53_123,
      remoteSocketPath: "/home/owner/hack/organizer-data/organizer.sock"
    )
    let joined = arguments.joined(separator: " ")
    for option in [
      "BatchMode=yes", "ExitOnForwardFailure=yes", "StrictHostKeyChecking=yes",
      "ServerAliveInterval=15", "ControlMaster=no",
    ] {
      XCTAssertTrue(joined.contains(option), option)
    }
    // To the organizer's socket in its 0700 directory, never a TCP port that
    // another process on the Spark could hold while the organizer is down.
    XCTAssertTrue(
      joined.contains("-L 127.0.0.1:53123:/home/owner/hack/organizer-data/organizer.sock"))
    XCTAssertFalse(joined.contains("8765"))
    XCTAssertEqual(arguments.suffix(2), ["--", "spark-xxxx"])
    let token = RemoteOrganizerSSHCommand.tokenArguments(
      host: "spark-xxxx", remoteTokenPath: "~/hack/organizer-data/link_token"
    )
    XCTAssertEqual(token.suffix(3), ["--", "spark-xxxx", "cat ~/hack/organizer-data/link_token"])
    XCTAssertTrue(token.contains("ClearAllForwardings=yes"))
    XCTAssertFalse(token.contains("-L"))
    XCTAssertTrue(RemoteOrganizerSSHCommand.isValidLinkToken(String(repeating: "0f", count: 32)))
    XCTAssertFalse(RemoteOrganizerSSHCommand.isValidLinkToken(String(repeating: "0F", count: 32)))
    XCTAssertFalse(RemoteOrganizerSSHCommand.isValidLinkToken("abc"))
    let resolve = RemoteOrganizerSSHCommand.socketDirectoryArguments(
      host: "spark-xxxx", remoteDirectory: "~/hack/organizer-data"
    )
    XCTAssertEqual(resolve.suffix(3), ["--", "spark-xxxx", "cd ~/hack/organizer-data && pwd -P"])
    XCTAssertTrue(resolve.contains("ClearAllForwardings=yes"))
    XCTAssertTrue(
      RemoteOrganizerSSHCommand.isValidResolvedSocketPath(
        "/home/o/hack/organizer-data/organizer.sock"))
    for bad in ["~/x.sock", "relative.sock", "/a b/x.sock", "/x/../y.sock", "/x/"] {
      XCTAssertFalse(RemoteOrganizerSSHCommand.isValidResolvedSocketPath(bad), bad)
    }
  }

  /// The owner check reads the real socket table: only the process that holds
  /// the loopback listener passes, for exactly that port.
  func testListenerOwnershipIsTheActualSocketOwner() throws {
    let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: in_addr_t(UInt32(0x7F00_0001).bigEndian))
    let port = try RemoteOrganizerProcessInspector.freeLoopbackPort()
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    XCTAssertEqual(bound, 0)
    XCTAssertFalse(
      RemoteOrganizerProcessInspector.holdsLoopbackListener(pid: getpid(), port: port),
      "bound but not listening"
    )
    XCTAssertEqual(listen(descriptor, 1), 0)
    XCTAssertTrue(RemoteOrganizerProcessInspector.holdsLoopbackListener(pid: getpid(), port: port))
    XCTAssertFalse(
      RemoteOrganizerProcessInspector.holdsLoopbackListener(
        pid: getpid(), port: port == 65_535 ? port - 1 : port + 1)
    )
    // Another process does not hold our listener.
    let other = try launchSleep()
    defer { other.terminate() }
    XCTAssertFalse(
      RemoteOrganizerProcessInspector.holdsLoopbackListener(
        pid: other.processIdentifier, port: port
      )
    )
  }

  func testStaleTunnelCleanupKillsOnlyAnExactSignatureMatch() throws {
    let directory = try makeTemporaryDirectory("tunnels")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RemoteOrganizerTunnelRecordStore(directory: directory)
    let deadAppPID = try deadProcessIdentifier()

    // A live process whose command line is not our ssh signature (for
    // example a reused PID) is left alone, and its stale record is dropped.
    let unrelated = try launchSleep()
    defer { unrelated.terminate() }
    try store.write(
      .init(
        sshPID: unrelated.processIdentifier, appPID: deadAppPID,
        appExecutable: "/Applications/bestASR.app/Contents/MacOS/bestASR",
        host: "spark-xxxx", localPort: 50_001, remoteTarget: "/s/o.sock"
      )
    )
    let untouched = store.cleanUpStale()
    XCTAssertEqual(untouched, [])
    XCTAssertTrue(unrelated.isRunning)
    XCTAssertTrue(store.records().isEmpty)

    // A record owned by another live instance of the app is skipped.
    let otherInstance = try launchSleep()
    defer { otherInstance.terminate() }
    let guarded = try launchSleep()
    defer { guarded.terminate() }
    try store.write(
      .init(
        sshPID: guarded.processIdentifier, appPID: otherInstance.processIdentifier,
        appExecutable: "/bin/sleep", host: "spark-xxxx", localPort: 50_002,
        remoteTarget: "/s/o.sock"
      )
    )
    let matchingSleep: (RemoteOrganizerTunnelRecord) -> (String, [String]) = { _ in
      ("/bin/sleep", ["300"])
    }
    let skipped = store.cleanUpStale(expectedCommandLine: matchingSleep)
    XCTAssertEqual(skipped, [])
    XCTAssertTrue(guarded.isRunning)
    XCTAssertEqual(store.records().count, 1)

    // An orphan whose owner is gone and whose command line matches exactly is
    // terminated (the signature is injected here because tests run no ssh).
    try FileManager.default.removeItem(at: directory)
    let orphan = try launchSleep()
    try store.write(
      .init(
        sshPID: orphan.processIdentifier, appPID: deadAppPID,
        appExecutable: "/Applications/bestASR.app/Contents/MacOS/bestASR",
        host: "spark-xxxx", localPort: 50_003, remoteTarget: "/s/o.sock"
      )
    )
    let killed = store.cleanUpStale(expectedCommandLine: matchingSleep)
    XCTAssertEqual(killed, [orphan.processIdentifier])
    orphan.waitUntilExit()
    XCTAssertFalse(orphan.isRunning)
    XCTAssertTrue(store.records().isEmpty)
  }

  func testRealSSHSignatureIsTheRecordedForwardCommand() {
    let record = RemoteOrganizerTunnelRecord(
      sshPID: 1, appPID: 2, appExecutable: "/x", host: "spark-xxxx", localPort: 50_004,
      remoteTarget: "/home/o/hack/organizer-data/organizer.sock"
    )
    XCTAssertEqual(record.expectedCommandLine.executable, "/usr/bin/ssh")
    XCTAssertEqual(
      record.expectedCommandLine.arguments,
      RemoteOrganizerSSHCommand.forwardArguments(
        host: "spark-xxxx", localPort: 50_004,
        remoteSocketPath: "/home/o/hack/organizer-data/organizer.sock"
      )
    )
    let roundTrip = try? JSONDecoder().decode(
      RemoteOrganizerTunnelRecord.self, from: try XCTUnwrap(try? JSONEncoder().encode(record)))
    XCTAssertEqual(roundTrip, record)
    // A record left by a build that forwarded to TCP 8765 still yields that
    // build's exact signature, so its orphan can be ended.
    let legacy = try? JSONDecoder().decode(
      RemoteOrganizerTunnelRecord.self,
      from: Data(
        #"{"ssh_pid":7,"app_pid":8,"app_executable":"/x","host":"spark-xxxx","local_port":50005,"remote_port":8765}"#
          .utf8))
    XCTAssertTrue(
      legacy?.expectedCommandLine.arguments.joined(separator: " ")
        .contains("-L 127.0.0.1:50005:127.0.0.1:8765") == true)
    let live = RemoteOrganizerProcessInspector.commandLine(getpid())
    XCTAssertNotNil(live)
    XCTAssertEqual(live?.executable.isEmpty, false)
    XCTAssertEqual(live?.arguments.isEmpty, false)
  }

  private func launchSleep() throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["300"]
    try process.run()
    return process
  }

  private func deadProcessIdentifier() throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try process.run()
    process.waitUntilExit()
    return process.processIdentifier
  }
}

final class RemoteOrganizerProvenanceTests: XCTestCase {
  private let marker = RemoteOrganizerDataProvenance.syntheticMarkerFileName

  func testOnlyAMarkedSeparateRootMaySend() throws {
    let real = try makeTemporaryDirectory("real-library")
    let demo = try makeTemporaryDirectory("demo")
    defer {
      try? FileManager.default.removeItem(at: real)
      try? FileManager.default.removeItem(at: demo)
    }
    XCTAssertEqual(
      RemoteOrganizerDataProvenance.verdict(dataRoot: real, realLibraryRoot: real),
      .refusedRealLibrary
    )
    FileManager.default.createFile(
      atPath: real.appendingPathComponent(marker).path, contents: Data())
    XCTAssertEqual(
      RemoteOrganizerDataProvenance.verdict(dataRoot: real, realLibraryRoot: real),
      .refusedRealLibrary, "a marker inside the real library does not count"
    )
    XCTAssertEqual(
      RemoteOrganizerDataProvenance.verdict(
        dataRoot: real.appendingPathComponent("sub"), realLibraryRoot: real
      ),
      .refusedRealLibrary
    )
    XCTAssertEqual(
      RemoteOrganizerDataProvenance.verdict(dataRoot: demo, realLibraryRoot: real),
      .refusedNotSynthetic
    )
    try FileManager.default.createDirectory(
      at: demo.appendingPathComponent(marker), withIntermediateDirectories: true
    )
    XCTAssertEqual(
      RemoteOrganizerDataProvenance.verdict(dataRoot: demo, realLibraryRoot: real),
      .refusedNotSynthetic, "a directory is not the marker file"
    )
    try FileManager.default.removeItem(at: demo.appendingPathComponent(marker))
    FileManager.default.createFile(
      atPath: demo.appendingPathComponent(marker).path, contents: Data())
    XCTAssertEqual(
      RemoteOrganizerDataProvenance.verdict(dataRoot: demo, realLibraryRoot: real), .allowed
    )
    // The guard has no build-configuration branch; only the release switch
    // changes it, and that switch stays off during development.
    XCTAssertFalse(RemoteOrganizerDataProvenance.productReleaseAllowsOwnLibrary)
    XCTAssertEqual(
      RemoteOrganizerDataProvenance.verdict(
        dataRoot: real, realLibraryRoot: real, allowsOwnLibrary: true
      ),
      .allowed
    )
  }

  func testSeparateDataRootCanNeverPointAtTheRealLibrary() throws {
    let base = try makeTemporaryDirectory("roots")
    defer { try? FileManager.default.removeItem(at: base) }
    let real = base.appendingPathComponent("Application Support/bestASR", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    func refused(_ requested: String, _ expected: BestASRDataRootSelection.SelectionError) {
      XCTAssertThrowsError(
        try BestASRDataRootSelection.separateDataRoot(requested: requested, realLibraryRoot: real),
        requested
      ) { XCTAssertEqual($0 as? BestASRDataRootSelection.SelectionError, expected, requested) }
    }
    refused("", .malformedArgument)
    refused("  ", .malformedArgument)
    refused("relative/demo", .notAbsolute)
    refused(real.path, .insideRealLibrary)
    refused(real.appendingPathComponent("demo").path, .insideRealLibrary)
    refused(real.path.uppercased(), .insideRealLibrary)
    refused(base.appendingPathComponent("Application Support").path, .containsRealLibrary)
    // A symlink that resolves into the real library is refused too.
    let link = base.appendingPathComponent("innocent-looking")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    refused(link.path, .insideRealLibrary)
    refused(link.appendingPathComponent("not-yet").path, .insideRealLibrary)
    let demo = base.appendingPathComponent("demo-root")
    let selected = try BestASRDataRootSelection.separateDataRoot(
      requested: demo.path, realLibraryRoot: real
    )
    XCTAssertEqual(selected.standardizedFileURL.path, demo.standardizedFileURL.path)
  }

  /// `/.nofollow/<path>`, `/.resolve/N/<path>` and `/.vol/...` reach the same
  /// directory under a different spelling; the check compares file identity.
  func testMagicPathPrefixesOfTheRealLibraryAreRefused() throws {
    let real = try makeTemporaryDirectory("magic-real")
    defer { try? FileManager.default.removeItem(at: real) }
    FileManager.default.createFile(
      atPath: real.appendingPathComponent(marker).path, contents: Data())
    let canonical = try XCTUnwrap(
      realpath(real.path, nil).map {
        defer { free($0) }
        return String(decoding: UnsafeRawBufferPointer(start: $0, count: strlen($0)), as: UTF8.self)
      })
    var reachable = 0
    for spelling in [
      "/.nofollow" + canonical, "/.resolve/1" + canonical, "/.resolve/2" + canonical,
    ] {
      XCTAssertThrowsError(
        try BestASRDataRootSelection.separateDataRoot(requested: spelling, realLibraryRoot: real),
        spelling
      )
      guard FileManager.default.fileExists(atPath: spelling) else { continue }
      reachable += 1
      let url = URL(fileURLWithPath: spelling, isDirectory: true)
      XCTAssertTrue(BestASRDataRootSelection.path(url, isWithinOrEqualTo: real), spelling)
      XCTAssertTrue(
        BestASRDataRootSelection.path(url.appendingPathComponent("new"), isWithinOrEqualTo: real),
        spelling)
      XCTAssertEqual(
        RemoteOrganizerDataProvenance.verdict(dataRoot: url, realLibraryRoot: real),
        .refusedRealLibrary, "\(spelling) must not count as a marked separate root"
      )
    }
    XCTAssertGreaterThan(reachable, 0, "this macOS resolves at least one magic prefix")
    // A real library that does not exist yet is still recognized through the
    // kernel's spelling of its existing parent.
    let missing = real.appendingPathComponent("not-created-yet/bestASR")
    let viaMagic = URL(fileURLWithPath: "/.nofollow" + canonical + "/not-created-yet/bestASR")
    if FileManager.default.fileExists(atPath: "/.nofollow" + canonical) {
      XCTAssertTrue(BestASRDataRootSelection.path(viaMagic, isWithinOrEqualTo: missing))
    }
  }

  func testLaunchArgumentsNeverFallBackToTheRealLibrary() throws {
    let base = try makeTemporaryDirectory("arguments")
    defer { try? FileManager.default.removeItem(at: base) }
    let real = base.appendingPathComponent("Application Support/bestASR", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let demo = base.appendingPathComponent("demo").path
    let app = "/Applications/bestASR.app/Contents/MacOS/bestASR"
    func select(_ arguments: [String]) throws -> URL? {
      try BestASRDataRootSelection.separateDataRoot(arguments: arguments, realLibraryRoot: real)
    }
    XCTAssertNil(try select([app]), "no mention: the normal library")
    XCTAssertNil(try select([app, "-NSDocumentRevisionsDebugMode", "YES"]))
    XCTAssertEqual(try select([app, "-BestASRDataRoot", demo])?.path, demo)
    XCTAssertEqual(
      try select([app, "-BestASRDataRoot", base.appendingPathComponent("BestASRDataRoot-x").path])?
        .lastPathComponent, "BestASRDataRoot-x", "the value may contain the option's name"
    )
    for arguments in [
      [app, "-BestASRDataRoot", ""],  // an unset shell variable
      [app, "-BestASRDataRoot", "   "],
      [app, "-BestASRDataRoot"],  // no value
      [app, "-BestASRDataRoot", "-NSSomething", "x"],
      [app, "-bestasrdataroot", demo],
      [app, "--BestASRDataRoot", demo],
      [app, "-BestASRDataRoot=" + demo],
      [app, "BestASRDataRoot", demo],
      [app, "-BestASRDataRoot", demo, "-BestASRDataRoot", demo],
      [app, "-BestASRDataRoot", real.path],
    ] {
      XCTAssertThrowsError(try select(arguments), arguments.joined(separator: " "))
    }
  }

  func testMarkedRootWhoseStoreLinksElsewhereIsRefused() throws {
    let real = try makeTemporaryDirectory("linked-real")
    let demo = try makeTemporaryDirectory("linked-demo")
    defer {
      try? FileManager.default.removeItem(at: real)
      try? FileManager.default.removeItem(at: demo)
    }
    FileManager.default.createFile(
      atPath: demo.appendingPathComponent(marker).path, contents: Data())
    let realDatabase = real.appendingPathComponent("history.sqlite")
    FileManager.default.createFile(atPath: realDatabase.path, contents: Data("db".utf8))
    try FileManager.default.createDirectory(
      at: real.appendingPathComponent("assets"), withIntermediateDirectories: true)
    let demoDatabase = demo.appendingPathComponent("history.sqlite")
    func verdict() -> RemoteOrganizerDataProvenance.Verdict {
      RemoteOrganizerDataProvenance.verdict(dataRoot: demo, realLibraryRoot: real)
    }
    XCTAssertEqual(verdict(), .allowed, "a fresh marked root")

    try FileManager.default.createSymbolicLink(at: demoDatabase, withDestinationURL: realDatabase)
    XCTAssertEqual(verdict(), .refusedLinkedStore, "symlinked database")
    try FileManager.default.removeItem(at: demoDatabase)

    try FileManager.default.linkItem(at: realDatabase, to: demoDatabase)
    XCTAssertEqual(verdict(), .refusedLinkedStore, "hard-linked database")
    try FileManager.default.removeItem(at: demoDatabase)

    let wal = demo.appendingPathComponent("history.sqlite-wal")
    try FileManager.default.createSymbolicLink(
      at: wal, withDestinationURL: real.appendingPathComponent("history.sqlite-wal"))
    XCTAssertEqual(verdict(), .refusedLinkedStore, "symlinked write-ahead log")
    try FileManager.default.removeItem(at: wal)

    let assets = demo.appendingPathComponent("assets")
    try FileManager.default.createSymbolicLink(
      at: assets, withDestinationURL: real.appendingPathComponent("assets"))
    XCTAssertEqual(verdict(), .refusedLinkedStore, "symlinked assets")
    try FileManager.default.removeItem(at: assets)

    FileManager.default.createFile(atPath: demoDatabase.path, contents: Data("own".utf8))
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    XCTAssertEqual(verdict(), .allowed, "its own database and assets")
  }

  func testOwnerRealLibraryIgnoresTheEnvironmentHome() throws {
    let expected = try XCTUnwrap(BestASRDataRootSelection.ownerRealLibraryRoot())
    XCTAssertTrue(expected.path.hasSuffix("/Library/Application Support/bestASR"))
    let previous = getenv("CFFIXED_USER_HOME").map { String(cString: $0) }
    setenv("CFFIXED_USER_HOME", "/tmp/not-the-owner", 1)
    defer {
      if let previous {
        setenv("CFFIXED_USER_HOME", previous, 1)
      } else {
        unsetenv("CFFIXED_USER_HOME")
      }
    }
    XCTAssertEqual(BestASRDataRootSelection.ownerRealLibraryRoot(), expected)
    XCTAssertFalse(expected.path.hasPrefix("/tmp/not-the-owner"))
  }
}

/// A one-connection HTTP/1.1 server on 127.0.0.1 that records the raw request.
private final class OneShotHTTPServer: @unchecked Sendable {
  let port: Int
  private let descriptor: Int32
  private let lock = NSLock()
  private var _request: String?

  var request: String? { lock.withLock { _request } }

  init() throws {
    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: in_addr_t(UInt32(0x7F00_0001).bigEndian))
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(fd, 4) == 0 else {
      close(fd)
      throw POSIXError(.EADDRINUSE)
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &length)
      }
    }
    descriptor = fd
    port = Int(UInt16(bigEndian: address.sin_port))
    Thread.detachNewThread { [self] in
      let client = accept(fd, nil, nil)
      guard client >= 0 else { return }
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while !String(decoding: data, as: UTF8.self).contains("\r\n\r\n") {
        let count = read(client, &buffer, buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
      }
      lock.withLock { _request = String(decoding: data, as: UTF8.self) }
      let body = #"{"ok":true}"#
      let response =
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
      let bytes = Array(response.utf8)
      _ = bytes.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
      close(client)
    }
  }

  func stop() { close(descriptor) }
}

final class RemoteOrganizerHTTPTransportTests: XCTestCase {
  private func request(port: Int, path: String = "/v1/health") -> RemoteOrganizerHTTPRequest {
    RemoteOrganizerHTTPRequest(
      method: "GET", port: port, path: path, body: nil,
      token: String(repeating: "5a", count: 32), timeout: 5
    )
  }

  /// Revocation cancels the transport while a worker may be about to send;
  /// that send must fail, not create a task on the invalidated session (an
  /// Objective-C exception that aborts the app).
  func testSendAfterCancelAllThrowsInsteadOfCrashing() async throws {
    let transport = URLSessionRemoteOrganizerTransport()
    transport.cancelAll()
    do {
      _ = try await transport.send(request(port: 9))
      XCTFail("a send after cancelAll must throw")
    } catch {}
  }

  func testSendsRacingCancelAllAllFinishWithoutCrashing() async throws {
    for _ in 0..<20 {
      let transport = URLSessionRemoteOrganizerTransport()
      let closedPort = request(port: 9)
      await withTaskGroup(of: Void.self) { group in
        for index in 0..<8 {
          group.addTask {
            _ = try? await transport.send(closedPort)
            if index == 3 { transport.cancelAll() }
          }
        }
        group.addTask { transport.cancelAll() }
      }
      do {
        _ = try await transport.send(request(port: 9))
        XCTFail("cancelled transports stay cancelled")
      } catch {}
    }
  }

  func testRequestCarriesTheBearerTokenOnlyToLoopbackV1Paths() async throws {
    XCTAssertThrowsError(
      try URLSessionRemoteOrganizerTransport.urlRequest(for: request(port: 8765, path: "/docs"))
    ) { XCTAssertEqual($0 as? RemoteOrganizerHTTPError, .notLoopback) }
    XCTAssertThrowsError(
      try URLSessionRemoteOrganizerTransport.urlRequest(
        for: request(port: 8765, path: "@evil.example/v1/health"))
    )
    let server = try OneShotHTTPServer()
    defer { server.stop() }
    let transport = URLSessionRemoteOrganizerTransport()
    let response = try await transport.send(request(port: server.port))
    XCTAssertEqual(response.status, 200)
    let raw = try XCTUnwrap(server.request)
    XCTAssertTrue(raw.hasPrefix("GET /v1/health HTTP/1.1\r\n"), raw)
    XCTAssertTrue(
      raw.contains("Authorization: Bearer \(String(repeating: "5a", count: 32))\r\n"),
      "the link token goes in the Authorization header"
    )
    XCTAssertFalse(raw.lowercased().contains("cookie"))
    transport.cancelAll()
  }
}
