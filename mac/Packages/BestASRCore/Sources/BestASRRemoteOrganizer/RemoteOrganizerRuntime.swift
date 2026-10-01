import BestASRDomain
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Owns one SSH forward and one HTTP transport for organizing on the user's
/// own Spark. It is created only after the user enables the link from an
/// allowed data root, and it is single-use: `stop()` ends it for good.
///
/// Every request goes to a per-session random loopback port and is sent only
/// after the listener on that port is confirmed to belong to this runtime's own
/// ssh child, with the link token read over a separate SSH command. `stop()` is
/// synchronous and generation-guarded: after it returns, no status or
/// projection from this runtime reaches `onUpdate`.
///
/// Privacy contract v6: the first data call after the token is
/// `POST /v1/unlock` with this library's key (into the organizing device's
/// memory only); then queued deletions, decisions and items, in that order.
/// Every text field is masked when the wire body is built, every screenshot
/// is redacted, audio and video never leave as bytes, and `finish(sending:)`
/// ends the runtime with one last request (lock on revocation, wipe on
/// "forget me") over the still-owned forward.
@MainActor
public final class RemoteOrganizerRuntime {
  public enum LinkState: Equatable, Sendable {
    case off
    case connecting
    case connected
    case unavailable
    /// The organizing device holds a store locked with another key
    /// (`foreignKeyID`); nothing is sent until it forgets that content.
    case wrongKey
    /// The organizing device cannot lock its store (no `/v1/unlock`):
    /// nothing is sent to it.
    case unsupported
  }

  /// The last request a finishing runtime sends.
  public enum FinalRequest: Equatable, Sendable {
    /// `POST /v1/lock`: close the store and drop the key from memory.
    case lock
    /// `POST /v1/wipe`: delete the store whose key ID this is.
    case wipe(keyID: String)
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
    /// 423: the store is locked (the organizing device restarted); the link
    /// reconnects and unlocks again.
    case locked
    /// Audio or video, or a screenshot that could not be redacted: it stays
    /// on the Mac.
    case staysLocal
    /// 409 `wrong_key` from `/v1/unlock`.
    case wrongKey(onDisk: String?)

    /// Link-level failures tear the tunnel down and reconnect later.
    var isLinkLevel: Bool {
      switch self {
      case .tunnelNotReady, .tokenUnavailable, .unauthorized, .unhealthy, .transport, .locked:
        true
      case .invalidResponse, .rejected, .server, .staysLocal, .wrongKey: false
      }
    }

