import AVFoundation
import BestASRDictation
import Foundation

private final class MicrophoneLevelCallback: @unchecked Sendable {
  let continuation: AsyncStream<Double>.Continuation

  init(_ continuation: AsyncStream<Double>.Continuation) {
    self.continuation = continuation
  }

  func receive(_ buffer: AVAudioPCMBuffer) {
    guard let channels = buffer.floatChannelData,
      buffer.frameLength > 0,
      buffer.format.channelCount > 0
    else { return }
    let frames = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    var sum = 0.0
    for channel in 0..<channelCount {
      for frame in 0..<frames {
        let sample = Double(channels[channel][frame])
        sum += sample * sample
      }
    }
    let rms = sqrt(sum / Double(frames * channelCount))
    _ = continuation.yield(min(1, max(0, rms / 0.20)))
  }
}

/// A short-lived local meter used before room recording. It never stores or
/// forwards audio and must be stopped before the durable recorder starts.
public actor AVAudioEngineMicrophoneLevelMonitor {
  private let selectedDeviceUID: String?
  private var engine: AVAudioEngine?
  private var continuation: AsyncStream<Double>.Continuation?
  private var stream: AsyncStream<Double>?

  public init(selectedDeviceUID: String? = nil) {
    self.selectedDeviceUID = selectedDeviceUID
  }

  public func start() throws -> AsyncStream<Double> {
    guard engine == nil else { throw MacMicrophoneCaptureError.alreadyActive }
    let permission = SystemMicrophoneAuthorizationChecker().state()
    guard permission == .granted else {
      throw MacMicrophoneCaptureError.permissionNotGranted(permission)
    }
    let device = try MicrophoneDeviceCatalog.device(uid: selectedDeviceUID)
    let newEngine = AVAudioEngine()
    let input = newEngine.inputNode
    if selectedDeviceUID != nil {
      try MicrophoneDeviceCatalog.select(deviceID: device.deviceID, for: input)
    }
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw MacMicrophoneCaptureError.invalidAudioFormat
    }
    let pair = AsyncStream.makeStream(
      of: Double.self,
      bufferingPolicy: .bufferingNewest(4)
    )
    let callback = MicrophoneLevelCallback(pair.continuation)
    input.installTap(
      onBus: 0,
      bufferSize: 1_024,
      format: format
    ) { buffer, _ in callback.receive(buffer) }
    newEngine.prepare()
    do {
      try newEngine.start()
    } catch {
      input.removeTap(onBus: 0)
      pair.continuation.finish()
      throw error
    }
    engine = newEngine
    continuation = pair.continuation
    stream = pair.stream
    return pair.stream
  }

  public func stop() {
    guard let engine else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    continuation?.finish()
    self.engine = nil
    continuation = nil
    stream = nil
  }
}
