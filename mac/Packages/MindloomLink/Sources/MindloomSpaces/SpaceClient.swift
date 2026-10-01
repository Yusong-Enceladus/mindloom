import Foundation
import MindloomLink

/// One HTTP request to the Spark's space routes. The transport adds the link
/// token (the user's own SSH forward); the client adds the device signature.
public struct SpaceHTTPRequest: Equatable, Sendable {
  public let method: String
  /// The raw path plus `?` and the raw query, exactly as sent and signed.
  public let target: String
  public let body: Data?
  public let contentType: String?
  public let headers: [String: String]

  public init(
    method: String, target: String, body: Data?, contentType: String?,
    headers: [String: String]
  ) {
    self.method = method
    self.target = target
    self.body = body
    self.contentType = contentType
    self.headers = headers
  }
}

public struct SpaceHTTPResponse: Equatable, Sendable {
  public let status: Int
  public let body: Data

  public init(status: Int, body: Data) {
    self.status = status
    self.body = body
  }
}

public protocol SpaceTransport: Sendable {
  func send(_ request: SpaceHTTPRequest) async throws -> SpaceHTTPResponse
}

/// `{"error": "<code>", "detail"?: …, …}` with its HTTP status. Bodies are
/// never echoed by the Spark, so this never holds content.
public struct SpaceServerError: Error, Equatable, Sendable {
  public let status: Int
  public let code: String
  public let detail: String?
  public let extra: SpaceJSON

  public init(status: Int, code: String, detail: String? = nil, extra: SpaceJSON = [:]) {
    self.status = status
    self.code = code
    self.detail = detail
    self.extra = extra
  }
}

public enum SpaceClientError: Error, Equatable, Sendable {
  /// The link is down (no forward, no token, a dropped connection).
  case transport
  /// The answer was not the expected shape.
  case malformed
  case server(SpaceServerError)
  /// 403 `not_member`: this device's access ended. `purgeForks` are the
  /// items it must delete from this Mac (forks kept under the policy);
  /// `removal` is the signed op that ended it, which the Mac checks against
  /// its own roster before it deletes anything (review V7-S16).
  case accessEnded(memberStatus: String?, purgeForks: [String], removal: SpaceLogEntry? = nil)

  public var serverCode: String? {
    if case .server(let error) = self { return error.code }
    return nil
  }
}

/// Speaks the space routes (SPACES-CONTRACT; route table in the Spark's
/// `docs/SPACES.md`). Reads, uploads and the organizer are signed per
/// request by this device; ops, joins and creations carry their own
/// signatures and go as they are.
public struct SpaceClient: Sendable {
  public let transport: any SpaceTransport
  public let device: SpaceDeviceKeys
  public let now: @Sendable () -> Date

  public init(
    transport: any SpaceTransport, device: SpaceDeviceKeys,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.transport = transport
    self.device = device
    self.now = now
  }

  // MARK: - Plumbing

  public func send(
    _ method: String, _ path: String, query: [(String, String)] = [], body: Data? = nil,
    contentType: String? = "application/json", signed: Bool, headers extra: [String: String] = [:]
  ) async throws -> Data {
    let queryString = query.map { "\($0.0)=\(Self.percentEncode($0.1))" }.joined(separator: "&")
    let target = path + (queryString.isEmpty ? "" : "?" + queryString)
    var headers =
      signed
      ? try device.requestHeaders(method: method, target: target, body: body ?? Data(), date: now())
      : [:]
    for (name, value) in extra { headers[name] = value }
    let response: SpaceHTTPResponse
    do {
      response = try await transport.send(
        SpaceHTTPRequest(
          method: method, target: target, body: body, contentType: body == nil ? nil : contentType,
          headers: headers))
    } catch let error as SpaceClientError {
      throw error
    } catch {
      throw SpaceClientError.transport
    }
    guard (200..<300).contains(response.status) else {
      throw Self.error(status: response.status, body: response.body)
    }
    return response.body
  }

  static func error(status: Int, body: Data) -> SpaceClientError {
    let json = (try? SpaceJSON.decode(body)) ?? [:]
    let code = json["error"]?.string ?? json["detail"]?.string ?? "http_\(status)"
    if status == 403, code == "not_member" {
      return .accessEnded(
        memberStatus: json["member_status"]?.string,
        purgeForks: json["purge_forks"]?.array?.compactMap(\.string) ?? [],
        removal: try? json["removal"]?.decoded(as: SpaceLogEntry.self))
    }
    return .server(
      SpaceServerError(
        status: status, code: code, detail: json["detail"]?.string, extra: json))
  }

