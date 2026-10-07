import BackgroundTasks
import Foundation
import MindloomInboxSSH
import MindloomLink
import MindloomPhoneKit
import Network
import Observation
import os

/// One row on Home: what the user sent, and whether it is still on this iPhone.
struct HomeRow: Identifiable, Equatable {
  var item: PhoneItem
  var onPhone: Bool
  var sentAt: Date?
  /// A part can no longer leave this iPhone (「没能送出」).
  var notSent = false
  /// Previews on disk (photos, a link's image).
  var previews: [URL]

  var id: String { item.id }
}

/// Keeps what the user sent and sends it to the Mac (PHONE-SPEC §7.5): pending → sent, with the
/// undo hold before anything leaves, automatic retries when the route comes back (network path,
/// becoming active, the voice session's heartbeat, background refresh), and the status line's
/// facts (pending count, reachability, the last delivery).
@MainActor
@Observable
final class DeliveryService {
  nonisolated static let refreshTaskIdentifier = PhoneNames.outboxRefreshTask
  static let retryInterval: TimeInterval = 60

  private(set) var rows: [HomeRow] = []
  /// The last attempt could not reach the Mac (and nothing got through since).
  private(set) var unreachable = false
  private(set) var isSending = false
  /// How many items are still on this iPhone.
  var pendingCount: Int { rows.filter(\.onPhone).count }

  let collector: PhoneItemCollector
  let settings: PhoneSettings
  /// Only on a build without the App Group: the items the share extension keeps and sends itself.
  /// With the group, the list a build without it left in the keychain, until the share extension
  /// has moved its own storage into the group (`shareHandoffIsLeftover`).
  var shareHandoff: ShareHandoff?
  /// `shareHandoff` is what a build without the App Group left: read until the extension removes it.
  var shareHandoffIsLeftover = false
  private let pairing: PairingModel
  private var lastAttempt: Date?
  private var observation: PhoneSignalObservation?
  private var holdTimer: Task<Void, Never>?
  private var monitor: NWPathMonitor?
  private var pathSatisfied = true
  private var running: Task<DeliveryReport?, Never>?
  /// A trigger arrived during the run in progress (a hold ended, a new item): run once more.
  private var rerun = false
  private let log = Logger(subsystem: PhoneNames.appLog, category: "delivery")

  init(
    collector: PhoneItemCollector, pairing: PairingModel, settings: PhoneSettings,
    signaling: any PhoneSignaling = DarwinSignaling.shared
  ) {
    self.collector = collector
    self.pairing = pairing
    self.settings = settings
    observation = signaling.observe(PhoneSignal.outboxChanged) { [weak self] in
      guard let self else { return }
      // The share extension may have moved items that waited for pairing into the group.
      self.sealPending()
      self.refresh()
      Task { await self.deliver() }
    }
    refresh()
  }

  var outbox: OutboxStore { collector.outbox }
  var lastSentAt: Date? { settings.lastSentAt }

