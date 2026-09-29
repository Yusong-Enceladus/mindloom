import CoreAudio
import Foundation

public struct AudioProcessSnapshot: Codable, Equatable, Sendable {
  public let objectID: UInt32
  public let processID: Int32
  public let parentProcessID: Int32
  public let bundleID: String
  public let displayName: String
  public let isRunningOutput: Bool

  public init(
    objectID: UInt32,
    processID: Int32,
    parentProcessID: Int32,
    bundleID: String,
    displayName: String,
    isRunningOutput: Bool
  ) {
    self.objectID = objectID
    self.processID = processID
    self.parentProcessID = parentProcessID
    self.bundleID = bundleID
    self.displayName = displayName
    self.isRunningOutput = isRunningOutput
  }
}

public struct ApplicationAudioGroup: Codable, Equatable, Sendable {
  public let identity: String
  public let displayName: String
  public let bundleID: String?
  public let processIDs: [Int32]
  public let audioObjectIDs: [UInt32]
  public let hasRunningOutput: Bool

  public init(
    identity: String,
    displayName: String,
    bundleID: String?,
    processIDs: [Int32],
    audioObjectIDs: [UInt32],
    hasRunningOutput: Bool
  ) {
    self.identity = identity
    self.displayName = displayName
    self.bundleID = bundleID
    self.processIDs = processIDs
    self.audioObjectIDs = audioObjectIDs
    self.hasRunningOutput = hasRunningOutput
  }
}

public struct AudioOutputDeviceSnapshot: Codable, Equatable, Sendable {
  public let objectID: UInt32
  public let uid: String
  public let name: String
  public let transportType: UInt32
  public let isDefaultOutput: Bool

  public init(
    objectID: UInt32,
    uid: String,
    name: String,
    transportType: UInt32,
    isDefaultOutput: Bool
  ) {
    self.objectID = objectID
    self.uid = uid
    self.name = name
    self.transportType = transportType
    self.isDefaultOutput = isDefaultOutput
  }
}

public enum ProcessTapLifecycleEventKind: String, Codable, Sendable {
  case aggregateCreated
  case captureStarted
  case captureStopped
  case deviceChanged
  case permissionRejected
  case processAdded
  case processRemoved
  case sourceRestarted
  case tapCreated
  case tapReconfigured
}

public struct ProcessTapLifecycleEvent: Codable, Equatable, Sendable {
  public let kind: ProcessTapLifecycleEventKind
  public let monotonicNanoseconds: UInt64
  public let processID: Int32?
  public let detail: String

  public init(
    kind: ProcessTapLifecycleEventKind,
    monotonicNanoseconds: UInt64,
    processID: Int32? = nil,
    detail: String
  ) {
    self.kind = kind
    self.monotonicNanoseconds = monotonicNanoseconds
    self.processID = processID
    self.detail = detail
  }
}

public struct ProcessTapCaptureSnapshot: Equatable, Sendable {
  public let samples: [Float]
  public let sampleRate: Double
  public let frameCount: Int
  public let droppedFrameCount: Int
  public let callbackCount: UInt64
  public let firstHostTime: UInt64
  public let lastHostTime: UInt64

  public init(
    samples: [Float],
    sampleRate: Double,
    frameCount: Int,
    droppedFrameCount: Int,
    callbackCount: UInt64,
    firstHostTime: UInt64,
    lastHostTime: UInt64
  ) {
    self.samples = samples
    self.sampleRate = sampleRate
    self.frameCount = frameCount
    self.droppedFrameCount = droppedFrameCount
    self.callbackCount = callbackCount
    self.firstHostTime = firstHostTime
    self.lastHostTime = lastHostTime
  }
}

public struct WatermarkMeasurement: Codable, Equatable, Sendable {
  public let frequency: Double
  public let amplitude: Double
  public let detected: Bool

  public init(frequency: Double, amplitude: Double, detected: Bool) {
    self.frequency = frequency
    self.amplitude = amplitude
    self.detected = detected
  }
}

public struct ProcessTapMatrixScenario: Codable, Equatable, Sendable {
  public let scenarioID: String
  public let status: String
  public let evidenceMode: String
  public let metrics: [String: String]
  public let lifecycleEvents: [ProcessTapLifecycleEvent]

  public init(
    scenarioID: String,
    status: String,
    evidenceMode: String,
    metrics: [String: String],
    lifecycleEvents: [ProcessTapLifecycleEvent] = []
  ) {
    self.scenarioID = scenarioID
    self.status = status
    self.evidenceMode = evidenceMode
    self.metrics = metrics
    self.lifecycleEvents = lifecycleEvents
  }
}

public struct ProcessTapMatrixEvidence: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let spikeID: String
  public let runID: UUID
  public let generatedAt: Date
  public let osVersion: String
  public let hardwareArchitecture: String
  public let scenarios: [ProcessTapMatrixScenario]

  public init(
    runID: UUID,
    generatedAt: Date,
    osVersion: String,
    hardwareArchitecture: String,
    scenarios: [ProcessTapMatrixScenario]
  ) {
    schemaVersion = 1
    kind = "process-tap-boundary-matrix"
    spikeID = "SPIKE-CAP-001"
    self.runID = runID
    self.generatedAt = generatedAt
    self.osVersion = osVersion
    self.hardwareArchitecture = hardwareArchitecture
    self.scenarios = scenarios
  }
}

