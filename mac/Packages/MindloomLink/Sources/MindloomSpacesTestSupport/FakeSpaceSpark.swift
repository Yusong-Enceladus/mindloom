import CryptoKit
import Foundation
import MindloomLink
import MindloomSpaces

/// An in-memory Spark for the member flows: the space routes of the Spark's
/// `spaces_api.py` with the same rules where the Mac's behaviour depends on
/// them (signatures on every op and request, roles, the withdraw window,
/// takedowns, rotation, crypto-shredding, the lease, `not_member`). It holds
/// only what the real one holds: signed ops, wraps, ciphertext and — under a
/// lease — masked organizing payloads. Every request body is logged so tests
/// can scan everything that left a Mac.
public final class FakeSpaceSpark: SpaceTransport, @unchecked Sendable {
  public struct Device {
    public var member: String
    public var signPub: Data
    public var sealPub: String
    public var signPubB64: String
    public var status = "active"
  }

  public struct Member {
    public var role: SpaceRole
    public var outside = false
    public var status = "active"
    public var joined: Date
    public var ended: Date?
  }

  public struct Item {
    public var contributor: String
    public var kind: String
    public var revision: Int
    public var status = "active"
    public var shareSeq: Int
    public var first: Date
    public var shareKey: String?
  }

  public struct LoggedOp {
    public var seq: Int
    public var type: String
    public var op: Data
    public var sig: String?
    public var enc: String?
    public var purged = false
    public var subject: String?
    public var at: Date
  }

  public struct Space {
    public var ownerKind: String
    public var ownerMember: String?
    public var orgID: String?
    public var policy: SpacePolicy
    public var epoch = 1
    public var rotationPending = false
    public var archived = false
    public var created: Date
    public var members: [String: Member] = [:]
    public var memberOrder: [String] = []
    public var devices: [String: Device] = [:]
    public var wraps: [String: String] = [:]  // "epoch|device"
    public var links: [Int: String] = [:]
    public var log: [LoggedOp] = []
    public var items: [String: Item] = [:]
    public var itemKeys: [String: (epoch: Int, wrapped: String)] = [:]
    public var blobs: [String: (data: Data, status: String, device: String, item: String?)] = [:]
    public var invites:
      [String: (hash: String, expires: Date, role: SpaceRole, outside: Bool, status: String)] = [:]
    public var joins:
      [String: (
        member: String, device: SpaceDevicePublic, profile: String?, status: String, invite: String,
        created: Date, request: Data, sig: String, binding: String
      )] = [:]
    /// Item → (contributor, recording, start, end) of a shared part.
    public var segments: [String: (member: String, parent: String, start: Int, end: Int)] = [:]
    public var hidden: Set<String> = []  // "member|item"
    public var forks: Set<String> = []  // "member|item"
    public var takedowns:
      [String: (item: String, kind: String, requester: String, status: String, due: Date?)] = [:]
    public var proposals: [String: String] = [:]
    public var audit: [(action: String, member: String?)] = []
    // Organizer.
    public var storeKeyID: String?
    public var maskKeyID: String?
    public var leaseOpen = false
    public var payloads: [String: SpaceJSON] = [:]
    public var payloadRevisions: [String: Int] = [:]
    public var origins: [String: (member: String, matter: String?)] = [:]
    // v8.
    public var escrow: [String: String] = [:]  // "epoch|device" → wrap
    public var snapshotCites: [String: [String]] = [:]
    public var audioParts: [String: String] = [:]  // "member|recording" → item
    /// Items that just left, whose citing snapshots go after the op is logged.
    var cascade: [String] = []
  }

  let lock = NSLock()
  public var now = Date(timeIntervalSince1970: 1_790_000_000)
  public internal(set) var spaces: [String: Space] = [:]
  var orgs: [String: FakeOrg] = [:]
  var backups: [String: Space] = [:]
  var packs: [String: (space: String, matter: String, pack: SpaceJSON, markdown: String)] = [:]
  public internal(set) var access: [String: FakeAccess] = [:]
  var tickets: [String: FakeTicket] = [:]
  var accessAudit: [(action: String, target: SpaceJSON)] = []
  var failures: [String: (code: String, status: Int)] = [:]
  var lostAnswers: Set<String> = []
  /// Every request as sent (method, target, body).
  public private(set) var requests: [SpaceHTTPRequest] = []
  /// Lent keys, as the real organizer would hold them in memory.
  public private(set) var leases: [(space: String, storeKey: String, maskKey: String)] = []
  var nonces: Set<String> = []
  /// Tests: fail every request (the link is down).
  public var offline = false

  public static let hostKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISyntheticHostKeyForTestsOnly00000000000"

  public init() {}

  public func advance(hours: Double) {
    lock.withLock { now = now.addingTimeInterval(hours * 3_600) }
  }

  public func space(_ id: String) -> Space? { lock.withLock { spaces[id] } }

  /// Every byte this Spark holds or was sent, for sentinel scans.
  public var everythingReceived: Data {
    lock.withLock {
      var all = Data()
      for request in requests {
        all.append(Data(request.target.utf8))
        all.append(request.body ?? Data())
      }
      return all
    }
  }

  /// Tests: rewrite one logged op's bytes (a Spark that tampers).
  public func tamper(space spaceID: String, seq: Int, _ change: (inout Data) -> Void) {
    lock.withLock {
      guard let index = spaces[spaceID]?.log.firstIndex(where: { $0.seq == seq }) else { return }
      change(&spaces[spaceID]!.log[index].op)
    }
  }

  /// Tests: append an op signed by a key the space does not know.
  public func injectForeignOp(space spaceID: String, op: SpaceWireOp) {
    lock.withLock {
      guard var space = spaces[spaceID] else { return }
      let seq = (space.log.last?.seq ?? 0) + 1
      space.log.append(
        LoggedOp(
          seq: seq, type: op.type, op: op.opJSON, sig: op.signature, enc: op.enc,
          subject: nil, at: now))
      spaces[spaceID] = space
    }
  }

  // MARK: - Transport

  public func send(_ request: SpaceHTTPRequest) async throws -> SpaceHTTPResponse {
    try lock.withLock {
      if offline { throw URLError(.notConnectedToInternet) }
      requests.append(request)
      do {
        return try route(request)
      } catch let error as FakeError {
        var body: [String: SpaceJSON] = ["error": .string(error.code)]
        for (key, value) in error.extra { body[key] = value }
        return SpaceHTTPResponse(status: error.status, body: try SpaceJSON.object(body).encoded())
      }
    }
  }

  struct FakeError: Error {
    let status: Int
    let code: String
    var extra: [String: SpaceJSON] = [:]
  }

  func need(_ condition: Bool, _ status: Int, _ code: String) throws {
    if !condition { throw FakeError(status: status, code: code) }
  }

  func ok(_ value: SpaceJSON) throws -> SpaceHTTPResponse {
    SpaceHTTPResponse(status: 200, body: try value.encoded())
  }

