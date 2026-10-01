import CryptoKit
import Foundation
import MindloomLink
import MindloomSpaces

/// An organization as the in-memory Spark keeps it (v8: a signed log, admin
/// devices, the recovery policy).
public struct FakeOrg {
  public struct Device {
    public var member: String
    public var signPub: Data
    public var signPubB64: String
    public var sealPub: String
    public var status = "active"
  }

  public var admins: [String: String] = [:]
  public var devices: [String: Device] = [:]
  public var policy = 1
  public var log: [FakeSpaceSpark.LoggedOp] = []

  public func isAdmin(_ member: String) -> Bool { admins[member] == "active" }

  /// Every active device of every active admin.
  public var escrowDevices: [(id: String, device: Device)] {
    devices.filter { $0.value.status == "active" && isAdmin($0.value.member) }
      .sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
  }
}

/// The per-member access records of the in-memory Spark (v8 B1).
public struct FakeAccess {
  public var accessID: String
  public var memberID: String
  public var deviceID: String
  public var signPub: String
  public var sealPub: String
  public var keyB64: String
  public var credentialHash: String?
  public var status = "active"
  public var invitedBy: String?
  public var created: Date
  public var ended: Date?
}

public struct FakeTicket {
  public var kind: String
  public var memberID: String?
  public var secretHash: String
  public var keyB64: String
  public var createdBy: String
  public var expires: Date
  public var status = "open"
  public var failures = 0
}

/// A transport that adds a member's credential, as the gate's bridge does
/// (tests of the access routes and of member calls).
public struct FakeCredentialTransport: SpaceTransport {
  public let spark: FakeSpaceSpark
  public let credential: String

  public func send(_ request: SpaceHTTPRequest) async throws -> SpaceHTTPResponse {
    var headers = request.headers
    headers["Authorization"] = "Bearer \(credential)"
    return try await spark.send(
      SpaceHTTPRequest(
        method: request.method, target: request.target, body: request.body,
        contentType: request.contentType, headers: headers))
  }
}

extension FakeSpaceSpark {
  static let retryCodes: [String: String] = [
    "rotation_pending": "remake", "stale_epoch": "remake", "bad_epoch": "remake",
    "escrow_required": "remake", "unknown_blob": "later", "quota_exceeded": "later",
    "unavailable": "later", "busy": "later",
  ]

  public func credentialTransport(_ credential: String) -> FakeCredentialTransport {
    FakeCredentialTransport(spark: self, credential: credential)
  }

  public func org(_ id: String) -> FakeOrg? { lock.withLock { orgs[id] } }

  /// Tests: the Spark refuses every op of one type once (a lost answer, an
  /// overloaded queue …) with this code.
  public func failNext(_ type: String, code: String, status: Int = 409) {
    lock.withLock { failures[type] = (code, status) }
  }

  /// Tests: the next op of this type is applied, but its answer is lost.
  public func loseNextAnswer(_ type: String) {
    lock.withLock { lostAnswers.insert(type) }
  }

  // MARK: - Routes

  func routeV8(_ request: SpaceHTTPRequest, path: String, query: String, segments: [String])
    throws -> SpaceHTTPResponse?
  {
    let body = request.body ?? Data()
    func json() throws -> SpaceJSON { try SpaceJSON.decode(body) }
    if segments.count >= 2, segments[1] == "access" || segments[1] == "infra" {
      return try accessRoute(request, segments: segments, query: query)
    }
    if segments.count >= 3, segments[1] == "orgs" {
      let orgID = segments[2]
      guard orgs[orgID] != nil else { throw FakeError(status: 404, code: "unknown_org") }
      switch (request.method, Array(segments.dropFirst(3))) {
      case ("GET", []):
        _ = try authenticateOrg(orgID, request)
        return try ok(orgSummary(orgID))
      case ("POST", ["ops"]):
        var results: [SpaceJSON] = []
        for wire in try json()["ops"]?.array ?? [] {
          do { results.append(try applyOrgOp(orgID, wire)) } catch let error as FakeError {
            results.append([
              "ok": false, "status": SpaceJSON(error.status), "error": .string(error.code),
            ])
          }
        }
        return try ok(["results": .array(results)])
      case ("GET", ["escrow"]):
        let deviceID = try authenticateOrg(orgID, request)
        let rows: [SpaceJSON] = spaces.filter { $0.value.orgID == orgID }.sorted { $0.key < $1.key }
          .map { id, space in
            [
              "space_id": .string(id), "epoch": SpaceJSON(space.epoch),
              "wrap": space.escrow["\(space.epoch)|\(deviceID)"].map(SpaceJSON.string) ?? .null,
              "rotation_pending": .bool(space.rotationPending),
            ]
          }
        return try ok(["device_id": .string(deviceID), "spaces": .array(rows)])
      case ("GET", ["audit"]):
        _ = try authenticateOrg(orgID, request)
        return try ok(["records": [], "cursor": 0])
      default:
        return nil
      }
    }
    if request.method == "GET", segments == ["v1", "spaces"] {
      return try ok(spaceList(request))
    }
    if request.method == "POST", segments.count == 4, segments[1] == "spaces",
      segments[3] == "restore"
    {
      return try ok(restore(segments[2], request))
    }
    return nil
  }

  func authenticateOrg(_ orgID: String, _ request: SpaceHTTPRequest) throws -> String {
    guard let org = orgs[orgID], let id = request.headers["X-Mindloom-Device"],
      let device = org.devices[id]
    else { throw FakeError(status: 401, code: "unknown_device") }
    try checkSignature(request, signPub: device.signPub)
    guard device.status == "active", org.isAdmin(device.member) else {
      throw FakeError(status: 403, code: "forbidden")
    }
    return id
  }

