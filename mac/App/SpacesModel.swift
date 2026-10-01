import AppKit
import BestASRAgentAccess
import BestASRDomain
import BestASRIntake
import BestASRMemory
import BestASRMemoryUI
import BestASRPersistence
import BestASRRemoteOrganizer
import Combine
import Foundation
import MindloomSpaces

/// Shared spaces in the App (SPACES-CONTRACT): runs the member engine over
/// the organizing link's own forward, keeps each space's read model, and
/// maps it onto the memory pages (我的 / a space / 全部) and the space sheets.
/// The engine, the crypto and every rule live in the packages; this only
/// schedules and adapts.
@MainActor
final class SpacesModel: ObservableObject {
  @Published private(set) var screen = SpacesScreenState()
  @Published var sheet: SpaceSheet? {
    didSet {
      guard sheet == nil else { return }
      screen.invite = nil
      screen.shareDraft = nil
      screen.joinPreview = nil
      screen.joinError = nil
    }
  }
  /// The read model of the scope when it is a space or 全部 (nil in 我的).
  @Published private(set) var scopeBase: MemoryScreenState?
  /// 全部's event ids that came from a space (read-only there).
  private(set) var spaceEventsInAll: [String: String] = [:]
  /// Matter id → its rope (filled by the matter map when it is present).
  var ropeOf: ((String) -> (id: String, title: String, matters: Int)?)?

  private var views: [String: SpaceView] = [:]
  private weak var app: DictationAppModel?
  private weak var memory: MemoryScreenModel?
  private var engine: SpaceEngine?
  private var loop: Task<Void, Never>?
  private var rebuildTask: Task<Void, Never>?
  private var observers: Set<AnyCancellable> = []
  private var shareEntries: [String: [String: SpaceShareContent.Entry]] = [:]
  private var lastOrganized: [String: Date] = [:]
  private var lastRewrap: [String: Date] = [:]
  private var refused = false
  /// Originals opened from a space, decrypted for the viewer app (V7-S11).
  private let originals = SpaceOriginalsFolder()

  static let tickInterval: Duration = .seconds(12)
  static let organizeInterval: TimeInterval = 45
  static let rewrapInterval: TimeInterval = 600

  // MARK: - Lifecycle

  func attach(to app: DictationAppModel, memory: MemoryScreenModel) {
    guard self.app == nil else { return }
    self.app = app
    self.memory = memory
    // Agents see the spaces' matters, labelled (AGENT-CONTRACT × SPACES-CONTRACT).
    app.agentAccess.spaces = self
    // 整根绳 offers the rope my matter is on (the matter map's ropes).
    ropeOf = { [weak memory] eventID in
      guard let ropes = memory?.projection?.ropes,
        let rope = ropes.first(where: { $0.children.contains(eventID) })
      else { return nil }
      return (rope.id, rope.title, SpaceRopeRule.matters(of: rope.id, in: ropes).count)
    }
    // Nothing an earlier launch decrypted outlives it; nor this one.
    originals.purgeAll()
    NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
      .sink { [originals] _ in originals.purgeAll() }
      .store(in: &observers)
    memory.$base
      .dropFirst()
      .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
      .sink { [weak self] _ in self?.rebuild() }
      .store(in: &observers)
    loop = Task { [weak self] in
      while !Task.isCancelled {
        await self?.tick()
        try? await Task.sleep(for: Self.tickInterval)
      }
    }
  }

  /// The engine of this library, made once the link controller exists. During
  /// development only a synthetic data root may share (the same provenance
  /// rule as the organizing link).
  private func ensureEngine() -> SpaceEngine? {
    if let engine { return engine }
    guard !refused, let controller = app?.remoteOrganizer else { return nil }
    guard controller.provenance == .allowed else {
      refused = true
      screen.status = "开发阶段只在合成演示资料库里使用共享空间；你的真实资料库不会发出任何内容"
      return nil
    }
    guard let dataRoot = try? DictationAppModel.applicationDataRoot() else { return nil }
    let stores = SpaceStores.keychain(
      dataRoot: dataRoot, sealKeys: KeychainPhoneSealKeyStore(dataRoot: dataRoot))
    guard let device = try? stores.loadOrCreateDevice() else {
      screen.status = "钥匙串暂不可用；共享空间没有打开"
      return nil
    }
    // The space routes ride the organizing link's own forward: the port is
    // handed out only while our own ssh child still holds it.
    let transport = LoopbackSpaceTransport {
      try await MainActor.run {
        guard let controller = RemoteOrganizerQuitLock.controller else {
          throw SpaceClientError.transport
        }
        return try controller.spaceEndpoint()
      }
    }
    let engine = SpaceEngine(
      client: SpaceClient(transport: transport, device: device), states: stores.states,
      keys: stores.keys, textMasker: SpaceTitleMasker())
    self.engine = engine
    screen.myFingerprint = device.fingerprint
    return engine
  }

  private var linkReady: Bool {
    (try? RemoteOrganizerQuitLock.controller?.spaceEndpoint()) != nil
  }

  // MARK: - Sync loop

