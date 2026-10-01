import BestASRMemoryUI
import Foundation
import XCTest

/// The five copy rules, checked on every fixed string of the memory pages.
final class CopyRulesTests: XCTestCase {
  func testNoMechanismWordsNoSpeakerNumbersNoExclamationMarks() {
    for text in ZhijiCopy.allFixedText {
      for word in ZhijiCopy.forbidden {
        XCTAssertFalse(text.contains(word), "「\(text)」 contains \(word)")
      }
      XCTAssertFalse(text.contains("!") || text.contains("！"), "「\(text)」 exclaims")
    }
  }

  /// The App's own pages reachable from the memory pages (全部 and its
  /// detail, the capture pages, the setup cards above Home, Settings, the
  /// history export) follow rule 1 too. Onboarding keeps its one privacy
  /// statement ("在这台 Mac 上"), which names no forbidden word. Status
  /// messages composed in `DictationAppModel+*.swift` are not covered here.
  func testReachableAppPagesNameNoMechanism() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let files = [
      "App/ContentView.swift", "App/ContentView+Memory.swift", "App/ContentView+History.swift",
      "App/ContentView+HistoryDetail.swift", "App/ContentView+People.swift",
      "App/ContentView+Capture.swift", "App/ContentView+Home.swift",
      "App/ContentView+Dictionary.swift", "App/ContentView+Events.swift",
      "App/HistoryFilterControls.swift", "App/DictationSettingsView.swift",
      "App/LocalHistoryExporter.swift", "App/EventExportModel.swift",
      "App/MemoryScreenModel.swift", "App/DictationAppModel+Memory.swift",
      "App/DictationAppModel+RemoteOrganizer.swift", "App/DictationAppModel+PhoneLink.swift",
      "App/AgentSettingsSection.swift", "App/AgentConsentPanel.swift", "App/AgentAccessModel.swift",
      "App/DictationAppModel+AgentAccess.swift",
    ]
    let literal = try NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)
    var found: [String] = []
    for file in files {
      let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
      for (number, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        let code = String(line)
        guard !code.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
        let range = NSRange(code.startIndex..., in: code)
        for match in literal.matches(in: code, range: range) {
          let text = (code as NSString).substring(with: match.range)
          for word in ZhijiCopy.forbidden where text.contains(word) {
            found.append("\(file):\(number + 1) \(text)")
          }
        }
      }
    }
    XCTAssertEqual(found, [], found.joined(separator: "\n"))
  }

  func testStatusLengthCopyStaysShort() {
    // Rule 5: fixed prompts stay within one line of the page.
    for text in ZhijiCopy.allFixedText {
      XCTAssertLessThanOrEqual(text.count, 28, "「\(text)」 is long")
    }
  }
}
