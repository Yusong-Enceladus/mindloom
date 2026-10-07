import Darwin
import Foundation

/// What one tmeet run gave.
public struct TencentMeetingRunResult: Equatable, Sendable {
  /// Why a run did not start.
  public enum LaunchFailure: String, Equatable, Sendable {
    /// The helper is missing, not executable, not the one sealed into the
    /// App, or a value was not in its format.
    case helper
    /// The login's key could not be read from this Mac (access refused,
    /// locked).
    case key
  }

  /// The exit status; -1 when the process was stopped (timeout, cancel) or
  /// could not be started.
  public let exitStatus: Int32
  public let stdout: Data
  public let stderr: Data
  public let timedOut: Bool
  /// Why the program could not be started, if it was not.
  public let launchFailure: LaunchFailure?

  public var launchFailed: Bool { launchFailure != nil }

  public init(
    exitStatus: Int32, stdout: Data, stderr: Data, timedOut: Bool = false,
    launchFailure: LaunchFailure? = nil
  ) {
    self.exitStatus = exitStatus
    self.stdout = stdout
    self.stderr = stderr
    self.timedOut = timedOut
    self.launchFailure = launchFailure
  }

  public static func notLaunched(_ failure: LaunchFailure) -> TencentMeetingRunResult {
    TencentMeetingRunResult(exitStatus: -1, stdout: Data(), stderr: Data(), launchFailure: failure)
  }
}

/// Stops a running login (the owner closed the window).
public final class TencentMeetingCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var handler: (@Sendable () -> Void)?

  public init() {}

  public var isCancelled: Bool { lock.withLock { cancelled } }

  public func cancel() {
    let run: (@Sendable () -> Void)? = lock.withLock {
      cancelled = true
      return handler
    }
    run?()
  }

  func onCancel(_ action: @escaping @Sendable () -> Void) {
    let now: Bool = lock.withLock {
      handler = action
      return cancelled
    }
    if now { action() }
  }
}

/// Runs tmeet commands. The App runs the bundled helper
/// (`TmeetProcessRunner`); tests use a fake.
public protocol TencentMeetingRunning: Sendable {
  func run(_ command: TencentMeetingCommand, timeout: Duration) async -> TencentMeetingRunResult
  /// `auth login --no-browser`, handing each output line to `onLine` while
  /// it waits for the owner.
  func login(
    onLine: @escaping @Sendable (String) -> Void, cancellation: TencentMeetingCancellation
  ) async -> TencentMeetingRunResult
}

/// Where tmeet keeps its login on this Mac and how it gets its master key.
public struct TmeetEnvironment: Sendable {
  public enum MasterKey: Sendable {
    /// Mindloom's own key (patch 0003), handed over on descriptor 3 on
    /// every run; tmeet never touches the system Keychain.
    case descriptor(@Sendable () throws -> Data)
    /// tmeet's own system Keychain entry. Only for the developer's live check
    /// on a login made outside Mindloom; the App never uses it.
    case tmeetSystemKeychain
  }

  /// The descriptor number tmeet reads the key from.
  public static let keyDescriptor: Int32 = 3

  public let executable: URL
  public let stateDirectory: URL
  public let masterKey: MasterKey
  /// Checked before every run that hands over the key: a helper that fails
  /// it never starts and never gets the key.
  public let helperCheck: TencentMeetingHelperCheck

  public init(
    executable: URL, stateDirectory: URL, masterKey: MasterKey,
    helperCheck: TencentMeetingHelperCheck
  ) {
    self.executable = executable
    self.stateDirectory = stateDirectory
    self.masterKey = masterKey
    self.helperCheck = helperCheck
  }

  /// The same tmeet and key with its login in another folder (a new login
  /// is made beside the one in use and replaces it once allowed).
  public func withStateDirectory(_ directory: URL) -> TmeetEnvironment {
    TmeetEnvironment(
      executable: executable, stateDirectory: directory, masterKey: masterKey,
      helperCheck: helperCheck)
  }

  public var configDirectory: URL {
    stateDirectory.appendingPathComponent("config", isDirectory: true)
  }
  public var dataDirectory: URL { stateDirectory.appendingPathComponent("data", isDirectory: true) }