  func tick() async {
    guard let engine = ensureEngine() else { return }
    let ready = linkReady
    screen.linkReady = ready
    if ready {
      await reconcileDeletions(engine)
      for state in (try? await engine.allStates()) ?? [] {
        await sync(state, engine: engine)
      }
      await deleteForkCopies(engine)
      await followRules(engine)
    }
    await publish()
  }

  private func sync(_ state: SpaceLocalState, engine: SpaceEngine) async {
    let id = state.spaceID
    do {
      switch state.membership {
      case .pending:
        let after = try await engine.refreshJoin(id)
        if after.membership == .active { screen.status = "已加入「\(after.name)」" }
      case .rejected:
        break
      case .active:
        // Items whose local source the user deleted leave the space first.
        _ = try? await engine.flushDeletes(id)
        var synced = try await engine.sync(id)
        if synced.rotationPending, synced.can("rotate") {
          try await engine.rotate(id)
          synced = try await engine.sync(id)
        }
        if synced.can("approve_joins") {
          screen.joinRequests[id] = try await engine.joinRequests(id)
        }
        screen.proposals[id] = try? await engine.openProposals(id)
        screen.takedowns[id] = try? await engine.openTakedowns(id)
        if synced.can("rewrap"),
          Date().timeIntervalSince(lastRewrap[id] ?? .distantPast) > Self.rewrapInterval
        {
          lastRewrap[id] = Date()
          _ = try? await engine.rewrapStale(id)
        }
        if Date().timeIntervalSince(lastOrganized[id] ?? .distantPast) > Self.organizeInterval {
          lastOrganized[id] = Date()
          // The lease lets the space organizer run while this Mac is here.
          _ = try? await engine.organize(
            id,
            builder: SpaceOrganizerPayloads(
              imageRedactor: VisionSendCopyRedactor()))
        }
      }
    } catch SpaceClientError.accessEnded {
      if (try? await engine.state(id)) != nil {
        // The Spark said so without a member's signed record: nothing deleted.
        screen.status = "整理设备说你已不在「\(state.name)」里，但没有成员签名的记录；内容先留在这台 Mac 上"
      } else {
        screen.status = "你已不在「\(state.name)」里；这台 Mac 上它的内容和钥匙已删除"
        if screen.scope == .space(id) { setScope(.mine) }
      }
    } catch {
      // A transient failure: the next tick tries again.
    }
  }

  /// Copies kept under a space's fork policy go when access to it ends or
  /// the item is removed for privacy. The engine keeps the list until the
  /// copies are really gone (V7-S15).
  private func deleteForkCopies(_ engine: SpaceEngine) async {
    let copies = await engine.forkCopiesToDelete()
    guard let repository = app?.repository, !copies.isEmpty else { return }
    let ids = copies.compactMap { UUID(uuidString: $0) }.map(SessionID.init)
    do {
      try await repository.deleteSessionRecordsExplicitly(sessionIDs: ids)
    } catch {
      return  // tried again on the next tick
    }
    await engine.forkCopiesDeleted(copies)
    await app?.refreshHistoryItems(preserveStatus: true)
  }

  /// Deleting an item of mine deletes it everywhere I control (SPACES-CONTRACT
  /// §4): what this Mac shared from a local item that is no longer in the
  /// library is queued to leave every space (V7-S12). Only a library that
  /// answers is trusted; an error changes nothing.
  private func reconcileDeletions(_ engine: SpaceEngine) async {
    guard let repository = app?.repository,
      let sources = try? await engine.sharedSources(), !sources.isEmpty
    else { return }
    let ids = sources.compactMap { UUID(uuidString: $0) }.map(SessionID.init)
    guard let existing = try? await repository.existingSessionIDs(among: ids) else { return }
    let present = Set(existing.map { $0.rawValue.uuidString.lowercased() })
    let gone = sources.filter { !present.contains($0) && UUID(uuidString: $0) != nil }
    guard !gone.isEmpty else { return }
    if let queued = try? await engine.localItemsDeleted(Set(gone)), queued > 0 {
      screen.status = "你删掉的 \(queued) 条也会从共享空间里撤回（过了撤回期限的会变成下架申请）"
    }
  }

