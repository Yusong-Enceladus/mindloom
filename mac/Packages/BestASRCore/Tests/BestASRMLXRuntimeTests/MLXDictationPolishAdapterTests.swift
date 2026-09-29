import BestASRDictation
import BestASRDomain
import BestASRInference
import XCTest

@testable import BestASRMLXRuntime

final class MLXDictationPolishAdapterTests: XCTestCase {
  func testBridgesTranscriptLineageIntoRewriteRequest() async throws {
    let revisionID = TranscriptRevisionID(
      UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
    )
    let segmentID = UUID(
      uuidString: "20000000-0000-4000-8000-000000000002"
    )!
    let engine = CapturingLocalTextEngine(
      artifactID: "qwen3-test",
      outputText: "We will ship."
    )
    let adapter = try MLXDictationPolishAdapter(
      engine: engine,
      artifactID: "qwen3-test",
      configHash: String(repeating: "a", count: 64)
    )

    let output = try await adapter.polish(
      DictationPolishRequest(
        sessionID: SessionID(),
        transcript: DictationTranscriptResult(
          revisionID: revisionID,
          segmentIDs: [segmentID],
          text: "um we will ship",
          modelArtifactID: "asr-test"
        ),
        dictionaryTerms: ["bestASR"],
        targetBundleIdentifier: "com.example.editor"
      )
    )

    XCTAssertEqual(output.sourceRevisionID, revisionID)
    XCTAssertEqual(output.text, "We will ship.")
    XCTAssertEqual(output.disposition, .model)
    XCTAssertEqual(output.modelArtifactID, "qwen3-test")
    let request = await engine.request
    XCTAssertEqual(request?.transcriptRevisionID, revisionID.rawValue)
    XCTAssertEqual(request?.sourceSegmentIDs, [segmentID])
    XCTAssertEqual(request?.metadata.jobID, revisionID.rawValue)
  }

  func testUsesRevisionAsSegmentFallback() async throws {
    let revisionID = TranscriptRevisionID(
      UUID(uuidString: "20000000-0000-4000-8000-000000000003")!
    )
    let engine = CapturingLocalTextEngine(
      artifactID: "qwen3-test",
      outputText: "完成。"
    )
    let adapter = try MLXDictationPolishAdapter(
      engine: engine,
      artifactID: "qwen3-test",
      configHash: String(repeating: "b", count: 64)
    )
    _ = try await adapter.polish(
      DictationPolishRequest(
        sessionID: SessionID(),
        transcript: DictationTranscriptResult(
          revisionID: revisionID,
          segmentIDs: [],
          text: "完成",
          modelArtifactID: "asr-test"
        ),
        dictionaryTerms: [],
        targetBundleIdentifier: nil
      )
    )
    let request = await engine.request
    XCTAssertEqual(request?.sourceSegmentIDs, [revisionID.rawValue])
  }
}

private actor CapturingLocalTextEngine: LocalTextEngine {
  let artifactID: String
  let outputText: String
  private(set) var request: LocalTextRequest?

  init(artifactID: String, outputText: String) {
    self.artifactID = artifactID
    self.outputText = outputText
  }

  func descriptor() async -> InferenceEngineDescriptor {
    InferenceEngineDescriptor(
      artifact: ModelArtifactDescriptor(
        artifactID: artifactID,
        version: "test",
        sha256: String(repeating: "c", count: 64),
        runtimeID: InferenceRuntimeID("mlx-test"),
        capabilities: [.localTextStructured],
        minimumOS: InferenceOSVersion(major: 14, minor: 2),
        supportedArchitectures: ["arm64"],
        minimumUnifiedMemoryBytes: 1,
        licenseIdentifier: "Apache-2.0",
        networkRequired: false
      )
    )
  }

  func generate(_ request: LocalTextRequest) async -> LocalTextResult {
    self.request = request
    return LocalTextResult(
      modelArtifactID: artifactID,
      taskID: .rewrite,
      outputText: outputText,
      claims: [],
      structuredItems: []
    )
  }
}
