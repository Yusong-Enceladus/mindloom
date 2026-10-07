import Foundation
import MindloomDesign
import XCTest

@testable import MindloomPhone

/// The status line, the text rules and the strings the phone shows (PHONE-SPEC §6).
final class PhoneRulesTests: XCTestCase {
  private let nine41: Date = {
    var c = DateComponents()
    c.year = 2026
    c.month = 10
    c.day = 2
    c.hour = 9
    c.minute = 41
    return Calendar.current.date(from: c)!
  }()

  func testStatusLineFollowsTheRuleOrder() {
    let paired = HomeStatus.Pairing.paired(name: "小林的 MacBook Pro")
    func status(
      _ pairing: HomeStatus.Pairing, unreachable: Bool = false, pending: Int = 0, items: Int = 0,
      last: Date? = nil
    ) -> HomeStatus {
      HomeStatus.derive(
        pairing: pairing, unreachable: unreachable, pending: pending, itemCount: items,
        lastSentAt: last)
    }
    XCTAssertEqual(status(paired, items: 9, last: nine41).text, "已发送 · 9:41")
    XCTAssertEqual(status(paired).text, "已连接 小林的 MacBook Pro")
    XCTAssertEqual(status(paired, pending: 2, items: 9).text, "2 条仍在 iPhone 上 · 正在发送")
    let offline = status(paired, unreachable: true, pending: 3, items: 10)
    XCTAssertEqual(offline.text, "未连接 Mac · 3 条仍在 iPhone 上")
    XCTAssertTrue(offline.leadIsAlert)
    XCTAssertEqual(offline.lead, "未连接 Mac", "only the lead is in the alert colour")
    XCTAssertEqual(status(paired, unreachable: true).text, "未连接 Mac", "no tail without items")
    let never = status(.never, pending: 2, items: 2)
    XCTAssertEqual(never.text, "尚未连接 Mac · 2 条仍在 iPhone 上")
    XCTAssertEqual(never.action, "连接")
    let gone = status(.disconnected, pending: 2, items: 9)
    XCTAssertEqual(gone.text, "已与 Mac 断开 · 2 条仍在 iPhone 上")
    XCTAssertEqual(gone.action, "重新连接")
    XCTAssertEqual(status(.disconnected).text, "已与 Mac 断开")
  }

  func testDayHeadersAndTimes() {
    let calendar = Calendar.current
    XCTAssertEqual(PhoneFormat.dayHeader(nine41, now: nine41), "今天")
    let yesterday = calendar.date(byAdding: .day, value: -1, to: nine41)!
    XCTAssertEqual(PhoneFormat.dayHeader(yesterday, now: nine41), "昨天")
    let older = calendar.date(byAdding: .day, value: -3, to: nine41)!
    XCTAssertEqual(PhoneFormat.dayHeader(older, now: nine41), "9月29日 星期二")
    XCTAssertEqual(PhoneFormat.time(calendar.date(byAdding: .hour, value: 12, to: nine41)!), "21:41")
    XCTAssertEqual(PhoneFormat.dayAndTime(nine41, now: nine41), "今天 9:41")
    XCTAssertEqual(PhoneFormat.monthDay(nine41), "10月2日")
  }

  func testCommitAppendsAFullStopOnlyWhenNeeded() {
    XCTAssertEqual(PhoneText.finalized("组会改到周三下午"), "组会改到周三下午。")
    XCTAssertEqual(PhoneText.finalized(" 真的吗？ "), "真的吗？")
    XCTAssertEqual(PhoneText.finalized("OK."), "OK.")
    XCTAssertEqual(PhoneText.finalized("   "), "", "nothing heard: nothing is saved")
  }

  func testWordsStayWhole() {
    let joined = PhoneText.keepingWordsWhole("我带上季度预算表。")
    XCTAssertEqual(PhoneText.plain(joined), "我带上季度预算表。")
    // inside a word the characters are joined; between words they are not
    XCTAssertTrue(joined.contains("预\u{2060}算"), joined)
    XCTAssertFalse(joined.contains("表\u{2060}。"), joined)
    XCTAssertEqual(PhoneText.keepingWordsWhole("FlowFlow"), "FlowFlow")
  }

  func testClampAfterFortyTwoCharacters() {
    XCTAssertFalse(PhoneText.needsClamp(String(repeating: "字", count: 42)))
    XCTAssertTrue(PhoneText.needsClamp(String(repeating: "字", count: 43)))
  }

  /// The phone's own strings: no banned word, and never "Spark" or "DGX" (PHONE-SPEC §0.1).
  func testVocabulary() {
    let info = Bundle.main.infoDictionary ?? [:]
    var strings = [
      "NSMicrophoneUsageDescription", "NSCameraUsageDescription",
      "NSSpeechRecognitionUsageDescription", "NSLocalNetworkUsageDescription",
    ].compactMap { info[$0] as? String }
    XCTAssertEqual(strings.count, 4)
    XCTAssertEqual(info["NSCameraUsageDescription"] as? String, "Mindloom 使用相机扫描 Mac 上显示的二维码。")
    strings += [
      HomeStatus.sent(nine41).text, HomeStatus.sending(2).text, HomeStatus.unreachable(3).text,
      HomeStatus.neverPaired(2).text, HomeStatus.disconnected(2).text,
    ]
    for string in strings {
      XCTAssertEqual(MLVocabulary.check(string).filter(\.isBanned), [], string)
      XCTAssertFalse(string.contains("Spark") || string.contains("DGX"), string)
      XCTAssertFalse(string.contains("织机"), "织机 only under the wordmark: \(string)")
    }
  }
}
