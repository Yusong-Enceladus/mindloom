import BestASRAlphaEvaluation
import BestASRBenchmark
import Foundation
import XCTest

final class AlphaASREvaluationTests: XCTestCase {
  func testCompleteContentFreeDecisionPassesWithProtectedTokenMatch() async throws {
    let run = try localRun(reference: "Alice will not delete 42")
    let evaluator = AlphaASREvaluator(
      transcriber: FixtureTranscriber(
        text: "Alice will not delete 42",
        emptyForSilence: true
      ),
      audioInspector: FixtureAudioInspector(),
      resourceSampler: FixtureResourceSampler()
    )

    let output = try await evaluator.evaluate(
      run: run,
      audioRoot: URL(fileURLWithPath: "/tmp/alpha-audio", isDirectory: true),
      benchmarkID: "alpha-fixture",
      implementationRevision: String(repeating: "1", count: 40),
      modelArtifact: BenchmarkModelArtifact(
        artifactID: "fixture-model",
        sha256: String(repeating: "a", count: 64)
      ),
      configuration: ["networkPolicy": "deny-all"],
      environmentRef: "fixture://environment/alpha",
      hardware: fixtureHardware,
      networkDeniedByParentSandbox: true
    )

    XCTAssertEqual(output.decision.status, "pass")
    XCTAssertTrue(output.decision.selectionEligible)
    XCTAssertEqual(output.decision.sampleCount, 2)
    XCTAssertTrue(output.decision.failedSampleUUIDs.isEmpty)
    XCTAssertEqual(metric("dangerous-token-errors", in: output.benchmark), 0)
    XCTAssertFalse(
      try JSONEncoder().encode(output.decision).contains(Data("Alice".utf8)),
      "aggregate decision evidence must not contain transcript content"
    )
    XCTAssertEqual(output.localDiagnostics.samples.first?.reference, "Alice will not delete 42")
    XCTAssertEqual(output.localDiagnostics.samples.first?.hypothesis, "Alice will not delete 42")
  }

  func testMissingDangerousTokenAndSilenceHallucinationFailClosed() async throws {
    let dangerous = try localRun(reference: "Alice will not delete 42")
    let missingEvaluator = AlphaASREvaluator(
      transcriber: FixtureTranscriber(
        text: "Alice will delete 41",
        emptyForSilence: true
      ),
      audioInspector: FixtureAudioInspector(),
      resourceSampler: FixtureResourceSampler()
    )
    let missing = try await missingEvaluator.evaluate(
      run: dangerous,
      audioRoot: URL(fileURLWithPath: "/tmp/alpha-audio", isDirectory: true),
      benchmarkID: "alpha-fixture-dangerous",
      implementationRevision: String(repeating: "1", count: 40),
      modelArtifact: BenchmarkModelArtifact(
        artifactID: "fixture-model",
        sha256: String(repeating: "a", count: 64)
      ),
      configuration: ["networkPolicy": "deny-all"],
      environmentRef: "fixture://environment/alpha",
      hardware: fixtureHardware,
      networkDeniedByParentSandbox: true
    )
    XCTAssertFalse(missing.decision.selectionEligible)
    XCTAssertEqual(metric("dangerous-token-errors", in: missing.benchmark), 2)

    let silence = AlphaASRLocalRun(
      runID: uuid(2),
      manifestID: "alpha-silence",
      version: "1.0.0",
      samples: [
        AlphaASRLocalSample(
          sampleUUID: uuid(3),
          relativeAudioPath: "silence.wav",
          languages: ["zh-CN"],
          tags: AlphaASREvaluationPolicy.requiredTags + ["noise"],
          reference: ""
        )
      ]
    )
    let hallucinating = AlphaASREvaluator(
      transcriber: FixtureTranscriber(text: "hallucinated"),
      audioInspector: FixtureAudioInspector(),
      resourceSampler: FixtureResourceSampler()
    )
    let silenceOutput = try await hallucinating.evaluate(
      run: silence,
      audioRoot: URL(fileURLWithPath: "/tmp/alpha-audio", isDirectory: true),
      benchmarkID: "alpha-fixture-silence",
      implementationRevision: String(repeating: "1", count: 40),
      modelArtifact: BenchmarkModelArtifact(
        artifactID: "fixture-model",
        sha256: String(repeating: "a", count: 64)
      ),
      configuration: ["networkPolicy": "deny-all"],
      environmentRef: "fixture://environment/alpha",
      hardware: fixtureHardware,
      networkDeniedByParentSandbox: true
    )
    XCTAssertEqual(silenceOutput.decision.failedSampleUUIDs, [uuid(3)])
    XCTAssertFalse(silenceOutput.decision.selectionEligible)
  }

