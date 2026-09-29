import BestASRDictation
import BestASRDomain
import Foundation
import XCTest

final class DictationDiagnosticsTests: XCTestCase {
  func testTypedEventContainsOnlyAllowedFields() throws {
    let event = try DictationDiagnosticEvent(
      sessionID: SessionID(testUUID(80)),
      phase: .recording,
      reason: .stateTransition,
      monotonicNanoseconds: 100,
      durationNanoseconds: 10,
      byteCount: 1_024,
      frameCount: 256,
      reasonCode: "capture-started",
      deviceID: "builtin-microphone",
      modelArtifactID: "fixture-asr"
    )
    let data = try JSONEncoder().encode(event)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    try PrivacySafeDictationDiagnosticSchema.validate(fieldNames: object.keys)
    XCTAssertTrue(
      Set(object.keys).isSubset(of: PrivacySafeDictationDiagnosticSchema.allowedFieldNames))
    let encoded = try XCTUnwrap(String(data: data, encoding: .utf8)).lowercased()
    for forbidden in [
      "transcript", "dictionary", "clipboard", "windowtitle",
      "personname", "audiopayload", "embedding", "surroundingtext",
    ] {
      XCTAssertFalse(encoded.contains(forbidden))
    }
  }

  func testForbiddenFieldsAndContentLikeTokensAreRejected() throws {
    for field in [
      "transcript", "dictionaryContents", "clipboardData", "windowTitle",
      "personName", "audioPayload", "speakerEmbedding", "participantMetadata",
    ] {
      XCTAssertThrowsError(
        try PrivacySafeDictationDiagnosticSchema.validate(fieldNames: [field])
      )
    }
    XCTAssertThrowsError(
      try DictationDiagnosticEvent(
        sessionID: nil,
        phase: .failedRecoverable,
        reason: .failure,
        monotonicNanoseconds: 1,
        reasonCode: "raw transcript leaked here"
      )
    )
  }
}
