import BestASRDomain
import BestASRMemory
import Foundation
import MindloomAgentProtocol

/// The App's MCP server behind the helper (AGENT-CONTRACT §1–§2). One
/// session per helper connection. Every tool call and resource read is
/// checked against the client's grant on that call (so a revocation or an
/// expiry takes effect on the next call), answered within the grant's scope
/// with numbers masked unless the grant says 原样, and written to the audit
/// (never content). An unknown client gets the consent sheet; a denial is a
/// clear MCP error. `add_to_inbox` only ever proposes: this service cannot
/// create an item at all.
public actor AgentAccessService {
  public struct Configuration: Sendable {
    /// How long a call waits for the owner in the consent sheet or a
    /// matter approval before it returns "等主人批准" (the sheet stays open;
    /// a later answer still counts).
    public var consentTimeout: Duration
    /// After 不同意, the same client is refused without asking again for
    /// this long (and for the rest of the session).
    public var denialCooldown: TimeInterval

    public init(consentTimeout: Duration = .seconds(60), denialCooldown: TimeInterval = 60) {
      self.consentTimeout = consentTimeout
      self.denialCooldown = denialCooldown
    }
  }

  /// A grant as the Settings page lists it.
  public struct GrantSummary: Equatable, Sendable, Identifiable {
    public let grantID: UUID
    public let clientKey: String
    public let clientName: String
    public let clientPath: String
    public let terms: AgentGrantTerms
    public let createdAt: Date
    public let expiresAt: Date?
    public var id: UUID { grantID }
  }

  private struct Session {
    let id: UUID
    let peer: AgentConnectionPeer
    var clientName = "unknown"
    var clientTitle: String?
    var once: OnceGrant?
    var denied = false

    var identity: AgentClientIdentity {
      AgentClientIdentity(
        name: clientName, title: clientTitle, path: peer.clientExecutablePath ?? "unknown",
        signer: peer.clientSigner, script: peer.clientScript)
    }
  }

  /// 这一次: kept in memory for its connection only.
  private struct OnceGrant {
    let grantID: UUID
    let terms: AgentGrantTerms
    let maskKey: Data
    let createdAt: Date
    var decisions: [String: Bool] = [:]
  }

  private struct ActiveGrant {
    let grantID: UUID
    let terms: AgentGrantTerms
    let maskKey: Data
    let isOnce: Bool
  }

  private enum Authorization {
    case granted(ActiveGrant)
    case denied
    case pending
    case unavailable
  }

  private let memory: any AgentMemoryProviding
  private let records: any AgentAccessRecordStore
  private let secrets: any AgentGrantSecretStore
  private let consent: any AgentConsentPresenting
  private let configuration: Configuration
  private let clock: @Sendable () -> Date
  private let timeZone: TimeZone
  private var sessions: [UUID: Session] = [:]
  private var consentTasks: [String: Task<AgentConsentAnswer?, Never>] = [:]
  private var approvalTasks: [String: Task<[String: Bool], Never>] = [:]
  private var deniedAt: [String: Date] = [:]

  public init(
    memory: any AgentMemoryProviding, records: any AgentAccessRecordStore,
    secrets: any AgentGrantSecretStore, consent: any AgentConsentPresenting,
    configuration: Configuration = Configuration(), timeZone: TimeZone = .current,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.memory = memory
    self.records = records
    self.secrets = secrets
    self.consent = consent
    self.configuration = configuration
    self.timeZone = timeZone
    self.clock = clock
  }

  // MARK: - Sessions

  public func openSession(peer: AgentConnectionPeer) -> UUID {
    let id = UUID()
    sessions[id] = Session(id: id, peer: peer)
    return id
  }

  public func closeSession(_ id: UUID) async {
    let hadOnce = sessions[id]?.once != nil
    sessions[id] = nil
    if hadOnce { await consent.accessChanged() }
  }

  /// The reply line for one incoming line (nil for a notification).
  public func handle(line: String, session: UUID) async -> String? {
    await handle(MCPMessage.decode(line), session: session)?.serialized
  }

  public func handle(_ message: MCPMessage, session sessionID: UUID) async -> JSONValue? {
    guard sessions[sessionID] != nil else {
      if case .request(let id, _, _) = message {
        return MCPMessage.error(id: id, code: MCPErrorCode.internalError, message: "No session")
      }
      return nil
    }
    switch message {
    case .invalid(let id, let code, let text):
      return MCPMessage.error(id: id, code: code, message: text)
    case .notification, .response, .errorResponse:
      return nil
    case .request(let id, let method, let params):
      switch method {
      case "initialize":
        let info = params?["clientInfo"]
        sessions[sessionID]?.clientName = info?["name"]?.stringValue ?? "unknown"
        sessions[sessionID]?.clientTitle = info?["title"]?.stringValue
        return MCPMessage.result(
          id: id,
          MCPServerInfo.initializeResult(requestedVersion: params?["protocolVersion"]?.stringValue))
      case "ping":
        return MCPMessage.result(id: id, [:])
      case "tools/list":
        return MCPMessage.result(id: id, AgentTool.listResult)
      case "resources/templates/list":
        return MCPMessage.result(id: id, AgentResource.templatesResult)
      case "tools/call":
        return await callTool(id: id, params: params, session: sessionID)
      case "resources/list":
        return await listResources(id: id, session: sessionID)
      case "resources/read":
        return await readResource(id: id, params: params, session: sessionID)
      default:
        return MCPMessage.error(
          id: id, code: MCPErrorCode.methodNotFound, message: "Method not found")
      }
    }
  }

  // MARK: - Tools

  private func callTool(id: JSONValue, params: JSONValue?, session: UUID) async -> JSONValue {
    guard let name = params?["name"]?.stringValue, let tool = AgentTool(rawValue: name) else {
      await audit(
        session: session, grant: nil, tool: "tools/call", outcome: .invalid, ids: [], bytes: 0)
      return MCPMessage.error(id: id, code: MCPErrorCode.invalidParams, message: "Unknown tool")
    }
    let arguments = params?["arguments"]?.objectValue ?? [:]
    let output: AgentToolOutput
    var grantID: UUID?
    switch await authorize(session: session) {
    case .denied:
      output = .failure(AgentCopy.denied, code: "denied", outcome: .denied)
    case .pending:
      output = .failure(AgentCopy.pending, code: "pending", outcome: .pending)
    case .unavailable:
      output = .failure(AgentCopy.unavailable, code: "unavailable", outcome: .failed)
    case .granted(let grant):
      grantID = grant.grantID
      let answer = await run(tool, arguments: arguments, grant: grant, session: session)
      // A call may have waited for the owner; a grant revoked meanwhile wins (V7-A5).
      output =
        await stillGranted(grant, session: session)
        ? answer : .failure(AgentCopy.denied, code: "denied", outcome: .denied)
    }
    let result = output.result
    await audit(
      session: session, grant: grantID, tool: tool.rawValue, outcome: output.outcome,
      ids: output.matterIDs, bytes: result.serializedData.count)
    return MCPMessage.result(id: id, result)
  }

  private func run(
    _ tool: AgentTool, arguments: [String: JSONValue], grant: ActiveGrant, session: UUID
  ) async -> AgentToolOutput {
    if tool == .addToInbox {
      return await propose(arguments: arguments, grant: grant, session: session)
    }
    guard let snapshot = await memory.agentSnapshot() else {
      return .failure(AgentCopy.unavailable, code: "unavailable", outcome: .failed)
    }
    let reader = reader(snapshot, grant: grant)
    switch tool {
    case .searchMatters:
      guard let query = text(arguments["query"], max: AgentTool.maximumQueryCharacters),
        !query.isEmpty
      else { return invalid("query 需要 1–\(AgentTool.maximumQueryCharacters) 个字") }
      guard !reader.mask.hides(query) else {
        // Numbers are masked for this agent: it cannot search by one either.
        return invalid(AgentCopy.numberQueryRefused)
      }
      guard
        let limit = integer(
          arguments["limit"], in: 1...AgentTool.maximumSearchLimit,
          default: AgentTool.defaultSearchLimit)
      else { return invalid("limit 需要在 1–\(AgentTool.maximumSearchLimit) 之间") }
      let space = arguments["space"]?.stringValue.map(AgentSpaceID.normalized)
      let matched = reader.search(query: query, space: space)
      let candidates = Array(matched.prefix(limit))
      let (allowed, waiting) = await approved(
        candidates.map(\.eventID), snapshot: snapshot, grant: grant, session: session)
      let shown = candidates.filter { allowed.contains($0.eventID) }
      // With "ask me first", matters the owner refused are not even counted (V7-A4).
      let total = grant.terms.askForNewMatters ? shown.count : matched.count
      return reader.renderSearch(shown, matched: total, waiting: waiting)
    case .getMatter:
      guard let matterID = text(arguments["id"], max: 128), !matterID.isEmpty else {
        return invalid("id 不能为空")
      }
      let format = arguments["format"]?.stringValue ?? "text"
      guard format == "text" || format == "json" else { return invalid("format 只能是 text 或 json") }
      return await matter(
        matterID, json: format == "json", reader: reader, grant: grant, session: session)
    case .listDeadlines:
      guard
        let days = integer(
          arguments["days"], in: 1...AgentTool.maximumDeadlineDays,
          default: AgentTool.defaultDeadlineDays)
      else { return invalid("days 需要在 1–\(AgentTool.maximumDeadlineDays) 之间") }
      let deadlines = reader.deadlines(days: days)
      let ids = orderedUnique(deadlines.map(\.entry.eventID))
      let (allowed, waiting) = await approved(
        ids, snapshot: snapshot, grant: grant, session: session)
      return reader.renderDeadlines(
        deadlines.filter { allowed.contains($0.entry.eventID) }, days: days, waiting: waiting)
    case .listRecent:
      guard
        let days = integer(
          arguments["days"], in: 1...AgentTool.maximumRecentDays,
          default: AgentTool.defaultRecentDays)
      else { return invalid("days 需要在 1–\(AgentTool.maximumRecentDays) 之间") }
      let space = arguments["space"]?.stringValue.map(AgentSpaceID.normalized)
      let entries = reader.recent(days: days, space: space)
      let (allowed, waiting) = await approved(
        entries.map(\.eventID), snapshot: snapshot, grant: grant, session: session)
      return reader.renderRecent(
        entries.filter { allowed.contains($0.eventID) }, days: days, waiting: waiting)
    case .getPerson:
      guard let name = text(arguments["name"], max: AgentTool.maximumPersonNameCharacters),
        !name.isEmpty
      else { return invalid("name 不能为空") }
      guard let found = reader.person(named: name) else {
        return .failure(AgentCopy.personNotFound, code: "not_found", outcome: .notFound)
      }
      let (person, matters) = found
      let (allowed, waiting) = await approved(
        matters.map(\.eventID), snapshot: snapshot, grant: grant, session: session)
      let shown = matters.filter { allowed.contains($0.eventID) }
      guard !shown.isEmpty else {
        // The same answer whether the person's matters wait for the owner or
        // were refused: no hint that the person is in matters not granted
        // (V7-A4). The owner still got the approval request.
        return .failure(AgentCopy.personNotFound, code: "not_found", outcome: .notFound)
      }
      return reader.renderPerson(
        person, matters: shown, quotes: reader.quotes(of: person, in: shown), waiting: waiting)
    case .addToInbox:
      return invalid("")
    }
  }

  private func matter(
    _ matterID: String, json: Bool, reader: AgentReader, grant: ActiveGrant, session: UUID
  ) async -> AgentToolOutput {
    // Outside the grant is the same answer as not existing.
    guard let entry = reader.entry(matterID), let detail = reader.detail(entry.eventID) else {
      return .failure(AgentCopy.notFound, code: "not_found", outcome: .notFound)
    }
    let (allowed, waiting) = await approved(
      [entry.eventID], snapshot: reader.snapshot, grant: grant, session: session)
    guard allowed.contains(entry.eventID) else {
      return waiting > 0
        ? .failure(AgentCopy.pending, code: "pending", outcome: .pending)
        : .failure("主人没有同意这个 Agent 读这件事。", code: "denied", outcome: .denied)
    }
    return reader.renderMatter(detail, json: json)
  }

  private func propose(
    arguments: [String: JSONValue], grant: ActiveGrant, session: UUID
  ) async -> AgentToolOutput {
    guard grant.terms.canPropose else {
      return .failure(AgentCopy.proposeNotAllowed, code: "read_only", outcome: .denied)
    }
    guard
      let body = text(
        arguments["text"], max: AgentTool.maximumInboxTextCharacters, keepLines: true),
      !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return invalid("text 需要 1–\(AgentTool.maximumInboxTextCharacters) 个字") }
    guard let title = text(arguments["title"] ?? "", max: AgentTool.maximumInboxTitleCharacters),
      let hint = text(arguments["matter_hint"] ?? "", max: AgentTool.maximumMatterHintCharacters)
    else {
      return invalid(
        "title 最多 \(AgentTool.maximumInboxTitleCharacters) 个字，matter_hint 最多 \(AgentTool.maximumMatterHintCharacters) 个字"
      )
    }
    guard let identity = sessions[session]?.identity else {
      return .failure(AgentCopy.unavailable, code: "unavailable", outcome: .failed)
    }
    let proposal = AgentInboxProposal(
      clientKey: identity.key, clientName: identity.displayName, createdAt: clock(),
      title: title, text: body, matterHint: hint)
    do {
      try await records.addAgentProposal(proposal)
    } catch {
      return .failure(AgentCopy.unavailable, code: "unavailable", outcome: .failed)
    }
    await consent.proposalArrived(proposal)
    let id = proposal.proposalID.uuidString.lowercased()
    return AgentToolOutput(
      text: AgentCopy.proposed + "（建议 id：\(id)）",
      structured: ["proposal_id": .string(id), "state": "pending"], matterIDs: [])
  }

  // MARK: - Resources

  private func listResources(id: JSONValue, session: UUID) async -> JSONValue {
    switch await authorize(session: session) {
    case .granted(let grant):
      guard let snapshot = await memory.agentSnapshot() else {
        await audit(
          session: session, grant: grant.grantID, tool: "resources/list", outcome: .failed, ids: [],
          bytes: 0)
        return MCPMessage.error(
          id: id, code: MCPErrorCode.internalError, message: AgentCopy.unavailable)
      }
      let reader = reader(snapshot, grant: grant)
      var entries = reader.byRecency
      if grant.terms.askForNewMatters {
        // Listing does not ask: it names only matters already approved.
        let decisions = await decisions(grant: grant, session: session)
        entries = entries.filter { decisions[$0.eventID.uppercased()] == true }
      }
      entries = Array(entries.prefix(AgentResource.maximumListed))
      let result = reader.resourceList(entries)
      await audit(
        session: session, grant: grant.grantID, tool: "resources/list", outcome: .allowed,
        ids: entries.map(\.eventID), bytes: result.serializedData.count)
      return MCPMessage.result(id: id, result)
    case .denied:
      await audit(
        session: session, grant: nil, tool: "resources/list", outcome: .denied, ids: [], bytes: 0)
      return MCPMessage.error(id: id, code: MCPErrorCode.notAllowed, message: AgentCopy.denied)
    case .pending:
      await audit(
        session: session, grant: nil, tool: "resources/list", outcome: .pending, ids: [], bytes: 0)
      return MCPMessage.error(id: id, code: MCPErrorCode.notAllowed, message: AgentCopy.pending)
    case .unavailable:
      await audit(
        session: session, grant: nil, tool: "resources/list", outcome: .failed, ids: [], bytes: 0)
      return MCPMessage.error(
        id: id, code: MCPErrorCode.internalError, message: AgentCopy.unavailable)
    }
  }

  private func readResource(id: JSONValue, params: JSONValue?, session: UUID) async -> JSONValue {
    guard let uri = params?["uri"]?.stringValue, let matterID = AgentResource.matterID(from: uri)
    else {
      await audit(
        session: session, grant: nil, tool: "resources/read", outcome: .invalid, ids: [], bytes: 0)
      return MCPMessage.error(
        id: id, code: MCPErrorCode.resourceNotFound, message: AgentCopy.notFound)
    }
    let output: AgentToolOutput
    var grantID: UUID?
    switch await authorize(session: session) {
    case .granted(let grant):
      grantID = grant.grantID
      if let snapshot = await memory.agentSnapshot() {
        let answer = await matter(
          matterID, json: false, reader: reader(snapshot, grant: grant), grant: grant,
          session: session)
        output =
          await stillGranted(grant, session: session)
          ? answer : .failure(AgentCopy.denied, code: "denied", outcome: .denied)
      } else {
        output = .failure(AgentCopy.unavailable, code: "unavailable", outcome: .failed)
      }
    case .denied: output = .failure(AgentCopy.denied, code: "denied", outcome: .denied)
    case .pending: output = .failure(AgentCopy.pending, code: "pending", outcome: .pending)
    case .unavailable:
      output = .failure(AgentCopy.unavailable, code: "unavailable", outcome: .failed)
    }
    guard !output.isError else {
      await audit(
        session: session, grant: grantID, tool: "resources/read", outcome: output.outcome, ids: [],
        bytes: 0)
      let code =
        output.outcome == .notFound
        ? MCPErrorCode.resourceNotFound
        : output.outcome == .failed ? MCPErrorCode.internalError : MCPErrorCode.notAllowed
      return MCPMessage.error(id: id, code: code, message: output.text)
    }
    let result: JSONValue = [
      "contents": [
        [
          "uri": .string(uri), "mimeType": .string(AgentResource.mimeType),
          "text": .string(output.text),
        ]
      ]
    ]
    await audit(
      session: session, grant: grantID, tool: "resources/read", outcome: .allowed,
      ids: output.matterIDs, bytes: result.serializedData.count)
    return MCPMessage.result(id: id, result)
  }

  // MARK: - Grants

  private func authorize(session sessionID: UUID) async -> Authorization {
    guard let session = sessions[sessionID] else { return .denied }
    let identity = session.identity
    if let once = session.once {
      return .granted(
        ActiveGrant(grantID: once.grantID, terms: once.terms, maskKey: once.maskKey, isOnce: true))
    }
    switch await storedGrant(for: identity) {
    case .some(.some(let grant)): return .granted(grant)
    case .none: return .unavailable
    case .some(.none): break
    }
    if session.denied { return .denied }
    if let refused = deniedAt[identity.key],
      clock().timeIntervalSince(refused) < configuration.denialCooldown
    {
      sessions[sessionID]?.denied = true
      return .denied
    }
    let task = consentTask(for: identity, session: sessionID)
    guard let answer = await waitWithTimeout(task) else {
      return sessions[sessionID]?.denied == true ? .denied : .pending
    }
    switch answer {
    case .none, .some(.deny):
      return .denied
    case .some(.allow):
      if let once = sessions[sessionID]?.once {
        return .granted(
          ActiveGrant(grantID: once.grantID, terms: once.terms, maskKey: once.maskKey, isOnce: true)
        )
      }
      switch await storedGrant(for: identity) {
      case .some(.some(let grant)): return .granted(grant)
      case .none: return .unavailable
      case .some(.none): return .pending
      }
    }
  }

  /// The grant a call started under is still the client's (not revoked, not
  /// expired, not replaced) after the call waited.
  private func stillGranted(_ grant: ActiveGrant, session: UUID) async -> Bool {
    guard let current = sessions[session] else { return false }
    if grant.isOnce { return current.once?.grantID == grant.grantID }
    if case .some(.some(let stored)) = await storedGrant(for: current.identity) {
      return stored.grantID == grant.grantID
    }
    return false
  }

  /// `.some(grant)` when a valid stored grant exists, `.some(nil)` when none
  /// does, nil when the store or the Keychain cannot be read (fail closed).
  private func storedGrant(for identity: AgentClientIdentity) async -> ActiveGrant?? {
    let all: [AgentGrantRecord]
    do { all = try await records.agentGrants() } catch { return nil }
    let now = clock()
    for record in all where record.clientKey == identity.key {
      if let expiry = record.expiresAt, expiry <= now {
        await removeGrant(record.grantID)
        continue
      }
      let secret: Data?
      do { secret = try secrets.secret(for: record.grantID) } catch { return nil }
      guard let secret else {
        // The secret is gone (revoked from the Keychain): the row is no grant.
        await removeGrant(record.grantID)
        continue
      }
      guard AgentGrantSecret.mac(record.canonicalText, secret: secret) == record.mac else {
        await removeGrant(record.grantID)
        continue
      }
      return .some(
        ActiveGrant(
          grantID: record.grantID, terms: record.terms,
          maskKey: AgentGrantSecret.maskKey(secret: secret), isOnce: false))
    }
    return .some(nil)
  }

  private func consentTask(for identity: AgentClientIdentity, session: UUID)
    -> Task<AgentConsentAnswer?, Never>
  {
    if let existing = consentTasks[identity.key] { return existing }
    let presenter = consent
    let memory = memory
    let now = clock()
    let task = Task<AgentConsentAnswer?, Never> { [weak self] in
      let snapshot = await memory.agentSnapshot()
      let options = AgentConsentOptions(
        spaces: snapshot?.spaces ?? [.personal], ropes: snapshot?.ropes ?? [],
        matters: (snapshot?.projection.home() ?? []).prefix(60).map {
          AgentMatterOption(id: $0.eventID, title: $0.title)
        })
      let answer = await presenter.requestConsent(
        AgentConsentRequest(client: identity, options: options, requestedAt: now))
      await self?.apply(answer, identity: identity, session: session)
      return answer
    }
    consentTasks[identity.key] = task
    return task
  }

  private func apply(_ answer: AgentConsentAnswer?, identity: AgentClientIdentity, session: UUID)
    async
  {
    consentTasks[identity.key] = nil
    switch answer {
    case .none, .some(.deny):
      deniedAt[identity.key] = clock()
      for (id, candidate) in sessions where candidate.identity.key == identity.key {
        sessions[id]?.denied = true
      }
    case .some(.allow(let terms)):
      deniedAt[identity.key] = nil
      do {
        try await createGrant(terms: terms, identity: identity, session: session)
      } catch {
        // Nothing half-made stays: the next call asks again.
      }
    }
    await consent.accessChanged()
  }

  private func createGrant(terms: AgentGrantTerms, identity: AgentClientIdentity, session: UUID)
    async throws
  {
    let secret = try AgentGrantSecret.random()
    let now = clock()
    let grantID = UUID()
    if terms.duration == .once {
      sessions[session]?.once = OnceGrant(
        grantID: grantID, terms: terms, maskKey: AgentGrantSecret.maskKey(secret: secret),
        createdAt: now)
      return
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let expiry =
      terms.duration == .today
      ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) : nil
    // One stored grant per client: a new consent replaces an old one.
    for old in (try? await records.agentGrants()) ?? [] where old.clientKey == identity.key {
      await removeGrant(old.grantID)
    }
    var record = AgentGrantRecord(
      grantID: grantID, clientKey: identity.key, clientName: identity.displayName,
      clientPath: identity.path, terms: terms, createdAt: now, expiresAt: expiry, mac: "")
    record.mac = AgentGrantSecret.mac(record.canonicalText, secret: secret)
    try secrets.save(secret, for: grantID)
    do {
      try await records.saveAgentGrant(record)
    } catch {
      try? secrets.delete(for: grantID)
      throw error
    }
  }

  private func removeGrant(_ grantID: UUID) async {
    try? secrets.delete(for: grantID)
    try? await records.deleteAgentGrant(grantID)
  }

  /// The task's value, or nil when it takes longer than the consent
  /// timeout. The task itself keeps running (the owner may answer later).
  private func waitWithTimeout<T: Sendable>(_ task: Task<T, Never>) async -> T? {
    let timeout = configuration.consentTimeout
    let gate = ResumeOnce<T?>()
    return await withCheckedContinuation { continuation in
      gate.arm(continuation)
      Task { gate.resume(await task.value) }
      Task {
        try? await Task.sleep(for: timeout)
        gate.resume(nil)
      }
    }
  }

  // MARK: - Per-matter approval

  private func decisions(grant: ActiveGrant, session: UUID) async -> [String: Bool] {
    if grant.isOnce { return sessions[session]?.once?.decisions ?? [:] }
    let stored = (try? await records.agentMatterDecisions(grantID: grant.grantID)) ?? [:]
    var result: [String: Bool] = [:]
    for (key, value) in stored { result[key.uppercased()] = value }
    return result
  }

  /// The matters the grant may return now, and how many wait for the owner.
  private func approved(
    _ matterIDs: [String], snapshot: AgentMemorySnapshot, grant: ActiveGrant, session: UUID
  ) async -> (Set<String>, Int) {
    guard grant.terms.askForNewMatters, !matterIDs.isEmpty else { return (Set(matterIDs), 0) }
    var known = await decisions(grant: grant, session: session)
    let fresh = orderedUnique(matterIDs.filter { known[$0.uppercased()] == nil })
    if !fresh.isEmpty, let identity = sessions[session]?.identity {
      let titles = Dictionary(
        snapshot.projection.home().map { ($0.eventID.uppercased(), $0.title) },
        uniquingKeysWith: { first, _ in first })
      let request = AgentMatterApprovalRequest(
        client: identity,
        matters: fresh.map { AgentMatterOption(id: $0, title: titles[$0.uppercased()] ?? $0) })
      let key =
        grant.grantID.uuidString + "|"
        + fresh.map { $0.uppercased() }.sorted().joined(separator: ",")
      let task: Task<[String: Bool], Never>
      if let existing = approvalTasks[key] {
        task = existing
      } else {
        let presenter = consent
        let grantCopy = grant
        task = Task { [weak self] in
          let answers = await presenter.approveMatters(request)
          await self?.record(answers, grant: grantCopy, session: session, key: key)
          return answers
        }
        approvalTasks[key] = task
      }
      if let answers = await waitWithTimeout(task) {
        for (id, allowed) in answers { known[id.uppercased()] = allowed }
      }
    }
    let allowed = Set(matterIDs.filter { known[$0.uppercased()] == true })
    let waiting = orderedUnique(matterIDs).filter { known[$0.uppercased()] == nil }.count
    return (allowed, waiting)
  }

  private func record(_ answers: [String: Bool], grant: ActiveGrant, session: UUID, key: String)
    async
  {
    approvalTasks[key] = nil
    let now = clock()
    if grant.isOnce {
      for (id, allowed) in answers { sessions[session]?.once?.decisions[id.uppercased()] = allowed }
    } else {
      for (id, allowed) in answers {
        try? await records.recordAgentMatterDecision(
          grantID: grant.grantID, matterID: id.uppercased(), allowed: allowed, at: now)
      }
    }
    await consent.accessChanged()
  }

  // MARK: - Management (Settings → Agent)

  public func grants() async -> [GrantSummary] {
    var result: [GrantSummary] = []
    for session in sessions.values {
      guard let once = session.once else { continue }
      let identity = session.identity
      result.append(
        GrantSummary(
          grantID: once.grantID, clientKey: identity.key, clientName: identity.displayName,
          clientPath: identity.path, terms: once.terms, createdAt: once.createdAt, expiresAt: nil))
    }
    let now = clock()
    for record in (try? await records.agentGrants()) ?? [] {
      if let expiry = record.expiresAt, expiry <= now { continue }
      result.append(
        GrantSummary(
          grantID: record.grantID, clientKey: record.clientKey, clientName: record.clientName,
          clientPath: record.clientPath, terms: record.terms, createdAt: record.createdAt,
          expiresAt: record.expiresAt))
    }
    return result.sorted { $0.createdAt > $1.createdAt }
  }

  /// 撤销: the secret and the scope record go; the next call from that
  /// client finds no grant.
  public func revoke(_ grantID: UUID) async {
    for (id, session) in sessions where session.once?.grantID == grantID {
      sessions[id]?.once = nil
    }
    await removeGrant(grantID)
    await consent.accessChanged()
  }

  // MARK: - Helpers

  private func reader(_ snapshot: AgentMemorySnapshot, grant: ActiveGrant) -> AgentReader {
    let terms = grant.terms
    let inScope: (String) -> Bool = { matterID in
      guard terms.spaces.contains(snapshot.space(of: matterID)) else { return false }
      switch terms.range {
      case .all:
        return true
      case .matters(let ids):
        return ids.contains { $0.caseInsensitiveCompare(matterID) == .orderedSame }
      case .ropes(let ids):
        return snapshot.ropeChain(of: matterID).contains { ids.contains($0.id) }
      }
    }
    let masker = terms.showNumbers ? nil : try? PrivacyMasker(maskKey: grant.maskKey)
    var reader = AgentReader(
      snapshot: snapshot, inScope: inScope, mask: AgentTextMask(masker: masker))
    // A split recording names its other matters only when they are in scope,
    // and never when each new matter first waits for the owner (V7-A1).
    reader.showSibling = terms.askForNewMatters ? { _ in false } : inScope
    return reader
  }

  private func audit(
    session: UUID, grant: UUID?, tool: String, outcome: AgentAuditOutcome, ids: [String], bytes: Int
  ) async {
    let identity =
      sessions[session]?.identity ?? AgentClientIdentity(name: "unknown", path: "unknown")
    let record = AgentAuditRecord(
      at: clock(), clientKey: identity.key, clientName: identity.displayName, grantID: grant,
      tool: tool, outcome: outcome, matterIDs: ids, byteCount: bytes)
    try? await records.appendAgentAudit(record)
    await consent.accessRecorded(record)
    await consent.accessChanged()
  }

  private func invalid(_ message: String) -> AgentToolOutput {
    .failure(message.isEmpty ? "参数不对" : message, code: "invalid_arguments", outcome: .invalid)
  }

  /// A string argument, trimmed, without control characters (line breaks
  /// kept when asked); nil when it is not a string or too long.
  private func text(_ value: JSONValue?, max: Int, keepLines: Bool = false) -> String? {
    guard let raw = value?.stringValue else { return nil }
    let allowed = keepLines ? CharacterSet(charactersIn: "\n\t") : CharacterSet()
    let scalars = raw.unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0) || allowed.contains($0)
    }
    let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(
      in: keepLines ? .whitespacesAndNewlines : .whitespaces)
    return cleaned.count <= max ? cleaned : nil
  }

  private func integer(_ value: JSONValue?, in range: ClosedRange<Int>, default fallback: Int)
    -> Int?
  {
    guard let value, value != .null else { return fallback }
    guard let number = value.intValue, range.contains(Int(number)) else { return nil }
    return Int(number)
  }

  private func orderedUnique(_ ids: [String]) -> [String] {
    var seen = Set<String>()
    return ids.filter { seen.insert($0.uppercased()).inserted }
  }
}

/// Resumes a continuation exactly once, whichever side comes first.
final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Never>?
  private var early: Value?
  private var done = false

  func arm(_ continuation: CheckedContinuation<Value, Never>) {
    lock.lock()
    if done, let early {
      lock.unlock()
      continuation.resume(returning: early)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  func resume(_ value: Value) {
    lock.lock()
    guard !done else {
      lock.unlock()
      return
    }
    done = true
    if let continuation {
      self.continuation = nil
      lock.unlock()
      continuation.resume(returning: value)
    } else {
      early = value
      lock.unlock()
    }
  }
}