  func route(_ request: SpaceHTTPRequest) throws -> SpaceHTTPResponse {
    let parts = request.target.split(separator: "?", maxSplits: 1)
    let path = String(parts[0])
    let query = parts.count > 1 ? String(parts[1]) : ""
    let segments = path.split(separator: "/").map(String.init)
    let body = request.body ?? Data()
    func json() throws -> SpaceJSON { try SpaceJSON.decode(body) }
    if let answer = try routeV8(request, path: path, query: query, segments: segments) {
      return answer
    }
    switch (request.method, segments.count) {
    case ("GET", 3) where segments[2] == "host-keys":
      return try ok(["host_keys": [.string(Self.hostKey)]])
    case ("POST", 2) where segments[1] == "orgs":
      return try ok(createOrg(try json()))
    case ("POST", 2) where segments[1] == "spaces":
      return try ok(createSpace(try json()))
    case ("POST", 4) where segments[3] == "ops":
      return try ok(applyOps(segments[2], try json()["ops"]?.array ?? []))
    case ("POST", 4) where segments[3] == "join":
      return try ok(join(segments[2], try json()))
    default:
      break
    }
    let spaceID = segments.count > 2 ? segments[2] : ""
    if request.method == "GET", segments.count == 5, segments[3] == "join" {
      return try ok(joinStatus(spaceID, segments[4], request))
    }
    if request.method == "GET", segments == ["v1", "spaces"] {
      let device = try authenticateDevice(request)
      return try ok(["device_id": .string(device), "spaces": [], "orgs": [], "pending_joins": []])
    }
    let (member, role) = try authenticate(spaceID, request)
    guard var space = spaces[spaceID] else { throw FakeError(status: 404, code: "unknown_space") }
    defer { spaces[spaceID] = space }
    let tail = Array(segments.dropFirst(3))
    switch (request.method, tail) {
    case ("GET", []):
      sweep(&space, spaceID: spaceID)
      return try ok(summary(space, spaceID: spaceID, member: member, role: role, request: request))
    case ("GET", ["ops"]):
      let since = Int(Self.param(query, "since") ?? "0") ?? 0
      let limit = Int(Self.param(query, "limit") ?? "200") ?? 200
      let rows = space.log.filter { $0.seq > since }
      let page = Array(rows.prefix(limit))
      let entries: [SpaceJSON] = page.compactMap { op in
        if op.type == "item.hide",
          (try? SpaceJSON.decode(op.op))?["member_id"]?.string != member
        {
          return nil
        }
        var entry: SpaceJSON = [
          "seq": SpaceJSON(op.seq), "type": .string(op.type),
          "applied_at": .string(SpaceTime.string(op.at)), "op": .string(Base64URL.encode(op.op)),
          "sig": op.sig.map(SpaceJSON.string) ?? .null,
          "enc": op.enc.map(SpaceJSON.string) ?? .null,
          "purged": .bool(op.purged),
        ]
        if op.type == "item.share" {
          if let subject = op.subject, let item = space.items[subject], item.status == "active",
            item.shareSeq == op.seq, let key = space.itemKeys[subject]
          {
            entry = entry.setting(
              "item_key", ["epoch": SpaceJSON(key.epoch), "wrapped_dk": .string(key.wrapped)])
          } else {
            entry = entry.setting("item_key", .null)
          }
        }
        return entry
      }
      return try ok([
        "ops": .array(entries), "cursor": SpaceJSON(page.last?.seq ?? since),
        "more": .bool(rows.count > limit), "head": SpaceJSON(space.log.last?.seq ?? 0),
      ])
    case ("GET", ["keys"]):
      let device = request.headers["X-Mindloom-Device"] ?? ""
      let wraps: [SpaceJSON] = space.wraps.compactMap { key, wrap in
        let parts = key.split(separator: "|")
        guard parts.count == 2, String(parts[1]) == device, let epoch = Int(parts[0]) else {
          return nil
        }
        return ["epoch": SpaceJSON(epoch), "wrap": .string(wrap)]
      }.sorted { ($0["epoch"]?.int ?? 0) < ($1["epoch"]?.int ?? 0) }
      return try ok([
        "epoch": SpaceJSON(space.epoch), "rotation_pending": .bool(space.rotationPending),
        "wraps": .array(wraps),
        "epoch_links": .array(
          space.links.sorted { $0.key < $1.key }.map {
            ["epoch": SpaceJSON($0.key), "prev_wrap": .string($0.value)]
          }),
      ])
    case ("GET", ["item-keys"]):
      let stale = Self.param(query, "stale") == "1"
      let ids = Self.params(query, "item_id")
      let rows = space.items.filter { id, item in
        item.status == "active"
          && (stale ? (space.itemKeys[id]?.epoch ?? 0) < space.epoch : ids.contains(id))
      }
      return try ok([
        "epoch": SpaceJSON(space.epoch),
        "items": .array(
          rows.compactMap { id, item in
            guard let key = space.itemKeys[id] else { return nil }
            return [
              "item_id": .string(id), "revision": SpaceJSON(item.revision),
              "epoch": SpaceJSON(key.epoch), "wrapped_dk": .string(key.wrapped),
            ]
          }),
      ])
    case ("PUT", ["item-keys"]):
      try need(role >= .write, 403, "forbidden")
      var n = 0
      for rewrap in try json()["rewraps"]?.array ?? [] {
        guard let id = rewrap["item_id"]?.string, rewrap["epoch"]?.int == space.epoch,
          let wrapped = rewrap["wrapped_dk"]?.string, wrapped.hasPrefix("mlikey1."),
          space.items[id]?.status == "active", (space.itemKeys[id]?.epoch ?? 0) < space.epoch
        else { continue }
        space.itemKeys[id] = (space.epoch, wrapped)
        n += 1
      }
      return try ok(["rewrapped": SpaceJSON(n), "epoch": SpaceJSON(space.epoch)])
    case ("PUT", let path) where path.count == 2 && path[0] == "blobs":
      try need(role >= .write, 403, "forbidden")
      try need(body.prefix(4) == Data("MLB1".utf8), 422, "not_ciphertext")
      space.blobs[path[1]] = (body, "pending", request.headers["X-Mindloom-Device"] ?? "", nil)
      return try ok(["blob_id": .string(path[1]), "size": SpaceJSON(body.count)])
    case ("GET", let path) where path.count == 2 && path[0] == "blobs":
      guard let blob = space.blobs[path[1]], blob.status == "attached" else {
        throw FakeError(status: 410, code: "blob_gone")
      }
      return SpaceHTTPResponse(status: 200, body: blob.data)
    case ("GET", ["join-requests"]):
      try need(role == .admin, 403, "forbidden")
      return try ok([
        "requests": .array(
          space.joins.filter { $0.value.status == "pending" }.map { id, join in
            [
              "request_id": .string(id), "invite_id": .string(join.invite),
              "member_id": .string(join.member), "device": join.device.json,
              "profile": join.profile.map(SpaceJSON.string) ?? .null, "status": "pending",
              "created_at": .string(SpaceTime.string(join.created)),
              "role": .string(space.invites[join.invite]?.role.rawValue ?? "write"),
              "outside": .bool(false), "request": .string(Base64URL.encode(join.request)),
              "sig": .string(join.sig), "binding": .string(join.binding),
            ]
          })
      ])
    case ("GET", ["takedowns"]):
      sweep(&space, spaceID: spaceID)
      return try ok([
        "takedowns": .array(
          space.takedowns.filter { $0.value.status == "open" }.map { id, t in
            [
              "takedown_id": .string(id), "item_id": .string(t.item), "kind": .string(t.kind),
              "requester": .string(t.requester), "status": .string(t.status),
              "due_at": t.due.map { .string(SpaceTime.string($0)) } ?? .null,
            ]
          })
      ])
    case ("GET", ["proposals"]):
      return try ok(["proposals": [], "organizer": []])
    case ("GET", ["audit"]):
      try need(role == .admin, 403, "forbidden")
      return try ok([
        "records": .array(
          space.audit.enumerated().map { index, record in
            [
              "id": SpaceJSON(index + 1), "space_id": .string(spaceID),
              "at": .string(SpaceTime.string(now)), "action": .string(record.action),
              "actor_member": record.member.map(SpaceJSON.string) ?? .null,
              "target": ["count": 1],
            ]
          }),
        "cursor": SpaceJSON(space.audit.count),
      ])
    case ("POST", ["organizer", "lease"]):
      let lease = try json()
      try need(lease["epoch"]?.int == space.epoch, 409, "stale_epoch")
      guard let storeHex = lease["store_key"]?.string, let maskHex = lease["mask_key"]?.string,
        let store = Data(spaceHex: storeHex), let mask = Data(spaceHex: maskHex)
      else { throw FakeError(status: 400, code: "bad_request") }
      let maskID = SpaceCrypto.maskKeyID(mask)
      if let on = space.maskKeyID, on != maskID {
        throw FakeError(status: 409, code: "wrong_mask_key")
      }
      let keyID = SpaceCrypto.storeKeyID(store)
      if let on = space.storeKeyID, on != keyID {
        guard let previous = lease["previous"]?["store_key"]?.string.flatMap(Data.init(spaceHex:)),
          SpaceCrypto.storeKeyID(previous) == on
        else {
          throw FakeError(
            status: 409, code: "wrong_key",
            extra: ["key_id": .string(on), "epoch": SpaceJSON(space.epoch - 1)])
        }
      }
      space.storeKeyID = keyID
      space.maskKeyID = maskID
      space.leaseOpen = true
      leases.append((spaceID, storeHex, maskHex))
      space.audit.append(("organizer.lease", member))
      return try ok([
        "locked": false, "key_id": .string(keyID), "created": false, "store_id": "store",
        "epoch": SpaceJSON(space.epoch), "lease_s": 600, "purged": 0,
      ])
    case ("POST", ["backup"]):
      try need(role == .admin, 403, "forbidden")
      return try backupStream(spaceID, space, request: request, body: try json())
    case ("POST", ["organizer", "handover-pack"]):
      try need(role >= .write, 403, "forbidden")
      return try handoverPackRequest(spaceID, space, body: try json())
    case ("GET", let path)
    where path.count == 3 && path[0] == "organizer" && path[1] == "handover-pack":
      return try ok(handoverPackGet(path[2]))
    case ("POST", ["organizer", "lock"]):
      space.leaseOpen = false
      return try ok(["locked": true])
    case ("GET", ["organizer", "pending"]):
      try need(role >= .write, 403, "forbidden")
      try need(space.leaseOpen, 423, "locked")
      let pending = space.items.filter { id, item in
        item.status == "active" && (space.payloadRevisions[id] ?? -1) < item.revision
      }.sorted { $0.value.shareSeq < $1.value.shareSeq }
      return try ok([
        "items": .array(
          pending.map { id, item in
            [
              "item_id": .string(id), "revision": SpaceJSON(item.revision),
              "contributor": .string(item.contributor), "kind": .string(item.kind),
            ]
          })
      ])
    case ("POST", ["organizer", "items"]):
      try need(role >= .write, 403, "forbidden")
      try need(space.leaseOpen, 423, "locked")
      var accepted = 0
      for payload in try json()["items"]?.array ?? [] {
        guard let id = payload["item_id"]?.string?.lowercased(), let item = space.items[id] else {
          throw FakeError(status: 404, code: "unknown_item")
        }
        try need(item.status == "active", 410, "item_gone")
        try need(payload["revision"]?.int == item.revision, 409, "revision_mismatch")
        space.payloads[id] = payload
        space.payloadRevisions[id] = item.revision
        space.origins[id] = (item.contributor, payload["origin_matter_id"]?.string)
        accepted += 1
      }
      return try ok(["accepted": SpaceJSON(accepted), "duplicates": 0])
    case ("GET", ["organizer", "state"]):
      try need(space.leaseOpen, 423, "locked")
      return try ok(organizerState(space))
    case ("POST", ["organizer", "decisions"]):
      try need(role >= .maintain, 403, "forbidden")
      let decisions = try json()["decisions"]?.array ?? []
      return try ok(["applied": SpaceJSON(decisions.count), "rejected": []])
    default:
      throw FakeError(status: 404, code: "no_route")
    }
  }

