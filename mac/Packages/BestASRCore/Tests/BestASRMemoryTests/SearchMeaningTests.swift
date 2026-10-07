import BestASRMemory
import Foundation
import XCTest

/// v12 search (ALIGNMENT 查-3, 查-6): pieces, vectors and how the two
/// searches combine. Synthetic text only.
final class SearchMeaningTests: XCTestCase {
  // MARK: - Pieces

  func testShortTextIsOnePiece() {
    let chunks = MeaningChunker.chunks(of: "  把 GripDiff 的消融实验结果发给导师。 ")
    XCTAssertEqual(chunks.count, 1)
    XCTAssertEqual(chunks[0].text, "把 GripDiff 的消融实验结果发给导师。")
    XCTAssertEqual(chunks[0].start, 0)
  }

  func testEmptyAndPunctuationOnlyTextHaveNoPieces() {
    XCTAssertEqual(MeaningChunker.chunks(of: ""), [])
    XCTAssertEqual(MeaningChunker.chunks(of: "  。。…\n "), [])
  }

  func testLongTextIsCutAtSentencesWithOverlapAndCovered() {
    let sentences = (0..<40).map { "第\($0)句话讲的是实验进度和下一步安排。" }
    let text = sentences.joined()
    let chunks = MeaningChunker.chunks(of: text, size: 60)
    XCTAssertGreaterThan(chunks.count, 5)
    for chunk in chunks {
      XCTAssertLessThanOrEqual(chunk.length, 60)
      // Each piece is exactly the text at its offset (trimmed).
      let characters = Array(text)
      let raw = String(characters[chunk.start..<(chunk.start + chunk.length)])
      XCTAssertEqual(raw.trimmingCharacters(in: .whitespacesAndNewlines), chunk.text)
    }
    // Every sentence is inside some piece.
    for sentence in sentences {
      XCTAssertTrue(chunks.contains { $0.text.contains(sentence) }, sentence)
    }
    // Neighbouring pieces share a sentence (a thought across the cut stays whole).
    for (a, b) in zip(chunks, chunks.dropFirst()) {
      XCTAssertLessThan(b.start, a.start + a.length)
    }
  }

  func testOneVeryLongSentenceIsCutToSize() {
    let text = String(repeating: "长", count: 1_000)
    let chunks = MeaningChunker.chunks(of: text, size: 240)
    XCTAssertEqual(chunks.map(\.length), [240, 240, 240, 240, 40])
  }

  func testPiecesAreCapped() {
    let text = (0..<1_000).map { "第\($0)句。" }.joined()
    XCTAssertEqual(MeaningChunker.chunks(of: text, size: 8, maximum: 7).count, 7)
  }

  // MARK: - Vectors

  func testPackRoundTripsWithinHalfPrecision() {
    let vector = MeaningMatrix.normalized((0..<64).map { Float(sin(Double($0))) })
    let data = MeaningMatrix.pack(vector)
    XCTAssertEqual(data.count, 128)
    let back = MeaningMatrix.unpack(data, dimension: 64)!
    for (a, b) in zip(vector, back) { XCTAssertEqual(a, b, accuracy: 1e-3) }
    XCTAssertNil(MeaningMatrix.unpack(data, dimension: 32))
  }

  func testBestTakesEachRecordsClosestPieceAndHonoursFloorAndFilter() {
    // Three records; B has two pieces, its second is the closest overall.
    let rows: [[Float]] = [
      [1, 0, 0], [0.6, 0.8, 0], [0, 1, 0], [0, 0, 1],
    ]
    let matrix = MeaningMatrix(
      dimension: 3, values: rows.flatMap { $0 }, rowOwner: [0, 1, 1, 2], owners: ["A", "B", "C"])
    let query = MeaningMatrix.normalized([0.1, 1, 0])
    let best = matrix.best(query)
    XCTAssertEqual(best.map(\.owner), ["B", "A", "C"])
    XCTAssertEqual(best[0].row, 2)
    XCTAssertEqual(matrix.best(query, floor: 0.5).map(\.owner), ["B"])
    XCTAssertEqual(matrix.best(query, allowed: { $0 != "B" }).map(\.owner), ["A", "C"])
    XCTAssertEqual(matrix.best(query, limit: 1).map(\.owner), ["B"])
  }

