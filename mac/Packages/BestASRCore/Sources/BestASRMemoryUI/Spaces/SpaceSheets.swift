import BestASRMemory
import MindloomSpaces
import SwiftUI

/// The sheet for one `SpaceSheet` (the App presents it with `.sheet(item:)`).
public struct SpaceSheetHost: View {
  let sheet: SpaceSheet
  let state: SpacesScreenState
  let actions: SpacesActions

  public init(sheet: SpaceSheet, state: SpacesScreenState, actions: SpacesActions) {
    self.sheet = sheet
    self.state = state
    self.actions = actions
  }

  public var body: some View {
    ZhijiThemed {
      Group {
        switch sheet {
        case .newSpace: NewSpaceSheet(state: state, actions: actions)
        case .join: JoinSpaceSheet(state: state, actions: actions)
        case .members(let id): SpaceMembersSheet(spaceID: id, state: state, actions: actions)
        case .share: ShareSheet(state: state, actions: actions)
        case .items(let s, let e):
          SpaceItemsSheet(spaceID: s, eventID: e, state: state, actions: actions)
        case .review(let id): SpaceReviewSheet(spaceID: id, state: state, actions: actions)
        case .audit(let id): SpaceAuditSheet(spaceID: id, state: state, actions: actions)
        case .propose(let s, let e):
          SpaceProposeSheet(spaceID: s, eventID: e, state: state, actions: actions)
        }
      }
      .frame(minWidth: 520, idealWidth: 560, minHeight: 360, idealHeight: 560)
    }
  }
}

/// A sheet's frame: title, close, scrolling content.
struct SpaceSheetFrame<Content: View>: View {
  @Environment(\.zhiji) private var palette
  let title: String
  let actions: SpacesActions
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(title).font(.zhiji(16, .semibold)).accessibilityAddTraits(.isHeader)
        Spacer()
        Button {
          actions.present(nil)
        } label: {
          Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            .frame(width: 26, height: 26)
            .background(palette.quietFill, in: Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("关闭")
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 14)
      Divider()
      ZhijiScroll {
        VStack(alignment: .leading, spacing: 18) { content }
          .padding(20)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .background(palette.bg)
    .foregroundStyle(palette.label)
  }
}

struct SpaceSection<Content: View>: View {
  @Environment(\.zhiji) private var palette
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.zhiji(13, .semibold)).foregroundStyle(palette.secondary)
      content
    }
  }
}

struct SpaceNote: View {
  @Environment(\.zhiji) private var palette
  let text: String

  var body: some View {
    Text(text).font(.zhiji(12)).foregroundStyle(palette.secondary)
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(palette.quietFill, in: RoundedRectangle(cornerRadius: 8))
  }
}

// MARK: - New space

struct NewSpaceSheet: View {
  @Environment(\.zhiji) private var palette
  let state: SpacesScreenState
  let actions: SpacesActions
  @State private var draft = SpaceDraft()
  @State private var error: String?

  var body: some View {
    SpaceSheetFrame(title: SpaceWords.newSpace, actions: actions) {
      SpaceSection(title: "空间名字") {
        TextField("比如：SkillKnit 论文组", text: $draft.name)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("bestASR.spaces.newName")
        if let error { Text(error).font(.zhiji(12)).foregroundStyle(.red) }
      }
      SpaceSection(title: "谁拥有它") {
        Picker("", selection: $draft.owner) {
          Text("我（小组空间）").tag(SpaceOwnerKind.person)
          Text("实验室（组织空间）").tag(SpaceOwnerKind.org)
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        Text(
          draft.owner == .org
            ? "像 GitHub 的组织仓库：共享进来的内容是实验室的资产。贡献者 \(draft.withdrawWindowHours) 小时内可以撤回，之后只能申请下架；成员离开后，他共享的内容留在空间里，署名不变。"
              + (state.orgAdmin ? "" : "会先以你为第一位管理员建一个组织；建议之后再加一位管理员。")
            : "像共享相册：谁共享的谁随时可以撤回或删除；你作为主人可以移除任何内容。成员离开时可以选择带走自己共享的内容。"
        )
        .font(.zhiji(12)).foregroundStyle(palette.secondary)
      }
      SpaceSection(title: "放在哪台整理设备") {
        Text("\(state.hostLabel)（这台 Mac 已经连上它）。空间里的整理在它上面进行，内容在那里只以密文存放。")
          .font(.zhiji(12)).foregroundStyle(palette.secondary)
      }
      SpaceSection(title: "空间设置") {
        Toggle("允许成员把素材存一份到自己的空间", isOn: $draft.forksAllowed)
        Toggle("只留文字（截图、文件、录音片段的原件留在各自的 Mac 上）", isOn: $draft.textOnly)
        if draft.owner == .person {
          Toggle("成员离开时，他共享的内容留在空间里", isOn: $draft.keepOnLeave)
        } else {
          Stepper(
            "撤回期限：\(draft.withdrawWindowHours) 小时", value: $draft.withdrawWindowHours, in: 1...720)
        }
      }
      SpaceNote(text: SpaceWords.keysNote)
      HStack {
        Spacer()
        Button("取消") { actions.present(nil) }.buttonStyle(ZhijiCapsuleButtonStyle())
        Button("新建") {
          let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !name.isEmpty else {
            error = "给空间起个名字，成员会在邀请里看到它。"
            return
          }
          guard !state.spaces.contains(where: { $0.name == name }) else {
            error = "已经有一个叫这个名字的空间了，换一个吧。"
            return
          }
          draft.name = name
          actions.createSpace(draft)
        }
        .buttonStyle(ZhijiCapsuleButtonStyle(prominent: true))
        .disabled(state.busy || !state.linkReady)
        .accessibilityIdentifier("bestASR.spaces.create")
      }
      if !state.linkReady {
        Text(SpaceWords.linkOff).font(.zhiji(12)).foregroundStyle(palette.secondary)
      }
    }
  }
}

// MARK: - Join

struct JoinSpaceSheet: View {
  @Environment(\.zhiji) private var palette
  let state: SpacesScreenState
  let actions: SpacesActions
  @State private var code = ""
  @State private var name = ""