  /// "以后新归进来的也共享": a matter shared with 自动 sends its new items
  /// (those the review list would tick); 每次先问我 only counts them. A rope
  /// rule (整根绳) does the same for every matter on the rope and on the ropes
  /// inside it, now and later; it sends by itself only while the owner has
  /// confirmed the rope (`SpaceRopeRule.sendsByItself`), otherwise it asks.
  private func followRules(_ engine: SpaceEngine) async {
    var waiting: [String] = []
    for state in (try? await engine.allStates()) ?? [] where state.membership == .active {
      var followed = Set<String>()
      for package in state.packages.values
      where package.active && package.owner == state.memberID && package.auto != .off {
        guard let matter = package.matterID,
          let entries = await entries(forMatter: matter)?.values
        else { continue }
        followed.insert(matter)
        let fresh = entries.filter { state.items[$0.candidate.id] == nil }
        guard !fresh.isEmpty else { continue }
        if package.auto == .auto {
          // A rule never sends a part of a recording: the user picks those.
          let send = fresh.filter {
            $0.candidate.tickedByDefault && $0.candidate.recordingID == nil
          }
          if !send.isEmpty {
            _ = try? await engine.share(
              state.spaceID, items: send.map(\.item),
              package: SpacePackageRequest(
                packageID: package.packageID, auto: .auto, matterID: matter,
                title: package.title))
          }
          if send.count < fresh.count { waiting.append(state.name) }
        } else {
          waiting.append(state.name)
        }
      }
      let ropes = memory?.projection?.ropes ?? []
      for rule in state.rules.values where rule.active && rule.kind == "rope" {
        guard let ropeID = rule.targetID, let rope = ropes.first(where: { $0.id == ropeID })
        else { continue }
        let byItself = rule.auto == .auto && SpaceRopeRule.sendsByItself(rope)
        for matter in SpaceRopeRule.matters(of: ropeID, in: ropes)
        where followed.insert(matter).inserted {
          guard let entries = await entries(forMatter: matter)?.values else { continue }
          let fresh = entries.filter { state.items[$0.candidate.id] == nil }
          guard !fresh.isEmpty else { continue }
          guard byItself else {
            waiting.append(state.name)
            continue
          }
          // Never a part of a recording, a private dictation or an item with numbers.
          let send = fresh.filter {
            $0.candidate.tickedByDefault && $0.candidate.recordingID == nil
          }
          if !send.isEmpty {
            let existing = state.packages.values.first {
              $0.active && $0.owner == state.memberID && $0.matterID == matter
            }
            _ = try? await engine.share(
              state.spaceID, items: send.map(\.item),
              package: SpacePackageRequest(
                packageID: existing?.packageID ?? SpaceID.new(), auto: existing?.auto ?? .off,
                matterID: matter, title: memory?.projection?.event(id: matter)?.title))
          }
          if send.count < fresh.count { waiting.append(state.name) }
        }
      }
    }
    if !waiting.isEmpty {
      screen.status =
        "共享的事有新素材等你确认（\(Set(waiting).sorted().joined(separator: "、"))）：打开那件事，点「共享这件事…」"
    }
  }

  // MARK: - Agents

  /// A space as agents may read it: its organizer state and the members'
  /// items as this Mac decrypted them.
  struct AgentInput: Sendable {
    let spaceID: String
    let name: String
    let projection: RemoteOrganizerProjection
    let records: [MemoryItemRecord]
  }

  /// The spaces this Mac is an active member of, for the agent's view.
  func agentInputs() -> [AgentInput] {
    screen.spaces.compactMap { state in
      guard state.membership == .active, let view = views[state.spaceID] else { return nil }
      return AgentInput(
        spaceID: state.spaceID, name: state.name, projection: view.projection,
        records: view.records)
    }
  }

  /// An agent read (or was refused) matters of a space: the space's log gets
  /// `agent.access` with counts only (SPACES-CONTRACT §1, the org audit log).
  func recordAgentAccess(_ record: AgentAuditRecord) {
    guard let engine else { return }
    let entries = AgentSpaceAccess.entries(for: record) { [views] matterID in
      guard let space = AgentSpaceAccess.space(ofMatter: matterID),
        let view = views[space]
      else { return 0 }
      let event = String(matterID.dropFirst("space:\(space):".count))
      return view.projection.events.first { $0.eventID == event }?.itemIDs.count ?? 0
    }
    let active = Set(screen.activeSpaces.map(\.spaceID))
    for entry in entries where active.contains(entry.spaceID) {
      Task {
        try? await engine.recordAgentAccess(
          entry.spaceID, client: entry.client, tool: entry.tool, matters: entry.matters,
          items: entry.items, bytes: entry.bytes, allowed: entry.allowed)
      }
    }
  }

  // MARK: - Read models

  func rebuild() {
    rebuildTask?.cancel()
    rebuildTask = Task { [weak self] in await self?.publish() }
  }

  private func publish() async {
    guard let engine else { return }
    let states = (try? await engine.allStates()) ?? []
    var views: [String: SpaceView] = [:]
    for state in states where state.membership == .active {
      views[state.spaceID] = SpaceProjectionBuilder.build(
        state, maskKey: try? await engine.maskKey(state.spaceID))
    }
    self.views = views
    screen.spaces = states
    // An opened original goes when its item leaves the space or access ends.
    let live = Dictionary(
      states.filter { $0.membership == .active }.map { ($0.spaceID, $0) }
    ) { first, _ in first }
    originals.prune { space, item in live[space]?.items[item]?.isActive == true }
    screen.orgAdmin = states.contains { $0.ownerKind == .org && $0.role == .admin }
    var shared: [String: [String]] = [:]
    for state in states where state.membership == .active {
      for package in state.packages.values
      where package.active && package.owner == state.memberID {
        if let matter = package.matterID { shared[matter, default: []].append(state.spaceID) }
      }
      screen.matterTitles[state.spaceID] = Dictionary(
        (views[state.spaceID]?.projection.events ?? []).map { ($0.eventID, $0.title) }
      ) { first, _ in first }
    }
    screen.sharedMatters = shared.mapValues { Array(Set($0)).sorted() }
    if case .space(let id) = screen.scope, views[id] == nil { screen.scope = .mine }
    let pairs = states.compactMap { state in views[state.spaceID].map { (state: state, view: $0) } }
    let personal = memory?.projection
    let badges = SpaceOverlay.badges(
      personal: (personal?.events ?? []).map { ($0.eventID, $0.itemIDs) }, spaces: pairs)
    screen.badges = badges.mapValues {
      SpaceBadgeInfo(spaceID: $0.spaceID, spaceEventID: $0.spaceEventID, text: $0.text)
    }
    await buildScope(pairs: pairs, personal: personal)
  }

