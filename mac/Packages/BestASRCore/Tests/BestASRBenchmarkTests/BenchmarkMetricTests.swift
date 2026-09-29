import Foundation
import XCTest

@testable import BestASRBenchmark
@testable import BestASREvidence

final class BenchmarkMetricTests: XCTestCase {
  func testHandCalculatedGoldenFixtureProducesEveryRequiredMetric() throws {
    let inputData = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Tests/Fixtures/Benchmark/golden-run.json"
      )
    )
    let input = try JSONDecoder().decode(BenchmarkRunInput.self, from: inputData)
    let result = try BenchmarkRunner.evaluate(input)
    let metrics = Dictionary(uniqueKeysWithValues: result.metrics.map { ($0.name, $0.value) })

    XCTAssertEqual(try XCTUnwrap(metrics["cer"]), 1.0 / 11.0, accuracy: 0.000_000_1)
    XCTAssertEqual(try XCTUnwrap(metrics["wer"]), 1.0 / 3.0, accuracy: 0.000_000_1)
    XCTAssertEqual(try XCTUnwrap(metrics["mer"]), 1.0 / 3.0, accuracy: 0.000_000_1)
    XCTAssertEqual(try XCTUnwrap(metrics["dangerous-token-errors"]), 1)
    XCTAssertEqual(try XCTUnwrap(metrics["dangerous-token-errors.action-owner"]), 0)
    XCTAssertEqual(try XCTUnwrap(metrics["dangerous-token-errors.date"]), 0)
    XCTAssertEqual(try XCTUnwrap(metrics["dangerous-token-errors.negation"]), 0)
    XCTAssertEqual(try XCTUnwrap(metrics["dangerous-token-errors.number"]), 1)
    XCTAssertEqual(try XCTUnwrap(metrics["dangerous-token-errors.person"]), 0)
    XCTAssertEqual(try XCTUnwrap(metrics["der"]), 1.0 / 4.0, accuracy: 0.000_000_1)
    XCTAssertEqual(try XCTUnwrap(metrics["jer"]), 5.0 / 12.0, accuracy: 0.000_000_1)
    XCTAssertEqual(try XCTUnwrap(metrics["speaker-miss-rate"]), 0)
    XCTAssertEqual(try XCTUnwrap(metrics["speaker-false-alarm-rate"]), 0)
    XCTAssertEqual(
      try XCTUnwrap(metrics["speaker-confusion-rate"]),
      1.0 / 4.0,
      accuracy: 0.000_000_1
    )
    XCTAssertEqual(try XCTUnwrap(metrics["false-merge-count"]), 1)
    XCTAssertEqual(try XCTUnwrap(metrics["false-split-count"]), 1)
    XCTAssertEqual(try XCTUnwrap(metrics["false-reject-count"]), 1)
    XCTAssertEqual(try XCTUnwrap(metrics["latency-p50"]), 100)
    XCTAssertEqual(try XCTUnwrap(metrics["latency-p95"]), 100)
    XCTAssertEqual(try XCTUnwrap(metrics["realtime-factor"]), 0.25)
    XCTAssertEqual(try XCTUnwrap(metrics["peak-rss"]), 1000)
    XCTAssertEqual(try XCTUnwrap(metrics["backlog-high-watermark"]), 3)
    XCTAssertEqual(result.configHash.count, 64)
    XCTAssertTrue(result.failedSampleUUIDs.isEmpty)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try JSONSchemaSubsetValidator.validate(
      instanceData: encoder.encode(result),
      schemaData: Data(
        contentsOf: repositoryRoot.appendingPathComponent(
          "schemas/evidence/benchmark-result.schema.json"
        )
      )
    )
    try JSONSchemaSubsetValidator.validate(
      instanceData: inputData,
      schemaData: Data(
        contentsOf: repositoryRoot.appendingPathComponent(
          "schemas/evidence/benchmark-run.schema.json"
        )
      )
    )
  }

  func testNearestRankLatencyAndFailedSampleUUIDsAreDeterministic() throws {
    let failedID = try XCTUnwrap(
      UUID(uuidString: "70000000-0000-4000-8000-000000000099")
    )
    let latencies: [UInt64] = [40, 10, 30, 20]
    let samples = latencies.enumerated().map { index, latency in
      BenchmarkSampleInput(
        sampleUUID: index == 0 ? failedID : UUID(),
        audioDurationNanoseconds: 100,
        inferenceDurationNanoseconds: 25,
        latencyNanoseconds: latency * 1_000_000,
        peakResidentBytes: UInt64(1_000 + index),
        backlogHighWatermark: UInt64(index),
        failureCategory: index == 0 ? "fixture-failure" : nil
      )
    }
    let result = try BenchmarkRunner.evaluate(run(samples: samples))
    let metrics = Dictionary(uniqueKeysWithValues: result.metrics.map { ($0.name, $0.value) })

    XCTAssertEqual(try XCTUnwrap(metrics["latency-p50"]), 20)
    XCTAssertEqual(try XCTUnwrap(metrics["latency-p95"]), 40)
    XCTAssertEqual(result.failedSampleUUIDs, [failedID])
  }

  func testConfigHashIsOrderIndependentAndChangesWithConfiguration() throws {
    let first = try BenchmarkConfigurationHasher.hash(["beam": "5", "lang": "mixed"])
    let reordered = try BenchmarkConfigurationHasher.hash([
      "lang": "mixed", "beam": "5",
    ])
    let changed = try BenchmarkConfigurationHasher.hash(["beam": "4", "lang": "mixed"])

    XCTAssertEqual(first, reordered)
    XCTAssertNotEqual(first, changed)
  }

  private func run(samples: [BenchmarkSampleInput]) -> BenchmarkRunInput {
    BenchmarkRunInput(
      benchmarkID: "fixture-run",
      task: .asr,
      protocolVersion: 1,
      implementationRevision: "fixture-revision",
      modelArtifact: BenchmarkModelArtifact(
        artifactID: "fixture-model",
        sha256: String(repeating: "a", count: 64)
      ),
      configuration: ["beam": "5"],
      corpus: BenchmarkCorpusReference(
        manifestID: "fixture-corpus",
        version: "1.0.0",
        split: .smoke
      ),
      environmentRef: "fixture://environment/arm64-offline",
      hardware: BenchmarkHardwareContext(
        osVersion: "14.2",
        architecture: "arm64",
        unifiedMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
        toolchainVersion: "Swift 6 fixture"
      ),
      samples: samples
    )
  }

  private var repositoryRoot: URL {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != "/" {
      if FileManager.default.fileExists(
        atPath: candidate.appendingPathComponent("PRODUCT_REQUIREMENTS.md").path
      ) {
        return candidate
      }
      candidate.deleteLastPathComponent()
    }
    fatalError("Could not locate repository root")
  }
}