    var retryable: Bool {
      switch self {
      case .rejected, .invalidResponse, .staysLocal, .wrongKey: false
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
      case .locked: "locked"
      case .staysLocal: "local-only"
      case .wrongKey: "wrong-key"
      case .server(410, _): "deleted"
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
    /// Contract v6: whether the store is locked, and the key ID of the store
    /// on disk (nil before the first unlock).
    let locked: Bool?
    let keyID: String?
    enum CodingKeys: String, CodingKey {
      case ok
      case storeID = "store_id"
      case clock, locked
      case keyID = "key_id"
    }
  }
  private struct UnlockReceipt: Decodable {
    let locked: Bool
    let keyID: String?
    enum CodingKeys: String, CodingKey {
      case locked
      case keyID = "key_id"
    }
  }
  private struct DeletionReceipt: Decodable { let deleted: Bool }
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
  /// `{"detail": …}` (FastAPI) or `{"error": …, "key_id": …}` (contract v6).
  private struct ErrorDetail: Decodable {
    let detail: String?
    let error: String?
    let keyID: String?
    enum CodingKeys: String, CodingKey {
      case detail, error
      case keyID = "key_id"
    }
  }
  /// A reply whose body is not read (an acknowledgement); may be empty.
  private struct NoContent: Decodable {}

  private let repository: any RemoteOrganizerRepository
  private let launcher: any RemoteOrganizerTunnelLauncher
  private let http: any RemoteOrganizerHTTPTransport
  /// This library's key; only `libraryKey` crosses the link, in `unlock`.
  private let keys: OrganizerKeyMaterial
  private let masking: RemoteOrganizerWireMasking
  /// Reads an image item's stored bytes at send time; without one, image
  /// items are parked instead of sent.
  private let itemAssetReader: (any RemoteOrganizerItemAssetReading)?
  /// Paints identifiers over a screenshot's send copy; without one, image
  /// items are parked instead of sent.
  private let imageRedactor: (any RemoteOrganizerImageRedacting)?
  /// Makes a file item's send copy (pictures redacted, recordings emptied;
  /// privacy review F3); without one, file items with bytes stay on the Mac.
  private let fileSanitizer: (any RemoteOrganizerFileSanitizing)?
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
  /// Called on the main actor after a sealed phone entry that can never be
  /// taken in was acknowledged (so it is counted once, not per pull).
  public var onInboxDiscarded: ((RemoteOrganizerInboxDiscard) -> Void)?
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
  /// While `wrongKey`: the key ID of the store the organizing device holds.
  public private(set) var foreignKeyID: String?
  /// The key ID this runtime unlocks with.
  public var keyID: String { keys.keyID }

  public init(
    repository: any RemoteOrganizerRepository,
    launcher: any RemoteOrganizerTunnelLauncher,
    http: any RemoteOrganizerHTTPTransport,
    keys: OrganizerKeyMaterial,
    itemAssetReader: (any RemoteOrganizerItemAssetReading)? = nil,
    imageRedactor: (any RemoteOrganizerImageRedacting)? = nil,
    fileSanitizer: (any RemoteOrganizerFileSanitizing)? = nil,
    inbox: (any RemoteOrganizerInboxIngesting)? = nil,
    timing: Timing = .standard,
    onUpdate: @escaping (LinkState, RemoteOrganizerProjection?) -> Void
  ) {
    self.repository = repository
    self.launcher = launcher
    self.http = http
    self.keys = keys
    masking = RemoteOrganizerWireMasking(keys: keys)
    self.itemAssetReader = itemAssetReader
    self.imageRedactor = imageRedactor
    self.fileSanitizer = fileSanitizer
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
    onInboxDiscarded = nil
    worker?.cancel()
    worker = nil
    http.cancelAll()
    closeTunnel()
    token = nil
    state = .off
  }

  /// Synchronously stops the worker: no further data request leaves and no
  /// status or projection is published. The forward and the token stay for
  /// `finish(sending:)`. Idempotent.
  public func halt() {
    generation += 1
    onUpdate = nil
    onInboxDiscarded = nil
    worker?.cancel()
    worker = nil
  }

  /// Ends the runtime like `stop()`, but first sends one last request over
  /// the forward while it is still up and still held by our own ssh child:
  /// `lock` when the user turns the link off (best effort), `wipe` for "让
  /// Spark 忘掉". From the moment this is called no worker request can leave
  /// and no status or projection is published; after `timeout` the request
  /// is abandoned. Returns the reply, or nil when it could not be sent.
  @discardableResult
  public func finish(sending request: FinalRequest, timeout: TimeInterval) async
    -> RemoteOrganizerHTTPResponse?
  {
    halt()
    var response: RemoteOrganizerHTTPResponse?
    if !stopped, let tunnel, tunnel.isRunning,
      launcher.listenerIsOwned(by: tunnel.processIdentifier, port: tunnel.localPort),
      let token
    {
      let (path, body): (String, Data)
      switch request {
      case .lock:
        (path, body) = ("/v1/lock", Data("{}".utf8))
      case .wipe(let keyID):
        (path, body) = (
          "/v1/wipe", (try? JSONSerialization.data(withJSONObject: ["key_id": keyID])) ?? Data()
        )
      }
      let http = self.http
      let outgoing = RemoteOrganizerHTTPRequest(
        method: "POST", port: tunnel.localPort, path: path, body: body, token: token,
        timeout: timeout, accessProof: keys.accessProof)
      // A hard bound: after `timeout` the answer is no longer waited for and
      // every request of this transport is cancelled, whatever the
      // transport's own timer does.
      let isLock = request == .lock
      response = await withCheckedContinuation { continuation in
        let once = ResumeOnce(continuation)
        Task.detached {
          var answer = try? await http.send(outgoing)
          // A lock that failed is sent once more within the same bound
          // (privacy review F1); the organizing device also locks itself when
          // the Mac stops asking (its unlock lease).
          if isLock, answer.map({ !(200..<300).contains($0.status) }) ?? true {
            answer = try? await http.send(outgoing)
          }
          once.resume(answer)
        }
        Task.detached {
          try? await Task.sleep(for: .seconds(timeout))
          once.resume(nil)
          http.cancelAll()
        }
      }
    }
    // `stop()` may have run meanwhile and ended everything already.
    if !stopped {
      stopped = true
      http.cancelAll()
      closeTunnel()
      token = nil
      state = .off
    }
    return response
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
        // The first data call: unlock with this library's key. A store the
        // health check already names as another key's is not sent this key.
        switch try await unlock(health: health, generation: generation) {
        case .unlocked:
          foreignKeyID = nil
        case .wrongKey(let onDisk):
          foreignKeyID = onDisk
          let projection = try? await repository.remoteProjection()
          publish(.wrongKey, projection: projection, generation: generation)
          try await Task.sleep(for: timing.reconnectDelay)
          continue
        case .unsupported:
          let projection = try? await repository.remoteProjection()
          publish(.unsupported, projection: projection, generation: generation)
          closeTunnel()
          try await Task.sleep(for: timing.reconnectDelay)
          continue
        }
        let storeID: String?
        if let known = health.storeID, health.locked != true {
          storeID = known
        } else {
          // Locked, the health check could not name the store; now it can.
          let unlocked: Health = try await call(
            "GET", "/v1/health", body: nil, generation: generation, timeout: 6)
          storeID = unlocked.storeID
        }
        if let storeID {
          _ = try await repository.observeRemoteStoreID(storeID)
        }
        try await publishProjection(.connected, generation: generation)
        while isCurrent(generation) {
          // Contract v6 order: deletions, then decisions, then items.
          if try await deliverNextDeletion(generation: generation) { continue }
          if try await deliverNextDecision(generation: generation) { continue }
          if try await deliverNextItem(generation: generation) { continue }
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

  private enum UnlockOutcome {
    case unlocked
    case wrongKey(String?)
    case unsupported
  }

  /// `POST /v1/unlock` with the library key (64 hex characters): the key
  /// goes only into the organizing device's memory. 409 means its store
  /// belongs to another key; 404/405 means a service that cannot lock its
  /// store, which is never sent anything.
  private func unlock(health: Health, generation: Int) async throws -> UnlockOutcome {
    if let onDisk = health.keyID, onDisk != keys.keyID { return .wrongKey(onDisk) }
    let body = try JSONSerialization.data(withJSONObject: ["key": keys.libraryKeyHex])
    do {
      let receipt: UnlockReceipt = try await call(
        "POST", "/v1/unlock", body: body, generation: generation, timeout: 30)
      guard !receipt.locked, receipt.keyID == nil || receipt.keyID == keys.keyID else {
        throw LinkError.invalidResponse
      }
      return .unlocked
    } catch LinkError.server(let status, _) where status == 404 || status == 405 {
      return .unsupported
    } catch LinkError.wrongKey(let onDisk) {
      return .wrongKey(onDisk)
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
          token: token, timeout: timeout ?? timing.requestTimeout,
          accessProof: keys.accessProof
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
      let error = try? JSONDecoder().decode(ErrorDetail.self, from: response.body)
      if response.status == 423 { throw LinkError.locked }
      // The store no longer takes this key's access proof (it locked and was opened again, or restarted):
      // reconnect and unlock, like a locked store (privacy review F1).
      if response.status == 403, error?.error == "access" { throw LinkError.locked }
      if response.status == 409, error?.error == "wrong_key" {
        throw LinkError.wrongKey(onDisk: error?.keyID)
      }
      let detail = error?.detail ?? error?.error
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

  /// When a failed send may be tried again: right away after a locked store
  /// (the reconnect unlocks it first), with backoff for other retryable
  /// failures, never for a permanent one.
  private static func retryDate(for error: LinkError, retryCount: Int) -> Date? {
    if error == .locked { return Date() }
    return error.retryable ? Date().addingTimeInterval(backoff(retryCount: retryCount)) : nil
  }

  private func deliverNextItem(generation: Int) async throws -> Bool {
    guard let delivery = try await repository.claimNextRemoteItem(now: Date()) else {
      return false
    }
    try ensureCurrent(generation)
    let wire: (body: Data, record: RemoteOrganizerMaskRecord)
    do {
      wire = try await Self.wireBody(
        for: delivery, reader: itemAssetReader, redactor: imageRedactor,
        sanitizer: fileSanitizer, masking: masking)
    } catch {
      // The stored image is missing, changed, linked, too large, or could not
      // be redacted, or the item is audio or video: keep it on the Mac,
      // parked until its next change, and carry on. A failure that may pass
      // (on-device recognition refused the request) is tried again later.
      try ensureCurrent(generation)
      let category = (error as? LinkError) == .staysLocal ? "local-only" : "asset"
      let transient = (error as? any RemoteOrganizerAssetErrorClassifying)?.isTransient == true
      try await repository.markRemoteItemFailed(
        delivery, category: category,
        retryAt: transient
          ? Date().addingTimeInterval(Self.backoff(retryCount: delivery.retryCount)) : nil)
      return true
    }
    try ensureCurrent(generation)
    // What each placeholder stands for is in the library before the masked
    // content leaves.
    try await repository.recordRemoteMasks(wire.record)
    let body = wire.body
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
        retryAt: Self.retryDate(for: error, retryCount: delivery.retryCount))
      if error.isLinkLevel { throw error }
    }
    return true
  }

  /// The `/v1/items` body for one claimed item and what its placeholders
  /// stand for. Every text field is masked; each local image reference is
  /// replaced by its verified, redacted send copy and each file reference by
  /// its verified bytes; audio and video never leave. Nonisolated, so reading
  /// up to 25 MB and recognizing a screenshot's text happen off the main actor.
  nonisolated static func wireBody(
    for delivery: RemoteOrganizerItemDelivery,
    reader itemAssetReader: (any RemoteOrganizerItemAssetReading)?,
    redactor: (any RemoteOrganizerImageRedacting)?,
    sanitizer: (any RemoteOrganizerFileSanitizing)? = nil,
    masking: RemoteOrganizerWireMasking
  ) async throws -> (body: Data, record: RemoteOrganizerMaskRecord) {
    let stored = try JSONDecoder().decode(RemoteOrganizerItem.self, from: delivery.payload)
    if isAudioOrVideo(uniformType: stored.uniformType, mediaType: stored.mediaType) {
      throw LinkError.staysLocal
    }
    let hasAssets =
      stored.imageAsset != nil || stored.fileAsset != nil
      || !(stored.extraImageAssets ?? []).isEmpty
    var imageBase64: String?
    var fileBase64: String?
    var extraImagesBase64: [String]?
    var imageDigest: String?
    var fileCopy: RemoteOrganizerFileSendCopy?
    if hasAssets {
      guard let reader = itemAssetReader else { throw LinkError.invalidResponse }
      func sendCopy(_ asset: RemoteOrganizerImageAsset) throws -> Data {
        guard let redactor else { throw LinkError.staysLocal }
        let data = try reader.imageData(for: asset)
        guard !MediaContentSniffer.isAudioOrVideo(data) else { throw LinkError.staysLocal }
        return try redactor.redactedSendCopy(of: data, mediaType: asset.mediaType)
      }
      let main = try stored.imageAsset.map(sendCopy)
      let frames = try stored.extraImageAssets.map { try $0.map(sendCopy) }
      if let main {
        // The digest of what is sent: after redaction (contract §4).
        let digests = ([main] + (frames ?? [])).map { hex(SHA256.hash(data: $0)) }
        imageDigest =
          digests.count == 1 ? digests[0] : hex(SHA256.hash(data: Data(digests.joined().utf8)))
      }
      imageBase64 = main?.base64EncodedString()
      extraImagesBase64 = frames?.map { $0.base64EncodedString() }
      if let asset = stored.fileAsset {
        let data = try reader.fileData(for: asset)
        guard !MediaContentSniffer.isAudioOrVideo(data) else { throw LinkError.staysLocal }
        // What leaves is the send copy: pictures redacted, recordings emptied
        // (privacy review F3). No sanitizer, or one that cannot make the
        // copy: the item stays on the Mac.
        guard let sanitizer else { throw LinkError.staysLocal }
        let copy: RemoteOrganizerFileSendCopy
        do {
          copy = try sanitizer.sendCopy(of: data, filename: stored.filename ?? "file")
        } catch let error as any RemoteOrganizerAssetErrorClassifying where error.isTransient {
          throw error
        } catch {
          throw LinkError.staysLocal
        }
        fileCopy = copy
        fileBase64 = copy.data.base64EncodedString()
      }
    }
    // The digest of what is sent (an image after redaction, a file's send copy).
    let sentDigest = imageDigest ?? fileCopy.map { hex(SHA256.hash(data: $0.data)) }
    let (masked, record) = masking.mask(stored, sha256: sentDigest)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let item = try encoder.encode(
      masked.wireItem(
        imageBase64: imageBase64, fileBase64: fileBase64, extraImagesBase64: extraImagesBase64))
    guard var object = try JSONSerialization.jsonObject(with: item) as? [String: Any] else {
      throw LinkError.invalidResponse
    }
    if let fileCopy {
      object["size"] = fileCopy.data.count
      // Only then may the organizing device read pictures inside the file.
      if fileCopy.picturesRedacted { object["pictures_redacted"] = true }
    }
    return (try JSONSerialization.data(withJSONObject: ["items": [object]]), record)
  }

  /// Audio or video by its declared type, whatever the file is called.
  nonisolated static func isAudioOrVideo(uniformType: String?, mediaType: String?) -> Bool {
    if let mediaType = mediaType?.lowercased(),
      mediaType.hasPrefix("audio/") || mediaType.hasPrefix("video/")
    {
      return true
    }
    if let uniformType, let type = UTType(uniformType), type.conforms(to: .audiovisualContent) {
      return true
    }
    if let mediaType, let type = UTType(mimeType: mediaType),
      type.conforms(to: .audiovisualContent)
    {
      return true
    }
    return false
  }

  nonisolated static func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  /// One queued deletion (`DELETE /v1/items/{id}`): the organizing device
  /// purges the item across every revision and keeps a content-free
  /// tombstone. A deletion carries no content, so a failure only waits.
  private func deliverNextDeletion(generation: Int) async throws -> Bool {
    guard let itemID = try await repository.claimNextRemoteDeletion(now: Date()) else {
      return false
    }
    try ensureCurrent(generation)
    guard
      let escaped = itemID.addingPercentEncoding(
        withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#")))
    else {
      try await repository.markRemoteDeletionSent(itemID: itemID)
      return true
    }
    do {
      let receipt: DeletionReceipt = try await call(
        "DELETE", "/v1/items/\(escaped)", body: nil, generation: generation)
      guard receipt.deleted else { throw LinkError.invalidResponse }
      try await repository.markRemoteDeletionSent(itemID: itemID)
    } catch let error as LinkError {
      try ensureCurrent(generation)
      try await repository.markRemoteDeletionFailed(
        itemID: itemID,
        retryAt: error == .locked ? Date() : Date().addingTimeInterval(Self.backoff(retryCount: 1)))
      if error.isLinkLevel { throw error }
    }
    return true
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
        retryAt: Self.retryDate(for: error, retryCount: job.retryCount))
      if error.isLinkLevel { throw error }
    }
    return true
  }

  private func postDecision(_ decision: RemoteOrganizerDecision, generation: Int) async throws {
    // A title or a name the user typed is masked like any text; the stored
    // decision keeps what they typed.
    let (wire, record) = masking.mask(decision)
    if !record.entries.isEmpty { try await repository.recordRemoteMasks(record) }
    try ensureCurrent(generation)
    let encoded = try JSONEncoder().encode(wire)
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
      if case .discarded(let reason) = outcome {
        // Sealed to a key this Mac no longer has, or not an item: it can
        // never be taken in, so the organizing device deletes it and the
        // status counts it (PHONE-CONTRACT §5.4).
        try await acknowledgeInbox(entry.inboxID, generation: generation)
        try ensureCurrent(generation)
        onInboxDiscarded?(reason)
        continue
      }
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

/// Resumes a continuation with the first value only.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Never>?

  init(_ continuation: CheckedContinuation<Value, Never>) {
    self.continuation = continuation
  }

  func resume(_ value: Value) {
    let pending = lock.withLock { () -> CheckedContinuation<Value, Never>? in
      defer { continuation = nil }
      return continuation
    }
    pending?.resume(returning: value)
  }
}