  static func param(_ query: String, _ name: String) -> String? { params(query, name).first }

  static func params(_ query: String, _ name: String) -> [String] {
    query.split(separator: "&").compactMap { pair in
      let kv = pair.split(separator: "=", maxSplits: 1)
      guard kv.count == 2, kv[0] == name else { return nil }
      return String(kv[1]).removingPercentEncoding
    }
  }

  // MARK: - Authentication

  func checkSignature(_ request: SpaceHTTPRequest, signPub: Data) throws {
    let h = request.headers
    guard let date = h["X-Mindloom-Date"], let nonce = h["X-Mindloom-Nonce"],
      let sig = h["X-Mindloom-Signature"], let seconds = Double(date),
      abs(seconds - now.timeIntervalSince1970) <= 300
    else { throw FakeError(status: 401, code: "bad_signature") }
    let message = SpaceSignatures.requestMessage(
      method: request.method, target: request.target, date: date, nonce: nonce,
      body: request.body ?? Data())
    guard SpaceSignatures.verify(signPub: signPub, message: message, signature: sig) else {
      throw FakeError(status: 401, code: "bad_signature")
    }
    guard nonces.insert(nonce).inserted else { throw FakeError(status: 401, code: "replayed") }
  }

  func authenticateDevice(_ request: SpaceHTTPRequest) throws -> String {
    guard let id = request.headers["X-Mindloom-Device"],
      let key = spaces.values.compactMap({ $0.devices[id]?.signPub }).first
    else { throw FakeError(status: 401, code: "unknown_device") }
    try checkSignature(request, signPub: key)
    return id
  }

