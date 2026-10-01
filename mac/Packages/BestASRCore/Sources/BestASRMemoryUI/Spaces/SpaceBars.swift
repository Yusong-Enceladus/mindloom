import MindloomSpaces
import SwiftUI

extension ZhijiPalette {
  /// The second tone: others' items in a shared thread.
  public var mate: Color { isDark ? .hex(0xD77BB4) : .hex(0xB04E8C) }
  public var mateFill: Color { isDark ? .hex(0x3A2232) : .hex(0xF7E8F1) }
  public var mateInk: Color { isDark ? .hex(0xF0B6D9) : .hex(0x83306A) }
}

/// Above Home: 我的 | each space | 全部 | ＋, and in a space the line that
/// says where it lives, who is in it and what needs the user.
public struct SpaceSwitcherBar: View {
  @Environment(\.zhiji) private var palette
  @Environment(\.zhijiSnapshot) private var snapshot
  let state: SpacesScreenState
  let actions: SpacesActions

  public init(state: SpacesScreenState, actions: SpacesActions) {
    self.state = state
    self.actions = actions
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        switcher
        if snapshot {
          // AppKit menus do not draw into a still image.
          Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
            .frame(width: 26, height: 26)
            .background(palette.quietFill, in: RoundedRectangle(cornerRadius: 8))
        } else {
          Menu {
            Button(SpaceWords.newSpace) { actions.present(.newSpace) }
            Button(SpaceWords.joinSpace) { actions.present(.join) }
          } label: {
            Image(systemName: "plus")
              .font(.system(size: 12, weight: .semibold))
              .frame(width: 26, height: 26)
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .accessibilityLabel(SpaceWords.newSpace)
          .accessibilityIdentifier("bestASR.spaces.add")
        }
        Spacer(minLength: 0)
      }
      bar
      ForEach(state.pendingSpaces) { pending in
        pendingRow(pending)
      }
      if let status = state.status, !status.isEmpty {
        Text(status).font(.zhiji(12)).foregroundStyle(palette.secondary)
      }
    }
  }

  private var options: [(SpaceScope, String)] {
    [(.mine, SpaceWords.mine)] + state.activeSpaces.map { (.space($0.spaceID), $0.name) }
      + (state.activeSpaces.isEmpty ? [] : [(.all, SpaceWords.all)])
  }

  private var switcher: some View {
    ZhijiSegmented(
      options: options,
      selection: Binding(get: { state.scope }, set: { actions.setScope($0) }),
      height: 26, fontSize: 13, horizontalPadding: 12
    )
    .accessibilityLabel("空间")
    .accessibilityIdentifier("bestASR.spaces.switcher")
  }

  @ViewBuilder
  private var bar: some View {
    switch state.scope {
    case .mine:
      if !state.linkReady, !state.activeSpaces.isEmpty {
        note(SpaceWords.linkOff)
      }
    case .all:
      HStack(spacing: 8) {
        Circle().fill(palette.mate).frame(width: 8, height: 8)
        Text(SpaceWords.allNote).font(.zhiji(12)).foregroundStyle(palette.secondary)
      }
    case .space(let id):
      if let space = state.space(id) { spaceLine(space) }
    }
  }

  /// What the Spark said that the members' signed records contradict.
  static func integrityNote(_ codes: [String]?) -> String? {
    let words: [String: String] = [
      "unknown_device_listed": "它列出了没有成员同意过的设备",
      "spark_epoch_behind": "它报的钥匙比成员签过名的旧",
      "not_member_unsigned": "它说你已不在空间里，却没有给出成员签名的记录",
    ]
    let found = (codes ?? []).compactMap { words[$0] }
    guard !found.isEmpty else { return nil }
    return "整理设备的回答和成员签过名的记录对不上（\(found.joined(separator: "；"))）。这台 Mac 只认签名的记录。"
  }

  private func spaceLine(_ space: SpaceLocalState) -> some View {
    let people = space.activeMembers
    let mine = state.sharedMatters.values.filter { $0.contains(space.spaceID) }.count
    let requests = state.joinRequests[space.spaceID]?.count ?? 0
    let review =
      (state.proposals[space.spaceID]?.proposals.count ?? 0)
      + (state.proposals[space.spaceID]?.organizer.count ?? 0)
      + (state.takedowns[space.spaceID]?.count ?? 0)
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: space.ownerKind == .org ? "building.2" : "person.2")
          .font(.system(size: 12)).foregroundStyle(palette.mate)
        Text(space.name).font(.zhiji(13, .semibold))
        Text(
          "\(space.ownerKind.title) · 放在\(state.hostLabel) · \(people.count) 位成员 · 你共享了 \(mine) 件事"
            + (space.archived ? " · 已归档（只读）" : "")
        )
        .font(.zhiji(12)).foregroundStyle(palette.secondary)
      }
      HStack(spacing: 8) {
        Button(requests > 0 ? "邀请和成员 · \(requests) 个申请" : "邀请和成员") {
          actions.present(.members(spaceID: space.spaceID))
        }
        .buttonStyle(ZhijiCapsuleButtonStyle(prominent: requests > 0))
        .accessibilityIdentifier("bestASR.spaces.members")
        if space.role >= .maintain || review > 0 {
          Button(review > 0 ? "待处理 · \(review)" : "待处理") {
            actions.present(.review(spaceID: space.spaceID))
          }
          .buttonStyle(ZhijiCapsuleButtonStyle(prominent: review > 0 && space.role >= .maintain))
        }
        if space.role == .admin {
          Button("记录") { actions.present(.audit(spaceID: space.spaceID)) }
            .buttonStyle(ZhijiCapsuleButtonStyle())
        }
        if space.rotationPending {
          Text(space.role == .admin ? "有成员离开，正在换钥匙…" : "有成员离开，等管理员换钥匙后才能共享")
            .font(.zhiji(12)).foregroundStyle(palette.secondary)
        }
      }
      if let note = Self.integrityNote(space.integrityWarnings) {
        Text(note).font(.zhiji(12, .semibold)).foregroundStyle(palette.mateInk)
      }
      if !state.linkReady { note(SpaceWords.linkOff) }
    }
    .padding(12)
    .background(palette.mateFill.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
  }

  private func pendingRow(_ pending: SpaceLocalState) -> some View {
    HStack(spacing: 8) {
      Image(systemName: pending.membership == .rejected ? "xmark.circle" : "hourglass")
        .foregroundStyle(palette.secondary)
      Text(
        pending.membership == .rejected
          ? "「\(pending.name)」的管理员没有同意你的申请"
          : "已申请加入「\(pending.name)」，等管理员同意。请对方核对你的指纹 \(state.myFingerprint)"
      )
      .font(.zhiji(12)).foregroundStyle(palette.secondary)
      Button(pending.membership == .rejected ? "知道了" : "取消申请") {
        actions.dropJoin(pending.spaceID)
      }
      .buttonStyle(ZhijiCapsuleButtonStyle())
    }
  }

  private func note(_ text: String) -> some View {
    Text(text).font(.zhiji(12)).foregroundStyle(palette.secondary)
  }
}

