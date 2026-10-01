import BestASRDomain
import Foundation

/// Accepting a proposal from the Agent 收件箱 (AGENT-CONTRACT §2): it becomes a
/// user item like a paste, with the source `agent:<client name>`, so it never
/// counts as the owner's own words and goes through the normal organizing
/// (masked) path. Only the owner's 收下 calls this; the agent cannot.
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
