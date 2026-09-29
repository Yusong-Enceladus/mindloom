import Foundation

public enum DiskPressureLevel: String, Codable, Sendable {
  case hard
  case normal
  case soft
}

public struct DiskPressureDecision: Codable, Equatable, Sendable {
  public let level: DiskPressureLevel
  public let captureMayContinue: Bool
  public let heavyInferenceMayRun: Bool

  public init(
    level: DiskPressureLevel,
    captureMayContinue: Bool,
    heavyInferenceMayRun: Bool
  ) {
    self.level = level
    self.captureMayContinue = captureMayContinue
    self.heavyInferenceMayRun = heavyInferenceMayRun
  }
}

public struct RecordingResourceSample: Codable, Equatable, Sendable {
  public let elapsedNanoseconds: UInt64
  public let residentBytes: UInt64
  public let cpuSeconds: Double
  public let thermalState: String

  public init(
    elapsedNanoseconds: UInt64,
    residentBytes: UInt64,
    cpuSeconds: Double,
    thermalState: String
  ) {
    self.elapsedNanoseconds = elapsedNanoseconds
    self.residentBytes = residentBytes
    self.cpuSeconds = cpuSeconds
    self.thermalState = thermalState
  }
}

public struct RecordingDeviceEvent: Codable, Equatable, Sendable {
  public let sourceTrack: String
  public let kind: String
  public let monotonicNanoseconds: UInt64
  public let gapDurationNanoseconds: UInt64

  public init(
    sourceTrack: String,
    kind: String,
    monotonicNanoseconds: UInt64,
    gapDurationNanoseconds: UInt64
  ) {
    self.sourceTrack = sourceTrack
    self.kind = kind
    self.monotonicNanoseconds = monotonicNanoseconds
    self.gapDurationNanoseconds = gapDurationNanoseconds
  }
}

public struct LongRecordingScenario: Codable, Equatable, Sendable {
  public let scenarioID: String
  public let status: String
  public let metrics: [String: String]
  public let errorCategory: String

  public init(
    scenarioID: String,
    status: String,
    metrics: [String: String],
    errorCategory: String = "none"
  ) {
    self.scenarioID = scenarioID
    self.status = status
    self.metrics = metrics
    self.errorCategory = errorCategory
  }
}

public struct LongRecordingEvidence: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let spikeID: String
  public let runID: UUID
  public let generatedAt: Date
  public let requestedDurationNanoseconds: UInt64
  public let measuredDurationNanoseconds: UInt64
  public let chunkDurationNanoseconds: UInt64
  public let committedChunkCount: Int
  public let droppedFrameCount: UInt64
  public let gapCount: Int
  public let driftNanoseconds: Int64
  public let peakResidentBytes: UInt64
  public let cpuSeconds: Double
  public let maximumThermalState: String
  public let resourceSamples: [RecordingResourceSample]
  public let deviceEvents: [RecordingDeviceEvent]
  public let scenarios: [LongRecordingScenario]
  public let conclusion: String

  public init(
    runID: UUID,
    generatedAt: Date,
    requestedDurationNanoseconds: UInt64,
    measuredDurationNanoseconds: UInt64,
    chunkDurationNanoseconds: UInt64,
    committedChunkCount: Int,
    droppedFrameCount: UInt64,
    gapCount: Int,
    driftNanoseconds: Int64,
    peakResidentBytes: UInt64,
    cpuSeconds: Double,
    maximumThermalState: String,
    resourceSamples: [RecordingResourceSample],
    deviceEvents: [RecordingDeviceEvent],
    scenarios: [LongRecordingScenario],
    conclusion: String
  ) {
    schemaVersion = 1
    kind = "long-recording-stability"
    spikeID = "SPIKE-JRN-001"
    self.runID = runID
    self.generatedAt = generatedAt
    self.requestedDurationNanoseconds = requestedDurationNanoseconds
    self.measuredDurationNanoseconds = measuredDurationNanoseconds
    self.chunkDurationNanoseconds = chunkDurationNanoseconds
    self.committedChunkCount = committedChunkCount
    self.droppedFrameCount = droppedFrameCount
    self.gapCount = gapCount
    self.driftNanoseconds = driftNanoseconds
    self.peakResidentBytes = peakResidentBytes
    self.cpuSeconds = cpuSeconds
    self.maximumThermalState = maximumThermalState
    self.resourceSamples = resourceSamples
    self.deviceEvents = deviceEvents
    self.scenarios = scenarios
    self.conclusion = conclusion
  }
}