  var body: some View {
    SpaceSheetFrame(title: SpaceWords.joinSpace, actions: actions) {
      SpaceSection(title: "邀请码") {
        TextEditor(text: $code)
          .font(.system(size: 11, design: .monospaced))
          .frame(height: 70)
          .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.separator))
          .onChange(of: code) { _, value in actions.readInvite(value) }
          .accessibilityLabel("邀请码")
          .accessibilityIdentifier("bestASR.spaces.joinCode")
        Text("把对方 Mac 上「邀请和成员」里的邀请码粘贴到这里（或扫二维码得到的那串文字）。")
          .font(.zhiji(12)).foregroundStyle(palette.secondary)
        if let error = state.joinError, !code.isEmpty {
          Text(error).font(.zhiji(12)).foregroundStyle(.red)
        }
      }
      if let preview = state.joinPreview {
        SpaceSection(title: "要加入的空间") {
          VStack(alignment: .leading, spacing: 4) {
            Text(preview.spaceName).font(.zhiji(14, .semibold))
            Text(
              "角色：\(SpaceRole(rawValue: preview.role ?? "write")?.title ?? "贡献") · 整理设备：\(preview.spark.host)"
                + (preview.expiry.map {
                  " · \(MemoryDateText.day($0, calendar: .current, now: Date())) 前有效"
                } ?? "")
            )
            .font(.zhiji(12)).foregroundStyle(palette.secondary)
            Text("主机指纹已固定在邀请里：连到别的机器会被拒绝。")
              .font(.zhiji(12)).foregroundStyle(palette.secondary)
          }
        }
        SpaceSection(title: "你在这个空间里的名字") {
          TextField("比如：韩策", text: $name).textFieldStyle(.roundedBorder)
          Text("名字加密后只交给发邀请的人看；同意之后，空间里的成员才看得到。")
            .font(.zhiji(12)).foregroundStyle(palette.secondary)
        }
        SpaceNote(text: "发送后，请把这串指纹念给对方核对：\(state.myFingerprint)。对方同意后，空间的钥匙才会发到这台 Mac。")
        HStack {
          Spacer()
          Button("发送申请") {
            actions.join(code, name.trimmingCharacters(in: .whitespacesAndNewlines))
          }
          .buttonStyle(ZhijiCapsuleButtonStyle(prominent: true))
          .disabled(
            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.busy
              || !state.linkReady
          )
          .accessibilityIdentifier("bestASR.spaces.sendJoin")
        }
      }
      if !state.linkReady {
        Text(SpaceWords.linkOff).font(.zhiji(12)).foregroundStyle(palette.secondary)
      }
    }
  }
}

// MARK: - Members, invites, settings

struct SpaceMembersSheet: View {
  @Environment(\.zhiji) private var palette
  let spaceID: String
  let state: SpacesScreenState
  let actions: SpacesActions
  @State private var inviteRole: SpaceRole = .write
  @State private var confirm: String?
  @State private var takeContributions = false
  @State private var approveRoles: [String: SpaceRole] = [:]

  var body: some View {
    if let space = state.space(spaceID) {
      SpaceSheetFrame(title: "\(space.name) · 邀请和成员", actions: actions) {
        Text("放在\(state.hostLabel) · \(space.ownerKind.title) · 你是\(space.role.title)")
          .font(.zhiji(12)).foregroundStyle(palette.secondary)
        if space.can("invite") { inviteSection(space) }
        if space.can("approve_joins") { requests(space) }
        members(space)
        settings(space)
      }
    }
  }

