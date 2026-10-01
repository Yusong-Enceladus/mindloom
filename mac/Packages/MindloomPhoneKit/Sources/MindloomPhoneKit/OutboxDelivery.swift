import Foundation
import MindloomLink

/// What the Spark answered for one `zhiji-inbox add --sealed`.
public struct InboxAddReceipt: Equatable, Sendable {
  public let entryID: String
  /// The Spark already had this id: a retry after a lost reply. Still success.
  public let duplicate: Bool

  public init(entryID: String, duplicate: Bool) {
    self.entryID = entryID
    self.duplicate = duplicate
  }
}

/// A delivery failure with a content-free category.
public struct InboxDeliveryError: Error, Equatable, Sendable {
  public let category: DeliveryErrorCategory
  /// A short technical note for diagnostics (never content).
  public let detail: String

  public init(_ category: DeliveryErrorCategory, detail: String = "") {
    self.category = category
    self.detail = detail
  }

  /// Whether the whole connection is unusable (stop), or only this entry was
  /// refused (go on with the next one).
  public var endsSession: Bool { category != .rejected }
}

/// One connection to the Spark's inbox gate.
public protocol InboxSession: Sendable {
  /// Runs `zhiji-inbox add --sealed --id <entryID>` with the wire on stdin.
  /// Throws `InboxDeliveryError`.
  func add(entryID: String, wire: String) async throws -> InboxAddReceipt
  func close() async
}

/// Opens sessions; the SSH implementation lives in `MindloomInboxSSH`.
public protocol InboxSessionOpening: Sendable {
  /// Throws `InboxDeliveryError`.
  func openSession() async throws -> any InboxSession
}

/// The result of one delivery run.
public struct DeliveryReport: Equatable, Sendable {
  public var sent: [String] = []
  public var duplicates: [String] = []
  public var failed: [String: DeliveryErrorCategory] = [:]
  /// Why the run ended early, if it did.
  public var stoppedBy: DeliveryErrorCategory?
  /// Entries still queued after the run.
  public var remaining: Int = 0

  public init() {}

  mutating func append(_ next: DeliveryReport) {
    sent += next.sent
    duplicates += next.duplicates
    failed.merge(next.failed) { $1 }
    stoppedBy = next.stoppedBy
    remaining = next.remaining
  }
}

/// Sends queued outbox entries to the Spark, oldest first, over one session.
///
/// Runs from the app only: when it becomes active, after each keyboard final
/// and from `BGAppRefreshTask`. Overlapping calls in one process share the
/// run already in progress instead of opening a second connection; a call
/// that arrives during a run makes it take one more pass, so an entry added
/// meanwhile (a keyboard final) is not left waiting for the next trigger.
public actor OutboxDeliverer {
  private let store: OutboxStore
  private let opener: any InboxSessionOpening
  private let clock: @Sendable () -> Date
  private var running: Task<DeliveryReport, Never>?
  private var rerunRequested = false

  /// For tests: a call arrived during the current run.
  var hasPendingRerun: Bool { rerunRequested }

  public init(
    store: OutboxStore, opener: any InboxSessionOpening,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.store = store
    self.opener = opener
    self.clock = clock
  }

  /// Delivers everything queued. Never throws: failures are recorded on the
  /// entries and summarized in the report.
  public func deliverQueued() async -> DeliveryReport {
    if let running {
      rerunRequested = true
      return await running.value
    }
    let task = Task { await self.runUntilSettled() }
    running = task
    let report = await task.value
    running = nil
    return report
  }

  private func runUntilSettled() async -> DeliveryReport {
    var report = await run()
    while rerunRequested, report.stoppedBy == nil {
      rerunRequested = false
      report.append(await run())
    }
    rerunRequested = false
    return report
  }

  private func run() async -> DeliveryReport {
    var report = DeliveryReport()
    _ = try? store.prune(now: clock())
    let queued = (try? store.queued()) ?? []
    guard !queued.isEmpty else { return report }

    let session: any InboxSession
    do {
      session = try await opener.openSession()
    } catch {
      let failure = Self.deliveryError(error)
      report.stoppedBy = failure.category
      // The attempt counts against the oldest entry only, so a long offline
      // spell does not inflate every entry's attempt count.
      if let first = queued.first {
        _ = try? store.recordFailure(id: first.entryID, category: failure.category, at: clock())
        report.failed[first.entryID] = failure.category
      }
      report.remaining = queued.count
      return report
    }

    for entry in queued {
      guard let wire = entry.wire else { continue }
      do {
        let receipt = try await session.add(entryID: entry.entryID, wire: wire)
        guard receipt.entryID == entry.entryID else {
          throw InboxDeliveryError(.protocolError, detail: "reply for another id")
        }
        _ = try? store.markSent(id: entry.entryID, at: clock(), duplicate: receipt.duplicate)
        report.sent.append(entry.entryID)
        if receipt.duplicate { report.duplicates.append(entry.entryID) }
      } catch {
        let failure = Self.deliveryError(error)
        _ = try? store.recordFailure(id: entry.entryID, category: failure.category, at: clock())
        report.failed[entry.entryID] = failure.category
        if failure.endsSession {
          report.stoppedBy = failure.category
          break
        }
      }
    }
    await session.close()
    report.remaining = (try? store.queued().count) ?? 0
    return report
  }

  static func deliveryError(_ error: Error) -> InboxDeliveryError {
    if let error = error as? InboxDeliveryError { return error }
    if error is CancellationError { return InboxDeliveryError(.timeout, detail: "cancelled") }
    return InboxDeliveryError(.network, detail: String(describing: type(of: error)))
  }
}
