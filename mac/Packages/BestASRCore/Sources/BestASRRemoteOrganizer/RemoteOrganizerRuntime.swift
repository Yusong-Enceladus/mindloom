import BestASRDomain
import Foundation

/// Owns one SSH forward and one HTTP transport for organizing on the user's
/// own Spark. It is created only after the user enables the link from an
/// allowed data root, and it is single-use: `stop()` ends it for good.
///
/// Every request goes to a per-session random loopback port and is sent only
/// after the listener on that port is confirmed to belong to this runtime's own
/// ssh child, with the link token read over a separate SSH command. `stop()` is
/// synchronous and generation-guarded: after it returns, no status or
/// projection from this runtime reaches `onUpdate`.
@MainActor
public final class RemoteOrganizerRuntime {
  public enum LinkState: Equatable, Sendable {
    case off
    case connecting
    case connected
    case unavailable
  }

  public struct Timing: Sendable {
    public var pollInterval: Duration
    public var reconnectDelay: Duration
    public var tunnelReadyTimeout: Duration
    public var tunnelPollInterval: Duration
    public var requestTimeout: TimeInterval

    public init(
      pollInterval: Duration = .seconds(4),
      reconnectDelay: Duration = .seconds(10),
      tunnelReadyTimeout: Duration = .seconds(35),
      tunnelPollInterval: Duration = .milliseconds(200),
      requestTimeout: TimeInterval = 30
    ) {
      self.pollInterval = pollInterval
      self.reconnectDelay = reconnectDelay
      self.tunnelReadyTimeout = tunnelReadyTimeout
      self.tunnelPollInterval = tunnelPollInterval
      self.requestTimeout = requestTimeout
    }

    public static let standard = Timing()
  }

  public enum LinkError: Error, Equatable, Sendable {
    /// The forward is not up, or its port is not held by our own ssh child.
    case tunnelNotReady
    case tokenUnavailable
    case unauthorized
    case unhealthy
    case transport
    case invalidResponse
    case rejected(reason: String?)
    case server(status: Int, reason: String?)

    /// Link-level failures tear the tunnel down and reconnect later.
    var isLinkLevel: Bool {
      switch self {
      case .tunnelNotReady, .tokenUnavailable, .unauthorized, .unhealthy, .transport: true
      case .invalidResponse, .rejected, .server: false
      }
    }

    var retryable: Bool {
      switch self {
      case .rejected, .invalidResponse: false
      case .server(let status, _): status == 429 || status >= 500
      default: true
      }
    }

    var category: String {
      switch self {
      case .tunnelNotReady: "tunnel"
      case .tokenUnavailable: "token"
      case .unauthorized: "auth"
      case .unhealthy: "health"
      case .transport: "transport"
      case .invalidResponse: "protocol"
      case .rejected: "rejected"
      case .server(let status, _): status >= 500 ? "server" : "client:\(status)"
      }
    }

    var reason: String? {
      switch self {
      case .rejected(let reason), .server(_, let reason): reason
      default: nil
      }
    }
  }

  private struct Health: Decodable {
    let ok: Bool
    let storeID: String?
    /// `wall` in production; anything else is an eval or test configuration.
    let clock: String?
    enum CodingKeys: String, CodingKey {
      case ok
      case storeID = "store_id"
      case clock
    }
  }
  private struct ItemReceipt: Decodable {
    let accepted: Int
    let duplicates: Int
  }
  private struct DecisionReceipt: Decodable {
    let applied: Int
    let rejected: [Rejected]
    struct Rejected: Decodable {
      let index: Int
      let reason: String?
    }
  }
  private struct QuestionReceipt: Decodable {
    let ok: Bool
    /// Present on current services: 200 means the answer's decision applied.
    let applied: Bool?
    let note: String?
  }
  private struct ErrorDetail: Decodable { let detail: String? }
  /// A reply whose body is not read (an acknowledgement); may be empty.
  private struct NoContent: Decodable {}

