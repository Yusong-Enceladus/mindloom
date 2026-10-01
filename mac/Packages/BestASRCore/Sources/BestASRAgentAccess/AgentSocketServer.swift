import Darwin
import Foundation
import MindloomAgentProtocol

/// The App's end of the helper's socket (AGENT-CONTRACT §1): a Unix domain
/// socket at `<data root>/agent/mindloom.sock`, the folder 0700 and the
/// socket 0600, both this user's. Each accepted connection is checked with
/// the kernel's peer credentials and libproc (the peer must be a process of
/// this user) before a single byte is read; then it is one MCP session.
public final class AgentSocketServer: @unchecked Sendable {
  public enum ServerError: Error, Equatable, Sendable {
    case folderNotPrivate
    case socket(AgentSocketError)
  }

  public let socketURL: URL
  private let service: AgentAccessService
  private let peerCheck: @Sendable (AgentPeer) -> Bool
  private let lock = NSLock()
  private var listener: Int32 = -1
  private var connections: Set<Int32> = []
  private var rejected = 0
  private var accepted = 0

  public init(
    dataRoot: URL, service: AgentAccessService,
    peerCheck: @escaping @Sendable (AgentPeer) -> Bool = { AgentProcessInspector.peerIsOwner($0) }
  ) {
    socketURL = AgentSocketLocation.socketURL(dataRoot: dataRoot)
    self.service = service
    self.peerCheck = peerCheck
  }

  /// Connections refused by the owner check since start.
  public var rejectedConnections: Int { lock.withLock { rejected } }
  public var acceptedConnections: Int { lock.withLock { accepted } }
  public var isRunning: Bool { lock.withLock { listener >= 0 } }

  public func start() throws {
    guard !isRunning else { return }
    let folder = socketURL.deletingLastPathComponent()
    try Self.preparePrivateFolder(folder)
    let descriptor: Int32
    do {
      descriptor = try AgentSocketIO.listen(path: socketURL.path)
    } catch let error as AgentSocketError {
      throw ServerError.socket(error)
    }
    lock.withLock { listener = descriptor }
    let thread = Thread { [weak self] in self?.acceptLoop(descriptor) }
    thread.name = "mindloom.agent.accept"
    thread.start()
  }

  /// Stops listening, removes the socket and ends every session.
  public func stop() {
    let (descriptor, open) = lock.withLock { () -> (Int32, Set<Int32>) in
      let current = (listener, connections)
      listener = -1
      connections = []
      return current
    }
    if descriptor >= 0 {
      shutdown(descriptor, SHUT_RDWR)
      close(descriptor)
      unlink(socketURL.path)
    }
    for connection in open { shutdown(connection, SHUT_RDWR) }
  }

  /// `<root>/agent`: created 0700; an existing one must be this user's
  /// directory (not a link) and is tightened to 0700.
  static func preparePrivateFolder(_ folder: URL) throws {
    var entry = stat()
    if lstat(folder.path, &entry) != 0 {
      guard mkdir(folder.path, S_IRWXU) == 0 || errno == EEXIST else {
        throw ServerError.folderNotPrivate
      }
      guard lstat(folder.path, &entry) == 0 else { throw ServerError.folderNotPrivate }
    }
    guard entry.st_mode & S_IFMT == S_IFDIR, entry.st_uid == getuid() else {
      throw ServerError.folderNotPrivate
    }
    if entry.st_mode & 0o077 != 0 {
      guard chmod(folder.path, S_IRWXU) == 0 else { throw ServerError.folderNotPrivate }
    }
  }

  private func acceptLoop(_ descriptor: Int32) {
    while true {
      let connection = accept(descriptor, nil, nil)
      if connection < 0 {
        if errno == EINTR || errno == ECONNABORTED { continue }
        return
      }
      var on: Int32 = 1
      setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      guard let peer = AgentPeer.of(connection), peerCheck(peer),
        let inspected = AgentConnectionPeer.inspect(connection)
      else {
        lock.withLock { rejected += 1 }
        close(connection)
        continue
      }
      let stillRunning = lock.withLock { () -> Bool in
        guard listener == descriptor else { return false }
        connections.insert(connection)
        accepted += 1
        return true
      }
      guard stillRunning else {
        close(connection)
        return
      }
      serve(connection, peer: inspected)
    }
  }

  private func serve(_ connection: Int32, peer: AgentConnectionPeer) {
    let (lines, continuation) = AsyncStream<String>.makeStream()
    let reader = Thread {
      var buffer = AgentLineBuffer()
      var chunk = [UInt8](repeating: 0, count: 65_536)
      while true {
        let count = read(connection, &chunk, chunk.count)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { break }
        for line in buffer.append(Data(chunk[0..<count])) { continuation.yield(line) }
        if buffer.overflowed { break }
      }
      continuation.finish()
    }
    reader.name = "mindloom.agent.connection"
    reader.start()
    let writeLock = NSLock()
    let service = service
    Task { [weak self] in
      let session = await service.openSession(peer: peer)
      let write: @Sendable (String?) -> Void = { reply in
        guard let reply else { return }
        writeLock.withLock { _ = AgentSocketIO.writeAll(connection, Data((reply + "\n").utf8)) }
      }
      await withTaskGroup(of: Void.self) { group in
        for await line in lines {
          // The handshake names the client; it is answered before anything
          // after it is read, so a call never runs as "unknown".
          if case .request(_, "initialize", _) = MCPMessage.decode(line) {
            write(await service.handle(line: line, session: session))
          } else {
            group.addTask { write(await service.handle(line: line, session: session)) }
          }
        }
      }
      await service.closeSession(session)
      self?.lock.withLock { _ = self?.connections.remove(connection) }
      close(connection)
    }
  }
}