  func knownSignKey(_ deviceID: String) -> Data? {
    if let key = spaces.values.compactMap({ $0.devices[deviceID]?.signPub }).first { return key }
    if let key = orgs.values.compactMap({ $0.devices[deviceID]?.signPub }).first { return key }
    return access.values.first { $0.deviceID == deviceID && $0.status == "active" }
      .flatMap { Base64URL.decode($0.signPub, allowPadding: true) }
  }

  /// The member a device id belongs to anywhere on this Spark (one device, one member).
  func memberOfDevice(_ deviceID: String) -> String? {
    if let m = spaces.values.compactMap({ $0.devices[deviceID]?.member }).first { return m }
    if let m = orgs.values.compactMap({ $0.devices[deviceID]?.member }).first { return m }
    return access.values.first { $0.deviceID == deviceID }?.memberID
  }

  func spaceList(_ request: SpaceHTTPRequest) throws -> SpaceJSON {
    guard let id = request.headers["X-Mindloom-Device"], let key = knownSignKey(id) else {
      throw FakeError(status: 401, code: "unknown_device")
    }
    try checkSignature(request, signPub: key)
    var rows: [SpaceJSON] = []
    for (spaceID, space) in spaces.sorted(by: { $0.key < $1.key }) {
      guard let device = space.devices[id], let member = space.members[device.member] else {
        continue
      }
      let active = device.status == "active" && member.status == "active"
      rows.append([
        "space_id": .string(spaceID), "owner_kind": .string(space.ownerKind),
        "org_id": space.orgID.map(SpaceJSON.string) ?? .null, "member_id": .string(device.member),
        "status": .string(active ? "active" : "removed"),
        "role": .string(effectiveRole(space, member: device.member).rawValue),
        "epoch": SpaceJSON(space.epoch), "archived": .bool(space.archived),
        "head": SpaceJSON(space.log.last?.seq ?? 0),
      ])
    }
    let orgRows: [SpaceJSON] = orgs.sorted { $0.key < $1.key }.compactMap { orgID, org in
      guard let device = org.devices[id], device.status == "active" else { return nil }
      return [
        "org_id": .string(orgID), "member_id": .string(device.member),
        "admin": .bool(org.isAdmin(device.member)),
      ]
    }
    return [
      "device_id": .string(id), "spaces": .array(rows), "orgs": .array(orgRows),
      "pending_joins": [],
    ]
  }

  func orgSummary(_ orgID: String) -> SpaceJSON {
    let org = orgs[orgID]!
    return [
      "org_id": .string(orgID), "policy": ["recovery_admins": SpaceJSON(org.policy)],
      "head": SpaceJSON(org.log.last?.seq ?? 0),
      "admins": .array(
        org.admins.sorted { $0.key < $1.key }.map {
          ["member_id": .string($0.key), "status": .string($0.value)]
        }),
      "spaces": SpaceJSON(spaces.filter { $0.value.orgID == orgID }.keys.sorted()),
      "ops": .array(
        org.log.map {
          [
            "seq": SpaceJSON($0.seq), "type": .string($0.type),
            "op": .string(Base64URL.encode($0.op)), "sig": $0.sig.map(SpaceJSON.string) ?? .null,
            "enc": .null,
          ]
        }),
    ]
  }

  // MARK: - Org ops

  func applyOrgOp(_ orgID: String, _ wire: SpaceJSON) throws -> SpaceJSON {
    let (op, bytes, sig) = try parse(wire)
    guard var org = orgs[orgID], op["org_id"]?.string == orgID, let type = op["type"]?.string,
      let member = op["member_id"]?.string, let deviceID = op["device_id"]?.string
    else { throw FakeError(status: 400, code: "bad_op") }
    if let opID = op["op_id"]?.string,
      let existing = org.log.first(where: {
        (try? SpaceJSON.decode($0.op))?["op_id"]?.string == opID
      })
    {
      return ["ok": true, "duplicate": true, "seq": SpaceJSON(existing.seq)]
    }
    guard let device = org.devices[deviceID], device.member == member else {
      throw FakeError(status: 403, code: "unknown_device")
    }
    try need(
      SpaceSignatures.verifyOp(bytes, signature: sig, signPub: device.signPub), 401, "bad_signature"
    )
    try need(device.status == "active" && org.isAdmin(member), 403, "forbidden")
    let body = op["body"] ?? [:]
    var effects: SpaceJSON = [:]
    func record(_ json: SpaceJSON?) throws -> SpaceDevicePublic {
      guard let d = try? json?.decoded(as: SpaceDevicePublic.self), d.signKey != nil,
        d.sealKey != nil, SpaceID.isValid(d.deviceID)
      else { throw FakeError(status: 422, code: "bad_field") }
      return d
    }
    switch type {
    case "org.admin_add":
      guard let target = body["member_id"]?.string, SpaceID.isValid(target) else {
        throw FakeError(status: 422, code: "bad_field")
      }
      let d = try record(body["device"])
      if let owner = memberOfDevice(d.deviceID) {
        try need(owner == target, 409, "device_member_conflict")
      }
      try need(
        !access.values.contains { $0.deviceID == d.deviceID && $0.status == "revoked" }, 409,
        "device_revoked")
      org.admins[target] = "active"
      org.devices[d.deviceID] = .init(
        member: target, signPub: d.signKey!, signPubB64: d.signPub, sealPub: d.sealPub)
      effects = ["member_id": .string(target), "device_id": .string(d.deviceID)]
    case "org.device_add":
      let d = try record(body["device"])
      if let owner = memberOfDevice(d.deviceID) {
        try need(owner == member, 409, "device_member_conflict")
      }
      org.devices[d.deviceID] = .init(
        member: member, signPub: d.signKey!, signPubB64: d.signPub, sealPub: d.sealPub)
      effects = ["member_id": .string(member), "device_id": .string(d.deviceID)]
    case "org.device_remove":
      guard let target = body["device_id"]?.string, target != deviceID else {
        throw FakeError(status: 422, code: "bad_field")
      }
      guard org.devices[target] != nil else { throw FakeError(status: 404, code: "unknown_device") }
      org.devices[target]?.status = "removed"
      var pending: [String] = []
      for (id, space) in spaces where space.orgID == orgID {
        if spaces[id]?.escrow.removeValue(forKey: "\(space.epoch)|\(target)") != nil {
          spaces[id]?.rotationPending = true
          pending.append(id)
        }
      }
      effects = ["device_id": .string(target), "rotation_pending": SpaceJSON(pending.sorted())]
    case "org.admin_remove":
      guard let target = body["member_id"]?.string else {
        throw FakeError(status: 422, code: "bad_field")
      }
      try need(org.admins.values.filter { $0 == "active" }.count > 1, 409, "last_admin")
      org.admins[target] = "removed"
      for (id, d) in org.devices where d.member == target {
        org.devices[id]?.status = "removed"
        for (sid, space) in spaces where space.orgID == orgID {
          spaces[sid]?.escrow["\(space.epoch)|\(id)"] = nil
        }
      }
      effects = ["member_id": .string(target)]
    case "org.policy":
      guard let n = body["recovery_admins"]?.int, (1...3).contains(n) else {
        throw FakeError(status: 422, code: "bad_field")
      }
      org.policy = n
      effects = ["recovery_admins": SpaceJSON(n)]
    default:
      throw FakeError(status: 400, code: "unknown_type")
    }
    let seq = (org.log.last?.seq ?? 0) + 1
    org.log.append(LoggedOp(seq: seq, type: type, op: bytes, sig: sig, enc: nil, at: now))
    orgs[orgID] = org
    return ["ok": true, "seq": SpaceJSON(seq), "effects": effects]
  }

