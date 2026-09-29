import AVFoundation
import BestASRDictation
import BestASRDomain
import Dispatch
import Foundation
import OSLog

public enum MacMicrophoneCaptureError: Error, Equatable, Sendable {
  case alreadyActive
  case bufferOverflow
  case deviceMetadataUnavailable
  case invalidAudioFormat
  case noDefaultInputDevice
  case notActive
  case permissionNotGranted(DictationPermissionState)
  case unsupportedPCMFormat
}

protocol MicrophoneAuthorizationChecking: Sendable {
  func state() -> DictationPermissionState
}

struct SystemMicrophoneAuthorizationChecker: MicrophoneAuthorizationChecking {
  func state() -> DictationPermissionState {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return .granted
    case .denied:
      return .denied
    case .restricted:
      return .restricted
    case .notDetermined:
      return .notDetermined
    @unknown default:
      return .restricted
    }
  }
}

enum MicrophoneDeviceSelectionPolicy {
  static func requiresExplicitSelection(
    selectedDeviceUID: String?,
    defaultDeviceUID: String
  ) -> Bool {
    guard let selectedDeviceUID, !selectedDeviceUID.isEmpty else { return false }
    return selectedDeviceUID != defaultDeviceUID
  }
}

enum MicrophoneFormatSettlingPolicy {
  /// A newly relaunched process can briefly see a zero-channel input format
  /// while CoreAudio settles a device or route change. Recreate the engine on
  /// each attempt so an invalid input node is never retained.
  static let retryDelaysNanoseconds: [UInt64] = [
    50_000_000,
    100_000_000,
    200_000_000,
    400_000_000,
    800_000_000,
  ]

  static func delay(afterFailedAttempt attempt: Int) -> UInt64? {
    retryDelaysNanoseconds.indices.contains(attempt)
      ? retryDelaysNanoseconds[attempt]
      : nil
  }
}

final class MicrophoneCallbackState: @unchecked Sendable {
  private let lock = NSLock()
  private let continuation: AsyncStream<CapturedPCMChunk>.Continuation
  private var chunkAccumulator: CapturedPCMChunkAccumulator
  private var finished = false
  private var storedFailure: MacMicrophoneCaptureError?
  private let trackID: TrackID?
  private var publishedThroughNanoseconds: UInt64 = 0

  init(
    continuation: AsyncStream<CapturedPCMChunk>.Continuation,
    trackID: TrackID? = nil,
    maximumChunkDurationNanoseconds: UInt64 =
      CapturedPCMChunkAccumulator.defaultMaximumDurationNanoseconds
  ) {
    self.continuation = continuation
    self.trackID = trackID
    chunkAccumulator = CapturedPCMChunkAccumulator(
      maximumDurationNanoseconds: maximumChunkDurationNanoseconds
    )
  }

  func receive(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    lock.unlock()

    let chunk: CapturedPCMChunk
    do {
      chunk = try MicrophonePCMBufferCopier.copy(
        buffer,
        time: time,
        sequence: 0,
        trackID: trackID
      )
    } catch {
      lock.lock()
      storedFailure = (error as? MacMicrophoneCaptureError) ?? .unsupportedPCMFormat
      finished = true
      continuation.finish()
      lock.unlock()
      return
    }

    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    do {
      for completed in try chunkAccumulator.append(chunk) {
        guard publish(completed) else { break }
      }
    } catch {
      storedFailure = .unsupportedPCMFormat
      finished = true
      continuation.finish()
    }
    lock.unlock()
  }

  func flushPending() {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    if let chunk = chunkAccumulator.flush() {
      _ = publish(chunk)
    }
    lock.unlock()
  }

  /// Publishes the partial chunk now and returns the monotonic end of all
  /// audio handed to the stream, or nil once finished.
  func flushPendingForSpeechPause() -> UInt64? {
    lock.lock()
    defer { lock.unlock() }
    guard !finished else { return nil }
    if let chunk = chunkAccumulator.flush(), !publish(chunk) { return nil }
    return publishedThroughNanoseconds
  }

