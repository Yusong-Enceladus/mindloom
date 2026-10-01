import BestASRDomain
import CryptoKit
import Darwin
import Foundation

/// The user's "on" choice for one data root, kept outside the library's
/// database. The link resumes at launch only when this marker AND the
/// library's enable watermark both exist, so turning the link off fails
/// closed: removing a marker needs no free space (a full disk cannot keep the
/// link on), and if the library write that clears the watermark and outbox
/// does not commit, the missing marker still stops the next launch from
/// resuming, and that launch retries the revocation before anything starts.
@MainActor
public protocol RemoteOrganizerLinkIntentStore: AnyObject {
  /// True only after an enable committed in the library and was recorded.
  var onRecorded: Bool { get }
  func recordOn() throws
  /// Must not throw when the marker is already absent.
  func clearOn() throws
}

/// One small marker file per data root in the app's organizer-link state
/// directory (outside every library), keyed by the kernel's canonical path of
/// the root (`F_GETPATH`: symlinks such as `/tmp`, `/.nofollow` spellings and
/// case variants all give the same key).
@MainActor
public final class RemoteOrganizerLinkIntentFile: RemoteOrganizerLinkIntentStore {
  private let url: URL

  public init(stateDirectory: URL, dataRoot: URL) {
    url = stateDirectory.appendingPathComponent("link-on-\(Self.rootIdentity(dataRoot))")
  }

  /// The data root's identity hash: its kernel-canonical path, hashed. Also
  /// the Keychain account of the root's organizing-link key.
  public nonisolated static func rootIdentity(_ dataRoot: URL) -> String {
    let standardized = dataRoot.standardizedFileURL.path
    let canonical =
      BestASRDataRootSelection.kernelPath(ofExisting: standardized)
      ?? dataRoot.standardizedFileURL.resolvingSymlinksInPath().path
    return SHA256.hash(data: Data(canonical.utf8))
      .prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  public var onRecorded: Bool { FileManager.default.fileExists(atPath: url.path) }

  public func recordOn() throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try Data().write(to: url, options: [.atomic])
  }

  public func clearOn() throws {
    guard unlink(url.path) == 0 || errno == ENOENT else {
      throw CocoaError(.fileWriteUnknown)
    }
  }
}

/// In-memory intent for tests and previews.
@MainActor
public final class RemoteOrganizerMemoryLinkIntent: RemoteOrganizerLinkIntentStore {
  public var onRecorded: Bool
  public var failWrites = false

  public init(onRecorded: Bool = false) {
    self.onRecorded = onRecorded
  }

  public func recordOn() throws {
    if failWrites { throw CocoaError(.fileWriteUnknown) }
    onRecorded = true
  }

  public func clearOn() throws {
    if failWrites { throw CocoaError(.fileWriteUnknown) }
    onRecorded = false
  }
}

/// The link controller the app asks to lock the organizing device's store
/// when it quits (privacy review F1); set by the app, weakly held.
@MainActor
public enum RemoteOrganizerQuitLock {
  public static weak var controller: RemoteOrganizerLinkController?
}

/// The app-facing switch for the own-device organizer link. It applies the
/// data-provenance guard, persists the per-library enable watermark, and owns
/// at most one runtime at a time.
///
/// Semantics (PRD §0.3.8): turning the link off stops all sending, ends the
/// tunnel and clears the pending outbox. Items captured while the link is off
/// are never sent automatically.
///
/// Privacy contract v6: the library key is created on the first enable and
/// kept in the key store (the Keychain); turning the link off first asks the
/// organizing device to lock its store (best effort, 2 s); "让 Spark 忘掉"
/// wipes the organizing device's store and, for this library's own content,
/// destroys the key.
@MainActor
public final class RemoteOrganizerLinkController {
  public enum Status: Equatable, Sendable {
    case off
    case refused(RemoteOrganizerDataProvenance.Verdict)
    case connecting
    case connected
    case unavailable
    case storageUnavailable
    /// The organizing device's store belongs to another key (its key ID).
    case wrongKey(String?)
    /// The organizing device cannot lock its store; nothing is sent.
    case unsupportedService
    /// The key store (Keychain) cannot be read or written; nothing is sent.
    case keyUnavailable
  }