  // MARK: - Escrow (B5)

  /// Who can open `epoch`'s key among the org's admins (member wraps of
  /// their devices, or escrow wraps), and which admin devices lack one.
  func escrowStatus(_ space: Space, epoch: Int) -> SpaceJSON? {
    guard space.ownerKind == "org", let orgID = space.orgID, let org = orgs[orgID] else {
      return nil
    }
    let devices = org.escrowDevices
    let admins = Set(devices.map(\.device.member))
    let required = min(org.policy, admins.count)
    var holders = Set<String>()
    var missing: [SpaceJSON] = []
    for (id, device) in devices {
      if space.wraps["\(epoch)|\(id)"] != nil || space.escrow["\(epoch)|\(id)"] != nil {
        holders.insert(device.member)
      } else {
        missing.append([
          "device_id": .string(id), "member_id": .string(device.member),
          "seal_pub": .string(device.sealPub),
        ])
      }
    }
    return [
      "policy": SpaceJSON(org.policy), "required": SpaceJSON(required),
      "holders": SpaceJSON(holders.sorted()), "missing": .array(missing),
      "ok": .bool(holders.count >= required),
    ]
  }

  func storeEscrow(_ space: inout Space, epoch: Int, wraps: [SpaceJSON]?) throws {
    guard let wraps, !wraps.isEmpty else { return }
    guard space.ownerKind == "org", let org = space.orgID.flatMap({ orgs[$0] }) else {
      throw FakeError(status: 422, code: "bad_field")
    }
    let devices = Set(org.escrowDevices.map(\.id))
    for wrap in wraps {
      guard let id = wrap["device_id"]?.string, devices.contains(id), wrap["epoch"]?.int == epoch,
        let value = wrap["wrap"]?.string, value.hasPrefix("mlwrap1.")
      else { throw FakeError(status: 422, code: "bad_field") }
      space.escrow["\(epoch)|\(id)"] = value
    }
  }

  func checkEscrow(_ space: Space, epoch: Int) throws {
    guard let status = escrowStatus(space, epoch: epoch), status["ok"]?.bool == false else {
      return
    }
    throw FakeError(
      status: 409, code: "escrow_required",
      extra: [
        "required": status["required"] ?? 0,
        "missing": SpaceJSON(
          (status["missing"]?.array ?? []).compactMap { $0["device_id"]?.string }),
      ])
  }

  /// `space.recover`: an org admin's device with an escrow wrap of the current key.
  func recoverOp(_ spaceID: String, _ space: inout Space, op: SpaceJSON, bytes: Data, sig: String)
    throws -> SpaceJSON
  {
    guard space.ownerKind == "org", let orgID = space.orgID, let org = orgs[orgID],
      let member = op["member_id"]?.string, let deviceID = op["device_id"]?.string,
      let device = org.devices[deviceID], device.member == member
    else { throw FakeError(status: 403, code: "unknown_device") }
    try need(
      SpaceSignatures.verifyOp(bytes, signature: sig, signPub: device.signPub), 401, "bad_signature"
    )
    try need(device.status == "active" && org.isAdmin(member), 403, "forbidden")
    guard let named = try? op["body"]?["device"]?.decoded(as: SpaceDevicePublic.self),
      named.deviceID == deviceID, named.signKey == device.signPub, named.sealPub == device.sealPub
    else { throw FakeError(status: 422, code: "bad_field") }
    guard let wrap = space.escrow["\(space.epoch)|\(deviceID)"] else {
      throw FakeError(status: 409, code: "no_escrow")
    }
    if space.members[member] == nil { space.memberOrder.append(member) }
    space.members[member] = Member(role: .admin, joined: now)
    space.devices[deviceID] = Device(
      member: member, signPub: device.signPub, sealPub: device.sealPub,
      signPubB64: device.signPubB64)
    space.wraps["\(space.epoch)|\(deviceID)"] = wrap
    return [
      "member_id": .string(member), "device_id": .string(deviceID), "epoch": SpaceJSON(space.epoch),
    ]
  }

