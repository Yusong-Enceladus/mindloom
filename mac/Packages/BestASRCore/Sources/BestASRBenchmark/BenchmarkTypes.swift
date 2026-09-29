import Foundation

public enum BenchmarkTask: String, Codable, Sendable {
  case asr
  case llm
  case resource
  case speaker
}

public enum BenchmarkCorpusSplit: String, Codable, Sendable {
  case releaseHoldout = "release-holdout"
  case smoke
  case tuning
}

public struct BenchmarkModelArtifact: Codable, Equatable, Sendable {
  public let artifactID: String
  public let sha256: String

  public init(artifactID: String, sha256: String) {
    self.artifactID = artifactID
    self.sha256 = sha256
  }
}

public struct BenchmarkCorpusReference: Codable, Equatable, Sendable {
  public let manifestID: String
  public let version: String
  public let split: BenchmarkCorpusSplit

  public init(
    manifestID: String,
    version: String,
    split: BenchmarkCorpusSplit
  ) {
    self.manifestID = manifestID
    self.version = version
    self.split = split
  }
}

public struct BenchmarkHardwareContext: Codable, Equatable, Sendable {
  public let osVersion: String
  public let architecture: String
  public let unifiedMemoryBytes: UInt64
  public let toolchainVersion: String

  public init(
    osVersion: String,
    architecture: String,
    unifiedMemoryBytes: UInt64,
    toolchainVersion: String
  ) {
    self.osVersion = osVersion
    self.architecture = architecture
    self.unifiedMemoryBytes = unifiedMemoryBytes
    self.toolchainVersion = toolchainVersion
  }
}

public enum DangerousTokenCategory: String, Codable, CaseIterable, Sendable {
  case actionOwner = "action-owner"
  case date
  case negation
  case number
  case person
}

public struct DangerousToken: Codable, Equatable, Sendable {
  public let category: DangerousTokenCategory
  public let value: String

  public init(category: DangerousTokenCategory, value: String) {
    self.category = category
    self.value = value
  }
}

public struct TranscriptEvaluation: Codable, Equatable, Sendable {
  public let reference: String
  public let hypothesis: String
  public let referenceDangerousTokens: [DangerousToken]
  public let hypothesisDangerousTokens: [DangerousToken]

  public init(
    reference: String,
    hypothesis: String,
    referenceDangerousTokens: [DangerousToken] = [],
    hypothesisDangerousTokens: [DangerousToken] = []
  ) {
    self.reference = reference
    self.hypothesis = hypothesis
    self.referenceDangerousTokens = referenceDangerousTokens
    self.hypothesisDangerousTokens = hypothesisDangerousTokens
  }
}

public struct SpeakerSegment: Codable, Equatable, Sendable {
  public let speakerID: String
  public let startNanoseconds: UInt64
  public let endNanoseconds: UInt64

  public init(
    speakerID: String,
    startNanoseconds: UInt64,
    endNanoseconds: UInt64
  ) {
    self.speakerID = speakerID
    self.startNanoseconds = startNanoseconds
    self.endNanoseconds = endNanoseconds
  }
}

public struct DiarizationEvaluation: Codable, Equatable, Sendable {
  public let reference: [SpeakerSegment]
  public let hypothesis: [SpeakerSegment]

  public init(reference: [SpeakerSegment], hypothesis: [SpeakerSegment]) {
    self.reference = reference
    self.hypothesis = hypothesis
  }
}

public struct IdentityAssignment: Codable, Equatable, Sendable {
  public let occurrenceID: UUID
  public let expectedPersonID: String
  public let predictedPersonID: String?
  public let evidenceSufficient: Bool

  public init(
    occurrenceID: UUID,
    expectedPersonID: String,
    predictedPersonID: String?,
    evidenceSufficient: Bool
  ) {
    self.occurrenceID = occurrenceID
    self.expectedPersonID = expectedPersonID
    self.predictedPersonID = predictedPersonID
    self.evidenceSufficient = evidenceSufficient
  }
}

public struct BenchmarkSampleInput: Codable, Equatable, Sendable {
  public let sampleUUID: UUID
  public let transcript: TranscriptEvaluation?
  public let diarization: DiarizationEvaluation?
  public let identityAssignments: [IdentityAssignment]
  public let audioDurationNanoseconds: UInt64
  public let inferenceDurationNanoseconds: UInt64
  public let latencyNanoseconds: UInt64
  public let peakResidentBytes: UInt64
  public let backlogHighWatermark: UInt64
  public let failureCategory: String?