  /// Whose content "让 Spark 忘掉" wipes.
  public enum ForgetTarget: Equatable, Sendable {
    /// This library's content: afterwards its key is destroyed and a new one
    /// is made for the (then empty) store.
    case mine
    /// A store locked with another key (`Status.wrongKey`); this library's
    /// key is kept.
    case otherKey(String)
  }

  public enum ForgetOutcome: Equatable, Sendable {
    case forgotten
    /// The link is not on and connected.
    case notConnected
    /// The organizing device did not confirm (its status, if it answered).
    case refused(Int?)
    /// Forgotten there, but the library could not record it.
    case storageUnavailable
    /// Forgotten there, but the old key could not be destroyed here (the
    /// key store refused): it is never used again and the link stays
    /// stopped until the key store works (privacy review F11).
    case keyNotDestroyed
  }

  /// Best-effort lock on revocation (contract §6).
  public static let lockTimeout: TimeInterval = 2
  public static let wipeTimeout: TimeInterval = 30

  public typealias RuntimeFactory =
    @MainActor (
      _ repository: any RemoteOrganizerRepository,
      _ keys: OrganizerKeyMaterial,
      _ onUpdate:
        @escaping (RemoteOrganizerRuntime.LinkState, RemoteOrganizerProjection?) ->
        Void
    ) -> RemoteOrganizerRuntime

  private let repository: any RemoteOrganizerRepository
  private let dataRoot: URL
  private let realLibraryRoot: URL
  private let allowsOwnLibrary: Bool
  private let makeRuntime: RuntimeFactory
  private let intent: any RemoteOrganizerLinkIntentStore
  private let keyStore: any OrganizerKeyStore
  private let cleanUpStaleTunnels: @MainActor () -> Void
  private var runtime: RemoteOrganizerRuntime?
  private var keys: OrganizerKeyMaterial?
  private var toggleGeneration = 0
  /// The lock (or wipe) a finishing runtime is still sending.
  private var finishing: Task<Void, Never>?
  /// The Mac went to sleep with the link on: the organizing device was asked
  /// to lock, and the link reconnects on wake.
  private var suspendedForSleep = false

  public private(set) var isEnabled = false
  public private(set) var status: Status = .off
  public private(set) var projection: RemoteOrganizerProjection?
  /// Called on every status or projection change.
  public var onChange: ((Status, RemoteOrganizerProjection?) -> Void)?

  public init(
    repository: any RemoteOrganizerRepository,
    dataRoot: URL,
    realLibraryRoot: URL,
    allowsOwnLibrary: Bool = RemoteOrganizerDataProvenance.productReleaseAllowsOwnLibrary,
    intent: any RemoteOrganizerLinkIntentStore,
    keyStore: any OrganizerKeyStore,
    cleanUpStaleTunnels: @escaping @MainActor () -> Void,
    makeRuntime: @escaping RuntimeFactory
  ) {
    self.repository = repository
    self.dataRoot = dataRoot
    self.realLibraryRoot = realLibraryRoot
    self.allowsOwnLibrary = allowsOwnLibrary
    self.intent = intent
    self.keyStore = keyStore
    self.cleanUpStaleTunnels = cleanUpStaleTunnels
    self.makeRuntime = makeRuntime
  }

  public var provenance: RemoteOrganizerDataProvenance.Verdict {
    RemoteOrganizerDataProvenance.verdict(
      dataRoot: dataRoot, realLibraryRoot: realLibraryRoot,
      allowsOwnLibrary: allowsOwnLibrary
    )
  }

  public var isRuntimeRunning: Bool { runtime?.isRunning == true }

  /// The organizer's clock mode while the link runs (`wall` in production).
  public var serviceClock: String? { runtime?.serviceClock }

  /// The key ID this library unlocks with while the link is on.
  public var keyID: String? { keys?.keyID }

