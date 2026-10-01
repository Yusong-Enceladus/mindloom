import Darwin
import Foundation

/// Where the App listens for the helper, and the POSIX pieces both sides
/// use: a Unix domain socket in the data root's private `agent` folder
/// (0700), the socket itself 0600, and a peer check on every connection
/// (AGENT-CONTRACT §1).
public enum AgentSocketLocation {
  public static let directoryName = "agent"
  public static let socketName = "mindloom.sock"
  /// Dev builds and tests point the helper at another data root.
  public static let dataRootEnvironmentKey = "MINDLOOM_DATA_ROOT"
  /// `sun_path` holds 104 bytes including the terminator.
  public static let maximumPathBytes = 103

  public static func directory(dataRoot: URL) -> URL {
    dataRoot.appendingPathComponent(directoryName, isDirectory: true)
  }

  public static func socketURL(dataRoot: URL) -> URL {
    directory(dataRoot: dataRoot).appendingPathComponent(socketName, isDirectory: false)
  }

  /// The owner's library, from the account database (not `HOME`), as the
  /// App finds it.
  public static func defaultDataRoot() -> URL? {
    guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return nil }
    let home = String(cString: directory)
    guard home.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent("Library/Application Support/bestASR", isDirectory: true)
  }

  /// `MINDLOOM_DATA_ROOT` when set to an absolute path, else the default.
  public static func dataRoot(environment: [String: String]) -> URL? {
    if let value = environment[dataRootEnvironmentKey]?.trimmingCharacters(
      in: .whitespacesAndNewlines), !value.isEmpty
    {
      guard value.hasPrefix("/") else { return nil }
      return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
    }
    return defaultDataRoot()
  }
}

public enum AgentSocketError: Error, Equatable, Sendable {
  case pathTooLong
  case socketFailed(Int32)
  case connectFailed(Int32)
  case bindFailed(Int32)
  case listenFailed(Int32)
  case notOwnedByUser
  case unsafePermissions
  case peerRejected
}

/// Plain POSIX socket calls, shared by the helper (client) and the App
/// (server).
public enum AgentSocketIO {
  static func address(for path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count <= AgentSocketLocation.maximumPathBytes else {
      throw AgentSocketError.pathTooLong
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.initializeMemory(as: UInt8.self, repeating: 0)
      for (index, byte) in bytes.enumerated() { buffer[index] = byte }
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
  }

  /// A connected stream socket, or an error when nothing listens there.
  public static func connect(path: String) throws -> Int32 {
    var address = try address(for: path)
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw AgentSocketError.socketFailed(errno) }
    var on: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      let error = errno
      close(descriptor)
      throw AgentSocketError.connectFailed(error)
    }
    return descriptor
  }

  /// Binds and listens at `path` (removing a stale socket file first) with
  /// the file made 0600 before anyone can connect: the umask is tightened
  /// around `bind`.
  public static func listen(path: String, backlog: Int32 = 16) throws -> Int32 {
    var address = try address(for: path)
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw AgentSocketError.socketFailed(errno) }
    var entry = stat()
    if lstat(path, &entry) == 0 {
      guard entry.st_mode & S_IFMT == S_IFSOCK else {
        close(descriptor)
        throw AgentSocketError.unsafePermissions
      }
      unlink(path)
    }
    let previous = umask(0o177)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    umask(previous)
    guard bound == 0 else {
      let error = errno
      close(descriptor)
      throw AgentSocketError.bindFailed(error)
    }
    chmod(path, S_IRUSR | S_IWUSR)
    guard Darwin.listen(descriptor, backlog) == 0 else {
      let error = errno
      close(descriptor)
      unlink(path)
      throw AgentSocketError.listenFailed(error)
    }
    return descriptor
  }

  /// Writes all of `data`; false when the other side is gone.
  @discardableResult
  public static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { buffer -> Bool in
      guard var pointer = buffer.baseAddress else { return true }
      var remaining = buffer.count
      while remaining > 0 {
        let written = write(descriptor, pointer, remaining)
        if written < 0 {
          if errno == EINTR { continue }
          return false
        }
        remaining -= written
        pointer = pointer.advanced(by: written)
      }
      return true
    }
  }
}

