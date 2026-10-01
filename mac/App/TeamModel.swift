import AppKit
import BestASRAgentAccess
import BestASRDomain
import BestASRMemoryUI
import BestASRRemoteOrganizer
import Combine
import Foundation
import MindloomSpaces

/// Settings → 团队与整理设备 (v8 contracts B and C on the Mac): this Mac's
/// own way in to the team's Spark, the admin console (health, members and
/// devices with their roles, org admins and key escrow, agents, the audit
/// records), a member's further Macs, scheduled encrypted backups and the
/// restore, storage quotas. Everything goes through the spaces engine and the
/// access client; this only schedules and adapts.
@MainActor
final class TeamModel: ObservableObject {
  static let shared = TeamModel()

  struct InviteDisplay: Equatable {
    let code: String
    let kind: AccessInviteCode.Kind
    let expires: Date
    let qr: NSImage?
    let spaceName: String?

    static func == (lhs: InviteDisplay, rhs: InviteDisplay) -> Bool { lhs.code == rhs.code }
  }

  /// One organization this Mac administers, from its own signed log.
  struct OrgView: Identifiable, Equatable {
    struct SpaceEscrow: Equatable {
      let spaceID: String
      let name: String
      let ok: Bool
      let required: Int
      let holders: Int
      let missing: [String]
      let member: Bool
    }

    let orgID: String
    let policy: Int
    let admins: [(id: String, name: String)]
    let spaces: [SpaceEscrow]
    /// Members of the org's spaces who are not admins (can be added).
    let candidates: [(id: String, name: String)]

    var id: String { orgID }

    static func == (lhs: OrgView, rhs: OrgView) -> Bool {
      lhs.orgID == rhs.orgID && lhs.policy == rhs.policy && lhs.spaces == rhs.spaces
        && lhs.admins.map(\.id) == rhs.admins.map(\.id)
        && lhs.candidates.map(\.id) == rhs.candidates.map(\.id)
    }
  }

  struct BackupRow: Identifiable, Equatable {
    let spaceID: String
    let name: String
    var schedule: SpaceBackupSchedule
    var receipts: [SpaceBackupReceipt]
    var folderMissing: Bool

    var id: String { spaceID }
  }

  @Published private(set) var access: MemberAccessRecord?
  @Published private(set) var me: AccessMe?
  @Published private(set) var health: InfraHealth?
  @Published private(set) var healthNote: String?
  @Published private(set) var members: [AccessRecord] = []
  @Published private(set) var myDevices: AccessDevicesView?
  @Published private(set) var tickets: [AccessTicketRecord] = []
  @Published private(set) var audit: [(at: String, text: String)] = []
  @Published private(set) var orgs: [OrgView] = []
  @Published private(set) var backups: [BackupRow] = []
  @Published private(set) var quotas:
    [(name: String, usage: SpaceUsage, members: [(String, Int)])] = []
  @Published var invite: InviteDisplay?
  @Published var status: String?
  @Published private(set) var busy = false
  @Published var joinCode = ""

  private(set) weak var spaces: SpacesModel?
  private(set) weak var app: DictationAppModel?
  private var schedules: [String: SpaceBackupSchedule] = [:]
  private var backupRunning = false

  func attach(spaces: SpacesModel, app: DictationAppModel) {
    self.spaces = spaces
    self.app = app
    loadSchedules()
  }

  private var engine: SpaceEngine? { spaces?.currentEngine() }

  private var accessClient: AccessClient? {
    guard let engine else { return nil }
    return AccessClient(client: engine.client)
  }

  /// This member's name as members see it, by member id.
  private func name(_ memberID: String) -> String {
    if memberID == access?.memberID || memberID == spaces?.screen.spaces.first?.memberID {
      return "我"
    }
    for state in spaces?.screen.spaces ?? [] {
      let name = state.name(of: memberID)
      if name != "成员" { return name }
    }
    return "成员 " + String(memberID.prefix(4))
  }

  var isOwner: Bool { me?.isOwner == true }
  var isAdmin: Bool { me.map { $0.isOwner || $0.mayInvite } ?? false }

  // MARK: - Refresh

