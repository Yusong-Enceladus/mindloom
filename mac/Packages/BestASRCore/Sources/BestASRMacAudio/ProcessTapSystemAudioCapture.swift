import BestASRDictation
import BestASRDomain
import BestASRProcessTapProbe
import CoreGraphics
import Dispatch
import Foundation

public enum SystemAudioCaptureScope: Codable, Equatable, Hashable, Sendable {
  case application(identity: String)
  case entireSystem
}

public struct SystemAudioSource: Codable, Equatable, Hashable, Identifiable, Sendable {
  public let id: String
  public let displayName: String
  public let bundleID: String?
  public let isRunningOutput: Bool

  public init(
    id: String,
    displayName: String,
    bundleID: String?,
    isRunningOutput: Bool
  ) {
    self.id = id
    self.displayName = displayName
    self.bundleID = bundleID
    self.isRunningOutput = isRunningOutput
  }
}

public enum SystemAudioCaptureError: Error, Equatable, Sendable {
  case alreadyActive
  case bufferOverflow
  case noAudioProcesses
  case notActive
  case permissionDenied
  case selectedApplicationUnavailable
  case unsupportedSystem
  case runtime(String)
}

/// A product-facing catalog over Core Audio's process objects. Only grouped
/// application identity is exposed to the UI; raw process IDs remain ephemeral
/// and are refreshed while capture is active so helpers and restarted sources
/// continue to join the selected application boundary.
@available(macOS 14.2, *)
public enum SystemAudioSourceCatalog {
  public static func sources() throws -> [SystemAudioSource] {
    try ProcessAudioGrouper.groups(from: CoreAudioHAL.audioProcesses())
      .filter { !$0.audioObjectIDs.isEmpty }
      .map {
        SystemAudioSource(
          id: $0.identity,
          displayName: $0.displayName,
          bundleID: $0.bundleID,
          isRunningOutput: $0.hasRunningOutput
        )
      }
  }
}

@available(macOS 14.2, *)
public enum SystemAudioOutputDeviceCatalog {
  public static func defaultOutputDeviceID() throws -> UInt32 {
    try CoreAudioHAL.defaultOutputDeviceID()
  }
}