/// Who is on the other end of a Unix socket, from the kernel (not from
/// anything the peer says): its user ID (`LOCAL_PEERCRED`) and process ID
/// (`LOCAL_PEERPID`), then libproc for the process's owner, parent and
/// executable, the same inspection the organizing link uses for its tunnel.
public struct AgentPeer: Equatable, Sendable {
  public let uid: uid_t
  public let pid: pid_t

  public init(uid: uid_t, pid: pid_t) {
    self.uid = uid
    self.pid = pid
  }

  public static func of(_ descriptor: Int32) -> AgentPeer? {
    var credentials = xucred()
    var length = socklen_t(MemoryLayout<xucred>.size)
    guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &length) == 0,
      credentials.cr_version == XUCRED_VERSION
    else { return nil }
    var pid: pid_t = 0
    var pidLength = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidLength) == 0, pid > 0
    else { return nil }
    return AgentPeer(uid: credentials.cr_uid, pid: pid)
  }
}

public enum AgentProcessInspector {
  /// The real user ID owning `pid`, from `proc_pidinfo(PROC_PIDTBSDINFO)`.
  public static func ownerUID(_ pid: pid_t) -> uid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
      return nil
    }
    return info.pbi_uid
  }

  public static func parentPID(_ pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
      return nil
    }
    return pid_t(info.pbi_ppid)
  }

  public static func executablePath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  /// The owner check: the peer's kernel credentials name this user, and
  /// libproc agrees the process is this user's.
  public static func peerIsOwner(_ peer: AgentPeer, uid: uid_t = getuid()) -> Bool {
    guard peer.uid == uid else { return false }
    guard let owner = ownerUID(peer.pid) else { return false }
    return owner == uid
  }
}

/// Splits a byte stream into lines (LF, with an optional CR before it).
public struct AgentLineBuffer: Sendable {
  public static let maximumLineBytes = 8 * 1_024 * 1_024
  private var pending = Data()
  public private(set) var overflowed = false

  public init() {}

  /// The complete lines in `data` (and what was left before it); an
  /// over-long line is dropped and `overflowed` set.
  public mutating func append(_ data: Data) -> [String] {
    pending.append(data)
    var lines: [String] = []
    while let newline = pending.firstIndex(of: 0x0A) {
      var line = pending[pending.startIndex..<newline]
      if line.last == 0x0D { line = line.dropLast() }
      pending.removeSubrange(pending.startIndex...newline)
      if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
    }
    if pending.count > Self.maximumLineBytes {
      pending.removeAll()
      overflowed = true
    }
    return lines
  }
}

/// The helper's side: connect only to a socket this user owns, in this
/// user's private folder, served by a process of this user.
public enum AgentSocketClient {
  /// A connected socket, or nil when nothing safe listens at `path`
  /// (`log` says why, without content).
  public static func connectVerified(
    _ path: String, uid: uid_t = getuid(), log: (String) -> Void
  ) -> Int32? {
    let directory = (path as NSString).deletingLastPathComponent
    var folder = stat()
    guard lstat(directory, &folder) == 0 else { return nil }
    guard folder.st_mode & S_IFMT == S_IFDIR, folder.st_uid == uid, folder.st_mode & 0o077 == 0
    else {
      log("refusing the App socket: its folder is not this user's private folder")
      return nil
    }
    var entry = stat()
    guard lstat(path, &entry) == 0 else { return nil }
    guard entry.st_mode & S_IFMT == S_IFSOCK, entry.st_uid == uid, entry.st_mode & 0o077 == 0
    else {
      log("refusing the App socket: not a socket owned by this user with mode 0600")
      return nil
    }
    guard let descriptor = try? AgentSocketIO.connect(path: path) else { return nil }
    guard let peer = AgentPeer.of(descriptor), AgentProcessInspector.peerIsOwner(peer, uid: uid)
    else {
      log("refusing the App socket: the listening process is not this user's")
      close(descriptor)
      return nil
    }
    return descriptor
  }
}