  private func buildScope(
    pairs: [(state: SpaceLocalState, view: SpaceView)], personal: MemoryProjection?
  ) async {
    let now = Date()
    switch screen.scope {
    case .mine:
      scopeBase = nil
      screen.matters = [:]
      spaceEventsInAll = [:]
    case .space(let id):
      guard let pair = pairs.first(where: { $0.state.spaceID == id }) else { return }
      let view = pair.view
      let model = await Task.detached(priority: .userInitiated) {
        MemoryReadModel(
          MemoryProjection(remote: view.projection, records: view.records, now: now))
      }.value
      var matters: [String: SpaceMatterInfo] = [:]
      for event in view.projection.events {
        matters[event.eventID] = SpaceMatterInfo.make(
          state: pair.state, itemIDs: event.itemIDs,
          contributionLine: view.contributionLine(eventID: event.eventID), now: now)
      }
      screen.matters = matters
      scopeBase = MemoryScreenState(mode: .spark, readModel: model)
    case .all:
      guard let personal else { return }
      let merged = SpaceOverlay.merged(
        personal: personal.events, personalRecords: Array(personal.records.values),
        personalPersons: personal.persons, spaces: pairs)
      let questions = personal.questions
      let readings = personal.remoteReadings
      let summaries = personal.remoteReadingSummaries
      let facts = personal.remoteReadingFacts
      let unfiled = personal.unfiled
      let owners = personal.ownerPersonIDs
      let model = await Task.detached(priority: .userInitiated) {
        MemoryReadModel(
          MemoryProjection(
            events: merged.events, records: merged.records, persons: merged.persons,
            questions: questions, remoteReadings: readings, remoteReadingSummaries: summaries,
            remoteReadingFacts: facts, unfiled: unfiled, now: now, ownerPersonIDs: owners))
      }.value
      var matters: [String: SpaceMatterInfo] = [:]
      for (eventID, spaceID) in merged.spaceEvents {
        guard let pair = pairs.first(where: { $0.state.spaceID == spaceID }),
          let source = merged.events.first(where: { $0.eventID == eventID })
        else { continue }
        let original = String(eventID.dropFirst("space:\(spaceID):".count))
        matters[eventID] = SpaceMatterInfo.make(
          state: pair.state, itemIDs: source.itemIDs,
          contributionLine: pair.view.contributionLine(eventID: original), now: now)
      }
      screen.matters = matters
      spaceEventsInAll = merged.spaceEvents
      var state = MemoryScreenState(mode: .spark, readModel: model)
      state.sharedItemIDs = merged.othersItemIDs
      scopeBase = state
    }
  }

  /// The page state for the scope: 我的 is the personal state as is; a space
  /// or 全部 takes the live parts (toast, capture, now) from it.
  func memoryState(personal: MemoryScreenState) -> MemoryScreenState {
    guard screen.scope != .mine, var state = scopeBase else { return personal }
    state.toast = personal.toast
    state.capture = personal.capture
    state.now = personal.now
    state.thumbnail = personal.thumbnail
    return state
  }

  func setScope(_ scope: SpaceScope) {
    guard screen.scope != scope else { return }
    screen.scope = scope
    scopeBase = nil
    rebuild()
  }

  // MARK: - Actions

  private func run(_ success: String?, _ work: @escaping (SpaceEngine) async throws -> Void) {
    guard let engine = ensureEngine() else {
      screen.status = "共享空间还没有准备好（先打开整理设备链路）"
      return
    }
    screen.busy = true
    Task { [weak self] in
      do {
        try await work(engine)
        self?.screen.status = success
      } catch {
        self?.screen.status = Self.message(error)
      }
      self?.screen.busy = false
      await self?.publish()
    }
  }

  static func message(_ error: Error) -> String {
    switch error {
    case SpaceClientError.transport: return "整理设备没有连上；稍后再试"
    case SpaceClientError.accessEnded: return "你已不在这个空间里"
    case SpaceEngine.EngineError.notAllowed(let right): return "你的角色不能这样做（\(right)）"
    case SpaceEngine.EngineError.refused(let code):
      return refusal(code)
    case let error as SpaceClientError:
      if let code = error.serverCode { return refusal(code) }
      return "整理设备的回答看不懂；没有改动"
    case is SpaceInviteCode.CodeError: return "邀请码看不懂或已过期"
    default: return "没有完成；你的内容没有变化"
    }
  }

