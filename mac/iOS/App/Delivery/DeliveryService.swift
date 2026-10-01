import BackgroundTasks
import Foundation
import MindloomInboxSSH
import MindloomLink
import MindloomPhoneKit
import Observation
import os

/// Sends the outbox to the Spark (PHONE-CONTRACT §5): when the app becomes
/// active, whenever the keyboard or the share extension adds something
/// (`outbox.changed`, heard while the voice session keeps the app running),
/// every minute while items wait and the session is alive, and from
/// `BGAppRefreshTask`.
@MainActor
@Observable
final class DeliveryService {
  enum Status: Equatable {
    case idle
    case sending
    case sent(Date)
    case waiting(DeliveryErrorCategory)
  }

  nonisolated static let refreshTaskIdentifier = "com.bestasr.phone.outbox-refresh"
  static let retryInterval: TimeInterval = 60

  private(set) var status: Status = .idle
  private(set) var counts = OutboxStore.Counts(queued: 0, sent: 0)
  private(set) var recent: [OutboxEntry] = []

  let outbox: OutboxStore
  private let pairing: PairingModel
  private var lastAttempt: Date?
  private var observation: PhoneSignalObservation?
  private let log = Logger(subsystem: "com.bestasr.phone", category: "delivery")

  init(
    outbox: OutboxStore, pairing: PairingModel,
    signaling: any PhoneSignaling = DarwinSignaling.shared
  ) {
    self.outbox = outbox
    self.pairing = pairing
    observation = signaling.observe(PhoneSignal.outboxChanged) { [weak self] in
      guard let self else { return }
      self.refresh()
      Task { await self.deliver() }
    }
    refresh()
  }

  /// Rereads the outbox for the screen.
  func refresh() {
    counts = (try? outbox.counts()) ?? counts
    let queued = (try? outbox.queued()) ?? []
    let sent = (try? outbox.sent()) ?? []
    recent = Array(
      (queued + sent).sorted { $0.createdAtMillis > $1.createdAtMillis }.prefix(50))
  }

  /// Sends everything queued now. Overlapping calls share one run.
  @discardableResult
  func deliver() async -> DeliveryReport? {
    refresh()
    guard counts.queued > 0 else { return nil }
    guard let opener = makeOpener() else {
      status = .waiting(.notPaired)
      return nil
    }
    status = .sending
    lastAttempt = Date()
    let report = await deliverer(opener).deliverQueued()
    refresh()
    if let stopped = report.stoppedBy {
      status = .waiting(stopped)
      log.info("delivery stopped: \(stopped.rawValue, privacy: .public)")
    } else if !report.sent.isEmpty {
      status = .sent(Date())
    } else if let failure = report.failed.values.first {
      status = .waiting(failure)
    } else {
      status = .idle
    }
    return report
  }

  /// Called on the voice session's heartbeat: retries a transient failure
  /// once a minute.
  func retryIfDue() {
    guard counts.queued > 0, status != .sending else { return }
    if case .waiting(let category) = status, !category.isTransient { return }
    if let lastAttempt, Date().timeIntervalSince(lastAttempt) < Self.retryInterval { return }
    Task { await deliver() }
  }

  // MARK: - Sender

  private var cachedDeliverer: (key: String, deliverer: OutboxDeliverer)?

  private func deliverer(_ opener: any InboxSessionOpening) -> OutboxDeliverer {
    let key = pairing.record?.phoneKeyID ?? "debug"
    if let cachedDeliverer, cachedDeliverer.key == key { return cachedDeliverer.deliverer }
    let deliverer = OutboxDeliverer(store: outbox, opener: opener)
    cachedDeliverer = (key, deliverer)
    return deliverer
  }

  private func makeOpener() -> (any InboxSessionOpening)? {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("-MindloomDebugLoopbackDelivery") {
        return DebugLoopbackOpener()
      }
    #endif
    guard let record = pairing.record, let key = pairing.signingKey() else { return nil }
    return InboxSSHSender(configuration: InboxSSHConfiguration(record: record, phoneKey: key))
  }

  // MARK: - Background refresh

  nonisolated static func registerBackgroundRefresh(
    handler: @escaping @Sendable (BGAppRefreshTask) -> Void
  ) {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskIdentifier, using: nil) {
      task in
      guard let refresh = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      handler(refresh)
    }
  }

  func scheduleBackgroundRefresh() {
    refresh()
    guard counts.queued > 0 else { return }
    let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    try? BGTaskScheduler.shared.submit(request)
  }
}

#if DEBUG
  /// DEBUG only (`-MindloomDebugLoopbackDelivery`): accepts every entry
  /// in-process instead of a Spark, so the simulator can show "已送出"
  /// without one. The wire is dropped, exactly as a real send would drop
  /// it from the phone. Never compiled into Release builds.
  struct DebugLoopbackOpener: InboxSessionOpening {
    func openSession() async throws -> any InboxSession { Session() }

    struct Session: InboxSession {
      func add(entryID: String, wire: String) async throws -> InboxAddReceipt {
        guard wire.hasPrefix(MindloomSeal.wirePrefix) else {
          throw InboxDeliveryError(.rejected, detail: "not sealed")
        }
        return InboxAddReceipt(entryID: entryID, duplicate: false)
      }

      func close() async {}
    }
  }
#endif
