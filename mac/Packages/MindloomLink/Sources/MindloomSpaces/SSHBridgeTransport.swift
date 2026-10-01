#if os(macOS)
  import Darwin
  import Foundation
  import MindloomLink

  /// How this Mac's own ssh reaches the gate with its own key (v8 B1): no
  /// config file, no agent, only the given identity, the pinned host key in
  /// a private known_hosts file under a fixed alias, batch mode. The key
  /// files exist only while ssh reads them.
  public struct SSHGateRoute: Sendable {
    public let sshPath: String
    public let spark: SpaceInviteCode.Endpoint
    public let relay: SpaceInviteCode.Endpoint?
    /// Tests only: a ProxyCommand used instead of the relay (e.g. the owner's
    /// own connection to a jump host); the member key still does the Spark hop.
    public let proxyCommandOverride: String?
    /// A private 0700 folder for the known_hosts file and the short-lived key files.
    public let workDirectory: URL

    public init(
      spark: SpaceInviteCode.Endpoint, relay: SpaceInviteCode.Endpoint?, workDirectory: URL,
      proxyCommandOverride: String? = nil, sshPath: String = "/usr/bin/ssh"
    ) {
      self.spark = spark
      self.relay = relay
      self.workDirectory = workDirectory
      self.proxyCommandOverride = proxyCommandOverride
      self.sshPath = sshPath
    }

    static let sparkAlias = "mindloom-spark"
    static let relayAlias = "mindloom-relay"

    public enum RouteError: Error, Equatable, Sendable {
      case unsafeEndpoint
      case filesystem
    }

    /// Writes the private known_hosts file (both pinned keys) and returns the
    /// ssh arguments for `command` on the Spark with the key file at
    /// `keyFile` (and the relay key at `relayKeyFile`).
    func arguments(command: String, keyFile: URL, relayKeyFile: URL?) throws -> [String] {
      try arguments(
        command: command, keyFile: keyFile, relayKeyFiles: relayKeyFile.map { [$0] } ?? [])
    }

    /// The relay hop offers each key in `relayKeyFiles` in turn (review
    /// V8R-12: the member's own key first, whose relay line the Spark owner's
    /// Mac adds after enrollment; the invite's ticket key only until then).
    func arguments(command: String, keyFile: URL, relayKeyFiles: [URL]) throws -> [String] {
      guard let user = spark.user, SSHEndpointRules.isSafeHost(spark.host),
        SSHEndpointRules.isSafeUser(user),
        let sparkKey = SSHEndpointRules.hostKeyWords(spark.hostKey)
      else { throw RouteError.unsafeEndpoint }
      var lines = ["\(Self.sparkAlias) \(sparkKey.0) \(sparkKey.1)"]
      var proxy: String?
      if let override = proxyCommandOverride {
        proxy = override
      } else if let relay {
        guard let relayUser = relay.user, SSHEndpointRules.isSafeHost(relay.host),
          SSHEndpointRules.isSafeUser(relayUser),
          let relayKey = SSHEndpointRules.hostKeyWords(relay.hostKey), !relayKeyFiles.isEmpty
        else { throw RouteError.unsafeEndpoint }
        lines.append("\(Self.relayAlias) \(relayKey.0) \(relayKey.1)")
        proxy =
          ([
            Self.quote(sshPath), "-F", "/dev/null", "-T", "-o", "BatchMode=yes", "-o",
            "IdentitiesOnly=yes", "-o", "IdentityAgent=none", "-o",
            "UserKnownHostsFile=\(Self.quote(knownHosts.path))", "-o",
            "GlobalKnownHostsFile=/dev/null",
            "-o", "HostKeyAlias=\(Self.relayAlias)", "-o", "StrictHostKeyChecking=yes", "-o",
            "LogLevel=ERROR", "-o", "ConnectTimeout=20",
          ] + relayKeyFiles.flatMap { ["-i", Self.quote($0.path)] } + [
            "-p", "\(relay.port)", "-W", "%h:%p", "\(relayUser)@\(relay.host)",
          ]).joined(separator: " ")
      }
      try Self.writePrivate(Data((lines.joined(separator: "\n") + "\n").utf8), to: knownHosts)
      var args = [
        "-F", "/dev/null", "-T", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o",
        "IdentityAgent=none", "-o", "UserKnownHostsFile=\(knownHosts.path)", "-o",
        "GlobalKnownHostsFile=/dev/null", "-o", "HostKeyAlias=\(Self.sparkAlias)", "-o",
        "StrictHostKeyChecking=yes", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=20", "-o",
        "ServerAliveInterval=30", "-o", "ClearAllForwardings=yes", "-o", "ForwardAgent=no", "-o",
        "ForwardX11=no", "-o", "PermitLocalCommand=no", "-i", keyFile.path,
      ]
      if let proxy { args += ["-o", "ProxyCommand=\(proxy)"] }
      args += ["-p", "\(spark.port)", "\(user)@\(spark.host)", command]
      return args
    }

    var knownHosts: URL { workDirectory.appendingPathComponent("known_hosts") }

    /// A fresh 0600 key file (O_EXCL) in the work folder.
    func materialize(_ key: SSHEd25519Key) throws -> URL {
      let url = workDirectory.appendingPathComponent(".k-\(UUID().uuidString.lowercased())")
      try Self.writePrivate(Data(key.openSSHPrivateKey().utf8), to: url, exclusive: true)
      return url
    }

    static func writePrivate(_ data: Data, to url: URL, exclusive: Bool = false) throws {
      let folder = url.deletingLastPathComponent()
      do {
        try FileManager.default.createDirectory(
          at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      } catch { throw RouteError.filesystem }
      guard chmod(folder.path, 0o700) == 0 else { throw RouteError.filesystem }
      let target = exclusive ? url : folder.appendingPathComponent(".tmp-\(UUID().uuidString)")
      let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else { throw RouteError.filesystem }
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      do {
        try handle.write(contentsOf: data)
        try handle.close()
      } catch {
        unlink(target.path)
        throw RouteError.filesystem
      }
      if !exclusive {
        guard rename(target.path, url.path) == 0 else {
          unlink(target.path)
          throw RouteError.filesystem
        }
      }
    }

    /// A word for `/bin/sh` (ProxyCommand runs through the shell).
    static func quote(_ text: String) -> String {
      "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
  }

  /// Bytes from a child's stdout, handed out in order; nil at the end.
  final class ChunkQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var finished = false
    private var waiter: CheckedContinuation<Data?, Never>?

    func push(_ data: Data) {
      let resume: CheckedContinuation<Data?, Never>? = lock.withLock {
        if let waiter {
          self.waiter = nil
          return waiter
        }
        chunks.append(data)
        return nil
      }
      resume?.resume(returning: data)
    }

    func finish() {
      let resume: CheckedContinuation<Data?, Never>? = lock.withLock {
        finished = true
        defer { waiter = nil }
        return waiter
      }
      resume?.resume(returning: nil)
    }

    func next() async -> Data? {
      await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
        let ready: (Bool, Data?) = lock.withLock {
          if !chunks.isEmpty { return (true, chunks.removeFirst()) }
          if finished { return (true, nil) }
          waiter = continuation
          return (false, nil)
        }
        if ready.0 { continuation.resume(returning: ready.1) }
      }
    }
  }

  /// One ssh child and its pipes; stdout is read on its own queue.
  final class BridgeProcess: @unchecked Sendable {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    let chunks = ChunkQueue()
    private let readQueue = DispatchQueue(label: "mindloom.bridge.read")
    private let writeQueue = DispatchQueue(label: "mindloom.bridge.write")

    init(path: String, arguments: [String]) throws {
      process.executableURL = URL(fileURLWithPath: path)
      process.arguments = arguments
      process.standardInput = input
      process.standardOutput = output
      process.standardError = errors
      var environment = ProcessInfo.processInfo.environment
      environment["SSH_AUTH_SOCK"] = nil
      environment["SSH_ASKPASS"] = nil
      process.environment = environment
      try process.run()
      let handle = output.fileHandleForReading
      let chunks = chunks
      readQueue.async {
        while true {
          let data = handle.availableData
          if data.isEmpty { break }
          chunks.push(data)
        }
        chunks.finish()
      }
      // stderr is drained (ssh's own messages; nothing of ours goes there).
      let errorHandle = errors.fileHandleForReading
      DispatchQueue.global(qos: .utility).async {
        while !errorHandle.availableData.isEmpty {}
      }
    }

    func write(_ data: Data) async throws {
      let handle = input.fileHandleForWriting
      try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
        writeQueue.async {
          do {
            try handle.write(contentsOf: data)
            done.resume()
          } catch {
            done.resume(throwing: SpaceClientError.transport)
          }
        }
      }
    }

    var isRunning: Bool { process.isRunning }

    func stop() {
      try? input.fileHandleForWriting.close()
      if process.isRunning { process.terminate() }
    }
  }

  /// A member Mac's transport to the space, access and infra routes: a
  /// long-lived `ssh -T <spark> bridge` with its own key, HTTP/1.1
  /// keep-alive over the session's stdin/stdout, its own credential on every
  /// request. One request at a time; a session the gate closed (idle 10
  /// minutes, a refused malformed request) is reopened.
  public actor SSHBridgeTransport: SpaceTransport {
    public typealias Secrets =
      @Sendable () throws -> (
        credential: String, key: SSHEd25519Key, relayKey: SSHEd25519Key?
      )

    private let route: SSHGateRoute
    private let secrets: Secrets
    private let timeout: TimeInterval
    private var process: BridgeProcess?
    private var parser = HTTPBridgeCodec.ResponseParser()
    private var keyFiles: [URL] = []
    /// The credential of the open session (read from the store once per session).
    private var credential: String?
    private var lastUsed = Date.distantPast
    private var answered = 0
    /// Responses this session has given (tests and the console's status).
    public private(set) var sessionsOpened = 0

    public init(route: SSHGateRoute, timeout: TimeInterval = 300, secrets: @escaping Secrets) {
      self.route = route
      self.timeout = timeout
      self.secrets = secrets
    }

    public func close() {
      teardown()
    }

    public nonisolated func send(_ request: SpaceHTTPRequest) async throws -> SpaceHTTPResponse {
      try await exchange(request)
    }

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// One request at a time on the session (the actor alone would let a
    /// second request in while the first waits for its answer).
    private func acquire() async {
      if !busy {
        busy = true
        return
      }
      await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
      if waiters.isEmpty {
        busy = false
      } else {
        waiters.removeFirst().resume()
      }
    }

    private func exchange(_ request: SpaceHTTPRequest) async throws -> SpaceHTTPResponse {
      await acquire()
      defer { release() }
      // The gate ends an idle session after 10 minutes: start a new one first.
      if Date().timeIntervalSince(lastUsed) > 540 { teardown() }
      do {
        return try await once(request)
      } catch SpaceClientError.transport where answered > 0 {
        // A session that had answered before died under us: one new session.
        teardown()
        return try await once(request)
      }
    }

    private func once(_ request: SpaceHTTPRequest) async throws -> SpaceHTTPResponse {
      if process == nil || process?.isRunning != true { try start() }
      guard let process, let credential else { throw SpaceClientError.transport }
      var headers: [(String, String)] = [("Authorization", "Bearer \(credential)")]
      if let type = request.contentType { headers.append(("Content-Type", type)) }
      for (name, value) in request.headers.sorted(by: { $0.key < $1.key }) {
        headers.append((name, value))
      }
      let bytes = HTTPBridgeCodec.encode(
        method: request.method, target: request.target, headers: headers, body: request.body)
      let watchdog = Task { [timeout] in
        try? await Task.sleep(for: .seconds(timeout))
        if !Task.isCancelled { process.stop() }
      }
      defer { watchdog.cancel() }
      do {
        try await process.write(bytes)
      } catch {
        teardown()
        throw SpaceClientError.transport
      }
      while true {
        let response: HTTPBridgeCodec.Response?
        do { response = try parser.next() } catch {
          teardown()
          throw SpaceClientError.transport
        }
        if let response {
          answered += 1
          lastUsed = Date()
          // The keys were read when the session authenticated.
          removeKeyFiles()
          if response.closes { teardown() }
          return SpaceHTTPResponse(status: response.status, body: response.body)
        }
        if let chunk = await process.chunks.next() {
          parser.feed(chunk)
        } else {
          parser.finish()
          if let last = try? parser.next() {
            answered += 1
            removeKeyFiles()
            teardown()
            return SpaceHTTPResponse(status: last.status, body: last.body)
          }
          teardown()
          throw SpaceClientError.transport
        }
      }
    }

    private func start() throws {
      teardown()
      let (credential, key, relayKey) = try secrets()
      self.credential = credential
      let keyFile = try route.materialize(key)
      keyFiles.append(keyFile)
      var relayFiles: [URL] = []
      if route.relay != nil, route.proxyCommandOverride == nil {
        // V8R-12: this Mac's own key first (its own relay line), the
        // invite's ticket key only while that line is not there yet.
        relayFiles.append(keyFile)
        if let relayKey {
          let ticketFile = try route.materialize(relayKey)
          keyFiles.append(ticketFile)
          relayFiles.append(ticketFile)
        }
      }
      do {
        let args = try route.arguments(
          command: "bridge", keyFile: keyFile, relayKeyFiles: relayFiles)
        let child = try BridgeProcess(path: route.sshPath, arguments: args)
        process = child
        parser = HTTPBridgeCodec.ResponseParser()
        answered = 0
        sessionsOpened += 1
      } catch {
        removeKeyFiles()
        throw SpaceClientError.transport
      }
    }

    private func removeKeyFiles() {
      for url in keyFiles { unlink(url.path) }
      keyFiles = []
    }

    private func teardown() {
      process?.stop()
      process = nil
      credential = nil
      parser = HTTPBridgeCodec.ResponseParser()
      removeKeyFiles()
    }
  }

  /// Runs enrollment: the invitee's Mac connects with the ticket key, which
  /// can only run `enroll`, writes the signed request on stdin and reads the
  /// Spark's one-line answer.
  public enum SSHGateEnrollment {
    public static func enroll(
      route: SSHGateRoute, ticketKey: SSHEd25519Key, request: SpaceJSON, timeout: TimeInterval = 90
    ) async throws -> AccessEnrollAnswer {
      let keyFile = try route.materialize(ticketKey)
      var relayFile: URL?
      if route.relay != nil, route.proxyCommandOverride == nil {
        relayFile = try route.materialize(ticketKey)
      }
      defer {
        unlink(keyFile.path)
        if let relayFile { unlink(relayFile.path) }
      }
      let args = try route.arguments(command: "enroll", keyFile: keyFile, relayKeyFile: relayFile)
      let child = try BridgeProcess(path: route.sshPath, arguments: args)
      let watchdog = Task {
        try? await Task.sleep(for: .seconds(timeout))
        if !Task.isCancelled { child.stop() }
      }
      defer { watchdog.cancel() }
      try await child.write(try request.encoded() + Data("\n".utf8))
      try? child.input.fileHandleForWriting.close()
      var output = Data()
      while let chunk = await child.chunks.next() {
        output.append(chunk)
        if output.count > 64 * 1024 { break }
      }
      child.stop()
      let line =
        String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(
          String.init) ?? ""
      guard let answer = try? JSONDecoder().decode(AccessEnrollAnswer.self, from: Data(line.utf8))
      else { throw SpaceClientError.transport }
      return answer
    }
  }
#endif
