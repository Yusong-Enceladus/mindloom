import BestASRAgentAccess
import BestASRDomain
import BestASRMemory
import Foundation
import MindloomAgentProtocol

/// Synthetic library for the agent tests: four matters in two spaces and two
/// ropes, with sentinel numbers and an out-of-scope sentinel phrase.
enum AgentFixture {
  static let phone = "13812345678"
  static let email = "twin7.sentinel@example.com"
  static let outside = "SENTINEL-OUTSIDE-SCOPE-7Q"
  static let twin = "E-TWIN7"
  static let openDay = "E-OPENDAY"
  static let labWeekly = "E-LABWEEKLY"
  static let moving = "E-MOVING"
  static let han = "5A0E4D8C-0000-4000-8000-000000000001"
  static let lin = "5A0E4D8C-0000-4000-8000-000000000002"
  static let items = (0..<6).map {
    UUID(uuidString: String(format: "7B1E0000-0000-4000-8000-%012d", $0))!
  }
  /// 2026-09-30 10:00 in Shanghai.
  static let now = Date(timeIntervalSince1970: 1_790_733_600)
  static let timeZone = TimeZone(identifier: "Asia/Shanghai")!

  static func day(_ offset: Int) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let date = calendar.date(byAdding: .day, value: offset, to: now)!
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
  }

  static func record(
    _ index: Int, text: String, source: String, hoursAgo: Double,
    segments: [MemoryItemRecord.Segment] = []
  ) -> MemoryItemRecord {
    let at = now.addingTimeInterval(-hoursAgo * 3_600)
    return MemoryItemRecord(
      sessionID: SessionID(items[index]), inputMode: segments.isEmpty ? .userItem : .roomMicrophone,
      itemKind: segments.isEmpty ? .text : nil, title: "", startedAt: at, updatedAt: at,
      sourceBundleID: nil, sourceDisplayName: source, sourceIdentifier: nil, text: text,
      segments: segments)
  }

  static func fact(_ text: String, _ state: String, date: String? = nil, item: Int)
    -> MemoryStatusFact
  {
    MemoryStatusFact(
      remote: RemoteOrganizerEvent.StatusFact(
        text: text, itemIDs: [items[item].uuidString], state: state, date: date))
  }

  static func snapshot(now: Date = now) throws -> AgentMemorySnapshot {
    let records = [
      record(0, text: "韩策：第三组周五前能跑完，有问题打我电话 \(phone)\n林晓：好的，我把表更新好", source: "微信", hoursAgo: 5),
      record(1, text: "第一组跑完了。结果发到 \(email)。", source: "邮件", hoursAgo: 30),
      record(
        2, text: "", source: "当面", hoursAgo: 3,
        segments: [
          .init(
            startMilliseconds: 0, endMilliseconds: 4_000,
            personID: PersonID(UUID(uuidString: han)!),
            personName: nil, text: "机械臂的夹爪这周换新的。"),
          .init(
            startMilliseconds: 4_000, endMilliseconds: 8_000,
            personID: PersonID(UUID(uuidString: lin)!),
            personName: nil, text: "那我周四去取货。"),
        ]),
      record(3, text: "开放日演示用 Twin-7 那台机器人。", source: "备忘录", hoursAgo: 4),
      record(4, text: "韩策：\(outside) 这件事只在实验室里说\n林晓：收到 \(outside)", source: "企业微信", hoursAgo: 1),
      record(5, text: "搬家公司 \(outside)，周六上午", source: "备忘录", hoursAgo: 6),
    ]
    func hours(_ value: Double) -> Date { now.addingTimeInterval(-value * 3_600) }
    let events = [
      MemoryEventSource(
        eventID: twin, origin: .spark, title: "Twin-7 真机实验", statusLine: "第三组数据周五前跑完",
        pinned: false, updatedAt: hours(2), itemIDs: [0, 1, 2].map { items[$0].uuidString },
        personIDs: [han, lin],
        statusFacts: MemoryStatusFact.ordered([
          fact("周五前跑完第三组", "planned", date: day(2), item: 0),
          fact("第一组已经跑完", "done", item: 1),
        ])),
      MemoryEventSource(
        eventID: openDay, origin: .spark, title: "开放日演示", statusLine: "演示脚本还差最后一段",
        pinned: false, updatedAt: hours(4), itemIDs: [items[3].uuidString], personIDs: [],
        statusFacts: [fact("开放日当天演示", "planned", date: day(5), item: 3)]),
      MemoryEventSource(
        eventID: labWeekly, origin: .spark, title: "实验室周会", statusLine: "下周二再对一次进度",
        pinned: false, updatedAt: hours(1), itemIDs: [items[4].uuidString], personIDs: [han],
        statusFacts: [fact("周二周会", "planned", date: day(1), item: 4)]),
      MemoryEventSource(
        eventID: moving, origin: .spark, title: "搬家", statusLine: "周六搬", pinned: false,
        updatedAt: hours(6), itemIDs: [items[5].uuidString], personIDs: [],
        statusFacts: [fact("周六搬家", "planned", date: day(3), item: 5)]),
    ]
    let persons = try JSONDecoder().decode(
      [RemoteOrganizerPerson].self,
      from: Data(
        """
        [{"person_id":"\(han)","display_name":"韩策","aliases":[],"origin":"spark"},
         {"person_id":"\(lin)","display_name":"林晓","aliases":[],"origin":"spark"}]
        """.utf8))
    let projection = MemoryProjection(events: events, records: records, persons: persons, now: now)
    return AgentMemorySnapshot(
      projection: projection,
      spaces: [.personal, AgentSpace(id: "lab", name: "实验室")],
      ropes: [
        AgentRope(id: "r-research", title: "科研", matterIDs: [twin]),
        AgentRope(id: "r-life", title: "生活", matterIDs: [moving]),
      ],
      spaceOfMatter: [labWeekly: "lab"], timeZone: timeZone)
  }
}

