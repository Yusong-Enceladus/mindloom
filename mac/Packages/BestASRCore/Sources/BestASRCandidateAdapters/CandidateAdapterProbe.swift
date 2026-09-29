import BestASRInference
import Foundation

public struct CandidateContractFixtureCase: Codable, Equatable, Sendable {
  public let caseID: String
  public let requirementIDs: [String]
  public let jobID: UUID
  public let sourceID: UUID
  public let trackID: UUID
  public let assetReference: String
  public let contentDigest: String
  public let monotonicStartNanoseconds: UInt64
  public let monotonicEndNanoseconds: UInt64
  public let mode: ASRMode
  public let languageHints: [String]
  public let dictionaryTerms: [String]
  public let priorStableSegments: [ASRContextSegment]
  public let supersedesRevisionID: UUID?
  public let revisionID: UUID
  public let expectedSegments: [CandidateRuntimeSegment]
}

public struct CandidateContractFixtureSuite: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let suiteID: String
  public let cases: [CandidateContractFixtureCase]

  public static func decode(_ data: Data) throws -> Self {
    let decoded = try JSONDecoder().decode(Self.self, from: data)
    guard
      decoded.schemaVersion == 1,
      decoded.kind == "candidate-adapter-contract-fixtures",
      !decoded.suiteID.isEmpty,
      !decoded.cases.isEmpty
    else {
      throw CandidateProbeError.invalidFixtureSuite
    }
    let expectedRequirements = Set((1...10).map { String(format: "ASR-%03d", $0) })
    let coveredRequirements = Set(decoded.cases.flatMap(\.requirementIDs))
    guard expectedRequirements.isSubset(of: coveredRequirements) else {
      throw CandidateProbeError.incompleteRequirementCoverage
    }
    return decoded
  }
}

public enum CandidateProbeError: Error, Equatable, Sendable {
  case incompleteRequirementCoverage
  case invalidFixtureSuite
  case missingFixture(String)
  case runtimeContractViolation(String)
}

public actor ContractFixtureCandidateRuntime: CandidateASRRuntime {
  private let fixturesByAssetReference: [String: CandidateContractFixtureCase]

  public init(suite: CandidateContractFixtureSuite) {
    fixturesByAssetReference = Dictionary(
      uniqueKeysWithValues: suite.cases.map { ($0.assetReference, $0) }
    )
  }

  public func networkPolicy() -> CandidateRuntimeNetworkPolicy {
    .modelManagerVerifiedArtifactsOnly
  }

  public func transcribe(
    _ request: ASRRequest,
    candidateID: String
  ) throws -> CandidateRuntimeOutput {
    guard let fixture = fixturesByAssetReference[request.audio.assetReference] else {
      throw CandidateProbeError.missingFixture(request.audio.assetReference)
    }
    guard
      request.audio.contentDigest == fixture.contentDigest,
      request.mode == fixture.mode,
      request.languageHints == fixture.languageHints,
      request.recognitionContext.priorStableSegments.count <= 8,
      Set(fixture.dictionaryTerms).isSubset(
        of: Set(request.recognitionContext.dictionaryTerms)
      ),
      request.supersedesRevisionID == fixture.supersedesRevisionID,
      !candidateID.isEmpty
    else {
      throw CandidateProbeError.runtimeContractViolation(fixture.caseID)
    }
    return CandidateRuntimeOutput(
      revisionID: fixture.revisionID,
      segments: fixture.expectedSegments
    )
  }
}

public struct CandidateProbeScenario: Codable, Equatable, Sendable {
  public let scenarioID: String
  public let requirementIDs: [String]
  public let status: String
  public let errorCode: String?
}

public struct CandidateProbeResult: Codable, Equatable, Sendable {
  public let candidateID: String
  public let adapterKind: String
  public let upstreamRuntime: CandidateUpstreamRuntime
  public let artifactID: String
  public let artifactSHA256: String
  public let digestScope: String
  public let modelSource: String
  public let modelRevision: String
  public let runtimeLicense: String
  public let modelLicense: String
  public let realModelArtifactStatus: String
  public let realModelArtifactID: String
  public let realModelTreeSHA256: String
  public let recommendedMemoryBenchmarkResult: String
  public let capabilities: [String]
  public let networkPolicy: String
  public let executionMode: String
  public let releaseEligible: Bool
  public let scenarios: [CandidateProbeScenario]
}

public struct CandidateAdapterProbeReport: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let runID: UUID
  public let protocolVersion: Int
  public let manifestSHA256: String
  public let fixtureSuiteSHA256: String
  public let requirementsCovered: [String]
  public let candidates: [CandidateProbeResult]
  public let selectionDecision: String
  public let conclusion: String
  public let unmetReleaseCriteria: [String]
}

public enum CandidateAdapterProbe {
  public static func run(
    manifest: ASRCandidateManifest,
    fixtureSuite: CandidateContractFixtureSuite,
    manifestSHA256: String,
    fixtureSuiteSHA256: String
  ) async -> CandidateAdapterProbeReport {
    let results = await manifest.candidates.asyncMap { candidate in
      await runCandidate(candidate, fixtureSuite: fixtureSuite)
    }
    let requirements = Set(fixtureSuite.cases.flatMap(\.requirementIDs)).sorted()
    let allPassed = results.allSatisfy { result in
      result.scenarios.allSatisfy { $0.status == "pass" }
    }

    return CandidateAdapterProbeReport(
      schemaVersion: 1,
      kind: "candidate-adapter-contract-smoke",
      runID: UUID(uuidString: "64000000-0000-4000-8000-000000000001")!,
      protocolVersion: InferenceContract.currentVersion,
      manifestSHA256: manifestSHA256,
      fixtureSuiteSHA256: fixtureSuiteSHA256,
      requirementsCovered: requirements,
      candidates: results,
      selectionDecision: "no-default-candidate-selected",
      conclusion: allPassed ? "pass" : "fail",
      unmetReleaseCriteria: [
        "the contract probe is separate from the recorded real-runtime recommended-memory smoke",
        "the versioned release corpus matrix has not run on the 16 GB minimum device",
        "release-holdout quality, thermal, long-session, and speaker gates remain pending",
      ]
    )
  }

