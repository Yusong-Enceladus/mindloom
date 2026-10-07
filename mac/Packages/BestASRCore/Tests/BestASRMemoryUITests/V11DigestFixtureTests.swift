import BestASRDomain
import BestASRMemory
import Foundation
import XCTest

@testable import BestASRMemoryUI

/// The native digest against the v10 prototype's own data (`data.js`, built
/// by `build_data.py` from the same synthetic state): matter E6's parts,
/// steps, risk and moments, and 按截止's rows. Skipped when the files are not
/// on this Mac.
final class V11DigestFixtureTests: XCTestCase {
  static let prototypeData = "/Users/Shared/mindloom-demo/v10/prototype/mac/src/data.js"

  private func prototype() throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: Self.prototypeData), V11Fixture.isAvailable else {
      throw XCTSkip("The v10 prototype data is not on this Mac.")
    }
    var text = try String(contentsOfFile: Self.prototypeData, encoding: .utf8)
    let start = try XCTUnwrap(text.firstIndex(of: "{"))
    let end = try XCTUnwrap(text.lastIndex(of: "}"))
    text = String(text[start...end])
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }

  @MainActor
  func testE6MatchesThePrototype() throws {
    let data = try prototype()
    let loaded = try V11Fixture.load()
    let state = V11Fixture.state(loaded)
    let digest = try XCTUnwrap(state.digest)
    let handle = Dictionary(loaded.handles.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    let matters = try XCTUnwrap(data["matters"] as? [[String: Any]])
    let e6 = try XCTUnwrap(matters.first { $0["id"] as? String == "E6" })
    let mine = try XCTUnwrap(digest.matter(loaded.handles["E6"] ?? ""))

    XCTAssertEqual(mine.status, e6["status"] as? String)
    XCTAssertEqual(mine.risk, e6["risk"] as? String)
    let parts = (e6["parts"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    XCTAssertEqual(Set(mine.parts.map(\.name)), Set(parts))

    let steps = e6["steps"] as? [[String: Any]] ?? []
    XCTAssertEqual(
      Set(mine.steps.map(\.id)), Set(steps.compactMap { $0["id"] as? String }), "the same steps")
    for step in steps {
      let id = try XCTUnwrap(step["id"] as? String)
      let native = try XCTUnwrap(mine.step(id), id)
      XCTAssertEqual(native.text, step["text"] as? String, id)
      XCTAssertEqual(native.partID, step["part"] as? String, id)
      XCTAssertEqual(native.glyph.rawValue, step["glyph"] as? String, id)
      XCTAssertEqual(native.due, step["due"] as? Bool, id)
      // The prototype repairs three names by hand (Ann Gu / Ann → 顾安, Yuan
      // Gao → 高原: a scenario table, F22); natively one person is one name
      // only through the organizer's persons and aliases.
      let repaired = native.who.map { ["Ann Gu": "顾安", "Ann": "顾安", "Yuan Gao": "高原"][$0] ?? $0 }
      XCTAssertEqual(repaired, step["who"] as? [String], id)
      let evidence = step["ev"] as? [String: Any]
      XCTAssertEqual(native.evidence != nil, evidence != nil, "\(id) has a source")
      if let evidence {
        XCTAssertEqual(native.evidence?.source.word, evidence["src"] as? String, id)
        XCTAssertEqual(
          native.evidence?.alsoIn.compactMap { handle[$0.eventID] }, evidence["also"] as? [String],
          "\(id) 同一…还讲到")
        XCTAssertEqual(native.evidence?.source.sameCaptureLead, evidence["lead"] as? String, id)
      }
    }
  }

  @MainActor
  func testDeadlineRowsMatchThePrototype() throws {
    let data = try prototype()
    let loaded = try V11Fixture.load()
    let digest = try XCTUnwrap(V11Fixture.state(loaded).digest)
    let handle = Dictionary(loaded.handles.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    let rows = try XCTUnwrap(data["deadlines"] as? [[String: Any]])
    let calendar = V11Fixture.calendar
    func day(_ date: Date) -> String {
      let parts = calendar.dateComponents([.year, .month, .day], from: date)
      return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    let theirs = rows.map {
      "\($0["date"] as? String ?? "") \($0["m"] as? String ?? "") \($0["text"] as? String ?? "")"
    }
    // The prototype keeps rows whose step is done and folds overdue ones at
    // runtime; compare the rows of matters that are not overdue.
    let ours = digest.deadlines.filter { $0.date >= digest.today }.map {
      "\(day($0.date)) \(handle[$0.eventID] ?? "?") \($0.text)"
    }
    // Rows on the same day may come in another matter order.
    XCTAssertEqual(ours.sorted(), theirs.filter { $0 >= "2026-09-20" }.sorted())
  }
}