  func authenticate(_ spaceID: String, _ request: SpaceHTTPRequest) throws -> (
    String, SpaceRole
  ) {
    guard let space = spaces[spaceID] else { throw FakeError(status: 404, code: "unknown_space") }
    guard let id = request.headers["X-Mindloom-Device"], let device = space.devices[id] else {
      throw FakeError(status: 401, code: "unknown_device")
    }
    try checkSignature(request, signPub: device.signPub)
    guard device.status == "active", let member = space.members[device.member],
      member.status == "active"
    else {
      let forks = space.forks.filter { $0.hasPrefix(device.member + "|") }.map {
        SpaceJSON.string(String($0.split(separator: "|")[1]))
      }
      var extra: [String: SpaceJSON] = [
        "member_status": .string(space.members[device.member]?.status ?? "removed"),
        "purge_forks": .array(forks),
      ]
      // The signed op that ended this device's access, for the Mac to check.
      if let ending = space.log.last(where: { logged in
        guard let op = try? SpaceJSON.decode(logged.op) else { return false }
        switch logged.type {
        case "member.remove": return op["body"]?["member_id"]?.string == device.member
        case "device.remove": return op["body"]?["device_id"]?.string == id
        case "member.leave": return op["member_id"]?.string == device.member
        default: return false
        }
      }) {
        extra["removal"] = [
          "seq": SpaceJSON(ending.seq), "type": .string(ending.type),
          "applied_at": .string(SpaceTime.string(ending.at)),
          "op": .string(Base64URL.encode(ending.op)),
          "sig": ending.sig.map(SpaceJSON.string) ?? .null,
          "enc": .null, "purged": false,
        ]
      }
      throw FakeError(status: 403, code: "not_member", extra: extra)
    }
    return (device.member, effectiveRole(space, member: device.member))
  }

  func effectiveRole(_ space: Space, member: String) -> SpaceRole {
    if space.ownerKind == "person", space.ownerMember == member { return .admin }
    if let org = space.orgID, orgs[org]?.isAdmin(member) == true { return .admin }
    return space.members[member]?.role ?? .read
  }

  // MARK: - Orgs and spaces

  func parse(_ wire: SpaceJSON) throws -> (SpaceJSON, Data, String) {
    guard let opString = wire["op"]?.string, let bytes = Base64URL.decode(opString),
      let op = try? SpaceJSON.decode(bytes), let sig = wire["sig"]?.string
    else { throw FakeError(status: 400, code: "bad_op") }
    for (field, key) in [("enc", "enc_sha256"), ("wrapped_dk", "wrapped_dk_sha256")] {
      if let value = wire[field]?.string {
        try need(op[key]?.string == SpaceCrypto.detachedHash(value), 400, "detached_mismatch")
      }
    }
    return (op, bytes, sig)
  }

  func createOrg(_ wire: SpaceJSON) throws -> SpaceJSON {
    let (op, bytes, sig) = try parse(wire)
    guard let orgID = op["org_id"]?.string, let member = op["member_id"]?.string,
      let device = op["body"]?["device"], let pub = device["sign_pub"]?.string,
      let key = Base64URL.decode(pub), let deviceID = device["device_id"]?.string
    else { throw FakeError(status: 400, code: "bad_op") }
    try need(SpaceSignatures.verifyOp(bytes, signature: sig, signPub: key), 401, "bad_signature")
    if let owner = memberOfDevice(deviceID) {
      try need(owner == member, 409, "device_member_conflict")
    }
    var org = FakeOrg()
    org.admins[member] = "active"
    org.devices[deviceID] = .init(
      member: member, signPub: key, signPubB64: pub,
      sealPub: device["seal_pub"]?.string ?? "")
    org.policy = op["body"]?["policy"]?["recovery_admins"]?.int ?? 1
    org.log.append(LoggedOp(seq: 1, type: "org.create", op: bytes, sig: sig, enc: nil, at: now))
    orgs[orgID] = org
    return ["ok": true, "org_id": .string(orgID), "seq": 1]
  }

  func createSpace(_ wire: SpaceJSON) throws -> SpaceJSON {
    let (op, bytes, sig) = try parse(wire)
    let body = op["body"] ?? [:]
    guard op["type"]?.string == "space.create", let spaceID = op["space_id"]?.string,
      let member = op["member_id"]?.string, let device = body["device"],
      let record = try? device.decoded(as: SpaceDevicePublic.self), let key = record.signKey
    else { throw FakeError(status: 400, code: "bad_op") }
    try need(SpaceSignatures.verifyOp(bytes, signature: sig, signPub: key), 401, "bad_signature")
    try need(op["epoch"]?.int == 1, 422, "bad_field")
    try need(spaces[spaceID] == nil, 409, "space_exists")
    let kind = body["owner"]?["kind"]?.string ?? "person"
    let orgID = body["owner"]?["org_id"]?.string
    if kind == "org" {
      try need(
        orgID.flatMap { orgs[$0] }.map { $0.isAdmin(member) } == true, 403, "forbidden")
    }
    var policy = kind == "org" ? SpacePolicy.org : SpacePolicy.group
    if let given = body["policy"],
      let merged = try? policy.json.merging(given).decoded(as: SpacePolicy.self)
    {
      policy = merged
    }
    var space = Space(
      ownerKind: kind, ownerMember: kind == "person" ? member : nil, orgID: orgID, policy: policy,
      created: now)
    space.members[member] = Member(role: .admin, joined: now)
    space.memberOrder.append(member)
    space.devices[record.deviceID] = Device(
      member: member, signPub: key, sealPub: record.sealPub, signPubB64: record.signPub)
    for wrap in body["wraps"]?.array ?? [] {
      guard let device = wrap["device_id"]?.string, let value = wrap["wrap"]?.string else {
        continue
      }
      try need(value.hasPrefix("mlwrap1."), 422, "not_ciphertext")
      space.wraps["1|\(device)"] = value
    }
    try need(wire["enc"]?.string?.hasPrefix("mlenc1.") ?? true, 422, "not_ciphertext")
    if let owner = memberOfDevice(record.deviceID) {
      try need(owner == member, 409, "device_member_conflict")
    }
    try storeEscrow(&space, epoch: 1, wraps: body["escrow_wraps"]?.array)
    try checkEscrow(space, epoch: 1)
    space.log.append(
      LoggedOp(
        seq: 1, type: "space.create", op: bytes, sig: sig, enc: wire["enc"]?.string, at: now))
    space.audit.append(("space.create", member))
    spaces[spaceID] = space
    return [
      "ok": true, "op_id": .string(op["op_id"]?.string ?? ""), "duplicate": false, "seq": 1,
      "effects": ["space_id": .string(spaceID), "epoch": 1],
    ]
  }

