import AppKit
import BestASRAgentAccess
import BestASRDomain
import BestASRIntake
import BestASRMemory
import BestASRMemoryUI
import BestASRPersistence
import BestASRRemoteOrganizer
import Foundation
import MindloomAgentProtocol
import MindloomIdentity
import MindloomLibrary
import OSLog
import UniformTypeIdentifiers

/// Other Apps reading Mindloom (AGENT-CONTRACT; PRD §0.3 第 11 条 as amended
/// 2026-10-05; v12 phase B, B5 appendix C F1–F13). The App listens on a Unix
/// socket in the data root's private `agent` folder for its bundled
/// `mindloom-mcp` helper only (F8), and only while 允许其他 App 读 is on for this
/// library (F1) or the owner's command line or Chrome extension needs the
/// socket. Every call is checked against the owner's grant, masked by
/// default, counted against hourly limits and written to the record without
/// content. A grant with 也可以改 lets the App add a note, move an item or take
/// it out, rename a matter or mark a step: applied at once as the owner's own
/// correction, recorded, and undoable here.
extension DictationAppModel {
  /// Called once the durable library is open, with the root it was opened on.
  func configureAgentAccess(repository: GRDBDictationStore, dataRoot: URL) {
    guard agentAccess.service == nil, !BestASRProcessEnvironment.isXCTestHost else { return }
    let preapproval = Self.agentPreapproval(dataRoot: dataRoot)
    let presenter = AppAgentConsentPresenter(preapproval: preapproval)
    presenter.model = agentAccess
    // Each grant's secret: the login Keychain, this Mac only. A check build
    // pre-approving on a synthetic library keeps its secrets in that
    // library's own folder instead, so a check run leaves nothing in the
    // owner's Keychain.
    let secrets: any AgentGrantSecretStore =
      preapproval.flatMap { _ in try? FileAgentGrantSecretStore(dataRoot: dataRoot) }
      ?? KeychainAgentGrantSecretStore(dataRoot: dataRoot)
    // The App's search, as agents use it (用-8): 历史's engine over the
    // matters in reach, with the dictionary and the owner's names.
    let search = AgentRecordSearch(
      vocabulary: { [weak self] in
        await self?.agentSearchVocabulary() ?? AgentRecordSearch.Vocabulary()
      },
      // The same meaning model and combining rule as 历史 (v12 search).
      meaning: { [weak self] in await self?.meaningSearch.agentMeaning() })
    let service = AgentAccessService(
      memory: AppAgentMemory(app: self), records: repository,
      secrets: secrets, consent: presenter,
      changes: AppAgentChanges(app: self),
      search: search,
      // Read at each use: a change in 通用 › 时区 reaches agents at once
      // (review v12-B #14).
      zone: { SearchClock.productTimeZone })
    let helper = URL(fileURLWithPath: agentAccess.helperPath)
    let gate = AgentHelperGate.bundled(helper: helper)
    let agentsSwitch = agentAccess.agentsSwitch
    // The same socket serves the owner's `mindloom` command line and the
    // Chrome extension (V8 contract A3, A6), each only while its own entry
    // is on.
    let server = AgentSocketServer(
      dataRoot: dataRoot, service: service, gate: gate, owner: entryOwnerChannel(),
      agentsAllowed: { agentsSwitch.isOn })
    Logger(subsystem: MindloomIdentity.logSubsystem, category: "agent").notice(
      "agent socket admits \(gate.description, privacy: .public)")
    agentAccess.service = service
    agentAccess.search = search
    agentAccess.server = server
    agentAccess.store = repository
    agentAccess.dataRoot = dataRoot
    let enabled = LibrarySettingsFile(dataRoot: dataRoot).load().otherAppsCanRead
    agentAccess.otherAppsCanRead = enabled
    agentsSwitch.set(enabled)
    let panel = AgentRequestPanelController(model: agentAccess)
    agentRequestPanel = panel
    agentAccess.present = { [weak panel] in panel?.show() }
    agentAccess.notify =
      Self.agentNotifiesOwner(preapproval: preapproval) ? AgentNotifier(model: agentAccess) : nil
    updateAgentListening()
    // v12 search: the agents' meaning vectors follow (made, or dropped).
    meaningSearch.scheduleIndexing()
    Task { [weak self] in await self?.agentAccess.refresh() }
  }