  private static func runCandidate(
    _ candidate: ASRCandidateRecord,
    fixtureSuite: CandidateContractFixtureSuite
  ) async -> CandidateProbeResult {
    let runtime = ContractFixtureCandidateRuntime(suite: fixtureSuite)
    var scenarios: [CandidateProbeScenario] = []

    do {
      let adapter = try CandidateAdapterFactory.make(
        candidate: candidate,
        runtime: runtime
      )
      for fixture in fixtureSuite.cases {
        do {
          let result = try await adapter.transcribe(request(for: fixture, candidate: candidate))
          let passed =
            result.modelArtifactID == candidate.probeArtifact.artifactID
            && result.segments
              == fixture.expectedSegments.map {
                ASRSegment(
                  segmentID: $0.segmentID,
                  monotonicStartNanoseconds: $0.monotonicStartNanoseconds,
                  monotonicEndNanoseconds: $0.monotonicEndNanoseconds,
                  text: $0.text,
                  confidence: $0.confidence
                )
              }
            && result.revision
              == ASRRevisionMetadata(
                revisionID: fixture.revisionID,
                supersedesRevisionID: fixture.supersedesRevisionID,
                mode: fixture.mode,
                monotonicStartNanoseconds: fixture.monotonicStartNanoseconds,
                monotonicEndNanoseconds: fixture.monotonicEndNanoseconds
              )
          scenarios.append(
            CandidateProbeScenario(
              scenarioID: fixture.caseID,
              requirementIDs: fixture.requirementIDs,
              status: passed ? "pass" : "fail",
              errorCode: passed ? nil : "candidate-result-mismatch"
            )
          )
        } catch {
          scenarios.append(
            CandidateProbeScenario(
              scenarioID: fixture.caseID,
              requirementIDs: fixture.requirementIDs,
              status: "fail",
              errorCode: String(describing: error)
            )
          )
        }
      }
    } catch {
      scenarios = fixtureSuite.cases.map {
        CandidateProbeScenario(
          scenarioID: $0.caseID,
          requirementIDs: $0.requirementIDs,
          status: "fail",
          errorCode: String(describing: error)
        )
      }
    }

    return CandidateProbeResult(
      candidateID: candidate.candidateID,
      adapterKind: candidate.adapterKind.rawValue,
      upstreamRuntime: candidate.upstreamRuntime,
      artifactID: candidate.probeArtifact.artifactID,
      artifactSHA256: candidate.probeArtifact.sha256,
      digestScope: candidate.probeArtifact.digestScope.rawValue,
      modelSource: candidate.probeArtifact.modelSource,
      modelRevision: candidate.probeArtifact.modelRevision,
      runtimeLicense: candidate.upstreamRuntime.license,
      modelLicense: candidate.probeArtifact.modelLicense,
      realModelArtifactStatus: candidate.probeArtifact.realModelArtifactStatus,
      realModelArtifactID: candidate.probeArtifact.realModelEvidence.artifactID,
      realModelTreeSHA256: candidate.probeArtifact.realModelEvidence.treeSHA256,
      recommendedMemoryBenchmarkResult:
        candidate.probeArtifact.realModelEvidence.benchmarkResultPath,
      capabilities: candidate.capabilities.sorted(),
      networkPolicy: candidate.networkPolicy.rawValue,
      executionMode: "contract-fixture-runtime",
      releaseEligible: candidate.releaseEligible,
      scenarios: scenarios
    )
  }

  private static func request(
    for fixture: CandidateContractFixtureCase,
    candidate: ASRCandidateRecord
  ) -> ASRRequest {
    ASRRequest(
      metadata: InferenceRequestMetadata(
        jobID: fixture.jobID,
        inputRevision: 1,
        modelArtifactID: candidate.probeArtifact.artifactID,
        configHash: String(repeating: "c", count: 64)
      ),
      audio: AudioRangeInput(
        sourceID: fixture.sourceID,
        trackID: fixture.trackID,
        assetReference: fixture.assetReference,
        contentDigest: fixture.contentDigest,
        monotonicStartNanoseconds: fixture.monotonicStartNanoseconds,
        monotonicEndNanoseconds: fixture.monotonicEndNanoseconds,
        sampleRateHertz: 16_000,
        channelCount: 1
      ),
      mode: fixture.mode,
      languageHints: fixture.languageHints,
      recognitionContext: ASRRecognitionContext(
        dictionaryTerms: fixture.dictionaryTerms,
        priorStableSegments: fixture.priorStableSegments
      ),
      supersedesRevisionID: fixture.supersedesRevisionID
    )
  }
}

extension Array where Element: Sendable {
  fileprivate func asyncMap<T: Sendable>(
    _ transform: @Sendable (Element) async -> T
  ) async -> [T] {
    var values: [T] = []
    values.reserveCapacity(count)
    for element in self {
      values.append(await transform(element))
    }
    return values
  }
}
