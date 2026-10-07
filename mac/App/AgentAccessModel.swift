import AppKit
import BestASRAgentAccess
import BestASRDomain
import BestASRMemory
import BestASRMemoryUI
import Combine
import Foundation
import MindloomIdentity
import MindloomLibrary
import OSLog

/// Other Apps reading (and, when allowed, changing) Mindloom (AGENT-CONTRACT
/// §2; v12 phase B, B5 appendix C F1–F13), as the App shows it: requests
/// waiting for the owner (the consent card and per-matter approvals), the
/// grants, every call (谁读过什么) and the changes other Apps made, each
/// undoable.
@MainActor
final class AgentAccessModel: ObservableObject {
  struct PendingConsent: Identifiable {
    let request: AgentConsentRequest
    let resume: (AgentConsentAnswer?) -> Void
    var id: UUID { request.id }
  }

  struct PendingApproval: Identifiable {
    let request: AgentMatterApprovalRequest
    var answers: [String: Bool] = [:]
    let resume: ([String: Bool]) -> Void
    var id: UUID { request.id }
    var unanswered: [AgentMatterOption] { request.matters.filter { answers[$0.id] == nil } }
  }

  @Published private(set) var consents: [PendingConsent] = []
  @Published private(set) var approvals: [PendingApproval] = []
  /// Esc put the card away: the requests still wait (F11).
  @Published var requestsHidden = false
  @Published private(set) var grants: [AgentAccessService.GrantSummary] = []
  /// The newest calls of everyone (for the App list).
  @Published private(set) var audit: [AgentAuditRecord] = []
  /// The newest changes of everyone.
  @Published private(set) var changes: [AgentChangeRecord] = []
  /// The open App page's calls (its own, up to 500) and their total.
  @Published private(set) var pageAudit: [AgentAuditRecord] = []
  @Published private(set) var pageAuditCount = 0
  /// Programs connected now, by key (who signed them, where they are).
  @Published private(set) var connected: [String: AgentClientIdentity] = [:]
  /// 设置 › 其他 App › 允许其他 App 读, for this library (off by default, F1).
  @Published var otherAppsCanRead = false
  /// The App whose page is open in Settings (its client key).
  @Published var openApp: String? {
    didSet { if openApp != oldValue { requestRefresh() } }
  }
  @Published var status: String?

  var service: AgentAccessService?
  /// The App's search as agents use it (v12 search: its meaning vectors are
  /// made in the background by `MeaningSearch`).
  var search: AgentRecordSearch?
  var server: AgentSocketServer?
  var store: (any AgentAccessRecordStore)?
  var dataRoot: URL?
  /// Read on the socket's accept thread.
  let agentsSwitch = AgentSwitch()
  /// Shared spaces (set when the memory pages attach them): their matters
  /// join the agent's view labelled with their space, and reads of a space
  /// go to its log as `agent.access`.
  weak var spaces: SpacesModel?
  /// Presents requests (the consent panel); set by the App.
  var present: (() -> Void)?
  var notify: AgentNotifying?
  private var refreshTask: Task<Void, Never>?

  /// Where the helper lives in this App (for the connection instructions).
  var helperPath: String {
    Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mindloom-mcp").path
  }

  var isRunning: Bool { server?.isRunning ?? false }

  /// Names of Apps whose request waits on a card the owner put away.
  var waitingNames: [String] {
    guard requestsHidden else { return [] }
    var seen = Set<String>()
    let names =
      consents.map(\.request.client.displayName) + approvals.map(\.request.client.displayName)
    return names.filter { seen.insert($0).inserted }
  }

  // MARK: Requests from the service

  func enqueue(_ request: AgentConsentRequest, resume: @escaping (AgentConsentAnswer?) -> Void) {
    consents.append(PendingConsent(request: request, resume: resume))
    notify?.consentRequested(request)
    requestsHidden = false
    present?()
  }

  func enqueue(_ request: AgentMatterApprovalRequest, resume: @escaping ([String: Bool]) -> Void) {
    approvals.append(PendingApproval(request: request, resume: resume))
    notify?.mattersRequested(request)
    requestsHidden = false
    present?()
  }

  func answer(_ consentID: UUID, with answer: AgentConsentAnswer?) {
    guard let index = consents.firstIndex(where: { $0.id == consentID }) else { return }
    let pending = consents.remove(at: index)
    pending.resume(answer)
    notify?.withdraw(consentID)
  }

  /// One matter of one approval request; the request is answered once every
  /// matter in it is.
  func answer(approval approvalID: UUID, matterID: String, allowed: Bool) {
    guard let index = approvals.firstIndex(where: { $0.id == approvalID }) else { return }
    approvals[index].answers[matterID] = allowed
    notify?.withdraw(approvalID, matterID: matterID)
    if approvals[index].unanswered.isEmpty {
      let done = approvals.remove(at: index)
      done.resume(done.answers)
    }
  }

