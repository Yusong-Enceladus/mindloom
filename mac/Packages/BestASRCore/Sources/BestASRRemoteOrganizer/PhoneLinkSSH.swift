import Darwin
import Foundation
import MindloomLink

/// How the Mac's own ssh reaches one host, as `ssh -G` resolves it from the
/// user's ssh configuration. Only the fields pairing needs.
public struct SSHResolvedHost: Equatable, Sendable {
  /// The real host name (`HostName`, lowercased by ssh).
  public let hostname: String
  public let port: Int
  public let user: String
  /// `ProxyJump` exactly as configured; nil when there is none.
  public let proxyJump: String?
  /// `ProxyCommand` as configured; nil when there is none.
  public let proxyCommand: String?
  public let hostKeyAlias: String?
  /// The known_hosts files ssh checks: the user's, then the global ones.
  public let knownHostsFiles: [String]

  public enum ParseError: Error, Equatable, Sendable {
    case missingField(String)
  }

  public init(
    hostname: String, port: Int, user: String, proxyJump: String? = nil,
    proxyCommand: String? = nil, hostKeyAlias: String? = nil, knownHostsFiles: [String] = []
  ) {
    self.hostname = hostname
    self.port = port
    self.user = user
    self.proxyJump = proxyJump
    self.proxyCommand = proxyCommand
    self.hostKeyAlias = hostKeyAlias
    self.knownHostsFiles = knownHostsFiles
  }

  /// Parses `ssh -G` output: one `keyword value` per line, keywords in
  /// lowercase. `none` means unset.
  public static func parse(sshG output: String) throws -> SSHResolvedHost {
    var fields: [String: String] = [:]
    for line in output.split(whereSeparator: \.isNewline) {
      let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
      guard parts.count == 2 else { continue }
      let key = parts[0].lowercased()
      // The first value wins, as in ssh itself.
      if fields[key] == nil {
        fields[key] = String(parts[1]).trimmingCharacters(in: .whitespaces)
      }
    }
    func value(_ key: String) -> String? {
      guard let value = fields[key], !value.isEmpty, value.lowercased() != "none" else {
        return nil
      }
      return value
    }
    guard let hostname = value("hostname") else { throw ParseError.missingField("hostname") }
    guard let user = value("user") else { throw ParseError.missingField("user") }
    guard let portText = value("port"), let port = Int(portText) else {
      throw ParseError.missingField("port")
    }
    let files = [value("userknownhostsfile"), value("globalknownhostsfile")]
      .compactMap { $0 }
      .flatMap { $0.split(separator: " ").map(String.init) }
    return SSHResolvedHost(
      hostname: hostname, port: port, user: user, proxyJump: value("proxyjump"),
      proxyCommand: value("proxycommand"), hostKeyAlias: value("hostkeyalias"),
      knownHostsFiles: files)
  }

  /// The name ssh looks this host up by in known_hosts: the alias when one
  /// is set, else the host name, bracketed with the port when it is not 22.
  public var knownHostsName: String {
    if let hostKeyAlias { return hostKeyAlias }
    return port == 22 ? hostname : "[\(hostname)]:\(port)"
  }
}

/// A single `ProxyJump` hop: `[user@]host[:port]`, `ssh://[user@]host[:port]`
/// or `[user@][v6]:port`. Several hops (a comma list) are not supported.
public struct SSHJumpSpec: Equatable, Sendable {
  public let host: String
  public let user: String?
  public let port: Int?

  public enum ParseError: Error, Equatable, Sendable {
    case multipleHops
    case invalid
  }

  public init(host: String, user: String? = nil, port: Int? = nil) throws {
    guard PhoneLinkSSHCommand.isSafeHost(host),
      user.map(PairingEndpoint.isValidUser) ?? true,
      port.map({ (1...65_535).contains($0) }) ?? true
    else { throw ParseError.invalid }
    self.host = host
    self.user = user
    self.port = port
  }

  public static func parse(_ text: String) throws -> SSHJumpSpec {
    var rest = Substring(text.trimmingCharacters(in: .whitespaces))
    guard !rest.contains(",") else { throw ParseError.multipleHops }
    if rest.hasPrefix("ssh://") { rest = rest.dropFirst("ssh://".count) }
    var user: String?
    if let at = rest.lastIndex(of: "@") {
      user = String(rest[..<at])
      rest = rest[rest.index(after: at)...]
    }
    var host: String
    var port: Int?
    if rest.hasPrefix("[") {
      guard let close = rest.firstIndex(of: "]") else { throw ParseError.invalid }
      host = String(rest[rest.index(after: rest.startIndex)..<close])
      let after = rest[rest.index(after: close)...]
      if !after.isEmpty {
        guard after.hasPrefix(":"), let value = Int(after.dropFirst()) else {
          throw ParseError.invalid
        }
        port = value
      }
    } else if let colon = rest.lastIndex(of: ":") {
      host = String(rest[..<colon])
      guard let value = Int(rest[rest.index(after: colon)...]) else { throw ParseError.invalid }
      port = value
    } else {
      host = String(rest)
    }
    host = host.lowercased()
    return try SSHJumpSpec(host: host, user: user, port: port)
  }
}