  /// What the agents' search reads besides the matters: the dictionary's
  /// words in use (spoken ↔ written; they stay in the engine) and the
  /// owner's names, never a condition (as 历史 reads a query).
  func agentSearchVocabulary() async -> AgentRecordSearch.Vocabulary {
    let words = (try? await repository?.allDictionaryEntries()) ?? []
    return AgentRecordSearch.Vocabulary(
      lexicon: words.filter(\.enabled).map {
        SearchLexiconEntry(canonical: $0.canonicalForm, spoken: $0.spokenForms)
      },
      ownerNames: Set(Self.memoryOwnerNames))
  }

  /// The socket exists only while something needs it: 允许其他 App 读, or the
  /// owner's command line or Chrome extension (F1: no socket while all are
  /// off).
  func updateAgentListening() {
    guard let server = agentAccess.server else { return }
    let wanted =
      agentAccess.otherAppsCanRead || entries.isOn(.commandLine)
      || entries.isOn(.browserExtension)
    if wanted, !server.isRunning {
      do {
        try server.start()
        AgentAccessQuit.server = server
        agentAccess.status = nil
      } catch {
        // Everything else in Mindloom works without it.
        agentAccess.status = "其他 App 暂时无法连接 Mindloom；Mindloom 的其他功能照常可用"
      }
    } else if !wanted, server.isRunning {
      server.stop()
    }
  }

  /// 设置 › 其他 App › 允许其他 App 读 (stored in the library). Turning it
  /// off ends every agent's connection at once.
  func setOtherAppsCanRead(_ on: Bool) {
    guard let root = agentAccess.dataRoot, on != agentAccess.otherAppsCanRead else { return }
    let file = LibrarySettingsFile(dataRoot: root)
    var settings = file.load()
    settings.otherAppsCanRead = on
    do {
      try file.save(settings)
    } catch {
      intake.show("未能更改。请重试。")
      return
    }
    agentAccess.otherAppsCanRead = on
    agentAccess.agentsSwitch.set(on)
    // v12 search: the agents' meaning vectors are made, or dropped.
    meaningSearch.scheduleIndexing()
    if !on, let server = agentAccess.server, server.isRunning {
      // Connections already open end now; the owner's entries reconnect.
      server.stop()
    }
    updateAgentListening()
    agentAccess.requestRefresh()
  }

  /// A check build's pre-approval (`-MindloomAgentTestGrant <spec>`): only
  /// when this is not a Release build, the launch has `-MindloomNoArm`, and
  /// the library is synthetic; read from the launch arguments alone, never
  /// from saved preferences (review v12-B #13).
  static func agentPreapproval(
    dataRoot: URL, arguments: [String] = ProcessInfo.processInfo.arguments,
    flavor: MindloomBuildFlavor = MindloomBuild.flavor
  ) -> AgentPreapproval? {
    guard flavor != .release, LibraryLaunchSelection.noArmRequested(arguments: arguments),
      let spec = AgentPreapproval.launchSpec(arguments: arguments),
      LibraryLaunchSelection.isMarkedSynthetic(dataRoot)
    else { return nil }
    return AgentPreapproval.parse(spec)
  }

  /// Requests, changes and pauses reach the owner as notifications, except
  /// in a check run with a pre-approval (a synthetic library, no card): that
  /// run never asks for notification permission and shows no banner on the
  /// owner's screen (end-to-end run with Claude Code, 2026-10-06).
  static func agentNotifiesOwner(preapproval: AgentPreapproval?) -> Bool {
    preapproval == nil
  }

  // MARK: Changes (也可以改)

  /// Applies one allowed change as the owner's own would be applied; returns
  /// the new item's ID for a note.
  func applyAgentChange(_ change: AgentChange, clientName: String) async throws -> String? {
    switch change {
    case .addNote(let title, let text, let matterID):
      guard let processor = intakeProcessor, let repository else {
        throw AgentChangeError.notApplied
      }
      await intakeReady?.value
      // Like any other item; the source is the App (`agent:<name>`), never
      // the owner's own words.
      let proposal = AgentInboxProposal(
        clientKey: "", clientName: clientName, createdAt: Date(), title: title, text: text,
        matterHint: "")
      guard case .item(let draft) = processor.prepareAgentProposal(proposal) else {
        throw AgentChangeError.notApplied
      }
      do {
        try await repository.createUserItem(draft)
        processor.assetStore.commit(sessionID: draft.id)
      } catch {
        processor.assetStore.discard(sessionID: draft.id)
        throw AgentChangeError.notApplied
      }
      let itemID = draft.id.rawValue.uuidString
      if let matterID {
        await memoryCommit(.moveItem(itemID: itemID, segID: nil, from: "", to: matterID))
      }
      await refreshHistoryItems(preserveStatus: true, organizeEvents: true)
      return itemID
    case .correction(let correction):
      await memoryCommit(correction)
      await refreshEventMemory(organize: false)
      return nil
    }
  }