  func refresh() {
    guard !busy else { return }
    busy = true
    Task {
      await load()
      busy = false
    }
  }

  private func load() async {
    access = try? spaces?.stores?.access.load()
    loadSchedules()
    refreshQuotas()
    guard let client = accessClient, let engine else {
      status = "共享空间还没有准备好：先在「数据」里打开整理设备链路，或用邀请码加入团队"
      return
    }
    do {
      let who = try await client.me()
      me = who
      members = (try? await client.members()) ?? []
      myDevices = try? await client.devices()
      tickets = (try? await client.tickets()) ?? []
      if who.isOwner { await reconcileRelay(force: false) }
      if who.isOwner || who.mayInvite {
        do {
          health = try await client.health()
          healthNote = nil
        } catch {
          healthNote = "暂时读不到整理设备的状态"
        }
      } else {
        health = nil
        healthNote = "只有整理设备的主人和组织管理员能看整理设备的状态"
      }
      var lines: [(at: String, text: String)] = []
      for entry in (try? await client.audit(limit: 100))?.entries ?? [] {
        lines.append((entry.at, SpaceWords.audit(entry.action) + Self.ids(entry.target)))
      }
      orgs = await loadOrgs(engine)
      for org in orgs {
        for record in (try? await engine.client.orgAudit(org.orgID, limit: 100))?.records ?? [] {
          lines.append(
            (record.at, SpaceWords.audit(record.action) + Self.ids(record.target)))
        }
      }
      audit = lines.sorted { $0.at > $1.at }.prefix(200).map { $0 }
      status = nil
    } catch {
      status = SpacesModel.message(error)
    }
    refreshBackups()
  }

  /// Ids only (an audit record never holds content).
  static func ids(_ target: SpaceJSON?) -> String {
    guard let object = target?.object else { return "" }
    let parts = object.keys.sorted().compactMap { key -> String? in
      guard let value = object[key] else { return nil }
      if let text = value.string { return "\(key)=\(text.prefix(8))" }
      if let number = value.int { return "\(key)=\(number)" }
      return nil
    }
    return parts.isEmpty ? "" : " · " + parts.joined(separator: " ")
  }

  private func loadOrgs(_ engine: SpaceEngine) async -> [OrgView] {
    let states = spaces?.screen.spaces ?? []
    var out: [OrgView] = []
    for org in (try? await engine.orgs()) ?? [] where org.admin {
      guard let roster = await engine.orgRoster(org.orgID) else { continue }
      let inOrg = states.filter { $0.orgID == org.orgID && $0.membership == .active }
      let escrow = inOrg.map { state in
        OrgView.SpaceEscrow(
          spaceID: state.spaceID, name: state.name, ok: state.escrow?.ok ?? true,
          required: state.escrow?.required ?? 1, holders: state.escrow?.holders.count ?? 1,
          missing: (state.escrow?.missing ?? []).map { name($0.memberID) }, member: true)
      }
      var candidates: [(id: String, name: String)] = []
      for state in inOrg {
        for member in state.activeMembers
        where !roster.isAdmin(member.memberID)
          && !candidates.contains(where: { $0.id == member.memberID })
        {
          candidates.append((member.memberID, name(member.memberID)))
        }
      }
      out.append(
        OrgView(
          orgID: org.orgID, policy: roster.policy,
          admins: roster.activeAdmins.map { ($0, name($0)) }, spaces: escrow,
          candidates: candidates))
    }
    return out
  }

  private func refreshQuotas() {
    quotas = (spaces?.screen.spaces ?? []).compactMap { state in
      guard state.membership == .active, let usage = state.usage else { return nil }
      let others =
        state.role == .admin
        ? state.activeMembers.compactMap { member in
          member.usageBytes.map { (state.name(of: member.memberID), $0) }
        } : []
      return (state.name, usage, others)
    }
  }

  // MARK: - This Mac's own way in

