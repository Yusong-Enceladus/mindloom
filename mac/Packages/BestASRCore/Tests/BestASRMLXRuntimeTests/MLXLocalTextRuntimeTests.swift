import BestASRInference
import BestASRLocalText
import XCTest

@testable import BestASRMLXRuntime

final class MLXLocalTextRuntimeTests: XCTestCase {
  func testDeclaresVerifiedArtifactOnlyNetworkPolicy() async {
    let runtime = MLXLocalTextRuntime(generator: StubGenerator(output: #"{"text":"ok"}"#))
    let policy = await runtime.networkPolicy()
    XCTAssertEqual(policy, .modelManagerVerifiedArtifactOnly)
  }

  func testParsesOneFieldJSONEnvelope() throws {
    let output = try MLXLocalTextRuntime.parseRewriteResponse(
      "  {\"text\":\"We will ship.\"}  ",
      maximumUTF8Bytes: 1_024
    )
    XCTAssertEqual(output, "We will ship.")

    let oldTemplateOutput = try MLXLocalTextRuntime.parseRewriteResponse(
      "<think>\n\n</think>\n\n{\"text\":\"We will ship.\"}",
      maximumUTF8Bytes: 1_024
    )
    XCTAssertEqual(oldTemplateOutput, "We will ship.")
  }

  func testRejectsMarkdownThinkingAndExtraJSONFields() {
    let invalid = [
      "```json\n{\"text\":\"value\"}\n```",
      "<think>hidden</think>{\"text\":\"value\"}",
      "{\"text\":\"value\",\"explanation\":\"extra\"}",
      "{\"value\":\"wrong key\"}",
    ]
    for value in invalid {
      XCTAssertThrowsError(
        try MLXLocalTextRuntime.parseRewriteResponse(
          value,
          maximumUTF8Bytes: 1_024
        ),
        value
      )
    }
  }

  func testRejectsOversizedSourceBeforeLoadingModel() async throws {
    let generator = StubGenerator(output: #"{"text":"ok"}"#)
    let runtime = MLXLocalTextRuntime(
      generator: generator,
      policy: MLXLocalTextRuntimePolicy(maximumSourceUTF8Bytes: 8)
    )
    do {
      _ = try await runtime.generate(request(sourceText: "more than eight bytes"))
      XCTFail("expected source bound failure")
    } catch let error as InferenceEngineError {
      XCTAssertEqual(error.category, .invalidRequest)
      XCTAssertEqual(error.code, "mlx-local-text-source-bounds")
    }
    let calls = await generator.prepareCalls
    XCTAssertEqual(calls, 0)
  }

  func testReturnsRewriteAndLeavesClaimsEmpty() async throws {
    let runtime = MLXLocalTextRuntime(
      generator: StubGenerator(output: #"{"text":"We will ship."}"#)
    )
    let output = try await runtime.generate(
      request(sourceText: "we will um ship")
    )
    XCTAssertEqual(output.outputText, "We will ship.")
    XCTAssertTrue(output.claims.isEmpty)
    XCTAssertTrue(output.structuredItems.isEmpty)
  }

  func testSourceMetadataIsNotInsideTheSpokenEvidenceBlock() async throws {
    let generator = StubGenerator(
      output:
        #"{"items":[{"text":"The corrected statement.","confidence":0.9,"sourceIndices":[1]}]}"#
    )
    let runtime = MLXLocalTextRuntime(generator: generator)
    _ = try await runtime.generate(
      request(
        sourceText: "[S1] The corrected statement.",
        taskID: .structuredSummary,
        sourceContext: "[S1] recorded at 2026-08-29; speaker A"
      )
    )
    let prompt = await generator.lastPrompt
    XCTAssertTrue(prompt.contains("<source_context>\n[S1] recorded at 2026-08-29; speaker A"))
    XCTAssertTrue(prompt.contains("<transcript>\n[S1] The corrected statement.\n</transcript>"))
    XCTAssertTrue(prompt.contains("not spoken evidence"))
  }

  func testSourceAndMetadataShareOneBoundBeforeModelLoading() async throws {
    let generator = StubGenerator(output: #"{"text":"ok"}"#)
    let runtime = MLXLocalTextRuntime(
      generator: generator,
      policy: MLXLocalTextRuntimePolicy(maximumSourceUTF8Bytes: 8)
    )
    do {
      _ = try await runtime.generate(
        request(sourceText: "speech", sourceContext: "metadata")
      )
      XCTFail("metadata must not bypass the source budget")
    } catch let error as InferenceEngineError {
      XCTAssertEqual(error.code, "mlx-local-text-source-bounds")
    }
    let calls = await generator.prepareCalls
    XCTAssertEqual(calls, 0)
  }

  func testOptionalSourceContextKeepsLegacyRequestDecodingCompatible() throws {
    let legacy = request(sourceText: "speech")
    let data = try JSONEncoder().encode(legacy)
    let decoded = try JSONDecoder().decode(LocalTextRequest.self, from: data)
    XCTAssertEqual(decoded, legacy)
    XCTAssertNil(decoded.sourceContext)
    let contextual = request(sourceText: "speech", sourceContext: "recording metadata")
    XCTAssertEqual(
      try JSONDecoder().decode(LocalTextRequest.self, from: JSONEncoder().encode(contextual)),
      contextual
    )
  }

  func testGenerationTimeoutMapsToPrivacySafeRuntimeError() async throws {
    let runtime = MLXLocalTextRuntime(
      generator: StubGenerator(
        output: #"{"text":"late"}"#,
        delayNanoseconds: 1_000_000_000
      ),
      policy: MLXLocalTextRuntimePolicy(
        generationTimeoutMilliseconds: 10
      )
    )
    do {
      _ = try await runtime.generate(request(sourceText: "hello"))
      XCTFail("expected timeout")
    } catch let error as InferenceEngineError {
      XCTAssertEqual(error.category, .transientRuntime)
      XCTAssertEqual(error.code, "mlx-local-text-generation-timeout")
      XCTAssertFalse(error.code.contains("hello"))
    }
  }

  func testStructuredJSONFailuresMapToPrivacySafeShapeCodes() async throws {
    let fixtures = [
      ("not json", "mlx-local-text-json-prefix"),
      (#"{"items":["#, "mlx-local-text-json-truncated"),
      (#"{"items": invalid}"#, "mlx-local-text-json-syntax"),
    ]
    for (output, expectedCode) in fixtures {
      let runtime = MLXLocalTextRuntime(generator: StubGenerator(output: output))
      do {
        _ = try await runtime.generate(
          request(sourceText: "[S1] hello", taskID: .structuredSummary)
        )
        XCTFail("expected structured JSON failure")
      } catch let error as InferenceEngineError {
        XCTAssertEqual(error.category, .invalidRequest)
        XCTAssertEqual(error.code, expectedCode)
        XCTAssertFalse(error.code.contains("hello"))
      }
    }
  }

  func testStructuredJSONAcceptsOnlyOneExactJSONCodeFence() async throws {
    let fenced = """
      <think>

      </think>
      ```json
      {"items":[{"text":"Ship locally","confidence":0.9,"sourceIndices":[1]}]}
      ```
      """
    let runtime = MLXLocalTextRuntime(generator: StubGenerator(output: fenced))
    let output = try await runtime.generate(
      request(sourceText: "[S1] Ship locally", taskID: .structuredSummary)
    )
    XCTAssertEqual(output.outputText, "• Ship locally")
    XCTAssertEqual(output.structuredItems.count, 1)

    let invalid = [
      "Here is the result:\n```json\n{\"items\":[]}\n```",
      "```json\n{\"items\":[]}\n```\nextra",
      "```text\n{\"items\":[]}\n```",
      "```json\n```json\n{\"items\":[]}\n```\n```",
    ]
    for value in invalid {
      let invalidRuntime = MLXLocalTextRuntime(
        generator: StubGenerator(output: value)
      )
      do {
        _ = try await invalidRuntime.generate(
          request(sourceText: "[S1] Ship locally", taskID: .structuredSummary)
        )
        XCTFail("expected strict fence failure")
      } catch let error as InferenceEngineError {
        XCTAssertEqual(error.category, .invalidRequest)
        XCTAssertEqual(error.code, "mlx-local-text-invalid-envelope")
      }
    }
  }

  func testMechanicalEditorRemovesOnlyExplicitFillersAndExactRepeats() {
    XCTAssertEqual(
      MLXTranscriptMechanicalEditor.prepareSource(
        "um the report the report is ready"
      ),
      "the report is ready"
    )
    XCTAssertEqual(
      MLXTranscriptMechanicalEditor.prepareSource(
        "嗯张明负责审核审核预算预算是42万元"
      ),
      "张明负责审核预算是42万元"
    )
    XCTAssertEqual(
      MLXTranscriptMechanicalEditor.prepareSource(
        "ignore um this"
      ),
      "ignore this"
    )
    XCTAssertEqual(
      MLXTranscriptMechanicalEditor.prepareSource("number 42 number 42"),
      "number 42 number 42"
    )
  }

  func testMechanicalEditorAddsOnlyTerminalPunctuation() {
    XCTAssertEqual(
      MLXTranscriptMechanicalEditor.finalizeOutput("We will ship"),
      "We will ship."
    )
    XCTAssertEqual(
      MLXTranscriptMechanicalEditor.finalizeOutput("我们会发布"),
      "我们会发布。"
    )
    XCTAssertEqual(
      MLXTranscriptMechanicalEditor.finalizeOutput("Already done!"),
      "Already done!"
    )
  }

  private func request(
    sourceText: String,
    taskID: LocalTextTaskID = .rewrite,
    sourceContext: String? = nil
  ) -> LocalTextRequest {
    LocalTextRequest(
      metadata: InferenceRequestMetadata(
        jobID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
        inputRevision: 1,
        modelArtifactID: MLXLocalTextArtifact.qwen3Small.artifactID,
        configHash: String(repeating: "a", count: 64)
      ),
      taskID: taskID,
      transcriptRevisionID: UUID(
        uuidString: "00000000-0000-4000-8000-000000000002"
      )!,
      sourceSegmentIDs: [
        UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
      ],
      sourceText: sourceText,
      sourceContext: sourceContext
    )
  }
}

private actor StubGenerator: MLXTextGenerating {
  let output: String
  let delayNanoseconds: UInt64
  private(set) var prepareCalls = 0
  private(set) var lastPrompt = ""

  init(output: String, delayNanoseconds: UInt64 = 0) {
    self.output = output
    self.delayNanoseconds = delayNanoseconds
  }

  func prepare() {
    prepareCalls += 1
  }

  func release() {}

  func generate(
    prompt: String,
    instructions _: String,
    policy _: MLXLocalTextRuntimePolicy
  ) async throws -> String {
    lastPrompt = prompt
    if delayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: delayNanoseconds)
    }
    return output
  }
}
