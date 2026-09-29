import Darwin
import Foundation

/// Where the organizer lives on the user's own Spark. Values are validated so
/// they can never inject ssh options or remote shell syntax.
///
/// The forward targets the organizer's Unix socket inside its 0700 data
/// directory, not a TCP port: any local process on the Spark could bind a
/// well-known loopback port while the organizer is down and receive the link
/// token and transcripts, but only the owner can create that socket.
///
/// There is deliberately no built-in host: the user names their own Spark
/// (an ssh host alias or name), and an empty or unset host is rejected, so an
/// unconfigured Mac never opens a link to anyone's machine.
public struct RemoteOrganizerLinkConfiguration: Equatable, Sendable {
  public static let defaultRemoteSocketPath = "~/hack/organizer-data/organizer.sock"
  public static let defaultRemoteTokenPath = "~/hack/organizer-data/link_token"
  /// Unix socket paths are limited to about 104 bytes on both ends.
  public static let maximumSocketPathBytes = 100

  public enum ConfigurationError: Error, Equatable, Sendable {
    case invalidHost
    case invalidSocketPath
    case invalidTokenPath
  }

  public let host: String
  public let remoteSocketPath: String
  public let remoteTokenPath: String

  public init(
    host: String,
    remoteSocketPath: String = defaultRemoteSocketPath,
    remoteTokenPath: String = defaultRemoteTokenPath
  ) throws {
    guard !host.isEmpty, host.count <= 253, host.first != "-",
      host.unicodeScalars.allSatisfy({
        CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0)
      })
    else { throw ConfigurationError.invalidHost }
    guard Self.isSafeRemotePath(remoteSocketPath),
      remoteSocketPath.utf8.count <= Self.maximumSocketPathBytes,
      remoteSocketPath.hasPrefix("/") || remoteSocketPath.hasPrefix("~/"),
      !remoteSocketPath.hasSuffix("/")
    else { throw ConfigurationError.invalidSocketPath }
    guard Self.isSafeRemotePath(remoteTokenPath) else {
      throw ConfigurationError.invalidTokenPath
    }
    self.host = host
    self.remoteSocketPath = remoteSocketPath
    self.remoteTokenPath = remoteTokenPath
  }

  /// Only `[A-Za-z0-9._/~-]`, no `..`, no leading `-`: safe as one word of a
  /// remote shell command and never an ssh option.
  static func isSafeRemotePath(_ path: String) -> Bool {
    !path.isEmpty && path.count <= 512 && path.first != "-" && !path.contains("..")
      && path.unicodeScalars.allSatisfy({
        CharacterSet.alphanumerics.contains($0) && $0.isASCII
          || "._/~-".unicodeScalars.contains($0)
      })
  }

  /// The socket's directory and file name, for resolving `~` on the Spark.
  var remoteSocketDirectory: String {
    String(remoteSocketPath[..<remoteSocketPath.lastIndex(of: "/")!])
  }

  var remoteSocketName: String {
    String(remoteSocketPath[remoteSocketPath.index(after: remoteSocketPath.lastIndex(of: "/")!)...])
  }
}

/// The exact ssh command lines this app runs. The stale-tunnel cleaner kills a
/// leftover process only when its live command line equals one of these.
public enum RemoteOrganizerSSHCommand {
  public static let executablePath = "/usr/bin/ssh"

  private static let hardening = [
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=yes",
    "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ControlPersist=no",
    "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
  ]

  /// Forwards a random loopback port on the Mac to the organizer's Unix
  /// socket (an absolute path) on the Spark.
  public static func forwardArguments(
    host: String, localPort: Int, remoteSocketPath: String
  ) -> [String] {
    [
      "-N", "-T",
      "-o", "BatchMode=yes",
      "-o", "ExitOnForwardFailure=yes",
      "-o", "StrictHostKeyChecking=yes",
      "-o", "ConnectTimeout=30",
      "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ControlPersist=no",
      "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
      "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
      "-L", "127.0.0.1:\(localPort):\(remoteSocketPath)",
      "--", host,
    ]
  }

  /// A separate authenticated SSH command that prints the link token. It
  /// never goes through the tunnel and the token is read from its stdout only.
  public static func tokenArguments(host: String, remoteTokenPath: String) -> [String] {
    ["-T"] + hardening + [
      "-o", "ConnectTimeout=20", "-o", "ClearAllForwardings=yes",
      "--", host, "cat \(remoteTokenPath)",
    ]
  }