  /// 用邀请码加入团队: enroll through the ticket key, keep the credential and
  /// this Mac's own key in the Keychain, then use the bridge from now on; a
  /// space invite inside the code is joined right after.
  func joinTeam() {
    let text = joinCode.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let code = try? AccessInviteCode.decode(text) else {
      status = "邀请码看不懂或已过期"
      return
    }
    guard let spaces, let engine, let stores = spaces.stores, let gate = stores.gateDirectory else {
      status = "共享空间还没有准备好"
      return
    }
    busy = true
    status = "正在用邀请钥匙连上整理设备…"
    Task {
      defer { busy = false }
      do {
        let route = SSHGateRoute(spark: code.spark, relay: code.relay, workDirectory: gate)
        let identity = try await engine.memberIdentity()
        let record = try await TeamAccess.enroll(
          code: code, device: await engine.device, memberID: identity, store: stores.access
        ) { key, request in
          try await SSHGateEnrollment.enroll(route: route, ticketKey: key, request: request)
        }
        try await engine.setMemberIdentity(record.memberID)
        spaces.resetEngine()
        joinCode = ""
        status = "已加入团队：这台 Mac 用自己的钥匙连整理设备" + (code.space == nil ? "" : "；正在申请加入共享空间")
        if let space = code.space {
          spaces.actions(navigate: { _, _ in }).join(space, SpacesModel.myName)
        }
        await load()
      } catch TeamAccess.TeamError.refused(let reason) {
        status = TeamAccess.message(reason)
      } catch {
        status = SpacesModel.message(error)
      }
    }
  }

  /// 断开这台 Mac: its key line leaves the Spark, its credential stops; its
  /// spaces stay on this Mac until someone removes this device there.
  func leaveTeam() {
    guard let access, let client = accessClient else { return }
    run("已断开这台 Mac：它的钥匙已从整理设备上删除") { [weak self] in
      _ = try await client.unpair(access.accessID)
      try self?.spaces?.stores?.access.delete()
      await MainActor.run { self?.spaces?.resetEngine() }
    }
  }

  // MARK: - Invites

  /// 邀请队友 / 加一台我的 Mac: a one-time ticket key and secret, registered
  /// on the Spark (public key and hash only); the code holds the private key.
  func makeInvite(kind: AccessInviteCode.Kind, spaceID: String? = nil) {
    guard let client = accessClient, let engine else { return }
    let service = app?.phoneLink.service
    let own = access
    run(nil) { [weak self] in
      var spark: SpaceInviteCode.Endpoint
      var relay: SpaceInviteCode.Endpoint?
      var route: TeamRoute?
      if let own {
        spark = own.spark
        relay = own.relay
      } else if let service {
        route = try await service.teamRoute()
        spark = route!.spark
        relay = route!.relay
      } else {
        throw SpaceEngine.EngineError.refused("no_route")
      }
      var spaceCode: String?
      var spaceName: String?
      if kind == .member, let spaceID {
        let state = try await engine.state(spaceID)
        spaceName = state?.name
        let invite = try await engine.invite(
          spaceID, role: .write, hostKey: spark.hostKey,
          spark: .init(host: spark.host, port: spark.port, user: nil, hostKey: spark.hostKey))
        spaceCode = try invite.encoded()
      }
      let identity = try await engine.memberIdentity()
      let (code, key) = try await TeamAccess.makeInvite(
        access: client, kind: kind, spark: spark, relay: relay,
        memberID: kind == .device ? identity : nil, team: spaceName, space: spaceCode)
      if let route, route.relay != nil, let service {
        // The relay line lets the ticket key open a tunnel to the Spark only.
        try await service.authorizeTeamRelay(route, key: key)
      }
      let text = try code.encoded()
      let qr = PhonePairingQRCode.image(for: text).map {
        NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
      }
      await MainActor.run {
        self?.invite = InviteDisplay(
          code: text, kind: kind, expires: code.expiry ?? Date(), qr: qr, spaceName: spaceName)
      }
    }
  }

  func revokeTicket(_ ticketID: String) {
    guard let client = accessClient else { return }
    run("已收回邀请") { [weak self] in
      try await client.revokeTicket(ticketID)
      await self?.reconcileRelay(force: true)
    }
  }

  // MARK: - Members and devices

