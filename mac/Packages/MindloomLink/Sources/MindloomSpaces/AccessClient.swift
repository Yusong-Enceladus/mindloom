import Foundation
import MindloomLink

// The Spark's access and infrastructure routes (`organizer/access_api.py`,
// docs/INFRA.md): ids, public keys, times, states and numbers only — never
// a name, a secret or any content.

/// One Mac's access record as the admin console shows it.
public struct AccessRecord: Codable, Equatable, Identifiable, Sendable {
  public let accessID: String
  public let memberID: String
  public let deviceID: String
  public let signPub: String?
  public let fingerprint: String?
  public let status: String
  public let createdAt: String?
  public let endedAt: String?
  public let lastSeenAt: String?
  public let invitedBy: String?
  /// The Mac's own SSH public key (`ssh-ed25519 …`; only in the Spark
  /// owner's view: its relay line, review V8R-12).
  public let sshKey: String?

  public var id: String { accessID }
  public var isActive: Bool { status == "active" }

  enum CodingKeys: String, CodingKey {
    case accessID = "access_id"
    case memberID = "member_id"
    case deviceID = "device_id"
    case signPub = "sign_pub"
    case fingerprint, status
    case createdAt = "created_at"
    case endedAt = "ended_at"
    case lastSeenAt = "last_seen_at"
    case invitedBy = "invited_by"
    case sshKey = "ssh_key"
  }
}

/// `GET /v1/access/me`: the owner's counts, or a member's own record and
/// what it administers here.
public struct AccessMe: Decodable, Equatable, Sendable {
  public let caller: String
  public let access: AccessRecord?
  public let orgAdminOf: [String]
  public let spaceAdminOf: [String]
  public let mayInvite: Bool
  public let membersActive: Int?
  public let devicesActive: Int?
  public let ticketsOpen: Int?

  public var isOwner: Bool { caller == "owner" }

  enum CodingKeys: String, CodingKey {
    case caller, access
    case orgAdminOf = "org_admin_of"
    case spaceAdminOf = "space_admin_of"
    case mayInvite = "may_invite"
    case membersActive = "members_active"
    case devicesActive = "devices_active"
    case ticketsOpen = "tickets_open"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    caller = try c.decode(String.self, forKey: .caller)
    access = try c.decodeIfPresent(AccessRecord.self, forKey: .access)
    orgAdminOf = try c.decodeIfPresent([String].self, forKey: .orgAdminOf) ?? []
    spaceAdminOf = try c.decodeIfPresent([String].self, forKey: .spaceAdminOf) ?? []
    mayInvite = try c.decodeIfPresent(Bool.self, forKey: .mayInvite) ?? (caller == "owner")
    membersActive = try c.decodeIfPresent(Int.self, forKey: .membersActive)
    devicesActive = try c.decodeIfPresent(Int.self, forKey: .devicesActive)
    ticketsOpen = try c.decodeIfPresent(Int.self, forKey: .ticketsOpen)
  }
}

/// `GET /v1/access/devices`: one member's Macs, where each is, and what is
/// left to sign (`to_add` for a paired Mac, `to_remove` for an unpaired one).
public struct AccessDevicesView: Decodable, Equatable, Sendable {
  public struct Places: Codable, Equatable, Sendable {
    public let spaces: [String]
    public let orgs: [String]

    public var isEmpty: Bool { spaces.isEmpty && orgs.isEmpty }
  }

  public struct Place: Decodable, Equatable, Sendable {
    public let id: String
    public let status: String

    enum CodingKeys: String, CodingKey {
      case spaceID = "space_id"
      case orgID = "org_id"
      case status
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      id =
        try c.decodeIfPresent(String.self, forKey: .spaceID)
        ?? c.decode(String.self, forKey: .orgID)
      status = try c.decodeIfPresent(String.self, forKey: .status) ?? "active"
    }
  }

  public struct Device: Decodable, Equatable, Identifiable, Sendable {
    public let deviceID: String
    public let signPub: String
    public let sealPub: String
    public let access: AccessRecord?
    public let spaces: [Place]
    public let orgs: [Place]
    public let toAdd: Places?
    public let toRemove: Places?

    public var id: String { deviceID }

    public var publicRecord: SpaceDevicePublic {
      SpaceDevicePublic(deviceID: deviceID, signPub: signPub, sealPub: sealPub)
    }