  static func refusal(_ code: String) -> String {
    let words: [String: String] = [
      "window_passed": "已经过了撤回期限；可以删除（会变成下架申请）",
      "rotation_pending": "有成员刚离开，等管理员换好钥匙再试",
      "host_key_mismatch": "邀请指向另一台整理设备；没有加入",
      "invite_used": "这个邀请码已经用过了", "invite_expired": "这个邀请码已经过期",
      "invite_revoked": "这个邀请码已被收回", "bad_invite_secret": "邀请码不对",
      "forks_not_allowed": "这个空间不允许存副本",
      "privacy_takedown": "共享的人自己申请的隐私下架不能拒绝",
      "too_many_takedowns": "你已有 3 条隐私下架申请没处理完，等维护者处理后再申请",
      "recording_share_limit": "同一段录音最多共享 15 分钟（可以换一段，或先撤回已共享的那段）",
      "member_id_taken": "这个成员编号已经属于别人",
      "approve_mismatch": "申请里的设备和要同意的不一致；没有同意",
      "join_request_unverified": "这条申请核对不上（不是持邀请码的人发的），不能同意",
      "bad_wraps": "整理设备列出的设备和成员签过名的记录对不上，没有换钥匙；请检查整理设备",
      "no_masker": "没有遮号工具，改动没有发出",
      "originals_not_allowed": "这个空间只留文字", "item_gone": "这条素材已经不在空间里",
      "archived": "空间已归档，只能查看", "forbidden": "你的角色不能这样做",
      "owner_cannot_leave": "主人不能离开自己的空间", "last_admin": "空间至少要留一位管理员",
      "never_shared": "声纹、词典、个人识别习惯和整段录音永远不共享",
      "audio_needs_segment": "录音只能按片段共享", "segment_too_long": "一段录音最多 15 分钟",
    ]
    return words[code] ?? "整理设备没有接受（\(code)）"
  }

  func actions(navigate: @escaping @MainActor (SpaceScope, String?) -> Void) -> SpacesActions {
    SpacesActions(
      setScope: { [weak self] in
        self?.setScope($0)
        navigate($0, nil)
      },
      present: { [weak self] sheet in self?.present(sheet) },
      createSpace: { [weak self] in self?.createSpace($0) },
      readInvite: { [weak self] in self?.readInvite($0) },
      join: { [weak self] in self?.join(code: $0, name: $1) },
      dropJoin: { [weak self] id in
        self?.run(nil) { try await $0.dropJoin(id) }
      },
      makeInvite: { [weak self] in self?.makeInvite($0, role: $1) },
      copy: { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
      },
      approve: { [weak self] space, request, role in
        self?.run("已同意；空间的钥匙已经发给对方的 Mac") {
          try await $0.approve(space, request: request, role: role)
        }
      },
      reject: { [weak self] space, request in
        self?.run("已拒绝") { try await $0.reject(space, requestID: request) }
      },
      setRole: { [weak self] space, member, role in
        self?.run("已改角色") { try await $0.setRole(space, memberID: member, role: role) }
      },
      removeMember: { [weak self] space, member in
        self?.run("已移除；空间换了一把新钥匙") {
          try await $0.removeMember(space, memberID: member)
        }
      },
      leave: { [weak self] space, take in
        self?.run("已离开空间；这台 Mac 上它的内容和钥匙已删除") { engine in
          let copies = try await engine.leave(space, withdrawContributions: take)
          await self?.deleteCopies(copies)
          await MainActor.run {
            self?.sheet = nil
            self?.setScope(.mine)
          }
        }
      },
      setPolicy: { [weak self] space, changes in
        self?.run("已更新空间设置") { try await $0.setPolicy(space, changes) }
      },
      archive: { [weak self] space, archived in
        self?.run(archived ? "空间已归档（只读）" : "已取消归档") {
          try await $0.archive(space, archived: archived)
        }
      },
      share: { [weak self] in self?.share($0) },
      unshare: { [weak self] space, event in self?.unshare(space, eventID: event) },
      itemAction: { [weak self] in self?.itemAction($0, itemID: $1, $2, reason: $3) },
      openOriginal: { [weak self] in self?.openOriginal($0, itemID: $1, blob: $2) },
      openSpaceMatter: { [weak self] space, event in
        self?.setScope(.space(space))
        navigate(.space(space), event)
      },
      resolveProposal: { [weak self] space, proposal, accept in
        self?.run(accept ? "已采纳" : "已不采纳") {
          _ = try await $0.resolveProposal(space, proposalID: proposal, accept: accept)
        }
      },
      answerOrganizer: { [weak self] space, question, yes in
        self?.run("已回答") {
          try await $0.answerOrganizerProposal(space, questionID: question, yes: yes)
        }
      },
      resolveTakedown: { [weak self] space, takedown, accept in
        self?.run(accept ? "已下架" : "已不同意") {
          try await $0.resolveTakedown(space, takedownID: takedown, accept: accept)
        }
      },
      rejectTakedown: { [weak self] space, takedown, reason in
        self?.run("已不同意；申请人会看到你的理由") {
          try await $0.resolveTakedown(
            space, takedownID: takedown, accept: false, reason: reason)
        }
      },
      propose: { [weak self] in self?.propose($0, eventID: $1, kind: $2, text: $3, other: $4) },
      refresh: { [weak self] space in
        guard let self else { return }
        Task {
          if let space, let engine = self.engine,
            let state = try? await engine.state(space), state.role == .admin
          {
            self.screen.audit[space] = (try? await engine.audit(space))?.records
          }
          await self.tick()
        }
      }
    )
  }