  /// 断开 a Mac (review V8R-07): its key line leaves the Spark (which from
  /// then on refuses that device everywhere and never lets it enroll again),
  /// and before this says it is done, the Mac is removed from every space and
  /// organization this Mac may sign for, each space with a new key. Spaces
  /// only their own admins can change are named in the result.
  func unpair(_ record: AccessRecord) {
    guard let client = accessClient else { return }
    let engine = self.engine
    let mine = record.accessID == access?.accessID
    run(nil) { [weak self] in
      _ = try await client.unpair(record.accessID)
      if mine {
        try self?.spaces?.stores?.access.delete()
        await MainActor.run {
          self?.spaces?.resetEngine()
          self?.status = "已断开这台 Mac"
        }
        return
      }
      var removed = 0
      var left = 0
      if let engine,
        let view = try? await client.devices(memberID: record.memberID),
        let device = view.devices.first(where: { $0.deviceID == record.deviceID }),
        let places = device.toRemove
      {
        for space in places.spaces {
          do {
            try await engine.retireDevice(space, deviceID: device.deviceID)
            removed += 1
          } catch { left += 1 }
        }
        for org in places.orgs { try? await engine.retireOrgDevice(org, deviceID: device.deviceID) }
      }
      await self?.reconcileRelay(force: true)
      let text =
        "已断开那台 Mac" + (removed > 0 ? "，并从 \(removed) 个空间移除（空间都换了新钥匙）" : "")
        + (left > 0 ? "；还有 \(left) 个空间要由那里的管理员移除它" : "")
      await MainActor.run { self?.status = text }
    }
  }

  private var lastRelayReconcile = Date.distantPast

  /// Review V8R-12 (the Spark owner's Mac, which alone can edit the relay):
  /// the relay's team lines follow the Spark's records — one per open ticket
  /// key and per paired Mac's own key; a used, expired or revoked ticket's and
  /// an unpaired Mac's line go, so the relay is as it was before the invite.
  func reconcileRelay(force: Bool) async {
    guard access == nil, let service = app?.phoneLink.service, let client = accessClient,
      force || Date().timeIntervalSince(lastRelayReconcile) > 300
    else { return }
    lastRelayReconcile = Date()
    guard let route = try? await service.teamRoute(), route.relayDestination != nil,
      let tickets = try? await client.tickets(), let members = try? await client.members()
    else { return }
    _ = try? await service.reconcileTeamRelay(
      route, wanted: TeamRelayLines.wanted(tickets: tickets, members: members))
  }

  /// 把新 Mac 加进去: `device.add` in each space (the current key wrapped to
  /// it), `org.device_add` in each org it should administer.
  func completeAdd(_ device: AccessDevicesView.Device) {
    guard let engine, let places = device.toAdd else { return }
    run("已把那台 Mac 加进 \(places.spaces.count) 个空间和 \(places.orgs.count) 个组织") {
      for space in places.spaces { try await engine.addDevice(space, device: device.publicRecord) }
      for org in places.orgs { try await engine.addOrgDevice(org, device: device.publicRecord) }
    }
  }

  /// 把断开的 Mac 移除: `device.remove` with a new key in each space,
  /// `org.device_remove` in each org.
  func completeRemove(_ device: AccessDevicesView.Device) {
    guard let engine, let places = device.toRemove else { return }
    run("已把断开的 Mac 从 \(places.spaces.count) 个空间移除，空间都换了新钥匙") {
      for space in places.spaces { try await engine.retireDevice(space, deviceID: device.deviceID) }
      for org in places.orgs { try await engine.retireOrgDevice(org, deviceID: device.deviceID) }
    }
  }

  // MARK: - Organizations and key escrow

  /// 添加组织管理员: names that member's own Mac as an org space's signed
  /// roster admitted it (review V8R-08: never from the Spark's device list,
  /// which a member id squatter could fill), then escrows the org spaces'
  /// keys to it.
  func addOrgAdmin(orgID: String, memberID: String) {
    guard let engine else { return }
    let states = (spaces?.screen.spaces ?? []).filter {
      $0.membership == .active && $0.orgID == orgID.lowercased()
    }
    run("已添加组织管理员；组织空间的钥匙也托管给了他") {
      let device = states.lazy.compactMap { state in
        state.roster?.members[memberID]?.devices.values.filter(\.active)
          .sorted { $0.deviceID < $1.deviceID }.first?.publicRecord
      }.first
      guard let device else { throw SpaceEngine.EngineError.refused("unknown_member_device") }
      try await engine.addOrgAdmin(orgID, memberID: memberID, device: device)
    }
  }