  /// Esc: the card goes away and nothing is answered (F11). The agent is
  /// told the owner has not decided yet; Settings › 其他 App and the
  /// notification bring the card back.
  func hideRequests() {
    requestsHidden = true
  }

  func showRequests() {
    requestsHidden = false
    present?()
  }

  // MARK: Lists

  func changeMade(_ change: AgentChangeRecord) {
    notify?.changeMade(change)
    requestRefresh()
  }

  /// Coalesces the service's change notices (one per call).
  func requestRefresh() {
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      await self?.refresh()
    }
  }

  func refresh() async {
    guard let service, let store else { return }
    let grants = await service.grants()
    let connected = await service.connectedClients()
    let audit = (try? await store.agentAudit(clientKey: nil, limit: 2_000)) ?? []
    let changes = (try? await store.agentChanges(clientKey: nil, limit: 500)) ?? []
    var page: [AgentAuditRecord] = []
    var pageCount = 0
    if let openApp {
      let all = (try? await store.agentAudit(clientKey: openApp, limit: 20_000)) ?? []
      pageCount = all.count
      page = Array(all.prefix(500))
    }
    self.grants = grants
    self.audit = audit
    self.changes = changes
    self.pageAudit = page
    self.pageAuditCount = pageCount
    var byKey = self.connected
    for identity in connected { byKey[identity.key] = identity }
    self.connected = byKey
  }

  func revoke(_ grantID: UUID) {
    guard let service else { return }
    Task { [weak self] in
      await service.revoke(grantID)
      await self?.refresh()
    }
  }

  /// 停止允许 everything one App has (its page's button).
  func stop(clientKey: String) {
    guard let service else { return }
    Task { [weak self] in
      await service.revokeAll(clientKey: clientKey)
      await self?.refresh()
    }
  }

  // MARK: Words

  /// 「「TES 论文…」 · 今天 · 只读」.
  static func allowedText(_ grant: AgentAccessService.GrantSummary, title: (String) -> String?)
    -> String
  {
    let what: String
    switch grant.terms.range {
    case .all: what = "所有事"
    case .matters(let ids):
      what =
        ids.count == 1
        ? "“\(ids.first.flatMap(title) ?? "一件事")”" : "\(ids.count) 件事"
    case .groups(let ids):
      what =
        ids.first.flatMap { MindloomTitles.shared.groups[$0.lowercased()] }
        .map { "分组“\($0)”" } ?? "一个分组"
    case .ropes: what = "以前允许的范围"
    }
    let spaces = grant.terms.spaces.filter { $0 != AgentSpaceID.personal }.count
    var parts = [what + (spaces > 0 ? "和 \(spaces) 个共享空间" : "")]
    let how: String =
      switch grant.terms.duration {
      case .once: "此次对话"
      case .today: "今天"
      case .always: "始终"
      }
    parts.append(how)
    parts.append(grant.terms.canChange ? "允许更改" : "只读")
    if grant.terms.showNumbers { parts.append("显示号码") }
    return parts.joined(separator: " · ")
  }

  /// 「找」「读一件事」…, and an unknown tool in plain words (review v12-B #16).
  static func toolName(_ tool: String) -> String { AgentAuditWords.tool(tool) }

  static func outcomeName(_ outcome: AgentAuditOutcome) -> String {
    AgentAuditWords.outcome(outcome)
  }
}

/// 允许其他 App 读, readable from the socket's accept thread.
final class AgentSwitch: @unchecked Sendable {
  private let lock = NSLock()
  private var on = false

  var isOn: Bool { lock.withLock { on } }
  func set(_ value: Bool) { lock.withLock { on = value } }
}

/// Notifications for agent requests and changes (the App's `AgentNotifier`).
@MainActor
protocol AgentNotifying: AnyObject {
  func consentRequested(_ request: AgentConsentRequest)
  func mattersRequested(_ request: AgentMatterApprovalRequest)
  func changeMade(_ change: AgentChangeRecord)
  func limitReached(_ clientName: String)
  func withdraw(_ requestID: UUID)
  func withdraw(_ requestID: UUID, matterID: String)
}

/// The owner's side of the service: hands each request to the model on the
/// main actor and waits for the answer.
final class AppAgentConsentPresenter: AgentConsentPresenting, @unchecked Sendable {
  @MainActor weak var model: AgentAccessModel?
  /// A check build's pre-approval, from the launch arguments, on a
  /// synthetic library only (`DictationAppModel.agentPreapproval`).
  let preapproval: AgentPreapproval?

  init(preapproval: AgentPreapproval? = nil) {
    self.preapproval = preapproval
  }

