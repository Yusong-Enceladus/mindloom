import Foundation

public enum InferenceContract {
  public static let currentVersion = 1
}

public struct InferenceCapability: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    rawValue = try container.decode(String.self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public static let asrBatch = Self("asr.batch")
  public static let asrContextTerms = Self("asr.context-terms")
  public static let asrMultilingual = Self("asr.multilingual")
  public static let asrRevisioned = Self("asr.revisioned")
  public static let asrStreaming = Self("asr.streaming")
  public static let asrTimestamps = Self("asr.timestamps")
  public static let diarizationBatch = Self("diarization.batch")
  public static let diarizationStreaming = Self("diarization.streaming")
  public static let localTextStructured = Self("local-text.structured")
  public static let speakerEmbedding = Self("speaker.embedding")
}

public struct InferenceRuntimeID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    rawValue = try container.decode(String.self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct InferenceOSVersion: Codable, Comparable, Equatable, Sendable {
  public let major: Int
  public let minor: Int
  public let patch: Int

  public init(major: Int, minor: Int, patch: Int = 0) {
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }
}

public struct ModelArtifactDescriptor: Codable, Equatable, Sendable {
  public let artifactID: String
  public let version: String
  public let sha256: String
  public let runtimeID: InferenceRuntimeID
  public let capabilities: [InferenceCapability]
  public let minimumOS: InferenceOSVersion
  public let supportedArchitectures: [String]
  public let minimumUnifiedMemoryBytes: UInt64
  public let licenseIdentifier: String
  public let networkRequired: Bool
  public let metadata: [String: String]

  public init(
    artifactID: String,
    version: String,
    sha256: String,
    runtimeID: InferenceRuntimeID,
    capabilities: [InferenceCapability],
    minimumOS: InferenceOSVersion,
    supportedArchitectures: [String],
    minimumUnifiedMemoryBytes: UInt64,
    licenseIdentifier: String,
    networkRequired: Bool,
    metadata: [String: String] = [:]
  ) {
    self.artifactID = artifactID
    self.version = version
    self.sha256 = sha256
    self.runtimeID = runtimeID
    self.capabilities = Array(Set(capabilities)).sorted { $0.rawValue < $1.rawValue }
    self.minimumOS = minimumOS
    self.supportedArchitectures = Array(Set(supportedArchitectures)).sorted()
    self.minimumUnifiedMemoryBytes = minimumUnifiedMemoryBytes
    self.licenseIdentifier = licenseIdentifier
    self.networkRequired = networkRequired
    self.metadata = metadata
  }
}

public struct CapabilityRequirement: Codable, Equatable, Sendable {
  public let capabilities: [InferenceCapability]
  public let allowedRuntimeIDs: [InferenceRuntimeID]
  public let offlineRequired: Bool

  public init(
    capabilities: [InferenceCapability],
    allowedRuntimeIDs: [InferenceRuntimeID] = [],
    offlineRequired: Bool = true
  ) {
    self.capabilities = Array(Set(capabilities)).sorted { $0.rawValue < $1.rawValue }
    self.allowedRuntimeIDs = Array(Set(allowedRuntimeIDs)).sorted {
      $0.rawValue < $1.rawValue
    }
    self.offlineRequired = offlineRequired
  }
}

public struct InferenceRuntimeEnvironment: Codable, Equatable, Sendable {
  public let osVersion: InferenceOSVersion
  public let architecture: String
  public let unifiedMemoryBytes: UInt64

  public init(
    osVersion: InferenceOSVersion,
    architecture: String,
    unifiedMemoryBytes: UInt64
  ) {
    self.osVersion = osVersion
    self.architecture = architecture
    self.unifiedMemoryBytes = unifiedMemoryBytes
  }
}

public enum ModelRegistryError: Error, Equatable, Sendable {
  case duplicateArtifactID(String)
  case emptyArtifactID
  case emptyCapabilities
  case invalidDigest
  case missingLicense
}

public protocol ModelRegistry: Sendable {
  func register(_ artifact: ModelArtifactDescriptor) async throws
  func artifact(id: String) async -> ModelArtifactDescriptor?
  func compatibleArtifacts(
    for requirement: CapabilityRequirement,
    environment: InferenceRuntimeEnvironment
  ) async -> [ModelArtifactDescriptor]
}

public actor CapabilityModelRegistry: ModelRegistry {
  private var artifacts: [String: ModelArtifactDescriptor] = [:]

  public init() {}

  public func register(_ artifact: ModelArtifactDescriptor) throws {
    guard !artifact.artifactID.isEmpty else {
      throw ModelRegistryError.emptyArtifactID
    }
    guard !artifact.capabilities.isEmpty else {
      throw ModelRegistryError.emptyCapabilities
    }
    guard
      artifact.sha256.range(
        of: "^[0-9a-f]{64}$",
        options: .regularExpression
      ) != nil
    else {
      throw ModelRegistryError.invalidDigest
    }
    guard !artifact.licenseIdentifier.isEmpty else {
      throw ModelRegistryError.missingLicense
    }
    guard artifacts[artifact.artifactID] == nil else {
      throw ModelRegistryError.duplicateArtifactID(artifact.artifactID)
    }
    artifacts[artifact.artifactID] = artifact
  }

  public func artifact(id: String) -> ModelArtifactDescriptor? {
    artifacts[id]
  }

  public func compatibleArtifacts(
    for requirement: CapabilityRequirement,
    environment: InferenceRuntimeEnvironment
  ) -> [ModelArtifactDescriptor] {
    let required = Set(requirement.capabilities)
    let runtimes = Set(requirement.allowedRuntimeIDs)
    return artifacts.values.filter { artifact in
      required.isSubset(of: Set(artifact.capabilities))
        && (runtimes.isEmpty || runtimes.contains(artifact.runtimeID))
        && (!requirement.offlineRequired || !artifact.networkRequired)
        && artifact.minimumOS <= environment.osVersion
        && artifact.supportedArchitectures.contains(environment.architecture)
        && artifact.minimumUnifiedMemoryBytes <= environment.unifiedMemoryBytes
    }.sorted { $0.artifactID < $1.artifactID }
  }
}

public struct InferenceRequestMetadata: Codable, Equatable, Sendable {
  public let contractVersion: Int
  public let jobID: UUID
  public let inputRevision: UInt64
  public let modelArtifactID: String
  public let configHash: String

  public init(
    contractVersion: Int = InferenceContract.currentVersion,
    jobID: UUID,
    inputRevision: UInt64,
    modelArtifactID: String,
    configHash: String
  ) {
    self.contractVersion = contractVersion
    self.jobID = jobID
    self.inputRevision = inputRevision
    self.modelArtifactID = modelArtifactID
    self.configHash = configHash
  }
}

public struct AudioRangeInput: Codable, Equatable, Sendable {
  public let sourceID: UUID
  public let trackID: UUID
  public let assetReference: String
  public let contentDigest: String
  public let monotonicStartNanoseconds: UInt64
  public let monotonicEndNanoseconds: UInt64
  public let sampleRateHertz: UInt32
  public let channelCount: UInt16

  public init(
    sourceID: UUID,
    trackID: UUID,
    assetReference: String,
    contentDigest: String,
    monotonicStartNanoseconds: UInt64,
    monotonicEndNanoseconds: UInt64,
    sampleRateHertz: UInt32,
    channelCount: UInt16
  ) {
    self.sourceID = sourceID
    self.trackID = trackID
    self.assetReference = assetReference
    self.contentDigest = contentDigest
    self.monotonicStartNanoseconds = monotonicStartNanoseconds
    self.monotonicEndNanoseconds = monotonicEndNanoseconds
    self.sampleRateHertz = sampleRateHertz
    self.channelCount = channelCount
  }
}

public struct InferenceEngineDescriptor: Codable, Equatable, Sendable {
  public let contractVersion: Int
  public let artifact: ModelArtifactDescriptor

  public init(
    contractVersion: Int = InferenceContract.currentVersion,
    artifact: ModelArtifactDescriptor
  ) {
    self.contractVersion = contractVersion
    self.artifact = artifact
  }
}

public enum InferenceFailureCategory: String, Codable, Sendable {
  case cancelled
  case corruptInput
  case incompatibleArtifact
  case invalidRequest
  case modelUnavailable
  case resourcePressure
  case transientRuntime
  case unsupportedContractVersion
}

public struct InferenceEngineError: Error, Codable, Equatable, Sendable {
  public let category: InferenceFailureCategory
  public let code: String
  public let retryable: Bool

  public init(
    category: InferenceFailureCategory,
    code: String,
    retryable: Bool
  ) {
    self.category = category
    self.code = code
    self.retryable = retryable
  }

  public static let cancelled = Self(
    category: .cancelled,
    code: "task-cancelled",
    retryable: true
  )
}

public enum InferenceCancellation {
  public static func check() throws {
    if Task.isCancelled {
      throw InferenceEngineError.cancelled
    }
  }
}

public enum ASRMode: String, Codable, Sendable {
  case final
  case streaming
}

/// A local dictionary entry projected into the inference boundary.  The
/// canonical form is the text that may be emitted; spoken forms are explicit
/// surfaces that may be rewritten to it.  Runtime adapters must still bound
/// and validate every value before inference.
public struct ASRDictionaryHint: Codable, Equatable, Sendable {
  public let canonicalForm: String
  public let spokenForms: [String]

  public init(canonicalForm: String, spokenForms: [String] = []) {
    self.canonicalForm = canonicalForm
    self.spokenForms = spokenForms
  }
}

public struct ASRContextSegment: Codable, Equatable, Sendable {
  public let text: String
  public let monotonicEndNanoseconds: UInt64

  public init(text: String, monotonicEndNanoseconds: UInt64) {
    self.text = text
    self.monotonicEndNanoseconds = monotonicEndNanoseconds
  }
}

public struct ASRRecognitionContext: Codable, Equatable, Sendable {
  public let dictionaryTerms: [String]
  public let dictionaryHints: [ASRDictionaryHint]
  public let priorStableSegments: [ASRContextSegment]

  public init(
    dictionaryTerms: [String] = [],
    priorStableSegments: [ASRContextSegment] = []
  ) {
    self.init(
      dictionaryTerms: dictionaryTerms,
      dictionaryHints: [],
      priorStableSegments: priorStableSegments
    )
  }

  public init(
    dictionaryTerms: [String],
    dictionaryHints: [ASRDictionaryHint],
    priorStableSegments: [ASRContextSegment] = []
  ) {
    self.dictionaryTerms = dictionaryTerms
    self.dictionaryHints = dictionaryHints
    self.priorStableSegments = priorStableSegments
  }

  private enum CodingKeys: String, CodingKey {
    case dictionaryTerms
    case dictionaryHints
    case priorStableSegments
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    dictionaryTerms =
      try container.decodeIfPresent(
        [String].self,
        forKey: .dictionaryTerms
      ) ?? []
    dictionaryHints =
      try container.decodeIfPresent(
        [ASRDictionaryHint].self,
        forKey: .dictionaryHints
      ) ?? []
    priorStableSegments =
      try container.decodeIfPresent(
        [ASRContextSegment].self,
        forKey: .priorStableSegments
      ) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(dictionaryTerms, forKey: .dictionaryTerms)
    try container.encode(dictionaryHints, forKey: .dictionaryHints)
    try container.encode(priorStableSegments, forKey: .priorStableSegments)
  }

  public func bounded(
    maximumDictionaryTerms: Int,
    maximumPriorSegments: Int
  ) -> Self {
    let termLimit = max(0, maximumDictionaryTerms)
    let segmentLimit = max(0, maximumPriorSegments)
    let boundedHints = dictionaryHints.compactMap {
      hint -> ASRDictionaryHint? in
      let canonical = hint.canonicalForm.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      guard
        !canonical.isEmpty,
        canonical.count <= 128,
        canonical == hint.canonicalForm
      else { return nil }
      let spoken = Array(
        hint.spokenForms.lazy
          .filter {
            !$0.isEmpty
              && $0.count <= 128
              && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
          }
          .prefix(32)
      )
      return ASRDictionaryHint(
        canonicalForm: canonical,
        spokenForms: spoken
      )
    }
    return Self(
      dictionaryTerms: Array(dictionaryTerms.prefix(termLimit)),
      dictionaryHints: Array(boundedHints.prefix(termLimit)),
      priorStableSegments: Array(priorStableSegments.suffix(segmentLimit))
    )
  }
}

public struct ASRRequest: Codable, Equatable, Sendable {
  public let metadata: InferenceRequestMetadata
  public let audio: AudioRangeInput
  public let mode: ASRMode
  public let languageHints: [String]
  public let recognitionContext: ASRRecognitionContext
  public let supersedesRevisionID: UUID?

  public init(
    metadata: InferenceRequestMetadata,
    audio: AudioRangeInput,
    mode: ASRMode,
    languageHints: [String],
    recognitionContext: ASRRecognitionContext = ASRRecognitionContext(),
    supersedesRevisionID: UUID? = nil
  ) {
    self.metadata = metadata
    self.audio = audio
    self.mode = mode
    self.languageHints = languageHints
    self.recognitionContext = recognitionContext
    self.supersedesRevisionID = supersedesRevisionID
  }
}

public enum ASRRevisionOperation: String, Codable, Sendable {
  case replaceAudioRange
}

public struct ASRRevisionMetadata: Codable, Equatable, Sendable {
  public let revisionID: UUID
  public let supersedesRevisionID: UUID?
  public let mode: ASRMode
  public let operation: ASRRevisionOperation
  public let monotonicStartNanoseconds: UInt64
  public let monotonicEndNanoseconds: UInt64

  public init(
    revisionID: UUID,
    supersedesRevisionID: UUID?,
    mode: ASRMode,
    operation: ASRRevisionOperation = .replaceAudioRange,
    monotonicStartNanoseconds: UInt64,
    monotonicEndNanoseconds: UInt64
  ) {
    self.revisionID = revisionID
    self.supersedesRevisionID = supersedesRevisionID
    self.mode = mode
    self.operation = operation
    self.monotonicStartNanoseconds = monotonicStartNanoseconds
    self.monotonicEndNanoseconds = monotonicEndNanoseconds
  }
}

public struct ASRSegment: Codable, Equatable, Sendable {
  public let segmentID: UUID
  public let monotonicStartNanoseconds: UInt64
  public let monotonicEndNanoseconds: UInt64
  public let text: String
  public let confidence: Double?

  public init(
    segmentID: UUID,
    monotonicStartNanoseconds: UInt64,
    monotonicEndNanoseconds: UInt64,
    text: String,
    confidence: Double?
  ) {
    self.segmentID = segmentID
    self.monotonicStartNanoseconds = monotonicStartNanoseconds
    self.monotonicEndNanoseconds = monotonicEndNanoseconds
    self.text = text
    self.confidence = confidence
  }
}

public struct ASRResult: Codable, Equatable, Sendable {
  public let contractVersion: Int
  public let modelArtifactID: String
  public let segments: [ASRSegment]
  public let detectedLanguage: String?
  public let revision: ASRRevisionMetadata?

  public init(
    contractVersion: Int = InferenceContract.currentVersion,
    modelArtifactID: String,
    segments: [ASRSegment],
    detectedLanguage: String? = nil,
    revision: ASRRevisionMetadata? = nil
  ) {
    self.contractVersion = contractVersion
    self.modelArtifactID = modelArtifactID
    self.segments = segments
    self.detectedLanguage = detectedLanguage
    self.revision = revision
  }
}

public struct DiarizationRequest: Codable, Equatable, Sendable {
  public let metadata: InferenceRequestMetadata
  public let audio: [AudioRangeInput]
  public let expectedSpeakerRange: ClosedRange<Int>?

  public init(
    metadata: InferenceRequestMetadata,
    audio: [AudioRangeInput],
    expectedSpeakerRange: ClosedRange<Int>?
  ) {
    self.metadata = metadata
    self.audio = audio
    self.expectedSpeakerRange = expectedSpeakerRange
  }
}

public struct DiarizationTurn: Codable, Equatable, Sendable {
  public let turnID: UUID
  public let speakerClusterID: String
  public let monotonicStartNanoseconds: UInt64
  public let monotonicEndNanoseconds: UInt64
  public let confidence: Double?
  public let overlapsAnotherSpeaker: Bool

  public init(
    turnID: UUID,
    speakerClusterID: String,
    monotonicStartNanoseconds: UInt64,
    monotonicEndNanoseconds: UInt64,
    confidence: Double?,
    overlapsAnotherSpeaker: Bool
  ) {
    self.turnID = turnID
    self.speakerClusterID = speakerClusterID
    self.monotonicStartNanoseconds = monotonicStartNanoseconds
    self.monotonicEndNanoseconds = monotonicEndNanoseconds
    self.confidence = confidence
    self.overlapsAnotherSpeaker = overlapsAnotherSpeaker
  }
}

public struct DiarizationResult: Codable, Equatable, Sendable {
  public let contractVersion: Int
  public let modelArtifactID: String
  public let turns: [DiarizationTurn]

  public init(
    contractVersion: Int = InferenceContract.currentVersion,
    modelArtifactID: String,
    turns: [DiarizationTurn]
  ) {
    self.contractVersion = contractVersion
    self.modelArtifactID = modelArtifactID
    self.turns = turns
  }
}

public struct SpeakerEmbeddingRequest: Codable, Equatable, Sendable {
  public let metadata: InferenceRequestMetadata
  public let audio: AudioRangeInput
  public let embeddingSpaceID: String

  public init(
    metadata: InferenceRequestMetadata,
    audio: AudioRangeInput,
    embeddingSpaceID: String
  ) {
    self.metadata = metadata
    self.audio = audio
    self.embeddingSpaceID = embeddingSpaceID
  }
}

public struct SpeakerEmbeddingResult: Codable, Equatable, Sendable {
  public let contractVersion: Int
  public let modelArtifactID: String
  public let embeddingSpaceID: String
  public let vector: [Float]

  public init(
    contractVersion: Int = InferenceContract.currentVersion,
    modelArtifactID: String,
    embeddingSpaceID: String,
    vector: [Float]
  ) {
    self.contractVersion = contractVersion
    self.modelArtifactID = modelArtifactID
    self.embeddingSpaceID = embeddingSpaceID
    self.vector = vector
  }
}

public struct LocalTextTaskID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    rawValue = try container.decode(String.self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public static let actionItems = Self("action-items")
  public static let chapters = Self("chapters")
  public static let decisions = Self("decisions-conclusions")
  public static let rewrite = Self("rewrite")
  public static let structuredSummary = Self("structured-summary")
}

public struct LocalTextRequest: Codable, Equatable, Sendable {
  public let metadata: InferenceRequestMetadata
  public let taskID: LocalTextTaskID
  public let transcriptRevisionID: UUID
  public let sourceSegmentIDs: [UUID]
  public let sourceText: String
  /// Optional local source metadata, never part of the spoken evidence.
  public let sourceContext: String?

  public init(
    metadata: InferenceRequestMetadata,
    taskID: LocalTextTaskID,
    transcriptRevisionID: UUID,
    sourceSegmentIDs: [UUID],
    sourceText: String,
    sourceContext: String? = nil
  ) {
    self.metadata = metadata
    self.taskID = taskID
    self.transcriptRevisionID = transcriptRevisionID
    self.sourceSegmentIDs = sourceSegmentIDs
    self.sourceText = sourceText
    self.sourceContext = sourceContext
  }
}

public enum LocalTextClaimDisposition: String, Codable, Sendable {
  case cautious
  case supported
}

public struct LocalTextClaim: Codable, Equatable, Sendable {
  public let claimID: UUID
  public let text: String
  public let sourceSegmentIDs: [UUID]
  public let confidence: Double?
  public let disposition: LocalTextClaimDisposition

  public init(
    claimID: UUID,
    text: String,
    sourceSegmentIDs: [UUID],
    confidence: Double? = nil,
    disposition: LocalTextClaimDisposition = .supported
  ) {
    self.claimID = claimID
    self.text = text
    self.sourceSegmentIDs = sourceSegmentIDs
    self.confidence = confidence
    self.disposition = disposition
  }
}

public enum LocalTextStructuredItemKind: String, Codable, Sendable {
  case actionItem = "action-item"
  case chapter
  case decision
  case summaryPoint = "summary-point"
}

public struct LocalTextStructuredItem: Codable, Equatable, Sendable {
  public let itemID: UUID
  public let kind: LocalTextStructuredItemKind
  public let text: String
  public let owner: String?
  public let sourceSegmentIDs: [UUID]
  public let confidence: Double
  public let disposition: LocalTextClaimDisposition
  public let dueDateText: String?
  public let completedAt: Date?

  public init(
    itemID: UUID,
    kind: LocalTextStructuredItemKind,
    text: String,
    owner: String?,
    sourceSegmentIDs: [UUID],
    confidence: Double,
    disposition: LocalTextClaimDisposition,
    dueDateText: String? = nil,
    completedAt: Date? = nil
  ) {
    self.itemID = itemID
    self.kind = kind
    self.text = text
    self.owner = owner
    self.sourceSegmentIDs = sourceSegmentIDs
    self.confidence = confidence
    self.disposition = disposition
    self.dueDateText = dueDateText
    self.completedAt = completedAt
  }
}

public struct LocalTextResult: Codable, Equatable, Sendable {
  public let contractVersion: Int
  public let modelArtifactID: String
  public let taskID: LocalTextTaskID
  public let outputText: String
  public let claims: [LocalTextClaim]
  public let structuredItems: [LocalTextStructuredItem]

  public init(
    contractVersion: Int = InferenceContract.currentVersion,
    modelArtifactID: String,
    taskID: LocalTextTaskID,
    outputText: String,
    claims: [LocalTextClaim],
    structuredItems: [LocalTextStructuredItem] = []
  ) {
    self.contractVersion = contractVersion
    self.modelArtifactID = modelArtifactID
    self.taskID = taskID
    self.outputText = outputText
    self.claims = claims
    self.structuredItems = structuredItems
  }
}

public protocol ASREngine: Sendable {
  func descriptor() async -> InferenceEngineDescriptor
  func transcribe(_ request: ASRRequest) async throws -> ASRResult
}

public protocol DiarizationEngine: Sendable {
  func descriptor() async -> InferenceEngineDescriptor
  func diarize(_ request: DiarizationRequest) async throws -> DiarizationResult
}

public protocol SpeakerEmbeddingEngine: Sendable {
  func descriptor() async -> InferenceEngineDescriptor
  func embed(_ request: SpeakerEmbeddingRequest) async throws
    -> SpeakerEmbeddingResult
}

public protocol LocalTextEngine: Sendable {
  func descriptor() async -> InferenceEngineDescriptor
  func generate(_ request: LocalTextRequest) async throws -> LocalTextResult
}