  /// "让 Spark 忘掉" is offered only while the link is on and the organizing
  /// device answers (connected, or holding another key's store).
  public var canForget: Bool {
    guard isEnabled, runtime != nil else { return false }
    switch status {
    case .connected, .wrongKey: return true
    default: return false
    }
  }

  /// At launch: end any orphaned forward from a previous run, then resume the
  /// link only if the user's "on" marker and the library's watermark both
  /// exist and the library is allowed. A watermark without the marker is a
  /// revocation that did not finish (or an enable that never completed): it
  /// is finished now, before anything else.
  public func restoreOnLaunch() async {
    cleanUpStaleTunnels()
    toggleGeneration += 1
    let current = toggleGeneration
    let record: RemoteOrganizerLinkRecord
    do { record = try await repository.remoteLinkRecord() } catch {
      guard current == toggleGeneration else { return }
      set(.storageUnavailable)
      return
    }
    guard current == toggleGeneration else { return }
    guard intent.onRecorded else {
      if record.enabledAt != nil {
        do { try await repository.revokeRemoteLink() } catch {
          guard current == toggleGeneration else { return }
          set(.storageUnavailable)
          return
        }
        guard current == toggleGeneration else { return }
      }
      set(.off)
      return
    }
    guard record.enabledAt != nil else {
      // The library was turned off (or replaced); the marker alone is stale.
      try? intent.clearOn()
      set(.off)
      return
    }
    let verdict = provenance
    guard verdict == .allowed else {
      // Fail closed: a library that lost its synthetic marker stops sending.
      try? intent.clearOn()
      try? await repository.revokeRemoteLink()
      isEnabled = false
      set(.refused(verdict))
      return
    }
    isEnabled = true
    guard loadKeys() else { return }
    startRuntime()
  }

  /// The library's key, made on the first enable. Without it nothing is
  /// sent: the status says the key store is unavailable.
  private func loadKeys() -> Bool {
    do {
      keys = try keyStore.loadOrCreate()
      return true
    } catch {
      keys = nil
      set(.keyUnavailable)
      return false
    }
  }

  public func setEnabled(_ enabled: Bool) async {
    guard enabled else {
      revokeNow()
      await waitForRevocation()
      await revokeStorage()
      return
    }
    toggleGeneration += 1
    let current = toggleGeneration
    cleanUpStaleTunnels()
    let verdict = provenance
    guard verdict == .allowed else {
      isEnabled = false
      set(.refused(verdict))
      return
    }
    // The key exists before anything can be queued for sending.
    guard loadKeys() else {
      isEnabled = false
      return
    }
    do { try await repository.enableRemoteLink(at: Date()) } catch {
      guard current == toggleGeneration else { return }
      isEnabled = false
      set(.storageUnavailable)
      return
    }
    guard current == toggleGeneration else { return }
    do { try intent.recordOn() } catch {
      // Without the marker the next launch would revoke anyway; stay off now
      // rather than half on.
      try? await repository.revokeRemoteLink()
      guard current == toggleGeneration else { return }
      isEnabled = false
      set(.storageUnavailable)
      return
    }
    isEnabled = true
    startRuntime()
  }

  /// The synchronous part of turning the link off, for the UI to call before
  /// anything else can run on the main actor: removes the "on" marker, stops
  /// the runtime (no request is sent and no status or projection is published
  /// after this returns), ends the tunnel, and shows the link as off. If the
  /// marker cannot be removed the status says storage is unavailable instead
  /// of claiming a clean off.
  public func revokeNow() {
    toggleGeneration += 1
    var markerCleared = true
    do { try intent.clearOn() } catch { markerCleared = false }
    let ending = runtime
    runtime = nil
    // No data request leaves after this line; only the lock below.
    ending?.halt()
    isEnabled = false
    projection = nil
    set(markerCleared ? .off : .storageUnavailable)
    guard let ending else {
      cleanUpStaleTunnels()
      return
    }
    let previous = finishing
    let cleanUp = cleanUpStaleTunnels
    // Best effort: the organizing device closes its store and drops the key
    // from memory, then the forward ends.
    finishing = Task {
      await previous?.value
      await ending.finish(sending: .lock, timeout: Self.lockTimeout)
      cleanUp()
    }
  }

