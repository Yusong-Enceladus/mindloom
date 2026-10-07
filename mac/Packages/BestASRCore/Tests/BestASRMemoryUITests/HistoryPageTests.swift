import BestASRMemory
import SwiftUI
import XCTest

@testable import BestASRMemoryUI

/// v12 find: 历史, the dictionary in Settings › 口述, and 最近记录 in the menu
/// bar (ALIGNMENT 查-1, 收1-7).
@MainActor
final class HistoryPageTests: XCTestCase {
  func testMenuBarOffersRecentRecordsExceptWhileRecording() {
    let idle = MenuBarExtraRow.rows(link: MemoryLinkState(), recording: nil)
    XCTAssertTrue(idle.contains(.submenu(id: "recent", title: "最近记录", symbol: "clock")))
    let recording = MenuBarExtraRow.rows(
      link: MemoryLinkState(),
      recording: MemoryCaptureIndicator(kind: .room, title: "正在记录会议", detail: "", paused: false))
    XCTAssertFalse(recording.contains { if case .submenu = $0 { true } else { false } })
  }

  /// v12 integration: 通用 (time zone, captions; restore 1A/1B) first, then
  /// 口述 (the dictionary; find), then the rest as before.
  func testSettingsPanesInOrder() {
    XCTAssertEqual(
      SettingsPane.allCases, [.general, .dictation, .entries, .devices, .apps, .about])
    XCTAssertEqual(SettingsPane.allCases.map(\.title), ["通用", "口述", "入口", "设备与隐私", "其他 App", "关于"])
  }

  /// The sidebar's 历史 and the toolbar's field are one page: typing from
  /// Home goes to it and Esc comes back; typing on 历史 stays on 历史.
  func testTypingAndClearingMoveBetweenThePages() {
    var navigation = MemoryNavigation()
    let navigator = MindloomNavigator(
      Binding(get: { navigation }, set: { navigation = $0 }))
    navigator.setSearch("报价")
    XCTAssertEqual(navigation.top, .search)
    navigator.clearSearch()
    XCTAssertEqual(navigation.top, .home)
    navigator.openRoot(.search)
    navigator.setSearch("报价")
    navigator.clearSearch()
    XCTAssertEqual(navigation.top, .search)
  }

  /// Review v12-B #15 (regression): 「还有 N 件」 opens every matter found on
  /// a page of its own instead of growing 事 in place over 人 and 原话; back
  /// returns to 历史 with the query as it was.
  func testMoreMattersOpenTheirOwnPage() {
    XCTAssertEqual(HistoryPage.mattersShown, 5)
    var navigation = MemoryNavigation()
    let navigator = MindloomNavigator(
      Binding(get: { navigation }, set: { navigation = $0 }))
    navigator.setSearch("论文")
    navigator.openMatterResults("论文")
    XCTAssertEqual(navigation.top, .matterResults("论文"))
    XCTAssertEqual(navigation.backTarget, .search)
    XCTAssertEqual(navigation.scrollKey, "matters:论文")
    navigator.openMatterResults("论文")
    XCTAssertEqual(navigation.path, [.matterResults("论文")], "not pushed twice")
    navigator.openMatter("E7")
    XCTAssertEqual(navigation.backTarget, .matterResults("论文"))
    navigator.back()
    navigator.back()
    XCTAssertEqual(navigation.top, .search)
    XCTAssertEqual(navigation.search, "论文")
  }

  func testAChipLeavesTheQueryWithOneClick() {
    let context = SearchContext(clock: SearchClock(now: Date(timeIntervalSince1970: 1_790_000_000)))
    let query = SearchQueryParser.parse("昨天 微信 报价", context: context)
    XCTAssertEqual(query.chips.count, 2)
    let remaining = query.chips.reduce("昨天 微信 报价") { SearchQueryParser.removing($1, from: $0) }
    XCTAssertEqual(remaining, "报价")
  }

  /// Review v12-B #6 (regression): a record with its recording offers, as
  /// d54's history detail did, 导出文字与字幕 (text and subtitles), 导出原音…
  /// and 删除…; a pasted item offers the text kinds and 删除….
  func testEveryRowCanBeExportedAndDeleted() {
    let recording = MemoryHistoryRow(
      itemID: "A1", time: Date(timeIntervalSince1970: 1_790_000_000), source: "口述",
      symbol: "mic", eventID: "E7", matterTitle: "中期考核", line: "周五交初稿",
      fullText: "周五交初稿", playable: true, duration: "12 秒")
    XCTAssertEqual(
      HistoryRowMenu.entries(for: recording),
      [
        .copy, .share, .addToDictionary, .divider,
        .exportText([.plainText, .markdown, .srt, .vtt]), .exportAudio, .divider,
        .openMatter("E7"), .divider, .delete,
      ])
    XCTAssertEqual(
      HistoryRowMenu.exportTextTitle([.plainText, .markdown, .srt, .vtt]), "导出文字与字幕")
    let pasted = MemoryHistoryRow(
      itemID: "B2", time: Date(timeIntervalSince1970: 1_790_000_000), source: "微信",
      symbol: "doc.on.clipboard", eventID: nil, matterTitle: nil, line: "好的", fullText: "好的")
    let entries = HistoryRowMenu.entries(for: pasted)
    XCTAssertEqual(
      entries,
      [
        .copy, .share, .addToDictionary, .divider, .exportText([.plainText, .markdown]), .divider,
        .delete,
      ])
    XCTAssertEqual(HistoryRowMenu.exportTextTitle([.plainText, .markdown]), "导出文字")
    XCTAssertEqual(
      MemoryHistoryExport.allCases.map(\.title), ["纯文本…", "Markdown…", "SRT 字幕…", "VTT 字幕…"])
    // The row's ⋯ menu draws these (an inert one still builds).
    final class Calls { var made: [String] = [] }
    let calls = Calls()
    let history = MemoryHistoryActions(
      exportText: { id, kind in calls.made.append("\(id):\(kind.rawValue)") },
      exportAudio: { calls.made.append("\($0):audio") },
      delete: { calls.made.append("\($0):delete") })
    history.exportText("A1", .srt)
    history.exportAudio("A1")
    history.delete("B2")
    XCTAssertEqual(calls.made, ["A1:srt", "A1:audio", "B2:delete"])
  }
}
