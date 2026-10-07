import Foundation
import MindloomTaglines
import XCTest

@testable import BestASRMemoryUI

/// The taglines on the Mac (docs/TAGLINES.md): the welcome window's first
/// screen shows the current line where the fixed slogan was, the sidebar
/// shows the same line quietly, and the copy rules point at the rotation.
final class WelcomeTaglineTests: XCTestCase {
  func testTheFirstScreenShowsTheCurrentTagline() throws {
    let source = try Self.source(
      "Packages/BestASRCore/Sources/BestASRMemoryUI/Capture/WelcomeView.swift")
    XCTAssertTrue(source.contains("WelcomeTagline(line: line)"))
    XCTAssertTrue(source.contains("public var tagline: MindloomTagline?"))
    // The two earlier fixed slogans are gone.
    XCTAssertFalse(source.contains("所闻所言"))
    XCTAssertFalse(source.contains("收集一切，自动整理。"))
    let sidebar = try Self.source(
      "Packages/BestASRCore/Sources/BestASRMemoryUI/Shell/MindloomSidebar.swift")
    XCTAssertTrue(sidebar.contains("if let line = state.tagline { SidebarTagline(line: line) }"))
  }

  func testANewInstallSeesTheFirstLine() {
    XCTAssertEqual(MindloomTaglineBoard.first(interfaceLanguage: "zh-Hans")?.text, "编织你的史诗。")
    XCTAssertEqual(MindloomTaglineBoard.first(interfaceLanguage: "en")?.text, "Weave your epic.")
    // A still image without a line shows that one.
    XCTAssertNil(WelcomeInput().tagline)
  }

  /// The board records the showing in the App's preferences and counts
  /// six-hour periods (from 00:00, 06:00, 12:00 and 18:00) in the product
  /// time zone.
  func testTheBoardCountsPeriodsInTheProductTimeZone() throws {
    let name = "mindloom.taglines.board-tests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let singapore = try XCTUnwrap(TimeZone(identifier: "Asia/Singapore"))
    let board = MindloomTaglineBoard(defaults: defaults)
    // 2026-10-06 05:30 and 06:30 in Singapore (the afternoon before in Los
    // Angeles, inside one period there).
    let early = Date(timeIntervalSince1970: 1_791_216_000 + 5.5 * 3600)
    let morning = early.addingTimeInterval(3600)
    let first = board.line(now: early, zone: singapore, interfaceLanguage: "zh-Hans")
    XCTAssertEqual(first?.text, "编织你的史诗。")
    XCTAssertEqual(
      board.line(now: early.addingTimeInterval(60), zone: singapore, interfaceLanguage: "zh-Hans"),
      first)
    let next = board.line(now: morning, zone: singapore, interfaceLanguage: "zh-Hans")
    XCTAssertNotNil(next)
    XCTAssertNotEqual(next, first)
    XCTAssertEqual(next?.language, .zh)
    let stored = try XCTUnwrap(defaults.string(forKey: TaglineStore.key))
    XCTAssertTrue(stored.contains(#""first_period":82928"#), stored)
    XCTAssertTrue(stored.contains(#""last_shown_period":82929"#), stored)
  }

  func testQuotationsShowTheirSourceInEachLanguagesStyle() throws {
    let chinese = try XCTUnwrap(MindloomTaglineBoard.line(id: "zh-01"))
    XCTAssertEqual(TaglineAttribution.text(chinese), "——韩愈《进学解》")
    let english = try XCTUnwrap(MindloomTaglineBoard.line(id: "en-02"))
    XCTAssertEqual(TaglineAttribution.text(english), "— William Shakespeare, The Tempest")
    let plain = try XCTUnwrap(MindloomTaglineBoard.line(id: "zh-16"))
    XCTAssertNil(TaglineAttribution.text(plain))
    XCTAssertEqual(TaglineAttribution.accessibilityLabel(chinese), "记事者必提其要，纂言者必钩其玄。 韩愈《进学解》")
  }

  /// docs/UI-COPY.md §4 points at docs/TAGLINES.md, and that lists every
  /// line of both sets as shipped.
  func testTheRulesRecordTheTaglines() throws {
    let rules = try Self.source("docs/UI-COPY.md")
    XCTAssertTrue(rules.contains("docs/TAGLINES.md"))
    XCTAssertFalse(rules.contains("所闻所言"))
    let taglines = try Self.source("docs/TAGLINES.md")
    for line in TaglineCatalog.bundled.zh + TaglineCatalog.bundled.en {
      XCTAssertTrue(taglines.contains("| \(line.id) |"), "\(line.id) is not listed")
      XCTAssertTrue(taglines.contains(line.text), "\(line.id) differs from the data file")
    }
  }

  static func source(_ path: String) throws -> String {
    try String(
      contentsOf: VocabularyGuardTests.repositoryRoot.appendingPathComponent(path), encoding: .utf8)
  }
}