  func finish(flushPending: Bool) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    if flushPending, let chunk = chunkAccumulator.flush() {
      _ = publish(chunk)
    } else {
      chunkAccumulator.discardPending()
    }
    finished = true
    continuation.finish()
    lock.unlock()
  }

  func recordRecoverableFailure(_ failure: MacMicrophoneCaptureError) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    storedFailure = failure
    lock.unlock()
  }

  func clearRecoverableDeviceFailure() {
    lock.lock()
    if storedFailure == .deviceMetadataUnavailable {
      storedFailure = nil
    }
    lock.unlock()
  }

  func failure() -> MacMicrophoneCaptureError? {
    lock.lock()
    defer { lock.unlock() }
    return storedFailure
  }

  private func publish(_ chunk: CapturedPCMChunk) -> Bool {
    switch continuation.yield(chunk) {
    case .enqueued:
      publishedThroughNanoseconds =
        chunk.monotonicStartNanoseconds
        + chunk.frameCount * 1_000_000_000 / UInt64(max(1, chunk.sampleRateHertz))
      return true
    case .dropped:
      storedFailure = .bufferOverflow
      finished = true
      chunkAccumulator.discardPending()
      continuation.finish()
      return false
    case .terminated:
      finished = true
      chunkAccumulator.discardPending()
      return false
    @unknown default:
      storedFailure = .bufferOverflow
      finished = true
      chunkAccumulator.discardPending()
      continuation.finish()
      return false
    }
  }
}

enum MicrophonePCMBufferCopier {
  static func copy(
    _ buffer: AVAudioPCMBuffer,
    time: AVAudioTime,
    sequence: UInt64,
    trackID: TrackID? = nil
  ) throws -> CapturedPCMChunk {
    let format = buffer.format
    guard format.commonFormat == .pcmFormatFloat32,
      !format.isInterleaved,
      let channelData = buffer.floatChannelData,
      format.sampleRate > 0,
      format.channelCount > 0,
      buffer.frameLength > 0
    else {
      throw MacMicrophoneCaptureError.unsupportedPCMFormat
    }
    let frameCount = Int(buffer.frameLength)
    let channelCount = Int(format.channelCount)
    var data = Data(capacity: frameCount * channelCount * 4)
    for frame in 0..<frameCount {
      for channel in 0..<channelCount {
        let bits = channelData[channel][frame].bitPattern.littleEndian
        withUnsafeBytes(of: bits) { data.append(contentsOf: $0) }
      }
    }
    let monotonicNanoseconds: UInt64
    if time.isHostTimeValid {
      monotonicNanoseconds = UInt64(
        max(0, AVAudioTime.seconds(forHostTime: time.hostTime) * 1_000_000_000)
      )
    } else {
      monotonicNanoseconds = DispatchTime.now().uptimeNanoseconds
    }
    return CapturedPCMChunk(
      trackID: trackID,
      sequence: sequence,
      monotonicStartNanoseconds: monotonicNanoseconds,
      frameCount: UInt64(frameCount),
      sampleRateHertz: UInt32(format.sampleRate.rounded()),
      channelCount: UInt16(format.channelCount),
      encoding: .float32LittleEndian,
      interleaved: true,
      bytes: data
    )
  }
}

private let microphoneTimingLogger = Logger(
  subsystem: "com.bestasr.app", category: "microphone-capture")

/// Content-free stage timing for microphone startup.
private func logMicrophoneStage(_ stage: String, since start: ContinuousClock.Instant) {
  let elapsed = ContinuousClock.now - start
  let milliseconds =
    elapsed.components.seconds * 1_000
    + elapsed.components.attoseconds / 1_000_000_000_000_000
  microphoneTimingLogger.notice(
    "dictation timing stage=\(stage, privacy: .public) ms=\(milliseconds, privacy: .public)"
  )
}

