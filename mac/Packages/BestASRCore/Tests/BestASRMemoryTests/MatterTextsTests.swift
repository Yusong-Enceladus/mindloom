import BestASRDomain
import Foundation
import XCTest

@testable import BestASRMemory

/// The matter page's 原文 derivation (MAC-SPEC §4.10, §13.6): only the part of
/// an item about the matter, speakers kept, mail headers dropped, shell
/// commands skipped, the quoted span found. Synthetic data only.
final class MatterTextsTests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
  }()

  private func date(_ month: Int, _ day: Int, _ hour: Int = 10) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
  }

  private var now: Date { date(9, 20, 22) }

  private func id(_ n: Int) -> String { String(format: "F0000000-0000-4000-8000-%012d", n) }

  private func record(
    _ n: Int, at: Date, text: String, app: String = "微信", mode: SessionInputMode = .userItem
  ) -> MemoryItemRecord {
    MemoryItemRecord(
      sessionID: SessionID(UUID(uuidString: id(n))!), inputMode: mode, itemKind: .text,
      title: "", startedAt: at, updatedAt: at, sourceBundleID: nil, sourceDisplayName: app,
      sourceIdentifier: nil, text: text)
  }

  private func projection() -> MemoryProjection {
    typealias K = RemoteOrganizerMatterMap.Knot
    let records =
      [
        record(1, at: date(9, 18), text: "周明澜：引理3那块确认了吗\n我：RoboPrior 的回复信 R3 部分雨桐已经改完了\n周明澜：好\n我：嗯"),
        record(2, at: date(9, 19), text: "今天天气不错 晚上吃火锅 顺便说一下 RoboPrior 回复信大概写了四成", app: "Fn 口述"),
        record(
          3, at: date(9, 17),
          text:
            "From: 顾安 <ann@example.com>\nTo: 我 <me@example.com>\nSubject: Re: R1 补实验\n\nHi Zhiyuan,\n\n刚看到你的邮件了。R1 的回复信我这边改得差不多了。",
          app: "邮件"),
        record(4, at: date(9, 16), text: "cd ~/RoboPrior && git pull", app: "Terminal"),
        record(5, at: date(9, 15), text: "周末去看电影，买了爆米花", app: "微信"),
      ]
    let map = RemoteOrganizerMatterMap(
      strands: [.init(id: "s1", name: "R3 写作与回复信", itemIDs: [id(1), id(2)])],
      knots: [
        K(
          id: "k1", strand: "s1", kind: "progress", text: "雨桐完成R3写作修改", date: "2026-09-18",
          state: "done", who: ["宋雨桐"], evidence: [id(1)], quote: "R3 部分雨桐已经改完了",
          quoteItemID: id(1))
      ])
    let event = MemoryEventSource(
      eventID: "E6", origin: .spark, title: "TES论文RoboPrior大修返修",
      statusLine: "R2已完成，9月21日交回复信", pinned: false, updatedAt: now,
      itemIDs: (1...5).map(id), personIDs: [], handle: "E6",
      map: map)
    return MemoryProjection(events: [event], records: records, now: now)
  }

  func testClausesAndTheRelevantPart() {
    XCTAssertEqual(
      MatterTexts.clauses("先吃饭，然后改 RoboPrior。不过明天再说！"),
      ["先吃饭", "然后改 RoboPrior", "不过明天再说"])
    let terms = MatterTexts.Terms(latin: ["RoboPrior"], cjk: ["回复信"])
    XCTAssertEqual(
      MatterTexts.relevantPart("今天下雨，RoboPrior 改完了，回复信也写了，晚上吃饭", terms: terms),
      "RoboPrior 改完了，回复信也写了。")
    XCTAssertNil(MatterTexts.relevantPart("周末去看电影", terms: terms))
    XCTAssertEqual(MatterTexts.tidy("具体建议：，1. R1。。"), "具体建议：1. R1。")
  }

  func testEntriesKeepOnlyWhatIsAboutTheMatter() throws {
    let projection = projection()
    let digest = MemoryDigest(projection: projection, now: now, calendar: calendar, ownerNames: ["林知远"])
    let matter = try XCTUnwrap(digest.matter("E6"))
    let entries = projection.matterTexts(matter, ownerNames: ["林知远"])
    // Newest first; the shell command and the film are left out.
    XCTAssertEqual(entries.map(\.itemID), [id(2), id(1), id(3)].map { $0.uppercased() })
    // A dictation: the relevant clause only, punctuated.
    let dictation = entries[0]
    XCTAssertEqual(dictation.source.word, "口述")
    XCTAssertTrue(dictation.ownerSpoken)
    XCTAssertEqual(dictation.lines.map(\.words), ["顺便说一下 RoboPrior 回复信大概写了四成。"])
    // A chat: from one line before the first relevant line, three lines;
    // speakers kept (「我」 for the owner); the step's quote is marked.
    let chat = entries[1]
    XCTAssertEqual(chat.lines.map(\.speaker), ["周明澜", "我", "周明澜"])
    XCTAssertTrue(chat.more)
    XCTAssertEqual(chat.people, ["周明澜"])
    XCTAssertEqual(chat.quote, "R3 部分雨桐已经改完了")
    XCTAssertTrue(chat.isLong)
    // Mail: headers and the greeting go, the subject stays.
    let mail = entries[2]
    XCTAssertEqual(mail.subject, "Re: R1 补实验")
    XCTAssertEqual(mail.lines.first?.words, "R1 的回复信我这边改得差不多了。")
    XCTAssertFalse(mail.lines.contains { $0.words.contains("From") || $0.words.contains("Hi") })
  }

  func testAnItemAStepQuotesIsKeptAndNothingAboutItShowsTheStart() throws {
    let projection = projection()
    let digest = MemoryDigest(projection: projection, now: now, calendar: calendar)
    let matter = try XCTUnwrap(digest.matter("E6"))
    // `keep` (a revealed row) is shown even with nothing about the matter.
    let kept = projection.matterTexts(matter, keep: [id(5)])
    XCTAssertTrue(kept.contains { $0.itemID == id(5).uppercased() })
    XCTAssertEqual(kept.first { $0.itemID == id(5).uppercased() }?.lines.first?.words, "周末去看电影，买了爆米花")
  }

  func testAMatterWithNothingRelevantStillShowsItsItems() throws {
    let records = [record(9, at: date(9, 10), text: "周末去看电影")]
    let event = MemoryEventSource(
      eventID: "E9", origin: .spark, title: "租房续约", statusLine: "", pinned: false,
      updatedAt: now, itemIDs: [id(9)], personIDs: [])
    let projection = MemoryProjection(events: [event], records: records, now: now)
    let digest = MemoryDigest(projection: projection, now: now, calendar: calendar)
    let matter = try XCTUnwrap(digest.matter("E9"))
    XCTAssertEqual(projection.matterTexts(matter).map(\.lines.first?.words), ["周末去看电影"])
  }
}