  private func inviteSection(_ space: SpaceLocalState) -> some View {
    SpaceSection(title: "邀请成员") {
      HStack {
        Picker("角色", selection: $inviteRole) {
          ForEach([SpaceRole.read, .write, .maintain, .admin], id: \.self) {
            Text($0.title).tag($0)
          }
        }
        .frame(width: 160)
        Button("生成邀请") { actions.makeInvite(space.spaceID, inviteRole) }
          .buttonStyle(ZhijiCapsuleButtonStyle(prominent: true))
          .disabled(state.busy || space.archived || !state.linkReady)
          .accessibilityIdentifier("bestASR.spaces.invite")
      }
      if let invite = state.invite, invite.spaceID == space.spaceID {
        HStack(alignment: .top, spacing: 16) {
          if let qr = invite.qr {
            Image(nsImage: qr).interpolation(.none).resizable()
              .frame(width: 132, height: 132)
              .accessibilityLabel("邀请二维码")
          }
          VStack(alignment: .leading, spacing: 8) {
            Text("在对方的 Mac 上扫这个码，或者粘贴邀请码：").font(.zhiji(12))
            Text(invite.code).font(.system(size: 10, design: .monospaced)).lineLimit(3)
              .truncationMode(.middle).textSelection(.enabled)
            Button("复制邀请码") { actions.copy(invite.code) }
              .buttonStyle(ZhijiCapsuleButtonStyle())
            Text(
              "\(invite.role.title)角色，一次有效，\(MemoryDateText.day(invite.expires, calendar: .current, now: Date())) 前有效。"
            )
            .font(.zhiji(12)).foregroundStyle(palette.secondary)
          }
        }
      }
      SpaceNote(text: SpaceWords.keysNote)
    }
  }

  private func requests(_ space: SpaceLocalState) -> some View {
    let pending = state.joinRequests[space.spaceID] ?? []
    return SpaceSection(title: "等你同意 · \(pending.count)") {
      if pending.isEmpty {
        Text("没有待处理的申请。").font(.zhiji(12)).foregroundStyle(palette.secondary)
      }
      ForEach(pending) { request in
        VStack(alignment: .leading, spacing: 6) {
          Text(request.displayName ?? "（名字只给发邀请的人看）").font(.zhiji(14, .semibold))
          Text("请和对方核对指纹：\(request.fingerprint)")
            .font(.system(size: 12, design: .monospaced)).foregroundStyle(palette.secondary)
          if let warning = request.warning {
            Text(warning).font(.zhiji(12, .semibold)).foregroundStyle(palette.mateInk)
          }
          HStack {
            Picker(
              "角色",
              selection: Binding(
                get: { approveRoles[request.requestID] ?? request.role ?? .write },
                set: { approveRoles[request.requestID] = $0 })
            ) {
              ForEach([SpaceRole.read, .write, .maintain, .admin], id: \.self) {
                Text($0.title).tag($0)
              }
            }
            .frame(width: 160)
            Button("同意") {
              actions.approve(
                space.spaceID, request, approveRoles[request.requestID] ?? request.role ?? .write)
            }
            .buttonStyle(ZhijiCapsuleButtonStyle(prominent: true))
            .disabled(request.blocked)
            .accessibilityIdentifier("bestASR.spaces.approve")
            Button("拒绝") { actions.reject(space.spaceID, request.requestID) }
              .buttonStyle(ZhijiCapsuleButtonStyle())
          }
        }
        .padding(10)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
      }
    }
  }