  /// The whole environment tmeet gets: nothing is inherited from the App
  /// (no proxy settings, no `TMEET_AGENT` / `TMEET_MODEL`, which upstream
  /// would put into request headers).
  public func variables(withKeyDescriptor: Bool) -> [String: String] {
    var variables: [String: String] = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "HOME": NSHomeDirectory(),
      "TMPDIR": NSTemporaryDirectory(),
      "LANG": "en_US.UTF-8",
      "TMEET_CLI_CONFIG_DIR": configDirectory.path,
      "TMEET_CLI_DATA_DIR": dataDirectory.path,
    ]
    if withKeyDescriptor { variables["TMEET_MASTER_KEY_FD"] = String(Self.keyDescriptor) }
    return variables
  }

  /// Creates the state folders 0700 (owned by this user, never a link).
  @discardableResult
  public func prepare() -> Bool {
    for directory in [stateDirectory, configDirectory, dataDirectory] {
      var entry = stat()
      if lstat(directory.path, &entry) != 0 {
        guard mkdir(directory.path, S_IRWXU) == 0 || errno == EEXIST,
          lstat(directory.path, &entry) == 0
        else { return false }
      }
      guard entry.st_mode & S_IFMT == S_IFDIR, entry.st_uid == getuid() else { return false }
      if entry.st_mode & 0o077 != 0 { chmod(directory.path, S_IRWXU) }
    }
    return true
  }
}

/// Runs the bundled tmeet with `posix_spawn`: a fixed environment, only
/// descriptors 0–3 open in the child (`POSIX_SPAWN_CLOEXEC_DEFAULT`), the
/// master key on descriptor 3, output read to the end, a time limit.
public struct TmeetProcessRunner: TencentMeetingRunning {
  public let environment: TmeetEnvironment
  /// Output beyond this is cut off (a transcript page is ~100 KB).
  public static let maximumOutputBytes = 32 * 1_024 * 1_024

  public init(environment: TmeetEnvironment) {
    self.environment = environment
  }

  public func run(_ command: TencentMeetingCommand, timeout: Duration) async
    -> TencentMeetingRunResult
  {
    guard let arguments = command.arguments, command != .authLogin else {
      return .notLaunched(.helper)
    }
    return await spawn(arguments, timeout: timeout, onLine: nil, cancellation: nil)
  }

  public func login(
    onLine: @escaping @Sendable (String) -> Void, cancellation: TencentMeetingCancellation
  ) async -> TencentMeetingRunResult {
    guard let arguments = TencentMeetingCommand.authLogin.arguments else {
      return .notLaunched(.helper)
    }
    // tmeet gives up after five minutes; a little longer here.
    return await spawn(
      arguments, timeout: .seconds(330), onLine: onLine, cancellation: cancellation)
  }

  private func spawn(
    _ arguments: [String], timeout: Duration, onLine: (@Sendable (String) -> Void)?,
    cancellation: TencentMeetingCancellation?
  ) async -> TencentMeetingRunResult {
    let key: Data?
    switch environment.masterKey {
    case .descriptor(let provide):
      // The helper first: a file put in its place never gets the key, and
      // the key is not even read for it.
      guard environment.helperCheck.trusts(environment.executable) else {
        return .notLaunched(.helper)
      }
      guard environment.prepare() else { return .notLaunched(.helper) }
      guard let value = try? provide(), value.count == 32 else { return .notLaunched(.key) }
      key = value
    case .tmeetSystemKeychain:
      guard environment.prepare() else { return .notLaunched(.helper) }
      key = nil
    }
    let launched = Self.launch(
      executable: environment.executable.path, arguments: arguments,
      variables: environment.variables(withKeyDescriptor: key != nil), key: key)
    guard let launched else { return .notLaunched(.helper) }
    let child = ChildProcess(pid: launched.pid)
    cancellation?.onCancel { child.terminate() }
    let watchdog = Task.detached {
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled else { return }
      child.terminate()
    }
    async let output = Self.readAll(launched.stdout, onLine: onLine)
    async let errors = Self.readAll(launched.stderr, onLine: nil)
    let status = await child.wait()
    watchdog.cancel()
    let (out, err) = await (output, errors)
    let wasStopped = child.wasTerminated
    return TencentMeetingRunResult(
      exitStatus: wasStopped ? -1 : status, stdout: out, stderr: err,
      timedOut: wasStopped && !(cancellation?.isCancelled ?? false))
  }

  // MARK: posix_spawn

  struct Launched {
    let pid: pid_t
    let stdout: Int32
    let stderr: Int32
  }