  /// A separate SSH command that prints the physical absolute path of the
  /// socket's directory (resolving `~`), because a forward to a Unix socket
  /// needs an absolute path.
  public static func socketDirectoryArguments(host: String, remoteDirectory: String) -> [String] {
    ["-T"] + hardening + [
      "-o", "ConnectTimeout=20", "-o", "ClearAllForwardings=yes",
      "--", host, "cd \(remoteDirectory) && pwd -P",
    ]
  }

  public static func isValidLinkToken(_ token: String) -> Bool {
    token.utf8.count == 64
      && token.unicodeScalars.allSatisfy { "0123456789abcdef".unicodeScalars.contains($0) }
  }

  /// The resolved socket path must be absolute, short enough, and safe.
  public static func isValidResolvedSocketPath(_ path: String) -> Bool {
    path.hasPrefix("/") && !path.hasSuffix("/") && !path.contains("~")
      && path.utf8.count <= RemoteOrganizerLinkConfiguration.maximumSocketPathBytes
      && RemoteOrganizerLinkConfiguration.isSafeRemotePath(path)
  }
}

/// One running forward. `terminateAndWait()` returns only after the process is
/// gone (SIGTERM, bounded wait, SIGKILL fallback).
@MainActor
public protocol RemoteOrganizerTunnelProcess: AnyObject {
  var processIdentifier: Int32 { get }
  var localPort: Int { get }
  var isRunning: Bool { get }
  func terminateAndWait()
}

/// Everything the runtime needs from the operating system, injectable so the
/// runtime can be tested without ssh or a network.
@MainActor
public protocol RemoteOrganizerTunnelLauncher: AnyObject {
  func freeLoopbackPort() throws -> Int
  func launchForward(localPort: Int) async throws -> any RemoteOrganizerTunnelProcess
  /// True only when `pid` itself holds a TCP listener on 127.0.0.1:`port`.
  func listenerIsOwned(by pid: Int32, port: Int) -> Bool
  func fetchLinkToken() async throws -> String
  func cleanUpStaleTunnels()
}

public enum RemoteOrganizerTunnelError: Error, Equatable, Sendable {
  case noFreePort
  case launchFailed
  case tokenUnavailable
  case tokenInvalid
  case socketPathUnavailable
}

/// Tunnels launched by this process, so quitting can end them synchronously.
@MainActor
public enum RemoteOrganizerProcessRegistry {
  private static var active: [ObjectIdentifier: any RemoteOrganizerTunnelProcess] = [:]

  static func register(_ process: any RemoteOrganizerTunnelProcess) {
    active[ObjectIdentifier(process)] = process
  }

  static func unregister(_ process: any RemoteOrganizerTunnelProcess) {
    active[ObjectIdentifier(process)] = nil
  }

  public static func terminateAll() {
    let processes = Array(active.values)
    active = [:]
    for process in processes { process.terminateAndWait() }
  }

  public static var activeCount: Int { active.count }
}

// MARK: - Operating-system inspection

public enum RemoteOrganizerProcessInspector {
  public static func isAlive(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    return kill(pid, 0) == 0 || errno == EPERM
  }