  /// 撤销 one change another App made: the inverse correction, or for a note
  /// the item it added goes. Any time after, not only within a toast.
  func undoAgentChange(_ changeID: UUID) {
    guard let store = agentAccess.store else { return }
    Task { [weak self] in
      guard let self,
        let change = (try? await store.agentChanges(clientKey: nil, limit: 5_000))?.first(where: {
          $0.changeID == changeID
        }), change.state == .applied
      else { return }
      do {
        try await self.reverse(change)
        _ = try await store.markAgentChangeUndone(changeID, at: Date())
        CaptureFeedback.shared.show(MemoryToast("已撤销", icon: .symbol("arrow.uturn.backward")))
      } catch {
        self.intake.show("没有撤销成；Mindloom 里还是改过的样子")
      }
      await self.agentAccess.refresh()
    }
  }

  private func reverse(_ change: AgentChangeRecord) async throws {
    let payload = Data(change.payload.utf8)
    if change.kind == .addNote {
      guard let id = change.itemID.flatMap(UUID.init(uuidString:)), let repository else {
        throw AgentChangeError.notApplied
      }
      try await repository.deleteSessionRecordsExplicitly(sessionID: SessionID(id))
      // Both lists Home's 刚收进来 and 历史 read from (v12 integration live
      // walk: the undone note stayed listed until the next full refresh).
      history.eventAvailableHistoryItems.removeAll { $0.sessionID == SessionID(id) }
      await refreshHistoryItems(preserveStatus: true)
      return
    }
    guard let correction = try? JSONDecoder().decode(MemoryCorrection.self, from: payload),
      let inverse = correction.inverse
    else { throw AgentChangeError.notApplied }
    await memoryCommit(inverse)
    await refreshEventMemory(organize: false)
  }

  /// 导出记录…: one App's calls and changes (no content in the calls; the
  /// changes' one-line summaries), as JSON.
  func exportAgentRecords(clientKey: String) {
    guard let store = agentAccess.store else { return }
    Task { [weak self] in
      let rows = (try? await store.agentAudit(clientKey: clientKey, limit: 20_000)) ?? []
      let changes = (try? await store.agentChanges(clientKey: clientKey, limit: 5_000)) ?? []
      guard let self else { return }
      let name = rows.first?.clientName ?? changes.first?.clientName ?? "App"
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.json]
      panel.nameFieldStringValue = "Mindloom-\(name)-记录.json"
      guard panel.runModal() == .OK, let destination = panel.url else { return }
      let formatter = ISO8601DateFormatter()
      let calls: [[String: Any]] = rows.map { row in
        [
          "time": formatter.string(from: row.at), "client": row.clientName,
          "tool": row.tool, "outcome": row.outcome.rawValue, "matter_ids": row.matterIDs,
          "bytes": row.byteCount, "grant_id": row.grantID?.uuidString.lowercased() ?? NSNull(),
        ]
      }
      let made: [[String: Any]] = changes.map { change in
        [
          "time": formatter.string(from: change.at), "kind": change.kind.rawValue,
          "summary": change.summary, "matter_ids": change.matterIDs,
          "item_id": change.itemID ?? NSNull(), "state": change.state.rawValue,
        ]
      }
      do {
        let data = try JSONSerialization.data(
          withJSONObject: ["client": name, "calls": calls, "changes": made],
          options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: destination, options: .atomic)
        intake.show("已导出 \(rows.count) 次读取和 \(changes.count) 次改动")
      } catch {
        intake.show("未能完成导出；记录仍保存在这台 Mac 上")
      }
    }
  }

  /// "claude mcp add …" for this App's helper; the library is named when it
  /// is not the default one (a demo or development root).
  var agentInstallCommand: String {
    var command = "claude mcp add mindloom"
    if let root = agentAccess.dataRoot,
      root.standardizedFileURL != AgentSocketLocation.defaultDataRoot()?.standardizedFileURL
    {
      command += " --env MINDLOOM_DATA_ROOT=\"\(root.path)\""
    }
    return command + " -- \"\(agentAccess.helperPath)\""
  }

  func copyAgentInstallCommand() {
    let board = NSPasteboard.general
    board.clearContents()
    board.setString(agentInstallCommand, forType: .string)
    // Mindloom's own copy: ⌘V here does not take it in as an item.
    board.setData(Data(), forType: IntakePasteboardMarks.ownOrigin)
    CaptureFeedback.shared.show(MemoryToast("已拷贝", icon: .symbol("doc.on.doc")))
  }
}