  // MARK: - Query text

  func testMeaningTextDropsTimeAndSourceButKeepsPeople() {
    let clock = SearchClock(now: Date(timeIntervalSince1970: 1_790_000_000))
    let context = SearchContext(
      people: [SearchPerson(id: "p1", name: "陆思成")], clock: clock)
    let query = SearchQueryParser.parse("上周 微信 陆思成 实习入职 ", context: context)
    let text = MeaningQueryText.text(query)
    XCTAssertFalse(text.contains("上周"))
    XCTAssertFalse(text.contains("微信"))
    XCTAssertTrue(text.contains("陆思成"))
    XCTAssertTrue(text.contains("实习入职"))
    XCTAssertTrue(MeaningQueryText.asksMeaning(query))
    // Only conditions: nothing to ask by meaning (time order).
    XCTAssertFalse(
      MeaningQueryText.asksMeaning(SearchQueryParser.parse("上周 微信 ", context: context)))
  }

  // MARK: - Combining

  func testWholeMatchesStayAheadOfMeaningOnlyRecords() {
    let lexical = [
      MeaningFusion.Lexical(id: "w1", partial: false),
      MeaningFusion.Lexical(id: "w2", partial: false),
      MeaningFusion.Lexical(id: "p1", partial: true),
    ]
    let meaning = [
      MeaningFusion.Meaning(id: "m1", similarity: 0.9),
      MeaningFusion.Meaning(id: "w2", similarity: 0.8),
      MeaningFusion.Meaning(id: "m2", similarity: 0.7),
    ]
    let fused = MeaningFusion.fuse(lexical: lexical, meaning: meaning)
    // w2 (both) above w1; both whole matches above everything else; then
    // what meaning found; records holding only some words last.
    XCTAssertEqual(fused.map(\.id), ["w2", "w1", "m1", "m2", "p1"])
    XCTAssertEqual(fused.first { $0.id == "m1" }?.meaningOnly, true)
    XCTAssertEqual(fused.first { $0.id == "p1" }?.partial, true)
    XCTAssertEqual(fused.first { $0.id == "w2" }?.meaningOnly, false)
    // Without the whole-match rule, a strong meaning hit can lead.
    let flat = MeaningFusion.fuse(
      lexical: lexical, meaning: meaning, policy: MeaningFusion.Policy(wholeMatchesFirst: false))
    XCTAssertEqual(flat.map(\.id).prefix(2), ["w2", "w1"])
    XCTAssertEqual(Set(flat.map(\.id)), ["w1", "w2", "p1", "m1", "m2"])
  }

  func testPartialFoundByMeaningIsNotMarkedPartial() {
    let fused = MeaningFusion.fuse(
      lexical: [MeaningFusion.Lexical(id: "x", partial: true)],
      meaning: [MeaningFusion.Meaning(id: "x", similarity: 0.6)])
    XCTAssertEqual(fused.map(\.partial), [false])
  }

  func testNoMeaningKeepsTheCharacterOrder() {
    let lexical = (0..<30).map { MeaningFusion.Lexical(id: "r\($0)", partial: $0 > 20) }
    let fused = MeaningFusion.fuse(lexical: lexical, meaning: [])
    XCTAssertEqual(fused.map(\.id), lexical.map(\.id))
  }

  func testDuplicatesInputsCountOnce() {
    let fused = MeaningFusion.fuse(
      lexical: [
        MeaningFusion.Lexical(id: "a", partial: false),
        MeaningFusion.Lexical(id: "a", partial: false),
      ],
      meaning: [MeaningFusion.Meaning(id: "b", similarity: 0.5)])
    XCTAssertEqual(fused.map(\.id), ["a", "b"])
  }
}