  public static func executablePath(_ pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  /// The live executable path and argv of `pid` (KERN_PROCARGS2), or nil when
  /// the process is gone or not readable by this user.
  public static func commandLine(_ pid: Int32) -> (executable: String, arguments: [String])? {
    guard pid > 0 else { return nil }
    var argumentMaximum: Int32 = 0
    var size = MemoryLayout<Int32>.size
    var maximumMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
    guard sysctl(&maximumMIB, 2, &argumentMaximum, &size, nil, 0) == 0,
      argumentMaximum > 0
    else { return nil }
    var buffer = [UInt8](repeating: 0, count: Int(argumentMaximum))
    size = buffer.count
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
      size > MemoryLayout<Int32>.size
    else { return nil }
    let argumentCount = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    var index = MemoryLayout<Int32>.size
    let executableStart = index
    while index < size, buffer[index] != 0 { index += 1 }
    let executable = String(decoding: buffer[executableStart..<index], as: UTF8.self)
    while index < size, buffer[index] == 0 { index += 1 }
    var arguments: [String] = []
    while arguments.count < Int(argumentCount), index < size {
      let start = index
      while index < size, buffer[index] != 0 { index += 1 }
      arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
      index += 1
    }
    guard arguments.count == Int(argumentCount) else { return nil }
    return (executable, arguments)
  }

  /// True only when `pid` holds a listening IPv4 TCP socket bound to
  /// 127.0.0.1:`port`. Uses libproc, so no helper process is spawned.
  public static func holdsLoopbackListener(pid: Int32, port: Int) -> Bool {
    guard pid > 0, (1...65_535).contains(port) else { return false }
    let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard needed > 0 else { return false }
    let stride = MemoryLayout<proc_fdinfo>.stride
    var descriptors = [proc_fdinfo](
      repeating: proc_fdinfo(), count: Int(needed) / stride + 32
    )
    let used = descriptors.withUnsafeMutableBytes {
      proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
    }
    guard used > 0 else { return false }
    let loopback = in_addr_t(UInt32(0x7F00_0001).bigEndian)
    for descriptor in descriptors.prefix(Int(used) / stride)
    where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
      var info = socket_fdinfo()
      let size = Int32(MemoryLayout<socket_fdinfo>.size)
      guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
        info.psi.soi_kind == Int32(SOCKINFO_TCP)
      else { continue }
      let tcp = info.psi.soi_proto.pri_tcp
      guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
      let internet = tcp.tcpsi_ini
      let localPort = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: internet.insi_lport)))
      guard localPort == port, internet.insi_vflag & UInt8(INI_IPV4) != 0 else { continue }
      if internet.insi_laddr.ina_46.i46a_addr4.s_addr == loopback { return true }
    }
    return false
  }

  /// A currently free loopback port chosen by the kernel (randomized).
  public static func freeLoopbackPort() throws -> Int {
    let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard descriptor >= 0 else { throw RemoteOrganizerTunnelError.noFreePort }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: in_addr_t(UInt32(0x7F00_0001).bigEndian))
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else { throw RemoteOrganizerTunnelError.noFreePort }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &length)
      }
    }
    guard named == 0 else { throw RemoteOrganizerTunnelError.noFreePort }
    let port = Int(UInt16(bigEndian: address.sin_port))
    guard port > 0 else { throw RemoteOrganizerTunnelError.noFreePort }
    return port
  }

  /// SIGTERM, wait up to `grace`, then SIGKILL and wait again.
  public static func terminate(
    pid: Int32, grace: TimeInterval = 1.5, isRunning: () -> Bool
  ) {
    guard pid > 0, isRunning() else { return }
    kill(pid, SIGTERM)
    if waitUntilGone(timeout: grace, isRunning: isRunning) { return }
    kill(pid, SIGKILL)
    _ = waitUntilGone(timeout: 2, isRunning: isRunning)
  }

  private static func waitUntilGone(
    timeout: TimeInterval, isRunning: () -> Bool
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while isRunning() {
      if Date() >= deadline { return false }
      usleep(10_000)
    }
    return true
  }
}

// MARK: - Durable record of launched tunnels

/// Written next to the app's support data for every launched ssh, so a later
/// launch (after a crash or force quit) can end an orphaned forward.
public struct RemoteOrganizerTunnelRecord: Codable, Equatable, Sendable {
  public let sshPID: Int32
  public let appPID: Int32
  public let appExecutable: String
  public let host: String
  public let localPort: Int
  /// The `-L` target: the organizer's absolute socket path on the Spark.
  public let remoteTarget: String

  public init(
    sshPID: Int32, appPID: Int32, appExecutable: String, host: String,
    localPort: Int, remoteTarget: String
  ) {
    self.sshPID = sshPID
    self.appPID = appPID
    self.appExecutable = appExecutable
    self.host = host
    self.localPort = localPort
    self.remoteTarget = remoteTarget
  }