  func setRecoveryAdmins(orgID: String, count: Int) {
    guard let engine else { return }
    run("已更新：至少 \(count) 位组织管理员能找回每个组织空间") {
      try await engine.setRecoveryAdmins(orgID, count: count)
    }
  }

  func fillEscrow(_ spaceID: String) {
    guard let engine else { return }
    run(nil) { [weak self] in
      let n = try await engine.fillEscrow(spaceID)
      await MainActor.run { self?.status = n > 0 ? "已补齐 \(n) 份托管钥匙" : "没有需要补的" }
    }
  }

  /// The org spaces of an org this Mac is not a member of (a takeover candidate).
  func recoverable(_ org: OrgView) async -> [SpaceEscrowWrap] {
    guard let engine else { return [] }
    let known = Set(
      (spaces?.screen.spaces ?? []).filter { $0.membership == .active }.map(\.spaceID))
    return ((try? await engine.client.orgEscrow(org.orgID)) ?? []).filter {
      $0.wrap != nil && !known.contains($0.spaceID)
    }
  }

  func recover(orgID: String, spaceID: String) {
    guard let engine else { return }
    run("已接管这个空间；你现在是它的管理员。记得把丢失的那台 Mac 移除（会换钥匙）") {
      _ = try await engine.recover(orgID: orgID, spaceID: spaceID, displayName: SpacesModel.myName)
    }
  }

  // MARK: - Agents

  func revokeAgent(_ grantID: UUID) { app?.agentAccess.revoke(grantID) }

  // MARK: - Backups (B4)

  private var schedulesURL: URL? {
    (try? DictationAppModel.applicationDataRoot())?.appendingPathComponent(
      "team", isDirectory: true
    )
    .appendingPathComponent("backups.json")
  }

  private func loadSchedules() {
    guard let url = schedulesURL, let data = try? Data(contentsOf: url) else { return }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    schedules = (try? decoder.decode([String: SpaceBackupSchedule].self, from: data)) ?? [:]
  }

  private func saveSchedules() {
    guard let url = schedulesURL else { return }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    if let data = try? encoder.encode(schedules) { try? data.write(to: url, options: [.atomic]) }
  }

  private func refreshBackups() {
    let states = (spaces?.screen.spaces ?? []).filter {
      $0.membership == .active && $0.role == .admin
    }
    backups = states.map { state in
      let schedule = schedules[state.spaceID] ?? SpaceBackupSchedule()
      let folder = schedule.folder.map { URL(fileURLWithPath: $0, isDirectory: true) }
      let missing = folder.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
      return BackupRow(
        spaceID: state.spaceID, name: state.name, schedule: schedule,
        receipts: folder.map { Self.receipts(in: $0, spaceID: state.spaceID) } ?? [],
        folderMissing: missing)
    }
  }

