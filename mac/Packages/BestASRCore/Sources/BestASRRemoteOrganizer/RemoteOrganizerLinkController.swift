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
    let standardized = dataRoot.standardizedFileURL.path
    let canonical =
      BestASRDataRootSelection.kernelPath(ofExisting: standardized)
      ?? dataRoot.standardizedFileURL.resolvingSymlinksInPath().path
    let key = SHA256.hash(data: Data(canonical.utf8))
      .prefix(16).map { String(format: "%02x", $0) }.joined()
    url = stateDirectory.appendingPathComponent("link-on-\(key)")
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

/// The app-facing switch for the own-device organizer link. It applies the
/// data-provenance guard, persists the per-library enable watermark, and owns
/// at most one runtime at a time.
///
/// Semantics (PRD §0.3.8): turning the link off stops all sending, ends the
/// tunnel and clears the pending outbox. Items captured while the link is off
/// are never sent automatically.
@MainActor
public final class RemoteOrganizerLinkController {
  public enum Status: Equatable, Sendable {
    case off
    case refused(RemoteOrganizerDataProvenance.Verdict)
    case connecting
    case connected
    case unavailable
    case storageUnavailable
  }

  public typealias RuntimeFactory =
    @MainActor (
      _ repository: any RemoteOrganizerRepository,
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
  private let cleanUpStaleTunnels: @MainActor () -> Void
  private var runtime: RemoteOrganizerRuntime?
  private var toggleGeneration = 0

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
    cleanUpStaleTunnels: @escaping @MainActor () -> Void,
    makeRuntime: @escaping RuntimeFactory
  ) {
    self.repository = repository
    self.dataRoot = dataRoot
    self.realLibraryRoot = realLibraryRoot
    self.allowsOwnLibrary = allowsOwnLibrary
    self.intent = intent
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
    startRuntime()
  }

  public func setEnabled(_ enabled: Bool) async {
    guard enabled else {
      revokeNow()
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
    stopRuntime()
    isEnabled = false
    projection = nil
    set(markerCleared ? .off : .storageUnavailable)
    cleanUpStaleTunnels()
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
    let runtime = makeRuntime(repository) { [weak self] state, projection in
      guard let self else { return }
      if let projection { self.projection = projection }
      self.set(Self.status(for: state))
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
    }
  }
}