  enum CodingKeys: String, CodingKey {
    case sshPID = "ssh_pid"
    case appPID = "app_pid"
    case appExecutable = "app_executable"
    case host
    case localPort = "local_port"
    case remoteTarget = "remote_target"
    case legacyRemotePort = "remote_port"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sshPID = try container.decode(Int32.self, forKey: .sshPID)
    appPID = try container.decode(Int32.self, forKey: .appPID)
    appExecutable = try container.decode(String.self, forKey: .appExecutable)
    host = try container.decode(String.self, forKey: .host)
    localPort = try container.decode(Int.self, forKey: .localPort)
    if let target = try container.decodeIfPresent(String.self, forKey: .remoteTarget) {
      remoteTarget = target
    } else {
      // Records written by builds that forwarded to a TCP port.
      let port = try container.decode(Int.self, forKey: .legacyRemotePort)
      remoteTarget = "127.0.0.1:\(port)"
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sshPID, forKey: .sshPID)
    try container.encode(appPID, forKey: .appPID)
    try container.encode(appExecutable, forKey: .appExecutable)
    try container.encode(host, forKey: .host)
    try container.encode(localPort, forKey: .localPort)
    try container.encode(remoteTarget, forKey: .remoteTarget)
  }

  /// The exact command line this app would have used for this record.
  public var expectedCommandLine: (executable: String, arguments: [String]) {
    (
      RemoteOrganizerSSHCommand.executablePath,
      RemoteOrganizerSSHCommand.forwardArguments(
        host: host, localPort: localPort, remoteSocketPath: remoteTarget
      )
    )
  }
}

public struct RemoteOrganizerTunnelRecordStore: Sendable {
  public let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  func url(for sshPID: Int32) -> URL {
    directory.appendingPathComponent("ssh-\(sshPID).json")
  }

  public func write(_ record: RemoteOrganizerTunnelRecord) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let data = try JSONEncoder().encode(record)
    let target = url(for: record.sshPID)
    try data.write(to: target, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
  }

  public func remove(sshPID: Int32) {
    try? FileManager.default.removeItem(at: url(for: sshPID))
  }

  public func records() -> [(url: URL, record: RemoteOrganizerTunnelRecord?)] {
    guard
      let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
    else { return [] }
    return names.filter { $0.hasPrefix("ssh-") && $0.hasSuffix(".json") }.sorted().map {
      let url = directory.appendingPathComponent($0)
      let record = (try? Data(contentsOf: url)).flatMap {
        try? JSONDecoder().decode(RemoteOrganizerTunnelRecord.self, from: $0)
      }
      return (url, record)
    }
  }

  /// Ends every recorded forward that no other running instance of this app
  /// owns, but only when the live process is alive and its command line is
  /// exactly the recorded ssh signature. Returns the PIDs it terminated.
  @discardableResult
  public func cleanUpStale(
    currentAppPID: Int32 = getpid(),
    expectedCommandLine: (RemoteOrganizerTunnelRecord) -> (
      executable: String, arguments: [String]
    ) = { $0.expectedCommandLine }
  ) -> [Int32] {
    var terminated: [Int32] = []
    for (url, record) in records() {
      guard let record else {
        try? FileManager.default.removeItem(at: url)
        continue
      }
      if record.appPID != currentAppPID,
        RemoteOrganizerProcessInspector.isAlive(record.appPID),
        RemoteOrganizerProcessInspector.executablePath(record.appPID) == record.appExecutable
      {
        continue  // Another running instance still owns this tunnel.
      }
      if RemoteOrganizerProcessInspector.isAlive(record.sshPID),
        let live = RemoteOrganizerProcessInspector.commandLine(record.sshPID)
      {
        let expected = expectedCommandLine(record)
        if live.executable == expected.executable,
          Array(live.arguments.dropFirst()) == expected.arguments
        {
          RemoteOrganizerProcessInspector.terminate(pid: record.sshPID) {
            RemoteOrganizerProcessInspector.isAlive(record.sshPID)
          }
          terminated.append(record.sshPID)
        }
      }
      try? FileManager.default.removeItem(at: url)
    }
    return terminated
  }
}

// MARK: - Real ssh launcher

@MainActor
final class SSHForwardProcess: RemoteOrganizerTunnelProcess {
  private let process: Process
  private let records: RemoteOrganizerTunnelRecordStore
  let localPort: Int

  init(process: Process, localPort: Int, records: RemoteOrganizerTunnelRecordStore) {
    self.process = process
    self.localPort = localPort
    self.records = records
  }

  var processIdentifier: Int32 { process.processIdentifier }
  var isRunning: Bool { process.isRunning }

  func terminateAndWait() {
    let pid = process.processIdentifier
    let process = self.process
    RemoteOrganizerProcessInspector.terminate(pid: pid) { process.isRunning }
    RemoteOrganizerProcessRegistry.unregister(self)
    records.remove(sshPID: pid)
  }
}

