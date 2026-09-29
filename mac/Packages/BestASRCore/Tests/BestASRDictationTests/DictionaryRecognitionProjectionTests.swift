import BestASRDictation
import BestASRDomain
import BestASRInference
import Foundation
import XCTest

final class DictionaryRecognitionProjectionTests: XCTestCase {
  func testProjectionPreservesCanonicalAndSpokenForms() throws {
    let date = Date(timeIntervalSince1970: 100)
    let projection = try DictionaryContextProjection(
      entries: [
        DictionaryEntry(
          revision: Revision(1),
          canonicalForm: "bestASR",
          spokenForms: ["best A S R", "best ar"],
          enabled: true,
          createdAt: date,
          updatedAt: date
        )
      ]
    )

    XCTAssertEqual(
      projection.asrDictionaryHints,
      [
        ASRDictionaryHint(
          canonicalForm: "bestASR",
          spokenForms: ["best A S R", "best ar"]
        )
      ]
    )
  }

  func testLegacyASRRequestWithoutStructuredHintsStillDecodes() throws {
    let sessionID = SessionID(
      UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    )
    let request = DictationASRRequest(
      sessionID: sessionID,
      inputRevision: 1,
      audio: [],
      dictionaryTerms: ["bestASR"]
    )
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        as? [String: Any]
    )
    object.removeValue(forKey: "dictionaryHints")

    let decoded = try JSONDecoder().decode(
      DictationASRRequest.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    XCTAssertEqual(decoded.sessionID, sessionID)
    XCTAssertEqual(decoded.dictionaryTerms, ["bestASR"])
    XCTAssertEqual(decoded.dictionaryHints, [])
  }
}
