import Foundation

public struct LLMFactualSourceSample: Codable, Equatable, Sendable {
  public let sampleUUID: UUID
  public let sourceText: String
  public let dangerousTokens: [DangerousToken]

  public init(
    sampleUUID: UUID,
    sourceText: String,
    dangerousTokens: [DangerousToken]
  ) {
    self.sampleUUID = sampleUUID
    self.sourceText = sourceText
    self.dangerousTokens = dangerousTokens
  }
}

public struct LLMFactualCandidateSample: Codable, Equatable, Sendable {
  public let sampleUUID: UUID
  public let outputText: String
  public let dangerousTokens: [DangerousToken]
  public let stylePreferenceScore: Double

  public init(
    sampleUUID: UUID,
    outputText: String,
    dangerousTokens: [DangerousToken],
    stylePreferenceScore: Double
  ) {
    self.sampleUUID = sampleUUID
    self.outputText = outputText
    self.dangerousTokens = dangerousTokens
    self.stylePreferenceScore = stylePreferenceScore
  }
}

public struct LLMFactualCandidate: Codable, Equatable, Sendable {
  public let candidateID: String
  public let modelArtifactSHA256: String
  public let samples: [LLMFactualCandidateSample]

  public init(
    candidateID: String,
    modelArtifactSHA256: String,
    samples: [LLMFactualCandidateSample]
  ) {
    self.candidateID = candidateID
    self.modelArtifactSHA256 = modelArtifactSHA256
    self.samples = samples
  }
}

public struct LLMFactualGateSuite: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let suiteID: String
  public let sources: [LLMFactualSourceSample]
  public let candidates: [LLMFactualCandidate]

  public init(
    schemaVersion: Int = 1,
    kind: String = "llm-factual-gate-suite",
    suiteID: String,
    sources: [LLMFactualSourceSample],
    candidates: [LLMFactualCandidate]
  ) {
    self.schemaVersion = schemaVersion
    self.kind = kind
    self.suiteID = suiteID
    self.sources = sources
    self.candidates = candidates
  }
}

public struct LLMFactualCategoryResult: Codable, Equatable, Sendable {
  public let category: DangerousTokenCategory
  public let errorCount: Int
  public let hardLimit: Int
  public let passed: Bool

  public init(
    category: DangerousTokenCategory,
    errorCount: Int,
    hardLimit: Int,
    passed: Bool
  ) {
    self.category = category
    self.errorCount = errorCount
    self.hardLimit = hardLimit
    self.passed = passed
  }
}

public struct LLMFactualCandidateResult: Codable, Equatable, Sendable {
  public let candidateID: String
  public let modelArtifactSHA256: String
  public let meanStylePreferenceScore: Double
  public let categoryResults: [LLMFactualCategoryResult]
  public let failedSampleUUIDs: [UUID]
  public let hardGateEligible: Bool

  public init(
    candidateID: String,
    modelArtifactSHA256: String,
    meanStylePreferenceScore: Double,
    categoryResults: [LLMFactualCategoryResult],
    failedSampleUUIDs: [UUID],
    hardGateEligible: Bool
  ) {
    self.candidateID = candidateID
    self.modelArtifactSHA256 = modelArtifactSHA256
    self.meanStylePreferenceScore = meanStylePreferenceScore
    self.categoryResults = categoryResults
    self.failedSampleUUIDs = failedSampleUUIDs
    self.hardGateEligible = hardGateEligible
  }
}

public struct LLMFactualGateEvaluation: Codable, Equatable, Sendable {
  public let suiteID: String
  public let sourceSampleCount: Int
  public let categoryCoverage: [DangerousTokenCategory]
  public let candidateResults: [LLMFactualCandidateResult]

  public init(
    suiteID: String,
    sourceSampleCount: Int,
    categoryCoverage: [DangerousTokenCategory],
    candidateResults: [LLMFactualCandidateResult]
  ) {
    self.suiteID = suiteID
    self.sourceSampleCount = sourceSampleCount
    self.categoryCoverage = categoryCoverage
    self.candidateResults = candidateResults
  }
}

public enum LLMFactualGateError: Error, Equatable, Sendable {
  case candidateSampleSetMismatch(String)
  case duplicateCandidateID(String)
  case duplicateCandidateSample(UUID)
  case duplicateSourceSample(UUID)
  case emptyCandidates
  case emptySources
  case incompleteCategoryCoverage
  case invalidArtifactDigest(String)
  case invalidCandidateID
  case invalidStyleScore(UUID)
  case unsupportedKind
  case unsupportedSchemaVersion(Int)
}

public struct LLMFactualGatePolicy: Codable, Equatable, Sendable {
  public let hardLimits: [DangerousTokenCategory: Int]

  public init(hardLimits: [DangerousTokenCategory: Int]) {
    self.hardLimits = hardLimits
  }

  public static let zeroTolerance = Self(
    hardLimits: Dictionary(
      uniqueKeysWithValues: DangerousTokenCategory.allCases.map { ($0, 0) }
    )
  )
}

