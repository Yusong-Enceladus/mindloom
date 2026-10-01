import AppKit
import BestASRAgentAccess
import BestASRDomain
import BestASRMemory
import Combine
import Foundation

/// Agents reading 织机 (AGENT-CONTRACT §2), as the App shows it: requests
/// waiting for the owner (the consent sheet and per-matter approvals), the
/// grants, the audit list 谁读过什么 and the Agent 收件箱.
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
  @Published private(set) var grants: [AgentAccessService.GrantSummary] = []
  @Published private(set) var audit: [AgentAuditRecord] = []
  @Published private(set) var proposals: [AgentInboxProposal] = []
  /// Clients seen in the audit or the grants, for the filter.
  @Published private(set) var clients: [(key: String, name: String)] = []
  /// Filters 谁读过什么 to one client (its key); nil shows everyone.
  @Published var auditClient: String? {
    didSet { if auditClient != oldValue { requestRefresh() } }
  }
  @Published var status: String?
  /// Settings switches to the Agent page when this flips on.
  @Published var showAgentSettings = false

  var service: AgentAccessService?
  var server: AgentSocketServer?
  var store: (any AgentAccessRecordStore)?
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

  // MARK: Requests from the service

  func enqueue(_ request: AgentConsentRequest, resume: @escaping (AgentConsentAnswer?) -> Void) {
    consents.append(PendingConsent(request: request, resume: resume))
    notify?.consentRequested(request)
    present?()
  }

  func enqueue(_ request: AgentMatterApprovalRequest, resume: @escaping ([String: Bool]) -> Void) {
    approvals.append(PendingApproval(request: request, resume: resume))
    notify?.mattersRequested(request)
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

  /// Closing the panel answers nothing: an unanswered consent is a no, and
  /// unanswered matters stay closed for now (the agent is told they wait).
  func dismissAll() {
    for pending in consents {
      pending.resume(nil)
      notify?.withdraw(pending.id)
    }
    consents = []
    for pending in approvals {
      pending.resume(pending.answers)
      notify?.withdraw(pending.id)
    }
    approvals = []
  }

  // MARK: Lists

  func proposalArrived(_ proposal: AgentInboxProposal) {
    notify?.proposalArrived(proposal)
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
    let audit = (try? await store.agentAudit(clientKey: auditClient, limit: 500)) ?? []
    let everyone = (try? await store.agentAudit(clientKey: nil, limit: 2_000)) ?? []
    let proposals = (try? await store.agentProposals(includeDecided: false)) ?? []
    self.grants = grants
    self.audit = audit
    self.proposals = proposals
    var seen = Set<String>()
    clients =
      (grants.map { ($0.clientKey, $0.clientName) } + everyone.map { ($0.clientKey, $0.clientName) })
      .filter { seen.insert($0.0).inserted }
      .map { (key: $0.0, name: $0.1) }
  }

  func revoke(_ grantID: UUID) {
    guard let service else { return }
    Task { [weak self] in
      await service.revoke(grantID)
      await self?.refresh()
    }
  }

  // MARK: Words

  static func scopeSummary(_ terms: AgentGrantTerms) -> String {
    let spaces = terms.spaces.sorted().map { $0 == AgentSpaceID.personal ? "我的" : $0 }
      .joined(separator: "、")
    let range: String
    switch terms.range {
    case .all: range = "全部"
    case .ropes(let ids): range = "\(ids.count) 条绳"
    case .matters(let ids): range = "\(ids.count) 件事"
    }
    var parts = ["空间：\(spaces)", "范围：\(range)", terms.canPropose ? "可以提建议" : "只读"]
    parts.append(terms.showNumbers ? "号码原样" : "号码遮住")
    if terms.askForNewMatters { parts.append("读新的一件事先问我") }
    return parts.joined(separator: " · ")
  }

  static func durationText(_ grant: AgentAccessService.GrantSummary) -> String {
    switch grant.terms.duration {
    case .once: "这一次（这次连接结束就失效）"
    case .today:
      "今天（到 \(grant.expiresAt?.formatted(date: .omitted, time: .shortened) ?? "今晚") 为止）"
    case .always: "一直（直到撤销）"
    }
  }

  static func toolName(_ tool: String) -> String {
    switch tool {
    case "search_matters": "找事"
    case "get_matter": "读一件事"
    case "list_deadlines": "看截止"
    case "list_recent": "看最近"
    case "get_person": "找人"
    case "add_to_inbox": "提建议"
    case "resources/list": "列出事"
    case "resources/read": "读一件事"
    default: tool
    }
  }

  static func outcomeName(_ outcome: AgentAuditOutcome) -> String {
    switch outcome {
    case .allowed: "已给"
    case .denied: "拒绝"
    case .pending: "等批准"
    case .notFound: "不在范围内"
    case .invalid: "参数不对"
    case .failed: "没读出来"
    }
  }
}