  // MARK: - Shares (C1, C2, C3)

  /// The v8 checks of an `item.share` before it is applied: a retried share
  /// (same share key) is accepted as the one it has; audio parts and
  /// snapshots follow their rules; the member's quota.
  func shareChecks(
    _ space: inout Space, item: String, member: String, revision: Int, kind: String,
    body: SpaceJSON, blobs: [SpaceJSON], enc: String?
  ) throws -> SpaceJSON? {
    if let key = body["share_key"]?.string, let current = space.items[item],
      current.contributor == member, current.revision == revision, current.shareKey == key
    {
      for blob in blobs {
        if let id = blob["blob_id"]?.string, space.blobs[id]?.status == "pending" {
          space.blobs[id] = nil
        }
      }
      return [
        "ok": true, "duplicate": true, "accepted_as": "share_key",
        "seq": SpaceJSON(current.shareSeq),
        "effects": [
          "item_id": .string(item), "revision": SpaceJSON(revision),
          "epoch": SpaceJSON(space.epoch),
        ],
      ]
    }
    let audio = blobs.filter { $0["role"]?.string == "audio" }
    if !audio.isEmpty {
      try need(audio.count == 1, 422, "bad_field")
      try need(SpaceEngine.audioKinds.contains(kind), 422, "bad_field")
      try need(space.policy.segmentAudio, 403, "audio_not_allowed")
      guard let s = body["segment"], let a = s["start_ms"]?.int, let b = s["end_ms"]?.int,
        let whole = s["recording_ms"]?.int, let parent = s["parent_item_id"]?.string
      else { throw FakeError(status: 422, code: "bad_field") }
      try need(whole >= b, 422, "bad_field")
      try need((b - a) * 5 <= whole * 4, 422, "whole_recording")
      try need(b - a <= 15 * 60 * 1000, 422, "segment_too_long")
      let size =
        audio.first.flatMap { $0["blob_id"]?.string }.flatMap { space.blobs[$0]?.data.count } ?? 0
      let limit = SpaceLimits.standard.audioCeiling(ms: b - a)
      if size > limit {
        throw FakeError(
          status: 413, code: "audio_too_large", extra: ["limit_bytes": SpaceJSON(limit)])
      }
      if let other = space.audioParts["\(member)|\(parent.lowercased())"], other != item,
        space.items[other]?.status == "active"
      {
        throw FakeError(
          status: 409, code: "one_part_per_recording", extra: ["item_id": .string(other)])
      }
      space.audioParts["\(member)|\(parent.lowercased())"] = item
    }
    if kind == "snapshot" || space.items[item]?.kind == "snapshot" {
      try need(space.items[item] == nil, 409, "snapshot_frozen")
      try need(blobs.isEmpty, 422, "bad_field")
      let cites = (body["snapshot"]?["cites"]?.array ?? []).compactMap(\.string)
      let unknown = cites.filter { $0 == item || space.items[$0]?.status != "active" }
      if !unknown.isEmpty {
        throw FakeError(status: 422, code: "unknown_items", extra: ["item_ids": SpaceJSON(unknown)])
      }
      space.snapshotCites[item] = cites
    } else if space.items[item] != nil, body["snapshot"] != nil {
      throw FakeError(status: 409, code: "snapshot_frozen")
    }
    let quotaMB = space.policy.memberQuotaMB ?? 2048
    if quotaMB > 0 {
      let adding =
        blobs.compactMap { $0["blob_id"]?.string }.compactMap { space.blobs[$0]?.data.count }
        .reduce(
          0, +) + (enc?.count ?? 0)
      let used = usage(space, member: member)
      if used + adding > quotaMB * 1_048_576 {
        throw FakeError(
          status: 413, code: "quota_exceeded",
          extra: [
            "used_bytes": SpaceJSON(used), "quota_bytes": SpaceJSON(quotaMB * 1_048_576),
            "adding_bytes": SpaceJSON(adding),
          ])
      }
    }
    return nil
  }

  func usage(_ space: Space, member: String) -> Int {
    let blobs = space.blobs.values.filter {
      $0.status != "deleted" && space.devices[$0.device]?.member == member
    }.map(\.data.count).reduce(0, +)
    let enc = space.log.filter {
      !$0.purged && (try? SpaceJSON.decode($0.op))?["member_id"]?.string == member
    }.compactMap { $0.enc?.count }.reduce(0, +)
    return blobs + enc
  }

  /// A withdrawn or removed item takes every snapshot that cites it along
  /// (a system record, reason `cited_item_gone`), chains included.
  func drainCascade(_ space: inout Space, spaceID: String) {
    while !space.cascade.isEmpty {
      cascadeSnapshots(&space, spaceID: spaceID, gone: space.cascade.removeFirst())
    }
  }

  func cascadeSnapshots(_ space: inout Space, spaceID: String, gone: String) {
    for (snapshot, cites) in space.snapshotCites.sorted(by: { $0.key < $1.key })
    where cites.contains(gone) && space.items[snapshot]?.status == "active" {
      let seq = (space.log.last?.seq ?? 0) + 1
      let record: SpaceJSON = [
        "v": 1, "space_id": .string(spaceID), "op_id": .string(SpaceID.new()),
        "type": "system.remove", "member_id": .null, "device_id": .null,
        "body": [
          "item_id": .string(snapshot), "reason": "cited_item_gone", "cited_item_id": .string(gone),
        ],
      ]
      space.log.append(
        LoggedOp(
          seq: seq, type: "system.remove", op: (try? record.encoded()) ?? Data(), sig: nil,
          enc: nil,
          subject: snapshot, at: now))
      purge(&space, snapshot, status: "removed", spaceID: spaceID)
    }
  }

