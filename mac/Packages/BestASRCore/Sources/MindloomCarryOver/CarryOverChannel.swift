import CryptoKit
import Darwin
import Foundation
import MindloomAgentProtocol
import MindloomIdentity
import Security

/// The private local channel of the keychain carry-over: a Unix socket in a
/// 0700 folder of the user's temporary directory, named after the App that
/// receives (`<DARWIN_USER_TEMP_DIR>/mindloom-carry-over-<hash of its bundle
/// id>/handover.sock`, the socket 0600). The helper listens; Mindloom connects on its first
/// launch. Each side reads the other's code signature from the kernel (the
/// peer's audit token, `LOCAL_PEERTOKEN`) and checks it against a
/// requirement: the expected identifier, an Apple-issued certificate and its
/// own team. Nothing the peer says about itself is trusted.
public enum CarryOverChannel {
  public static let socketName = "handover.sock"
  /// How long one side waits for the other's next frame.
  public static let ioTimeoutSeconds = 10

  /// `<DARWIN_USER_TEMP_DIR>` (the same for the App and the switch script).
  public static func userTemporaryDirectory() -> URL? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return nil }
    let path = String(
      decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    guard path.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  /// `mindloom-carry-over-<the first 12 hex digits of SHA-256(receiver)>`: one
  /// folder per receiving App, and a socket path of the same length for any
  /// bundle id (a Unix socket path has at most 103 bytes; the folder named
  /// after a long verification identity did not fit).
  public static func directory(receiver: String, temporaryDirectory: URL) -> URL {
    let digest = SHA256.hash(data: Data(receiver.utf8)).prefix(6)
      .map { String(format: "%02x", $0) }.joined()
    return temporaryDirectory.appendingPathComponent(
      "mindloom-carry-over-" + digest, isDirectory: true)
  }

  public static func socketURL(receiver: String, temporaryDirectory: URL) -> URL {
    directory(receiver: receiver, temporaryDirectory: temporaryDirectory)
      .appendingPathComponent(socketName, isDirectory: false)
  }

  // MARK: Signatures

  /// `identifier "<id>" and anchor apple generic and certificate leaf[subject.OU] = "<team>"`.
  public static func requirement(identifier: String, team: String) -> String? {
    guard isPlain(identifier), isPlain(team) else { return nil }
    return
      "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
  }

  /// This process's signing identifier and team; nil when ad hoc or unsigned.
  public static func ownSignature() -> (identifier: String, team: String)? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
      let dictionary = info as? [String: Any],
      let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String,
      let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty
    else { return nil }
    return (identifier, team)
  }

  /// A check that the connected peer is the same user and satisfies
  /// `requirement`, by the peer's audit token.
  public static func signatureCheck(requirement text: String) -> @Sendable (Int32) -> Bool {
    { descriptor in
      guard let peer = AgentPeer.of(descriptor), peer.uid == getuid(),
        let token = peer.auditToken
      else { return false }
      var requirement: SecRequirement?
      var code: SecCode?
      guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
        let requirement,
        SecCodeCopyGuestWithAttributes(
          nil, [kSecGuestAttributeAudit: token as NSData] as CFDictionary, [], &code)
          == errSecSuccess,
        let code
      else { return false }
      return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
  }

  static func isPlain(_ text: String) -> Bool {
    !text.isEmpty
      && text.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_"
      }
  }

  // MARK: The helper's side

  /// Makes the 0700 folder (or takes an existing one only when it is this
  /// user's, a real folder and 0700), and listens at its socket.
  public static func listen(directory: URL) throws -> Int32 {
    let path = directory.path
    if mkdir(path, S_IRWXU) != 0 {
      guard errno == EEXIST else { throw CarryOverError.socket(errno) }
    }
    var entry = stat()
    guard lstat(path, &entry) == 0, entry.st_mode & S_IFMT == S_IFDIR, entry.st_uid == getuid(),
      entry.st_mode & 0o777 == 0o700
    else { throw CarryOverError.unsafeDirectory }
    let socket = directory.appendingPathComponent(socketName).path
    guard socket.utf8.count <= AgentSocketLocation.maximumPathBytes else {
      throw CarryOverError.pathTooLong
    }
    let listener: Int32
    do { listener = try AgentSocketIO.listen(path: socket, backlog: 4) } catch {
      throw CarryOverError.socket(errno)
    }
    // On the listener, so every accepted connection has it from the start: set on a
    // connection whose peer already left, it fails (EINVAL) and a write would raise SIGPIPE.
    var on: Int32 = 1
    setsockopt(listener, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    return listener
  }

  /// The first connection whose peer passes `check`, before `deadline`;
  /// others are closed and waiting goes on.
  public static func acceptVerified(
    _ listener: Int32, until deadline: Date, check: (Int32) -> Bool
  ) throws -> Int32 {
    while true {
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { throw CarryOverError.timedOut }
      var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
      let ready = poll(&poller, 1, Int32(min(remaining, 3_600) * 1_000))
      if ready < 0, errno == EINTR { continue }
      guard ready > 0 else { continue }
      let connection = accept(listener, nil, nil)
      guard connection >= 0 else { continue }
      if check(connection) {
        setTimeouts(connection)
        return connection
      }
      close(connection)
    }
  }

  /// Removes the socket and its folder (only ours, only empty after that).
  public static func remove(directory: URL) {
    unlink(directory.appendingPathComponent(socketName).path)
    rmdir(directory.path)
  }

  // MARK: Mindloom's side

  /// Connects when a helper listens there (nil when nothing does) and checks
  /// it; a helper that fails the check is a refusal.
  public static func connectVerified(socket: URL, check: (Int32) -> Bool) throws -> Int32? {
    var entry = stat()
    guard lstat(socket.path, &entry) == 0 else { return nil }
    guard entry.st_mode & S_IFMT == S_IFSOCK, entry.st_uid == getuid() else {
      throw CarryOverError.unsafeDirectory
    }
    var folder = stat()
    guard lstat(socket.deletingLastPathComponent().path, &folder) == 0,
      folder.st_mode & S_IFMT == S_IFDIR, folder.st_uid == getuid(), folder.st_mode & 0o077 == 0
    else { throw CarryOverError.unsafeDirectory }
    let descriptor: Int32
    do { descriptor = try AgentSocketIO.connect(path: socket.path) } catch {
      return nil
    }
    guard check(descriptor) else {
      close(descriptor)
      throw CarryOverError.peerRejected
    }
    setTimeouts(descriptor)
    return descriptor
  }

  // MARK: Frames

  /// Bounded waits, and a peer that went away is an error, not SIGPIPE.
  static func setTimeouts(_ descriptor: Int32) {
    var timeout = timeval(tv_sec: ioTimeoutSeconds, tv_usec: 0)
    let size = socklen_t(MemoryLayout<timeval>.size)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, size)
    var on: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
  }

  public static func send(_ value: some Encodable, on descriptor: Int32) throws {
    guard AgentSocketIO.writeAll(descriptor, try CarryOverFrame.encode(value)) else {
      throw CarryOverError.closed
    }
  }

  public static func receive<T: Decodable>(_ type: T.Type, on descriptor: Int32) throws -> T {
    let length = try CarryOverFrame.length(of: try read(4, from: descriptor))
    return try CarryOverFrame.decode(type, body: try read(length, from: descriptor))
  }

  static func read(_ count: Int, from descriptor: Int32) throws -> Data {
    var data = Data(count: count)
    var filled = 0
    while filled < count {
      let got = data.withUnsafeMutableBytes { buffer in
        Darwin.read(descriptor, buffer.baseAddress!.advanced(by: filled), count - filled)
      }
      if got < 0, errno == EINTR { continue }
      if got < 0, errno == EAGAIN { throw CarryOverError.timedOut }
      guard got > 0 else { throw CarryOverError.closed }
      filled += got
    }
    return data
  }
}