  func summary(
    _ space: Space, spaceID: String, member: String, role: SpaceRole, request: SpaceHTTPRequest
  ) -> SpaceJSON {
    let members: [SpaceJSON] = space.memberOrder.compactMap { id in
      guard let m = space.members[id] else { return nil }
      let devices: [SpaceJSON] = space.devices.filter { $0.value.member == id }.map { did, d in
        [
          "device_id": .string(did), "sign_pub": .string(d.signPubB64),
          "seal_pub": .string(d.sealPub), "status": .string(d.status),
        ]
      }
      return [
        "member_id": .string(id), "role": .string(m.role.rawValue),
        "effective_role": .string(effectiveRole(space, member: id).rawValue),
        "outside": .bool(m.outside), "status": .string(m.status),
        "owner": .bool(space.ownerKind == "person" && space.ownerMember == id),
        "org_admin": .bool(space.orgID.flatMap { orgs[$0]?.isAdmin(id) } ?? false),
        "joined_at": .string(SpaceTime.string(m.joined)),
        "ended_at": m.ended.map { .string(SpaceTime.string($0)) } ?? .null,
        "devices": .array(devices),
        "usage_bytes": role == .admin ? SpaceJSON(usage(space, member: id)) : .null,
      ]
    }
    var owner: SpaceJSON = ["kind": .string(space.ownerKind)]
    if let ownerMember = space.ownerMember {
      owner = owner.setting("member_id", .string(ownerMember))
    }
    if let org = space.orgID { owner = owner.setting("org_id", .string(org)) }
    return [
      "space_id": .string(spaceID), "owner": owner, "policy": space.policy.json,
      "epoch": SpaceJSON(space.epoch), "rotation_pending": .bool(space.rotationPending),
      "archived": .bool(space.archived), "head": SpaceJSON(space.log.last?.seq ?? 0),
      "created_at": .string(SpaceTime.string(space.created)), "members": .array(members),
      "me": [
        "member_id": .string(member),
        "device_id": .string(request.headers["X-Mindloom-Device"] ?? ""),
        "role": .string(role.rawValue),
        "rights": SpaceJSON(SpaceRules.rights(role: role, policy: space.policy)),
        "hidden": SpaceJSON(
          space.hidden.filter { $0.hasPrefix(member + "|") }.map {
            String($0.split(separator: "|")[1])
          }),
        "forks": SpaceJSON(
          space.forks.filter { $0.hasPrefix(member + "|") }.map {
            String($0.split(separator: "|")[1])
          }),
        "usage": [
          "bytes": SpaceJSON(usage(space, member: member)),
          "quota_bytes": (space.policy.memberQuotaMB ?? 2048) > 0
            ? SpaceJSON((space.policy.memberQuotaMB ?? 2048) * 1_048_576) : .null,
        ],
      ],
      "escrow": escrowStatus(space, epoch: space.epoch) ?? .null,
      "limits": (try? SpaceJSON.from(SpaceLimits.standard)) ?? .null,
      "counts": [
        "items": SpaceJSON(space.items.values.filter { $0.status == "active" }.count),
        "open_takedowns": 0, "open_proposals": 0,
        "pending_joins": SpaceJSON(space.joins.values.filter { $0.status == "pending" }.count),
      ],
      "organizer": ["locked": .bool(!space.leaseOpen)],
    ]
  }

  // MARK: - Join

  func join(_ spaceID: String, _ wire: SpaceJSON) throws -> SpaceJSON {
    guard var space = spaces[spaceID] else { throw FakeError(status: 404, code: "unknown_space") }
    guard let raw = wire["request"]?.string.flatMap({ Base64URL.decode($0) }),
      let request = try? SpaceJSON.decode(raw), let sig = wire["sig"]?.string,
      let device = try? request["device"]?.decoded(as: SpaceDevicePublic.self),
      let key = device.signKey, let inviteID = request["invite_id"]?.string,
      let requestID = request["request_id"]?.string, let member = request["member_id"]?.string,
      wire["invite_secret"] == nil,
      let gate = wire["invite_gate"]?.string.flatMap({ Base64URL.decode($0) }), gate.count == 32,
      let binding = wire["invite_binding"]?.string, binding.count == 64
    else { throw FakeError(status: 400, code: "bad_request") }
    try need(
      SpaceSignatures.verify(
        signPub: key, message: SpaceSignatures.joinDomain + raw, signature: sig),
      401, "bad_signature")
    guard var invite = space.invites[inviteID] else {
      throw FakeError(status: 404, code: "unknown_invite")
    }
    try need(invite.status == "open", 410, "invite_used")
    try need(invite.expires > now, 410, "invite_expired")
    try need(
      SpaceCrypto.sha256Hex(Data("mindloom-space-invite-v1".utf8) + gate) == invite.hash, 403,
      "bad_invite_secret")
    // A member id bound to another device key anywhere on this Spark is taken.
    let bound = spaces.values.flatMap { $0.devices.values.filter { $0.member == member } }
      .map(\.signPub)
    try need(bound.isEmpty || bound.contains(key), 409, "member_id_taken")
    invite.status = "used"
    space.invites[inviteID] = invite
    space.joins[requestID] = (
      member, device, wire["profile"]?.string, "pending", inviteID, now, raw, sig, binding
    )
    spaces[spaceID] = space
    return ["ok": true, "duplicate": false, "request_id": .string(requestID), "status": "pending"]
  }

  func joinStatus(_ spaceID: String, _ requestID: String, _ request: SpaceHTTPRequest)
    throws -> SpaceJSON
  {
    guard let join = spaces[spaceID]?.joins[requestID],
      request.headers["X-Mindloom-Device"] == join.device.deviceID, let key = join.device.signKey
    else { throw FakeError(status: 404, code: "unknown_request") }
    try checkSignature(request, signPub: key)
    return [
      "request_id": .string(requestID), "status": .string(join.status),
      "member_id": .string(join.member),
    ]
  }

  // MARK: - Ops

  func applyOps(_ spaceID: String, _ wires: [SpaceJSON]) throws -> SpaceJSON {
    guard spaces[spaceID] != nil else { throw FakeError(status: 404, code: "unknown_space") }
    var results: [SpaceJSON] = []
    for wire in wires {
      do {
        let type = (try? parse(wire))?.0["type"]?.string ?? ""
        if let failure = failures.removeValue(forKey: type) {
          throw FakeError(status: failure.status, code: failure.code)
        }
        let result = try applyOne(spaceID, wire)
        if lostAnswers.remove(type) != nil { throw URLError(.networkConnectionLost) }
        results.append(result)
      } catch let error as FakeError {
        var result: SpaceJSON = [
          "ok": false, "status": SpaceJSON(error.status), "error": .string(error.code),
          "retry": .string(Self.retryCodes[error.code] ?? "never"),
        ]
        for (key, value) in error.extra { result = result.setting(key, value) }
        results.append(result)
      }
    }
    return ["results": .array(results), "head": SpaceJSON(spaces[spaceID]?.log.last?.seq ?? 0)]
  }

