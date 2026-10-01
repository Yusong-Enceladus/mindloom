import Foundation
import MindloomLink
import XCTest

@testable import MindloomPhoneKit

/// A scripted inbox: records what was added and answers per entry.
final class FakeInbox: InboxSessionOpening, @unchecked Sendable {
  enum Answer {
    case ok
    case duplicate
    case fail(DeliveryErrorCategory)
    case wrongID
  }

  private let lock = NSLock()
  private var _added: [String: String] = [:]
  private var _order: [String] = []
  private var _sessions = 0
  private var _closed = 0
  var openFailure: DeliveryErrorCategory?
  var answers: [String: Answer] = [:]
  /// Called inside `add`, before answering (to add entries mid-run).
  var onAdd: (@Sendable (String) -> Void)?

  var added: [String: String] { lock.withLock { _added } }
  var order: [String] { lock.withLock { _order } }
  var sessions: Int { lock.withLock { _sessions } }
  var closed: Int { lock.withLock { _closed } }

  func openSession() async throws -> any InboxSession {
    lock.withLock { _sessions += 1 }
    if let openFailure { throw InboxDeliveryError(openFailure) }
    return Session(inbox: self)
  }

  struct Session: InboxSession {
    let inbox: FakeInbox

    func add(entryID: String, wire: String) async throws -> InboxAddReceipt {
      inbox.onAdd?(entryID)
      let answer = inbox.lock.withLock { () -> Answer in
        inbox._order.append(entryID)
        return inbox.answers[entryID] ?? .ok
      }
      switch answer {
      case .ok:
        inbox.lock.withLock { inbox._added[entryID] = wire }
        return InboxAddReceipt(entryID: entryID, duplicate: false)
      case .duplicate:
        return InboxAddReceipt(entryID: entryID, duplicate: true)
      case .fail(let category):
        throw InboxDeliveryError(category)
      case .wrongID:
        return InboxAddReceipt(entryID: EntryID.make(), duplicate: false)
      }
    }

    func close() async { inbox.lock.withLock { inbox._closed += 1 } }
  }
}

final class OutboxDelivererTests: XCTestCase {
  private var root: URL!
  private var store: OutboxStore!
  private let inbox = FakeInbox()

  override func setUpWithError() throws {
    root = try makeTemporaryDirectory().appendingPathComponent("outbox")
    store = try OutboxStore(root: root)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
  }

  private func deliverer() -> OutboxDeliverer {
    OutboxDeliverer(store: store, opener: inbox, clock: { baseDate.addingTimeInterval(100) })
  }

  func testSendsEverythingOldestFirstOverOneSession() async throws {
    let entries = try (0..<3).map { try makeEntry("条目\($0)", at: TimeInterval(3 - $0)) }
    for entry in entries { try store.add(entry) }
    let report = await deliverer().deliverQueued()
    let expectedOrder = entries.reversed().map(\.entryID)
    XCTAssertEqual(report.sent, expectedOrder)
    XCTAssertEqual(inbox.order, expectedOrder)
    XCTAssertEqual(inbox.sessions, 1)
    XCTAssertEqual(inbox.closed, 1)
    XCTAssertEqual(report.remaining, 0)
    XCTAssertNil(report.stoppedBy)
    for entry in entries {
      XCTAssertEqual(
        inbox.added[entry.entryID], entry.wire, "the Spark receives exactly the sealed wire")
      XCTAssertEqual(try store.entry(id: entry.entryID)?.state, .sent)
    }
  }

  func testNothingQueuedOpensNoConnection() async {
    let report = await deliverer().deliverQueued()
    XCTAssertEqual(report, DeliveryReport())
    XCTAssertEqual(inbox.sessions, 0)
  }

  func testDuplicateIDCountsAsSent() async throws {
    let entry = try makeEntry()
    try store.add(entry)
    inbox.answers[entry.entryID] = .duplicate
    let report = await deliverer().deliverQueued()
    XCTAssertEqual(report.sent, [entry.entryID])
    XCTAssertEqual(report.duplicates, [entry.entryID])
    XCTAssertEqual(try store.entry(id: entry.entryID)?.duplicate, true)
  }

