import BestASRPersistence
import Foundation
import GRDB
import XCTest

/// REHEARSAL.md §8 (regression): a second launch on a copy of the real
/// library stopped with 「本机服务启动失败」 on SQLITE_BUSY_RECOVERY (261),
/// because another program was reading `history.sqlite` at that moment and
/// the open neither waited nor tried again; and each quit left a 26 MB WAL
/// for the next open to recover. Every value is synthetic.
final class LibraryOpenRetryTests: XCTestCase {
  private struct Unrelated: Error {}

  func testABusyOpenIsTriedAgainAfterABoundedBackoff() throws {
    var attempts = 0
    var slept: [TimeInterval] = []
    let open: () throws -> String = {
      attempts += 1
      if attempts == 1 { throw DatabaseError(resultCode: .SQLITE_BUSY_RECOVERY) }
      if attempts == 2 { throw DatabaseError(resultCode: .SQLITE_BUSY) }
      return "open"
    }
    let value = try LibraryOpenRetry.standard.run(sleep: { slept.append($0) }, open)
    XCTAssertEqual(value, "open")
    XCTAssertEqual(attempts, 3)
    XCTAssertEqual(slept, [0.1, 0.2])
  }

  func testOnlyBusyIsWaitedFor() {
    XCTAssertTrue(LibraryOpenRetry.isBusy(DatabaseError(resultCode: .SQLITE_BUSY_RECOVERY)))
    XCTAssertTrue(LibraryOpenRetry.isBusy(DatabaseError(resultCode: .SQLITE_BUSY_SNAPSHOT)))
    XCTAssertFalse(LibraryOpenRetry.isBusy(DatabaseError(resultCode: .SQLITE_CORRUPT)))
    XCTAssertFalse(LibraryOpenRetry.isBusy(Unrelated()))
    var attempts = 0
    let corrupt: () throws -> Int = {
      attempts += 1
      throw DatabaseError(resultCode: .SQLITE_CORRUPT)
    }
    XCTAssertThrowsError(
      try LibraryOpenRetry.standard.run(sleep: { _ in XCTFail("no wait") }, corrupt))
    XCTAssertEqual(attempts, 1)
  }

  /// The waits are bounded: a database that stays busy fails the open after
  /// the last attempt, and no attempt starts after the deadline.
  func testTheWaitsAreBounded() {
    let retry = LibraryOpenRetry.standard
    var attempts = 0
    var slept: [TimeInterval] = []
    let busy: () throws -> Int = {
      attempts += 1
      throw DatabaseError(resultCode: .SQLITE_BUSY)
    }
    XCTAssertThrowsError(try retry.run(sleep: { slept.append($0) }, busy)) { error in
      XCTAssertTrue(LibraryOpenRetry.isBusy(error))
    }
    XCTAssertEqual(attempts, retry.delays.count + 1)
    XCTAssertEqual(slept, retry.delays)
    XCTAssertLessThanOrEqual(retry.delays.reduce(0, +), retry.maximumSeconds)

    // Each attempt waiting out a five-second lock: the deadline stops it.
    var clock = Date(timeIntervalSince1970: 0)
    attempts = 0
    let locked: () throws -> Int = {
      attempts += 1
      clock.addTimeInterval(LibraryOpenRetry.busyTimeoutSeconds)
      throw DatabaseError(resultCode: .SQLITE_BUSY)
    }
    XCTAssertThrowsError(
      try retry.run(sleep: { clock.addTimeInterval($0) }, now: { clock }, locked))
    XCTAssertLessThan(attempts, retry.delays.count + 1)
    XCTAssertLessThanOrEqual(
      clock.timeIntervalSince1970,
      retry.maximumSeconds + LibraryOpenRetry.busyTimeoutSeconds)
  }

