import BestASRDomain
import BestASRMemory
import Foundation
import MindloomAgentProtocol
import XCTest

@testable import BestASRAgentAccess

/// v12 search: the agents' search finds matters by meaning with the App's
/// model and combining rule, only from the words the agent may read.
/// A deterministic stand-in model; synthetic text.
final class AgentMeaningSearchTests: XCTestCase {
  private let zone = TimeZone(identifier: "Asia/Singapore")!

  private func date(_ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 15))!
  }

  private var clock: SearchClock { SearchClock(now: date(9, 30), timeZone: zone) }

  /// Records the pieces that reach the stand-in model.
  final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    func add(_ more: [String]) { lock.withLock { texts += more } }
    var all: [String] { lock.withLock { texts } }
  }

  /// A stand-in model: words of one concept point the same way.
  private static func meaning(_ recorder: Recorder, floor: Float = 0.5) -> AgentMeaning {
    AgentMeaning(floor: floor) { texts, role in
      if role == .document { recorder.add(texts) }
      let concepts: [[String]] = [["房东", "续租", "房子到期", "房租"], ["实习", "入职", "报到"]]
      return texts.map { text in
        var vector = [Float](repeating: 0, count: 16)
        for (index, words) in concepts.enumerated() where words.contains(where: text.contains) {
          vector[index] = 1
        }
        // Anything else: a small direction of its own per character (two
        // unrelated texts are not alike; once all such texts shared one
        // direction and every one of them matched every other).
        for scalar in text.unicodeScalars where scalar.value > 0x4E00 {
          vector[3 + Int(scalar.value % 13)] += 0.05
        }
        return MeaningMatrix.normalized(vector)
      }
    }
  }

  private func document(_ id: String, _ title: String, _ text: String, source: String = "微信")
    -> AgentSearchDocument
  {
    AgentSearchDocument(
      matterID: id, title: title, status: "", people: [], steps: [],
      items: [
        .init(
          itemID: "\(id)-1", text: text, at: date(9, 25),
          source: AgentSearchSource(name: source, inputMode: "userItem", itemKind: "text"))
      ], updatedAt: date(9, 25))
  }

  func testMeaningFindsMattersWithoutTheWordsAfterMattersWithThem() async {
    let documents = [
      document("E-RENT", "租房的事", "续租合同下周签"),
      document("E-LANDLORD", "房东", "房东说要涨价"),
      document("E-JOB", "穹顶", "四月去报到"),
    ]
    let recorder = Recorder()
    let engine = AgentRecordSearch(meaning: { Self.meaning(recorder) })
    let result = await engine.search("房东", in: documents, limit: 10, clock: clock)
    XCTAssertEqual(result.hits.map(\.matterID), ["E-LANDLORD", "E-RENT"])
    XCTAssertEqual(result.hits.last?.itemID, "E-RENT-1")
    XCTAssertFalse(result.hits.last?.partial ?? true)
    // Without the model: characters only.
    let plain = await AgentRecordSearch().search("房东", in: documents, limit: 10, clock: clock)
    XCTAssertEqual(plain.hits.map(\.matterID), ["E-LANDLORD"])
    // Words nothing holds.
    let vague = await engine.search("房子到期", in: documents, limit: 10, clock: clock)
    XCTAssertEqual(Set(vague.hits.map(\.matterID)), ["E-RENT", "E-LANDLORD"])
  }

  func testConditionsStillApplyAndVectorsAreReused() async {
    let documents = [
      document("E-RENT", "租房的事", "续租合同下周签", source: "邮件"),
      document("E-LANDLORD", "房东", "房东说要涨价"),
    ]
    let recorder = Recorder()
    let engine = AgentRecordSearch(meaning: { Self.meaning(recorder) })
    let result = await engine.search("微信 房子到期", in: documents, limit: 10, clock: clock)
    XCTAssertEqual(result.hits.map(\.matterID), ["E-LANDLORD"])
    let embedded = recorder.all.count
    _ = await engine.search("微信 房子到期", in: documents, limit: 10, clock: clock)
    XCTAssertEqual(recorder.all.count, embedded)
  }

  /// Only the words the agent reads are embedded: a masked number never
  /// reaches the model, so meaning cannot find what masking hid (AGENT-005).
  /// Through the service, with the grant's real masking (review fix: the
  /// earlier test fed already masked words and could not fail). The same
  /// search for an agent allowed to see numbers does embed the number, so
  /// the check can fail.
  func testMaskedNumbersNeverReachTheModelThroughTheService() async throws {
    let recorder = Recorder()
    let owner = ScriptedOwner()
    let service = AgentAccessService(
      memory: FixedMemory(snapshot: try AgentFixture.snapshot()), records: MemoryAgentRecords(),
      secrets: MemoryAgentGrantSecretStore(), consent: owner,
      search: AgentRecordSearch(meaning: { Self.meaning(recorder) }),
      timeZone: AgentFixture.timeZone, clock: { AgentFixture.now })
    await owner.queue(allowAll())  // numbers masked: the default
    let masked = await AgentTestClient(service: service)
    let answer = await masked.call("search", ["query": "第三组什么时候跑完"])
    XCTAssertFalse(answer.isErrorResult, answer.text)
    let embedded = recorder.all
    XCTAssertTrue(embedded.contains { $0.contains("第三组") }, "the matter's words were embedded")
    XCTAssertTrue(embedded.contains { $0.contains("〔手机号·") }, "as the agent reads them")
    for text in embedded {
      XCTAssertFalse(text.contains(AgentFixture.phone))
      XCTAssertFalse(text.contains(AgentFixture.email))
      XCTAssertNil(text.range(of: "1[3-9][0-9]{9}", options: .regularExpression))
    }
    await owner.queue(allowAll(numbers: true))
    let raw = await AgentTestClient(service: service, name: "codex-mcp-client", path: "/opt/codex")
    _ = await raw.call("search", ["query": "第三组什么时候跑完"])
    XCTAssertTrue(recorder.all.contains { $0.contains(AgentFixture.phone) })
  }

  /// A piece the warm-up made from words as they are is never used for the
  /// same piece masked: masked words have their own key, made by the search.
  func testMaskedPiecesDoNotUseTheVectorsOfTheWordsAsTheyAre() async throws {
    let shelf = Shelf()
    let recorder = Recorder()
    let engine = AgentRecordSearch(meaning: { Self.meaning(recorder, shelf: shelf) })
    let plain = [document("E-RENT", "租房的事", "房东电话 13812345678，续租合同下周签")]
    _ = try await engine.warmMeaning(
      plain, meaning: Self.meaning(recorder, shelf: shelf), stored: [], pause: {})
    let warmed = recorder.all.count
    let masker = try PrivacyMasker(
      maskKey: Data(repeating: 3, count: OrganizerKeyMaterial.byteCount))
    let maskedDocument = document("E-RENT", "租房的事", masker.mask("房东电话 13812345678，续租合同下周签"))
    _ = await engine.search("房东", in: [maskedDocument], limit: 10, clock: clock)
    let made = recorder.all.dropFirst(warmed)
    XCTAssertEqual(made.count, 1, "the masked piece was made by the search")
    XCTAssertFalse(made.first?.contains("13812345678") ?? true)
  }

  // MARK: - Vectors kept in the library (review fixes)

  /// A lock-protected stand-in for the library's agent vectors.
  final class Shelf: @unchecked Sendable {
    private let lock = NSLock()
    private var vectors: [String: [Float]] = [:]
    private(set) var reads = 0
    func stored(_ keys: [String]) -> [String: [Float]] {
      lock.withLock {
        reads += 1
        return vectors.filter { keys.contains($0.key) }
      }
    }
    func store(_ more: [String: [Float]]) { lock.withLock { vectors.merge(more) { $1 } } }
    var keys: Set<String> { lock.withLock { Set(vectors.keys) } }
  }

  private static func meaning(
    _ recorder: Recorder, shelf: Shelf, maximumNewPieces: Int = 1_500,
    delay: Duration? = nil
  ) -> AgentMeaning {
    let base = meaning(recorder)
    return AgentMeaning(
      floor: base.floor, maximumNewPieces: maximumNewPieces, model: "concept",
      stored: { shelf.stored($0) }, store: { vectors, _ in shelf.store(vectors) },
      embed: { texts, role in
        if let delay { try await Task.sleep(for: delay) }
        return try await base.embed(texts, role)
      })
  }

  private var library: [AgentSearchDocument] {
    [
      document("E-RENT", "租房的事", "续租合同下周签"),
      document("E-LANDLORD", "房东", "房东说要涨价"),
      document("E-JOB", "穹顶", "四月去报到"),
    ]
  }

  /// After a relaunch (a new engine) the vectors come from the library: no
  /// piece is made again.
  func testVectorsKeptInTheLibraryAreNotMadeAgainAfterALaunch() async {
    let shelf = Shelf()
    let recorder = Recorder()
    let first = AgentRecordSearch(meaning: { Self.meaning(recorder, shelf: shelf) })
    let before = await first.search("房子到期", in: library, limit: 10, clock: clock)
    let made = recorder.all.count
    XCTAssertGreaterThan(made, 0)
    let relaunched = AgentRecordSearch(meaning: { Self.meaning(recorder, shelf: shelf) })
    let after = await relaunched.search("房子到期", in: library, limit: 10, clock: clock)
    XCTAssertEqual(recorder.all.count, made, "nothing made again")
    XCTAssertEqual(after.hits.map(\.matterID), before.hits.map(\.matterID))
    XCTAssertFalse(after.meaningPartial)
  }

  /// Two searches at once make each piece once.
  func testParallelSearchesMakeEachPieceOnce() async {
    let shelf = Shelf()
    let recorder = Recorder()
    let engine = AgentRecordSearch(meaning: {
      Self.meaning(recorder, shelf: shelf, delay: .milliseconds(40))
    })
    let documents = library
    let clock = clock
    async let a = engine.search("房子到期", in: documents, limit: 10, clock: clock)
    async let b = engine.search("房东", in: documents, limit: 10, clock: clock)
    _ = await (a, b)
    XCTAssertEqual(recorder.all.count, Set(recorder.all).count, "no piece made twice")
    XCTAssertEqual(Set(recorder.all).count, AgentRecordSearch.meaningKeys(of: documents).count)
  }

  /// Memory stays within its budget even for the pieces the current search
  /// uses; what went is read from the library again, not made again.
  func testMemoryStaysWithinItsBudget() async {
    let shelf = Shelf()
    let recorder = Recorder()
    let meaning = Self.meaning(recorder, shelf: shelf)
    let vectors = AgentMeaningVectors(budget: 500)
    let wanted = (0..<10).map { (key: "k\($0)", text: "第\($0)段：房东和续租") }
    let first = await vectors.vectors(for: wanted, meaning: meaning, maximumNew: 100)
    XCTAssertEqual(first.found.count, 10, "this search compares all ten")
    XCTAssertEqual(first.missing, 0)
    let bytes = await vectors.bytes
    XCTAssertLessThanOrEqual(bytes, 500)
    let kept = await vectors.count
    XCTAssertLessThan(kept, 10)
    let second = await vectors.vectors(for: wanted, meaning: meaning, maximumNew: 100)
    XCTAssertEqual(second.found.count, 10)
    XCTAssertEqual(recorder.all.count, 10, "read from the library, not made again")
    let after = await vectors.bytes
    XCTAssertLessThanOrEqual(after, 500)
  }

  /// The background warm-up makes every piece a search compares; the search
  /// then makes none. It waits at its pause and continues where it stopped.
  func testWarmUpMakesWhatSearchesNeedAndResumes() async throws {
    let shelf = Shelf()
    let recorder = Recorder()
    let engine = AgentRecordSearch(meaning: { Self.meaning(recorder, shelf: shelf) })
    let documents = (0..<40).map { document("E\($0)", "第\($0)件事", "第\($0)次和房东谈续租") }
    let all = AgentRecordSearch.meaningKeys(of: documents)
    // Dictation starts after the first batch: the warm-up stops there.
    let calls = Counter()
    do {
      _ = try await engine.warmMeaning(
        documents, meaning: Self.meaning(recorder, shelf: shelf), stored: shelf.keys
      ) {
        if calls.next() > 1 { throw CancellationError() }
      }
      XCTFail("the pause stops the warm-up")
    } catch is CancellationError {}
    XCTAssertEqual(recorder.all.count, AgentMeaningVectors.warmBatch)
    let warmup = try await engine.warmMeaning(
      documents, meaning: Self.meaning(recorder, shelf: shelf), stored: shelf.keys, pause: {})
    XCTAssertEqual(warmup.keys, all)
    XCTAssertEqual(warmup.embedded, all.count - AgentMeaningVectors.warmBatch)
    XCTAssertEqual(recorder.all.count, all.count, "each piece made once")
    let result = await engine.search("房子到期", in: documents, limit: 10, clock: clock)
    XCTAssertEqual(recorder.all.count, all.count, "the search made nothing")
    XCTAssertFalse(result.hits.isEmpty)
    XCTAssertFalse(result.meaningPartial)
  }

  /// A search that may make only some pieces says its meaning side was
  /// partial, and the agent's answer says so too.
  func testPartialMeaningIsSaidInTheAnswer() async throws {
    let recorder = Recorder()
    let partial = await AgentRecordSearch(meaning: {
      Self.meaning(recorder, shelf: Shelf(), maximumNewPieces: 1)
    }).search("房子到期", in: library, limit: 10, clock: clock)
    XCTAssertTrue(partial.meaningPartial)
    let full = await AgentRecordSearch(meaning: { Self.meaning(recorder, shelf: Shelf()) })
      .search("房子到期", in: library, limit: 10, clock: clock)
    XCTAssertFalse(full.meaningPartial)

    let owner = ScriptedOwner()
    let service = AgentAccessService(
      memory: FixedMemory(snapshot: try AgentFixture.snapshot()), records: MemoryAgentRecords(),
      secrets: MemoryAgentGrantSecretStore(), consent: owner,
      search: AgentRecordSearch(meaning: {
        Self.meaning(recorder, shelf: Shelf(), maximumNewPieces: 0)
      }),
      timeZone: AgentFixture.timeZone, clock: { AgentFixture.now })
    await owner.queue(allowAll())
    let client = await AgentTestClient(service: service)
    let answer = await client.call("search", ["query": "第三组什么时候跑完"])
    XCTAssertTrue(answer.text.contains(AgentCopy.meaningPartial), answer.text)
    XCTAssertEqual(answer.structured?["meaning_partial"], true)
  }

  /// Once dictation starts (the App's gate says no), a search embeds no new
  /// pieces: it answers by characters and the vectors it already has.
  func testGateStopsNewPiecesAndKeepsTheCharacterResults() async {
    let documents = [
      document("E-RENT", "租房的事", "续租合同下周签"),
      document("E-LANDLORD", "房东", "房东说要涨价"),
    ]
    let recorder = Recorder()
    let gated = AgentMeaning(
      floor: 0.5, mayEmbed: { false },
      embed: { texts, role in try await Self.meaning(recorder).embed(texts, role) })
    let engine = AgentRecordSearch(meaning: { gated })
    let result = await engine.search("房东", in: documents, limit: 10, clock: clock)
    XCTAssertEqual(result.hits.map(\.matterID), ["E-LANDLORD"])
    XCTAssertTrue(recorder.all.isEmpty, "no record piece reached the model")
  }

  func testUnrelatedQueryAddsNothing() async {
    let documents = [document("E-RENT", "租房的事", "续租合同下周签")]
    let recorder = Recorder()
    let engine = AgentRecordSearch(meaning: { Self.meaning(recorder) })
    let result = await engine.search("滑雪装备", in: documents, limit: 10, clock: clock)
    XCTAssertEqual(result.hits, [])
  }
}
