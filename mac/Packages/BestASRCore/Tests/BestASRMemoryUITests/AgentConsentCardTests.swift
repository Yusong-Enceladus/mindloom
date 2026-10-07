import BestASRDomain
import XCTest

@testable import BestASRMemoryUI

/// v12 phase B, B5 appendix C F2, F4, F9: the consent card starts at the
/// smallest scope, makes 全部, each shared space and 也可以改 explicit ticks,
/// says exactly what 允许 does, and asks for Touch ID for the big grants.
@MainActor
final class AgentConsentCardTests: XCTestCase {
  private let named = AgentConsentInput(
    appName: "Claude Code", whoLine: "Anthropic PBC 签名的程序 · ~/.local/bin/claude",
    matterTitle: "TES 论文", groupName: "论文", spaces: [.init(id: "lab", title: "实验室")])

  func testTheDefaultIsTheSmallestScope() {
    let choice = AgentConsentChoice()
    XCTAssertFalse(choice.all)
    XCTAssertFalse(choice.group)
    XCTAssertEqual(choice.spaces, [])
    XCTAssertFalse(choice.canChange)
    XCTAssertEqual(choice.duration, .once)
    XCTAssertFalse(choice.showNumbers)
    XCTAssertFalse(choice.needsOwnerCheck)
    XCTAssertTrue(choice.readsSomething(namedMatter: true))
    // A first call that named no matter: nothing is read until something is ticked.
    XCTAssertFalse(choice.readsSomething(namedMatter: false))
    XCTAssertTrue(AgentConsentChoice(matterIDs: ["E1"]).readsSomething(namedMatter: false))
  }

  func testBigGrantsNeedTheOwner() {
    XCTAssertTrue(AgentConsentChoice(duration: .always).needsOwnerCheck)
    XCTAssertTrue(AgentConsentChoice(all: true).needsOwnerCheck)
    XCTAssertTrue(AgentConsentChoice(canChange: true).needsOwnerCheck)
    XCTAssertFalse(AgentConsentChoice(spaces: ["lab"], duration: .today).needsOwnerCheck)
  }

  func testTheSentenceSaysWhatAllowDoes() {
    XCTAssertEqual(ConsentDuration.once.title, "此次对话")
    XCTAssertEqual(
      AgentConsentChoice().sentence(named),
      "此次对话结束前，Claude Code 可以读取这件事的进展和原文。手机号和证件号将被隐藏。它读取的内容会发送到它使用的模型。")
    let wide = AgentConsentChoice(
      all: true, spaces: ["lab"], duration: .always, showNumbers: true, canChange: true)
    let sentence = wide.sentence(named)
    XCTAssertTrue(sentence.hasPrefix("直到你停止允许，Claude Code 可以读取你的所有事，以及选择的共享空间"), sentence)
    XCTAssertTrue(sentence.contains("添加内容、更改归属、重新命名和标记为完成"), sentence)
    XCTAssertTrue(sentence.contains("撤销"), sentence)
    XCTAssertTrue(sentence.contains("手机号和证件号完整提供"), sentence)
    for banned in ["不会", "从不", "安全", "只读，只这一次"] {
      XCTAssertFalse(sentence.contains(banned), banned)
      XCTAssertFalse(AgentConsentChoice().sentence(named).contains(banned), banned)
    }
  }

  /// Review v12-B #3 (regression): 全部 on a card whose request named a
  /// shared space's matter reads exactly the spaces ticked on the card; the
  /// named matter's space comes only with a grant of that one matter.
  func testAllNeverBringsTheNamedMattersSharedSpace() {
    let shared = "space:lab:E42"
    let all = AgentConsentChoice(all: true).terms(
      requestedMatterID: shared, groupOfRequestedMatter: nil)
    XCTAssertEqual(all.range, .all)
    XCTAssertEqual(all.spaces, [AgentSpaceID.personal])
    let allAndLab = AgentConsentChoice(all: true, spaces: ["lab"]).terms(
      requestedMatterID: shared, groupOfRequestedMatter: nil)
    XCTAssertEqual(allAndLab.spaces, [AgentSpaceID.personal, "lab"])
    let grouped = AgentConsentChoice(group: true).terms(
      requestedMatterID: shared, groupOfRequestedMatter: "g1")
    XCTAssertEqual(grouped.range, .groups(["g1"]))
    XCTAssertEqual(grouped.spaces, [AgentSpaceID.personal])
    // Only this matter: its space comes with it, and nothing else in it.
    let one = AgentConsentChoice().terms(requestedMatterID: shared, groupOfRequestedMatter: nil)
    XCTAssertEqual(one.range, .matters([shared]))
    XCTAssertEqual(one.spaces, [AgentSpaceID.personal, "lab"])
    // The owner's own matter brings no space.
    let own = AgentConsentChoice(duration: .today, canChange: true).terms(
      requestedMatterID: "E7", groupOfRequestedMatter: nil)
    XCTAssertEqual(own.range, .matters(["E7"]))
    XCTAssertEqual(own.spaces, [AgentSpaceID.personal])
    XCTAssertEqual(own.duration, .today)
    XCTAssertTrue(own.canChange)
    // Ticked from the list (no matter named).
    let ticked = AgentConsentChoice(matterIDs: ["E1", "space:team:E9"]).terms(
      requestedMatterID: nil, groupOfRequestedMatter: nil)
    XCTAssertEqual(ticked.range, .matters(["E1", "space:team:E9"]))
    XCTAssertEqual(ticked.spaces, [AgentSpaceID.personal, "team"])
    // The sentence still says only what is ticked.
    XCTAssertFalse(AgentConsentChoice(all: true).sentence(named).contains("共享空间"))
  }
}