  func applyOne(_ spaceID: String, _ wire: SpaceJSON) throws -> SpaceJSON {
    let (op, bytes, sig) = try parse(wire)
    var space = spaces[spaceID]!
    guard let type = op["type"]?.string, let member = op["member_id"]?.string,
      let deviceID = op["device_id"]?.string, op["space_id"]?.string == spaceID
    else { throw FakeError(status: 400, code: "bad_op") }
    if let opID = op["op_id"]?.string,
      let existing = space.log.first(where: {
        (try? SpaceJSON.decode($0.op))?["op_id"]?.string == opID
      })
    {
      return ["ok": true, "duplicate": true, "seq": SpaceJSON(existing.seq)]
    }
    if type == "space.recover" {
      let effects = try recoverOp(spaceID, &space, op: op, bytes: bytes, sig: sig)
      let seq = (space.log.last?.seq ?? 0) + 1
      space.log.append(LoggedOp(seq: seq, type: type, op: bytes, sig: sig, enc: nil, at: now))
      spaces[spaceID] = space
      return ["ok": true, "seq": SpaceJSON(seq), "effects": effects]
    }
    guard let device = space.devices[deviceID], device.member == member else {
      throw FakeError(status: 403, code: "unknown_device")
    }
    try need(
      SpaceSignatures.verifyOp(bytes, signature: sig, signPub: device.signPub), 401, "bad_signature"
    )
    guard device.status == "active", space.members[member]?.status == "active" else {
      throw FakeError(status: 403, code: "not_member")
    }
    let role = effectiveRole(space, member: member)
    let body = op["body"] ?? [:]
    let enc = wire["enc"]?.string
    if let enc { try need(enc.hasPrefix("mlenc1."), 422, "not_ciphertext") }
    if enc != nil { try need(op["epoch"]?.int == space.epoch, 409, "stale_epoch") }
    let seq = (space.log.last?.seq ?? 0) + 1
    var subject: String?
    var effects: SpaceJSON = [:]
    func needRole(_ minimum: SpaceRole) throws { try need(role >= minimum, 403, "forbidden") }
    switch type {
    case "member.profile", "agent.access":
      break
    case "space.meta":
      try needRole(.admin)
    case "space.policy":
      try needRole(.admin)
      if let changes = body["policy"],
        let merged = try? space.policy.json.merging(changes).decoded(as: SpacePolicy.self)
      {
        try need(space.ownerKind == "person" || merged.withdrawWindowHours != nil, 422, "bad_field")
        space.policy = merged
      }
    case "space.archive":
      try needRole(.admin)
      space.archived = body["archived"]?.bool ?? false
    case "invite.create":
      try needRole(.admin)
      try need(!space.archived, 403, "archived")
      try need(body["host_key"]?.string == Self.hostKey, 422, "host_key_mismatch")
      guard let id = body["invite_id"]?.string, let hash = body["secret_hash"]?.string,
        let expires = SpaceTime.date(body["expires_at"]?.string)
      else { throw FakeError(status: 422, code: "bad_field") }
      try need(expires <= now.addingTimeInterval(7 * 86_400), 422, "bad_field")
      space.invites[id] = (
        hash, expires, SpaceRole(rawValue: body["role"]?.string ?? "") ?? .write,
        body["outside"]?.bool ?? false, "open"
      )
    case "invite.revoke":
      try needRole(.admin)
      if let id = body["invite_id"]?.string { space.invites[id]?.status = "revoked" }
    case "join.approve":
      try needRole(.admin)
      try need(!space.rotationPending, 409, "rotation_pending")
      guard let requestID = body["request_id"]?.string, var join = space.joins[requestID],
        join.status == "pending"
      else { throw FakeError(status: 404, code: "unknown_request") }
      try need(
        body["member_id"]?.string == join.member
          && (try? body["device"]?.decoded(as: SpaceDevicePublic.self))?.json == join.device.json,
        422, "approve_mismatch")
      let wraps = body["wraps"]?.array ?? []
      try need(
        wraps.count == 1 && wraps[0]["device_id"]?.string == join.device.deviceID
          && wraps[0]["epoch"]?.int == space.epoch, 422, "bad_wraps")
      let roleName = body["role"]?.string ?? space.invites[join.invite]?.role.rawValue ?? "write"
      space.members[join.member] = Member(
        role: SpaceRole(rawValue: roleName) ?? .write, joined: now)
      space.memberOrder.append(join.member)
      space.devices[join.device.deviceID] = Device(
        member: join.member, signPub: join.device.signKey!, sealPub: join.device.sealPub,
        signPubB64: join.device.signPub)
      space.wraps["\(space.epoch)|\(join.device.deviceID)"] = wraps[0]["wrap"]?.string
      join.status = "approved"
      space.joins[requestID] = join
      effects = ["member_id": .string(join.member), "role": .string(roleName)]
    case "join.reject":
      try needRole(.admin)
      if let id = body["request_id"]?.string { space.joins[id]?.status = "rejected" }
    case "member.role":
      try needRole(.admin)
      if let id = body["member_id"]?.string, let r = body["role"]?.string.flatMap(SpaceRole.init) {
        space.members[id]?.role = r
      }
    case "device.add":
      guard let added = try? body["device"]?.decoded(as: SpaceDevicePublic.self),
        let addedKey = added.signKey, added.sealKey != nil
      else { throw FakeError(status: 422, code: "bad_field") }
      if let owner = memberOfDevice(added.deviceID) {
        try need(owner == member, 409, "device_member_conflict")
      }
      try need(space.devices[added.deviceID] == nil, 409, "device_exists")
      let wraps = body["wraps"]?.array ?? []
      try need(
        wraps.count == 1 && wraps[0]["device_id"]?.string == added.deviceID
          && wraps[0]["epoch"]?.int == space.epoch, 422, "bad_wraps")
      space.devices[added.deviceID] = Device(
        member: member, signPub: addedKey, sealPub: added.sealPub, signPubB64: added.signPub)
      space.wraps["\(space.epoch)|\(added.deviceID)"] = wraps[0]["wrap"]?.string
      effects = ["device_id": .string(added.deviceID)]
    case "escrow.wrap":
      try needRole(.admin)
      try need(body["epoch"]?.int == space.epoch, 409, "stale_epoch")
      let wraps = body["wraps"]?.array ?? []
      let members = Set(space.wraps.keys.filter { $0.hasPrefix("\(space.epoch)|") })
      try need(
        wraps.allSatisfy { !members.contains("\(space.epoch)|\($0["device_id"]?.string ?? "")") },
        422, "bad_field")
      try storeEscrow(&space, epoch: space.epoch, wraps: wraps)
      effects = [
        "epoch": SpaceJSON(space.epoch), "stored": SpaceJSON(wraps.count),
        "escrow_ok": escrowStatus(space, epoch: space.epoch)?["ok"] ?? true,
      ]
    case "member.remove", "epoch.rotate", "device.remove":
      // A member retires its own devices; an admin anyone's (and rotates).
      if type == "device.remove", let retired = body["device_id"]?.string {
        guard let retiredDevice = space.devices[retired] else {
          throw FakeError(status: 404, code: "unknown_device")
        }
        if retiredDevice.member != member { try needRole(.admin) }
        try need(retired != deviceID, 422, "bad_field")
        space.devices[retired]?.status = "removed"
      } else {
        try needRole(.admin)
      }
      let removed = type == "member.remove" ? body["member_id"]?.string : nil
      if let removed {
        try need(removed != space.ownerMember, 403, "forbidden")
        space.members[removed]?.status = "removed"
        space.members[removed]?.ended = now
        for (id, d) in space.devices where d.member == removed {
          space.devices[id]?.status = "removed"
        }
      }
      let next = space.epoch + 1
      try need(body["epoch"]?.int == next, 409, "stale_epoch")
      let remaining = Set(
        space.devices.filter {
          $0.value.status == "active" && space.members[$0.value.member]?.status == "active"
        }.keys)
      let wraps = body["wraps"]?.array ?? []
      let given = Set(wraps.compactMap { $0["device_id"]?.string })
      try need(given == remaining, 422, "bad_wraps")
      for wrap in wraps {
        space.wraps["\(next)|\(wrap["device_id"]!.string!)"] = wrap["wrap"]?.string
      }
      try storeEscrow(&space, epoch: next, wraps: body["escrow_wraps"]?.array)
      try checkEscrow(space, epoch: next)
      guard let link = body["epoch_link"]?.string, link.hasPrefix("mlelink1.") else {
        throw FakeError(status: 422, code: "bad_field")
      }
      space.links[next] = link
      space.epoch = next
      space.rotationPending = false
      space.leaseOpen = false
      effects = ["epoch": SpaceJSON(next)]
    case "member.leave":
      try need(member != space.ownerMember, 403, "owner_cannot_leave")
      space.members[member]?.status = "left"
      space.members[member]?.ended = now
      for (id, d) in space.devices where d.member == member {
        space.devices[id]?.status = "removed"
      }
      var withdrawn = 0
      if body["contributions"]?.string == "withdraw", space.policy.onLeave == "contributor_choice" {
        for (id, item) in space.items where item.contributor == member && item.status == "active" {
          purge(&space, id, status: "withdrawn", spaceID: spaceID)
          withdrawn += 1
        }
      }
      space.rotationPending = true
      space.leaseOpen = false
      effects = ["rotation_pending": true, "withdrawn": SpaceJSON(withdrawn)]
    case "item.share":
      try needRole(.write)
      try need(!space.archived, 403, "archived")
      guard let item = body["item_id"]?.string, let revision = body["revision"]?.int,
        let kind = body["kind"]?.string
      else { throw FakeError(status: 400, code: "bad_field") }
      try need(!SpaceEngine.neverShared.contains(kind), 422, "never_shared")
      try need(
        enc != nil && wire["wrapped_dk"]?.string?.hasPrefix("mlikey1.") == true, 400, "bad_op")
      let blobs = body["blobs"]?.array ?? []
      if let duplicate = try shareChecks(
        &space, item: item, member: member, revision: revision, kind: kind, body: body,
        blobs: blobs, enc: enc)
      {
        spaces[spaceID] = space
        return duplicate
      }
      try need(!space.rotationPending, 409, "rotation_pending")
      for blob in blobs {
        guard let id = blob["blob_id"]?.string, let stored = space.blobs[id],
          stored.status == "pending", stored.device == deviceID
        else { throw FakeError(status: 409, code: "unknown_blob") }
      }
      if !blobs.isEmpty {
        try need(space.policy.originals != "text_only", 403, "originals_not_allowed")
      }
      let audio = blobs.contains { $0["role"]?.string == "audio" }
      if audio || kind == "audio_segment" {
        guard let s = body["segment"], let a = s["start_ms"]?.int, let b = s["end_ms"]?.int else {
          throw FakeError(status: 422, code: "audio_needs_segment")
        }
        try need(b - a <= 15 * 60 * 1000, 422, "segment_too_long")
      }
      if let s = body["segment"], let parent = s["parent_item_id"]?.string?.lowercased(),
        let a = s["start_ms"]?.int, let b = s["end_ms"]?.int
      {
        let spans =
          space.segments.filter {
            $0.key != item && $0.value.member == member && $0.value.parent == parent
              && space.items[$0.key]?.status == "active"
          }.map { ($0.value.start, $0.value.end) } + [(a, b)]
        try need(SpaceEngine.covered(spans) <= 15 * 60 * 1000, 422, "recording_share_limit")
        space.segments[item] = (member, parent, a, b)
      }
      if let current = space.items[item] {
        try need(current.status == "active", 410, "item_gone")
        try need(current.contributor == member, 403, "forbidden")
        try need(revision > current.revision, 409, "stale_revision")
        let windowOpen =
          space.policy.withdrawWindowHours.map {
            now.timeIntervalSince(current.first) <= TimeInterval($0) * 3_600
          } ?? true
        try need(windowOpen, 403, "window_passed")
        for index in space.log.indices
        where space.log[index].subject == item && space.log[index].type == "item.share" {
          space.log[index].enc = nil
          space.log[index].purged = true
        }
        for (id, blob) in space.blobs where blob.item == item {
          space.blobs[id]?.status = "deleted"
        }
        space.items[item]?.revision = revision
        space.items[item]?.shareSeq = seq
      } else {
        space.items[item] = Item(
          contributor: member, kind: kind, revision: revision, shareSeq: seq, first: now)
      }
      space.items[item]?.shareKey = body["share_key"]?.string
      space.itemKeys[item] = (space.epoch, wire["wrapped_dk"]!.string!)
      for blob in blobs {
        let id = blob["blob_id"]!.string!
        space.blobs[id]?.status = "attached"
        space.blobs[id]?.item = item
      }
      subject = item
      effects = [
        "item_id": .string(item), "revision": SpaceJSON(revision), "epoch": SpaceJSON(space.epoch),
      ]
    case "item.withdraw", "item.delete":
      if let item = body["item_id"]?.string, let current = space.items[item],
        current.status == "withdrawn", current.contributor == member,
        let original = space.log.last(where: { $0.subject == item && $0.type != "item.share" })
      {
        // A remade withdraw of what this member already took back (v8 C3).
        return [
          "ok": true, "duplicate": true, "accepted_as": "withdrawn", "seq": SpaceJSON(original.seq),
        ]
      }
      guard let item = body["item_id"]?.string, let current = space.items[item],
        current.status == "active"
      else { throw FakeError(status: 410, code: "item_gone") }
      try need(current.contributor == member, 403, "forbidden")
      let open =
        space.policy.withdrawWindowHours.map {
          now.timeIntervalSince(current.first) <= TimeInterval($0) * 3_600
        } ?? true
      if open {
        purge(&space, item, status: "withdrawn", spaceID: spaceID)
        effects = ["item_id": .string(item), "status": "withdrawn"]
      } else if type == "item.withdraw" {
        throw FakeError(status: 403, code: "window_passed")
      } else {
        let opID = op["op_id"]?.string ?? ""
        let takedownID = SpaceEngine.takedownID(deleteOpID: opID)
        space.takedowns[takedownID] = (item, "other", member, "open", nil)
        effects = [
          "item_id": .string(item), "status": "takedown_requested",
          "takedown_id": .string(takedownID),
        ]
      }
      subject = item
    case "item.remove":
      try needRole(.maintain)
      guard let item = body["item_id"]?.string, space.items[item]?.status == "active" else {
        throw FakeError(status: 410, code: "item_gone")
      }
      purge(&space, item, status: "removed", spaceID: spaceID)
      subject = item
    case "item.hide":
      if let item = body["item_id"]?.string {
        if body["hidden"]?.bool == false {
          space.hidden.remove("\(member)|\(item)")
        } else {
          space.hidden.insert("\(member)|\(item)")
        }
      }
    case "item.fork":
      try need(space.policy.forksAllowed, 403, "forks_not_allowed")
      if let item = body["item_id"]?.string { space.forks.insert("\(member)|\(item)") }
    case "item.unfork":
      if let item = body["item_id"]?.string { space.forks.remove("\(member)|\(item)") }
    case "takedown.request":
      guard let id = body["takedown_id"]?.string, let item = body["item_id"]?.string,
        let current = space.items[item], current.status == "active"
      else { throw FakeError(status: 410, code: "item_gone") }
      let kind = body["kind"]?.string ?? "other"
      if kind == "other" { try need(current.contributor == member, 403, "forbidden") }
      let due =
        kind == "privacy"
        ? now.addingTimeInterval(TimeInterval(space.policy.takedownWindowHours) * 3_600) : nil
      space.takedowns[id] = (item, kind, member, "open", due)
      effects = ["takedown_id": .string(id), "kind": .string(kind)]
    case "takedown.resolve":
      try needRole(.maintain)
      guard let id = body["takedown_id"]?.string, let takedown = space.takedowns[id],
        takedown.status == "open"
      else { throw FakeError(status: 404, code: "unknown_takedown") }
      let accept = body["decision"]?.string == "accept"
      if !accept, takedown.kind == "privacy" {
        // The contributor's own privacy takedown is honoured; anyone else's may
        // be rejected with a reason.
        try need(
          space.items[takedown.item]?.contributor != takedown.requester, 403, "privacy_takedown")
        try need(enc != nil, 400, "bad_op")
      }
      space.takedowns[id]?.status = accept ? "done" : "rejected"
      if accept { purge(&space, takedown.item, status: "removed", spaceID: spaceID) }
    case "takedown.withdraw":
      if let id = body["takedown_id"]?.string { space.takedowns[id]?.status = "withdrawn" }
    case "matter.share":
      try needRole(.write)
      let ids = body["item_ids"]?.array?.compactMap(\.string) ?? []
      try need(
        ids.allSatisfy {
          space.items[$0]?.contributor == member && space.items[$0]?.status == "active"
        },
        422, "unknown_items")
    case "matter.unshare", "share_rule.set", "share_rule.clear", "proposal.create",
      "proposal.withdraw":
      try needRole(type == "proposal.withdraw" || type == "matter.unshare" ? .read : .write)
    case "proposal.resolve":
      try needRole(.maintain)
    case "matter.handover":
      try needRole(.maintain)
      if let pack = body["pack_item_id"]?.string {
        try need(
          space.items[pack]?.kind == "snapshot" && space.items[pack]?.status == "active", 422,
          "bad_field")
        effects = ["pack_item_id": .string(pack)]
      }
    default:
      throw FakeError(status: 400, code: "unknown_type")
    }
    space.log.append(
      LoggedOp(seq: seq, type: type, op: bytes, sig: sig, enc: enc, subject: subject, at: now))
    drainCascade(&space, spaceID: spaceID)
    space.audit.append((type, member))
    spaces[spaceID] = space
    return [
      "ok": true, "op_id": .string(op["op_id"]?.string ?? ""), "duplicate": false,
      "seq": SpaceJSON(seq), "effects": effects,
    ]
  }