public actor AVAudioEngineMicrophoneCapture: MicrophoneCapturePort {
  private let authorization: any MicrophoneAuthorizationChecking
  private let deviceProvider: any DefaultInputDeviceProviding
  private let bufferFrameCapacity: AVAudioFrameCount
  private let streamCapacity: Int
  private let sourceRole: SourceTrackRole
  private let selectedDeviceUID: String?
  private let maximumChunkDurationNanoseconds: UInt64
  private let levelHandler: (@Sendable (Float) -> Void)?
  private let speechPauseHandler: (@Sendable (MicrophoneSpeechPause) -> Void)?

  private var engine: AVAudioEngine?
  private var stream: AsyncStream<CapturedPCMChunk>?
  private var callbackState: MicrophoneCallbackState?
  private var descriptor: MicrophoneCaptureDescriptor?
  private var lastStoppedFailure: MacMicrophoneCaptureError?
  private var configurationObserver: NSObjectProtocol?
  private var prestartedSessionID: SessionID?

  /// `levelHandler` receives a normalized 0...1 input level for every capture
  /// buffer on the audio thread. It carries no samples; callers use it only
  /// for a live level indicator. `speechPauseHandler`, also on the audio
  /// thread, hears when the speaker pauses — after the pending audio has been
  /// handed to the chunk stream — and when speech resumes.
  public init(
    sourceRole: SourceTrackRole = .microphoneLocal,
    selectedDeviceUID: String? = nil,
    bufferFrameCapacity: AVAudioFrameCount = 2_048,
    streamCapacity: Int = 32,
    levelHandler: (@Sendable (Float) -> Void)? = nil,
    speechPauseHandler: (@Sendable (MicrophoneSpeechPause) -> Void)? = nil
  ) {
    self.levelHandler = levelHandler
    self.speechPauseHandler = speechPauseHandler
    authorization = SystemMicrophoneAuthorizationChecker()
    deviceProvider = SystemDefaultInputDeviceProvider()
    self.sourceRole = sourceRole
    self.selectedDeviceUID = selectedDeviceUID
    self.bufferFrameCapacity = bufferFrameCapacity
    self.streamCapacity = max(2, streamCapacity)
    self.maximumChunkDurationNanoseconds =
      CapturedPCMChunkAccumulator.defaultMaximumDurationNanoseconds
  }

  init(
    authorization: any MicrophoneAuthorizationChecking,
    deviceProvider: any DefaultInputDeviceProviding,
    sourceRole: SourceTrackRole = .microphoneLocal,
    selectedDeviceUID: String? = nil,
    bufferFrameCapacity: AVAudioFrameCount = 2_048,
    streamCapacity: Int = 32,
    maximumChunkDurationNanoseconds: UInt64 =
      CapturedPCMChunkAccumulator.defaultMaximumDurationNanoseconds
  ) {
    self.authorization = authorization
    levelHandler = nil
    speechPauseHandler = nil
    self.deviceProvider = deviceProvider
    self.sourceRole = sourceRole
    self.selectedDeviceUID = selectedDeviceUID
    self.bufferFrameCapacity = bufferFrameCapacity
    self.streamCapacity = max(2, streamCapacity)
    self.maximumChunkDurationNanoseconds = max(
      1,
      maximumChunkDurationNanoseconds
    )
  }

  public func prepare(sessionID: SessionID) async throws
    -> MicrophoneCaptureDescriptor
  {
    if let prestartedSessionID, prestartedSessionID == sessionID,
      let descriptor, engine?.isRunning == true
    {
      return descriptor
    }
    guard engine == nil else { throw MacMicrophoneCaptureError.alreadyActive }
    let prepareStarted = ContinuousClock.now
    defer { logMicrophoneStage("mic-prepare", since: prepareStarted) }
    let permission = authorization.state()
    guard permission == .granted else {
      throw MacMicrophoneCaptureError.permissionNotGranted(permission)
    }
    let defaultDevice = try deviceProvider.currentDefaultInput()
    let requiresExplicitSelection =
      MicrophoneDeviceSelectionPolicy.requiresExplicitSelection(
        selectedDeviceUID: selectedDeviceUID,
        defaultDeviceUID: defaultDevice.uid
      )
    let device =
      requiresExplicitSelection
      ? try MicrophoneDeviceCatalog.device(uid: selectedDeviceUID)
      : defaultDevice
    lastStoppedFailure = nil
    var preparedEngine: AVAudioEngine?
    var preparedInput: AVAudioInputNode?
    var preparedTapFormat: AVAudioFormat?
    var failedAttempt = 0
    while true {
      let candidateEngine = AVAudioEngine()
      let candidateInput = candidateEngine.inputNode
      if requiresExplicitSelection {
        try MicrophoneDeviceCatalog.select(
          deviceID: device.deviceID,
          for: candidateInput
        )
      }
      let hardwareFormat = candidateInput.outputFormat(forBus: 0)
      if hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
        let candidateTapFormat = AVAudioFormat(
          commonFormat: .pcmFormatFloat32,
          sampleRate: hardwareFormat.sampleRate,
          channels: hardwareFormat.channelCount,
          interleaved: false
        )
      {
        preparedEngine = candidateEngine
        preparedInput = candidateInput
        preparedTapFormat = candidateTapFormat
        break
      }
      guard
        let delay = MicrophoneFormatSettlingPolicy.delay(
          afterFailedAttempt: failedAttempt
        )
      else { break }
      failedAttempt += 1
      try await Task.sleep(nanoseconds: delay)
    }
    guard let newEngine = preparedEngine, let input = preparedInput,
      let tapFormat = preparedTapFormat
    else { throw MacMicrophoneCaptureError.invalidAudioFormat }
    let pair = AsyncStream.makeStream(
      of: CapturedPCMChunk.self,
      bufferingPolicy: .bufferingOldest(streamCapacity)
    )
    let trackID = TrackID()
    let state = MicrophoneCallbackState(
      continuation: pair.continuation,
      trackID: trackID,
      maximumChunkDurationNanoseconds: maximumChunkDurationNanoseconds
    )
    let levelHandler = levelHandler
    let speechPauseHandler = speechPauseHandler
    let pauseTracker = SpeechPauseTracker()
    input.installTap(
      onBus: 0,
      bufferSize: bufferFrameCapacity,
      format: tapFormat
    ) { buffer, time in
      state.receive(buffer: buffer, time: time)
      let rms = Self.rootMeanSquare(buffer)
      if let levelHandler { levelHandler(Self.normalizedLevel(rms: rms)) }
      guard let speechPauseHandler,
        let event = pauseTracker.consume(
          rms: rms, seconds: Double(buffer.frameLength) / buffer.format.sampleRate)
      else { return }
      switch event {
      case .paused:
        if let through = state.flushPendingForSpeechPause() {
          speechPauseHandler(.paused(committedThroughNanoseconds: through))
        }
      case .resumed:
        speechPauseHandler(.resumed)
      }
    }
    newEngine.prepare()
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: newEngine,
      queue: nil
    ) { _ in
      state.recordRecoverableFailure(.deviceMetadataUnavailable)
    }
    let captureDescriptor = MicrophoneCaptureDescriptor(
      sessionID: sessionID,
      deviceUID: device.uid,
      sampleRateHertz: UInt32(tapFormat.sampleRate.rounded()),
      channelCount: UInt16(tapFormat.channelCount),
      encoding: .float32LittleEndian,
      interleaved: true,
      tracks: [
        CaptureTrackDescriptor(
          id: trackID,
          role: sourceRole,
          deviceUID: device.uid,
          sampleRateHertz: UInt32(tapFormat.sampleRate.rounded()),
          channelCount: UInt16(tapFormat.channelCount),
          encoding: .float32LittleEndian,
          interleaved: true
        )
      ]
    )
    engine = newEngine
    stream = pair.stream
    callbackState = state
    descriptor = captureDescriptor
    return captureDescriptor
  }

  /// Prepares and starts capture at once so audio flows before any session,
  /// database, or focus work exists. Chunks queue in the capture stream. The
  /// following `prepare(sessionID:)` and `start()` for the same session adopt
  /// the running capture instead of failing as already active.
  public func prestart(sessionID: SessionID) async throws {
    _ = try await prepare(sessionID: sessionID)
    try await start()
    prestartedSessionID = sessionID
  }

  public func start() async throws {
    guard let engine, descriptor != nil else {
      throw MacMicrophoneCaptureError.notActive
    }
    if let prestarted = prestartedSessionID, descriptor?.sessionID == prestarted,
      engine.isRunning
    {
      prestartedSessionID = nil
      return
    }
    guard !engine.isRunning else {
      throw MacMicrophoneCaptureError.alreadyActive
    }
    do {
      let engineStartStarted = ContinuousClock.now
      try engine.start()
      logMicrophoneStage("mic-engine-start", since: engineStartStarted)
    } catch {
      engine.inputNode.removeTap(onBus: 0)
      callbackState?.finish(flushPending: false)
      removeConfigurationObserver()
      self.engine = nil
      callbackState = nil
      descriptor = nil
      throw error
    }
  }

  /// RMS of the first channel mapped from -50...-10 dBFS onto 0...1.
  nonisolated static func normalizedLevel(_ buffer: AVAudioPCMBuffer) -> Float {
    normalizedLevel(rms: rootMeanSquare(buffer))
  }

  nonisolated static func rootMeanSquare(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
      return 0
    }
    let count = Int(buffer.frameLength)
    var sum: Float = 0
    for index in 0..<count {
      let sample = samples[index]
      if sample.isFinite { sum += sample * sample }
    }
    return (sum / Float(count)).squareRoot()
  }

  nonisolated static func normalizedLevel(rms: Float) -> Float {
    guard rms > 0 else { return 0 }
    let decibels = 20 * log10(rms)
    return min(1, max(0, (decibels + 50) / 40))
  }

  public func chunks() async -> AsyncStream<CapturedPCMChunk> {
    stream ?? AsyncStream { $0.finish() }
  }

  public func pause() async throws {
    guard let engine else { throw MacMicrophoneCaptureError.notActive }
    engine.pause()
    callbackState?.flushPending()
  }

  public func resume() async throws {
    guard let engine else { throw MacMicrophoneCaptureError.notActive }
    callbackState?.clearRecoverableDeviceFailure()
    try engine.start()
  }

  public func stop() async throws {
    prestartedSessionID = nil
    guard let engine else { throw MacMicrophoneCaptureError.notActive }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    callbackState?.finish(flushPending: true)
    lastStoppedFailure = callbackState?.failure()
    removeConfigurationObserver()
    self.engine = nil
    callbackState = nil
    descriptor = nil
  }

  public func cancel() async {
    prestartedSessionID = nil
    guard let engine else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    callbackState?.finish(flushPending: false)
    lastStoppedFailure = callbackState?.failure()
    removeConfigurationObserver()
    self.engine = nil
    callbackState = nil
    descriptor = nil
  }

  public func currentDeviceInfo() throws -> MicrophoneDeviceInfo {
    try deviceProvider.currentDefaultInput()
  }

  public func lastFailure() -> MacMicrophoneCaptureError? {
    callbackState?.failure()
  }

  public func terminalFailure() async -> DictationFailure? {
    guard let failure = callbackState?.failure() ?? lastStoppedFailure else { return nil }
    let category: DictationFailureCategory
    let code: String
    switch failure {
    case .bufferOverflow:
      category = .resourcePressure
      code = "microphone-buffer-overflow"
    case .permissionNotGranted:
      category = .permissionDenied
      code = "microphone-permission"
    case .noDefaultInputDevice, .deviceMetadataUnavailable:
      category = .targetUnavailable
      code = "microphone-device-unavailable"
    case .alreadyActive, .invalidAudioFormat, .notActive, .unsupportedPCMFormat:
      category = .transientRuntime
      code = "microphone-runtime"
    }
    return try? DictationFailure(
      stage: .capture,
      category: category,
      code: code,
      retryable: true,
      recoveryPhase: .recording
    )
  }

  private func removeConfigurationObserver() {
    guard let configurationObserver else { return }
    NotificationCenter.default.removeObserver(configurationObserver)
    self.configurationObserver = nil
  }
}