  static func launch(
    executable: String, arguments: [String], variables: [String: String], key: Data?
  ) -> Launched? {
    var outPipe: [Int32] = [-1, -1]
    var errPipe: [Int32] = [-1, -1]
    var keyPipe: [Int32] = [-1, -1]
    func closeAll() {
      for fd in outPipe + errPipe + keyPipe where fd >= 0 { close(fd) }
    }
    guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
      closeAll()
      return nil
    }
    if let key {
      guard pipe(&keyPipe) == 0 else {
        closeAll()
        return nil
      }
      let encoded = Array(key.base64EncodedString().utf8) + [0x0A]
      let written = encoded.withUnsafeBytes { write(keyPipe[1], $0.baseAddress, $0.count) }
      close(keyPipe[1])
      keyPipe[1] = -1
      guard written == encoded.count else {
        closeAll()
        return nil
      }
    }
    let null = open("/dev/null", O_RDONLY | O_CLOEXEC)
    guard null >= 0 else {
      closeAll()
      return nil
    }
    defer { close(null) }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    func place(_ source: Int32, at target: Int32) {
      if source == target {
        posix_spawn_file_actions_addinherit_np(&actions, target)
      } else {
        posix_spawn_file_actions_adddup2(&actions, source, target)
      }
    }
    place(null, at: 0)
    place(outPipe[1], at: 1)
    place(errPipe[1], at: 2)
    if key != nil { place(keyPipe[0], at: TmeetEnvironment.keyDescriptor) }

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var noSignals = sigset_t()
    sigemptyset(&noSignals)
    var allSignals = sigset_t()
    sigfillset(&allSignals)
    posix_spawnattr_setsigmask(&attributes, &noSignals)
    posix_spawnattr_setsigdefault(&attributes, &allSignals)
    // Its own process group, so a time limit stops anything it started.
    posix_spawnattr_setpgroup(&attributes, 0)
    posix_spawnattr_setflags(
      &attributes,
      Int16(
        POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
          | POSIX_SPAWN_SETPGROUP))

    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let envp = variables.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      for pointer in argv { free(pointer) }
      for pointer in envp { free(pointer) }
    }
    var pid: pid_t = 0
    let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
    // The child has its own copies now.
    close(outPipe[1])
    close(errPipe[1])
    if keyPipe[0] >= 0 { close(keyPipe[0]) }
    guard status == 0 else {
      close(outPipe[0])
      close(errPipe[0])
      return nil
    }
    return Launched(pid: pid, stdout: outPipe[0], stderr: errPipe[0])
  }

  /// Reads a pipe to its end (closing it), calling `onLine` for each line.
  static func readAll(_ fd: Int32, onLine: (@Sendable (String) -> Void)?) async -> Data {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        var data = Data()
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
          let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
          if count < 0, errno == EINTR { continue }
          guard count > 0 else { break }
          if data.count < TmeetProcessRunner.maximumOutputBytes {
            data.append(contentsOf: buffer[0..<count])
          }
          if let onLine {
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
              let line = pending[pending.startIndex..<newline]
              onLine(String(decoding: line, as: UTF8.self))
              pending.removeSubrange(pending.startIndex...newline)
            }
          }
        }
        if let onLine, !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
        close(fd)
        continuation.resume(returning: data)
      }
    }
  }
}

/// A started tmeet: stopped at most once, and never signalled after it was
/// reaped (its number may belong to another process by then).
final class ChildProcess: @unchecked Sendable {
  let pid: pid_t
  private let lock = NSLock()
  private var reaped = false
  private var terminated = false

  init(pid: pid_t) { self.pid = pid }

  var wasTerminated: Bool { lock.withLock { terminated } }

  func terminate() {
    let send: Bool = lock.withLock {
      guard !reaped, !terminated else { return false }
      terminated = true
      return true
    }
    guard send else { return }
    // The whole group (the process is its leader).
    kill(-pid, SIGTERM)
    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
      lock.withLock { if !reaped { kill(-pid, SIGKILL) } }
    }
  }

  /// The exit status (-1 for a signal), once the process has ended.
  func wait() async -> Int32 {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async { [self] in
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        lock.withLock { reaped = true }
        let exited = status & 0x7F == 0
        continuation.resume(returning: exited ? (status >> 8) & 0xFF : -1)
      }
    }
  }
}