  func testConnectionFailureKeepsEverythingQueued() async throws {
    let entries = try (0..<3).map { try makeEntry("离线\($0)", at: TimeInterval($0)) }
    for entry in entries { try store.add(entry) }
    inbox.openFailure = .network
    let report = await deliverer().deliverQueued()
    XCTAssertEqual(report.stoppedBy, .network)
    XCTAssertEqual(report.remaining, 3)
    XCTAssertEqual(try store.queued().map(\.entryID), entries.map(\.entryID))
    XCTAssertEqual(
      try store.entry(id: entries[0].entryID)?.attempts, 1, "only the oldest is charged")
    XCTAssertEqual(try store.entry(id: entries[1].entryID)?.attempts, 0)

    // Back online: the same entries go out, with their original ids.
    inbox.openFailure = nil
    let retry = await deliverer().deliverQueued()
    XCTAssertEqual(retry.sent, entries.map(\.entryID))
    XCTAssertEqual(retry.remaining, 0)
  }

  func testHostKeyMismatchStopsTheRun() async throws {
    try store.add(makeEntry())
    inbox.openFailure = .hostKeyMismatch
    let report = await deliverer().deliverQueued()
    XCTAssertEqual(report.stoppedBy, .hostKeyMismatch)
    XCTAssertEqual(inbox.order, [], "nothing is sent to an unverified host")
    XCTAssertEqual(try store.queued().first?.lastError, .hostKeyMismatch)
  }

  func testRejectedEntrySkipsToTheNextButNetworkLossStops() async throws {
    let entries = try (0..<4).map { try makeEntry("混合\($0)", at: TimeInterval($0)) }
    for entry in entries { try store.add(entry) }
    inbox.answers[entries[0].entryID] = .fail(.rejected)
    inbox.answers[entries[2].entryID] = .fail(.network)
    let report = await deliverer().deliverQueued()
    XCTAssertEqual(report.sent, [entries[1].entryID])
    XCTAssertEqual(report.failed, [entries[0].entryID: .rejected, entries[2].entryID: .network])
    XCTAssertEqual(report.stoppedBy, .network)
    XCTAssertEqual(inbox.order, entries.prefix(3).map(\.entryID), "the fourth was not tried")
    XCTAssertEqual(report.remaining, 3)
    XCTAssertEqual(try store.entry(id: entries[0].entryID)?.lastError, .rejected)
  }

  func testReplyForAnotherIDIsNotSuccess() async throws {
    let entry = try makeEntry()
    try store.add(entry)
    inbox.answers[entry.entryID] = .wrongID
    let report = await deliverer().deliverQueued()
    XCTAssertEqual(report.sent, [])
    XCTAssertEqual(report.stoppedBy, .protocolError)
    XCTAssertEqual(try store.entry(id: entry.entryID)?.state, .queued)
  }

  /// A call during a run shares it, and an entry added meanwhile still goes
  /// out in the same run.
  func testOverlappingCallsShareOneRunAndPickUpNewEntries() async throws {
    let first = try makeEntry("第一条", at: 0)
    try store.add(first)
    let late = try makeEntry("说话时新加的", at: 1)
    let deliverer = deliverer()
    let store = self.store!
    let started = expectation(description: "first add started")
    let gate = AsyncGate()
    inbox.onAdd = { id in
      if id == first.entryID {
        _ = try? store.add(late)
        started.fulfill()
        gate.wait()
      }
    }
    async let firstReport = deliverer.deliverQueued()
    await fulfillment(of: [started], timeout: 5)
    async let secondReport = deliverer.deliverQueued()
    for _ in 0..<500 where !(await deliverer.hasPendingRerun) {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let registered = await deliverer.hasPendingRerun
    XCTAssertTrue(registered)
    gate.open()
    let (a, b) = await (firstReport, secondReport)
    XCTAssertEqual(a, b)
    XCTAssertEqual(Set(a.sent), [first.entryID, late.entryID])
    XCTAssertEqual(inbox.sessions, 2, "one extra pass for the late entry")
    XCTAssertEqual(try store.queued(), [])
  }
}

/// A one-shot latch a synchronous callback can block on.
final class AsyncGate: @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 0)
  func wait() { semaphore.wait() }
  func open() { semaphore.signal() }
}