struct FixedMemory: AgentMemoryProviding {
  let snapshot: AgentMemorySnapshot?
  func agentSnapshot() async -> AgentMemorySnapshot? { snapshot }
}

/// The owner, by script. Answers are queued; a request with none queued
/// waits until one is.
actor ScriptedOwner: AgentConsentPresenting {
  private(set) var consentRequests: [AgentConsentRequest] = []
  private(set) var approvalRequests: [AgentMatterApprovalRequest] = []
  private(set) var proposals: [AgentInboxProposal] = []
  private(set) var changes = 0
  private var answers: [AgentConsentAnswer?] = []
  private var waiters: [CheckedContinuation<AgentConsentAnswer?, Never>] = []
  private var approvals: [[String: Bool]] = []
  private var approvalWaiters: [CheckedContinuation<[String: Bool], Never>] = []

  func queue(_ answer: AgentConsentAnswer?) {
    if waiters.isEmpty {
      answers.append(answer)
    } else {
      waiters.removeFirst().resume(returning: answer)
    }
  }

  func queueApproval(_ answer: [String: Bool]) {
    if approvalWaiters.isEmpty {
      approvals.append(answer)
    } else {
      approvalWaiters.removeFirst().resume(returning: answer)
    }
  }

  func requestConsent(_ request: AgentConsentRequest) async -> AgentConsentAnswer? {
    consentRequests.append(request)
    if !answers.isEmpty { return answers.removeFirst() }
    return await withCheckedContinuation { waiters.append($0) }
  }

  func approveMatters(_ request: AgentMatterApprovalRequest) async -> [String: Bool] {
    approvalRequests.append(request)
    if !approvals.isEmpty { return approvals.removeFirst() }
    return await withCheckedContinuation { approvalWaiters.append($0) }
  }

  func proposalArrived(_ proposal: AgentInboxProposal) async { proposals.append(proposal) }
  func accessChanged() async { changes += 1 }
  private(set) var recorded: [AgentAuditRecord] = []
  func accessRecorded(_ record: AgentAuditRecord) async { recorded.append(record) }
}

