import AppKit
import BestASRAgentAccess
import BestASRDomain
import BestASRIntake
import BestASRPersistence
import Foundation
import UniformTypeIdentifiers

/// Agents reading 织机 (AGENT-CONTRACT; PRD §0.3 第 11 条). The App listens on
/// a Unix socket in the data root's private `agent` folder for the bundled
/// `mindloom-mcp` helper; every call is checked against the owner's grant,
/// masked by default, and written to the audit list without content. Nothing
/// an agent proposes is filed until the owner accepts it here.
extension DictationAppModel {
  /// Called once the durable library is open, with the root it was opened on.
  func configureAgentAccess(repository: GRDBDictationStore, dataRoot: URL) {
    guard agentAccess.service == nil, !BestASRProcessEnvironment.isXCTestHost else { return }
    let presenter = AppAgentConsentPresenter()
    presenter.model = agentAccess
    let service = AgentAccessService(
      memory: AppAgentMemory(app: self), records: repository,
      // Each grant's secret: the login Keychain, this Mac only.
      secrets: KeychainAgentGrantSecretStore(dataRoot: dataRoot), consent: presenter)
    // The same socket serves the owner's `mindloom` command line (V8
    // contract A3), answered only while 设置 → 入口 has it on.
    let server = AgentSocketServer(
      dataRoot: dataRoot, service: service, owner: entryOwnerChannel())
    agentAccess.service = service
    agentAccess.server = server
    agentAccess.store = repository
    let panel = AgentRequestPanelController(model: agentAccess)
    agentRequestPanel = panel
    agentAccess.present = { [weak panel] in panel?.show() }
    agentAccess.notify = AgentNotifier(model: agentAccess)
    do {
      try server.start()
      AgentAccessQuit.server = server
      agentAccess.status = nil
    } catch {
      // Everything else in 织机 works without it.
      agentAccess.status = "Agent 连接暂时不可用；织机的其他功能不受影响"
    }
    Task { [weak self] in await self?.agentAccess.refresh() }
  }

  /// 收下: the proposal becomes an item from the agent (never the owner's own
  /// words) and goes through the normal organizing path.
  func acceptAgentProposal(_ proposal: AgentInboxProposal) {
    guard let processor = intakeProcessor, let repository else {
      intake.show("资料库尚未打开；这条建议还在收件箱里")
      return
    }
    let ready = intakeReady
    Task { [weak self] in
      await ready?.value
      guard case .item(let draft) = processor.prepareAgentProposal(proposal) else {
        self?.intake.show("这条建议没有能收进来的文字")
        return
      }
      do {
        try await repository.createUserItem(draft)
        processor.assetStore.commit(sessionID: draft.id)
        try await repository.resolveAgentProposal(
          proposal.proposalID, state: .accepted, itemID: draft.id, at: Date())
      } catch {
        processor.assetStore.discard(sessionID: draft.id)
        self?.intake.show("没有收下；这条建议还在收件箱里")
        return
      }
      guard let self else { return }
      intake.show("已收下，来源标为 \(draft.source?.name ?? "Agent")", item: draft.id)
      await refreshHistoryItems(preserveStatus: true, organizeEvents: true)
      await agentAccess.refresh()
    }
  }

  /// 不要: the proposal leaves the inbox and its text is dropped.
  func rejectAgentProposal(_ proposal: AgentInboxProposal) {
    guard let repository else { return }
    Task { [weak self] in
      try? await repository.resolveAgentProposal(
        proposal.proposalID, state: .rejected, itemID: nil, at: Date())
      await self?.agentAccess.refresh()
    }
  }

  /// 导出: the audit rows shown (no content in them), as JSON.
  func exportAgentAudit() {
    guard let store = agentAccess.store else { return }
    let client = agentAccess.auditClient
    Task { [weak self] in
      let rows = (try? await store.agentAudit(clientKey: client, limit: 20_000)) ?? []
      guard let self else { return }
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.json]
      panel.nameFieldStringValue = "织机-谁读过什么.json"
      guard panel.runModal() == .OK, let destination = panel.url else { return }
      let formatter = ISO8601DateFormatter()
      let objects: [[String: Any]] = rows.map { row in
        [
          "time": formatter.string(from: row.at), "client": row.clientName,
          "client_key": row.clientKey, "tool": row.tool, "outcome": row.outcome.rawValue,
          "matter_ids": row.matterIDs, "bytes": row.byteCount,
          "grant_id": row.grantID?.uuidString.lowercased() ?? NSNull(),
        ]
      }
      do {
        let data = try JSONSerialization.data(
          withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: destination, options: .atomic)
        intake.show("已导出 \(rows.count) 条记录")
      } catch {
        intake.show("导出失败；记录仍保留在本机")
      }
    }
  }

  /// "claude mcp add …" for this App's helper, for the Settings page.
  func copyAgentInstallCommand() {
    let command = "claude mcp add mindloom -- \"\(agentAccess.helperPath)\""
    let board = NSPasteboard.general
    board.clearContents()
    board.setString(command, forType: .string)
    // 织机's own copy: ⌘V here does not take it in as an item.
    board.setData(Data(), forType: IntakePasteboardMarks.ownOrigin)
    intake.show("已复制 Claude Code 的连接命令")
  }
}
