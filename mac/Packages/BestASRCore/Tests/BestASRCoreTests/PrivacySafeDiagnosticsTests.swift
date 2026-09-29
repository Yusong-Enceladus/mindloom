import Foundation
import XCTest

@testable import BestASRCore
@testable import BestASREvidence

final class PrivacySafeDiagnosticsTests: XCTestCase {
  func testLoggerStoresOnlyTypedPrivacySafeEvents() async throws {
    let logger = PrivacySafeLogger(capacity: 2)
    let event = try makeEvent()

    await logger.record(event)

    let snapshot = await logger.snapshot()
    XCTAssertEqual(snapshot, [event])
    XCTAssertThrowsError(try SafeDiagnosticToken("unsafe/path"))
    XCTAssertThrowsError(
      try PrivacySafeMetric(name: .realtimeFactor, value: .infinity)
    )
  }

  func testDiagnosticBundleRedactsSensitiveInputAndMatchesSchema() throws {
    let plantedParticipantName = "PERSON_NAME_FIXTURE"
    let plantedWindowTitle = "WINDOW_TITLE_FIXTURE"
    let plantedTranscriptText = "TRANSCRIPT_TEXT_FIXTURE"
    let plantedAudioPath = "/private/tmp/audio-fixture.wav"
    let plantedEmbedding: [Float] = [0.123_456_7, -0.234_567_8, 0.345_678_9]
    let input = DiagnosticSourceInput(
      appVersion: try SafeDiagnosticToken("0.1.0"),
      osVersion: try SafeDiagnosticToken("26.5.2"),
      models: [
        DiagnosticModelVersion(
          capability: .asr,
          artifactID: try SafeDiagnosticToken("fixture-asr"),
          version: try SafeDiagnosticToken("1.0.0")
        )
      ],
      events: [try makeEvent()],
      participantName: plantedParticipantName,
      windowTitle: plantedWindowTitle,
      transcriptText: plantedTranscriptText,
      audioPath: plantedAudioPath,
      speakerEmbedding: plantedEmbedding
    )
    let bundle = DiagnosticBundleBuilder.build(
      input: input,
      bundleID: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
      createdAt: Date(timeIntervalSince1970: 1_753_286_400)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(bundle)
    let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))

    XCTAssertFalse(encoded.contains(plantedParticipantName))
    XCTAssertFalse(encoded.contains(plantedWindowTitle))
    XCTAssertFalse(encoded.contains(plantedTranscriptText))
    XCTAssertFalse(encoded.contains(plantedAudioPath))
    for value in plantedEmbedding {
      XCTAssertFalse(encoded.contains(String(value)))
    }
    XCTAssertEqual(Set(bundle.redactedFields), Set(DiagnosticRedactedField.allCases))

    let schemaData = try Data(
      contentsOf:
        repositoryRoot
        .appendingPathComponent("schemas/evidence/diagnostic-bundle.schema.json")
    )
    try JSONSchemaSubsetValidator.validate(instanceData: data, schemaData: schemaData)
  }

  private func makeEvent() throws -> PrivacySafeLogEvent {
    try PrivacySafeLogEvent(
      correlationID: UUID(uuidString: "88888888-8888-4888-8888-888888888888")!,
      recordedAt: Date(timeIntervalSince1970: 1_753_286_400),
      category: .inference,
      state: .recovered,
      durationMilliseconds: 125,
      retryCount: 1,
      metrics: [
        try PrivacySafeMetric(name: .backlogCount, value: 2),
        try PrivacySafeMetric(name: .realtimeFactor, value: 0.5),
      ]
    )
  }

  private var repositoryRoot: URL {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != "/" {
      let marker = candidate.appendingPathComponent("PRODUCT_REQUIREMENTS.md")
      if FileManager.default.fileExists(atPath: marker.path) {
        return candidate
      }
      candidate.deleteLastPathComponent()
    }
    fatalError("Could not locate repository root from \(#filePath)")
  }
}