  func requestConsent(_ request: AgentConsentRequest) async -> AgentConsentAnswer? {
    if let preapproval, let terms = preapproval.answer(request) {
      Logger(subsystem: MindloomIdentity.logSubsystem, category: "agent").notice(
        "check build: pre-approved \(request.client.name, privacy: .public) without a card")
      return .allow(terms)
    }
    return await withCheckedContinuation { continuation in
      Task { @MainActor in
        guard let model = self.model else {
          continuation.resume(returning: nil)
          return
        }
        model.enqueue(request) { continuation.resume(returning: $0) }
      }
    }
  }

  func approveMatters(_ request: AgentMatterApprovalRequest) async -> [String: Bool] {
    await withCheckedContinuation { continuation in
      Task { @MainActor in
        guard let model = self.model else {
          continuation.resume(returning: [:])
          return
        }
        model.enqueue(request) { continuation.resume(returning: $0) }
      }
    }
  }

  func changeMade(_ change: AgentChangeRecord) async {
    await MainActor.run { model?.changeMade(change) }
  }

  func limitReached(clientName: String) async {
    await MainActor.run { model?.notify?.limitReached(clientName) }
  }

  func accessRecorded(_ record: AgentAuditRecord) async {
    await MainActor.run { model?.spaces?.recordAgentAccess(record) }
  }

  func accessChanged() async {
    await MainActor.run { model?.requestRefresh() }
  }
}

/// What Mindloom holds right now, as the memory pages see it: the organizing
/// device's projection with the owner's decisions applied, or the local
/// organizer's events, with their ropes and map strands (MAP-CONTRACT); plus
/// each shared space this Mac is a member of, its matters labelled with the
/// space (SPACES-CONTRACT; `AgentMemorySnapshot.init(personal:spaces:)`); and
/// the owner's own marks, with the pages' digest (steps and their IDs).
/// Rebuilt at most every two seconds, and at once after an agent's change.
final class AppAgentMemory: AgentMemoryProviding, @unchecked Sendable {
  @MainActor weak var app: DictationAppModel?
  private let lock = NSLock()
  private var cached: (snapshot: AgentMemorySnapshot, at: Date)?

  @MainActor init(app: DictationAppModel) {
    self.app = app
  }

  func invalidate() async {
    lock.withLock { cached = nil }
  }

  func agentSnapshot() async -> AgentMemorySnapshot? {
    if let cached = lock.withLock({ cached }), Date().timeIntervalSince(cached.at) < 2 {
      return cached.snapshot
    }
    let gathered = await Task {
      @MainActor [weak self] () -> (
        DictationAppModel.MemoryProjectionInputs, [SpacesModel.AgentInput], [String: String],
        UserOrganizingSnapshot, Calendar, [String]
      )? in
      guard let app = self?.app, let inputs = await app.memoryProjectionInputs() else {
        return nil
      }
      // 「这个分组」 grants follow the library's own groups, not what a
      // window last drew (the main window may never have drawn).
      var membership: [String: String] = [:]
      let user = (try? await app.repository?.userOrganizing()) ?? .empty
      for group in user.groups {
        for id in group.eventIDs { membership[id.uppercased()] = group.id.uuidString.lowercased() }
      }
      return (
        inputs, app.agentAccess.spaces?.agentInputs() ?? [], membership, user, app.productCalendar,
        DictationAppModel.memoryOwnerNames
      )
    }.value
    guard let gathered else { return nil }
    let (inputs, spaces, groups, user, calendar, owners) = gathered
    var snapshot = await Task.detached(priority: .userInitiated) {
      var snapshot = AgentMemorySnapshot(
        personal: inputs.projection(),
        spaces: spaces.map {
          AgentSpaceSource(
            space: AgentSpace(id: $0.spaceID, name: $0.name),
            projection: MemoryProjection(
              remote: $0.projection, records: $0.records, now: inputs.now))
        }, timeZone: calendar.timeZone)
      snapshot.user = user
      snapshot.digest = MemoryDigest(
        projection: snapshot.projection, user: user, now: snapshot.now, calendar: calendar,
        ownerNames: owners)
      return snapshot
    }.value
    // v11 「这个分组」 grants: which user group each matter is in.
    snapshot.groupOfMatter = groups
    lock.withLock { cached = (snapshot, Date()) }
    return snapshot
  }
}

/// Applies an allowed change exactly as the owner's own correction on the
/// pages would be applied (v12, 也可以改).
final class AppAgentChanges: AgentChangeApplying, @unchecked Sendable {
  @MainActor weak var app: DictationAppModel?

  @MainActor init(app: DictationAppModel) {
    self.app = app
  }

  func apply(_ change: AgentChange, client: AgentClientIdentity) async throws -> String? {
    guard let app = await MainActor.run(body: { self.app }) else {
      throw AgentChangeError.notApplied
    }
    return try await app.applyAgentChange(change, clientName: client.displayName)
  }
}

/// Stops listening when the App quits, so the socket does not outlive it.
@MainActor
enum AgentAccessQuit {
  static var server: AgentSocketServer?
}