public enum MicrophoneSpeechPause: Equatable, Sendable {
  /// The speaker went quiet after speaking; every sample up to this
  /// monotonic time has already been handed to the chunk stream.
  case paused(committedThroughNanoseconds: UInt64)
  /// Speech started again after a reported pause.
  case resumed
}

/// Finds pauses in capture buffers relative to the room's noise floor, so a
/// quiet speaker on a quiet microphone is detected as reliably as a loud one.
/// The floor follows the quietest recent level (down at once, up slowly).
/// Speech is at least 4× the floor, quiet is below 2.5× it; a pause is 200 ms
/// of speech followed by 150 ms of quiet, and speech resumes after 80 ms.
///
/// The quiet threshold is what decides whether a short dictation is already
/// being recognized when the user lets go. Recognizing 1-3 seconds of speech
/// takes about 250 ms, and people release the key within a few hundred
/// milliseconds of their last word, so waiting 350 ms of silence before
/// starting meant every short dictation paid the whole decode after release.
/// A threshold this low also fires between phrases; that costs a speculative
/// decode which the cache either reuses or drops, and only one runs at a time.
struct SpeechPauseDetector {
  enum Event: Equatable { case paused, resumed }

  private var floor: Float = 0.002
  private var speechSeconds = 0.0
  private var quietSeconds = 0.0
  private var resumingSeconds = 0.0
  private var paused = false

  mutating func consume(rms: Float, seconds: Double) -> Event? {
    floor = rms < floor ? rms : floor + (rms - floor) * 0.005
    let speechLevel = max(floor * 4, 0.003)
    let quietLevel = max(floor * 2.5, 0.002)
    if rms >= speechLevel {
      quietSeconds = 0
      guard paused else {
        speechSeconds += seconds
        return nil
      }
      resumingSeconds += seconds
      guard resumingSeconds >= 0.08 else { return nil }
      paused = false
      speechSeconds = resumingSeconds
      resumingSeconds = 0
      return .resumed
    }
    resumingSeconds = 0
    if rms < quietLevel { quietSeconds += seconds }
    guard !paused, speechSeconds >= 0.2, quietSeconds >= 0.15 else { return nil }
    paused = true
    speechSeconds = 0
    return .paused
  }
}

/// Holds the detector for the tap block, which the audio thread calls
/// serially.
private final class SpeechPauseTracker: @unchecked Sendable {
  private var detector = SpeechPauseDetector()

  func consume(rms: Float, seconds: Double) -> SpeechPauseDetector.Event? {
    detector.consume(rms: rms, seconds: seconds)
  }
}