  /// Until the lock sent by `revokeNow` was answered or given up (at most
  /// `lockTimeout`) and the forward is gone.
  public func waitForRevocation() async {
    await finishing?.value
  }

  /// "让 Spark 忘掉我的内容" (or, holding another key's store, "让 Spark 忘掉旧
  /// 内容"): `POST /v1/wipe` over the running link. On 200 the library
  /// records that nothing is on the organizing device any more (nothing is
  /// sent again unless it changes), this library's key is destroyed when the
  /// content was its own, and the link goes on with a new key and an empty
  /// store. On anything else nothing changes here and the link resumes.
  public func forgetOnOrganizer(_ target: ForgetTarget) async -> ForgetOutcome {
    guard canForget, let ending = runtime, let keys else { return .notConnected }
    let keyID: String
    switch target {
    case .mine: keyID = keys.keyID
    case .otherKey(let other): keyID = other
    }
    toggleGeneration += 1
    let current = toggleGeneration
    runtime = nil
    ending.halt()
    set(.connecting)
    let response = await ending.finish(sending: .wipe(keyID: keyID), timeout: Self.wipeTimeout)
    guard current == toggleGeneration, isEnabled else { return .notConnected }
    guard response?.status == 200 else {
      startRuntime()
      return .refused(response?.status)
    }
    let keyDestroyed = target != .mine || destroyKey(keys)
    if !keyDestroyed {
      // The content is gone there; the old key must never unlock anything again.
      self.keys = nil
    }
    do { try await repository.forgetRemoteStore() } catch {
      guard current == toggleGeneration else { return .storageUnavailable }
      set(.storageUnavailable)
      return .storageUnavailable
    }
    guard current == toggleGeneration, isEnabled else {
      return keyDestroyed ? .forgotten : .keyNotDestroyed
    }
    projection = nil
    guard keyDestroyed else {
      set(.keyUnavailable)
      return .keyNotDestroyed
    }
    guard loadKeys() else { return .forgotten }
    if target == .mine, self.keys?.keyID == keys.keyID {
      // Never go on with the key that was just forgotten.
      self.keys = nil
      set(.keyUnavailable)
      return .keyNotDestroyed
    }
    startRuntime()
    return .forgotten
  }

  /// Destroys the forgotten key in the key store: deleted, or, when the
  /// delete fails or the key still reads back, overwritten with a new one
  /// that reads back. False when neither worked (privacy review F11).
  private func destroyKey(_ old: OrganizerKeyMaterial) -> Bool {
    func storedKey() -> (read: Bool, keys: OrganizerKeyMaterial?) {
      do { return (true, try keyStore.load()) } catch { return (false, nil) }
    }
    let deleted = (try? keyStore.delete()) != nil
    if deleted {
      let after = storedKey()
      if after.read, after.keys == nil { return true }
    }
    guard let fresh = try? OrganizerKeyMaterial.random(), (try? keyStore.save(fresh)) != nil else {
      return false
    }
    let after = storedKey()
    return after.read && after.keys?.keyID == fresh.keyID && fresh.keyID != old.keyID
  }

  /// The durable part of turning the link off: clears the watermark and the
  /// pending outbox in the library. If it fails, the missing "on" marker
  /// makes the next launch retry it before anything starts.
  public func revokeStorage() async {
    let current = toggleGeneration
    do { try await repository.revokeRemoteLink() } catch {
      guard current == toggleGeneration else { return }
      set(.storageUnavailable)
      return
    }
    guard current == toggleGeneration else { return }
    // With the watermark gone a lingering marker cannot resume anything.
    if intent.onRecorded {
      try? intent.clearOn()
    }
    if status == .storageUnavailable { set(.off) }
  }

  /// Quit: end the tunnel synchronously. The enable watermark stays, so the
  /// link resumes on the next launch.
  public func shutdown() {
    stopRuntime()
  }

