import BestASRDomain
import BestASRMemory
import Foundation
import MindloomAgentProtocol

/// The App's MCP server behind the helper (AGENT-CONTRACT §1–§2; v12 phase B,
/// B5 appendix C F1–F13). One session per helper connection. Every tool call
/// and resource read is checked against the client's grant on that call (so
/// a revocation or an expiry takes effect on the next call), answered within
/// the grant's scope with numbers masked unless the grant says 原样, inside a
/// fence made fresh for each answer, counted against the grant's hourly
/// limits, and written to the audit (never content). An unknown client gets
/// the consent card; a denial is a clear MCP error.
///
/// Agent-tool practice (AGENT-TOOLS.md): the hourly content quota counts the
/// bytes of library text an answer gives (reads and searches), not the
/// resource list; `resources/list` gives nothing before a grant, then pages
/// of titles and ids, each page audited and counted against its own limit.
///
/// Reading is the default. A grant with 也可以改 also lists and runs four
/// change tools (add a note, move an item or take it out, rename a matter,
/// mark a step); each is applied at once through the App
/// (`AgentChangeApplying`), recorded in `agent_changes` and undoable from the
/// Mac. Nothing here deletes, shares, exports, records or changes settings.
public actor AgentAccessService {
  /// Per grant, per rolling hour (v12 F7; B5 B6's suggested values).
  /// `bytesPerHour` counts the content bytes reads and searches return (the
  /// UTF-8 text the agent's model reads); `listingsPerHour` counts
  /// `resources/list` pages, which use no content quota.
  public struct Limits: Sendable, Equatable {
    public var mattersPerHour: Int
    public var bytesPerHour: Int
    public var notesPerHour: Int
    public var changesPerHour: Int
    public var listingsPerHour: Int
    public var window: TimeInterval

    public init(
      mattersPerHour: Int = 40, bytesPerHour: Int = 200_000, notesPerHour: Int = 30,
      changesPerHour: Int = 15, listingsPerHour: Int = 40, window: TimeInterval = 3_600
    ) {
      self.mattersPerHour = mattersPerHour
      self.bytesPerHour = bytesPerHour
      self.notesPerHour = notesPerHour
      self.changesPerHour = changesPerHour
      self.listingsPerHour = listingsPerHour
      self.window = window
    }
  }

  public struct Configuration: Sendable {
    /// How long a call waits for the owner in the consent card or a
    /// matter approval before it returns "等主人批准" (the card stays open;
    /// a later answer still counts).
    public var consentTimeout: Duration
    /// After 不允许, the same client is refused without asking again for
    /// this long (and for the rest of the session).
    public var denialCooldown: TimeInterval
    public var limits: Limits
    /// `resources/list`: matters a page, and over all pages.
    public var listPageSize: Int
    public var listMaximum: Int

    public init(
      consentTimeout: Duration = .seconds(60), denialCooldown: TimeInterval = 60,
      limits: Limits = Limits(), listPageSize: Int = AgentResource.pageSize,
      listMaximum: Int = AgentResource.maximumListed
    ) {
      self.consentTimeout = consentTimeout
      self.denialCooldown = denialCooldown
      self.limits = limits
      self.listPageSize = max(1, listPageSize)
      self.listMaximum = max(0, listMaximum)
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
    /// Writes a line to the client on the service's own (a notification).
    var push: (@Sendable (String) -> Void)?
    /// Whether the last `tools/list` it got had the change tools; nil before
    /// it asked.
    var listedChanges: Bool?

    var identity: AgentClientIdentity {
      AgentClientIdentity(
        name: clientName, title: clientTitle, path: peer.clientExecutablePath ?? "unknown",
        signer: peer.clientSigner, script: peer.clientScript, signerName: peer.clientSignerName)
    }
  }

  /// 这次对话 (这一次): kept in memory for its connection only.
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

  /// One grant's use in the rolling hour.
  private struct Usage {
    var reads: [(at: Date, matters: Int, bytes: Int)] = []
    var notes: [Date] = []
    var changes: [Date] = []
    /// `resources/list` pages (titles and ids; no content quota).
    var listings: [Date] = []
    /// When the owner was last told this grant is paused.
    var toldAt: Date?
  }

  private let memory: any AgentMemoryProviding
  private let records: any AgentAccessRecordStore
  private let secrets: any AgentGrantSecretStore
  private let consent: any AgentConsentPresenting
  private let changes: (any AgentChangeApplying)?
  private let search: any AgentSearching
  private let configuration: Configuration
  private let clock: @Sendable () -> Date
  /// The product time zone, read at each use: changed in Settings, it
  /// applies to agents at once (review v12-B #14).
  private let zone: @Sendable () -> TimeZone
  private var timeZone: TimeZone { zone() }
  private var sessions: [UUID: Session] = [:]
  private var maskMemos: [Data: AgentGenerationCache<String>] = [:]
  private var consentTasks: [String: Task<AgentConsentAnswer?, Never>] = [:]
  /// Identity key → the name its open consent card shows.
  private var consentNames: [String: String] = [:]
  private var approvalTasks: [String: Task<[String: Bool], Never>] = [:]
  private var deniedAt: [String: Date] = [:]
  private var usage: [UUID: Usage] = [:]

  /// - Parameters:
  ///   - changes: applies an allowed change (the App); nil answers every
  ///     change tool that Mindloom cannot change things right now.
  ///   - search: the App's search engine (`AgentRecordSearch`; the App
  ///     passes the dictionary and the owner's names).
  public init(
    memory: any AgentMemoryProviding, records: any AgentAccessRecordStore,
    secrets: any AgentGrantSecretStore, consent: any AgentConsentPresenting,
    changes: (any AgentChangeApplying)? = nil, search: any AgentSearching = AgentRecordSearch(),
    configuration: Configuration = Configuration(), timeZone: TimeZone = .current,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.init(
      memory: memory, records: records, secrets: secrets, consent: consent, changes: changes,
      search: search, configuration: configuration, zone: { timeZone }, clock: clock)
  }

  /// `zone` gives the product time zone each time it is needed (the App's
  /// setting), for time words, 今天 and a 今天 grant's end.
  public init(
    memory: any AgentMemoryProviding, records: any AgentAccessRecordStore,
    secrets: any AgentGrantSecretStore, consent: any AgentConsentPresenting,
    changes: (any AgentChangeApplying)? = nil, search: any AgentSearching = AgentRecordSearch(),
    configuration: Configuration = Configuration(), zone: @escaping @Sendable () -> TimeZone,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.memory = memory
    self.records = records
    self.secrets = secrets
    self.consent = consent
    self.changes = changes
    self.search = search
    self.configuration = configuration
    self.zone = zone
    self.clock = clock
  }

  // MARK: - Sessions

  public func openSession(
    peer: AgentConnectionPeer, push: (@Sendable (String) -> Void)? = nil
  ) -> UUID {
    let id = UUID()
    sessions[id] = Session(id: id, peer: peer, push: push)
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
        // The change tools only for a grant that may change (F5): nothing
        // is offered that the owner did not allow. Listing never asks.
        let includeChanges = await mayChange(sessionID)
        sessions[sessionID]?.listedChanges = includeChanges
        return MCPMessage.result(id: id, AgentTool.listResult(includingChanges: includeChanges))
      case "resources/templates/list":
        return MCPMessage.result(id: id, AgentResource.templatesResult)
      case "tools/call":
        return await callTool(id: id, params: params, session: sessionID)
      case "resources/list":
        return await listResources(id: id, params: params, session: sessionID)
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
    let hint: String? =
      switch tool {
      case .getMatter: arguments["id"]?.stringValue
      case .renameMatter, .markStep, .addNote: arguments["matter_id"]?.stringValue
      case .moveItem: arguments["from_matter_id"]?.stringValue
      default: nil
      }
    switch await authorize(session: session, matterHint: hint, wantsToChange: tool.isChange) {
    case .denied:
      output = .failure(AgentCopy.denied, code: "denied", outcome: .denied)
    case .pending:
      output = .failure(AgentCopy.pending, code: "pending", outcome: .pending)
    case .unavailable:
      output = .failure(AgentCopy.unavailable, code: "unavailable", outcome: .failed)
    case .granted(let grant):
      grantID = grant.grantID
      if tool.isChange, !grant.terms.canChange {
        output = .failure(AgentCopy.changeNotAllowed, code: "read_only", outcome: .denied)
      } else if await overLimit(grant.grantID, tool: tool, session: session) {
        output = .failure(AgentCopy.limited, code: "limited", outcome: .limited)
      } else {
        let answer = await run(tool, arguments: arguments, grant: grant, session: session)
        // A call may have waited for the owner; a grant revoked meanwhile wins (V7-A5).
        output =
          await stillGranted(grant, session: session)
          ? answer : .failure(AgentCopy.denied, code: "denied", outcome: .denied)
      }
    }
    let result = output.result(withData: AgentToolResult.wantsData(params))
    // The content quota and the audit count the library text the answer
    // gives (what the agent's model reads), not the JSON around it nor the
    // data a script asked for in `_meta`; a refusal gives none.
    let bytes = output.outcome == .allowed ? output.contentBytes : 0
    if let grantID, output.outcome == .allowed {
      account(grantID, tool: tool, matters: output.matterIDs.count, bytes: bytes)
    }
    await audit(
      session: session, grant: grantID, tool: tool.rawValue, outcome: output.outcome,
      ids: output.matterIDs, bytes: bytes)
    return MCPMessage.result(id: id, result)
  }

  private func run(
    _ tool: AgentTool, arguments: [String: JSONValue], grant: ActiveGrant, session: UUID
  ) async -> AgentToolOutput {
    guard let snapshot = await memory.agentSnapshot() else {
      return .failure(AgentCopy.unavailable, code: "unavailable", outcome: .failed)
    }
    let reader = reader(snapshot, grant: grant)
    if tool.isChange {
      return await change(
        tool, arguments: arguments, reader: reader, grant: grant, session: session)
    }
    switch tool {
    case .today:
      guard grant.terms.askForNewMatters else { return reader.renderToday() }
      // An older grant that asks matter by matter reads only approved ones.
      let ids = reader.matters.map(\.eventID)
      let (allowed, _) = await approved(ids, snapshot: snapshot, grant: grant, session: session)
      return restricted(reader, to: allowed).renderToday()
    case .search:
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
      // The App's search engine, over the masked, in-scope matters only
      // (AGENT-004, AGENT-005); time words in the product time zone.
      let found = await search.search(
        query, in: reader.searchDocuments(space: space), limit: AgentTool.maximumSearchLimit,
        clock: SearchClock(now: clock(), timeZone: timeZone))
      let matched = found.hits
      let candidates = Array(matched.prefix(limit))
      let (allowed, waiting) = await approved(
        candidates.map(\.matterID), snapshot: snapshot, grant: grant, session: session)
      let shown = candidates.filter { allowed.contains($0.matterID) }
      // With "ask me first", matters the owner refused are not even counted (V7-A4).
      let total = grant.terms.askForNewMatters ? shown.count : matched.count
      return reader.renderSearch(
        shown, total: total, waiting: waiting, conditions: found.conditions,
        dropped: found.dropped, meaningPartial: found.meaningPartial)
    case .getMatter:
      guard let matterID = text(arguments["id"], max: AgentTool.maximumIDCharacters),
        !matterID.isEmpty
      else { return invalid("id 不能为空") }
      let format = arguments["format"]?.stringValue ?? "text"
      guard format == "text" || format == "json" else { return invalid("format 只能是 text 或 json") }
      let detail = arguments["detail"]?.stringValue ?? "brief"
      guard detail == "brief" || detail == "full" else {
        return invalid("detail 只能是 brief 或 full")
      }
      var item: (id: String, around: String?)?
      if let raw = arguments["item_id"] {
        guard let itemID = text(raw, max: AgentTool.maximumIDCharacters), !itemID.isEmpty else {
          return invalid("item_id 不能为空")
        }
        guard let around = optionalText(arguments["around"], max: AgentTool.maximumQueryCharacters)
        else { return invalid("around 最多 \(AgentTool.maximumQueryCharacters) 个字") }
        item = (itemID, around)
      } else if arguments["around"] != nil {
        return invalid("around 要和 item_id 一起用")
      }
      // The full lens comes in pages (AGENT-TOOLS.md, verification 10-6).
      guard let page = integer(arguments["page"], in: 1...Int(Int32.max), default: 1) else {
        return invalid("page 需要是 1 或更大的整数")
      }
      if let raw = arguments["page"], raw != .null, detail != "full" || item != nil {
        return invalid("page 要和 detail=full 一起用（不给 item_id）")
      }
      return await matter(
        matterID, json: format == "json", full: detail == "full", page: page, item: item,
        reader: reader, grant: grant, session: session)
    case .listDeadlines:
      guard
        let days = integer(
          arguments["days"], in: 1...AgentTool.maximumDeadlineDays,
          default: AgentTool.defaultDeadlineDays)
      else { return invalid("days 需要在 1–\(AgentTool.maximumDeadlineDays) 之间") }
      guard let limit = listLimit(arguments) else { return listLimitInvalid }
      let all = reader.deadlines(days: days)
      let deadlines = Array(all.prefix(limit))
      let ids = orderedUnique(deadlines.map(\.entry.eventID))
      let (allowed, waiting) = await approved(
        ids, snapshot: snapshot, grant: grant, session: session)
      return reader.renderDeadlines(
        deadlines.filter { allowed.contains($0.entry.eventID) }, days: days, waiting: waiting,
        more: unlisted(all.count, limit, grant))
    case .listRecent:
      guard
        let days = integer(
          arguments["days"], in: 1...AgentTool.maximumRecentDays,
          default: AgentTool.defaultRecentDays)
      else { return invalid("days 需要在 1–\(AgentTool.maximumRecentDays) 之间") }
      guard let limit = listLimit(arguments) else { return listLimitInvalid }
      let space = arguments["space"]?.stringValue.map(AgentSpaceID.normalized)
      let all = reader.recent(days: days, space: space)
      let entries = Array(all.prefix(limit))
      let (allowed, waiting) = await approved(
        entries.map(\.eventID), snapshot: snapshot, grant: grant, session: session)
      return reader.renderRecent(
        entries.filter { allowed.contains($0.eventID) }, days: days, waiting: waiting,
        more: unlisted(all.count, limit, grant))
    case .getPerson:
      guard let name = text(arguments["name"], max: AgentTool.maximumPersonNameCharacters),
        !name.isEmpty
      else { return invalid("name 不能为空") }
      guard let limit = listLimit(arguments) else { return listLimitInvalid }
      guard let found = reader.person(named: name) else {
        return .failure(AgentCopy.personNotFound, code: "not_found", outcome: .notFound)
      }
      let (person, all) = found
      let matters = Array(all.prefix(limit))
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
        person, matters: shown, quotes: reader.quotes(of: person, in: shown), waiting: waiting,
        more: unlisted(all.count, limit, grant))
    case .addNote, .moveItem, .renameMatter, .markStep:
      return invalid("")
    }
  }

  private func matter(
    _ matterID: String, json: Bool, full: Bool, page: Int = 1,
    item: (id: String, around: String?)? = nil, reader: AgentReader, grant: ActiveGrant,
    session: UUID
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
        : .failure("主人没有同意这个 App 读这件事。", code: "denied", outcome: .denied)
    }
    if let item {
      // One item, with who said it (review 10-5d R8).
      return reader.renderItem(detail, itemID: item.id, around: item.around, json: json)
        ?? .failure(AgentCopy.itemNotInMatter, code: "not_found", outcome: .notFound)
    }
    return full
      ? reader.renderMatter(detail, page: page, json: json)
      : reader.renderBrief(detail, json: json)
  }

  /// The reader limited to `allowed` matters (an older grant that asks
  /// matter by matter).
  private func restricted(_ reader: AgentReader, to allowed: Set<String>) -> AgentReader {
    AgentReader(
      snapshot: reader.snapshot, inScope: { reader.inScope($0) && allowed.contains($0) },
      mask: reader.mask)
  }

  // MARK: - Changes (也可以改)

  /// Why a matter cannot be changed, as the answer the agent gets.
  private struct Refusal: Error {
    let output: AgentToolOutput
  }

  /// A matter a change may touch: in the grant (approved when it asks
  /// first), and the owner's own (a shared space's matters are read-only
  /// here, AGENT-004).
  private func changeable(
    _ raw: String?, reader: AgentReader, grant: ActiveGrant, session: UUID
  ) async -> Result<MemoryHomeEntry, Refusal> {
    guard let raw, !raw.isEmpty, raw.count <= AgentTool.maximumIDCharacters,
      let entry = reader.entry(raw)
    else {
      return .failure(
        Refusal(output: .failure(AgentCopy.notFound, code: "not_found", outcome: .notFound)))
    }
    guard reader.snapshot.space(of: entry.eventID) == AgentSpaceID.personal else {
      return .failure(
        Refusal(
          output: .failure(AgentCopy.sharedNotChangeable, code: "read_only", outcome: .denied)))
    }
    let (allowed, waiting) = await approved(
      [entry.eventID], snapshot: reader.snapshot, grant: grant, session: session)
    guard allowed.contains(entry.eventID) else {
      return .failure(
        Refusal(
          output: waiting > 0
            ? .failure(AgentCopy.pending, code: "pending", outcome: .pending)
            : .failure(AgentCopy.notFound, code: "not_found", outcome: .notFound)))
    }
    return .success(entry)
  }

  private func change(
    _ tool: AgentTool, arguments: [String: JSONValue], reader: AgentReader, grant: ActiveGrant,
    session: UUID
  ) async -> AgentToolOutput {
    guard let changes, let identity = sessions[session]?.identity else {
      return .failure(AgentCopy.unavailable, code: "unavailable", outcome: .failed)
    }
    let applied: AgentChange
    let kind: AgentChangeRecord.Kind
    var matterIDs: [String] = []
    var itemID: String?
    let summary: String
    switch tool {
    case .addNote:
      guard
        let body = text(arguments["text"], max: AgentTool.maximumNoteCharacters, keepLines: true),
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return invalid("text 需要 1–\(AgentTool.maximumNoteCharacters) 个字") }
      guard let title = text(arguments["title"] ?? "", max: AgentTool.maximumNoteTitleCharacters)
      else { return invalid("title 最多 \(AgentTool.maximumNoteTitleCharacters) 个字") }
      var target: MemoryHomeEntry?
      if let raw = arguments["matter_id"]?.stringValue, !raw.isEmpty {
        switch await changeable(raw, reader: reader, grant: grant, session: session) {
        case .failure(let refusal): return refusal.output
        case .success(let entry): target = entry
        }
      }
      applied = .addNote(title: title, text: body, matterID: target?.eventID)
      kind = .addNote
      matterIDs = target.map { [$0.eventID] } ?? []
      let shown = title.isEmpty ? String(reader.oneLine(body).prefix(24)) : title
      summary =
        "添加“\(shown)”" + (target.map { "到“\(reader.oneLine($0.title))”" } ?? "")
    case .moveItem:
      let from: MemoryHomeEntry
      switch await changeable(
        arguments["from_matter_id"]?.stringValue, reader: reader, grant: grant, session: session)
      {
      case .failure(let refusal): return refusal.output
      case .success(let entry): from = entry
      }
      var to: MemoryHomeEntry?
      if let raw = arguments["to_matter_id"]?.stringValue, !raw.isEmpty {
        switch await changeable(raw, reader: reader, grant: grant, session: session) {
        case .failure(let refusal): return refusal.output
        case .success(let entry): to = entry
        }
        guard to?.eventID != from.eventID else { return invalid("移出和移入是同一件事") }
      }
      guard let wanted = text(arguments["item_id"], max: AgentTool.maximumIDCharacters),
        let item = reader.detail(from.eventID)?.items.first(where: {
          $0.itemID.caseInsensitiveCompare(wanted) == .orderedSame
        })
      else {
        return .failure(AgentCopy.itemNotInMatter, code: "not_found", outcome: .notFound)
      }
      itemID = item.itemID
      if let to {
        applied = .correction(
          .moveItem(itemID: item.itemID, segID: nil, from: from.eventID, to: to.eventID))
        kind = .moveItem
        matterIDs = [from.eventID, to.eventID]
        summary = "将一条原文从“\(reader.oneLine(from.title))”移到“\(reader.oneLine(to.title))”"
      } else {
        applied = .correction(.takeOut(itemID: item.itemID, segID: nil, from: from.eventID))
        kind = .takeOut
        matterIDs = [from.eventID]
        summary = "将一条原文移出“\(reader.oneLine(from.title))”"
      }
    case .renameMatter:
      let entry: MemoryHomeEntry
      switch await changeable(
        arguments["matter_id"]?.stringValue, reader: reader, grant: grant, session: session)
      {
      case .failure(let refusal): return refusal.output
      case .success(let found): entry = found
      }
      guard let title = text(arguments["title"], max: AgentTool.maximumMatterTitleCharacters),
        !title.isEmpty
      else { return invalid("title 需要 1–\(AgentTool.maximumMatterTitleCharacters) 个字") }
      guard title != entry.title else {
        return AgentToolOutput(
          text: "名字本来就是这个，没有改。", structured: ["changed": false], matterIDs: [entry.eventID])
      }
      applied = .correction(.rename(eventID: entry.eventID, from: entry.title, to: title))
      kind = .renameMatter
      matterIDs = [entry.eventID]
      summary = "将“\(reader.oneLine(entry.title))”重新命名为“\(title)”"
    case .markStep:
      let entry: MemoryHomeEntry
      switch await changeable(
        arguments["matter_id"]?.stringValue, reader: reader, grant: grant, session: session)
      {
      case .failure(let refusal): return refusal.output
      case .success(let found): entry = found
      }
      guard let stepID = text(arguments["step_id"], max: AgentTool.maximumIDCharacters),
        let step = reader.steps(entry.eventID)?.step(stepID)
      else { return .failure(AgentCopy.stepNotFound, code: "not_found", outcome: .notFound) }
      let wanted = arguments["state"]?.stringValue ?? "done"
      guard let state = UserStepOverride.State(rawValue: wanted) else {
        return invalid("state 只能是 done 或 settled")
      }
      if state == .settled, !step.isOpenQuestion {
        return invalid("只有待定的问题能标为已经定了（settled）；这一步用 done")
      }
      if state == .done, step.isOpenQuestion {
        return invalid("这是一个待定的问题，用 state=settled")
      }
      let previous = reader.snapshot.user.override(eventID: entry.eventID, stepID: step.id)?.state
      guard previous != state, !(state == .done && step.isDone && previous == nil) else {
        return AgentToolOutput(
          text: "这一步已经是这样了，没有改。", structured: ["changed": false], matterIDs: [entry.eventID])
      }
      applied = .correction(
        .markStep(eventID: entry.eventID, stepID: step.id, state: state, previous: previous))
      kind = .markStep
      matterIDs = [entry.eventID]
      summary =
        "将“\(reader.oneLine(step.text))”标记为\(state == .done ? "完成" : "已确定")（“\(reader.oneLine(entry.title))”）"
    default:
      return invalid("")
    }
    let made: String?
    do {
      made = try await changes.apply(applied, client: identity)
    } catch {
      return .failure("没有改成；Mindloom 里什么都没变。", code: "failed", outcome: .failed)
    }
    let payload: JSONValue
    switch applied {
    case .addNote(_, _, let matterID):
      itemID = made
      payload = [
        "item_id": made.map(JSONValue.string) ?? .null,
        "matter_id": matterID.map(JSONValue.string) ?? .null,
      ]
    case .correction(let correction):
      payload = (try? JSONEncoder().encode(correction)).flatMap { try? JSONValue.parse($0) } ?? [:]
    }
    let record = AgentChangeRecord(
      at: clock(), clientKey: identity.key, clientName: identity.displayName,
      grantID: grant.grantID, kind: kind, matterIDs: matterIDs, itemID: itemID,
      payload: payload.serialized, summary: String(summary.prefix(200)))
    try? await records.appendAgentChange(record)
    await memory.invalidate()
    await consent.changeMade(record)
    var structured: [String: JSONValue] = [
      "changed": true, "change_id": .string(record.changeID.uuidString.lowercased()),
      "kind": .string(kind.rawValue), "matter_ids": .strings(matterIDs),
    ]
    if let itemID { structured["item_id"] = .string(itemID) }
    return AgentToolOutput(
      text: AgentCopy.changed + (itemID.map { "（条目 id：\($0)）" } ?? ""),
      structured: .object(structured), matterIDs: matterIDs)
  }

  // MARK: - Limits (F7)

  /// True when the grant has used its hour for this kind of call; the owner
  /// is told once per pause.
  private func overLimit(_ grantID: UUID, tool: AgentTool, session: UUID) async -> Bool {
    let limits = configuration.limits
    let now = clock()
    var current = usage[grantID] ?? Usage()
    let since = now.addingTimeInterval(-limits.window)
    current.reads.removeAll { $0.at < since }
    current.notes.removeAll { $0 < since }
    current.changes.removeAll { $0 < since }
    current.listings.removeAll { $0 < since }
    let over: Bool
    switch tool {
    case .addNote: over = current.notes.count >= limits.notesPerHour
    case .moveItem, .renameMatter, .markStep: over = current.changes.count >= limits.changesPerHour
    default:
      over =
        current.reads.reduce(0) { $0 + $1.matters } >= limits.mattersPerHour
        || current.reads.reduce(0) { $0 + $1.bytes } >= limits.bytesPerHour
    }
    var tell = false
    if over, current.toldAt.map({ $0 < since }) ?? true {
      current.toldAt = now
      tell = true
    }
    usage[grantID] = current
    if tell, let name = sessions[session]?.identity.displayName {
      await consent.limitReached(clientName: name)
    }
    return over
  }

  /// True when the grant has listed resources `listingsPerHour` times in
  /// the rolling hour. The owner is not told: a client lists at its own
  /// start, not because anyone asked for something.
  private func overListingLimit(_ grantID: UUID) -> Bool {
    let since = clock().addingTimeInterval(-configuration.limits.window)
    usage[grantID, default: Usage()].listings.removeAll { $0 < since }
    return (usage[grantID]?.listings.count ?? 0) >= configuration.limits.listingsPerHour
  }

  private func account(_ grantID: UUID, tool: AgentTool?, matters: Int, bytes: Int) {
    let now = clock()
    switch tool {
    case .addNote: usage[grantID, default: Usage()].notes.append(now)
    case .moveItem, .renameMatter, .markStep: usage[grantID, default: Usage()].changes.append(now)
    default: usage[grantID, default: Usage()].reads.append((now, matters, bytes))
    }
  }

  // MARK: - Resources

  /// `resources/list` (MCP resources are application-driven: Claude Code
  /// lists them at every start for its @-mention picker and follows
  /// `nextCursor` by itself). Listing never asks (as `tools/list`): before a
  /// grant the list is empty and nothing is recorded, so no card appears
  /// before anyone asked for anything (v12 end-to-end check). With a grant,
  /// one page of titles and ids, most recent first, at most
  /// `listMaximum` over all pages; each page is audited and counted against
  /// `listingsPerHour`, never against the content quota (AGENT-TOOLS.md).
  private func listResources(id: JSONValue, params: JSONValue?, session: UUID) async -> JSONValue {
    if let current = sessions[session], current.once == nil,
      case .some(.none) = await storedGrant(for: current.identity)
    {
      return MCPMessage.result(id: id, AgentOfflineResponder.emptyResourceList)
    }
    switch await authorize(session: session) {
    case .granted(let grant):
      var position: (offset: Int, after: String)?
      if let raw = params?["cursor"], raw != .null {
        guard let cursor = raw.stringValue, let found = AgentResource.position(of: cursor),
          found.offset <= configuration.listMaximum
        else {
          await audit(
            session: session, grant: grant.grantID, tool: "resources/list", outcome: .invalid,
            ids: [], bytes: 0)
          return MCPMessage.error(
            id: id, code: MCPErrorCode.invalidParams, message: AgentCopy.invalidCursor)
        }
        position = found
      }
      if overListingLimit(grant.grantID) {
        await audit(
          session: session, grant: grant.grantID, tool: "resources/list", outcome: .limited,
          ids: [], bytes: 0)
        return MCPMessage.error(
          id: id, code: MCPErrorCode.notAllowed, message: AgentCopy.listingLimited)
      }
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
      entries = Array(entries.prefix(configuration.listMaximum))
      // The page starts after the last matter the cursor named while it is
      // still listed (stable when a matter moved up), else at its offset.
      var start = position?.offset ?? 0
      if let after = position?.after,
        let index = entries.firstIndex(where: {
          $0.eventID.caseInsensitiveCompare(after) == .orderedSame
        })
      {
        start = index + 1
      }
      start = min(start, entries.count)
      let end = min(start + configuration.listPageSize, entries.count)
      let page = Array(entries[start..<end])
      let next = page.last.flatMap {
        end < entries.count ? AgentResource.cursor(offset: end, after: $0.eventID) : nil
      }
      let result = reader.resourceList(page, nextCursor: next)
      let bytes = result.serializedData.count
      usage[grant.grantID, default: Usage()].listings.append(clock())
      await audit(
        session: session, grant: grant.grantID, tool: "resources/list", outcome: .allowed,
        ids: page.map(\.eventID), bytes: bytes)
      return MCPMessage.result(id: id, result)
    case .denied:
      return MCPMessage.result(id: id, AgentOfflineResponder.emptyResourceList)
    case .pending:
      return MCPMessage.result(id: id, AgentOfflineResponder.emptyResourceList)
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
    switch await authorize(session: session, matterHint: matterID) {
    case .granted(let grant):
      grantID = grant.grantID
      if await overLimit(grant.grantID, tool: .getMatter, session: session) {
        output = .failure(AgentCopy.limited, code: "limited", outcome: .limited)
      } else if let snapshot = await memory.agentSnapshot() {
        let answer = await matter(
          matterID, json: false, full: false, reader: reader(snapshot, grant: grant),
          grant: grant, session: session)
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
    let bytes = output.contentBytes
    if let grantID { account(grantID, tool: .getMatter, matters: 1, bytes: bytes) }
    await audit(
      session: session, grant: grantID, tool: "resources/read", outcome: .allowed,
      ids: output.matterIDs, bytes: bytes)
    return MCPMessage.result(id: id, result)
  }

  // MARK: - Grants

  private func authorize(
    session sessionID: UUID, matterHint: String? = nil, wantsToChange: Bool = false
  ) async -> Authorization {
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
    // One open card per name (F7): another program calling itself the same
    // waits instead of stacking cards.
    if consentTasks[identity.key] == nil,
      consentNames.contains(where: { $0.key != identity.key && $0.value == identity.displayName })
    {
      return .pending
    }
    let task = consentTask(
      for: identity, session: sessionID, matterHint: matterHint, wantsToChange: wantsToChange)
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

  /// The session's current grant allows changes (checked without asking).
  private func mayChange(_ sessionID: UUID) async -> Bool {
    guard let session = sessions[sessionID] else { return false }
    if let once = session.once { return once.terms.canChange }
    if case .some(.some(let grant)) = await storedGrant(for: session.identity) {
      return grant.terms.canChange
    }
    return false
  }

  /// Tells each client that listed tools when what it may do changed
  /// (`notifications/tools/list_changed`), so it lists them again.
  private func refreshListedTools() async {
    for (id, session) in sessions {
      guard let listed = session.listedChanges else { continue }
      let now = await mayChange(id)
      guard now != listed else { continue }
      sessions[id]?.listedChanges = now
      session.push?(MCPMessage.notification(method: "notifications/tools/list_changed").serialized)
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
      // v11 shows no ropes: an old rope grant covers nothing, so it is no
      // grant at all; it is removed and the owner is asked again (fix-mac).
      if case .ropes = record.terms.range {
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

  private func consentTask(
    for identity: AgentClientIdentity, session: UUID, matterHint: String? = nil,
    wantsToChange: Bool = false
  )
    -> Task<AgentConsentAnswer?, Never>
  {
    if let existing = consentTasks[identity.key] { return existing }
    let presenter = consent
    let memory = memory
    let records = records
    let now = clock()
    let task = Task<AgentConsentAnswer?, Never> { [weak self] in
      let snapshot = await memory.agentSnapshot()
      let options = AgentConsentOptions(
        spaces: snapshot?.spaces ?? [.personal], ropes: snapshot?.ropes ?? [],
        matters: (snapshot?.projection.home() ?? []).filter {
          snapshot?.space(of: $0.eventID) == AgentSpaceID.personal
        }.prefix(60).map {
          AgentMatterOption(id: $0.eventID, title: $0.title)
        })
      // The matter the first call names (get_matter, a change, a resource),
      // so the owner is asked about that one (v11 「让 … 读「…」？」).
      let requested = matterHint.flatMap { hint in
        snapshot?.projection.home().first {
          $0.eventID.caseInsensitiveCompare(hint) == .orderedSame
        }.map { AgentMatterOption(id: $0.eventID, title: $0.title) }
      }
      // Another program allowed before under the same name (F3).
      let lookalike = ((try? await records.agentGrants()) ?? []).first {
        $0.clientName == identity.displayName && $0.clientKey != identity.key
      }.map { AgentLookalike(name: $0.clientName, path: $0.clientPath) }
      let answer = await presenter.requestConsent(
        AgentConsentRequest(
          client: identity, options: options, requestedAt: now, requestedMatter: requested,
          lookalike: lookalike, wantsToChange: wantsToChange))
      await self?.apply(answer, identity: identity, session: session)
      return answer
    }
    consentTasks[identity.key] = task
    consentNames[identity.key] = identity.displayName
    return task
  }

  private func apply(_ answer: AgentConsentAnswer?, identity: AgentClientIdentity, session: UUID)
    async
  {
    consentTasks[identity.key] = nil
    consentNames[identity.key] = nil
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
    await refreshListedTools()
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
    usage[grantID] = nil
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

  // MARK: - Management (Settings › 其他 App)

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

  /// The programs connected right now, by client key (for Settings: who is
  /// talking to Mindloom, signed by whom, from where).
  public func connectedClients() -> [AgentClientIdentity] {
    var seen = Set<String>()
    return sessions.values.map(\.identity).filter {
      $0.name != "unknown" && seen.insert($0.key).inserted
    }
  }

  /// 停止允许: the secret and the scope record go; the next call from that
  /// client finds no grant.
  public func revoke(_ grantID: UUID) async {
    for (id, session) in sessions where session.once?.grantID == grantID {
      sessions[id]?.once = nil
    }
    await removeGrant(grantID)
    await refreshListedTools()
    await consent.accessChanged()
  }

  /// 停止允许 for every grant of one client (the per-App page's button).
  public func revokeAll(clientKey: String) async {
    for (id, session) in sessions where session.identity.key == clientKey {
      sessions[id]?.once = nil
    }
    for record in (try? await records.agentGrants()) ?? [] where record.clientKey == clientKey {
      await removeGrant(record.grantID)
    }
    await refreshListedTools()
    await consent.accessChanged()
  }

  /// Every matter's words as the search reads them for a grant that shows
  /// numbers, over the whole library: what the App's background warm-up of
  /// the agents' meaning vectors embeds (`AgentRecordSearch.warmMeaning`).
  /// Never sent to an agent; a grant reads only its own scope, masked as it
  /// says, and a masked piece has its own key.
  public func meaningDocuments() async -> [AgentSearchDocument] {
    guard let snapshot = await memory.agentSnapshot() else { return [] }
    let reader = AgentReader(
      snapshot: snapshot, inScope: { _ in true }, mask: AgentTextMask(masker: nil))
    return reader.searchDocuments(space: nil)
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
      case .ropes:
        // v11 shows no ropes: an old rope grant covers nothing.
        return false
      case .groups(let ids):
        guard let group = snapshot.groupOfMatter[matterID.uppercased()] else { return false }
        return ids.contains { $0.caseInsensitiveCompare(group) == .orderedSame }
      }
    }
    let masker = terms.showNumbers ? nil : try? PrivacyMasker(maskKey: grant.maskKey)
    // What this grant's key masked before is kept (review v12-B #10).
    let memo = masker.map { _ in maskMemo(grant.maskKey) }
    memo?.beginUse()
    var reader = AgentReader(
      snapshot: snapshot, inScope: inScope, mask: AgentTextMask(masker: masker, memo: memo))
    // A split recording names its other matters only when they are in scope,
    // and never when each new matter first waits for the owner (V7-A1).
    reader.showSibling = terms.askForNewMatters ? { _ in false } : inScope
    return reader
  }

  /// The masked texts of one mask key (one per grant), at most a few kept.
  private func maskMemo(_ key: Data) -> AgentGenerationCache<String> {
    if let memo = maskMemos[key] { return memo }
    if maskMemos.count >= 4 { maskMemos.removeAll() }
    let memo = AgentGenerationCache<String>(budget: 16_000_000)
    maskMemos[key] = memo
    return memo
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

  /// `limit` of the list tools; nil when it is out of range.
  private func listLimit(_ arguments: [String: JSONValue]) -> Int? {
    integer(
      arguments["limit"], in: 1...AgentTool.maximumListLimit, default: AgentTool.defaultListLimit)
  }

  private var listLimitInvalid: AgentToolOutput {
    invalid("limit 需要在 1–\(AgentTool.maximumListLimit) 之间")
  }

  /// Rows a `limit` left out, said under the list; not said to a grant that
  /// asks matter by matter, whose refused matters are not even counted
  /// (V7-A4).
  private func unlisted(_ total: Int, _ limit: Int, _ grant: ActiveGrant) -> Int {
    grant.terms.askForNewMatters ? 0 : max(0, total - limit)
  }

  private func invalid(_ message: String) -> AgentToolOutput {
    .failure(message.isEmpty ? "参数有误" : message, code: "invalid_arguments", outcome: .invalid)
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

  /// An optional string argument: `.some(nil)` when it is absent or empty,
  /// nil when it is not a string or too long.
  private func optionalText(_ value: JSONValue?, max: Int) -> String?? {
    guard let value, value != .null else { return .some(nil) }
    guard let cleaned = text(value, max: max) else { return nil }
    return .some(cleaned.isEmpty ? nil : cleaned)
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