  private let repository: any RemoteOrganizerRepository
  private let launcher: any RemoteOrganizerTunnelLauncher
  private let http: any RemoteOrganizerHTTPTransport
  /// Reads an image item's stored bytes at send time; without one, image
  /// items are parked instead of sent.
  private let itemAssetReader: (any RemoteOrganizerItemAssetReading)?
  /// Takes the phone entry's inbox in through intake; without one the inbox
  /// is never read.
  private let inbox: (any RemoteOrganizerInboxIngesting)?
  /// In memory only: after a relaunch the organizing device returns every
  /// entry not yet acknowledged, and intake finds those already taken in.
  private var inboxCursor: Int64 = 0
  /// Entries intake refused this launch; left on the organizing device.
  private var refusedInbox = Set<String>()
  /// The organizing device has no inbox (an older service).
  private var inboxUnsupported = false
  private let timing: Timing
  private var onUpdate: ((LinkState, RemoteOrganizerProjection?) -> Void)?
  private var worker: Task<Void, Never>?
  private var tunnel: (any RemoteOrganizerTunnelProcess)?
  /// Held in memory only; never logged, persisted, or passed to a process.
  private var token: String?
  private var generation = 0
  private var stopped = false
  public private(set) var state: LinkState = .off
  /// The organizer's clock mode from its last health check (`wall` in
  /// production); nil until one succeeded or when the service omits it.
  public private(set) var serviceClock: String?

  public init(
    repository: any RemoteOrganizerRepository,
    launcher: any RemoteOrganizerTunnelLauncher,
    http: any RemoteOrganizerHTTPTransport,
    itemAssetReader: (any RemoteOrganizerItemAssetReading)? = nil,
    inbox: (any RemoteOrganizerInboxIngesting)? = nil,
    timing: Timing = .standard,
    onUpdate: @escaping (LinkState, RemoteOrganizerProjection?) -> Void
  ) {
    self.repository = repository
    self.launcher = launcher
    self.http = http
    self.itemAssetReader = itemAssetReader
    self.inbox = inbox
    self.timing = timing
    self.onUpdate = onUpdate
  }

  public var isRunning: Bool { worker != nil && !stopped }

  public func start() {
    guard worker == nil, !stopped else { return }
    generation += 1
    let current = generation
    launcher.cleanUpStaleTunnels()
    publish(.connecting, projection: nil, generation: current)
    worker = Task { [weak self] in await self?.run(generation: current) }
  }

  /// Revocation. Synchronous: when this returns the worker is cancelled, the
  /// HTTP transport is cancelled, the ssh child is gone, and no later callback
  /// from this runtime can publish a status or projection.
  public func stop() {
    stopped = true
    generation += 1
    onUpdate = nil
    worker?.cancel()
    worker = nil
    http.cancelAll()
    closeTunnel()
    token = nil
    state = .off
  }

  // MARK: - Worker

  private func isCurrent(_ generation: Int) -> Bool {
    !stopped && generation == self.generation && !Task.isCancelled
  }

  private func ensureCurrent(_ generation: Int) throws {
    guard isCurrent(generation) else { throw CancellationError() }
  }

  private func publish(
    _ newState: LinkState, projection: RemoteOrganizerProjection?, generation: Int
  ) {
    guard isCurrent(generation), let onUpdate else { return }
    state = newState
    onUpdate(newState, projection)
  }