/// The library's agent tables, in memory.
actor MemoryAgentRecords: AgentAccessRecordStore {
  var grants: [AgentGrantRecord] = []
  var decisions: [UUID: [String: Bool]] = [:]
  var audit: [AgentAuditRecord] = []
  var inbox: [AgentInboxProposal] = []

  func agentGrants() async throws -> [AgentGrantRecord] { grants }
  func saveAgentGrant(_ grant: AgentGrantRecord) async throws {
    grants.removeAll { $0.grantID == grant.grantID }
    grants.append(grant)
  }
  func deleteAgentGrant(_ grantID: UUID) async throws {
    grants.removeAll { $0.grantID == grantID }
    decisions[grantID] = nil
  }
  func agentMatterDecisions(grantID: UUID) async throws -> [String: Bool] {
    decisions[grantID] ?? [:]
  }
  func recordAgentMatterDecision(grantID: UUID, matterID: String, allowed: Bool, at: Date)
    async throws
  {
    decisions[grantID, default: [:]][matterID] = allowed
  }
  func appendAgentAudit(_ record: AgentAuditRecord) async throws { audit.append(record) }
  func agentAudit(clientKey: String?, limit: Int) async throws -> [AgentAuditRecord] {
    Array(audit.filter { clientKey == nil || $0.clientKey == clientKey }.reversed().prefix(limit))
  }
  func addAgentProposal(_ proposal: AgentInboxProposal) async throws { inbox.append(proposal) }
  func agentProposals(includeDecided: Bool) async throws -> [AgentInboxProposal] {
    inbox.filter { includeDecided || $0.state == .pending }
  }
  func resolveAgentProposal(
    _ proposalID: UUID, state: AgentInboxProposal.State, itemID: SessionID?, at: Date
  ) async throws {}

  func tamperFirstGrant() {
    guard let grant = grants.first else { return }
    grants[0] = AgentGrantRecord(
      grantID: grant.grantID, clientKey: grant.clientKey, clientName: grant.clientName,
      clientPath: grant.clientPath,
      terms: AgentGrantTerms(
        spaces: ["personal", "lab"], range: .all, duration: grant.terms.duration),
      createdAt: grant.createdAt, expiresAt: grant.expiresAt, mac: grant.mac)
  }
}

final class MutableClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  init(_ value: Date) { self.value = value }
  var now: Date { lock.withLock { value } }
  func advance(_ seconds: TimeInterval) {
    lock.withLock { value = value.addingTimeInterval(seconds) }
  }
}

/// One MCP session against the service, with helpers to read results.
struct AgentTestClient {
  let service: AgentAccessService
  let session: UUID
  private static let counter = Counter()

  /// The test client stands for Claude Code as shipped: a binary signed by
  /// its developer team (`signer`), so its version folder is folded.
  static let claudeSigner = "team:TESTTEAM01:com.anthropic.claude-code"

  init(
    service: AgentAccessService, name: String = "claude-code",
    path: String = "/Users/test/.local/share/claude/versions/2.1.260",
    signer: String? = AgentTestClient.claudeSigner, script: String? = nil
  ) async {
    self.service = service
    session = await service.openSession(
      peer: AgentConnectionPeer(
        pid: 4242, uid: getuid(), clientExecutablePath: path, clientSigner: signer,
        clientScript: script))
    _ = await request(
      "initialize",
      [
        "protocolVersion": "2025-06-18", "capabilities": [:],
        "clientInfo": ["name": .string(name), "version": "test"],
      ])
  }

  func request(_ method: String, _ params: JSONValue? = nil) async -> JSONValue {
    let id = JSONValue.int(Int64(Self.counter.next()))
    let reply = await service.handle(
      .request(id: id, method: method, params: params), session: session)
    return reply ?? .null
  }

  func call(_ tool: String, _ arguments: JSONValue = [:]) async -> JSONValue {
    await request("tools/call", ["name": .string(tool), "arguments": arguments])["result"] ?? .null
  }

  func close() async { await service.closeSession(session) }
}

final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func next() -> Int {
    lock.withLock {
      value += 1
      return value
    }
  }
}

extension JSONValue {
  var text: String {
    (self["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined()
  }
  var isErrorResult: Bool { self["isError"]?.boolValue == true }
  var errorCode: String? { self["structuredContent"]?["error"]?.stringValue }
  var matterIDs: [String] {
    (self["structuredContent"]?["matters"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
  }
}

func allowAll(
  spaces: Set<String> = ["personal"], range: AgentScopeRange = .all, propose: Bool = false,
  duration: AgentGrantDuration = .always, numbers: Bool = false, ask: Bool = false
) -> AgentConsentAnswer {
  .allow(
    AgentGrantTerms(
      spaces: spaces, range: range, canPropose: propose, duration: duration, showNumbers: numbers,
      askForNewMatters: ask))
}
