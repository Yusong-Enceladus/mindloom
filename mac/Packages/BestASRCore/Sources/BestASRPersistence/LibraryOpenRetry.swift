import Foundation
import GRDB
import os

/// Opening the library while another program has `history.sqlite` busy — a
/// `sqlite3` check, an import, a backup tool, or a reader recovering the WAL
/// an earlier run left (SQLITE_BUSY_RECOVERY) — is a wait, not a failure.
///
/// The rehearsal on a copy of the real library (REHEARSAL.md §8) saw the App
/// stop its startup with 「本机服务启动失败」 on `SQLITE_BUSY_RECOVERY` (261),
/// because nothing waited: the connections had no busy timeout and the open
/// was tried once. Now each connection waits up to `busyTimeout` for a lock,
/// and the whole open is tried again after a bounded backoff while the
/// database reports busy; any other error still fails at once.
///
/// The whole open has one deadline, `maximumSeconds` after it began: no
/// attempt starts after it, and no statement of an attempt waits for a lock
/// past it (`LibraryBusyWait`). Review 10-5d R6: each statement of an attempt
/// used to wait its own five seconds, so an open that started its last
/// attempt in time could still run well past fifteen seconds, on the main
/// thread, with no window shown.
public struct LibraryOpenRetry: Equatable, Sendable {
  /// The waits between attempts, in seconds: one attempt more than waits.
  public let delays: [TimeInterval]
  /// The deadline of the whole open, after its start: no attempt starts and
  /// no lock is waited for later than this.
  public let maximumSeconds: TimeInterval
  /// How long one statement waits for a lock another program holds.
  public let busyTimeout: TimeInterval

  public init(
    delays: [TimeInterval], maximumSeconds: TimeInterval,
    busyTimeout: TimeInterval = LibraryOpenRetry.busyTimeoutSeconds
  ) {
    self.delays = delays
    self.maximumSeconds = maximumSeconds
    self.busyTimeout = busyTimeout
  }

  /// Seven attempts over about six seconds of waiting, all of it within
  /// fifteen seconds of the first.
  public static let standard = LibraryOpenRetry(
    delays: [0.1, 0.2, 0.4, 0.8, 1.6, 3.2], maximumSeconds: 15)

  /// How long a connection waits for a lock another program holds before it
  /// reports busy.
  public static let busyTimeoutSeconds: TimeInterval = 5

  /// SQLITE_BUSY and its extended codes: BUSY_RECOVERY (261),
  /// BUSY_SNAPSHOT (517), BUSY_TIMEOUT (773).
  public static func isBusy(_ error: any Error) -> Bool {
    guard let error = error as? DatabaseError else { return false }
    return error.resultCode == .SQLITE_BUSY
  }

  /// `open` until it succeeds, fails with something other than busy, or the
  /// waits run out; `sleep` waits between attempts (the App's startup is
  /// synchronous, so the App passes `Thread.sleep`). `open` gets the
  /// deadline of the whole open, for its statements' waits. The last busy
  /// error is thrown when the waits run out.
  public func run<Value>(
    sleep: (TimeInterval) -> Void,
    now: () -> Date = Date.init,
    _ open: (_ deadline: Date) throws -> Value
  ) throws -> Value {
    let started = now()
    let deadline = started.addingTimeInterval(maximumSeconds)
    var attempt = 0
    while true {
      do {
        return try open(deadline)
      } catch let error where Self.isBusy(error) {
        guard attempt < delays.count,
          now().timeIntervalSince(started) + delays[attempt] <= maximumSeconds
        else { throw error }
        sleep(delays[attempt])
        attempt += 1
      }
    }
  }

  /// `run` for an open that does not need the deadline.
  public func run<Value>(
    sleep: (TimeInterval) -> Void,
    now: () -> Date = Date.init,
    _ open: () throws -> Value
  ) throws -> Value {
    try run(sleep: sleep, now: now) { (_: Date) in try open() }
  }
}

/// SQLite's busy handler for the library's connections: it waits in short
/// steps while another program holds a lock, up to `timeout` for one lock,
/// and, while an open is in progress, never past that open's deadline
/// (review 10-5d R6). After the open, `openFinished()` lifts the deadline and
/// every statement waits up to `timeout` again.
public final class LibraryBusyWait: Sendable {
  /// One wait between tries.
  public static let step: TimeInterval = 0.02

  public let timeout: TimeInterval
  private let openDeadline: OSAllocatedUnfairLock<Date?>

  public init(timeout: TimeInterval, openDeadline: Date?) {
    self.timeout = timeout
    self.openDeadline = OSAllocatedUnfairLock(initialState: openDeadline)
  }

  /// The open is done: from now on only `timeout` bounds a wait.
  public func openFinished() {
    openDeadline.withLock { $0 = nil }
  }

  /// How long to wait before trying again after `tries` tries at one lock,
  /// or nil to give up (SQLite then reports busy).
  public func nextWait(afterTries tries: Int, now: Date = Date()) -> TimeInterval? {
    guard Double(tries) * Self.step < timeout else { return nil }
    guard let deadline = openDeadline.withLock({ $0 }) else { return Self.step }
    let left = deadline.timeIntervalSince(now)
    guard left > 0 else { return nil }
    return min(Self.step, left)
  }

  /// The handler GRDB installs (`Configuration.busyMode = .callback`).
  public var callback: Database.BusyCallback {
    { [self] tries in
      guard let wait = nextWait(afterTries: tries) else { return false }
      Thread.sleep(forTimeInterval: wait)
      return true
    }
  }
}