  // MARK: - Backups (B4)

  func backupStream(_ spaceID: String, _ space: Space, request: SpaceHTTPRequest, body: SpaceJSON)
    throws -> SpaceHTTPResponse
  {
    guard let backupID = body["backup_id"]?.string, SpaceID.isValid(backupID),
      let keyHex = body["key"]?.string, let key = Data(spaceHex: keyHex), key.count == 32
    else { throw FakeError(status: 400, code: "bad_request") }
    try need(body["epoch"]?.int == space.epoch, 409, "stale_epoch")
    backups[backupID] = space
    let manifest: SpaceJSON = [
      "v": 1, "space": ["space_id": .string(spaceID)],
      "tables": [
        "items": .array(
          space.items.sorted { $0.key < $1.key }.map {
            ["item_id": .string($0.key), "status": .string($0.value.status)]
          }),
        "ops": .array(space.log.map { ["seq": SpaceJSON($0.seq), "type": .string($0.type)] }),
      ],
      "blobs": SpaceJSON(space.blobs.filter { $0.value.status != "deleted" }.keys.sorted()),
      "files": [],
    ]
    var records: [(type: UInt8, payload: Data)] = [(UInt8(ascii: "M"), try manifest.encoded())]
    for (id, blob) in space.blobs.sorted(by: { $0.key < $1.key }) where blob.status != "deleted" {
      records.append((UInt8(ascii: "B"), Data(id.utf8) + blob.data))
    }
    records.append((UInt8(ascii: "E"), Data("{}".utf8)))
    let header = try SpaceJSON.object([
      "v": 1, "format": .string(SpaceBackup.format), "backup_id": .string(backupID),
      "space_id": .string(spaceID), "epoch": SpaceJSON(space.epoch),
      "created_at": .string(SpaceTime.string(now)), "chunk": 1024,
    ]).decoded(as: SpaceBackup.Header.self)
    let stream = try SpaceBackup.seal(header: header, records: records, key: key, chunk: 1024)
    return SpaceHTTPResponse(status: 200, body: stream)
  }

  func restore(_ spaceID: String, _ request: SpaceHTTPRequest) throws -> SpaceJSON {
    guard let keyHex = request.headers["X-Mindloom-Backup-Key"], let key = Data(spaceHex: keyHex),
      let stream = request.body
    else { throw FakeError(status: 400, code: "bad_key") }
    let options =
      request.headers["X-Mindloom-Restore"].flatMap { try? SpaceJSON.decode(Data($0.utf8)) } ?? [:]
    let contents: SpaceBackup.Contents
    do { contents = try SpaceBackup.open(stream, key: key) } catch {
      throw FakeError(status: 422, code: "bad_backup")
    }
    try need(contents.header.spaceID == spaceID, 422, "bad_backup")
    guard var restored = backups[contents.header.backupID] else {
      throw FakeError(status: 422, code: "bad_backup")
    }
    let mode = options["mode"]?.string ?? "new"
    if mode == "new" { try need(spaces[spaceID] == nil, 409, "space_exists") }
    // As the Spark (backup.restore, review V8R-01/V8R-03): when this Spark's
    // log already holds the backup's, its rows stay ("fill"); a shorter log of
    // its own is replaced; a diverged one is refused unless the owner forces.
    var applied = "full"
    var relation = "new"
    if let current = spaces[spaceID] {
      let n = min(current.log.count, restored.log.count)
      let same = (0..<n).allSatisfy {
        current.log[$0].op == restored.log[$0].op && current.log[$0].sig == restored.log[$0].sig
      }
      if !same {
        relation = "diverged"
        try need(options["force"]?.bool == true, 409, "log_diverges")
      } else if current.log.count >= restored.log.count {
        relation = current.log.count == restored.log.count ? "equal" : "current_newer"
        applied = "fill"
        restored = current
      } else {
        relation = "backup_newer"
      }
    }
    var purged = 0
    for item in (options["purge"]?.array ?? []).compactMap(\.string)
    where restored.items[item]?.status == "active" {
      let seq = (restored.log.last?.seq ?? 0) + 1
      let record: SpaceJSON = [
        "v": 1, "space_id": .string(spaceID), "op_id": .string(SpaceID.new()),
        "type": "system.remove", "member_id": .null, "device_id": .null,
        "body": ["item_id": .string(item), "reason": "restore"],
      ]
      restored.log.append(
        LoggedOp(
          seq: seq, type: "system.remove", op: (try? record.encoded()) ?? Data(), sig: nil,
          enc: nil,
          subject: item, at: now))
      purge(&restored, item, status: "removed", spaceID: spaceID)
      drainCascade(&restored, spaceID: spaceID)
      purged += 1
    }
    spaces[spaceID] = restored
    return [
      "ok": true, "space_id": .string(spaceID), "backup_id": .string(contents.header.backupID),
      "epoch": SpaceJSON(contents.header.epoch), "head": SpaceJSON(restored.log.last?.seq ?? 0),
      "ops": SpaceJSON(restored.log.count), "items": SpaceJSON(restored.items.count),
      "blobs": SpaceJSON(contents.blobIDs.count), "purged": SpaceJSON(purged),
      "applied": .string(applied), "log": .string(relation),
    ]
  }

  // MARK: - Handover packs (B3)