/// Notifications for agent requests (the App's `AgentNotifier`).
@MainActor
protocol AgentNotifying: AnyObject {
  func consentRequested(_ request: AgentConsentRequest)
  func mattersRequested(_ request: AgentMatterApprovalRequest)
  func proposalArrived(_ proposal: AgentInboxProposal)
  func withdraw(_ requestID: UUID)
  func withdraw(_ requestID: UUID, matterID: String)
}

/// The owner's side of the service: hands each request to the model on the
/// main actor and waits for the answer.
final class AppAgentConsentPresenter: AgentConsentPresenting, @unchecked Sendable {
  @MainActor weak var model: AgentAccessModel?

  func requestConsent(_ request: AgentConsentRequest) async -> AgentConsentAnswer? {
    await withCheckedContinuation { continuation in
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

  func proposalArrived(_ proposal: AgentInboxProposal) async {
    await MainActor.run { model?.proposalArrived(proposal) }
  }

  func accessRecorded(_ record: AgentAuditRecord) async {
    await MainActor.run { model?.spaces?.recordAgentAccess(record) }
  }

  func accessChanged() async {
    await MainActor.run { model?.requestRefresh() }
  }
}

/// What 织机 holds right now, as the memory pages see it: the organizing
/// device's projection with the owner's decisions applied, or the local
/// organizer's events, with their ropes and map strands (MAP-CONTRACT); plus
/// each shared space this Mac is a member of, its matters labelled with the
/// space (SPACES-CONTRACT; `AgentMemorySnapshot.init(personal:spaces:)`).
/// Rebuilt at most every two seconds.
final class AppAgentMemory: AgentMemoryProviding, @unchecked Sendable {
  @MainActor weak var app: DictationAppModel?
  private let lock = NSLock()
  private var cached: (snapshot: AgentMemorySnapshot, at: Date)?

  @MainActor init(app: DictationAppModel) {
    self.app = app
  }

  func agentSnapshot() async -> AgentMemorySnapshot? {
    if let cached = lock.withLock({ cached }), Date().timeIntervalSince(cached.at) < 2 {
      return cached.snapshot
    }
    let gathered = await Task {
      @MainActor [weak self] () -> (
        DictationAppModel.MemoryProjectionInputs, [SpacesModel.AgentInput]
      )? in
      guard let app = self?.app, let inputs = await app.memoryProjectionInputs() else {
        return nil
      }
      return (inputs, app.agentAccess.spaces?.agentInputs() ?? [])
    }.value
    guard let gathered else { return nil }
    let (inputs, spaces) = gathered
    let snapshot = await Task.detached(priority: .userInitiated) {
      AgentMemorySnapshot(
        personal: inputs.projection(),
        spaces: spaces.map {
          AgentSpaceSource(
            space: AgentSpace(id: $0.spaceID, name: $0.name),
            projection: MemoryProjection(
              remote: $0.projection, records: $0.records, now: inputs.now))
        })
    }.value
    lock.withLock { cached = (snapshot, Date()) }
    return snapshot
  }
}

/// Stops listening when the App quits, so the socket does not outlive it.
@MainActor
enum AgentAccessQuit {
  static var server: AgentSocketServer?
}