  /// Watches the network path: when it comes back, items leave by themselves.
  func startMonitoring() {
    guard monitor == nil else { return }
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      let satisfied = path.status == .satisfied
      Task { @MainActor in self?.pathChanged(satisfied: satisfied) }
    }
    monitor.start(queue: DispatchQueue(label: PhoneNames.queueLabel("path")))
    self.monitor = monitor
  }

  private func pathChanged(satisfied: Bool) {
    let wasSatisfied = pathSatisfied
    pathSatisfied = satisfied
    if !satisfied, pendingCount > 0 { unreachable = true }
    if satisfied, !wasSatisfied { Task { await deliver() } }
  }

  // MARK: - Rows

  /// Rereads the items and the outbox for the screen.
  func refresh() {
    if let handoff = shareHandoff {
      if shareHandoffIsLeftover, !handoff.hasItems {
        shareHandoff = nil
      } else {
        handoff.importItems(into: collector.items)
      }
    }
    let items = collector.items.all()
    var referenced = Set<String>()
    var next: [HomeRow] = items.map { item in
      referenced.formUnion(item.entryIDs)
      let delivery = collector.delivery(of: item)
      let count = item.kind == .photos ? item.photoCount : (item.kind == .link ? 1 : 0)
      let previews = (0..<max(count, 0)).map { collector.items.previewURL(id: item.id, index: $0) }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
      switch delivery {
      case .onPhone: return HomeRow(item: item, onPhone: true, sentAt: nil, previews: previews)
      case .sent(let at): return HomeRow(item: item, onPhone: false, sentAt: at, previews: previews)
      case .notSent:
        return HomeRow(item: item, onPhone: false, sentAt: nil, notSent: true, previews: previews)
      }
    }
    next += orphanRows(excluding: referenced)
    next.sort { ($0.item.createdAt, $0.id) > ($1.item.createdAt, $1.id) }
    if next != rows { rows = next }
    if pendingCount == 0 { unreachable = false }
    scheduleHoldRelease()
  }

  /// Outbox entries no item describes (written by an older keyboard or share extension): shown
  /// from their short preview so nothing the user sent is hidden.
  private func orphanRows(excluding referenced: Set<String>) -> [HomeRow] {
    let outbox = collector.outbox
    let entries =
      ((try? outbox.held()) ?? []).map { ($0, true) } + ((try? outbox.queued()) ?? []).map { ($0, true) }
      + ((try? outbox.sent()) ?? []).map { ($0, false) }
    return entries.filter { !referenced.contains($0.0.entryID) }.map { entry, onPhone in
      let kind: PhoneItem.Kind
      switch entry.kind {
      case .text: kind = .text
      case .link: kind = .link
      case .image: kind = .photos
      case .file: kind = .file
      }
      var item = PhoneItem(
        id: entry.entryID, createdAt: entry.createdAt, kind: kind,
        source: PhoneItem.Source(entry.source), entryIDs: [entry.entryID])
      switch kind {
      case .text: item.text = entry.preview
      case .link: item.link = PhoneItem.Link(url: entry.preview ?? "")
      case .photos: item.photoCount = 1
      case .file: item.fileTitle = entry.preview
      }
      return HomeRow(item: item, onPhone: onPhone, sentAt: entry.sentAt, previews: [])
    }
  }

  // MARK: - Sending

  /// Sends everything queued now. Overlapping calls share one run.
  @discardableResult
  func deliver() async -> DeliveryReport? {
    if let running {
      rerun = true
      return await running.value
    }
    let task = Task { @MainActor in
      var report: DeliveryReport?
      repeat {
        self.rerun = false
        report = await self.run()
      } while self.rerun && report?.stoppedBy == nil
      self.rerun = false
      return report
    }
    running = task
    let report = await task.value
    running = nil
    return report
  }

  private func run() async -> DeliveryReport? {
    // The deliverer prunes the outbox: an item of a kept recording keeps its delivery first.
    collector.noteKeptItemsSent()
    refresh()
    let sealKeyID = pairing.record?.sealKeyID
    let queued = ((try? outbox.queued()) ?? []).filter { $0.sealKeyID == sealKeyID }.count
    guard queued > 0 else { return nil }
    guard let opener = makeOpener() else { return nil }
    isSending = true
    lastAttempt = Date()
    let report = await deliverer(opener).deliverQueued()
    isSending = false
    collector.noteKeptItemsSent()
    if !report.sent.isEmpty || !report.duplicates.isEmpty {
      settings.lastSentAt = Date()
      unreachable = false
    }
    if let stopped = report.stoppedBy {
      unreachable = stopped != .rejected
      log.info("delivery stopped: \(stopped.rawValue, privacy: .public)")
    } else if report.failed.values.contains(where: { $0 != .rejected }) {
      unreachable = true
    }
    refresh()
    return report
  }

  /// Called on the voice session's heartbeat: retries once a minute while items wait.
  func retryIfDue() {
    guard pendingCount > 0, !isSending, pairing.isPaired else { return }
    if let lastAttempt, Date().timeIntervalSince(lastAttempt) < Self.retryInterval { return }
    Task { await deliver() }
  }

  /// When the earliest undo hold ends, send.
  private func scheduleHoldRelease() {
    holdTimer?.cancel()
    guard let end = try? outbox.nextHoldEnd() else { return }
    holdTimer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(max(0.05, end.timeIntervalSinceNow + 0.05)))
      guard !Task.isCancelled, let self else { return }
      await self.deliver()
    }
  }

  // MARK: - Items

  /// Ends an item's undo window now and sends it.
  func release(itemID: String) {
    try? collector.release(id: itemID)
    refresh()
    Task { await deliver() }
  }

  /// 「撤销」 / 「撤回」.
  @discardableResult
  func withdraw(itemID: String) -> Bool {
    let done = (try? collector.withdraw(id: itemID)) ?? false
    refresh()
    return done
  }

  /// Seals what waits for a Mac when one is paired: items kept unsealed by the share extension
  /// before the app had moved its pairing into the App Group, or brought over from a build
  /// without the group. Nothing when unpaired; a second call finds nothing.
  func sealPending() {
    guard pairing.isPaired else { return }
    do {
      let sealed = try collector.sealAwaitingItems()
      if sealed > 0 { log.notice("sealed \(sealed) waiting items") }
    } catch {
      log.error("sealing waiting items: \(String(describing: error), privacy: .public)")
    }
  }

  /// After pairing: seal what waited for a Mac, then send.
  func paired() {
    try? collector.sealAwaitingItems()
    unreachable = false
    refresh()
    Task { await deliver() }
  }

  func prune() {
    collector.prune()
    try? outbox.prune()
    refresh()
  }

  // MARK: - Sender

  private var cachedDeliverer: (key: String, deliverer: OutboxDeliverer)?

  private func deliverer(_ opener: any InboxSessionOpening) -> OutboxDeliverer {
    let sealKeyID = pairing.record?.sealKeyID
    let key = (pairing.record?.phoneKeyID ?? "debug") + "/" + (sealKeyID ?? "-")
    if let cachedDeliverer, cachedDeliverer.key == key { return cachedDeliverer.deliverer }
    // Only what is sealed to the paired Mac leaves; parts sealed to an earlier Mac stay.
    let deliverer = OutboxDeliverer(store: outbox, opener: opener, sealKeyID: sealKeyID)
    cachedDeliverer = (key, deliverer)
    return deliverer
  }

  private func makeOpener() -> (any InboxSessionOpening)? {
    guard let record = pairing.record, let key = pairing.signingKey() else { return nil }
    #if DEBUG
      if let opener = DebugLaunch.deliveryOpener() { return opener }
    #endif
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
    guard pendingCount > 0 else { return }
    let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    try? BGTaskScheduler.shared.submit(request)
  }
}

#if DEBUG
  /// DEBUG only (`-MindloomDebugLoopbackDelivery`): accepts every entry
  /// in-process instead of a Mac, so the simulator can show delivery
  /// without one. The wire is dropped, exactly as a real send would drop
  /// it from the phone. Never compiled into Release builds.
  struct DebugLoopbackOpener: InboxSessionOpening {
    var delay: Duration = .zero

    func openSession() async throws -> any InboxSession { Session(delay: delay) }

    struct Session: InboxSession {
      let delay: Duration

      func add(entryID: String, wire: String) async throws -> InboxAddReceipt {
        guard wire.hasPrefix(MindloomSeal.wirePrefix) else {
          throw InboxDeliveryError(.rejected, detail: "not sealed")
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        return InboxAddReceipt(entryID: entryID, duplicate: false)
      }

      func close() async {}
    }
  }

  /// DEBUG only (`-MindloomDebugOffline`): every attempt finds no route.
  struct DebugOfflineOpener: InboxSessionOpening {
    func openSession() async throws -> any InboxSession {
      throw InboxDeliveryError(.network, detail: "debug offline")
    }
  }
#endif