  /// Quit with the link on (privacy review F1): the organizing device is
  /// asked to lock its store first (best effort, `lockTimeout`, tried twice),
  /// then the forward ends. The enable watermark stays, so the link resumes
  /// on the next launch. If the lock does not arrive, the organizing device
  /// locks itself when its unlock lease runs out.
  public func shutdownLocking() async {
    let ending = runtime
    runtime = nil
    ending?.halt()
    if let ending { await ending.finish(sending: .lock, timeout: Self.lockTimeout) }
    cleanUpStaleTunnels()
  }

  /// The Mac goes to sleep (or the user session is switched away) with the
  /// link on: nothing more is sent, the organizing device is asked to lock
  /// its store (best effort), and the forward ends. The link stays on and
  /// connects again, unlocking with the same key, on `resumeAfterSleep()`.
  public func suspendForSleep() async {
    guard isEnabled, let ending = runtime else { return }
    runtime = nil
    ending.halt()
    suspendedForSleep = true
    set(.connecting)
    await ending.finish(sending: .lock, timeout: Self.lockTimeout)
    cleanUpStaleTunnels()
  }

  /// The Mac woke up: a link suspended for sleep connects again.
  public func resumeAfterSleep() {
    guard suspendedForSleep else { return }
    suspendedForSleep = false
    guard isEnabled, runtime == nil, keys != nil else { return }
    startRuntime()
  }

  public func enqueueCompletedSession(_ sessionID: SessionID) async throws {
    guard isEnabled else { return }
    _ = try await repository.enqueueRemoteSession(sessionID: sessionID)
  }

  public func record(_ decision: RemoteOrganizerDecision) async throws {
    guard isEnabled else { return }
    try await repository.enqueueRemoteDecision(decision)
    await refreshProjection()
  }

  public func retryDecision(_ id: UUID) async throws {
    guard isEnabled else { return }
    try await repository.retryRemoteDecision(id: id)
    await refreshProjection()
  }

  public func discardDecision(_ id: UUID) async throws {
    try await repository.discardRemoteDecision(id: id)
    await refreshProjection()
  }

  /// After a portable-archive import. The import itself turned the link off
  /// in the library (imported rows have unknown provenance); this makes the
  /// app agree right away. Restored decisions are listed as not sent once the
  /// link is on again, and leave the Mac only if the user retries one.
  /// Returns true when a running link was turned off.
  @discardableResult
  public func archiveImported() async -> Bool {
    let current = toggleGeneration
    guard let record = try? await repository.remoteLinkRecord(),
      current == toggleGeneration
    else { return false }
    guard record.enabledAt == nil else {
      await refreshProjection()
      return false
    }
    guard isEnabled else { return false }
    revokeNow()
    return true
  }

  public func refreshProjection() async {
    let current = toggleGeneration
    guard isEnabled, let projection = try? await repository.remoteProjection(),
      current == toggleGeneration, isEnabled
    else { return }
    self.projection = projection
    onChange?(status, projection)
  }

  private func startRuntime() {
    stopRuntime()
    suspendedForSleep = false
    guard let keys else {
      set(.keyUnavailable)
      return
    }
    let runtime = makeRuntime(repository, keys) { [weak self] state, projection in
      guard let self else { return }
      if let projection { self.projection = projection }
      if state == .wrongKey {
        // Only the current runtime publishes (generation guard).
        self.set(.wrongKey(self.runtime?.foreignKeyID))
      } else {
        self.set(Self.status(for: state))
      }
    }
    self.runtime = runtime
    runtime.start()
  }

  private func stopRuntime() {
    runtime?.stop()
    runtime = nil
  }

  private func set(_ newStatus: Status) {
    status = newStatus
    onChange?(newStatus, projection)
  }

  private static func status(for state: RemoteOrganizerRuntime.LinkState) -> Status {
    switch state {
    case .off: .off
    case .connecting: .connecting
    case .connected: .connected
    case .unavailable: .unavailable
    case .wrongKey: .wrongKey(nil)
    case .unsupported: .unsupportedService
    }
  }
}