  static func percentEncode(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  func decode<Value: Decodable>(_ type: Value.Type, _ data: Data) throws -> Value {
    do { return try JSONDecoder().decode(Value.self, from: data) } catch {
      throw SpaceClientError.malformed
    }
  }

  func json(_ value: SpaceJSON) throws -> Data { try value.encoded() }

  // MARK: - This Spark

  public func hostKeys() async throws -> [String] {
    let data = try await send("GET", "/v1/spaces/host-keys", signed: false)
    return try decode(SpaceJSON.self, data)["host_keys"]?.array?.compactMap(\.string) ?? []
  }

  // MARK: - Organizations

  public func createOrg(_ op: SpaceWireOp) async throws -> SpaceJSON {
    try decode(
      SpaceJSON.self,
      await send("POST", "/v1/orgs", body: json(op.json), signed: false))
  }

  public func orgOps(_ orgID: String, _ ops: [SpaceWireOp]) async throws -> [SpaceOpResult] {
    let data = try await send(
      "POST", "/v1/orgs/\(orgID)/ops", body: json(["ops": .array(ops.map(\.json))]),
      signed: false)
    return try decode(SpaceOpsAnswer.self, data).results
  }

  public func org(_ orgID: String) async throws -> SpaceJSON {
    try decode(SpaceJSON.self, await send("GET", "/v1/orgs/\(orgID)", signed: true))
  }

  public func orgAudit(_ orgID: String, since: Int = 0, limit: Int = 200) async throws
    -> SpaceAuditPage
  {
    try decode(
      SpaceAuditPage.self,
      await send(
        "GET", "/v1/orgs/\(orgID)/audit", query: [("since", "\(since)"), ("limit", "\(limit)")],
        signed: true))
  }

  /// The organization's signed log (org admins' devices only).
  public func orgLog(_ orgID: String) async throws -> [SpaceLogEntry] {
    try await org(orgID)["ops"].map { try $0.decoded(as: [SpaceLogEntry].self) } ?? []
  }

  /// This org device's escrow wraps of each org space's current key (v8 B5).
  public func orgEscrow(_ orgID: String) async throws -> [SpaceEscrowWrap] {
    let data = try await send("GET", "/v1/orgs/\(orgID)/escrow", signed: true)
    return try decode(SpaceJSON.self, data)["spaces"].map {
      try $0.decoded(as: [SpaceEscrowWrap].self)
    } ?? []
  }

  // MARK: - Backups (v8 B4)

  /// The encrypted `MLBK1` stream of the space (an admin device signs; the
  /// key it lends is derived from the current epoch's key).
  public func backup(_ spaceID: String, backupID: String, epoch: Int, key: Data) async throws
    -> Data
  {
    let body: SpaceJSON = [
      "backup_id": .string(backupID.lowercased()), "epoch": SpaceJSON(epoch),
      "key": .string(SpaceCrypto.hex(key)),
    ]
    return try await send("POST", "/v1/spaces/\(spaceID)/backup", body: json(body), signed: true)
  }

  /// Puts a space back from a backup stream (`mode` new or replace; `purge`:
  /// items withdrawn or removed after it, from this Mac's own log).
  public func restore(
    _ spaceID: String, stream: Data, key: Data, mode: String, purge: [String]
  ) async throws -> SpaceJSON {
    let options: SpaceJSON = ["mode": .string(mode), "purge": SpaceJSON(purge)]
    let data = try await send(
      "POST", "/v1/spaces/\(spaceID)/restore", body: stream,
      contentType: "application/octet-stream", signed: false,
      headers: [
        "X-Mindloom-Backup-Key": SpaceCrypto.hex(key),
        "X-Mindloom-Restore": String(decoding: try options.encoded(), as: UTF8.self),
      ])
    return try decode(SpaceJSON.self, data)
  }

  // MARK: - Handover packs (v8 B3)

  public func requestHandoverPack(
    _ spaceID: String, matterID: String, from: String?, to: String?
  ) async throws -> SpaceJSON {
    var body: SpaceJSON = ["matter_id": .string(matterID)]
    if let from { body = body.setting("from", .string(from)) }
    if let to { body = body.setting("to", .string(to)) }
    return try decode(
      SpaceJSON.self,
      await send(
        "POST", "/v1/spaces/\(spaceID)/organizer/handover-pack", body: json(body), signed: true))
  }

  public func handoverPack(_ spaceID: String, packID: String) async throws -> SpaceJSON {
    try decode(
      SpaceJSON.self,
      await send(
        "GET", "/v1/spaces/\(spaceID)/organizer/handover-pack/\(packID)", signed: true))
  }

  // MARK: - Spaces

  public func createSpace(_ op: SpaceWireOp) async throws -> SpaceOpResult {
    try decode(
      SpaceOpResult.self, await send("POST", "/v1/spaces", body: json(op.json), signed: false))
  }

  public func listSpaces() async throws -> SpaceList {
    try decode(SpaceList.self, await send("GET", "/v1/spaces", signed: true))
  }

  public func summary(_ spaceID: String) async throws -> SpaceSummary {
    try decode(SpaceSummary.self, await send("GET", "/v1/spaces/\(spaceID)", signed: true))
  }

  /// Posts up to 50 ops; each gets its own result (in order; a refused op
  /// takes no seq).
  public func submit(_ spaceID: String, _ ops: [SpaceWireOp]) async throws -> SpaceOpsAnswer {
    try decode(
      SpaceOpsAnswer.self,
      await send(
        "POST", "/v1/spaces/\(spaceID)/ops", body: json(["ops": .array(ops.map(\.json))]),
        signed: false))
  }

  public func ops(_ spaceID: String, since: Int, limit: Int = 200) async throws -> SpaceOpsPage {
    try decode(
      SpaceOpsPage.self,
      await send(
        "GET", "/v1/spaces/\(spaceID)/ops", query: [("since", "\(since)"), ("limit", "\(limit)")],
        signed: true))
  }

  public func keys(_ spaceID: String) async throws -> SpaceKeys {
    try decode(SpaceKeys.self, await send("GET", "/v1/spaces/\(spaceID)/keys", signed: true))
  }

  public func staleItemKeys(_ spaceID: String, limit: Int = 200) async throws -> SpaceItemKeys {
    try decode(
      SpaceItemKeys.self,
      await send(
        "GET", "/v1/spaces/\(spaceID)/item-keys", query: [("stale", "1"), ("limit", "\(limit)")],
        signed: true))
  }

  public func itemKeys(_ spaceID: String, itemIDs: [String]) async throws -> SpaceItemKeys {
    try decode(
      SpaceItemKeys.self,
      await send(
        "GET", "/v1/spaces/\(spaceID)/item-keys", query: itemIDs.map { ("item_id", $0) },
        signed: true))
  }

  public func rewrap(_ spaceID: String, _ rewraps: [SpaceJSON]) async throws -> Int {
    let data = try await send(
      "PUT", "/v1/spaces/\(spaceID)/item-keys", body: json(["rewraps": .array(rewraps)]),
      signed: true)
    return try decode(SpaceJSON.self, data)["rewrapped"]?.int ?? 0
  }

  /// Uploads one sealed original (`MLB1…`); the Spark refuses anything else.
  public func putBlob(_ spaceID: String, blobID: String, sealed: Data) async throws {
    _ = try await send(
      "PUT", "/v1/spaces/\(spaceID)/blobs/\(blobID)", body: sealed,
      contentType: "application/octet-stream", signed: true)
  }

  public func blob(_ spaceID: String, blobID: String) async throws -> Data {
    try await send("GET", "/v1/spaces/\(spaceID)/blobs/\(blobID)", signed: true)
  }

  public func join(_ spaceID: String, request: SpaceJSON) async throws -> SpaceJSON {
    try decode(
      SpaceJSON.self,
      await send("POST", "/v1/spaces/\(spaceID)/join", body: json(request), signed: false))
  }

  public func joinStatus(_ spaceID: String, requestID: String) async throws -> SpaceJoinStatus {
    try decode(
      SpaceJoinStatus.self,
      await send("GET", "/v1/spaces/\(spaceID)/join/\(requestID)", signed: true))
  }

  public func joinRequests(_ spaceID: String, status: String? = "pending") async throws
    -> [SpaceJoinRequestRecord]
  {
    let data = try await send(
      "GET", "/v1/spaces/\(spaceID)/join-requests", query: status.map { [("status", $0)] } ?? [],
      signed: true)
    return try decode(SpaceJSON.self, data)["requests"].map {
      try $0.decoded(as: [SpaceJoinRequestRecord].self)
    } ?? []
  }

  public func invites(_ spaceID: String) async throws -> [SpaceInviteRecord] {
    let data = try await send("GET", "/v1/spaces/\(spaceID)/invites", signed: true)
    return try decode(SpaceJSON.self, data)["invites"].map {
      try $0.decoded(as: [SpaceInviteRecord].self)
    } ?? []
  }

  public func takedowns(_ spaceID: String, status: String? = nil) async throws
    -> [SpaceTakedownRecord]
  {
    let data = try await send(
      "GET", "/v1/spaces/\(spaceID)/takedowns", query: status.map { [("status", $0)] } ?? [],
      signed: true)
    return try decode(SpaceJSON.self, data)["takedowns"].map {
      try $0.decoded(as: [SpaceTakedownRecord].self)
    } ?? []
  }

  public func proposals(_ spaceID: String, status: String? = "open") async throws
    -> SpaceProposals
  {
    try decode(
      SpaceProposals.self,
      await send(
        "GET", "/v1/spaces/\(spaceID)/proposals", query: status.map { [("status", $0)] } ?? [],
        signed: true))
  }

  public func audit(_ spaceID: String, since: Int = 0, limit: Int = 200) async throws
    -> SpaceAuditPage
  {
    try decode(
      SpaceAuditPage.self,
      await send(
        "GET", "/v1/spaces/\(spaceID)/audit",
        query: [("since", "\(since)"), ("limit", "\(limit)")],
        signed: true))
  }

  // MARK: - The space organizer

  public func lease(_ spaceID: String, body: SpaceJSON) async throws -> SpaceLease {
    try decode(
      SpaceLease.self,
      await send(
        "POST", "/v1/spaces/\(spaceID)/organizer/lease", body: json(body), signed: true))
  }

  public func lockOrganizer(_ spaceID: String) async throws {
    _ = try await send(
      "POST", "/v1/spaces/\(spaceID)/organizer/lock", body: Data("{}".utf8), signed: true)
  }

  public func pending(_ spaceID: String, limit: Int = 200) async throws -> [SpacePendingItem] {
    let data = try await send(
      "GET", "/v1/spaces/\(spaceID)/organizer/pending", query: [("limit", "\(limit)")],
      signed: true)
    return try decode(SpaceJSON.self, data)["items"].map {
      try $0.decoded(as: [SpacePendingItem].self)
    } ?? []
  }

  /// Organizing payloads (the v6 item format, masked with the space's mask key).
  public func organizerItems(_ spaceID: String, items: [Data]) async throws -> SpaceJSON {
    var body = Data("{\"items\":[".utf8)
    for (index, item) in items.enumerated() {
      if index > 0 { body.append(Data(",".utf8)) }
      body.append(item)
    }
    body.append(Data("]}".utf8))
    return try decode(
      SpaceJSON.self,
      await send("POST", "/v1/spaces/\(spaceID)/organizer/items", body: body, signed: true))
  }

  /// The v6 `/v1/state` shape plus `same_as` and `busy`, as raw JSON.
  public func organizerState(_ spaceID: String, since: Int = 0) async throws -> Data {
    try await send(
      "GET", "/v1/spaces/\(spaceID)/organizer/state", query: [("since", "\(since)")], signed: true)
  }

  public func organizerDecisions(_ spaceID: String, body: Data) async throws -> SpaceJSON {
    try decode(
      SpaceJSON.self,
      await send("POST", "/v1/spaces/\(spaceID)/organizer/decisions", body: body, signed: true))
  }

  public func answerOrganizerQuestion(_ spaceID: String, questionID: String, answer: String)
    async throws -> SpaceJSON
  {
    try decode(
      SpaceJSON.self,
      await send(
        "POST", "/v1/spaces/\(spaceID)/organizer/questions/\(questionID)/answer",
        body: json(["answer": .string(answer)]), signed: true))
  }
}