    enum CodingKeys: String, CodingKey {
      case deviceID = "device_id"
      case signPub = "sign_pub"
      case sealPub = "seal_pub"
      case access, spaces, orgs
      case toAdd = "to_add"
      case toRemove = "to_remove"
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      deviceID = try c.decode(String.self, forKey: .deviceID)
      signPub = try c.decode(String.self, forKey: .signPub)
      sealPub = try c.decode(String.self, forKey: .sealPub)
      access = try c.decodeIfPresent(AccessRecord.self, forKey: .access)
      spaces = try c.decodeIfPresent([Place].self, forKey: .spaces) ?? []
      orgs = try c.decodeIfPresent([Place].self, forKey: .orgs) ?? []
      toAdd = try c.decodeIfPresent(Places.self, forKey: .toAdd)
      toRemove = try c.decodeIfPresent(Places.self, forKey: .toRemove)
    }
  }

  public let memberID: String
  public let spaces: [String]
  public let orgs: [String]
  public let devices: [Device]

  enum CodingKeys: String, CodingKey {
    case memberID = "member_id"
    case spaces, orgs, devices
  }
}

public struct AccessAuditEntry: Decodable, Equatable, Identifiable, Sendable {
  public let id: Int
  public let at: String
  public let actor: String?
  /// `access.ticket`, `access.enroll`, `access.revoke`, `access.ticket_revoke`, `access.ticket_expired`.
  public let action: String
  public let target: SpaceJSON?
}

public struct AccessAuditPage: Decodable, Sendable {
  public let entries: [AccessAuditEntry]
  public let cursor: Int?
}

public struct AccessTicketRecord: Decodable, Equatable, Identifiable, Sendable {
  public let ticketID: String
  public let kind: String
  public let memberID: String?
  public let status: String
  public let expiresAt: String?
  public let fingerprint: String?
  /// The ticket key's public half (Spark owner's view; its relay line).
  public let sshKey: String?

  public var id: String { ticketID }

  enum CodingKeys: String, CodingKey {
    case ticketID = "ticket_id"
    case kind
    case memberID = "member_id"
    case status
    case expiresAt = "expires_at"
    case fingerprint
    case sshKey = "ssh_key"
  }
}

/// The team's lines on the relay (review V8R-12): one per open ticket key (to
/// enroll) and one per paired Mac's own key (its bridge), each keyed
/// `team-<12 hex of SHA-256 of the raw public key>`. A used, expired or
/// revoked ticket and an unpaired Mac have none, so the relay's
/// authorized_keys returns to what it was before the invite.
public enum TeamRelayLines {
  public static func keyID(rawPublicKey: Data) -> String {
    "team-" + SpaceCrypto.sha256Hex(rawPublicKey).prefix(12)
  }

  /// The raw 32-byte ed25519 key inside `ssh-ed25519 <base64>`.
  public static func raw(_ authorizedKey: String) -> (raw: Data, base64: String)? {
    let words = authorizedKey.split(separator: " ")
    guard words.count >= 2, words[0] == "ssh-ed25519",
      let blob = Data(base64Encoded: String(words[1])),
      blob.count >= 32
    else { return nil }
    return (blob.suffix(32), String(words[1]))
  }

  /// Key id → base64 key of every line the relay should have now.
  public static func wanted(
    tickets: [AccessTicketRecord], members: [AccessRecord]
  ) -> [String: String] {
    var out: [String: String] = [:]
    let keys =
      tickets.filter { $0.status == "open" }.compactMap(\.sshKey)
      + members.filter(\.isActive).compactMap(\.sshKey)
    for key in keys {
      guard let parsed = raw(key) else { continue }
      out[keyID(rawPublicKey: parsed.raw)] = parsed.base64
    }
    return out
  }
}

/// `GET /v1/infra/health` (owner, or an admin through the gate): numbers and
/// states only.
public struct InfraHealth: Decodable, Equatable, Sendable {
  public struct Organizer: Decodable, Equatable, Sendable {
    public struct Personal: Decodable, Equatable, Sendable {
      public let locked: Bool?
      public let queue: Int?
      public let lastError: String?
      enum CodingKeys: String, CodingKey {
        case locked, queue
        case lastError = "last_error"
      }
    }