/// Host keys read from the Mac's own known_hosts (`ssh-keygen -F`). Pairing
/// pins them into the phone; nothing is ever learned from the network.
public enum KnownHostKeys {
  /// Every usable key line of `ssh-keygen -F` output. Comment lines and
  /// `@cert-authority` lines are skipped; a key listed `@revoked` is dropped.
  /// Types the phone cannot verify (`ssh-rsa`, `ssh-dss`) are dropped.
  public static func keys(fromKeygenOutput output: String) -> [SSHHostKey] {
    var keys: [SSHHostKey] = []
    var revoked = Set<SSHHostKey>()
    for line in output.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
      var fields = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
      var marker: String?
      if fields.first?.hasPrefix("@") == true { marker = fields.removeFirst() }
      // host-pattern type base64 [comment]
      guard fields.count >= 3, let key = SSHHostKey(openSSH: "\(fields[1]) \(fields[2])") else {
        continue
      }
      switch marker {
      case nil: if !keys.contains(key) { keys.append(key) }
      case "@revoked": revoked.insert(key)
      default: continue
      }
    }
    return keys.filter { !revoked.contains($0) }
  }

  /// The key the phone pins: ed25519 first, then ECDSA P-256, P-384, P-521.
  public static func preferred(_ keys: [SSHHostKey]) -> SSHHostKey? {
    let order = [
      "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
    ]
    return keys.min {
      (order.firstIndex(of: $0.type) ?? 99) < (order.firstIndex(of: $1.type) ?? 99)
    }
  }
}

/// Where the Mac's own ssh reaches a host: an ssh destination (alias or
/// name) plus optional login name and port, all validated so they can never
/// become an ssh option or remote shell syntax.
public struct SSHDestination: Codable, Equatable, Sendable {
  public let host: String
  public let user: String?
  public let port: Int?

  public init(host: String, user: String? = nil, port: Int? = nil) throws {
    guard PhoneLinkSSHCommand.isSafeHost(host), user.map(PairingEndpoint.isValidUser) ?? true,
      port.map({ (1...65_535).contains($0) }) ?? true
    else { throw PhoneLinkSSHCommand.CommandError.unsafeValue }
    self.host = host
    self.user = user
    self.port = port
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      host: try container.decode(String.self, forKey: .host),
      user: try container.decodeIfPresent(String.self, forKey: .user),
      port: try container.decodeIfPresent(Int.self, forKey: .port))
  }

  init(_ jump: SSHJumpSpec) {
    host = jump.host
    user = jump.user
    port = jump.port
  }
}

/// The exact command lines pairing runs. Every word that reaches a remote
/// shell is checked against the same allowed characters as the link
/// configuration (`[A-Za-z0-9._/~-]` for paths, the host rule for hosts, the
/// key-ID rule for key IDs, base64 for the phone's public key), and the
/// organizing device gets the public key on stdin. The phone's private key
/// never reaches any command: it exists only in the pairing code shown to
/// the user.
public enum PhoneLinkSSHCommand {
  public static let sshPath = "/usr/bin/ssh"
  public static let keygenPath = "/usr/bin/ssh-keygen"
  /// Where `zhiji-inbox` lives on the organizing device by default (the
  /// deploy script's layout).
  public static let defaultInboxCommand = "~/hack/organizer/spark/zhiji-inbox"

  public enum CommandError: Error, Equatable, Sendable {
    case unsafeValue
  }

  static let hardening = [
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=yes",
    "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ControlPersist=no",
    "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes",
    "-o", "ConnectTimeout=20",
  ]

  /// The link configuration's host rule: ASCII letters, digits, `._-`, at
  /// most 253 characters, no leading `-` (plus `:` for an IPv6 literal).
  public static func isSafeHost(_ host: String) -> Bool {
    PairingEndpoint.isValidHost(host)
  }

  /// One safe word of a remote shell command (the link configuration's
  /// remote-path rule).
  public static func isSafeCommandPath(_ path: String) -> Bool {
    RemoteOrganizerLinkConfiguration.isSafeRemotePath(path)
  }