  func testLocalRunRejectsTraversalAndDuplicateIDs() throws {
    let sample = AlphaASRLocalSample(
      sampleUUID: uuid(10),
      relativeAudioPath: "../private.wav",
      languages: ["en-US"],
      tags: ["english"],
      reference: "fixture"
    )
    XCTAssertThrowsError(
      try AlphaASRLocalRun(
        runID: uuid(11),
        manifestID: "invalid",
        version: "1",
        samples: [sample]
      ).validate()
    ) { error in
      XCTAssertEqual(error as? AlphaASREvaluationError, .invalidLocalRun)
    }
  }

  private func localRun(reference: String) throws -> AlphaASRLocalRun {
    let run = AlphaASRLocalRun(
      runID: uuid(1),
      manifestID: "alpha-fixture-v1",
      version: "1.0.0",
      samples: [
        AlphaASRLocalSample(
          sampleUUID: uuid(2),
          relativeAudioPath: "sample.aiff",
          languages: ["zh-CN", "en-US"],
          tags: AlphaASREvaluationPolicy.requiredTags.filter { $0 != "silence" },
          reference: reference,
          dangerousTokens: [
            AlphaDangerousTokenSpec(
              category: .number,
              canonicalValue: "42",
              acceptedSurfaceForms: ["42", "forty two"]
            ),
            AlphaDangerousTokenSpec(
              category: .negation,
              canonicalValue: "not delete",
              acceptedSurfaceForms: ["not delete"]
            ),
          ]
        ),
        AlphaASRLocalSample(
          sampleUUID: uuid(3),
          relativeAudioPath: "silence.wav",
          languages: ["zh-CN", "en-US"],
          tags: ["silence"],
          reference: ""
        ),
      ]
    )
    try run.validate()
    return run
  }

  private var fixtureHardware: BenchmarkHardwareContext {
    BenchmarkHardwareContext(
      osVersion: "fixture",
      architecture: "arm64",
      unifiedMemoryBytes: 17_179_869_184,
      toolchainVersion: "fixture"
    )
  }

  private func metric(_ name: String, in result: BenchmarkResult) -> Double? {
    result.metrics.first { $0.name == name }?.value
  }
}

private struct FixtureTranscriber: AlphaASRFileTranscribing {
  let text: String
  var emptyForSilence = false

  func transcribe(audioURL: URL, dictionaryTerms: [String]) async throws -> String {
    if emptyForSilence, audioURL.lastPathComponent.contains("silence") {
      return ""
    }
    return text
  }
}

private struct FixtureAudioInspector: AlphaASRAudioInspecting {
  func durationNanoseconds(audioURL: URL) throws -> UInt64 { 1_000_000_000 }
}

private struct FixtureResourceSampler: AlphaASRResourceSampling {
  func peakResidentBytes() -> UInt64 { 64 * 1_024 * 1_024 }
}

private func uuid(_ value: UInt64) -> UUID {
  UUID(
    uuidString: String(
      format: "00000000-0000-4000-8000-%012llx",
      value
    )
  )!
}