    public struct Spaces: Decodable, Equatable, Sendable {
      public let spaces: Int?
      public let orgs: Int?
      public let blobBytes: Int?
      public let organizersUnlocked: Int?
      public let queue: Int?
      enum CodingKeys: String, CodingKey {
        case spaces, orgs, queue
        case blobBytes = "blob_bytes"
        case organizersUnlocked = "organizers_unlocked"
      }
    }

    public struct Access: Decodable, Equatable, Sendable {
      public let membersActive: Int?
      public let devicesActive: Int?
      public let ticketsOpen: Int?
      enum CodingKeys: String, CodingKey {
        case membersActive = "members_active"
        case devicesActive = "devices_active"
        case ticketsOpen = "tickets_open"
      }
    }

    public let version: String?
    public let revision: String?
    public let uptimeS: Double?
    public let workers: Int?
    public let personalStore: Personal?
    public let spaces: Spaces?
    public let access: Access?

    enum CodingKeys: String, CodingKey {
      case version, revision, workers, spaces, access
      case uptimeS = "uptime_s"
      case personalStore = "personal_store"
    }
  }

  public struct Model: Decodable, Equatable, Sendable {
    public let role: String
    public let port: Int?
    public let up: Bool
    public let model: String?
    public let latencyMS: Double?
    public let error: String?
    enum CodingKeys: String, CodingKey {
      case role, port, up, model, error
      case latencyMS = "latency_ms"
    }
  }

  public struct GPU: Decodable, Equatable, Sendable {
    public struct Card: Decodable, Equatable, Sendable {
      public let name: String?
      public let utilizationPct: Double?
      public let temperatureC: Double?
      public let powerW: Double?
      public let memoryUsedMiB: Double?
      public let memoryTotalMiB: Double?
      enum CodingKeys: String, CodingKey {
        case name
        case utilizationPct = "utilization_pct"
        case temperatureC = "temperature_c"
        case powerW = "power_w"
        case memoryUsedMiB = "memory_used_mib"
        case memoryTotalMiB = "memory_total_mib"
      }
    }

    public struct Unified: Decodable, Equatable, Sendable {
      public let totalMiB: Double?
      public let availableMiB: Double?
      public let gpuProcessesMiB: Double?
      enum CodingKeys: String, CodingKey {
        case totalMiB = "total_mib"
        case availableMiB = "available_mib"
        case gpuProcessesMiB = "gpu_processes_mib"
      }
    }

    public let available: Bool?
    public let gpus: [Card]
    public let unifiedMemory: Unified?

    enum CodingKeys: String, CodingKey {
      case available, gpus
      case unifiedMemory = "unified_memory"
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      available = try c.decodeIfPresent(Bool.self, forKey: .available)
      gpus = try c.decodeIfPresent([Card].self, forKey: .gpus) ?? []
      unifiedMemory = try c.decodeIfPresent(Unified.self, forKey: .unifiedMemory)
    }
  }

  public struct Disk: Decodable, Equatable, Sendable {
    public let totalGB: Double?
    public let freeGB: Double?
    public let freePct: Double?
    public let dataBytes: Int?
    public let spacesBytes: Int?
    enum CodingKeys: String, CodingKey {
      case totalGB = "total_gb"
      case freeGB = "free_gb"
      case freePct = "free_pct"
      case dataBytes = "data_bytes"
      case spacesBytes = "spaces_bytes"
    }
  }

  public let ok: Bool?
  public let checkedAt: String?
  public let organizer: Organizer?
  public let models: [Model]
  public let gpu: GPU?
  public let disk: Disk?
  public let warnings: [String]

  enum CodingKeys: String, CodingKey {
    case ok, organizer, models, gpu, disk, warnings
    case checkedAt = "checked_at"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    ok = try c.decodeIfPresent(Bool.self, forKey: .ok)
    checkedAt = try c.decodeIfPresent(String.self, forKey: .checkedAt)
    organizer = try c.decodeIfPresent(Organizer.self, forKey: .organizer)
    models = try c.decodeIfPresent([Model].self, forKey: .models) ?? []
    gpu = try c.decodeIfPresent(GPU.self, forKey: .gpu)
    disk = try c.decodeIfPresent(Disk.self, forKey: .disk)
    warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
  }