public enum LLMFactualHardGate {
  public static func evaluate(
    _ suite: LLMFactualGateSuite,
    policy: LLMFactualGatePolicy = .zeroTolerance
  ) throws -> LLMFactualGateEvaluation {
    try validate(suite)
    let sourcesByID = Dictionary(
      uniqueKeysWithValues: suite.sources.map { ($0.sampleUUID, $0) }
    )
    let sourceIDs = Set(sourcesByID.keys)
    let candidateResults = suite.candidates.map { candidate in
      evaluateCandidate(
        candidate,
        sourcesByID: sourcesByID,
        policy: policy
      )
    }
    guard candidateResults.allSatisfy({ Set($0.failedSampleUUIDs).isSubset(of: sourceIDs) })
    else {
      throw LLMFactualGateError.incompleteCategoryCoverage
    }

    return LLMFactualGateEvaluation(
      suiteID: suite.suiteID,
      sourceSampleCount: suite.sources.count,
      categoryCoverage: DangerousTokenCategory.allCases,
      candidateResults: candidateResults
    )
  }

  private static func evaluateCandidate(
    _ candidate: LLMFactualCandidate,
    sourcesByID: [UUID: LLMFactualSourceSample],
    policy: LLMFactualGatePolicy
  ) -> LLMFactualCandidateResult {
    var errorsByCategory = Dictionary(
      uniqueKeysWithValues: DangerousTokenCategory.allCases.map { ($0, 0) }
    )
    var failedSampleUUIDs = Set<UUID>()
    var styleTotal = 0.0
    for sample in candidate.samples {
      guard let source = sourcesByID[sample.sampleUUID] else { continue }
      let metrics = TranscriptScorer.dangerousTokenMetrics(
        reference: source.dangerousTokens,
        hypothesis: sample.dangerousTokens
      )
      for category in DangerousTokenCategory.allCases {
        let errors = metrics.errorsByCategory[category, default: 0]
        errorsByCategory[category, default: 0] += errors
        if errors > 0 {
          failedSampleUUIDs.insert(sample.sampleUUID)
        }
      }
      styleTotal += sample.stylePreferenceScore
    }
    let categoryResults = DangerousTokenCategory.allCases.map { category in
      let errors = errorsByCategory[category, default: 0]
      let limit = policy.hardLimits[category, default: 0]
      return LLMFactualCategoryResult(
        category: category,
        errorCount: errors,
        hardLimit: limit,
        passed: errors <= limit
      )
    }
    return LLMFactualCandidateResult(
      candidateID: candidate.candidateID,
      modelArtifactSHA256: candidate.modelArtifactSHA256,
      meanStylePreferenceScore: styleTotal / Double(candidate.samples.count),
      categoryResults: categoryResults,
      failedSampleUUIDs: failedSampleUUIDs.sorted {
        $0.uuidString < $1.uuidString
      },
      hardGateEligible: categoryResults.allSatisfy(\.passed)
    )
  }

  private static func validate(_ suite: LLMFactualGateSuite) throws {
    guard suite.schemaVersion == 1 else {
      throw LLMFactualGateError.unsupportedSchemaVersion(suite.schemaVersion)
    }
    guard suite.kind == "llm-factual-gate-suite", !suite.suiteID.isEmpty else {
      throw LLMFactualGateError.unsupportedKind
    }
    guard !suite.sources.isEmpty else { throw LLMFactualGateError.emptySources }
    guard !suite.candidates.isEmpty else { throw LLMFactualGateError.emptyCandidates }

    var sourceIDs = Set<UUID>()
    var coverage = Set<DangerousTokenCategory>()
    for source in suite.sources {
      guard sourceIDs.insert(source.sampleUUID).inserted else {
        throw LLMFactualGateError.duplicateSourceSample(source.sampleUUID)
      }
      coverage.formUnion(source.dangerousTokens.map(\.category))
    }
    guard coverage == Set(DangerousTokenCategory.allCases) else {
      throw LLMFactualGateError.incompleteCategoryCoverage
    }

    var candidateIDs = Set<String>()
    for candidate in suite.candidates {
      guard !candidate.candidateID.isEmpty else {
        throw LLMFactualGateError.invalidCandidateID
      }
      guard candidateIDs.insert(candidate.candidateID).inserted else {
        throw LLMFactualGateError.duplicateCandidateID(candidate.candidateID)
      }
      guard isSHA256(candidate.modelArtifactSHA256) else {
        throw LLMFactualGateError.invalidArtifactDigest(candidate.candidateID)
      }
      var sampleIDs = Set<UUID>()
      for sample in candidate.samples {
        guard sampleIDs.insert(sample.sampleUUID).inserted else {
          throw LLMFactualGateError.duplicateCandidateSample(sample.sampleUUID)
        }
        guard
          sample.stylePreferenceScore.isFinite,
          (0...1).contains(sample.stylePreferenceScore)
        else {
          throw LLMFactualGateError.invalidStyleScore(sample.sampleUUID)
        }
      }
      guard sampleIDs == sourceIDs else {
        throw LLMFactualGateError.candidateSampleSetMismatch(candidate.candidateID)
      }
    }
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
  }
}