  static func receipts(in folder: URL, spaceID: String) -> [SpaceBackupReceipt] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return names.filter { $0.hasSuffix(".\(SpaceBackup.fileExtension).json") }.compactMap {
      try? decoder.decode(
        SpaceBackupReceipt.self, from: Data(contentsOf: folder.appendingPathComponent($0)))
    }.filter { $0.spaceID == spaceID }.sorted { $0.createdAt > $1.createdAt }
  }

  func setInterval(_ spaceID: String, _ interval: SpaceBackupSchedule.Interval) {
    var schedule = schedules[spaceID] ?? SpaceBackupSchedule()
    schedule.interval = interval
    schedules[spaceID] = schedule
    saveSchedules()
    refreshBackups()
  }

  /// A folder on this Mac or an external disk.
  func chooseFolder(_ spaceID: String) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "存到这里"
    panel.message = "选一个文件夹（这台 Mac 上，或移动硬盘上）存放这个空间的加密备份"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    var schedule = schedules[spaceID] ?? SpaceBackupSchedule()
    schedule.folder = url.path
    schedules[spaceID] = schedule
    saveSchedules()
    refreshBackups()
  }

  func backupNow(_ spaceID: String) {
    Task { await backup(spaceID) }
  }

  /// Called on every tick of the spaces loop.
  func runDueBackups() async {
    guard !backupRunning else { return }
    for (spaceID, schedule) in schedules where schedule.isDue(now: Date()) {
      await backup(spaceID)
    }
  }

  private func backup(_ spaceID: String) async {
    guard let engine, !backupRunning else { return }
    var schedule = schedules[spaceID] ?? SpaceBackupSchedule()
    guard let path = schedule.folder else {
      status = "先选一个存放备份的文件夹"
      return
    }
    backupRunning = true
    defer { backupRunning = false }
    schedule.lastAttempt = Date()
    let folder = URL(fileURLWithPath: path, isDirectory: true)
    do {
      guard FileManager.default.fileExists(atPath: folder.path) else {
        throw CocoaError(.fileNoSuchFile)
      }
      let (stream, receipt) = try await engine.backup(spaceID)
      let file = folder.appendingPathComponent(receipt.fileName)
      try stream.write(to: file, options: [.atomic])
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .secondsSince1970
      encoder.outputFormatting = [.sortedKeys]
      // V8R-13: the receipt names no space (ids, counts, the key sealed to the
      // admins' Macs) and is readable by this user only.
      let receiptFile = folder.appendingPathComponent(receipt.fileName + ".json")
      try encoder.encode(receipt).write(to: receiptFile, options: [.atomic])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: receiptFile.path)
      schedule.lastSuccess = Date()
      schedule.lastError = nil
      let name = spaces?.screen.space(spaceID)?.name ?? ""
      status = "已备份「\(name)」：\(SpaceUsage.megabytes(receipt.bytes))，只有空间管理员打得开"
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      schedule.lastError = "folder_missing"
      status = "备份文件夹不在（移动硬盘没有接上？）"
    } catch {
      schedule.lastError = "failed"
      status = "备份没有完成：" + SpacesModel.message(error)
    }
    schedules[spaceID] = schedule
    saveSchedules()
    refreshBackups()
  }

  /// 恢复: puts the space on the Spark back from a kept backup (`replace`).
  /// Review V8R-03: when the Spark's record of the space already holds the
  /// backup's (the backup is older), only missing or damaged data comes back;
  /// members removed and keys changed since stay as they are. Items this
  /// Mac's own log says were withdrawn or removed since are purged again.
  func restore(_ receipt: SpaceBackupReceipt) {
    guard let engine, let path = schedules[receipt.spaceID]?.folder else { return }
    let file = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(
      receipt.fileName)
    let when = receipt.createdAt.formatted(date: .abbreviated, time: .shortened)
    run(nil) { [weak self] in
      let stream = try Data(contentsOf: file)
      guard SpaceCrypto.sha256Hex(stream) == receipt.sha256 else {
        throw SpaceBackup.BackupError.damaged("digest")
      }
      let answer = try await engine.restore(
        receipt.spaceID, stream: stream, mode: "replace", keyWraps: receipt.keyWraps)
      let text =
        answer["applied"]?.string == "fill"
        ? "已用 \(when) 的备份补回缺的内容；这个备份比现在的记录旧，之后的成员变动和换过的钥匙都保持现在的样子"
        : "已从 \(when) 的备份恢复了空间"
      await MainActor.run { self?.status = text }
    }
  }

  // MARK: - Plumbing

  private func run(_ success: String?, _ work: @escaping () async throws -> Void) {
    busy = true
    Task { [weak self] in
      do {
        try await work()
        self?.status = success ?? self?.status
      } catch TeamAccess.TeamError.refused(let reason) {
        self?.status = TeamAccess.message(reason)
      } catch {
        self?.status = SpacesModel.message(error)
      }
      self?.busy = false
      await self?.load()
    }
  }
}