  private func run(generation: Int) async {
    while isCurrent(generation) {
      do {
        try await repository.resetRemoteLeases()
        _ = try await repository.recoverRemoteDecisionsToOutbox()
        _ = try await repository.reconcileRemoteItems()
        try ensureCurrent(generation)
        try await ensureTunnel(generation: generation)
        let health: Health = try await call(
          "GET", "/v1/health", body: nil, generation: generation, timeout: 6
        )
        guard health.ok else { throw LinkError.unhealthy }
        serviceClock = health.clock
        if let storeID = health.storeID {
          _ = try await repository.observeRemoteStoreID(storeID)
        }
        try await publishProjection(.connected, generation: generation)
        while isCurrent(generation) {
          if try await deliverNextItem(generation: generation) { continue }
          if try await deliverNextDecision(generation: generation) { continue }
          // What the phone left on the organizing device becomes a local
          // item first; it is then sent like any item (next pass).
          if try await pullInbox(generation: generation) { continue }
          try await pullState(generation: generation)
          try await publishProjection(.connected, generation: generation)
          try await Task.sleep(for: timing.pollInterval)
          // Pick up decisions restored by an archive import and sessions
          // completed through recovery paths without restarting the link.
          _ = try await repository.recoverRemoteDecisionsToOutbox()
          _ = try await repository.reconcileRemoteItems()
        }
      } catch {
        guard isCurrent(generation) else { return }
        closeTunnel()
        let projection = try? await repository.remoteProjection()
        publish(.unavailable, projection: projection, generation: generation)
        try? await Task.sleep(for: timing.reconnectDelay)
      }
    }
  }

  private func publishProjection(_ state: LinkState, generation: Int) async throws {
    let projection = try await repository.remoteProjection()
    publish(state, projection: projection, generation: generation)
  }

