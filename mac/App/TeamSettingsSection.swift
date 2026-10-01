import AppKit
import BestASRAgentAccess
import MindloomSpaces
import SwiftUI

/// 设置 → 团队与整理设备 (v8 contracts B and C): how this Mac reaches the
/// team's organizing device (its own key, never the owner's account), the
/// device's health, members and their Macs with roles, inviting a teammate
/// and adding another Mac of mine, org admins and key escrow, agents with
/// access, the audit records, backups, storage.
struct TeamSettingsSections: View {
  @ObservedObject var model: DictationAppModel
  @ObservedObject var team: TeamModel
  @State private var confirmLeave = false
  @State private var pendingUnpair: AccessRecord?
  @State private var pendingRestore: SpaceBackupReceipt?
  @State private var inviteSpace: String = ""
  @State private var recoverable: [String: [SpaceEscrowWrap]] = [:]

  init(model: DictationAppModel) {
    self.model = model
    team = TeamModel.shared
  }

  var body: some View {
    Section {
      Text(
        "一台整理设备可以给整个实验室用：每个人的 Mac 用自己的钥匙进门，只能进共享空间的门，进不了主人的账号；空间里的内容照样只在成员的 Mac 上打得开。管理员在这里看整理设备的状态、成员和设备、钥匙托管、备份。"
      )
      .font(.callout)
      HStack {
        Button("刷新") { team.refresh() }.disabled(team.busy)
        if team.busy { ProgressView().controlSize(.small) }
      }
      if let status = team.status {
        Text(status).font(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("bestASR.settings.team.status")
      }
    }
    .onAppear { team.refresh() }
    thisMac
    healthSection
    membersSection
    devicesToDo
    orgsSection
    agentsSection
    backupsSection
    quotasSection
    auditSection
  }

  // MARK: - This Mac

  @ViewBuilder private var thisMac: some View {
    Section("这台 Mac 怎么连整理设备") {
      if let access = team.access {
        Text("团队成员：用这台 Mac 自己的钥匙连「\(access.team ?? "团队")」的整理设备")
        Text(
          "钥匙指纹 \(access.fingerprint ?? "—") · \(access.pairedAt.formatted(date: .abbreviated, time: .shortened)) 加入"
        )
        .font(.caption).foregroundStyle(.secondary)
        Button("断开这台 Mac…", role: .destructive) { confirmLeave = true }
          .accessibilityIdentifier("bestASR.settings.team.leave")
          .confirmationDialog("断开这台 Mac？", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("断开", role: .destructive) { team.leaveTeam() }
            Button("取消", role: .cancel) {}
          } message: {
            Text("这台 Mac 的钥匙会从整理设备上删除，之后它连不上团队的整理设备。它已经在的共享空间，要由管理员把这台设备移除（会换钥匙）。")
          }
      } else if model.remoteOrganizerEnabled {
        Text("整理设备的主人：用你自己的 SSH 账号和链路令牌（「数据」里的整理设备链路）")
        Text("队友不会用你的账号：请在下面「邀请队友」，他们的 Mac 会有自己的钥匙。")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Text("还没有连上团队的整理设备")
      }
      if team.access == nil {
        VStack(alignment: .leading, spacing: 6) {
          Text("用邀请码加入团队").font(.headline)
          TextField("粘贴队友发来的邀请码（mlteam1. 开头）", text: $team.joinCode)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("bestASR.settings.team.joinCode")
          Button("加入") { team.joinTeam() }
            .disabled(team.joinCode.isEmpty || team.busy)
            .accessibilityIdentifier("bestASR.settings.team.join")
          Text("加入时这台 Mac 会生成自己的钥匙；邀请码里的一次性钥匙只能用来加入，用完就作废。")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  // MARK: - Health

  @ViewBuilder private var healthSection: some View {
    Section("整理设备状态") {
      if let health = team.health {
        if let organizer = health.organizer {
          Text(
            "整理器 \(organizer.version ?? "") · 已运行 \(Self.duration(organizer.uptimeS)) · 共享空间 \(organizer.spaces?.spaces ?? 0) 个，排队 \(organizer.spaces?.queue ?? 0) 条"
          )
        }
        ForEach(Array(health.models.enumerated()), id: \.offset) { _, model in
          HStack {
            Image(systemName: model.up ? "checkmark.circle.fill" : "xmark.octagon.fill")
              .foregroundStyle(model.up ? .green : .red)
            Text(Self.modelRole(model.role))
            Spacer()
            Text(model.up ? "\(Int(model.latencyMS ?? 0)) ms" : "没有响应")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        if let memory = health.gpu?.unifiedMemory, let total = memory.totalMiB {
          Text(
            "GPU \(health.gpu?.gpus.first?.name ?? "") · 共享内存可用 \(Int((memory.availableMiB ?? 0) / 1024)) / \(Int(total / 1024)) GB"
          )
        } else if let card = health.gpu?.gpus.first {
          Text(
            "GPU \(card.name ?? "") · 显存 \(Int((card.memoryUsedMiB ?? 0) / 1024)) / \(Int((card.memoryTotalMiB ?? 0) / 1024)) GB"
          )
        }
        if let disk = health.disk {
          Text("磁盘剩余 \(Int(disk.freeGB ?? 0)) GB（\(Int(disk.freePct ?? 0))%）")
        }
        ForEach(health.warnings, id: \.self) { warning in
          Text(InfraHealth.warningText(warning)).foregroundStyle(.orange)
        }
        Text("这里只有数字和状态，没有任何素材、名字或别人的进程。").font(.caption).foregroundStyle(.secondary)
      } else {
        Text(team.healthNote ?? "还没有读到").foregroundStyle(.secondary)
      }
    }
  }

  static func duration(_ seconds: Double?) -> String {
    guard let seconds else { return "—" }
    if seconds < 3_600 { return "\(Int(seconds / 60)) 分钟" }
    if seconds < 86_400 { return "\(Int(seconds / 3_600)) 小时" }
    return "\(Int(seconds / 86_400)) 天"
  }

  static func modelRole(_ role: String) -> String {
    switch role {
    case "chat": return "整理用的对话模型"
    case "embed": return "向量模型"
    default: return role.hasPrefix("image") ? "读图模型" : role
    }
  }

  // MARK: - Members and devices

  @ViewBuilder private var membersSection: some View {
    Section("成员和设备") {
      let grouped = Dictionary(grouping: team.members, by: \.memberID)
      if grouped.isEmpty {
        Text("还没有队友用自己的钥匙加入。").foregroundStyle(.secondary)
      }
      ForEach(grouped.keys.sorted(), id: \.self) { member in
        VStack(alignment: .leading, spacing: 4) {
          Text(memberTitle(member)).font(.headline)
          ForEach(grouped[member] ?? []) { record in
            HStack {
              Text(
                (record.accessID == team.access?.accessID ? "这台 Mac" : "Mac")
                  + " · \(record.fingerprint ?? "")"
              )
              .font(.caption)
              Text(record.isActive ? "已连接" : "已断开").font(.caption)
                .foregroundStyle(record.isActive ? .green : .secondary)
              if let seen = record.lastSeenAt.flatMap(SpaceTime.date) {
                Text("最近 \(seen.formatted(date: .abbreviated, time: .shortened))")
                  .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if record.isActive, team.isAdmin || record.memberID == team.access?.memberID {
                Button("断开") { pendingUnpair = record }
              }
            }
          }
        }
      }
      .confirmationDialog(
        "断开这台 Mac？",
        isPresented: Binding(
          get: { pendingUnpair != nil }, set: { if !$0 { pendingUnpair = nil } }),
        titleVisibility: .visible
      ) {
        Button("断开", role: .destructive) {
          if let record = pendingUnpair { team.unpair(record) }
        }
        Button("取消", role: .cancel) {}
      } message: {
        Text("它的钥匙从整理设备上删除，凭证立即失效。要让它看不到以后的新内容，还要在它所在的空间里把它移除（会换钥匙）——下面的「待办」会列出来。")
      }
      if team.isAdmin || team.access != nil {
        HStack {
          if team.isAdmin {
            Picker("连同空间", selection: $inviteSpace) {
              Text("只邀请进门").tag("")
              ForEach(adminSpaces, id: \.spaceID) { Text("并加入「\($0.name)」").tag($0.spaceID) }
            }
            .frame(width: 260)
            Button("邀请队友") {
              team.makeInvite(kind: .member, spaceID: inviteSpace.isEmpty ? nil : inviteSpace)
            }
            .accessibilityIdentifier("bestASR.settings.team.invite")
          }
          Button("加一台我的 Mac") { team.makeInvite(kind: .device) }
            .accessibilityIdentifier("bestASR.settings.team.addMac")
        }
      }
      if let invite = team.invite {
        HStack(alignment: .top, spacing: 14) {
          if let qr = invite.qr {
            Image(nsImage: qr).interpolation(.none).resizable().frame(width: 120, height: 120)
              .accessibilityLabel("邀请二维码")
          }
          VStack(alignment: .leading, spacing: 6) {
            Text(invite.kind == .device ? "在你的另一台 Mac 上粘贴这个邀请码：" : "把这个邀请码当面或私下发给队友：")
              .font(.caption)
            Text(invite.code).font(.system(size: 10, design: .monospaced)).lineLimit(3)
              .truncationMode(.middle).textSelection(.enabled)
            Button("复制邀请码") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(invite.code, forType: .string)
            }
            Text(
              "一次有效，\(invite.expires.formatted(date: .abbreviated, time: .shortened)) 前有效。邀请码里有一把一次性钥匙，只能用来加入；对方加入时会生成自己的钥匙。"
                + (invite.spaceName.map { "加入后会申请进「\($0)」，你同意后才进得去。" } ?? "")
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      let open = team.tickets.filter { $0.status == "open" }
      if !open.isEmpty {
        ForEach(open) { ticket in
          HStack {
            Text("没用掉的邀请（\(ticket.kind == "device" ? "我的 Mac" : "队友")）").font(.caption)
            Spacer()
            Button("收回") { team.revokeTicket(ticket.ticketID) }
          }
        }
      }
    }
  }

  private var adminSpaces: [SpaceLocalState] {
    (team.spaces?.screen.spaces ?? []).filter { $0.membership == .active && $0.can("invite") }
  }

  private func memberTitle(_ memberID: String) -> String {
    var roles: [String] = []
    for state in team.spaces?.screen.spaces ?? [] where state.membership == .active {
      if let member = state.member(memberID), member.isActive {
        roles.append("「\(state.name)」\(member.role.title)")
      }
    }
    for org in team.orgs where org.admins.contains(where: { $0.id == memberID }) {
      roles.append("组织管理员")
    }
    let name =
      team.spaces?.screen.spaces.lazy.map { $0.name(of: memberID) }.first { $0 != "成员" }
      ?? "成员 \(memberID.prefix(4))"
    return roles.isEmpty ? name : "\(name) · " + roles.joined(separator: "、")
  }

  // MARK: - To do for my Macs

  @ViewBuilder private var devicesToDo: some View {
    let devices = team.myDevices?.devices ?? []
    let add = devices.filter {
      !($0.toAdd?.isEmpty ?? true) && $0.deviceID != team.access?.deviceID
    }
    let remove = devices.filter { !($0.toRemove?.isEmpty ?? true) }
    if !add.isEmpty || !remove.isEmpty {
      Section("待办：我的几台 Mac") {
        ForEach(add) { device in
          HStack {
            Text(
              "另一台 Mac（\(device.publicRecord.fingerprint)）还没加进 \(device.toAdd?.spaces.count ?? 0) 个空间、\(device.toAdd?.orgs.count ?? 0) 个组织"
            )
            Spacer()
            Button("加进去") { team.completeAdd(device) }
          }
        }
        ForEach(remove) { device in
          HStack {
            Text(
              "断开的 Mac（\(device.publicRecord.fingerprint)）还在 \(device.toRemove?.spaces.count ?? 0) 个空间、\(device.toRemove?.orgs.count ?? 0) 个组织里"
            )
            Spacer()
            Button("移除（换钥匙）") { team.completeRemove(device) }
          }
        }
      }
    }
  }

  // MARK: - Organizations and key escrow

  @ViewBuilder private var orgsSection: some View {
    if !team.orgs.isEmpty {
      Section("组织管理员和钥匙托管") {
        Text(
          "组织空间的每一把钥匙，都另外托管给几位组织管理员的 Mac：丢了一位管理员的电脑，另一位还能接管空间。组织管理员因此能打开组织的任何空间（就像组织所有者能进组织的任何仓库）。"
        )
        .font(.caption).foregroundStyle(.secondary)
        ForEach(team.orgs) { org in
          VStack(alignment: .leading, spacing: 6) {
            Text("组织管理员：" + org.admins.map(\.name).joined(separator: "、")).font(.headline)
            Picker(
              "至少几位管理员能找回空间",
              selection: Binding(
                get: { org.policy }, set: { team.setRecoveryAdmins(orgID: org.orgID, count: $0) })
            ) {
              ForEach(1...3, id: \.self) { Text("\($0) 位").tag($0) }
            }
            .frame(width: 320)
            ForEach(org.spaces, id: \.spaceID) { space in
              HStack {
                Text("「\(space.name)」")
                Text(
                  space.ok
                    ? "\(space.holders) 位管理员能打开" : "还缺：" + space.missing.joined(separator: "、")
                )
                .font(.caption).foregroundStyle(space.ok ? .green : .orange)
                Spacer()
                if !space.missing.isEmpty { Button("补齐托管") { team.fillEscrow(space.spaceID) } }
              }
            }
            if !org.candidates.isEmpty {
              Menu("添加组织管理员") {
                ForEach(org.candidates, id: \.id) { candidate in
                  Button(candidate.name) {
                    team.addOrgAdmin(orgID: org.orgID, memberID: candidate.id)
                  }
                }
              }
              .frame(width: 200)
            }
            ForEach(recoverable[org.orgID] ?? [], id: \.spaceID) { wrap in
              HStack {
                Text("你不在的组织空间 \(wrap.spaceID.prefix(8))：可以用托管的钥匙接管").font(.caption)
                Spacer()
                Button("接管…") { team.recover(orgID: org.orgID, spaceID: wrap.spaceID) }
              }
            }
          }
          .task(id: org.orgID) { recoverable[org.orgID] = await team.recoverable(org) }
        }
      }
    }
  }

  // MARK: - Agents

  @ViewBuilder private var agentsSection: some View {
    Section("可以读织机的 Agent") {
      let grants = model.agentAccess.grants
      if grants.isEmpty {
        Text("没有 Agent 有读取权限。").foregroundStyle(.secondary)
      }
      ForEach(grants) { grant in
        HStack {
          VStack(alignment: .leading) {
            Text(grant.clientName)
            Text(AgentAccessModel.scopeSummary(grant.terms)).font(.caption).foregroundStyle(
              .secondary)
          }
          Spacer()
          Button("收回", role: .destructive) { team.revokeAgent(grant.grantID) }
        }
      }
      Text("Agent 每读一次共享空间，空间的记录里都会留一条（只有次数，没有内容）。").font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Backups

  @ViewBuilder private var backupsSection: some View {
    if !team.backups.isEmpty {
      Section("备份") {
        Text("每个空间可以定时加密备份到这台 Mac 或移动硬盘。备份只有空间成员的钥匙打得开，整理设备自己也打不开。")
          .font(.caption).foregroundStyle(.secondary)
        ForEach(team.backups) { row in
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text("「\(row.name)」").font(.headline)
              Spacer()
              Picker(
                "",
                selection: Binding(
                  get: { row.schedule.interval }, set: { team.setInterval(row.spaceID, $0) })
              ) {
                ForEach(SpaceBackupSchedule.Interval.allCases, id: \.self) {
                  Text($0.title).tag($0)
                }
              }
              .labelsHidden().frame(width: 120)
            }
            HStack {
              Text(row.schedule.folder ?? "还没选存放的文件夹").font(.caption).lineLimit(1)
                .truncationMode(.middle)
              if row.folderMissing {
                Text("（现在找不到：移动硬盘没接上？）").font(.caption).foregroundStyle(.orange)
              }
              Spacer()
              Button("选择文件夹…") { team.chooseFolder(row.spaceID) }
              Button("现在备份") { team.backupNow(row.spaceID) }.disabled(row.schedule.folder == nil)
                .accessibilityIdentifier("bestASR.settings.team.backupNow")
            }
            if let last = row.schedule.lastSuccess {
              Text("上次备份：\(last.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                .foregroundStyle(.secondary)
            }
            ForEach(row.receipts.prefix(5)) { receipt in
              HStack {
                Text(
                  "\(receipt.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(receipt.items) 条素材 · \(SpaceUsage.megabytes(receipt.bytes))"
                )
                .font(.caption)
                Spacer()
                Button("恢复…") { pendingRestore = receipt }
              }
            }
          }
        }
        .confirmationDialog(
          "用这份备份恢复空间？",
          isPresented: Binding(
            get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
          titleVisibility: .visible
        ) {
          Button("恢复", role: .destructive) {
            if let receipt = pendingRestore { team.restore(receipt) }
          }
          Button("取消", role: .cancel) {}
        } message: {
          Text("整理设备上这个空间会回到备份时的样子。备份之后被撤回或移除的素材，会按这台 Mac 的记录再清除一次；之后新共享的内容需要重新共享。")
        }
      }
    }
  }

  // MARK: - Quotas

  @ViewBuilder private var quotasSection: some View {
    if !team.quotas.isEmpty {
      Section("存储配额") {
        ForEach(Array(team.quotas.enumerated()), id: \.offset) { _, quota in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text("「\(quota.name)」")
              Spacer()
              Text(quota.usage.text).font(.caption)
            }
            if let fraction = quota.usage.fraction { ProgressView(value: fraction) }
            ForEach(Array(quota.members.enumerated()), id: \.offset) { _, member in
              Text("\(member.0)：\(SpaceUsage.megabytes(member.1))").font(.caption).foregroundStyle(
                .secondary)
            }
          }
        }
      }
    }
  }

  // MARK: - Audit

  @ViewBuilder private var auditSection: some View {
    if !team.audit.isEmpty {
      Section("审计记录") {
        Text("谁在什么时候做了什么：只有编号和动作，没有内容。").font(.caption).foregroundStyle(.secondary)
        ForEach(Array(team.audit.prefix(60).enumerated()), id: \.offset) { _, line in
          HStack(alignment: .top) {
            Text(
              SpaceTime.date(line.at)?.formatted(date: .abbreviated, time: .shortened) ?? line.at
            )
            .font(.caption.monospaced()).frame(width: 150, alignment: .leading)
            Text(line.text).font(.caption)
          }
        }
      }
    }
  }
}