  func handoverPackRequest(_ spaceID: String, _ space: Space, body: SpaceJSON) throws
    -> SpaceHTTPResponse
  {
    try need(space.leaseOpen, 423, "locked")
    guard let matter = body["matter_id"]?.string else {
      throw FakeError(status: 422, code: "bad_field")
    }
    let packID = SpaceID.new()
    let ids = space.payloads.keys.sorted()
    let lines = ids.compactMap { id in
      space.payloads[id]?["text"]?.string.map { "- \($0)（素材 \(id.prefix(8))）" }
    }
    let markdown =
      "# 交接包：\(matter)\n\n## 现在到哪了\n" + lines.joined(separator: "\n") + "\n\n## 接手先做什么\n- 先看引用的素材\n"
    let pack: SpaceJSON = [
      "title": .string("交接包"), "status": ["text": "进行中", "evidence": SpaceJSON(ids)],
      "commitments": [], "deadlines": [], "decisions": [], "open_questions": [],
      "links": .array(ids.map { ["item": .string($0), "why": "出处"] }), "next_steps": [],
      "sources": .object(
        Dictionary(uniqueKeysWithValues: ids.map { ($0, ["kind": "text"] as SpaceJSON) })),
    ]
    packs[packID] = (spaceID, matter, pack, markdown)
    return SpaceHTTPResponse(
      status: 202,
      body: try SpaceJSON.object(["queued": true, "pack_id": .string(packID)]).encoded())
  }

  func handoverPackGet(_ packID: String) throws -> SpaceJSON {
    guard let pack = packs[packID] else { throw FakeError(status: 404, code: "unknown_pack") }
    return [
      "pack_id": .string(packID), "event_id": .string(pack.matter), "status": "ready",
      "pack": pack.pack, "markdown": .string(pack.markdown),
    ]
  }

  // MARK: - Access (B1)

  func accessCaller(_ request: SpaceHTTPRequest) throws -> FakeAccess? {
    guard let auth = request.headers["Authorization"], auth.hasPrefix("Bearer mlacc1.") else {
      return nil
    }
    let credential = String(auth.dropFirst("Bearer ".count))
    guard let id = MemberAccess.accessID(ofCredential: credential), let row = access[id],
      row.status == "active", row.credentialHash == SpaceCrypto.sha256Hex(Data(credential.utf8))
    else { throw FakeError(status: 401, code: "bad_credential") }
    return row
  }

  func accessRecordJSON(_ row: FakeAccess) -> SpaceJSON {
    [
      "access_id": .string(row.accessID), "member_id": .string(row.memberID),
      "device_id": .string(row.deviceID), "sign_pub": .string(row.signPub),
      "fingerprint": .string("SHA256:" + String(row.keyB64.prefix(12))),
      "status": .string(row.status),
      "created_at": .string(SpaceTime.string(row.created)),
      "ended_at": row.ended.map { .string(SpaceTime.string($0)) } ?? .null,
      "last_seen_at": .null, "invited_by": row.invitedBy.map(SpaceJSON.string) ?? .null,
    ]
  }

  func adminScope(_ row: FakeAccess) -> (orgs: [String], spaces: [String], members: Set<String>) {
    let orgIDs = orgs.filter { id, org in
      org.isAdmin(row.memberID) && org.devices[row.deviceID]?.status == "active"
    }.keys.sorted()
    let spaceIDs = spaces.filter { _, space in
      space.devices[row.deviceID]?.status == "active"
        && effectiveRole(space, member: row.memberID) == .admin
    }.keys.sorted()
    var members = Set<String>()
    for id in spaceIDs { members.formUnion(spaces[id]?.members.keys ?? [:].keys) }
    for id in orgIDs {
      members.formUnion(orgs[id]?.admins.keys ?? [:].keys)
      for (_, space) in spaces where space.orgID == id { members.formUnion(space.members.keys) }
    }
    return (orgIDs, spaceIDs, members)
  }

