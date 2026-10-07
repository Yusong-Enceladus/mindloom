import BestASRDomain
import BestASRMemory
import Foundation
import XCTest

@testable import BestASRAgentAccess

/// Review v12-B #10 (regression): an agent's search keeps the index tokens
/// and the masked text of the matters in reach between calls. A corpus
/// bigger than the cache's budget no longer empties it in the middle of a
/// call (the old token cache cleared itself whole past 4 MB, so every call on
/// a large 全部 grant re-masked and re-tokenized everything).
final class AgentSearchCacheTests: XCTestCase {
  func testOneCallNeverDropsWhatItUsesAndTheNextFindsIt() {
    let cache = AgentGenerationCache<String>(budget: 100)
    // One call touches ~400 bytes against a 100-byte budget.
    cache.beginUse()
    let keys = (0..<40).map { "key-\($0)" }
    for key in keys { _ = cache.value(key) { key.uppercased() } }
    XCTAssertEqual(cache.made, 40)
    XCTAssertEqual(cache.count, 40, "nothing dropped while the call runs")
    // The next call over the same keys makes nothing again.
    cache.beginUse()
    for key in keys { XCTAssertEqual(cache.value(key) { "made again" }, key.uppercased()) }
    XCTAssertEqual(cache.made, 40)
    // A call over other keys: at its start what the last call did not use
    // would go (here everything was used), afterwards the old keys go first.
    cache.beginUse()
    for index in 0..<5 { _ = cache.value("other-\(index)") { "x" } }
    cache.beginUse()
    XCTAssertLessThanOrEqual(cache.count, 40)
    XCTAssertEqual(cache.value("other-0") { "made again" }, "x", "the last call's keys stay")
  }

  /// Masked text: the same matter's words are masked once per grant.
  func testMaskedTextIsMadeOnceAcrossCalls() throws {
    let masker = try PrivacyMasker(
      maskKey: Data(repeating: 7, count: OrganizerKeyMaterial.byteCount))
    let memo = AgentGenerationCache<String>(budget: 1_000)
    let mask = AgentTextMask(masker: masker, memo: memo)
    let text = "张三的电话 13800138000，周五交初稿"
    memo.beginUse()
    let first = mask(text)
    XCTAssertFalse(first.contains("13800138000"))
    memo.beginUse()
    XCTAssertEqual(mask(text), first)
    XCTAssertEqual(memo.made, 1)
    // Without masking nothing is kept.
    XCTAssertEqual(AgentTextMask(masker: nil, memo: memo)(text), text)
  }

  /// A corpus several times the old 4 MB budget (synthetic, about 6,000
  /// records): the second search tokenizes nothing again and is faster.
  func testASecondSearchOverALargeCorpusTokenizesNothingAgain() async {
    let zone = TimeZone(identifier: "Asia/Singapore")!
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let filler = String(repeating: "组会讨论实验进度和下周安排，", count: 25)
    let documents = (0..<200).map { matter in
      AgentSearchDocument(
        matterID: "E\(matter)", title: "合成事 \(matter)", status: "", people: [], steps: [],
        items: (0..<30).map { item in
          AgentSearchDocument.Item(
            itemID: "I\(matter)-\(item)", text: "第\(matter)-\(item)条：\(filler)",
            at: now.addingTimeInterval(Double(-item) * 3_600), source: nil, speakers: [])
        }, updatedAt: now)
    }
    let bytes = documents.flatMap(\.items).reduce(0) { $0 + $1.text.utf8.count }
    XCTAssertGreaterThan(bytes, 4_000_000, "bigger than the old cache's budget")
    let search = AgentRecordSearch()
    let clock = SearchClock(now: now, timeZone: zone)
    let started = ContinuousClock.now
    let first = await search.search("实验进度 下周", in: documents, limit: 5, clock: clock)
    let firstTook = ContinuousClock.now - started
    let made = search.cache.made
    let again = ContinuousClock.now
    let second = await search.search("组会 安排", in: documents, limit: 5, clock: clock)
    let secondTook = ContinuousClock.now - again
    XCTAssertFalse(first.hits.isEmpty)
    XCTAssertFalse(second.hits.isEmpty)
    XCTAssertEqual(search.cache.made, made, "the second search tokenized nothing again")
    XCTAssertLessThan(secondTook, firstTook)
    print(
      "agent search over \(documents.flatMap(\.items).count) records, \(bytes / 1_000_000) MB: "
        + "first \(firstTook), second \(secondTook)")
  }
}