/// Mindloom's first launch: takes what a waiting helper offers, makes the
/// items again under Mindloom's identity and the opened library's, turns
/// 「登录时打开」 on when bestASR had it on, and says what it made.
public enum KeychainCarryOverReceiver {
  public struct Outcome: Equatable, Sendable {
    public let offered: Int
    public let created: Int
    public let existing: Int
    public let failed: Int
    public let unreadable: Int
    public let loginItemWasEnabled: Bool
    public let loginItemRegistered: Bool
  }

  /// nil when no helper waits. `check` admits the helper
  /// (`CarryOverChannel.signatureCheck` with bestASR's identifier and
  /// Mindloom's own team). `acceptsLibrary` admits the folder the offer was
  /// read for (`CarryOverSource.isPreviousLibrary`); any other offer is
  /// refused before anything is made. `registerLoginItem` is asked only
  /// when bestASR's login item was on, and says whether Mindloom's is on now.
  public static func run(
    socket: URL, check: (Int32) -> Bool, acceptsLibrary: (String?) -> Bool, newRoot: String,
    keychain: some CarryOverKeychain, registerLoginItem: () -> Bool
  ) throws -> Outcome? {
    guard let descriptor = try CarryOverChannel.connectVerified(socket: socket, check: check)
    else { return nil }
    defer { close(descriptor) }
    let offer = try CarryOverChannel.receive(KeychainCarryOver.Offer.self, on: descriptor)
    try offer.validate()
    guard acceptsLibrary(offer.library) else { throw CarryOverError.otherLibrary }
    let made = KeychainCarryOver.receive(offer, newRoot: newRoot, keychain: keychain)
    let registered = offer.loginItemWasEnabled ? registerLoginItem() : false
    try CarryOverChannel.send(
      KeychainCarryOver.Receipt(
        created: made.created, existing: made.existing, failed: made.failed,
        loginItemRegistered: registered),
      on: descriptor)
    return Outcome(
      offered: offer.items.count, created: made.created, existing: made.existing,
      failed: made.failed, unreadable: offer.unreadable,
      loginItemWasEnabled: offer.loginItemWasEnabled, loginItemRegistered: registered)
  }
}