  func accessRoute(_ request: SpaceHTTPRequest, segments: [String], query: String) throws
    -> SpaceHTTPResponse
  {
    let caller = try accessCaller(request)
    let body = (request.body.flatMap { try? SpaceJSON.decode($0) }) ?? [:]
    let tail = Array(segments.dropFirst(2))
    switch (request.method, segments[1], tail) {
    case ("GET", "access", ["me"]):
      guard let caller else {
        return try ok([
          "caller": "owner",
          "members_active": SpaceJSON(
            Set(access.values.filter { $0.status == "active" }.map(\.memberID)).count),
          "devices_active": SpaceJSON(access.values.filter { $0.status == "active" }.count),
          "tickets_open": SpaceJSON(tickets.values.filter { $0.status == "open" }.count),
        ])
      }
      let scope = adminScope(caller)
      return try ok([
        "caller": "member", "access": accessRecordJSON(caller),
        "org_admin_of": SpaceJSON(scope.orgs), "space_admin_of": SpaceJSON(scope.spaces),
        // As the Spark (review V8R-06): org admins invite; a space admin does not.
        "may_invite": .bool(!scope.orgs.isEmpty),
      ])
    case ("POST", "access", ["tickets"]):
      guard let id = body["ticket_id"]?.string, SpaceID.isValid(id),
        let kind = body["kind"]?.string, ["member", "device"].contains(kind),
        let key = body["ssh_key"]?.string, key.hasPrefix("ssh-ed25519 "),
        let hash = body["secret_hash"]?.string, hash.count == 64,
        let expires = SpaceTime.date(body["expires_at"]?.string)
      else { throw FakeError(status: 422, code: "bad_field") }
      try need(tickets[id] == nil, 409, "ticket_exists")
      try need(expires <= now.addingTimeInterval(7 * 86_400), 422, "bad_field")
      var member: String?
      if kind == "device" {
        member = caller?.memberID ?? body["member_id"]?.string
        try need(member != nil, 422, "bad_field")
        try need(
          access.values.filter { $0.memberID == member && $0.status == "active" }.count < 4, 409,
          "too_many_devices")
      } else if let caller {
        try need(!adminScope(caller).orgs.isEmpty, 403, "forbidden")
      }
      tickets[id] = FakeTicket(
        kind: kind, memberID: member, secretHash: hash,
        keyB64: String(key.split(separator: " ")[1]), createdBy: caller?.accessID ?? "owner",
        expires: expires)
      accessAudit.append(("access.ticket", ["ticket_id": .string(id)]))
      return try ok([
        "ok": true, "ticket_id": .string(id), "kind": .string(kind),
        "expires_at": .string(SpaceTime.string(expires)), "command": "enroll",
      ])
    case ("GET", "access", ["tickets"]):
      let rows = tickets.filter { caller == nil || $0.value.createdBy == caller?.accessID }
      return try ok([
        "tickets": .array(
          rows.sorted { $0.key < $1.key }.map { id, t in
            [
              "ticket_id": .string(id), "kind": .string(t.kind),
              "member_id": t.memberID.map(SpaceJSON.string) ?? .null, "status": .string(t.status),
              "expires_at": .string(SpaceTime.string(t.expires)),
            ]
          })
      ])
    case ("DELETE", "access", let path) where path.count == 2 && path[0] == "tickets":
      guard tickets[path[1]] != nil else { throw FakeError(status: 404, code: "unknown_ticket") }
      tickets[path[1]]?.status = "revoked"
      return try ok(["ok": true, "ticket_id": .string(path[1]), "removed": 1])
    case ("GET", "access", ["members"]):
      let scope = caller.map(adminScope)
      let rows = access.values.filter { row in
        guard let caller, let scope else { return true }
        return row.memberID == caller.memberID || scope.members.contains(row.memberID)
          || row.invitedBy == caller.accessID
      }.sorted { $0.created < $1.created }
      return try ok(["members": .array(rows.map(accessRecordJSON))])
    case ("GET", "access", ["devices"]):
      let member = FakeSpaceSpark.param(query, "member_id") ?? caller?.memberID
      guard let member else { throw FakeError(status: 422, code: "bad_field") }
      return try ok(devicesView(member))
    case ("DELETE", "access", let path) where path.count == 2 && path[0] == "members":
      guard var row = access[path[1]] else { throw FakeError(status: 404, code: "unknown_access") }
      if let caller {
        let scope = adminScope(caller)
        try need(
          row.memberID == caller.memberID
            || (!scope.orgs.isEmpty
              && (row.invitedBy == caller.accessID || scope.members.contains(row.memberID))),
          403, "forbidden")
      }
      let removed = row.status == "active" ? 1 : 0
      row.status = "revoked"
      row.credentialHash = nil
      row.ended = now
      access[path[1]] = row
      accessAudit.append(("access.revoke", ["access_id": .string(row.accessID)]))
      return try ok(["ok": true, "access_id": .string(row.accessID), "removed": SpaceJSON(removed)])
    case ("GET", "access", ["audit"]):
      return try ok([
        "entries": .array(
          accessAudit.enumerated().map { index, entry in
            [
              "id": SpaceJSON(index + 1), "at": .string(SpaceTime.string(now)),
              "actor": "owner", "action": .string(entry.action), "target": entry.target,
            ]
          }),
        "cursor": SpaceJSON(accessAudit.count),
      ])
    case ("GET", "infra", ["health"]):
      if let caller {
        let scope = adminScope(caller)
        try need(!scope.orgs.isEmpty, 403, "forbidden")
      }
      return try ok([
        "ok": true, "checked_at": .string(SpaceTime.string(now)),
        "organizer": [
          "version": "test", "revision": "fake", "uptime_s": 60, "workers": 1,
          "personal_store": ["locked": true, "queue": 0],
          "spaces": ["spaces": SpaceJSON(spaces.count), "orgs": SpaceJSON(orgs.count), "queue": 0],
          "access": [
            "members_active": SpaceJSON(access.values.filter { $0.status == "active" }.count),
            "devices_active": SpaceJSON(access.values.filter { $0.status == "active" }.count),
            "tickets_open": SpaceJSON(tickets.values.filter { $0.status == "open" }.count),
          ],
        ],
        "models": [["role": "chat", "port": 8000, "up": true, "model": "fake", "latency_ms": 12]],
        "gpu": [
          "available": true, "gpus": [["name": "GB10", "utilization_pct": 3]],
          "unified_memory": [
            "total_mib": 124_610, "available_mib": 1_600, "gpu_processes_mib": 99_000,
          ],
        ],
        "disk": [
          "total_gb": 3_700, "free_gb": 2_100, "free_pct": 56.7, "data_bytes": 1024,
          "spaces_bytes": 512,
        ],
        "warnings": ["memory_low"],
      ])
    default:
      throw FakeError(status: 404, code: "no_route")
    }
  }