/// Under a matter page: in 我的 the shared version's badge and 共享这件事…;
/// inside a space whose items it holds, the items' rights and proposals.
public struct SpaceMatterBar: View {
  @Environment(\.zhiji) private var palette
  let eventID: String
  let state: SpacesScreenState
  let actions: SpacesActions

  public init(eventID: String, state: SpacesScreenState, actions: SpacesActions) {
    self.eventID = eventID
    self.state = state
    self.actions = actions
  }

  public static func shows(eventID: String, state: SpacesScreenState) -> Bool {
    switch state.scope {
    case .mine: !state.activeSpaces.isEmpty || state.badges[eventID] != nil
    case .space, .all: state.matters[eventID] != nil
    }
  }

  public var body: some View {
    HStack(spacing: 10) {
      content
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 10)
    .background(.bar)
    .overlay(alignment: .top) { Rectangle().fill(palette.hairline).frame(height: 1) }
  }

  @ViewBuilder
  private var content: some View {
    if let info = state.matters[eventID] {
      Image(systemName: "person.2").foregroundStyle(palette.mate)
      Text(
        "\(info.spaceName)版" + (info.contributionLine.map { " · \($0)" } ?? "")
          + " · 在整理设备上合起来整理"
      )
      .font(.zhiji(12)).foregroundStyle(palette.secondary).lineLimit(1)
      Button("素材和权限…") { actions.present(.items(spaceID: info.spaceID, eventID: eventID)) }
        .buttonStyle(ZhijiCapsuleButtonStyle())
      if info.canHandover {
        Button("交接…") { actions.present(.handover(spaceID: info.spaceID, eventID: eventID)) }
          .buttonStyle(ZhijiCapsuleButtonStyle())
          .accessibilityIdentifier("bestASR.spaces.handover")
      }
      if info.canPropose || info.canEdit {
        Button(info.canEdit ? "修改…" : "提议修改…") {
          actions.present(.propose(spaceID: info.spaceID, eventID: eventID))
        }
        .buttonStyle(ZhijiCapsuleButtonStyle())
      }
    } else {
      if let badge = state.badges[eventID] {
        Button {
          actions.openSpaceMatter(badge.spaceID, badge.spaceEventID)
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "person.2.fill")
            Text(badge.text).font(.zhiji(12, .semibold))
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
          }
          .foregroundStyle(palette.mateInk)
          .padding(.horizontal, 10)
          .frame(height: 26)
          .background(palette.mateFill, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bestASR.spaces.badge")
      }
      if let shared = state.sharedMatters[eventID], !shared.isEmpty {
        Text("已共享到 " + shared.compactMap { state.space($0)?.name }.joined(separator: "、"))
          .font(.zhiji(12)).foregroundStyle(palette.secondary)
      }
      Button("共享这件事…") { actions.present(.share(eventID: eventID)) }
        .buttonStyle(ZhijiCapsuleButtonStyle())
        .accessibilityIdentifier("bestASR.spaces.share")
    }
  }
}
