import Foundation
import XCTest

@testable import BestASRSpeakerEvidence

final class SpeakerIdentityEvaluatorTests: XCTestCase {
  func testEnrollmentOnlyThresholdMatchesKnownAndRejectsUnknown() throws {
    for format in [
      SpeakerIdentityEmbeddingFormat.recordsFile,
      SpeakerIdentityEmbeddingFormat.fluidDirectory,
    ] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
      )
      defer { try? FileManager.default.removeItem(at: root) }
      try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
      )
      let manifestURL = root.appendingPathComponent("manifest.json")
      try Data(manifest.utf8).write(to: manifestURL)
      let vectors: [(String, [Float])] = [
        ("e-p1a", [1, 0]), ("e-p1b", [0.99, 0.01]),
        ("e-p2a", [0, 1]), ("e-p2b", [0.01, 0.99]),
        ("e-p3a", [-1, 0]), ("e-p3b", [-0.99, 0.01]),
        ("q-p1", [1, 0]), ("q-p2", [0, 1]),
        ("q-p3", [-1, 0]), ("q-p4", [0, -1]),
      ]
      let embeddingURL: URL
      switch format {
      case .recordsFile:
        embeddingURL = root.appendingPathComponent("records.json")
        let records = vectors.map {
          VectorRecord(sampleID: $0.0, embedding: $0.1)
        }
        try encode(VectorOutput(records: records)).write(to: embeddingURL)
      case .fluidDirectory:
        embeddingURL = root.appendingPathComponent(
          "fluid",
          isDirectory: true
        )
        for (sampleID, vector) in vectors {
          let directory = embeddingURL.appendingPathComponent(
            sampleID,
            isDirectory: true
          )
          try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
          )
          try encode([
            FluidVectorRecord(embedding256: vector),
            FluidVectorRecord(embedding256: vector),
          ]).write(to: directory.appendingPathComponent("embeddings.json"))
        }
      }

      let result = try SpeakerIdentityEvaluator.evaluate(
        SpeakerIdentityEvaluationRequest(
          candidate: "fixture",
          manifestURL: manifestURL,
          embeddingsURL: embeddingURL,
          embeddingFormat: format
        ))
      XCTAssertTrue(result.enrollmentSeparationFeasible)
      XCTAssertEqual(result.enrollmentCount, 6)
      XCTAssertEqual(result.queryCount, 4)
      XCTAssertEqual(result.knownCorrectCount, 3)
      XCTAssertEqual(result.knownWrongCount, 0)
      XCTAssertEqual(result.knownRejectedCount, 0)
      XCTAssertEqual(result.unknownRejectedCount, 1)
      XCTAssertEqual(result.falseMergeCount, 0)
      XCTAssertEqual(result.falseSplitCount, 0)
      XCTAssertEqual(result.falseRejectCount, 0)
      XCTAssertEqual(result.assignments.count, 4)
    }
  }

  private func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  private var manifest: String {
    #"""
    {
      "schemaVersion":1,
      "kind":"synthetic-speaker-identity-manifest",
      "entries":[
        {"sampleID":"e-p1a","expectedPersonID":"P1","evidenceSufficient":true,"role":"enrollment","mode":"dictation"},
        {"sampleID":"e-p1b","expectedPersonID":"P1","evidenceSufficient":true,"role":"enrollment","mode":"dictation"},
        {"sampleID":"e-p2a","expectedPersonID":"P2","evidenceSufficient":true,"role":"enrollment","mode":"dictation"},
        {"sampleID":"e-p2b","expectedPersonID":"P2","evidenceSufficient":true,"role":"enrollment","mode":"dictation"},
        {"sampleID":"e-p3a","expectedPersonID":"P3","evidenceSufficient":true,"role":"enrollment","mode":"dictation"},
        {"sampleID":"e-p3b","expectedPersonID":"P3","evidenceSufficient":true,"role":"enrollment","mode":"dictation"},
        {"sampleID":"q-p1","expectedPersonID":"P1","evidenceSufficient":true,"role":"query","mode":"dictation"},
        {"sampleID":"q-p2","expectedPersonID":"P2","evidenceSufficient":true,"role":"query","mode":"room-microphone"},
        {"sampleID":"q-p3","expectedPersonID":"P3","evidenceSufficient":true,"role":"query","mode":"system-audio"},
        {"sampleID":"q-p4","expectedPersonID":"P4","evidenceSufficient":false,"role":"query","mode":"imported-media"}
      ]
    }
    """#
  }
}

private struct VectorOutput: Encodable {
  let records: [VectorRecord]
}

private struct VectorRecord: Encodable {
  let sampleID: String
  let embedding: [Float]
}

private struct FluidVectorRecord: Encodable {
  let embedding256: [Float]
}