/// Core Audio Process Tap capture with a bounded real-time ring and continual
/// non-real-time draining. It conforms to the same durable capture port as a
/// microphone so recording durability, pause/resume, recovery, inference and
/// speaker identity use the production session pipeline without a parallel
/// system-audio-only implementation.
@available(macOS 14.2, *)
public actor ProcessTapSystemAudioCapture: MicrophoneCapturePort {
  private let scope: SystemAudioCaptureScope
  private let ringDurationSeconds: TimeInterval
  private let drainFrameCount: Int
  private let streamCapacity: Int
  private let captureTrackID = TrackID()

  private var session: ProcessTapCaptureSession?
  private var stream: AsyncStream<CapturedPCMChunk>?
  private var continuation: AsyncStream<CapturedPCMChunk>.Continuation?
  private var drainTask: Task<Void, Never>?
  private var chunkAccumulator = CapturedPCMChunkAccumulator()
  private var nextMonotonicStartNanoseconds: UInt64 = 0
  private var activeProcessObjectIDs: [UInt32] = []
  private var lastCatalogRefreshNanoseconds: UInt64 = 0
  private var stoppedFailure: SystemAudioCaptureError?
  private var sourceMissingSinceNanoseconds: UInt64?
  private var isRunning = false

  public init(
    scope: SystemAudioCaptureScope,
    ringDurationSeconds: TimeInterval = 4,
    drainFrameCount: Int = 4_096,
    streamCapacity: Int = 64
  ) {
    self.scope = scope
    self.ringDurationSeconds = max(1, ringDurationSeconds)
    self.drainFrameCount = max(256, drainFrameCount)
    self.streamCapacity = max(8, streamCapacity)
  }

  public func prepare(sessionID: SessionID) async throws
    -> MicrophoneCaptureDescriptor
  {
    guard #available(macOS 14.2, *) else {
      throw SystemAudioCaptureError.unsupportedSystem
    }
    // A denied Process Tap can still deliver real-time zero buffers on some
    // macOS versions. Refuse to construct the durable stream unless TCC says
    // capture is allowed, so denial can never become a silent success record.
    guard CGPreflightScreenCaptureAccess() else {
      throw SystemAudioCaptureError.permissionDenied
    }
    guard session == nil else { throw SystemAudioCaptureError.alreadyActive }
    let processIDs = try Self.processObjectIDs(for: scope)
    guard !processIDs.isEmpty else {
      throw Self.emptySourceError(for: scope)
    }

    let capture: ProcessTapCaptureSession
    do {
      capture = try ProcessTapCaptureSession(
        processObjectIDs: processIDs,
        maximumDuration: ringDurationSeconds
      )
    } catch {
      throw Self.mapRuntimeError(error)
    }
    let pair = AsyncStream.makeStream(
      of: CapturedPCMChunk.self,
      bufferingPolicy: .bufferingOldest(streamCapacity)
    )
    session = capture
    stream = pair.stream
    continuation = pair.continuation
    activeProcessObjectIDs = processIDs.sorted()
    chunkAccumulator.reset()
    nextMonotonicStartNanoseconds = 0
    lastCatalogRefreshNanoseconds = 0
    stoppedFailure = nil
    sourceMissingSinceNanoseconds = nil
    isRunning = false
    return MicrophoneCaptureDescriptor(
      sessionID: sessionID,
      deviceUID: Self.descriptorIdentity(for: scope),
      sampleRateHertz: UInt32(capture.sampleRate.rounded()),
      channelCount: 1,
      encoding: .float32LittleEndian,
      interleaved: true,
      tracks: [
        CaptureTrackDescriptor(
          id: captureTrackID,
          role: .systemRemote,
          deviceUID: Self.descriptorIdentity(for: scope),
          sampleRateHertz: UInt32(capture.sampleRate.rounded()),
          channelCount: 1,
          encoding: .float32LittleEndian,
          interleaved: true
        )
      ]
    )
  }

  public func start() async throws {
    guard let session else { throw SystemAudioCaptureError.notActive }
    guard !isRunning else { throw SystemAudioCaptureError.alreadyActive }
    do {
      try session.start()
    } catch {
      stoppedFailure = Self.mapRuntimeError(error)
      throw stoppedFailure!
    }
    isRunning = true
    if nextMonotonicStartNanoseconds == 0 {
      nextMonotonicStartNanoseconds = DispatchTime.now().uptimeNanoseconds
    }
    if drainTask == nil {
      drainTask = Task { [weak self] in
        guard let self else { return }
        await self.runDrainLoop()
      }
    }
  }

  public func chunks() async -> AsyncStream<CapturedPCMChunk> {
    stream ?? AsyncStream { $0.finish() }
  }

  public func pause() async throws {
    guard let session else { throw SystemAudioCaptureError.notActive }
    session.pause()
    isRunning = false
    drainAvailableFrames()
    flushAccumulatedFrames()
    if stoppedFailure == .selectedApplicationUnavailable {
      // Source disappearance is a recoverable lifecycle pause, not evidence
      // that already captured frames are corrupt. Ending from this paused
      // state may safely seal and process the retained prefix.
      stoppedFailure = nil
    }
  }

  public func resume() async throws {
    guard let session else { throw SystemAudioCaptureError.notActive }
    guard !isRunning else { throw SystemAudioCaptureError.alreadyActive }
    do {
      try refreshSelectedProcesses(force: true)
      try session.start()
      isRunning = true
      nextMonotonicStartNanoseconds = DispatchTime.now().uptimeNanoseconds
    } catch {
      stoppedFailure = Self.mapRuntimeError(error)
      throw stoppedFailure!
    }
  }

  public func stop() async throws {
    guard let session else { throw SystemAudioCaptureError.notActive }
    isRunning = false
    session.pause()
    drainTask?.cancel()
    _ = await drainTask?.result
    drainTask = nil
    drainAvailableFrames()
    flushAccumulatedFrames()
    if session.droppedFrameCount > 0, stoppedFailure == nil {
      stoppedFailure = .bufferOverflow
    }
    continuation?.finish()
    session.close()
    self.session = nil
    continuation = nil
    stream = nil
    activeProcessObjectIDs = []
    sourceMissingSinceNanoseconds = nil
    chunkAccumulator.reset()
  }

  public func cancel() async {
    isRunning = false
    drainTask?.cancel()
    _ = await drainTask?.result
    drainTask = nil
    continuation?.finish()
    session?.close()
    session = nil
    continuation = nil
    stream = nil
    activeProcessObjectIDs = []
    sourceMissingSinceNanoseconds = nil
    chunkAccumulator.reset()
  }

  public func terminalFailure() async -> DictationFailure? {
    guard let failure = stoppedFailure else { return nil }
    let category: DictationFailureCategory
    let code: String
    switch failure {
    case .permissionDenied:
      category = .permissionDenied
      code = "system-audio-permission"
    case .selectedApplicationUnavailable, .noAudioProcesses:
      category = .targetUnavailable
      code = "system-audio-source-unavailable"
    case .bufferOverflow:
      category = .resourcePressure
      code = "system-audio-buffer-overflow"
    case .alreadyActive, .notActive, .unsupportedSystem, .runtime:
      category = .transientRuntime
      code = "system-audio-runtime"
    }
    return try? DictationFailure(
      stage: .capture,
      category: category,
      code: code,
      retryable: true,
      recoveryPhase: .recording
    )
  }

  private func runDrainLoop() async {
    while !Task.isCancelled, session != nil {
      drainAvailableFrames()
      if isRunning {
        do {
          try refreshSelectedProcesses(force: false)
        } catch {
          // A selected app may briefly disappear during an update/restart. The
          // existing tap remains alive and is reconfigured when it reappears.
          if case .entireSystem = scope {
            stoppedFailure = Self.mapRuntimeError(error)
          }
        }
      }
      try? await Task.sleep(for: .milliseconds(40))
    }
  }

  private func drainAvailableFrames() {
    guard let session, let continuation else { return }
    while true {
      let samples = session.drainSamples(maximumFrames: drainFrameCount)
      guard !samples.isEmpty else { break }
      let sampleRate = UInt32(session.sampleRate.rounded())
      guard sampleRate > 0 else {
        stoppedFailure = .runtime("invalid-sample-rate")
        continuation.finish()
        return
      }
      let bytes = samples.withUnsafeBytes { Data($0) }
      let callbackChunk = CapturedPCMChunk(
        trackID: captureTrackID,
        sequence: 0,
        monotonicStartNanoseconds: nextMonotonicStartNanoseconds,
        frameCount: UInt64(samples.count),
        sampleRateHertz: sampleRate,
        channelCount: 1,
        encoding: .float32LittleEndian,
        interleaved: true,
        bytes: bytes
      )
      nextMonotonicStartNanoseconds &+= UInt64(
        (Double(samples.count) / Double(sampleRate) * 1_000_000_000).rounded()
      )
      do {
        for chunk in try chunkAccumulator.append(callbackChunk) {
          guard publish(chunk, to: continuation) else { return }
        }
      } catch {
        stoppedFailure = .runtime("invalid-pcm-callback")
        continuation.finish()
        return
      }
    }
    if session.droppedFrameCount > 0, stoppedFailure == nil {
      stoppedFailure = .bufferOverflow
      continuation.finish()
    }
  }

  private func flushAccumulatedFrames() {
    guard let continuation,
      let chunk = chunkAccumulator.flush()
    else { return }
    _ = publish(chunk, to: continuation)
  }

  private func publish(
    _ chunk: CapturedPCMChunk,
    to continuation: AsyncStream<CapturedPCMChunk>.Continuation
  ) -> Bool {
    switch continuation.yield(chunk) {
    case .enqueued:
      return true
    case .dropped:
      stoppedFailure = .bufferOverflow
      chunkAccumulator.discardPending()
      continuation.finish()
      return false
    case .terminated:
      chunkAccumulator.discardPending()
      return false
    @unknown default:
      stoppedFailure = .bufferOverflow
      chunkAccumulator.discardPending()
      continuation.finish()
      return false
    }
  }

  private func refreshSelectedProcesses(force: Bool) throws {
    guard let session else { throw SystemAudioCaptureError.notActive }
    let now = DispatchTime.now().uptimeNanoseconds
    if !force, now - lastCatalogRefreshNanoseconds < 1_000_000_000 { return }
    lastCatalogRefreshNanoseconds = now
    let identifiers = try Self.processObjectIDs(for: scope).sorted()
    guard !identifiers.isEmpty else {
      if force { throw Self.emptySourceError(for: scope) }
      if case .application = scope {
        if let missingSince = sourceMissingSinceNanoseconds {
          if now >= missingSince, now - missingSince >= 2_000_000_000 {
            stoppedFailure = .selectedApplicationUnavailable
          }
        } else {
          sourceMissingSinceNanoseconds = now
        }
      }
      return
    }
    sourceMissingSinceNanoseconds = nil
    if stoppedFailure == .selectedApplicationUnavailable {
      stoppedFailure = nil
    }
    guard identifiers != activeProcessObjectIDs else { return }
    try session.updateProcessObjectIDs(identifiers)
    activeProcessObjectIDs = identifiers
  }

  private static func processObjectIDs(
    for scope: SystemAudioCaptureScope
  ) throws -> [UInt32] {
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let processes = try CoreAudioHAL.audioProcesses().filter {
      $0.processID != ownPID
    }
    switch scope {
    case .entireSystem:
      return processes.map(\.objectID)
    case .application(let identity):
      return ProcessAudioGrouper.groups(from: processes)
        .first(where: { $0.identity == identity })?
        .audioObjectIDs ?? []
    }
  }

  private static func descriptorIdentity(
    for scope: SystemAudioCaptureScope
  ) -> String {
    switch scope {
    case .entireSystem: "system-audio:entire-system"
    case .application(let identity): "system-audio:\(identity)"
    }
  }

  private static func emptySourceError(
    for scope: SystemAudioCaptureScope
  ) -> SystemAudioCaptureError {
    switch scope {
    case .entireSystem: .noAudioProcesses
    case .application: .selectedApplicationUnavailable
    }
  }

  private static func mapRuntimeError(_ error: Error) -> SystemAudioCaptureError {
    let description = String(describing: error)
    if description.contains("perm") || description.contains("denied")
      || description.contains("1937010544")
    {
      return .permissionDenied
    }
    if let known = error as? SystemAudioCaptureError { return known }
    return .runtime(description)
  }
}
