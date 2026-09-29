import BestASRBenchmark
import Foundation
import XCTest

@testable import BestASRSpeakerEvidence

final class SpeakerEvidenceCollatorTests: XCTestCase {
  func testCollatesAllCandidateFormatsUnderOneBenchmarkContract() throws {
    for candidate in SpeakerEvidenceCandidate.allCases {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
      )
      defer { try? FileManager.default.removeItem(at: root) }
      let corpus = root.appendingPathComponent("corpus", isDirectory: true)
      let output = root.appendingPathComponent("output", isDirectory: true)
      let sampleOutput = output.appendingPathComponent(
        "spk-v1-001",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: sampleOutput,
        withIntermediateDirectories: true
      )
      try write(
        #"{"sampleID":"spk-v1-001","sampleRate":16000,"sampleCount":64000}"#,
        to: corpus.appendingPathComponent("spk-v1-001.receipt.json")
      )
      try write(
        "SPEAKER spk-v1-001 1 0.500 2.500 <NA> <NA> S1 <NA> <NA>\n",
        to: corpus.appendingPathComponent("spk-v1-001.rttm")
      )
      try write(
        "        0.25 real         0.10 user         0.01 sys\n"
          + "           123456  maximum resident set size\n",
        to: sampleOutput.appendingPathComponent("stderr.log")
      )

      switch candidate {
      case .fluid:
        try write(
          #"{"segments":[{"speakerId":"S1","startTimeSeconds":0.55,"endTimeSeconds":2.95}]}"#,
          to: sampleOutput.appendingPathComponent("result.json")
        )
      case .argmax:
        try write(
          "SPEAKER spk-v1-001 1 0.550 2.400 <NA> <NA> A <NA> <NA>\n",
          to: sampleOutput.appendingPathComponent("result.rttm")
        )
      case .sherpa:
        try write(
          "configuration\nStarted\n0.550 -- 2.950 speaker_00\n",
          to: sampleOutput.appendingPathComponent("stdout.log")
        )
      }

      let result = try SpeakerEvidenceCollator.collate(
        request(
          candidate: candidate,
          corpus: corpus,
          output: output
        ))
      XCTAssertEqual(result.task, .speaker)
      XCTAssertEqual(result.samples.count, 1)
      XCTAssertEqual(
        result.samples[0].sampleUUID.uuidString,
        "35000000-0000-4000-8000-000000000001"
      )
      XCTAssertEqual(result.samples[0].audioDurationNanoseconds, 4_000_000_000)
      XCTAssertEqual(result.samples[0].inferenceDurationNanoseconds, 250_000_000)
      XCTAssertEqual(result.samples[0].peakResidentBytes, 123_456)
      XCTAssertEqual(result.samples[0].diarization?.reference.count, 1)
      XCTAssertEqual(result.samples[0].diarization?.hypothesis.count, 1)
      XCTAssertEqual(result.configuration["network"], "denied")
    }
  }

  func testRejectsUnknownMatrixMode() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertThrowsError(
      try SpeakerEvidenceCollator.collate(
        SpeakerEvidenceCollationRequest(
          candidate: .fluid,
          matrixMode: "unreviewed",
          corpusDirectory: root,
          candidateOutputDirectory: root,
          benchmarkID: "speaker-test",
          runID: UUID(uuidString: "40000000-0000-4000-8000-000000000001")!,
          implementationRevision: "revision",
          artifactID: "artifact",
          artifactSHA256: String(repeating: "a", count: 64),
          provider: "provider",
          corpusManifestID: "manifest",
          corpusVersion: "1.0.0",
          environmentRef: "fixture://environment",
          toolchainVersion: "toolchain"
        ))
    ) { error in
      XCTAssertEqual(
        error as? SpeakerEvidenceCollatorError,
        .invalidMatrixMode("unreviewed")
      )
    }
  }

  private func request(
    candidate: SpeakerEvidenceCandidate,
    corpus: URL,
    output: URL
  ) -> SpeakerEvidenceCollationRequest {
    SpeakerEvidenceCollationRequest(
      candidate: candidate,
      matrixMode: "oracle",
      corpusDirectory: corpus,
      candidateOutputDirectory: output,
      benchmarkID: "speaker-\(candidate.rawValue)-test",
      runID: UUID(uuidString: "40000000-0000-4000-8000-000000000001")!,
      implementationRevision: "revision",
      artifactID: "artifact",
      artifactSHA256: String(repeating: "a", count: 64),
      provider: "provider",
      corpusManifestID: "manifest",
      corpusVersion: "1.0.0",
      environmentRef: "fixture://environment",
      toolchainVersion: "toolchain"
    )
  }

  private func write(_ string: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(string.utf8).write(to: url)
  }
}