  /// `ssh-ed25519 <base64> mindloom-phone:<key id>`, nothing else.
  public static func isSafeAuthorizedKey(_ line: String, keyID: String) -> Bool {
    let fields = line.split(separator: " ", omittingEmptySubsequences: false)
    return fields.count == 3 && fields[0] == "ssh-ed25519"
      && fields[2] == "mindloom-phone:\(keyID)" && PairingPayload.isValidKeyID(keyID)
      && isBase64Word(String(fields[1]))
  }

  static func destinationArguments(_ destination: SSHDestination, configFile: String?)
    -> [String]
  {
    var arguments: [String] = []
    if let configFile { arguments += ["-F", configFile] }
    if let user = destination.user { arguments += ["-l", user] }
    if let port = destination.port { arguments += ["-p", String(port)] }
    return arguments + ["--", destination.host]
  }

  /// `ssh -G`: how the Mac's ssh would reach `destination` (no connection).
  public static func resolveArguments(_ destination: SSHDestination, configFile: String? = nil)
    -> [String]
  {
    ["-G"] + destinationArguments(destination, configFile: configFile)
  }

  /// `ssh-keygen -F <name> -f <file>`: the known_hosts lines for one name.
  public static func knownHostsArguments(name: String, file: String) throws -> [String] {
    let bare = name.hasPrefix("[") ? String(name.dropFirst().prefix { $0 != "]" }) : name
    guard isSafeHost(bare), name.utf8.count <= 300, !file.isEmpty, file.hasPrefix("/"),
      !file.contains("\0")
    else { throw CommandError.unsafeValue }
    return ["-F", name, "-f", file]
  }

  /// One command on a remote host over the Mac's own ssh, no forwarding.
  public static func remoteArguments(
    _ destination: SSHDestination, command: String, configFile: String? = nil
  ) -> [String] {
    var arguments = ["-T"] + hardening
    arguments += destinationArguments(destination, configFile: configFile)
    return arguments + [command]
  }

  /// `zhiji-inbox authorize-phone --key-id <id> --pubkey -` on the
  /// organizing device (PHONE-CONTRACT §4.2), with the public key line on
  /// stdin (`authorizePhoneStdin`). It appends
  /// `command="…/zhiji-inbox gate",restrict <pub> mindloom-phone:<id>`.
  public static func authorizePhoneCommand(inboxCommand: String, keyID: String) throws -> String {
    guard isSafeCommandPath(inboxCommand), PairingPayload.isValidKeyID(keyID) else {
      throw CommandError.unsafeValue
    }
    return "\(inboxCommand) authorize-phone --key-id \(keyID) --pubkey -"
  }

  /// stdin for `authorize-phone`: exactly `ssh-ed25519 <base64>
  /// mindloom-phone:<id>` and a newline.
  public static func authorizePhoneStdin(authorizedKey: String, keyID: String) throws -> Data {
    guard isSafeAuthorizedKey(authorizedKey, keyID: keyID) else { throw CommandError.unsafeValue }
    return Data((authorizedKey + "\n").utf8)
  }

  /// `zhiji-inbox revoke-phone --key-id <id>`: removes that phone's line.
  public static func revokePhoneCommand(inboxCommand: String, keyID: String) throws -> String {
    guard isSafeCommandPath(inboxCommand), PairingPayload.isValidKeyID(keyID) else {
      throw CommandError.unsafeValue
    }
    return "\(inboxCommand) revoke-phone --key-id \(keyID)"
  }

  /// The relay helper (`PhoneRelayScript`) goes on stdin to `sh -s`, so
  /// nothing is installed on the relay: `add <key id> <spark host> <spark
  /// port> ssh-ed25519 <base64>` writes `restrict,port-forwarding,
  /// permitopen="<host>:<port>",permitlisten="127.0.0.1:1",command="false"
  /// <pub> mindloom-phone:<id>`. The public key travels as two argument
  /// words because stdin is the script itself; it is public and checked to be
  /// base64 only. `<spark host>` is the pairing payload's `spark.host`
  /// string, which sshd compares to the phone's tunnel target.
  public static func relayAuthorizeCommand(
    keyID: String, sparkHost: String, sparkPort: Int, publicKeyBase64: String
  ) throws -> String {
    guard PairingPayload.isValidKeyID(keyID), isSafeHost(sparkHost),
      (1...65_535).contains(sparkPort), isBase64Word(publicKeyBase64)
    else { throw CommandError.unsafeValue }
    return "sh -s -- add \(keyID) \(sparkHost) \(sparkPort) ssh-ed25519 \(publicKeyBase64)"
  }

