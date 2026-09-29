import BestASRInference
import CryptoKit
import Foundation
import XCTest

@testable import BestASRCandidateAdapters

final class CandidateAdapterTests: XCTestCase {
  func testManifestPinsThreeAdaptersAndProbeArtifactDigests() throws {
    let manifest = try loadManifest()

    XCTAssertEqual(Set(manifest.candidates.map(\.adapterKind)), Set(CandidateAdapterKind.allCases))
    XCTAssertEqual(
      manifest.selectionStatus,
      "alpha-default-selected-from-local-corpus"
    )
    XCTAssertEqual(manifest.candidates.filter(\.alphaDefault).count, 1)
    XCTAssertEqual(
      manifest.candidates.first(where: \.alphaDefault)?.candidateID,
      "fluid-sensevoice"
    )
    for candidate in manifest.candidates {
      let artifactURL = repositoryRoot.appendingPathComponent(
        candidate.probeArtifact.relativePath
      )
      XCTAssertEqual(
        sha256(try Data(contentsOf: artifactURL)),
        candidate.probeArtifact.sha256,
        candidate.candidateID
      )
      XCTAssertEqual(candidate.probeArtifact.digestScope, .contractFixtureOnly)
      XCTAssertEqual(
        candidate.probeArtifact.realModelArtifactStatus,
        "recommended-memory-smoke-complete-release-matrix-pending"
      )
      XCTAssertTrue(candidate.probeArtifact.realModelEvidence.networkDenied)
      XCTAssertEqual(candidate.upstreamRuntime.revision.count, 40)
      let benchmarkResultURL = repositoryRoot.appendingPathComponent(
        candidate.probeArtifact.realModelEvidence.benchmarkResultPath
      )
      XCTAssertEqual(
        sha256(try Data(contentsOf: benchmarkResultURL)),
        candidate.probeArtifact.realModelEvidence.benchmarkResultSHA256,
        candidate.candidateID
      )
      XCTAssertFalse(candidate.releaseEligible)
      XCTAssertEqual(candidate.alphaEvidence != nil, candidate.alphaDefault)
      XCTAssertEqual(
        candidate.networkPolicy,
        .modelManagerVerifiedArtifactsOnly
      )
    }
  }

