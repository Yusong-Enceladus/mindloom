import BestASRProcessTapRT
import CoreAudio
import Foundation

@available(macOS 14.2, *)
public final class ProcessTapCaptureSession {
  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
  private var tapDescription: CATapDescription?
  private var recorder: OpaquePointer?
  private var isStarted = false
  private var maximumFrames = 0
  private(set) public var sampleRate: Double = 0

  public init(
    processObjectIDs: [UInt32],
    maximumDuration: TimeInterval,
    deviceUID: String? = nil
  ) throws {
    guard !processObjectIDs.isEmpty, maximumDuration > 0 else {
      throw CoreAudioProbeError.invalidData("capture-configuration")
    }

    let description = CATapDescription()
    description.name = "bestASR SPIKE-CAP-001 \(UUID().uuidString)"
    description.processes = processObjectIDs
    description.isPrivate = true
    description.muteBehavior = .unmuted
    description.isMixdown = true
    description.isMono = true
    description.isExclusive = false
    description.deviceUID = deviceUID
    tapDescription = description

    do {
      try CoreAudioHAL.check(
        AudioHardwareCreateProcessTap(description, &tapID),
        operation: "create-process-tap"
      )
      let tapUID = try Self.stringProperty(
        objectID: tapID,
        selector: kAudioTapPropertyUID
      )
      let format = try Self.formatProperty(objectID: tapID)
      guard format.mSampleRate > 0 else {
        throw CoreAudioProbeError.invalidData("tap-sample-rate")
      }
      sampleRate = format.mSampleRate
      maximumFrames = max(
        1,
        Int((format.mSampleRate * maximumDuration).rounded(.up))
      )

      let aggregateDescription: [String: Any] = [
        kAudioAggregateDeviceNameKey: "bestASR SPIKE-CAP-001 Aggregate",
        kAudioAggregateDeviceUIDKey: "com.bestasr.spike.cap.\(UUID().uuidString)",
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceTapAutoStartKey: false,
        kAudioAggregateDeviceTapListKey: [
          [kAudioSubTapUIDKey: tapUID]
        ],
      ]
      try CoreAudioHAL.check(
        AudioHardwareCreateAggregateDevice(
          aggregateDescription as CFDictionary,
          &aggregateDeviceID
        ),
        operation: "create-tap-aggregate"
      )

      recorder = BestASRProcessTapRTRecorderCreate(
        aggregateDeviceID,
        maximumFrames
      )
      guard recorder != nil else {
        throw CoreAudioProbeError.unavailable("rt-recorder")
      }
    } catch {
      cleanup()
      throw error
    }
  }

  deinit {
    cleanup()
  }

  public func start() throws {
    guard let recorder else {
      throw CoreAudioProbeError.unavailable("rt-recorder")
    }
    try CoreAudioHAL.check(
      BestASRProcessTapRTRecorderStart(recorder),
      operation: "start-tap-io"
    )
    isStarted = true
  }

  public func pause() {
    guard let recorder, isStarted else { return }
    BestASRProcessTapRTRecorderStop(recorder)
    isStarted = false
  }

  public func drainSamples(maximumFrames: Int) -> [Float] {
    guard let recorder, maximumFrames > 0 else { return [] }
    let available = min(
      maximumFrames,
      Int(BestASRProcessTapRTRecorderAvailableFrameCount(recorder))
    )
    guard available > 0 else { return [] }
    var samples = [Float](repeating: 0, count: available)
    let drained = BestASRProcessTapRTRecorderDrainSamples(
      recorder,
      &samples,
      samples.count
    )
    if drained < samples.count {
      samples.removeLast(samples.count - drained)
    }
    return samples
  }

  public var droppedFrameCount: Int {
    guard let recorder else { return 0 }
    return Int(BestASRProcessTapRTRecorderDroppedFrameCount(recorder))
  }

  public func updateProcessObjectIDs(_ processObjectIDs: [UInt32]) throws {
    guard !processObjectIDs.isEmpty, var description = tapDescription else {
      throw CoreAudioProbeError.invalidData("tap-process-list")
    }
    description.processes = processObjectIDs
    var address = CoreAudioHAL.propertyAddress(
      selector: kAudioTapPropertyDescription
    )
    try withUnsafeMutablePointer(to: &description) { pointer in
      try CoreAudioHAL.check(
        AudioObjectSetPropertyData(
          tapID,
          &address,
          0,
          nil,
          UInt32(MemoryLayout<CATapDescription>.stride),
          pointer
        ),
        operation: "update-tap-processes"
      )
    }
    tapDescription = description
  }

  public func finish() -> ProcessTapCaptureSnapshot {
    guard let recorder else {
      return ProcessTapCaptureSnapshot(
        samples: [],
        sampleRate: sampleRate,
        frameCount: 0,
        droppedFrameCount: 0,
        callbackCount: 0,
        firstHostTime: 0,
        lastHostTime: 0
      )
    }
    pause()
    let frameCount = min(
      Int(BestASRProcessTapRTRecorderAvailableFrameCount(recorder)),
      maximumFrames
    )
    var samples = [Float](repeating: 0, count: frameCount)
    let copied = BestASRProcessTapRTRecorderCopySamples(
      recorder,
      &samples,
      samples.count
    )
    if copied < samples.count {
      samples.removeLast(samples.count - copied)
    }
    return ProcessTapCaptureSnapshot(
      samples: samples,
      sampleRate: sampleRate,
      frameCount: copied,
      droppedFrameCount: Int(
        BestASRProcessTapRTRecorderDroppedFrameCount(recorder)
      ),
      callbackCount: BestASRProcessTapRTRecorderCallbackCount(recorder),
      firstHostTime: BestASRProcessTapRTRecorderFirstHostTime(recorder),
      lastHostTime: BestASRProcessTapRTRecorderLastHostTime(recorder)
    )
  }

  public func close() {
    cleanup()
  }

  private func cleanup() {
    if let recorder {
      BestASRProcessTapRTRecorderDestroy(recorder)
      self.recorder = nil
    }
    isStarted = false
    if aggregateDeviceID != kAudioObjectUnknown {
      AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
      aggregateDeviceID = kAudioObjectUnknown
    }
    if tapID != kAudioObjectUnknown {
      AudioHardwareDestroyProcessTap(tapID)
      tapID = kAudioObjectUnknown
    }
  }

  private static func stringProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
  ) throws -> String {
    var address = CoreAudioHAL.propertyAddress(selector: selector)
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.stride)
    try withUnsafeMutablePointer(to: &value) { pointer in
      try CoreAudioHAL.check(
        AudioObjectGetPropertyData(
          objectID,
          &address,
          0,
          nil,
          &size,
          pointer
        ),
        operation: "tap-uid"
      )
    }
    return value as String
  }

  private static func formatProperty(
    objectID: AudioObjectID
  ) throws -> AudioStreamBasicDescription {
    var address = CoreAudioHAL.propertyAddress(
      selector: kAudioTapPropertyFormat
    )
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
    try CoreAudioHAL.check(
      AudioObjectGetPropertyData(
        objectID,
        &address,
        0,
        nil,
        &size,
        &format
      ),
      operation: "tap-format"
    )
    return format
  }
}