  private func present(_ sheet: SpaceSheet?) {
    self.sheet = sheet
    if case .share(let eventID) = sheet { prepareShare(eventID) }
    if case .audit(let space) = sheet, let engine {
      Task { [weak self] in self?.screen.audit[space] = (try? await engine.audit(space))?.records }
    }
  }

  private func createSpace(_ draft: SpaceDraft) {
    run("已建好「\(draft.name)」；现在可以邀请成员了") { [weak self] engine in
      var orgID: String?
      var orgMember: String?
      if draft.owner == .org {
        let org = try await engine.createOrg()
        orgID = org.orgID
        orgMember = org.memberID
      }
      let state = try await engine.createSpace(
        name: draft.name, owner: draft.owner, orgID: orgID, orgMemberID: orgMember,
        policy: draft.policy, displayName: Self.myName, spark: nil)
      await MainActor.run {
        self?.sheet = .members(spaceID: state.spaceID)
        self?.screen.scope = .space(state.spaceID)
      }
    }
  }

  /// The user's name as members see it (the Mac's user name; changeable later).
  static var myName: String {
    let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
    return full.isEmpty ? "我" : full
  }

  private func readInvite(_ text: String) {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      screen.joinPreview = nil
      screen.joinError = nil
      return
    }
    do {
      screen.joinPreview = try SpaceInviteCode.decode(text)
      screen.joinError = nil
    } catch {
      screen.joinPreview = nil
      screen.joinError = Self.message(error)
    }
  }

  private func join(code: String, name: String) {
    guard let invite = try? SpaceInviteCode.decode(code) else {
      screen.joinError = "邀请码看不懂或已过期"
      return
    }
    guard let service = app?.phoneLink.service else {
      screen.joinError = "整理设备的连接设置无效，无法加入"
      return
    }
    run("已发送申请；对方同意后会自动加入") { [weak self] engine in
      // The invite must pin the host key this Mac's own link pinned (its
      // known_hosts entry), not merely one the Spark says is its own.
      let endpoint = try await service.sparkEndpoint()
      _ = try await engine.join(
        code: invite, displayName: name, localHostKey: endpoint.hostKey.openSSH)
      await MainActor.run { self?.sheet = nil }
    }
  }

  private func makeInvite(_ spaceID: String, role: SpaceRole) {
    guard let service = app?.phoneLink.service else {
      screen.status = "整理设备的连接设置无效，无法生成邀请"
      return
    }
    run(nil) { [weak self] engine in
      // The invite pins the organizing device's host key from this Mac's
      // known_hosts; the Spark refuses a key that is not one of its own.
      let endpoint = try await service.sparkEndpoint()
      let spark = SpaceInviteCode.Endpoint(
        host: endpoint.host, port: endpoint.port, user: nil, hostKey: endpoint.hostKey.openSSH)
      let code = try await engine.invite(
        spaceID, role: role, hostKey: endpoint.hostKey.openSSH, spark: spark)
      let text = try code.encoded()
      let qr = PhonePairingQRCode.image(for: text).map {
        NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
      }
      await MainActor.run {
        self?.screen.invite = SpaceInviteDisplay(
          spaceID: spaceID, code: text, role: role, expires: code.expiry ?? Date(), qr: qr)
      }
    }
  }

  // MARK: - Share

  /// The review list for one of my matters: each item (a recording only by
  /// the parts filed into the matter), private dictations and items with
  /// numbers unticked.
  private func prepareShare(_ eventID: String) {
    screen.shareDraft = nil
    Task { [weak self] in
      guard let self, let entries = await self.entries(forMatter: eventID) else { return }
      let detail = self.memory?.projection?.event(id: eventID)
      let ordered = entries.values.sorted {
        ($0.candidate.startedAt ?? .distantPast, $0.candidate.id)
          < ($1.candidate.startedAt ?? .distantPast, $1.candidate.id)
      }
      let destinations = self.screen.activeSpaces.filter { $0.can("share") && !$0.archived }
      var sharedIn: [String: SpaceRuleMode] = [:]
      for space in self.screen.activeSpaces {
        for package in space.packages.values
        where package.active && package.owner == space.memberID && package.matterID == eventID {
          sharedIn[space.spaceID] = package.auto
        }
      }
      var draft = SpaceShareDraft(
        eventID: eventID, title: detail?.title ?? "这件事", destinations: destinations,
        destination: self.screen.scope.spaceID ?? destinations.first?.spaceID,
        rope: self.ropeOf?(eventID),
        review: SpaceShareReview(candidates: ordered.map(\.candidate)), sharedIn: sharedIn)
      if let space = draft.destination, let mode = sharedIn[space] {
        draft.scale = .matter(rule: mode)
      }
      self.screen.shareDraft = draft
    }
  }

  /// What a matter of mine would send, by space item id.
  private func entries(forMatter eventID: String) async -> [String: SpaceShareContent.Entry]? {
    guard let repository = app?.repository, let projection = memory?.projection,
      let detail = projection.event(id: eventID)
    else { return nil }
    let assetRoot = app?.intake.assetRoot
    var parts: [String: [SpaceShareContent.Part]] = [:]
    var order: [String] = []
    var records: [String: MemoryItemRecord] = [:]
    for item in detail.items {
      if parts[item.itemID] == nil { order.append(item.itemID) }
      if let segment = item.segment {
        parts[item.itemID, default: []].append(.init(start: segment.start, end: segment.end))
      } else {
        parts[item.itemID] = parts[item.itemID] ?? []
      }
      if let record = item.record { records[item.itemID] = record }
    }
    var out: [String: SpaceShareContent.Entry] = [:]
    for itemID in order {
      guard let uuid = UUID(uuidString: itemID),
        let content = try? await repository.spaceShareContent(sessionID: SessionID(uuid))
      else { continue }
      let record = records[itemID]
      var originals: [(role: String, data: Data)] = []
      if let root = assetRoot, let record {
        let path =
          content.kind == "image"
          ? record.thumbnailAssetPath
          : (content.kind == "file" || content.kind == "document")
            ? record.originalAssetPath : nil
        if let path, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
          let data = try? Data(contentsOf: root.appendingPathComponent(path)),
          data.count <= 25 * 1_048_576
        {
          originals.append((content.kind == "image" ? "image" : "original", data))
        }
      }
      for entry in SpaceShareContent.entries(
        for: content, title: record?.titleIsUserEdited == true ? record?.title : nil,
        matterID: eventID,
        parts: parts[itemID] ?? [], reading: record?.localReading, originals: originals)
      {
        out[entry.candidate.id] = entry
      }
    }
    shareEntries[eventID] = out
    return out
  }

  private func share(_ draft: SpaceShareDraft) {
    guard let space = draft.destination ?? draft.destinations.first?.spaceID else { return }
    let entries = shareEntries[draft.eventID] ?? [:]
    let picked: [SpaceShareContent.Entry]
    var package: SpacePackageRequest?
    var rope: (id: String, title: String, mode: SpaceRuleMode)?
    let detail = memory?.projection?.event(id: draft.eventID)
    switch draft.scale {
    case .item:
      picked = draft.picked.flatMap { entries[$0] }.map { [$0] } ?? []
    case .matter(let rule):
      picked = draft.review.selected.compactMap { entries[$0.id] }
      let existing = screen.space(space)?.packages.values.first {
        $0.active && $0.matterID == draft.eventID
      }
      package = SpacePackageRequest(
        packageID: existing?.packageID ?? SpaceID.new(), auto: rule, matterID: draft.eventID,
        title: detail?.title,
        facts: (detail?.statusFacts ?? []).prefix(8).map(\.text))
    case .rope(let rule):
      picked = draft.review.selected.compactMap { entries[$0.id] }
      if let value = draft.rope { rope = (value.id, value.title, rule) }
      package = SpacePackageRequest(
        auto: .off, matterID: draft.eventID, title: detail?.title,
        facts: (detail?.statusFacts ?? []).prefix(8).map(\.text))
    }
    let count = picked.count
    run(nil) { [weak self] engine in
      let report = try await engine.share(space, items: picked.map(\.item), package: package)
      if let rope {
        _ = try await engine.setRule(
          space, kind: "rope", targetID: rope.id, title: rope.title, auto: rope.mode)
      }
      await MainActor.run {
        self?.sheet = nil
        let refused = report.refused.count
        self?.screen.status =
          "已共享 \(report.shared.count) 条" + (refused > 0 ? "，\(refused) 条没有共享" : "")
          + (report.originalsDropped > 0 ? "；这个空间只留文字，原件留在你的 Mac 上" : "")
        _ = count
      }
    }
  }

  private func unshare(_ spaceID: String, eventID: String) {
    guard
      let package = screen.space(spaceID)?.packages.values.first(where: {
        $0.active && $0.matterID == eventID
      })
    else { return }
    run("这件事以后的新素材不再共享；已共享的还在空间里") {
      try await $0.unsharePackage(spaceID, packageID: package.packageID)
    }
    sheet = nil
  }

  // MARK: - Items

  private func itemAction(
    _ spaceID: String, itemID: String, _ action: SpaceRules.ItemAction, reason: String?
  ) {
    switch action {
    case .withdraw:
      run("已撤回；成员的 Mac 会删掉它") { try await $0.withdraw(spaceID, itemID: itemID) }
    case .delete:
      run(nil) { [weak self] engine in
        let outcome = try await engine.delete(spaceID, itemID: itemID)
        await MainActor.run {
          self?.screen.status =
            outcome == .takedownRequested
            ? "已过撤回期限：已向维护者提出下架申请" : "已从空间里删除；你自己的空间里它还在"
        }
      }
    case .requestPrivacyTakedown:
      run("已提出隐私下架申请") {
        try await $0.requestTakedown(spaceID, itemID: itemID, privacy: true, reason: reason)
      }
    case .remove:
      run("已移除") { try await $0.remove(spaceID, itemID: itemID) }
    case .hide:
      run("已隐藏，只对你；别人还看得到") { try await $0.hide(spaceID, itemID: itemID) }
    case .unhide:
      run("已取消隐藏") { try await $0.hide(spaceID, itemID: itemID, hidden: false) }
    case .fork:
      run("已存一份到你的空间；失去这个空间的访问权时会删除") { [weak self] engine in
        try await engine.fork(spaceID, itemID: itemID)
        if let copy = await self?.makeForkCopy(spaceID, itemID: itemID, engine: engine) {
          try await engine.recordForkCopy(spaceID, itemID: itemID, localID: copy)
        }
      }
    case .unfork:
      run("已删除副本") { [weak self] engine in
        if let copy = try await engine.unfork(spaceID, itemID: itemID) {
          await self?.deleteCopies([copy])
        }
      }
    }
  }

  /// "存一份到我的空间": the item's text as a new item of mine, its source
  /// naming the space and the contributor.
  private func makeForkCopy(_ spaceID: String, itemID: String, engine: SpaceEngine) async
    -> String?
  {
    guard let app, let processor = app.intakeProcessor, let repository = app.repository,
      let state = try? await engine.state(spaceID), let item = state.items[itemID.lowercased()],
      let fields = item.fields
    else { return nil }
    let text = [fields.title, SpaceOrganizerPayloads.organizerText(fields)]
      .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    let source = ItemSourceApplication(
      bundleID: nil, name: "共享空间·\(state.name)·\(state.name(of: item.contributor))")
    guard
      case .item(let draft) = processor.prepare(
        .text(text, extractor: "plain-text-v1"), capturedAt: Date(), source: source,
        origin: .user)
    else { return nil }
    do {
      try await repository.createUserItem(draft)
      processor.assetStore.commit(sessionID: draft.id)
    } catch {
      processor.assetStore.discard(sessionID: draft.id)
      return nil
    }
    await app.refreshHistoryItems(preserveStatus: true, organizeEvents: true)
    return draft.id.rawValue.uuidString
  }

  private func deleteCopies(_ copies: [String]) async {
    guard let repository = app?.repository else { return }
    let ids = copies.compactMap { UUID(uuidString: $0) }.map(SessionID.init)
    guard !ids.isEmpty else { return }
    try? await repository.deleteSessionRecordsExplicitly(sessionIDs: ids)
    await app?.refreshHistoryItems(preserveStatus: true)
  }

  private func openOriginal(_ spaceID: String, itemID: String, blob: SpaceBlobRef) {
    let folder = originals
    run(nil) { engine in
      let data = try await engine.original(spaceID, itemID: itemID, blob: blob)
      let state = try await engine.state(spaceID)
      let fields = state?.items[itemID.lowercased()]?.fields
      let ext =
        fields?.filename.flatMap { URL(fileURLWithPath: $0).pathExtension }.flatMap {
          $0.isEmpty ? nil : $0
        } ?? (blob.role == "image" ? "png" : "bin")
      let url = try folder.write(data, space: spaceID, item: itemID, blob: blob.blobID, ext: ext)
      await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }
  }

  // MARK: - Proposals

  private func propose(
    _ spaceID: String, eventID: String, kind: String, text: String, other: String?
  ) {
    let original =
      eventID.hasPrefix("space:") ? String(eventID.split(separator: ":").last ?? "") : eventID
    guard let state = screen.space(spaceID) else { return }
    if state.can("edit_matters") {
      run("已修改") { engine in
        var decision: SpaceJSON
        switch kind {
        case "rename":
          decision = [
            "decision_id": .string(SpaceID.new()), "kind": "rename_event",
            "event_id": .string(original), "title": .string(text),
          ]
        case "merge":
          decision = [
            "decision_id": .string(SpaceID.new()), "kind": "same_event",
            "a": .string(original), "b": .string(other ?? ""), "answer": true,
          ]
        default:
          _ = try await engine.propose(
            spaceID, kind: kind, matterIDs: [original], details: ["note": .string(text)])
          return
        }
        // The title is masked with the space's mask key first (V7-S13).
        _ = try await engine.editMatters(spaceID, decisions: [decision])
      }
    } else {
      var details: SpaceJSON = [:]
      if kind == "rename" {
        details = ["title": .string(text)]
      } else if !text.isEmpty {
        details = ["note": .string(text)]
      }
      run("已提交提议，等维护者处理") { engine in
        _ = try await engine.propose(
          spaceID, kind: kind, matterIDs: [original] + (other.map { [$0] } ?? []),
          details: details)
      }
    }
    sheet = nil
  }

  /// 复制为文本 for a space's matter (the same format as my own matters).
  func copySpaceText(_ eventID: String) {
    guard let app, let detail = scopeBase?.projection?.event(id: eventID) else { return }
    let text = EventPlainTextFormatter().format(detail)
    app.intake.show(app.pasteboardWriter.write(text) ? "已复制这件事的文字" : "复制失败")
  }

  /// A rename on a space's matter page: a maintainer edits, others propose.
  func renameInSpace(eventID: String, title: String) {
    guard let spaceID = screen.scope.spaceID ?? spaceEventsInAll[eventID] else { return }
    propose(spaceID, eventID: eventID, kind: "rename", text: title, other: nil)
  }
}