  func devicesView(_ member: String) -> SpaceJSON {
    var ids: [String] = []
    for row in access.values.sorted(by: { $0.created < $1.created }) where row.memberID == member {
      if !ids.contains(row.deviceID) { ids.append(row.deviceID) }
    }
    for space in spaces.values {
      for (id, d) in space.devices where d.member == member && !ids.contains(id) { ids.append(id) }
    }
    let memberSpaces = spaces.filter { $0.value.members[member]?.status == "active" }.keys.sorted()
    let memberOrgs = orgs.filter { $0.value.isAdmin(member) }.keys.sorted()
    let devices: [SpaceJSON] = ids.map { id in
      let row = access.values.filter { $0.deviceID == id }.max { $0.created < $1.created }
      let inSpaces = spaces.filter { $0.value.devices[id] != nil }.sorted { $0.key < $1.key }
      let inOrgs = orgs.filter { $0.value.devices[id] != nil }.sorted { $0.key < $1.key }
      let anySpaceDevice = inSpaces.first?.value.devices[id]
      var entry: SpaceJSON = [
        "device_id": .string(id),
        "sign_pub": .string(anySpaceDevice?.signPubB64 ?? row?.signPub ?? ""),
        "seal_pub": .string(anySpaceDevice?.sealPub ?? row?.sealPub ?? ""),
        "access": row.map(accessRecordJSON) ?? .null,
        "spaces": .array(
          inSpaces.map {
            ["space_id": .string($0.key), "status": .string($0.value.devices[id]!.status)]
          }),
        "orgs": .array(
          inOrgs.map {
            ["org_id": .string($0.key), "status": .string($0.value.devices[id]!.status)]
          }),
      ]
      if let row, row.status == "active" {
        let listed = Set(inSpaces.map(\.key))
        let activeOrgs = Set(inOrgs.filter { $0.value.devices[id]?.status == "active" }.map(\.key))
        entry = entry.setting(
          "to_add",
          [
            "spaces": SpaceJSON(memberSpaces.filter { !listed.contains($0) }),
            "orgs": SpaceJSON(memberOrgs.filter { !activeOrgs.contains($0) }),
          ])
      } else if row != nil {
        entry = entry.setting(
          "to_remove",
          [
            "spaces": SpaceJSON(
              inSpaces.filter { $0.value.devices[id]?.status == "active" }.map(\.key)),
            "orgs": SpaceJSON(
              inOrgs.filter { $0.value.devices[id]?.status == "active" }.map(\.key)),
          ])
      }
      return entry
    }
    return [
      "member_id": .string(member), "spaces": SpaceJSON(memberSpaces),
      "orgs": SpaceJSON(memberOrgs),
      "devices": .array(devices),
    ]
  }

  /// What the gate's `enroll` does with the ticket key's stdin: checks the
  /// secret, the signature and the ids, then turns the ticket into an access
  /// record and hands out the credential once.
  public func enroll(ticketKey: String, request wire: SpaceJSON) -> AccessEnrollAnswer {
    lock.withLock {
      func fail(_ code: String) -> AccessEnrollAnswer {
        (try? JSONDecoder().decode(
          AccessEnrollAnswer.self,
          from: SpaceJSON.object(["ok": false, "error": .string(code)]).encoded()))!
      }
      let keyB64 = String(ticketKey.split(separator: " ").dropFirst().first ?? "")
      guard let (ticketID, ticket) = tickets.first(where: { $0.value.keyB64 == keyB64 }) else {
        return fail("not_allowed")
      }
      guard ticket.status == "open", ticket.expires > now else { return fail("ticket_closed") }
      guard let raw = wire["request"]?.string.flatMap({ Base64URL.decode($0) }),
        let request = try? SpaceJSON.decode(raw), let sig = wire["sig"]?.string,
        request["ticket_id"]?.string == ticketID,
        let secret = request["secret"]?.string.flatMap({ Base64URL.decode($0) }),
        let device = try? request["device"]?.decoded(as: SpaceDevicePublic.self),
        let signKey = device.signKey, let member = request["member_id"]?.string,
        let sshKey = request["ssh_key"]?.string, sshKey.hasPrefix("ssh-ed25519 ")
      else { return fail("bad_request") }
      guard MemberAccess.ticketHash(secret) == ticket.secretHash else {
        tickets[ticketID]?.failures += 1
        if (tickets[ticketID]?.failures ?? 0) >= 10 { tickets[ticketID]?.status = "locked" }
        return fail("bad_secret")
      }
      guard
        SpaceSignatures.verify(
          signPub: signKey, message: MemberAccess.enrollDomain + raw, signature: sig)
      else { return fail("bad_signature") }
      if ticket.kind == "device", member != ticket.memberID { return fail("wrong_member") }
      if ticket.kind == "member",
        access.values.contains(where: { $0.memberID == member && $0.status == "active" })
      {
        return fail("member_exists")
      }
      if let owner = memberOfDevice(device.deviceID), owner != member {
        return fail("device_member_conflict")
      }
      let accessID = SpaceID.new()
      let secretPart = Base64URL.encode(SpaceCrypto.randomKey())
      let credential = "mlacc1.\(accessID).\(secretPart)"
      access[accessID] = FakeAccess(
        accessID: accessID, memberID: member, deviceID: device.deviceID, signPub: device.signPub,
        sealPub: device.sealPub, keyB64: String(sshKey.split(separator: " ")[1]),
        credentialHash: SpaceCrypto.sha256Hex(Data(credential.utf8)),
        invitedBy: ticket.createdBy == "owner" ? nil : ticket.createdBy, created: now)
      tickets[ticketID]?.status = "used"
      accessAudit.append(("access.enroll", ["access_id": .string(accessID)]))
      let answer: SpaceJSON = [
        "ok": true, "access_id": .string(accessID), "member_id": .string(member),
        "device_id": .string(device.deviceID), "credential": .string(credential),
        "fingerprint": "SHA256:fake", "command": "bridge",
      ]
      return (try? JSONDecoder().decode(AccessEnrollAnswer.self, from: answer.encoded()))!
    }
  }

  /// Tests: the ticket key's public half as registered.
  public func ticketKeys() -> [String] { lock.withLock { tickets.values.map(\.keyB64) } }
}
