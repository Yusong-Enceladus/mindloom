import BestASRBenchmark
import Foundation
import XCTest

@testable import BestASRSpeakerReleaseEvaluation

final class SpeakerReleaseEvaluationTests: XCTestCase {
  func testPinnedAMIPlanIsPublicPseudonymousAndSplit() throws {
    let plan = try AMIPublicSpeakerEvaluationPlan.decode(
      Data(
        contentsOf: repositoryRoot.appendingPathComponent(
          "config/ami-speaker-evaluation.json"
        )
      )
    )

    XCTAssertEqual(plan.audioArtifacts.count, 18)
    XCTAssertEqual(plan.meetings.count, 3)
    XCTAssertEqual(
      Set(plan.meetings.map(\.split)),
      Set([.tuning, .releaseHoldout])
    )
    XCTAssertTrue(
      plan.meetings.flatMap(\.speakers).allSatisfy {
        $0.expectedPersonID.hasPrefix("ami-")
      }
    )
    XCTAssertFalse(
      String(
        decoding: try Data(
          contentsOf: repositoryRoot.appendingPathComponent(
            "config/ami-speaker-evaluation.json"
          )
        ),
        as: UTF8.self
      ).contains("participantName")
    )
  }

  func testCalibrationAndIndependentReleaseUseFrozenThreshold() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bestasr-speaker-release-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    let tuningRoot = root.appendingPathComponent("tuning", isDirectory: true)
    let releaseRoot = root.appendingPathComponent("release", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: tuningRoot,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: releaseRoot,
      withIntermediateDirectories: true
    )
    try writeManifest(
      at: tuningRoot,
      id: "fixture-speaker-tuning",
      tier: .public,
      holdout: false
    )
    try writeManifest(
      at: releaseRoot,
      id: "fixture-speaker-release",
      tier: .releaseHoldout,
      holdout: true
    )

    let tuning = makeTuningRun()
    let release = makeReleaseRun()
    try encode(tuning).write(
      to: tuningRoot.appendingPathComponent("local-run.json")
    )
    try encode(release).write(
      to: releaseRoot.appendingPathComponent("local-run.json")
    )
    let engine = FixtureSpeakerEngine(
      vectors: vectorMap(tuning: tuning, release: release)
    )
    let hardware = BenchmarkHardwareContext(
      osVersion: "test",
      architecture: "arm64",
      unifiedMemoryBytes: 17_179_869_184,
      toolchainVersion: "test"
    )

    let calibration = try await SpeakerReleaseEvaluator.calibrate(
      tuningRoot: tuningRoot,
      releaseHoldoutRoot: releaseRoot,
      engine: engine,
      hardware: hardware,
      networkDeniedByParentSandbox: true
    )
    let frozen = try XCTUnwrap(calibration.frozenModel)
    XCTAssertEqual(calibration.decision.status, "pass")
    XCTAssertTrue(calibration.decision.eligibleForHoldout)
    XCTAssertFalse(calibration.decision.selectionEligible)
    XCTAssertTrue(frozen.separationFeasible)
    XCTAssertEqual(frozen.profiles.count, 2)