  /// `remove <key id>`: deletes every line marked `mindloom-phone:<id>`.
  public static func relayRevokeCommand(keyID: String) throws -> String {
    guard PairingPayload.isValidKeyID(keyID) else { throw CommandError.unsafeValue }
    return "sh -s -- remove \(keyID)"
  }

  static func isBase64Word(_ text: String) -> Bool {
    !text.isEmpty && text.utf8.count <= 128
      && text.unicodeScalars.allSatisfy {
        ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "+/=".unicodeScalars.contains($0)
      }
  }
}

/// What one command printed and how it ended.
public struct PhoneLinkCommandResult: Equatable, Sendable {
  public let status: Int32
  public let stdout: Data
  public let stderr: Data

  public init(status: Int32, stdout: Data = Data(), stderr: Data = Data()) {
    self.status = status
    self.stdout = stdout
    self.stderr = stderr
  }

  public var output: String { String(decoding: stdout, as: UTF8.self) }
}

public enum PhoneLinkCommandError: Error, Equatable, Sendable {
  case launchFailed
  case timedOut
  /// The command ran and exited with this status.
  case exited(Int32)
}

/// Runs one local program (ssh, ssh-keygen); injectable for tests.
public protocol PhoneLinkCommandRunning: Sendable {
  func run(_ executable: String, _ arguments: [String], stdin: Data?, timeout: TimeInterval)
    async throws -> PhoneLinkCommandResult
}

/// The real runner: a child process with its own pipes. Output is capped
/// (64 KiB each) and never logged; stdin is written without SIGPIPE; the
/// child is ended (SIGTERM, then SIGKILL) at the timeout.
public struct ProcessPhoneLinkCommandRunner: PhoneLinkCommandRunning {
  public static let outputLimit = 64 * 1024

  public init() {}

  public func run(
    _ executable: String, _ arguments: [String], stdin: Data?, timeout: TimeInterval
  ) async throws -> PhoneLinkCommandResult {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(
          with: Result {
            try Self.runBlocking(executable, arguments, stdin: stdin, timeout: timeout)
          })
      }
    }
  }

  static func runBlocking(
    _ executable: String, _ arguments: [String], stdin: Data?, timeout: TimeInterval
  ) throws -> PhoneLinkCommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    let errors = Pipe()
    let input = stdin == nil ? nil : Pipe()
    process.standardInput = input ?? FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errors
    do { try process.run() } catch { throw PhoneLinkCommandError.launchFailed }
    let deadline = Date().addingTimeInterval(timeout)

    if let input, let stdin {
      let handle = input.fileHandleForWriting
      _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
      DispatchQueue.global(qos: .userInitiated).async {
        stdin.withUnsafeBytes { buffer in
          var offset = 0
          while offset < buffer.count {
            let written = Darwin.write(
              handle.fileDescriptor, buffer.baseAddress! + offset, buffer.count - offset)
            if written <= 0 {
              if written < 0, errno == EINTR { continue }
              break
            }
            offset += written
          }
        }
        try? handle.close()
      }
    }

    var descriptors = [
      pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0),
      pollfd(fd: errors.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0),
    ]
    var collected = [Data(), Data()]
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    var timedOut = false
    var exitedAt: Date?
    while descriptors.contains(where: { $0.fd >= 0 }) {
      if !process.isRunning, exitedAt == nil { exitedAt = Date() }
      // A grandchild (a ProxyJump ssh) may keep a pipe open after the
      // child is gone; stop reading shortly after the child exits.
      if let exitedAt, Date().timeIntervalSince(exitedAt) > 2 { break }
      if process.isRunning, Date() >= deadline {
        timedOut = true
        RemoteOrganizerProcessInspector.terminate(pid: process.processIdentifier) {
          process.isRunning
        }
      }
      let ready = poll(&descriptors, nfds_t(descriptors.count), 50)
      guard ready > 0 else { continue }
      for index in descriptors.indices where descriptors[index].fd >= 0 {
        guard descriptors[index].revents != 0 else { continue }
        let count = read(descriptors[index].fd, &buffer, buffer.count)
        if count > 0 {
          let room = Self.outputLimit - collected[index].count
          if room > 0 { collected[index].append(contentsOf: buffer.prefix(min(room, count))) }
        } else if count == 0 || errno != EINTR {
          descriptors[index].fd = -1
        }
      }
    }
    if process.isRunning {
      RemoteOrganizerProcessInspector.terminate(pid: process.processIdentifier) {
        process.isRunning
      }
    }
    process.waitUntilExit()
    try? output.fileHandleForReading.close()
    try? errors.fileHandleForReading.close()
    if timedOut { throw PhoneLinkCommandError.timedOut }
    return PhoneLinkCommandResult(
      status: process.terminationStatus, stdout: collected[0], stderr: collected[1])
  }
}
