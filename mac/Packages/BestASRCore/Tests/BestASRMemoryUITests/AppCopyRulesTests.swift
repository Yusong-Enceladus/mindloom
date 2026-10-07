import BestASRDomain
import Foundation
import XCTest

@testable import BestASRMemoryUI

/// B7 设计 7 and 11 on the words this review touched (review v12-B #4, #16):
/// say what it does and what the owner can do, one name (Mindloom), and no
/// protocol names on screen. The App's Shortcuts strings are read from the
/// source, as `VocabularyGuardTests` reads every literal.
final class AppCopyRulesTests: XCTestCase {
  private static let reassurance = ["不会", "从不", "安全", "只读", "不记"]

  func testAgentRecordWordsArePlain() {
    XCTAssertEqual(AgentAuditWords.tool("tools/call"), "调用了 Mindloom 不支持的操作")
    XCTAssertEqual(AgentAuditWords.tool("delete_matter"), AgentAuditWords.unknownTool)
    XCTAssertEqual(AgentAuditWords.tool("search"), "搜索")
    XCTAssertEqual(AgentAuditWords.outcome(.invalid), "无法识别请求")
    for tool in ["today", "search", "get_matter", "tools/call", "x/y", "resources/list"] {
      XCTAssertFalse(AgentAuditWords.tool(tool).contains("/"), tool)
    }
    XCTAssertEqual(AgentAuditWords.recordsFooter, "每次访问都会记录时间、操作、结果和字数。")
    for banned in Self.reassurance + ["只"] {
      XCTAssertFalse(AgentAuditWords.recordsFooter.contains(banned), banned)
    }
    XCTAssertFalse(SettingsWindowText.timeZoneFooter.contains("不会"))
  }

  func testTheShortcutsSpeakAsMindloomAndSayWhatTheyDo() throws {
    let source = VocabularyGuardTests.repositoryRoot.appendingPathComponent(
      "App/MindloomIntents.swift")
    let text = try String(contentsOf: source, encoding: .utf8)
    var literals: [String] = []
    for line in text.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.hasPrefix("//") else { continue }
      literals += VocabularyGuardTests.literals(in: String(line)).filter {
        $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
      }
    }
    XCTAssertFalse(literals.isEmpty)
    for literal in literals {
      XCTAssertFalse(literal.contains("织机"), literal)
      for banned in Self.reassurance { XCTAssertFalse(literal.contains(banned), literal) }
    }
    XCTAssertTrue(literals.contains { $0.contains("Mindloom：今天到期") })
  }

  /// v12 F10 (review v12-B #4): Settings › 入口 says Shortcuts is off until
  /// switched on and why, and that a shared file is copied in.
  func testTheEntriesPageSaysWhatShareAndShortcutsDo() throws {
    let entries = MindloomSettingsState.defaultEntries
    let shortcuts = try XCTUnwrap(entries.first { $0.id == "shortcuts" })
    XCTAssertFalse(shortcuts.isOn)
    XCTAssertTrue(shortcuts.detail.contains("“Mindloom：今天到期”"))
    XCTAssertTrue(shortcuts.detail.contains("这台 Mac 上的其他程序也可以运行"))
    let share = try XCTUnwrap(entries.first { $0.id == "share" })
    XCTAssertTrue(share.detail.contains("文件会拷贝到 Mindloom"))
    for entry in [shortcuts, share] {
      for banned in Self.reassurance { XCTAssertFalse(entry.detail.contains(banned), entry.detail) }
    }
  }
}