  private func ensureTunnel(generation: Int) async throws {
    if let tunnel, tunnel.isRunning,
      launcher.listenerIsOwned(by: tunnel.processIdentifier, port: tunnel.localPort)
    {
      if token == nil { try await loadToken(generation: generation) }
      return
    }
    closeTunnel()
    let port = try launcher.freeLoopbackPort()
    let process = try await launcher.launchForward(localPort: port)
    guard isCurrent(generation) else {
      process.terminateAndWait()
      throw CancellationError()
    }
    tunnel = process
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timing.tunnelReadyTimeout)
    while true {
      try ensureCurrent(generation)
      guard process.isRunning else { throw LinkError.tunnelNotReady }
      if launcher.listenerIsOwned(by: process.processIdentifier, port: port) { break }
      guard clock.now < deadline else { throw LinkError.tunnelNotReady }
      try await Task.sleep(for: timing.tunnelPollInterval)
    }
    if token == nil { try await loadToken(generation: generation) }
  }

  private func loadToken(generation: Int) async throws {
    let fetched: String
    do { fetched = try await launcher.fetchLinkToken() } catch {
      try ensureCurrent(generation)
      throw LinkError.tokenUnavailable
    }
    try ensureCurrent(generation)
    guard RemoteOrganizerSSHCommand.isValidLinkToken(fetched) else {
      throw LinkError.tokenUnavailable
    }
    token = fetched
  }

  private func closeTunnel() {
    tunnel?.terminateAndWait()
    tunnel = nil
  }

  private func call<Value: Decodable>(
    _ method: String, _ path: String, body: Data?, generation: Int,
    timeout: TimeInterval? = nil
  ) async throws -> Value {
    try ensureCurrent(generation)
    // Nothing is sent unless the port is still held by our own ssh child.
    guard let tunnel, tunnel.isRunning,
      launcher.listenerIsOwned(by: tunnel.processIdentifier, port: tunnel.localPort)
    else { throw LinkError.tunnelNotReady }
    guard let token else { throw LinkError.tokenUnavailable }
    let response: RemoteOrganizerHTTPResponse
    do {
      response = try await http.send(
        RemoteOrganizerHTTPRequest(
          method: method, port: tunnel.localPort, path: path, body: body,
          token: token, timeout: timeout ?? timing.requestTimeout
        )
      )
    } catch {
      try ensureCurrent(generation)
      throw LinkError.transport
    }
    try ensureCurrent(generation)
    if response.status == 401 {
      self.token = nil
      throw LinkError.unauthorized
    }
    guard (200..<300).contains(response.status) else {
      let detail = (try? JSONDecoder().decode(ErrorDetail.self, from: response.body))?.detail
      throw LinkError.server(status: response.status, reason: detail.map { String($0.prefix(200)) })
    }
    if Value.self == NoContent.self, let empty = NoContent() as? Value { return empty }
    do { return try JSONDecoder().decode(Value.self, from: response.body) } catch {
      throw LinkError.invalidResponse
    }
  }

  private static func backoff(retryCount: Int) -> TimeInterval {
    min(300.0, pow(2.0, Double(min(retryCount, 7))) * 3.0)
  }

  private func deliverNextItem(generation: Int) async throws -> Bool {
    guard let delivery = try await repository.claimNextRemoteItem(now: Date()) else {
      return false
    }
    try ensureCurrent(generation)
    let body: Data
    do {
      body = try await Self.wireBody(for: delivery, reader: itemAssetReader)
    } catch {
      // The stored image is missing, changed, linked, or too large: keep the
      // item on the Mac, parked until its next change, and carry on.
      try ensureCurrent(generation)
      try await repository.markRemoteItemFailed(delivery, category: "asset", retryAt: nil)
      return true
    }
    do {
      // A file item may carry up to 25 MiB (about 33 MB as base64): its
      // upload gets time in proportion to its size.
      let receipt: ItemReceipt = try await call(
        "POST", "/v1/items", body: body, generation: generation,
        timeout: max(timing.requestTimeout, 30 + Double(body.count) / 500_000)
      )
      guard receipt.accepted + receipt.duplicates == 1 else {
        throw LinkError.invalidResponse
      }
      try await repository.markRemoteItemDelivered(delivery)
    } catch let error as LinkError {
      try ensureCurrent(generation)
      try await repository.markRemoteItemFailed(
        delivery, category: error.category,
        retryAt: error.retryable
          ? Date().addingTimeInterval(Self.backoff(retryCount: delivery.retryCount)) : nil
      )
      if error.isLinkLevel { throw error }
    }
    return true
  }

  /// The `/v1/items` body for one claimed item. Each local image or file
  /// reference is replaced by its verified bytes; nothing else is added. Nonisolated, so
  /// reading up to 12 MB happens off the main actor.
  private nonisolated static func wireBody(
    for delivery: RemoteOrganizerItemDelivery,
    reader itemAssetReader: (any RemoteOrganizerItemAssetReading)?
  ) async throws -> Data {
    let stored = try JSONDecoder().decode(RemoteOrganizerItem.self, from: delivery.payload)
    let hasAssets =
      stored.imageAsset != nil || stored.fileAsset != nil
      || !(stored.extraImageAssets ?? []).isEmpty
    var imageBase64: String?
    var fileBase64: String?
    var extraImagesBase64: [String]?
    if hasAssets {
      guard let reader = itemAssetReader else { throw LinkError.invalidResponse }
      imageBase64 = try stored.imageAsset.map { try reader.imageData(for: $0).base64EncodedString() }
      fileBase64 = try stored.fileAsset.map { try reader.fileData(for: $0).base64EncodedString() }
      extraImagesBase64 = try stored.extraImageAssets.map { assets in
        try assets.map { try reader.imageData(for: $0).base64EncodedString() }
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let item = try encoder.encode(
      stored.wireItem(
        imageBase64: imageBase64, fileBase64: fileBase64, extraImagesBase64: extraImagesBase64))
    let object = try JSONSerialization.jsonObject(with: item)
    return try JSONSerialization.data(withJSONObject: ["items": [object]])
  }

  private func deliverNextDecision(generation: Int) async throws -> Bool {
    guard let job = try await repository.claimNextRemoteDecision(now: Date()) else {
      return false
    }
    try ensureCurrent(generation)
    let id = job.decision.decisionID
    do {
      switch job.kind {
      case .decision:
        try await postDecision(job.decision, generation: generation)
      case .question:
        do {
          try await answerQuestion(job.decision, generation: generation)
        } catch LinkError.server(let status, _) where status == 404 || status == 409 {
          // The question expired or is unknown on the Spark. The user's answer
          // still stands, so it goes out as the equivalent plain decision.
          try await postDecision(job.decision, generation: generation)
        }
      }
      try await repository.markRemoteDecisionDelivered(id: id)
    } catch let error as LinkError {
      try ensureCurrent(generation)
      try await repository.markRemoteDecisionFailed(
        id: id, category: error.category, reason: error.reason,
        retryAt: error.retryable
          ? Date().addingTimeInterval(Self.backoff(retryCount: job.retryCount)) : nil
      )
      if error.isLinkLevel { throw error }
    }
    return true
  }

  private func postDecision(_ decision: RemoteOrganizerDecision, generation: Int) async throws {
    let encoded = try JSONEncoder().encode(decision)
    let object = try JSONSerialization.jsonObject(with: encoded)
    let body = try JSONSerialization.data(withJSONObject: ["decisions": [object]])
    let receipt: DecisionReceipt = try await call(
      "POST", "/v1/decisions", body: body, generation: generation
    )
    guard receipt.applied == 1, receipt.rejected.isEmpty else {
      throw LinkError.rejected(
        reason: receipt.rejected.first?.reason.map { String($0.prefix(200)) })
    }
  }

  private func answerQuestion(_ decision: RemoteOrganizerDecision, generation: Int) async throws {
    guard let questionID = decision.questionID, let answer = decision.answer,
      let escapedID = questionID.addingPercentEncoding(
        withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
      )
    else { throw LinkError.invalidResponse }
    let body = try JSONSerialization.data(withJSONObject: ["answer": answer])
    let receipt: QuestionReceipt = try await call(
      "POST", "/v1/questions/\(escapedID)/answer", body: body, generation: generation
    )
    guard receipt.ok else { throw LinkError.rejected(reason: nil) }
    if receipt.applied != true, receipt.note == "already answered" {
      // An older service answers a replay this way even when the decision
      // was never applied; confirm through the equivalent plain decision.
      throw LinkError.server(status: 409, reason: "already answered")
    }
  }

  /// One page of the inbox: each entry is committed locally through intake,
  /// then acknowledged so the organizing device deletes it. An entry intake
  /// refuses stays there (skipped until the next launch); a local failure
  /// leaves the rest of the page for the next poll. Returns true when
  /// something was taken in.
  private func pullInbox(generation: Int) async throws -> Bool {
    guard let inbox, !inboxUnsupported else { return false }
    let page: RemoteOrganizerInboxPage
    do {
      page = try await call(
        "GET", "/v1/inbox?since=\(inboxCursor)", body: nil, generation: generation)
    } catch LinkError.server(let status, _) where status == 404 || status == 405 {
      inboxUnsupported = true
      return false
    } catch LinkError.invalidResponse {
      return false
    }
    var committed = false
    var finished = true
    for entry in page.entries where !refusedInbox.contains(entry.inboxID) {
      try ensureCurrent(generation)
      let outcome: RemoteOrganizerInboxOutcome
      do { outcome = try await inbox.ingest(entry) } catch {
        try ensureCurrent(generation)
        finished = false
        break
      }
      try ensureCurrent(generation)
      guard outcome.isCommitted else {
        refusedInbox.insert(entry.inboxID)
        continue
      }
      committed = true
      try await acknowledgeInbox(entry.inboxID, generation: generation)
    }
    if finished, let cursor = page.cursor, cursor > inboxCursor { inboxCursor = cursor }
    if committed { _ = try await repository.reconcileRemoteItems() }
    return committed
  }

  private func acknowledgeInbox(_ inboxID: String, generation: Int) async throws {
    guard
      let escaped = inboxID.addingPercentEncoding(
        withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#")))
    else { return }
    do {
      let _: NoContent = try await call(
        "POST", "/v1/inbox/\(escaped)/ack", body: nil, generation: generation)
    } catch LinkError.server(let status, _) where status == 404 {
      // Already gone from the organizing device.
    }
  }

  private func pullState(generation: Int) async throws {
    var cursor = try await repository.remoteCursor()
    for _ in 0..<2 {
      let state: RemoteOrganizerState = try await call(
        "GET", "/v1/state?since=\(cursor)", body: nil, generation: generation
      )
      guard try await repository.applyRemoteState(state) else { return }
      // The Spark's store was reset; items are queued again, pull everything.
      try ensureCurrent(generation)
      cursor = 0
    }
  }
}