  public init(
    sampleUUID: UUID,
    transcript: TranscriptEvaluation? = nil,
    diarization: DiarizationEvaluation? = nil,
    identityAssignments: [IdentityAssignment] = [],
    audioDurationNanoseconds: UInt64,
    inferenceDurationNanoseconds: UInt64,
    latencyNanoseconds: UInt64,
    peakResidentBytes: UInt64,
    backlogHighWatermark: UInt64,
    failureCategory: String? = nil
  ) {
    self.sampleUUID = sampleUUID
    self.transcript = transcript
    self.diarization = diarization
    self.identityAssignments = identityAssignments
    self.audioDurationNanoseconds = audioDurationNanoseconds
    self.inferenceDurationNanoseconds = inferenceDurationNanoseconds
    self.latencyNanoseconds = latencyNanoseconds
    self.peakResidentBytes = peakResidentBytes
    self.backlogHighWatermark = backlogHighWatermark
    self.failureCategory = failureCategory
  }
}

public struct BenchmarkRunInput: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let benchmarkID: String
  public let runID: UUID
  public let task: BenchmarkTask
  public let protocolVersion: Int
  public let implementationRevision: String
  public let modelArtifact: BenchmarkModelArtifact
  public let configuration: [String: String]
  public let corpus: BenchmarkCorpusReference
  public let environmentRef: String
  public let hardware: BenchmarkHardwareContext
  public let samples: [BenchmarkSampleInput]

  public init(
    schemaVersion: Int = 1,
    kind: String = "benchmark-run",
    benchmarkID: String,
    runID: UUID = UUID(),
    task: BenchmarkTask,
    protocolVersion: Int,
    implementationRevision: String,
    modelArtifact: BenchmarkModelArtifact,
    configuration: [String: String],
    corpus: BenchmarkCorpusReference,
    environmentRef: String,
    hardware: BenchmarkHardwareContext,
    samples: [BenchmarkSampleInput]
  ) {
    self.schemaVersion = schemaVersion
    self.kind = kind
    self.benchmarkID = benchmarkID
    self.runID = runID
    self.task = task
    self.protocolVersion = protocolVersion
    self.implementationRevision = implementationRevision
    self.modelArtifact = modelArtifact
    self.configuration = configuration
    self.corpus = corpus
    self.environmentRef = environmentRef
    self.hardware = hardware
    self.samples = samples
  }
}

public enum BenchmarkMetricDirection: String, Codable, Sendable {
  case higherIsBetter = "higher-is-better"
  case informational
  case lowerIsBetter = "lower-is-better"
}

public struct BenchmarkMetric: Codable, Equatable, Sendable {
  public let name: String
  public let value: Double
  public let unit: String
  public let direction: BenchmarkMetricDirection

  public init(
    name: String,
    value: Double,
    unit: String,
    direction: BenchmarkMetricDirection
  ) {
    self.name = name
    self.value = value
    self.unit = unit
    self.direction = direction
  }
}

public struct BenchmarkResult: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let benchmarkID: String
  public let runID: UUID
  public let task: BenchmarkTask
  public let protocolVersion: Int
  public let implementationRevision: String
  public let modelArtifact: BenchmarkModelArtifact
  public let configHash: String
  public let corpus: BenchmarkCorpusReference
  public let environmentRef: String
  public let hardware: BenchmarkHardwareContext
  public let metrics: [BenchmarkMetric]
  public let failedSampleUUIDs: [UUID]

  public init(
    schemaVersion: Int = 1,
    kind: String = "benchmark-result",
    benchmarkID: String,
    runID: UUID,
    task: BenchmarkTask,
    protocolVersion: Int,
    implementationRevision: String,
    modelArtifact: BenchmarkModelArtifact,
    configHash: String,
    corpus: BenchmarkCorpusReference,
    environmentRef: String,
    hardware: BenchmarkHardwareContext,
    metrics: [BenchmarkMetric],
    failedSampleUUIDs: [UUID]
  ) {
    self.schemaVersion = schemaVersion
    self.kind = kind
    self.benchmarkID = benchmarkID
    self.runID = runID
    self.task = task
    self.protocolVersion = protocolVersion
    self.implementationRevision = implementationRevision
    self.modelArtifact = modelArtifact
    self.configHash = configHash
    self.corpus = corpus
    self.environmentRef = environmentRef
    self.hardware = hardware
    self.metrics = metrics
    self.failedSampleUUIDs = failedSampleUUIDs
  }
}

public enum BenchmarkError: Error, Equatable, Sendable {
  case emptySamples
  case invalidArtifactDigest
  case invalidBenchmarkID
  case invalidConfiguration
  case invalidDuration
  case invalidEnvironmentReference
  case invalidSegment
  case unsupportedKind
  case unsupportedSchemaVersion
}