  func testEveryAdapterRunsSameASR001Through010FixtureSuite() async throws {
    let manifestData = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "config/inference-candidates.json"
      )
    )
    let suiteData = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Tests/Fixtures/CandidateAdapters/contract-cases.json"
      )
    )
    let manifest = try ASRCandidateManifest.decode(manifestData)
    let suite = try CandidateContractFixtureSuite.decode(suiteData)
    let report = await CandidateAdapterProbe.run(
      manifest: manifest,
      fixtureSuite: suite,
      manifestSHA256: sha256(manifestData),
      fixtureSuiteSHA256: sha256(suiteData)
    )

    XCTAssertEqual(report.conclusion, "pass")
    XCTAssertEqual(report.selectionDecision, "no-default-candidate-selected")
    XCTAssertEqual(report.candidates.count, 3)
    XCTAssertEqual(
      report.requirementsCovered,
      (1...10).map { String(format: "ASR-%03d", $0) }
    )
    XCTAssertTrue(
      report.candidates.allSatisfy {
        $0.scenarios.count == 10
          && $0.scenarios.allSatisfy { $0.status == "pass" }
          && $0.executionMode == "contract-fixture-runtime"
          && !$0.releaseEligible
      }
    )
  }

  func testAdapterBoundsContextAndCarriesDictionaryTermsAndRevision() async throws {
    let candidate = try XCTUnwrap(
      loadManifest().candidates.first { $0.adapterKind == .fluidSenseVoice }
    )
    let runtime = CapturingCandidateRuntime(
      output: CandidateRuntimeOutput(
        revisionID: uuid(900),
        segments: [
          CandidateRuntimeSegment(
            segmentID: uuid(901),
            monotonicStartNanoseconds: 10,
            monotonicEndNanoseconds: 20,
            text: "fixture",
            confidence: 1
          )
        ],
        detectedLanguage: "zh-CN"
      )
    )
    let adapter = try FluidSenseVoiceASRAdapter(
      candidate: candidate,
      runtime: runtime,
      policy: CandidateAdapterPolicy(
        maximumDictionaryTerms: 2,
        maximumPriorSegments: 3
      )
    )
    let superseded = uuid(899)
    let request = makeRequest(
      candidate: candidate,
      dictionaryTerms: ["one", "two", "three"],
      priorSegments: (0..<10).map {
        ASRContextSegment(
          text: "prior-\($0)",
          monotonicEndNanoseconds: UInt64($0)
        )
      },
      supersedesRevisionID: superseded
    )

    let result = try await adapter.transcribe(request)
    let capturedValue = await runtime.lastRequest()
    let captured = try XCTUnwrap(capturedValue)

    XCTAssertEqual(captured.recognitionContext.dictionaryTerms, ["one", "two"])
    XCTAssertEqual(
      captured.recognitionContext.priorStableSegments.map(\.text),
      ["prior-7", "prior-8", "prior-9"]
    )
    XCTAssertEqual(result.revision?.supersedesRevisionID, superseded)
    XCTAssertEqual(result.revision?.operation, .replaceAudioRange)
    XCTAssertEqual(result.revision?.monotonicStartNanoseconds, 10)
    XCTAssertEqual(result.revision?.monotonicEndNanoseconds, 20)
    XCTAssertEqual(result.detectedLanguage, "zh-CN")
  }

  func testAdapterRejectsImplicitDownloadsAndOutOfRangeTimestamps() async throws {
    let candidate = try XCTUnwrap(
      loadManifest().candidates.first { $0.adapterKind == .whisperKit }
    )
    let networkRuntime = CapturingCandidateRuntime(
      policy: .implicitDownloadsAllowed,
      output: CandidateRuntimeOutput(revisionID: uuid(910), segments: [])
    )
    let networkAdapter = try WhisperKitASRAdapter(
      candidate: candidate,
      runtime: networkRuntime
    )

    await assertInferenceFailure(
      category: .modelUnavailable,
      code: "candidate-implicit-network-disallowed"
    ) {
      _ = try await networkAdapter.transcribe(self.makeRequest(candidate: candidate))
    }

    let invalidRuntime = CapturingCandidateRuntime(
      output: CandidateRuntimeOutput(
        revisionID: uuid(911),
        segments: [
          CandidateRuntimeSegment(
            segmentID: uuid(912),
            monotonicStartNanoseconds: 10,
            monotonicEndNanoseconds: 21,
            text: "outside",
            confidence: nil
          )
        ]
      )
    )
    let timestampAdapter = try WhisperKitASRAdapter(
      candidate: candidate,
      runtime: invalidRuntime
    )

    await assertInferenceFailure(
      category: .invalidRequest,
      code: "candidate-segment-outside-audio-range"
    ) {
      _ = try await timestampAdapter.transcribe(self.makeRequest(candidate: candidate))
    }
  }

  private func assertInferenceFailure(
    category: InferenceFailureCategory,
    code: String,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("Expected categorized inference failure")
    } catch let error as InferenceEngineError {
      XCTAssertEqual(error.category, category)
      XCTAssertEqual(error.code, code)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private func makeRequest(
    candidate: ASRCandidateRecord,
    dictionaryTerms: [String] = [],
    priorSegments: [ASRContextSegment] = [],
    supersedesRevisionID: UUID? = nil
  ) -> ASRRequest {
    ASRRequest(
      metadata: InferenceRequestMetadata(
        jobID: uuid(920),
        inputRevision: 1,
        modelArtifactID: candidate.probeArtifact.artifactID,
        configHash: String(repeating: "c", count: 64)
      ),
      audio: AudioRangeInput(
        sourceID: uuid(921),
        trackID: uuid(922),
        assetReference: "fixture://candidate-adapter/unit",
        contentDigest: String(repeating: "d", count: 64),
        monotonicStartNanoseconds: 10,
        monotonicEndNanoseconds: 20,
        sampleRateHertz: 16_000,
        channelCount: 1
      ),
      mode: .final,
      languageHints: ["zh-CN", "en-US"],
      recognitionContext: ASRRecognitionContext(
        dictionaryTerms: dictionaryTerms,
        priorStableSegments: priorSegments
      ),
      supersedesRevisionID: supersedesRevisionID
    )
  }

  private func loadManifest() throws -> ASRCandidateManifest {
    try ASRCandidateManifest.decode(
      Data(
        contentsOf: repositoryRoot.appendingPathComponent(
          "config/inference-candidates.json"
        )
      )
    )
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func uuid(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", value))!
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

private actor CapturingCandidateRuntime: CandidateASRRuntime {
  private let policy: CandidateRuntimeNetworkPolicy
  private let output: CandidateRuntimeOutput
  private var capturedRequest: ASRRequest?

  init(
    policy: CandidateRuntimeNetworkPolicy = .modelManagerVerifiedArtifactsOnly,
    output: CandidateRuntimeOutput
  ) {
    self.policy = policy
    self.output = output
  }

  func networkPolicy() -> CandidateRuntimeNetworkPolicy { policy }

  func transcribe(
    _ request: ASRRequest,
    candidateID: String
  ) -> CandidateRuntimeOutput {
    capturedRequest = request
    return output
  }

  func lastRequest() -> ASRRequest? { capturedRequest }
}
