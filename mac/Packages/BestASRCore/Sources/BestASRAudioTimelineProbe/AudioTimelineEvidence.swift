import Foundation

public enum ProbeSourceRole: String, Codable, CaseIterable, Sendable {
  case microphoneLocal
  case systemRemote
}

public enum ProbeDiscontinuityReason: String, Codable, Sendable {
  case deviceDisconnected
  case deviceReconnected
  case sampleRateChanged
}

public struct ProbeTrack: Codable, Equatable, Sendable {
  public let trackID: String
  public let sourceRole: ProbeSourceRole
  public let clockDomain: String

  public init(
    trackID: String,
    sourceRole: ProbeSourceRole,
    clockDomain: String
  ) {
    self.trackID = trackID
    self.sourceRole = sourceRole
    self.clockDomain = clockDomain
  }
}

public struct ProbeAudioChunk: Codable, Equatable, Sendable {
  public let trackID: String
  public let segment: UInt32
  public let sequence: UInt64
  public let hostTime: UInt64
  public let monotonicStartNanoseconds: UInt64
  public let sampleRateHertz: UInt32
  public let frameCount: UInt32
  public let contentDigest: String
  public let discontinuity: ProbeDiscontinuityReason?

  public init(
    trackID: String,
    segment: UInt32,
    sequence: UInt64,
    hostTime: UInt64,
    monotonicStartNanoseconds: UInt64,
    sampleRateHertz: UInt32,
    frameCount: UInt32,
    contentDigest: String,
    discontinuity: ProbeDiscontinuityReason? = nil
  ) {
    self.trackID = trackID
    self.segment = segment
    self.sequence = sequence
    self.hostTime = hostTime
    self.monotonicStartNanoseconds = monotonicStartNanoseconds
    self.sampleRateHertz = sampleRateHertz
    self.frameCount = frameCount
    self.contentDigest = contentDigest
    self.discontinuity = discontinuity
  }
}

public struct ProbeTimelineBoundary: Codable, Equatable, Sendable {
  public let trackID: String
  public let fromSegment: UInt32
  public let toSegment: UInt32
  public let monotonicNanoseconds: UInt64
  public let reason: ProbeDiscontinuityReason
  public let priorSampleRateHertz: UInt32
  public let nextSampleRateHertz: UInt32
  public let gapDurationNanoseconds: UInt64

  public init(
    trackID: String,
    fromSegment: UInt32,
    toSegment: UInt32,
    monotonicNanoseconds: UInt64,
    reason: ProbeDiscontinuityReason,
    priorSampleRateHertz: UInt32,
    nextSampleRateHertz: UInt32,
    gapDurationNanoseconds: UInt64 = 0
  ) {
    self.trackID = trackID
    self.fromSegment = fromSegment
    self.toSegment = toSegment
    self.monotonicNanoseconds = monotonicNanoseconds
    self.reason = reason
    self.priorSampleRateHertz = priorSampleRateHertz
    self.nextSampleRateHertz = nextSampleRateHertz
    self.gapDurationNanoseconds = gapDurationNanoseconds
  }
}

public struct ProbePulseObservation: Codable, Equatable, Sendable {
  public let pulseID: String
  public let trackID: String
  public let expectedMonotonicNanoseconds: UInt64
  public let observedMonotonicNanoseconds: UInt64
  public let absoluteErrorNanoseconds: UInt64

  public init(
    pulseID: String,
    trackID: String,
    expectedMonotonicNanoseconds: UInt64,
    observedMonotonicNanoseconds: UInt64,
    absoluteErrorNanoseconds: UInt64
  ) {
    self.pulseID = pulseID
    self.trackID = trackID
    self.expectedMonotonicNanoseconds = expectedMonotonicNanoseconds
    self.observedMonotonicNanoseconds = observedMonotonicNanoseconds
    self.absoluteErrorNanoseconds = absoluteErrorNanoseconds
  }
}

public struct ProbeDriftObservation: Codable, Equatable, Sendable {
  public let nominalSampleRateHertz: Double
  public let observedSampleRateHertz: Double
  public let expectedPartsPerMillion: Double
  public let measuredPartsPerMillion: Double

  public init(
    nominalSampleRateHertz: Double,
    observedSampleRateHertz: Double,
    expectedPartsPerMillion: Double,
    measuredPartsPerMillion: Double
  ) {
    self.nominalSampleRateHertz = nominalSampleRateHertz
    self.observedSampleRateHertz = observedSampleRateHertz
    self.expectedPartsPerMillion = expectedPartsPerMillion
    self.measuredPartsPerMillion = measuredPartsPerMillion
  }
}

public struct AudioTimelineScenario: Codable, Equatable, Sendable {
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

public struct AudioTimelineMatrixEvidence: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let spikeID: String
  public let runID: UUID
  public let generatedAt: Date
  public let tracks: [ProbeTrack]
  public let chunks: [ProbeAudioChunk]
  public let boundaries: [ProbeTimelineBoundary]
  public let pulseObservations: [ProbePulseObservation]
  public let drift: ProbeDriftObservation
  public let scenarios: [AudioTimelineScenario]

  public init(
    runID: UUID,
    generatedAt: Date,
    tracks: [ProbeTrack],
    chunks: [ProbeAudioChunk],
    boundaries: [ProbeTimelineBoundary],
    pulseObservations: [ProbePulseObservation],
    drift: ProbeDriftObservation,
    scenarios: [AudioTimelineScenario]
  ) {
    schemaVersion = 1
    kind = "audio-timeline-matrix"
    spikeID = "SPIKE-TIM-001"
    self.runID = runID
    self.generatedAt = generatedAt
    self.tracks = tracks
    self.chunks = chunks
    self.boundaries = boundaries
    self.pulseObservations = pulseObservations
    self.drift = drift
    self.scenarios = scenarios
  }
}
