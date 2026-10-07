import BestASRDomain
import Foundation

/// An agent's note (v12 `add_note`; before v12 a proposal the owner accepted
/// from the Agent 收件箱): it becomes a user item like a paste, with the
/// source `agent:<client name>` (pages read 「<name>（其他 App）」), so it never
/// counts as the owner's own words and goes through the normal organizing
/// (masked) path. The App calls this only for a grant with 也可以改.
extension IntakeProcessor {
  public static let agentProposalExtractor = "agent-inbox-v1"

  public func prepareAgentProposal(_ proposal: AgentInboxProposal, id: SessionID = SessionID())
    -> IntakeOutcome
  {
    prepare(
      .text(proposal.itemText, extractor: Self.agentProposalExtractor), id: id,
      capturedAt: proposal.createdAt,
      source: ItemSourceApplication(
        bundleID: nil, name: AgentInboxProposal.sourceName(clientName: proposal.clientName)),
      origin: .unknown)
  }
}