@MainActor
public final class SSHRemoteOrganizerTunnelLauncher: RemoteOrganizerTunnelLauncher {
  private let configuration: RemoteOrganizerLinkConfiguration
  private let records: RemoteOrganizerTunnelRecordStore
  /// The socket's absolute path on the Spark, resolved once per launcher.
  private var resolvedSocketPath: String?

  /// `stateDirectory` holds the tunnel records; it must be outside any
  /// library that could be sent.
  public init(configuration: RemoteOrganizerLinkConfiguration, stateDirectory: URL) {
    self.configuration = configuration
    records = RemoteOrganizerTunnelRecordStore(directory: stateDirectory)
  }

  public func freeLoopbackPort() throws -> Int {
    try RemoteOrganizerProcessInspector.freeLoopbackPort()
  }

  public func launchForward(localPort: Int) async throws -> any RemoteOrganizerTunnelProcess {
    let socketPath = try await remoteSocketPath()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: RemoteOrganizerSSHCommand.executablePath)
    process.arguments = RemoteOrganizerSSHCommand.forwardArguments(
      host: configuration.host, localPort: localPort, remoteSocketPath: socketPath
    )
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { throw RemoteOrganizerTunnelError.launchFailed }
    let forward = SSHForwardProcess(process: process, localPort: localPort, records: records)
    RemoteOrganizerProcessRegistry.register(forward)
    let record = RemoteOrganizerTunnelRecord(
      sshPID: process.processIdentifier, appPID: getpid(),
      appExecutable: RemoteOrganizerProcessInspector.executablePath(getpid()) ?? "",
      host: configuration.host, localPort: localPort, remoteTarget: socketPath
    )
    do { try records.write(record) } catch {
      // Without a durable record a crash could orphan this forward.
      forward.terminateAndWait()
      throw RemoteOrganizerTunnelError.launchFailed
    }
    return forward
  }

  public func listenerIsOwned(by pid: Int32, port: Int) -> Bool {
    RemoteOrganizerProcessInspector.holdsLoopbackListener(pid: pid, port: port)
  }

  public func fetchLinkToken() async throws -> String {
    let output = try await runSSH(
      RemoteOrganizerSSHCommand.tokenArguments(
        host: configuration.host, remoteTokenPath: configuration.remoteTokenPath
      ),
      failure: .tokenUnavailable
    )
    guard RemoteOrganizerSSHCommand.isValidLinkToken(output) else {
      throw RemoteOrganizerTunnelError.tokenInvalid
    }
    return output
  }

  public func cleanUpStaleTunnels() {
    records.cleanUpStale()
  }

  private func remoteSocketPath() async throws -> String {
    if let resolvedSocketPath { return resolvedSocketPath }
    let path: String
    if configuration.remoteSocketPath.hasPrefix("/") {
      path = configuration.remoteSocketPath
    } else {
      let directory = try await runSSH(
        RemoteOrganizerSSHCommand.socketDirectoryArguments(
          host: configuration.host, remoteDirectory: configuration.remoteSocketDirectory
        ),
        failure: .socketPathUnavailable
      )
      path = directory + "/" + configuration.remoteSocketName
    }
    guard RemoteOrganizerSSHCommand.isValidResolvedSocketPath(path) else {
      throw RemoteOrganizerTunnelError.socketPathUnavailable
    }
    resolvedSocketPath = path
    return path
  }

  /// Runs one short ssh command and returns its trimmed stdout (at most 4 KB).
  /// Its output is never logged.
  private func runSSH(
    _ arguments: [String], failure: RemoteOrganizerTunnelError
  ) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: RemoteOrganizerSSHCommand.executablePath)
    process.arguments = arguments
    let output = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { throw failure }
    defer {
      if process.isRunning {
        RemoteOrganizerProcessInspector.terminate(pid: process.processIdentifier) {
          process.isRunning
        }
      }
    }
    let deadline = Date().addingTimeInterval(30)
    while process.isRunning {
      guard Date() < deadline else { throw failure }
      try await Task.sleep(for: .milliseconds(50))
    }
    guard process.terminationStatus == 0 else { throw failure }
    let data = (try? output.fileHandleForReading.read(upToCount: 4096)) ?? nil
    return String(decoding: data ?? Data(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
