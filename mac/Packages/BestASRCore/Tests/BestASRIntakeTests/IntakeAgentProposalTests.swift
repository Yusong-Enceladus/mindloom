import BestASRDomain
import BestASRIntake
import Foundation
import XCTest

/// Accepting an Agent 收件箱 proposal (AGENT-CONTRACT §2): a text item whose
/// source is the agent, never the owner; its time is when the agent wrote it.
final class IntakeAgentProposalTests: XCTestCase {
  func testAcceptedProposalBecomesAnItemFromTheAgent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let processor = IntakeProcessor(
      assetStore: IntakeAssetStore(assetRoot: root.appendingPathComponent("assets")),
      pathPolicy: .none)
    let proposal = AgentInboxProposal(
      clientKey: "k", clientName: "Claude Code", createdAt: Date(timeIntervalSince1970: 5_000),
      title: "交接说明", text: "第三组周五前跑完。\n表在共享盘。", matterHint: "E-TWIN7")
    guard case .item(let draft) = processor.prepareAgentProposal(proposal) else {
      return XCTFail("a text item")
    }
    XCTAssertEqual(draft.kind, .text)
    XCTAssertEqual(draft.source?.name, "agent:Claude Code")
    XCTAssertNil(draft.source?.bundleID)
    XCTAssertEqual(draft.sourceOrigin, .unknown)
    XCTAssertEqual(draft.capturedAt, proposal.createdAt)
    XCTAssertEqual(draft.extractor, IntakeProcessor.agentProposalExtractor)
    XCTAssertEqual(draft.automaticTitle, "交接说明")
    XCTAssertTrue(draft.text.contains("表在共享盘。"))
    XCTAssertTrue(draft.attachments.isEmpty)
    // The hint only helps the owner; it is not part of the item.
    XCTAssertFalse(draft.text.contains("E-TWIN7"))
    let untitled = AgentInboxProposal(
      clientKey: "k", clientName: "  ", createdAt: Date(), title: "", text: "只有正文",
      matterHint: "")
    guard case .item(let plain) = processor.prepareAgentProposal(untitled) else {
      return XCTFail("a text item")
    }
    XCTAssertEqual(plain.source?.name, "agent:未知")
    XCTAssertEqual(plain.text, "只有正文")
  }
}
