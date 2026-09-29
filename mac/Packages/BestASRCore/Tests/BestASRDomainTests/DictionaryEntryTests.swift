import BestASRDomain
import Foundation
import XCTest

final class DictionaryEntryTests: XCTestCase {
  func testDictionaryEntryRoundTripsWithStableIdentityAndRevision() throws {
    let date = Date(timeIntervalSince1970: 100)
    let entry = try DictionaryEntry(
      id: DictionaryEntryID(
        UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
      ),
      revision: Revision(2),
      canonicalForm: "bestASR",
      spokenForms: ["best A S R", "最佳语音"],
      enabled: true,
      createdAt: date,
      updatedAt: date
    )
    let decoded = try JSONDecoder().decode(
      DictionaryEntry.self,
      from: JSONEncoder().encode(entry)
    )
    XCTAssertEqual(decoded, entry)
    XCTAssertEqual(
      try DictionaryContextProjection(entries: [entry]).canonicalTerms,
      ["bestASR"]
    )
  }

  func testDictionaryEntryRejectsUnboundedDuplicateAndInvalidTerms() throws {
    let date = Date(timeIntervalSince1970: 100)
    let invalid: [(String, [String])] = [
      ("", []),
      (" Alice ", []),
      ("Alice", ["same", "SAME"]),
      (String(repeating: "a", count: 257), []),
    ]
    for (canonical, spoken) in invalid {
      XCTAssertThrowsError(
        try DictionaryEntry(
          revision: Revision(1),
          canonicalForm: canonical,
          spokenForms: spoken,
          enabled: true,
          createdAt: date,
          updatedAt: date
        )
      )
    }
  }
}