  /// Plain words for each warning code.
  public static func warningText(_ code: String) -> String {
    switch code {
    case "chat_down": return "整理用的模型没有响应"
    case "embed_down": return "向量模型没有响应"
    case "disk_low": return "磁盘剩余不到 5%"
    case "memory_low": return "可用内存不到 2 GB"
    default: return "整理设备报告：\(code)"
    }
  }
}

/// What enrollment answered (the credential is shown once).
public struct AccessEnrollAnswer: Decodable, Equatable, Sendable {
  public let ok: Bool
  public let accessID: String?
  public let memberID: String?
  public let deviceID: String?
  public let credential: String?
  public let fingerprint: String?
  public let error: String?

  enum CodingKeys: String, CodingKey {
    case ok
    case accessID = "access_id"
    case memberID = "member_id"
    case deviceID = "device_id"
    case credential, fingerprint, error
  }
}

/// The access and infrastructure routes over any transport: the owner's
/// own link (link token) or a member's bridge (its credential). None of them
/// is device-signed; the gate and the credential say who is asking.
public struct AccessClient: Sendable {
  public let client: SpaceClient

  public init(client: SpaceClient) { self.client = client }

  func decode<Value: Decodable>(_ type: Value.Type, _ data: Data) throws -> Value {
    do { return try JSONDecoder().decode(Value.self, from: data) } catch {
      throw SpaceClientError.malformed
    }
  }

  public func me() async throws -> AccessMe {
    try decode(AccessMe.self, await client.send("GET", "/v1/access/me", signed: false))
  }

  /// Registers a ticket: the invite key's public half and the secret's hash.
  public func createTicket(
    ticketID: String, kind: AccessInviteCode.Kind, sshKey: String, secretHash: String,
    expiresAt: Date, memberID: String? = nil
  ) async throws {
    var body: SpaceJSON = [
      "ticket_id": .string(ticketID.lowercased()), "kind": .string(kind.rawValue),
      "ssh_key": .string(sshKey), "secret_hash": .string(secretHash),
      "expires_at": .string(SpaceTime.string(expiresAt)),
    ]
    if let memberID { body = body.setting("member_id", .string(memberID.lowercased())) }
    let answer = try decode(
      SpaceJSON.self,
      await client.send("POST", "/v1/access/tickets", body: try body.encoded(), signed: false))
    guard answer["ok"]?.bool == true else {
      throw SpaceClientError.server(
        SpaceServerError(status: 200, code: answer["error"]?.string ?? "refused"))
    }
  }

  public func tickets() async throws -> [AccessTicketRecord] {
    let data = try await client.send("GET", "/v1/access/tickets", signed: false)
    return try decode(SpaceJSON.self, data)["tickets"].map {
      try $0.decoded(as: [AccessTicketRecord].self)
    } ?? []
  }

  public func revokeTicket(_ ticketID: String) async throws {
    _ = try await client.send(
      "DELETE", "/v1/access/tickets/\(ticketID.lowercased())", signed: false)
  }

  public func members() async throws -> [AccessRecord] {
    let data = try await client.send("GET", "/v1/access/members", signed: false)
    return try decode(SpaceJSON.self, data)["members"].map {
      try $0.decoded(as: [AccessRecord].self)
    } ?? []
  }

  public func devices(memberID: String? = nil) async throws -> AccessDevicesView {
    try decode(
      AccessDevicesView.self,
      await client.send(
        "GET", "/v1/access/devices", query: memberID.map { [("member_id", $0.lowercased())] } ?? [],
        signed: false))
  }

  /// Unpairs one Mac: its key line leaves the Spark (the file byte-identical
  /// to before its invite), its credential stops working at once.
  @discardableResult
  public func unpair(_ accessID: String) async throws -> Int {
    let data = try await client.send(
      "DELETE", "/v1/access/members/\(accessID.lowercased())", signed: false)
    return try decode(SpaceJSON.self, data)["removed"]?.int ?? 0
  }

  public func audit(since: Int = 0, limit: Int = 200) async throws -> AccessAuditPage {
    try decode(
      AccessAuditPage.self,
      await client.send(
        "GET", "/v1/access/audit", query: [("since", "\(since)"), ("limit", "\(limit)")],
        signed: false))
  }

  public func health() async throws -> InfraHealth {
    try decode(InfraHealth.self, await client.send("GET", "/v1/infra/health", signed: false))
  }
}