  /// Crypto-shredding: the data key, the fields and the originals go.
  func purge(_ space: inout Space, _ item: String, status: String, spaceID: String = "") {
    if space.items[item]?.status == "active", !spaceID.isEmpty { space.cascade.append(item) }
    space.items[item]?.status = status
    space.itemKeys[item] = nil
    for index in space.log.indices
    where space.log[index].subject == item && space.log[index].type == "item.share" {
      space.log[index].enc = nil
      space.log[index].purged = true
    }
    for (id, blob) in space.blobs where blob.item == item {
      space.blobs[id]?.status = "deleted"
      space.blobs[id]?.data = Data()
    }
    space.payloads[item] = nil
  }

  /// An overdue privacy takedown is carried out by the Spark.
  func sweep(_ space: inout Space, spaceID: String) {
    for (id, takedown) in space.takedowns
    where takedown.status == "open" && takedown.kind == "privacy" && (takedown.due ?? now) < now {
      space.takedowns[id]?.status = "done"
      purge(&space, takedown.item, status: "removed", spaceID: spaceID)
      let seq = (space.log.last?.seq ?? 0) + 1
      let record: SpaceJSON = [
        "v": 1, "space_id": .string(spaceID), "op_id": .string(SpaceID.new()),
        "type": "system.remove", "member_id": .null, "device_id": .null,
        "body": [
          "item_id": .string(takedown.item), "reason": "takedown_overdue",
          "takedown_id": .string(id),
        ],
      ]
      space.log.append(
        LoggedOp(
          seq: seq, type: "system.remove", op: (try? record.encoded()) ?? Data(), sig: nil,
          enc: nil, subject: takedown.item, at: now))
      drainCascade(&space, spaceID: spaceID)
    }
  }

