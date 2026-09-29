import BestASRDictation
import BestASRDomain
import Foundation

/// Co-captures the selected system-audio boundary and microphone into two
/// independent durable tracks. It never mixes the streams before journaling,
/// so users can export or reprocess either side and the unified speaker pipeline
/// retains track provenance.
@available(macOS 14.2, *)
public actor SystemAudioWithMicrophoneCapture: MicrophoneCapturePort {
  private let systemCapture: ProcessTapSystemAudioCapture
  private let microphoneCapture: AVAudioEngineMicrophoneCapture
  private let streamCapacity: Int

  private var stream: AsyncStream<CapturedPCMChunk>?
  private var continuation: AsyncStream<CapturedPCMChunk>.Continuation?
  private var forwardingTasks: [Task<Void, Never>] = []
  private var prepared = false
  private var stoppedFailure: DictationFailure?

  public init(
    scope: SystemAudioCaptureScope,
    microphoneDeviceUID: String? = nil,
    streamCapacity: Int = 128
  ) {
    systemCapture = ProcessTapSystemAudioCapture(scope: scope)
    microphoneCapture = AVAudioEngineMicrophoneCapture(
      sourceRole: .microphoneLocal,
      selectedDeviceUID: microphoneDeviceUID
    )
    self.streamCapacity = max(16, streamCapacity)
  }

  public func prepare(sessionID: SessionID) async throws
    -> MicrophoneCaptureDescriptor
  {
    guard !prepared else { throw SystemAudioCaptureError.alreadyActive }
    let systemDescriptor = try await systemCapture.prepare(sessionID: sessionID)
    let microphoneDescriptor: MicrophoneCaptureDescriptor
    do {
      microphoneDescriptor = try await microphoneCapture.prepare(
        sessionID: sessionID
      )
    } catch {
      await systemCapture.cancel()
      throw error
    }
    guard
      let systemTracks = systemDescriptor.tracks,
      let microphoneTracks = microphoneDescriptor.tracks,
      !systemTracks.isEmpty,
      !microphoneTracks.isEmpty
    else {
      await systemCapture.cancel()
      await microphoneCapture.cancel()
      throw SystemAudioCaptureError.runtime("missing-track-descriptor")
    }
    let pair = AsyncStream.makeStream(
      of: CapturedPCMChunk.self,
      bufferingPolicy: .bufferingOldest(streamCapacity)
    )
    stream = pair.stream
    continuation = pair.continuation
    prepared = true
    stoppedFailure = nil
    return MicrophoneCaptureDescriptor(
      sessionID: sessionID,
      deviceUID: "system-audio+microphone",
      sampleRateHertz: systemDescriptor.sampleRateHertz,
      channelCount: systemDescriptor.channelCount,
      encoding: systemDescriptor.encoding,
      interleaved: systemDescriptor.interleaved,
      tracks: systemTracks + microphoneTracks
    )
  }

  public func start() async throws {
    guard prepared, continuation != nil else {
      throw SystemAudioCaptureError.notActive
    }
    do {
      try await systemCapture.start()
      try await microphoneCapture.start()
    } catch {
      await systemCapture.cancel()
      await microphoneCapture.cancel()
      throw error
    }
    let systemStream = await systemCapture.chunks()
    let microphoneStream = await microphoneCapture.chunks()
    forwardingTasks = [
      Task { [weak self] in
        for await chunk in systemStream {
          guard let self else { return }
          await self.forward(chunk)
        }
      },
      Task { [weak self] in
        for await chunk in microphoneStream {
          guard let self else { return }
          await self.forward(chunk)
        }
      },
    ]
  }

  public func chunks() async -> AsyncStream<CapturedPCMChunk> {
    stream ?? AsyncStream { $0.finish() }
  }

  public func pause() async throws {
    try await systemCapture.pause()
    do {
      try await microphoneCapture.pause()
    } catch {
      try? await systemCapture.resume()
      throw error
    }
  }

  public func resume() async throws {
    try await systemCapture.resume()
    do {
      try await microphoneCapture.resume()
    } catch {
      try? await systemCapture.pause()
      throw error
    }
  }

  public func stop() async throws {
    guard prepared else { throw SystemAudioCaptureError.notActive }
    var firstError: Error?
    do { try await systemCapture.stop() } catch { firstError = error }
    do { try await microphoneCapture.stop() } catch {
      if firstError == nil { firstError = error }
    }
    for task in forwardingTasks { _ = await task.result }
    forwardingTasks.removeAll()
    let systemFailure = await systemCapture.terminalFailure()
    let microphoneFailure = await microphoneCapture.terminalFailure()
    stoppedFailure = systemFailure ?? microphoneFailure
    continuation?.finish()
    continuation = nil
    stream = nil
    prepared = false
    if let firstError { throw firstError }
  }

  public func cancel() async {
    await systemCapture.cancel()
    await microphoneCapture.cancel()
    for task in forwardingTasks { task.cancel() }
    for task in forwardingTasks { _ = await task.result }
    forwardingTasks.removeAll()
    continuation?.finish()
    continuation = nil
    stream = nil
    prepared = false
  }

  public func terminalFailure() async -> DictationFailure? {
    if let stoppedFailure { return stoppedFailure }
    if let systemFailure = await systemCapture.terminalFailure() {
      return systemFailure
    }
    return await microphoneCapture.terminalFailure()
  }

  private func forward(_ chunk: CapturedPCMChunk) {
    guard let continuation else { return }
    switch continuation.yield(chunk) {
    case .enqueued:
      break
    case .dropped:
      stoppedFailure = try? DictationFailure(
        stage: .capture,
        category: .resourcePressure,
        code: "multi-track-forward-buffer-overflow",
        retryable: true,
        recoveryPhase: .recording
      )
      continuation.finish()
    case .terminated:
      break
    @unknown default:
      continuation.finish()
    }
  }
}