    let holdout = try await SpeakerReleaseEvaluator.evaluateReleaseHoldout(
      tuningRoot: tuningRoot,
      releaseHoldoutRoot: releaseRoot,
      frozenModel: frozen,
      engine: engine,
      hardware: hardware,
      networkDeniedByParentSandbox: true
    )
    XCTAssertEqual(holdout.decision.status, "pass")
    XCTAssertTrue(holdout.decision.selectionEligible)
    XCTAssertEqual(holdout.decision.knownWrongCount, 0)
    XCTAssertEqual(holdout.decision.unknownRejectedCount, 4)
    XCTAssertEqual(holdout.decision.falseMergeCount, 0)
    XCTAssertNil(holdout.frozenModel)
  }

  func testCalibrationKeepsHighPrecisionWhenEnrollmentPairsOverlap() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bestasr-speaker-overlap-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    let tuningRoot = root.appendingPathComponent("tuning", isDirectory: true)
    let releaseRoot = root.appendingPathComponent("release", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: tuningRoot,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: releaseRoot,
      withIntermediateDirectories: true
    )
    try writeManifest(
      at: tuningRoot,
      id: "fixture-speaker-overlap-tuning",
      tier: .public,
      holdout: false
    )
    try writeManifest(
      at: releaseRoot,
      id: "fixture-speaker-overlap-release",
      tier: .releaseHoldout,
      holdout: true
    )

    let enrollment = [
      identity(101, "p1-e1", "P1", .enrollment, .dictation, "d"),
      identity(102, "p1-e2", "P1", .enrollment, .dictation, "e"),
      identity(103, "p2-e1", "P2", .enrollment, .dictation, "f"),
      identity(104, "p2-e2", "P2", .enrollment, .dictation, "a"),
    ]
    let queries = SpeakerEvaluationEntryMode.allCases.enumerated().map {
      identity(
        110 + $0.offset,
        "p1-q-\($0.offset)",
        "P1",
        .query,
        $0.element,
        "b"
      )
    }
    let tuning = AMISpeakerLocalRun(
      split: .tuning,
      corpusManifestID: "fixture-speaker-overlap-tuning",
      corpusVersion: "1.0.0",
      datasetID: "ami-meeting-corpus",
      datasetVersion: "1.6.2",
      license: "CC-BY-4.0",
      diarizationSamples: [diarization(120)],
      identitySamples: enrollment + queries
    )
    try encode(tuning).write(
      to: tuningRoot.appendingPathComponent("local-run.json")
    )
    let vectors = [
      String(repeating: "d", count: 64): unitVector(degrees: -20),
      String(repeating: "e", count: 64): unitVector(degrees: 20),
      String(repeating: "f", count: 64): unitVector(degrees: 60),
      String(repeating: "a", count: 64): unitVector(degrees: 100),
      String(repeating: "b", count: 64): unitVector(degrees: 0),
    ]
    let engine = FixtureSpeakerEngine(vectors: vectors)
    let hardware = BenchmarkHardwareContext(
      osVersion: "test",
      architecture: "arm64",
      unifiedMemoryBytes: 17_179_869_184,
      toolchainVersion: "test"
    )

    let calibration = try await SpeakerReleaseEvaluator.calibrate(
      tuningRoot: tuningRoot,
      releaseHoldoutRoot: releaseRoot,
      engine: engine,
      hardware: hardware,
      networkDeniedByParentSandbox: true
    )
    let frozen = try XCTUnwrap(calibration.frozenModel)

    XCTAssertFalse(frozen.separationFeasible)
    XCTAssertEqual(
      frozen.threshold,
      frozen.maximumImpostorSimilarity + frozen.thresholdMargin,
      accuracy: 0.000_000_1
    )
    XCTAssertEqual(calibration.decision.status, "pass")
    XCTAssertTrue(calibration.decision.eligibleForHoldout)
    XCTAssertEqual(calibration.decision.knownCorrectCount, 4)
    XCTAssertEqual(calibration.decision.knownWrongCount, 0)
    XCTAssertEqual(calibration.decision.knownRejectedCount, 0)
  }

  private func makeTuningRun() -> AMISpeakerLocalRun {
    let enrollment = [
      identity(1, "p1-e1", "P1", .enrollment, .dictation, "a"),
      identity(2, "p1-e2", "P1", .enrollment, .dictation, "a"),
      identity(3, "p2-e1", "P2", .enrollment, .dictation, "b"),
      identity(4, "p2-e2", "P2", .enrollment, .dictation, "b"),
    ]
    let queries = SpeakerEvaluationEntryMode.allCases.enumerated().map {
      identity(10 + $0.offset, "p1-q-\($0.offset)", "P1", .query, $0.element, "a")
    }
    return AMISpeakerLocalRun(
      split: .tuning,
      corpusManifestID: "fixture-speaker-tuning",
      corpusVersion: "1.0.0",
      datasetID: "ami-meeting-corpus",
      datasetVersion: "1.6.2",
      license: "CC-BY-4.0",
      diarizationSamples: [diarization(20)],
      identitySamples: enrollment + queries
    )
  }

  private func makeReleaseRun() -> AMISpeakerLocalRun {
    let known = SpeakerEvaluationEntryMode.allCases.enumerated().map {
      identity(30 + $0.offset, "p2-q-\($0.offset)", "P2", .query, $0.element, "b")
    }
    let unknown = SpeakerEvaluationEntryMode.allCases.enumerated().map {
      identity(
        40 + $0.offset,
        "unknown-q-\($0.offset)",
        "PX",
        .query,
        $0.element,
        "c",
        evidenceSufficient: false
      )
    }
    return AMISpeakerLocalRun(
      split: .releaseHoldout,
      corpusManifestID: "fixture-speaker-release",
      corpusVersion: "1.0.0",
      datasetID: "ami-meeting-corpus",
      datasetVersion: "1.6.2",
      license: "CC-BY-4.0",
      diarizationSamples: [diarization(50)],
      identitySamples: known + unknown
    )
  }

  private func diarization(_ ordinal: Int) -> SpeakerDiarizationLocalSample {
    SpeakerDiarizationLocalSample(
      sampleUUID: uuid(ordinal),
      meetingID: "fixture-meeting",
      mode: .roomMicrophone,
      expectedSpeakerCount: 2,
      audio: audio("d"),
      reference: [
        SpeakerSegment(
          speakerID: "A",
          startNanoseconds: 0,
          endNanoseconds: 500_000_000
        ),
        SpeakerSegment(
          speakerID: "B",
          startNanoseconds: 500_000_000,
          endNanoseconds: 1_000_000_000
        ),
      ]
    )
  }

  private func identity(
    _ ordinal: Int,
    _ sampleID: String,
    _ personID: String,
    _ role: SpeakerIdentitySampleRole,
    _ mode: SpeakerEvaluationEntryMode,
    _ digestCharacter: Character,
    evidenceSufficient: Bool = true
  ) -> SpeakerIdentityLocalSample {
    SpeakerIdentityLocalSample(
      sampleUUID: uuid(ordinal),
      sampleID: sampleID,
      expectedPersonID: personID,
      evidenceSufficient: evidenceSufficient,
      role: role,
      mode: mode,
      audio: audio(digestCharacter)
    )
  }

  private func audio(_ digestCharacter: Character) -> SpeakerPreparedAudioAsset {
    SpeakerPreparedAudioAsset(
      relativePath: "audio/\(digestCharacter).f32le",
      contentDigest: String(repeating: String(digestCharacter), count: 64),
      sampleCount: 16_000,
      durationNanoseconds: 1_000_000_000
    )
  }

  private func vectorMap(
    tuning: AMISpeakerLocalRun,
    release: AMISpeakerLocalRun
  ) -> [String: [Float]] {
    Dictionary(
      (tuning.identitySamples + release.identitySamples).map {
        let vector: [Float]
        switch $0.audio.contentDigest.first {
        case "a": vector = [1, 0]
        case "b": vector = [0, 1]
        default: vector = [-1, 0]
        }
        return ($0.audio.contentDigest, vector)
      },
      uniquingKeysWith: { first, _ in first }
    )
  }

  private func unitVector(degrees: Double) -> [Float] {
    let radians = degrees * .pi / 180
    return [Float(cos(radians)), Float(sin(radians))]
  }

  private func writeManifest(
    at root: URL,
    id: String,
    tier: CorpusTier,
    holdout: Bool
  ) throws {
    let manifest = CorpusManifest(
      manifestID: id,
      version: "1.0.0",
      tier: tier,
      releaseHoldout: holdout,
      containsPrivateContent: false,
      samples: [
        CorpusSampleManifest(
          sampleUUID: uuid(99),
          consentClass: "public",
          assetReference: "external-corpus://fixture/audio.wav",
          contentDigest: String(repeating: "f", count: 64),
          languages: ["en-US"],
          tags: ["fixture"]
        )
      ]
    )
    try encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
  }

  private func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  private func uuid(_ ordinal: Int) -> UUID {
    UUID(
      uuidString: String(
        format: "73000000-0000-4000-8000-%012d",
        ordinal
      )
    )!
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

private actor FixtureSpeakerEngine: ProductionSpeakerEvaluationEngine {
  let vectors: [String: [Float]]

  init(vectors: [String: [Float]]) {
    self.vectors = vectors
  }

  func diarize(
    audio: SpeakerPreparedAudioAsset,
    jobID: UUID,
    expectedSpeakerRange: ClosedRange<Int>?
  ) -> [SpeakerSegment] {
    XCTAssertNil(
      expectedSpeakerRange, "Evaluation must not supply AMI's participant count to the model.")
    return [
      SpeakerSegment(
        speakerID: "X",
        startNanoseconds: 0,
        endNanoseconds: 500_000_000
      ),
      SpeakerSegment(
        speakerID: "Y",
        startNanoseconds: 500_000_000,
        endNanoseconds: 1_000_000_000
      ),
    ]
  }

  func embed(
    audio: SpeakerPreparedAudioAsset,
    jobID: UUID
  ) throws -> [Float] {
    try XCTUnwrap(vectors[audio.contentDigest])
  }
}