public struct ProcessTapTCCDenialEvidence: Codable, Equatable, Sendable {
  public static let expectedProbeBundleIdentifier =
    "com.bestasr.spike.process-tap-tcc-denial-probe.v2"

  public let schemaVersion: Int
  public let kind: String
  public let spikeID: String
  public let runID: UUID
  public let generatedAt: Date
  public let osVersion: String
  public let hardwareArchitecture: String
  public let probeBundleIdentifier: String
  public let status: String
  public let denialObserved: Bool
  public let operatorConfirmedDenial: Bool
  public let tapCreated: Bool
  public let createTapStatus: Int32
  public let captureStarted: Bool
  public let startCaptureStatus: Int32
  public let callbackCount: UInt64
  public let frameCount: Int
  public let capturedRMS: Double
  public let capturedWatermarkAmplitude: Double
  public let watermarkDetected: Bool
  public let audioContentSuppressed: Bool
  public let tapCountBefore: Int
  public let tapCountAfter: Int
  public let aggregateDeviceCountBefore: Int
  public let aggregateDeviceCountAfter: Int
  public let syntheticSourceOnly: Bool
  public let sourceAudioPersisted: Bool
  public let failureCategory: String

  public init(
    runID: UUID,
    generatedAt: Date,
    osVersion: String,
    hardwareArchitecture: String,
    probeBundleIdentifier: String,
    status: String,
    denialObserved: Bool,
    operatorConfirmedDenial: Bool,
    tapCreated: Bool,
    createTapStatus: Int32,
    captureStarted: Bool,
    startCaptureStatus: Int32,
    callbackCount: UInt64,
    frameCount: Int,
    capturedRMS: Double,
    capturedWatermarkAmplitude: Double,
    watermarkDetected: Bool,
    audioContentSuppressed: Bool,
    tapCountBefore: Int,
    tapCountAfter: Int,
    aggregateDeviceCountBefore: Int,
    aggregateDeviceCountAfter: Int,
    syntheticSourceOnly: Bool,
    sourceAudioPersisted: Bool,
    failureCategory: String
  ) {
    schemaVersion = 1
    kind = "process-tap-tcc-denial"
    spikeID = "SPIKE-CAP-001"
    self.runID = runID
    self.generatedAt = generatedAt
    self.osVersion = osVersion
    self.hardwareArchitecture = hardwareArchitecture
    self.probeBundleIdentifier = probeBundleIdentifier
    self.status = status
    self.denialObserved = denialObserved
    self.operatorConfirmedDenial = operatorConfirmedDenial
    self.tapCreated = tapCreated
    self.createTapStatus = createTapStatus
    self.captureStarted = captureStarted
    self.startCaptureStatus = startCaptureStatus
    self.callbackCount = callbackCount
    self.frameCount = frameCount
    self.capturedRMS = capturedRMS
    self.capturedWatermarkAmplitude = capturedWatermarkAmplitude
    self.watermarkDetected = watermarkDetected
    self.audioContentSuppressed = audioContentSuppressed
    self.tapCountBefore = tapCountBefore
    self.tapCountAfter = tapCountAfter
    self.aggregateDeviceCountBefore = aggregateDeviceCountBefore
    self.aggregateDeviceCountAfter = aggregateDeviceCountAfter
    self.syntheticSourceOnly = syntheticSourceOnly
    self.sourceAudioPersisted = sourceAudioPersisted
    self.failureCategory = failureCategory
  }

  public var isConfirmedDenial: Bool {
    let deniedBeforeIOStart =
      !captureStarted
      && startCaptureStatus != kAudioHardwareNoError
      && callbackCount == 0
      && frameCount == 0
      && audioContentSuppressed
      && !watermarkDetected
      && failureCategory == "tcc-denied-before-capture-start"
    let deniedByContentSuppression =
      captureStarted
      && startCaptureStatus == kAudioHardwareNoError
      && callbackCount > 0
      && frameCount >= 128
      && capturedRMS <= 0.000_001
      && capturedWatermarkAmplitude < 0.001
      && audioContentSuppressed
      && !watermarkDetected
      && failureCategory == "tcc-denied-audio-content-suppressed"

    return schemaVersion == 1
      && kind == "process-tap-tcc-denial"
      && spikeID == "SPIKE-CAP-001"
      && probeBundleIdentifier == Self.expectedProbeBundleIdentifier
      && status == "pass"
      && denialObserved
      && operatorConfirmedDenial
      && tapCreated
      && createTapStatus == kAudioHardwareNoError
      && (deniedBeforeIOStart || deniedByContentSuppression)
      && tapCountBefore == tapCountAfter
      && aggregateDeviceCountBefore == aggregateDeviceCountAfter
      && syntheticSourceOnly
      && !sourceAudioPersisted
  }
}