  /// Another program holds the write lock while Mindloom opens the library:
  /// the open waits for it instead of failing (it failed at once before).
  func testTheLibraryOpensWhileAnotherProgramHoldsTheDatabaseBriefly() async throws {
    let root = try persistenceTemporaryDirectory()
    let databaseURL = root.appendingPathComponent("history.sqlite")
    let first = try GRDBDictationStore(databaseURL: databaseURL)
    await first.closeForQuit()

    // Another program (a `sqlite3` check, an import) in a write transaction.
    var otherConfiguration = Configuration()
    otherConfiguration.allowsUnsafeTransactions = true
    let other = try DatabaseQueue(path: databaseURL.path, configuration: otherConfiguration)
    try await other.writeWithoutTransaction { db in try db.execute(sql: "BEGIN IMMEDIATE") }
    let released = expectation(description: "the other program lets go")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      try? other.writeWithoutTransaction { db in try db.execute(sql: "COMMIT") }
      released.fulfill()
    }
    let started = Date()
    let store = try GRDBDictationStore.openWaitingWhileBusy(databaseURL: databaseURL)
    let waited = Date().timeIntervalSince(started)
    await fulfillment(of: [released], timeout: 5)
    XCTAssertGreaterThanOrEqual(waited, 0.2, "the open waited for the other program")
    _ = try await store.historyCountsByMode()
    await store.closeForQuit()
    try other.close()
  }

  /// Regression (review 10-5d R6): each statement of an open waited its own
  /// five seconds for a lock, so an open whose last attempt started in time
  /// could run far past the retry's deadline, on the main thread with no
  /// window. A statement now stops waiting at the deadline of the whole open.
  func testTheWholeOpenEndsByItsDeadline() async throws {
    let root = try persistenceTemporaryDirectory()
    let databaseURL = root.appendingPathComponent("history.sqlite")
    let first = try GRDBDictationStore(databaseURL: databaseURL)
    await first.closeForQuit()

    // Another program keeps the write lock for longer than the open may take.
    var otherConfiguration = Configuration()
    otherConfiguration.allowsUnsafeTransactions = true
    let other = try DatabaseQueue(path: databaseURL.path, configuration: otherConfiguration)
    try await other.writeWithoutTransaction { db in try db.execute(sql: "BEGIN IMMEDIATE") }
    defer {
      try? other.writeWithoutTransaction { db in try db.execute(sql: "ROLLBACK") }
      try? other.close()
    }
    let retry = LibraryOpenRetry(delays: [0.1], maximumSeconds: 0.6)
    XCTAssertEqual(retry.busyTimeout, LibraryOpenRetry.busyTimeoutSeconds)
    let started = Date()
    XCTAssertThrowsError(
      try GRDBDictationStore.openWaitingWhileBusy(databaseURL: databaseURL, retry: retry)
    ) { error in
      XCTAssertTrue(LibraryOpenRetry.isBusy(error), "\(error)")
    }
    let waited = Date().timeIntervalSince(started)
    XCTAssertGreaterThanOrEqual(waited, 0.4, "it waited for the lock")
    XCTAssertLessThan(
      waited, 2, "the open ended by its deadline, not after a five-second wait per statement")
  }

  /// The busy handler's arithmetic: a short step at a time, up to the
  /// timeout for one lock, never past the open's deadline; after the open,
  /// only the timeout.
  func testTheBusyWaitStopsAtTheTimeoutAndAtTheOpensDeadline() {
    let now = Date(timeIntervalSince1970: 1_000)
    let open = LibraryBusyWait(timeout: 5, openDeadline: now.addingTimeInterval(0.05))
    XCTAssertEqual(open.nextWait(afterTries: 0, now: now), LibraryBusyWait.step)
    XCTAssertEqual(
      open.nextWait(afterTries: 0, now: now.addingTimeInterval(0.04)) ?? 0, 0.01, accuracy: 1e-6)
    XCTAssertNil(open.nextWait(afterTries: 1, now: now.addingTimeInterval(0.05)), "deadline")
    let tries = Int((5 / LibraryBusyWait.step).rounded())
    XCTAssertNil(open.nextWait(afterTries: tries, now: now), "timeout")
    open.openFinished()
    XCTAssertEqual(
      open.nextWait(afterTries: 1, now: now.addingTimeInterval(60)), LibraryBusyWait.step,
      "after the open only the timeout bounds a wait")
    XCTAssertNil(open.nextWait(afterTries: tries, now: now.addingTimeInterval(60)))
    let unbounded = LibraryBusyWait(timeout: 5, openDeadline: nil)
    XCTAssertEqual(unbounded.nextWait(afterTries: 3, now: now), LibraryBusyWait.step)
  }

  /// Regression (review 10-5d R6): quitting waited for the library to close,
  /// and closing waits for every access in progress, with no bound — a long
  /// read by another program (or a long write of the App's) held up the quit,
  /// a log out or a shutdown. Quitting now waits at most a few seconds; the
  /// close goes on and finishes once the other program lets go.
  func testQuittingWaitsForTheLibraryOnlyBriefly() async throws {
    let root = try persistenceTemporaryDirectory()
    let databaseURL = root.appendingPathComponent("history.sqlite")
    let store = try GRDBDictationStore(databaseURL: databaseURL)
    _ = try await store.historyCountsByMode()

    // Another program writes, then keeps reading the snapshot that has its
    // write in the WAL: the checkpoint at quit has to wait for it.
    var otherConfiguration = Configuration()
    otherConfiguration.allowsUnsafeTransactions = true
    let other = try DatabaseQueue(path: databaseURL.path, configuration: otherConfiguration)
    try await other.writeWithoutTransaction { db in
      // Its write stays in the WAL (no checkpoint of its own).
      try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
      try db.execute(sql: "CREATE TABLE other_program (x INTEGER)")
      try db.execute(sql: "INSERT INTO other_program VALUES (1)")
      try db.execute(sql: "BEGIN")
      _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM other_program")
    }
    await MainActor.run { LibraryQuit.store = store }
    XCTAssertGreaterThan(LibraryQuit.quitWaitSeconds, 1)
    XCTAssertLessThanOrEqual(LibraryQuit.quitWaitSeconds, 3)
    let started = Date()
    let closed = await LibraryQuit.close(within: 0.3)
    let waited = Date().timeIntervalSince(started)
    XCTAssertFalse(closed, "the other program still reads: the close is not done yet")
    XCTAssertLessThan(waited, 1.5, "quitting did not wait for the close")

    try await other.writeWithoutTransaction { db in try db.execute(sql: "COMMIT") }
    try other.close()
    // The close goes on and finishes: nothing is left in the WAL.
    let wal = databaseURL.path + "-wal"
    var walBytes = Int.max
    for _ in 0..<100 {
      walBytes = (try? FileManager.default.attributesOfItem(atPath: wal)[.size] as? Int) ?? 0
      if walBytes == 0 { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertEqual(walBytes, 0)
    let nothingOpen = await LibraryQuit.close(within: 0.3)
    XCTAssertTrue(nothingOpen)
  }

  /// Quitting checkpoints the WAL into the database and closes it: nothing
  /// is left for the next open to recover, and the store is closed.
  func testQuittingClosesTheLibraryAndLeavesNoWAL() async throws {
    let root = try persistenceTemporaryDirectory()
    let databaseURL = root.appendingPathComponent("history.sqlite")
    let store = try GRDBDictationStore(databaseURL: databaseURL)
    _ = try await store.historyCountsByMode()
    let wal = URL(fileURLWithPath: databaseURL.path + "-wal")
    await MainActor.run { LibraryQuit.store = store }
    let didClose = await LibraryQuit.close()
    XCTAssertTrue(didClose)
    let walBytes =
      (try? FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int) ?? 0
    XCTAssertEqual(walBytes, 0, "no WAL left to recover")
    do {
      _ = try await store.historyCountsByMode()
      XCTFail("a closed library is not used again")
    } catch {}
    let nothingOpen = await LibraryQuit.close()
    XCTAssertTrue(nothingOpen)
    // The next open finds the library as it was.
    let reopened = try GRDBDictationStore(databaseURL: databaseURL)
    _ = try await reopened.historyCountsByMode()
    await reopened.closeForQuit()
  }
}