  private func members(_ space: SpaceLocalState) -> some View {
    let people = space.members.filter(\.isActive)
    return SpaceSection(title: "成员 · \(people.count)") {
      ForEach(people) { member in
        let isMe = member.memberID == space.memberID
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(space.name(of: member.memberID) + (isMe ? "（你）" : ""))
                .font(.zhiji(13, .semibold))
              Text(
                [
                  member.owner ? "主人" : nil, member.orgAdmin ? "组织管理员" : nil,
                  member.outside ? "外部合作者" : nil,
                ].compactMap { $0 }.joined(separator: " · ")
              )
              .font(.zhiji(11)).foregroundStyle(palette.secondary)
            }
            Spacer()
            if space.can("set_roles"), !member.owner, !member.orgAdmin, !isMe {
              Picker(
                "",
                selection: Binding(
                  get: { member.role }, set: { actions.setRole(space.spaceID, member.memberID, $0) }
                )
              ) {
                ForEach([SpaceRole.read, .write, .maintain, .admin], id: \.self) {
                  Text($0.title).tag($0)
                }
              }
              .labelsHidden().frame(width: 100)
            } else {
              Text(member.role.title).font(.zhiji(12)).foregroundStyle(palette.secondary)
            }
            if isMe, !member.owner {
              Button("离开空间") { confirm = member.memberID }.buttonStyle(ZhijiCapsuleButtonStyle())
            } else if !isMe, space.can("remove_members"), !member.owner {
              Button("移除") { confirm = member.memberID }.buttonStyle(ZhijiCapsuleButtonStyle())
            }
          }
          if confirm == member.memberID { confirmation(space, member: member, isMe: isMe) }
        }
        .padding(.vertical, 4)
      }
    }
  }

  private func confirmation(_ space: SpaceLocalState, member: SpaceMember, isMe: Bool) -> some View
  {
    let keeps = space.policy.onLeave == "keep"
    return VStack(alignment: .leading, spacing: 8) {
      if isMe {
        Text("离开「\(space.name)」？").font(.zhiji(13, .semibold))
        Text(
          "这台 Mac 上这个空间的钥匙和内容会被删掉，存过的副本也会删除。"
            + (keeps ? "按空间设置，你共享的内容留在空间里，署名不变。" : "你可以选择带走自己共享的内容。")
            + "你自己的空间里一条也不少。"
        )
        .font(.zhiji(12)).foregroundStyle(palette.secondary)
        if !keeps { Toggle("带走我共享的内容", isOn: $takeContributions) }
      } else {
        Text("移除 \(space.name(of: member.memberID))？").font(.zhiji(13, .semibold))
        Text(
          "空间会换一把新钥匙重新上锁，他的 Mac 就再也打不开之后的内容；他共享过的内容留在空间里，署名不变。"
        )
        .font(.zhiji(12)).foregroundStyle(palette.secondary)
      }
      HStack {
        Button(isMe ? "离开空间" : "移除") {
          confirm = nil
          if isMe {
            actions.leave(space.spaceID, takeContributions)
          } else {
            actions.removeMember(space.spaceID, member.memberID)
          }
        }
        .buttonStyle(ZhijiCapsuleButtonStyle(prominent: true))
        Button("取消") { confirm = nil }.buttonStyle(ZhijiCapsuleButtonStyle())
      }
    }
    .padding(10)
    .background(palette.mateFill, in: RoundedRectangle(cornerRadius: 8))
  }

  private func settings(_ space: SpaceLocalState) -> some View {
    let admin = space.can("policy")
    return SpaceSection(title: "空间设置") {
      VStack(alignment: .leading, spacing: 8) {
        row(
          "撤回",
          space.policy.withdrawWindowHours.map { "共享后 \($0) 小时内可以撤回，之后只能申请下架" } ?? "共享的人随时可以撤回")
        row("隐私下架", "因隐私申请的下架，维护者必须在 \(space.policy.takedownWindowHours) 小时内处理，否则到期自动下架")
        row(
          "原件", space.policy.originalsForMembers ? "成员可以查看原件（只有成员的 Mac 能解开）" : "只留文字，原件只在主人的 Mac 上")
        row("存一份", space.policy.forksAllowed ? "允许；失去访问权时副本会被删除" : "不允许")
        row("成员离开", space.policy.onLeave == "keep" ? "他共享的内容留在空间里" : "由他决定留下还是带走")
        if admin {
          HStack(spacing: 8) {
            if space.ownerKind == .person {
              Button(space.policy.forksAllowed ? "不允许存副本" : "允许存副本") {
                actions.setPolicy(
                  space.spaceID, ["forks_allowed": .bool(!space.policy.forksAllowed)])
              }
              .buttonStyle(ZhijiCapsuleButtonStyle())
            }
            Button(space.policy.originalsForMembers ? "改成只留文字" : "允许成员查看原件") {
              actions.setPolicy(
                space.spaceID,
                ["originals": .string(space.policy.originalsForMembers ? "text_only" : "members")])
            }
            .buttonStyle(ZhijiCapsuleButtonStyle())
            Button(space.archived ? "取消归档" : "归档（只读）") {
              actions.archive(space.spaceID, !space.archived)
            }
            .buttonStyle(ZhijiCapsuleButtonStyle())
          }
        }
        Text("角色：管理能邀请、移除成员、改设置；维护能移除内容、处理下架和提议；贡献能共享和撤回自己的内容；只读只能查看。")
          .font(.zhiji(12)).foregroundStyle(palette.secondary)
      }
    }
  }

  private func row(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(title).font(.zhiji(12, .semibold)).frame(width: 64, alignment: .leading)
      Text(value).font(.zhiji(12)).foregroundStyle(palette.secondary)
    }
  }
}