  /// A one-event state: every ingested item in one matter titled by the
  /// first payload's text (masked as it came), and the "同一件事" links.
  func organizerState(_ space: Space) -> SpaceJSON {
    let ids = space.payloads.keys.sorted()
    var events: [SpaceJSON] = []
    if let first = ids.first, let text = space.payloads[first]?["text"]?.string {
      events.append([
        "event_id": "ev-1", "title": .string(String(text.prefix(24))),
        "title_user_edited": false, "status_line": .string("共 \(ids.count) 条：" + text.prefix(40)),
        "status_facts": [], "importance": 0.9, "item_ids": SpaceJSON(ids), "person_ids": [],
        "pinned": false, "deleted": false, "provenance": [:], "segments": [],
      ])
    }
    var sameAs: [String: Int] = [:]
    for id in ids {
      if let origin = space.origins[id], let matter = origin.matter {
        sameAs["\(origin.member)|\(matter)", default: 0] += 1
      }
    }
    return [
      "cursor": 1, "events": .array(events), "questions": [], "persons": [], "unfiled": [],
      "readings": [], "store_id": "store",
      "same_as": .array(
        sameAs.sorted { $0.key < $1.key }.map { key, count in
          let parts = key.split(separator: "|")
          return [
            "event_id": "ev-1", "member_id": .string(String(parts[0])),
            "matter_id": .string(String(parts[1])), "items": SpaceJSON(count),
          ]
        }),
      "busy": ["queue": 0, "briefs": 0],
    ]
  }
}
