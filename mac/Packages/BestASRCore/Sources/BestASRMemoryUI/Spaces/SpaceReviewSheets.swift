import BestASRMemory
import MindloomSpaces
import SwiftUI

/// 素材和权限: the matter's shared items with what this member may do with
/// each (by role and space type): 撤回 / 删除… / 隐私下架… / 移除 / 隐藏 /
/// 存一份, and opening an original.
struct SpaceItemsSheet: View {
  @Environment(\.zhiji) private var palette
  let spaceID: String
  let eventID: String
  let state: SpacesScreenState
  let actions: SpacesActions
  @State private var confirm: (item: String, action: SpaceRules.ItemAction)?
  @State private var reason = ""

  var body: some View {
    let info = state.matters[eventID]
    let space = state.space(spaceID)
    SpaceSheetFrame(title: "内容和权限", actions: actions) {
      if let space {
        Text(rulesLine(space)).font(.zhiji(12)).foregroundStyle(palette.secondary)
      }
      ForEach(info?.items ?? []) { row in
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            Text(row.kindLabel).font(.zhiji(11))
              .padding(.horizontal, 6).frame(height: 18)
              .background(row.isMine ? palette.quietFill : palette.quietFill, in: Capsule())
            Text(row.title).font(.zhiji(13, .semibold)).lineLimit(1)
            Spacer()
            Text(row.isMine ? "你共享的" : "\(row.contributor) 共享的")
              .font(.zhiji(11)).foregroundStyle(row.isMine ? palette.secondary : palette.label)
          }
          if !row.preview.isEmpty {
            Text(row.preview).font(.zhiji(12)).foregroundStyle(palette.secondary).lineLimit(2)
          }
          if let note = row.windowNote {
            Text(note).font(.zhiji(11)).foregroundStyle(palette.secondary)
          }
          if let note = row.snapshotNote {
            Text(note).font(.zhiji(11)).foregroundStyle(palette.secondary)
          }
          HStack(spacing: 6) {
            if let audio = row.audio {
              Button(state.playingItem == row.itemID ? "停止" : "播放此段录音") {
                actions.playAudio(spaceID, row.itemID, audio)
              }
              .buttonStyle(ZhijiCapsuleButtonStyle())
              .accessibilityIdentifier("bestASR.spaces.playAudio")
            }
            ForEach(row.originals, id: \.blobID) { blob in
              Button("打开原件") { actions.openOriginal(spaceID, row.itemID, blob) }
                .buttonStyle(ZhijiCapsuleButtonStyle())
            }
            ForEach(row.actions, id: \.self) { action in
              Button(SpaceWords.action(action)) {
                switch action {
                case .delete, .requestPrivacyTakedown, .remove:
                  confirm = (row.itemID, action)
                  reason = ""
                default:
                  actions.itemAction(spaceID, row.itemID, action, nil)
                }
              }
              .buttonStyle(ZhijiCapsuleButtonStyle())
            }
          }
          if let confirm, confirm.item == row.itemID {
            confirmation(row, confirm.action, space: space)
          }
        }
        .padding(10)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
      }
      if info?.items.isEmpty ?? true {
        Text("这件事在空间中尚无内容。").font(.zhiji(12)).foregroundStyle(palette.secondary)
      }
    }
  }

  private func rulesLine(_ space: SpaceLocalState) -> String {
    let withdraw =
      space.policy.withdrawWindowHours.map { "共享后 \($0) 小时内可以撤回，之后删除将提交撤回申请" }
      ?? "共享者可以随时撤回或删除"
    return "\(space.ownerKind.title)：\(withdraw)。你无法删除他人的内容，但可以对自己隐藏，或因隐私申请撤回。你是\(space.role.title)。"
  }

  @ViewBuilder
  private func confirmation(
    _ row: SpaceItemRow, _ action: SpaceRules.ItemAction, space: SpaceLocalState?
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      switch action {
      case .delete:
        Text("删除这条内容？").font(.zhiji(13, .semibold))
        Text(
          row.windowNote == nil && space?.policy.withdrawWindowHours != nil
            ? "已过撤回期限：将向维护者提出撤回申请，维护者同意后从空间中移除。它会保留在你自己的空间中。"
            : "它将从空间中移除，成员 Mac 上的副本也会删除；它会保留在你自己的空间中。"
        )
        .font(.zhiji(12)).foregroundStyle(palette.secondary)
      case .requestPrivacyTakedown:
        Text("因隐私申请撤回").font(.zhiji(13, .semibold))
        Text(
          "维护者要在 \(space?.policy.takedownWindowHours ?? 72) 小时内处理：维护者可以注明理由拒绝；逾期未处理将自动撤回。理由仅维护者可见。"
        )
        .font(.zhiji(12)).foregroundStyle(palette.secondary)
        TextField("理由（可选）", text: $reason).textFieldStyle(.roundedBorder)
      default:
        Text("移除这条内容？").font(.zhiji(13, .semibold))
        Text("它将从空间中移除并清除，署名保留在记录中。它会保留在共享者自己的空间中。")
          .font(.zhiji(12)).foregroundStyle(palette.secondary)
      }
      HStack {
        Button("确定") {
          let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
          actions.itemAction(spaceID, row.itemID, action, text.isEmpty ? nil : text)
          confirm = nil
        }
        .buttonStyle(ZhijiCapsuleButtonStyle(prominent: true))
        Button("取消") { confirm = nil }.buttonStyle(ZhijiCapsuleButtonStyle())
      }
    }
    .padding(10)
    .background(palette.quietFill, in: RoundedRectangle(cornerRadius: 8))
  }
}

/// 待处理 (maintainers): members' proposals, the organizer's own merge and
/// same-person proposals, and takedown requests.
struct SpaceReviewSheet: View {
  @Environment(\.zhiji) private var palette
  let spaceID: String
  let state: SpacesScreenState
  let actions: SpacesActions
  @State private var rejectReasons: [String: String] = [:]

  var body: some View {
    let space = state.space(spaceID)
    let maintainer = (space?.role ?? .read) >= .maintain
    let titles = state.matterTitles[spaceID] ?? [:]
    SpaceSheetFrame(title: "待处理", actions: actions) {
      if !maintainer {
        Text("维护者和管理员在这里处理提议和撤回申请；你可以查看自己提交的内容。")
          .font(.zhiji(12)).foregroundStyle(palette.secondary)
      }
      SpaceSection(title: "成员的提议") {
        let proposals = state.proposals[spaceID]?.proposals ?? []
        if proposals.isEmpty { empty }
        ForEach(proposals, id: \.proposalID) { proposal in
          let local = space?.proposals[proposal.proposalID]
          VStack(alignment: .leading, spacing: 6) {
            Text(proposalLine(proposal, local: local, titles: titles)).font(.zhiji(13))
            Text("\(space?.name(of: proposal.author) ?? "成员") 提出").font(.zhiji(11))
              .foregroundStyle(palette.secondary)
            if maintainer {
              HStack {
                Button("采纳") { actions.resolveProposal(spaceID, proposal.proposalID, true) }
                  .buttonStyle(ZhijiCapsuleButtonStyle(prominent: true))
                Button("拒绝") { actions.resolveProposal(spaceID, proposal.proposalID, false) }
                  .buttonStyle(ZhijiCapsuleButtonStyle())
              }
            }
          }
          .padding(10)
          .background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
        }
      }
      SpaceSection(title: "DGX Spark 的提议") {
        let organizer = state.proposals[spaceID]?.organizer ?? []
        if organizer.isEmpty { empty }
        ForEach(organizer, id: \.proposalID) { proposal in
          VStack(alignment: .leading, spacing: 6) {
            Text(proposal.question?["prompt_zh"]?.string ?? proposal.kind).font(.zhiji(13))
            if maintainer {
              YesNoButtons { yes in actions.answerOrganizer(spaceID, proposal.proposalID, yes) }
            }
          }
          .padding(10)
          .background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
        }
      }
      SpaceSection(title: "撤回申请") {
        let takedowns = state.takedowns[spaceID] ?? []
        if takedowns.isEmpty { empty }
        ForEach(takedowns, id: \.takedownID) { takedown in
          let item = space?.items[takedown.itemID.lowercased()]
          let reason = space?.takedowns[takedown.takedownID]?.reason
          VStack(alignment: .leading, spacing: 6) {
            Text(
              (takedown.kind == "privacy" ? "因隐私申请撤回：" : "共享者请求删除：")
                + (item?.fields?.title ?? "一条内容")
            )
            .font(.zhiji(13))
            Text(
              [
                "\(space?.name(of: takedown.requester) ?? "成员") 提出",
                reason.map { "理由：\($0)" },
                takedown.dueAt.flatMap(SpaceTime.date).map {
                  "须在 \(MemoryDateText.day($0, calendar: .current, now: Date())) \(MemoryDateText.time($0, calendar: .current)) 前处理，逾期将自动撤回"
                },
              ].compactMap { $0 }.joined(separator: " · ")
            )
            .font(.zhiji(11)).foregroundStyle(palette.secondary)
            if maintainer {
              HStack {
                Button("同意撤回") { actions.resolveTakedown(spaceID, takedown.takedownID, true) }
                  .buttonStyle(ZhijiCapsuleButtonStyle(prominent: true))
                if takedown.kind != "privacy" {
                  Button("拒绝") { actions.resolveTakedown(spaceID, takedown.takedownID, false) }
                    .buttonStyle(ZhijiCapsuleButtonStyle())
                }
              }
              // Someone else's privacy takedown on an item: a maintainer may
              // say no, with a reason the requester sees. The contributor's
              // own is always honoured.
              if takedown.kind == "privacy", let item, item.contributor != takedown.requester {
                let reasonText = rejectReasons[takedown.takedownID] ?? ""
                HStack {
                  TextField(
                    "拒绝理由（申请人可见）",
                    text: Binding(
                      get: { rejectReasons[takedown.takedownID] ?? "" },
                      set: { rejectReasons[takedown.takedownID] = $0 })
                  )
                  .textFieldStyle(.roundedBorder)
                  Button("拒绝") {
                    actions.rejectTakedown(
                      spaceID, takedown.takedownID,
                      reasonText.trimmingCharacters(in: .whitespacesAndNewlines))
                  }
                  .buttonStyle(ZhijiCapsuleButtonStyle())
                  .disabled(reasonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
              }
            }
          }
          .padding(10)
          .background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
        }
      }
    }
    .onAppear { actions.refresh(spaceID) }
  }

  private var empty: some View {
    Text("无。").font(.zhiji(12)).foregroundStyle(palette.secondary)
  }

  private func proposalLine(
    _ proposal: SpaceProposalRecord, local: SpaceProposal?, titles: [String: String]
  ) -> String {
    let matters = proposal.targets?["matter_ids"]?.array?.compactMap(\.string) ?? []
    let names = matters.map { titles[$0].map { "“\($0)”" } ?? "一件事" }
    let detail = local?.details
    switch proposal.kind {
    case "rename":
      return "将\(names.first ?? "这件事")重新命名为“\(detail?["title"]?.string ?? "…")”"
    case "merge":
      return "将\(names.joined(separator: "和"))合并为一件事"
    case "split":
      return "将\(names.first ?? "这件事")拆分" + (detail?["note"]?.string.map { "：\($0)" } ?? "")
    case "move_to_rope":
      return "将\(names.first ?? "这件事")移到另一件事中"
    default:
      return detail?["note"]?.string ?? "一项修改"
    }
  }
}

/// 记录 (admins): who did what, when — ids, counts and codes only, never content.
struct SpaceAuditSheet: View {
  @Environment(\.zhiji) private var palette
  let spaceID: String
  let state: SpacesScreenState
  let actions: SpacesActions

  var body: some View {
    let space = state.space(spaceID)
    SpaceSheetFrame(title: "空间记录", actions: actions) {
      SpaceNote(text: "记录包含操作者、时间、操作和数量，不包含内容本身。")
      let records = (state.audit[spaceID] ?? []).reversed()
      if records.isEmpty {
        Text("尚无记录。").font(.zhiji(12)).foregroundStyle(palette.secondary)
      }
      ForEach(Array(records)) { record in
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text(
            SpaceTime.date(record.at).map {
              "\(MemoryDateText.day($0, calendar: .current, now: Date())) \(MemoryDateText.time($0, calendar: .current))"
            } ?? record.at
          )
          .font(.zhiji(11)).monospacedDigit().foregroundStyle(palette.secondary)
          .frame(width: 110, alignment: .leading)
          Text(record.actorMember.map { space?.name(of: $0) ?? "成员" } ?? "DGX Spark")
            .font(.zhiji(12, .semibold)).frame(width: 80, alignment: .leading)
          Text(SpaceWords.audit(record.action) + counts(record.target)).font(.zhiji(12))
          Spacer(minLength: 0)
        }
      }
    }
    .onAppear { actions.refresh(spaceID) }
  }

  private func counts(_ target: SpaceJSON?) -> String {
    guard let fields = target?.object else { return "" }
    let numbers = fields.compactMap { key, value -> String? in
      guard let n = value.int, !key.hasSuffix("_id"), key != "epoch" || n > 1 else { return nil }
      let words = [
        "count": "条", "items": "条", "applied": "项生效", "rejected": "项未生效", "purged": "条清除",
        "withdrawn": "条撤回", "epoch": "号密钥", "blobs": "个原件",
      ]
      return "\(n) \(words[key] ?? key)"
    }
    return numbers.isEmpty ? "" : "（" + numbers.sorted().joined(separator: "，") + "）"
  }
}

/// 提议修改 (contributors) or 修改 (maintainers, applied directly).
struct SpaceProposeSheet: View {
  @Environment(\.zhiji) private var palette
  let spaceID: String
  let eventID: String
  let state: SpacesScreenState
  let actions: SpacesActions
  @State private var kind = "rename"
  @State private var text = ""
  @State private var other: String?

  var body: some View {
    let titles = state.matterTitles[spaceID] ?? [:]
    let maintainer = (state.space(spaceID)?.role ?? .read) >= .maintain
    SpaceSheetFrame(title: maintainer ? "修改共享的事" : "提议修改", actions: actions) {
      Text(
        maintainer
          ? "你是维护者：修改直接生效，并记录在空间记录中。"
          : "提议将提交给维护者，采纳后生效。你自己的空间保持不变。"
      )
      .font(.zhiji(12)).foregroundStyle(palette.secondary)
      Picker("", selection: $kind) {
        Text("重新命名").tag("rename")
        Text("与另一件事合并").tag("merge")
        Text("拆分").tag("split")
        Text("其他").tag("other")
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      switch kind {
      case "rename":
        TextField("新名称", text: $text).textFieldStyle(.roundedBorder)
      case "merge":
        Picker("与哪件事合并", selection: $other) {
          Text("选择一件事").tag(String?.none)
          ForEach(
            titles.sorted(by: { $0.value < $1.value }).filter { $0.key != eventID }, id: \.key
          ) {
            Text($0.value).tag(Optional($0.key))
          }
        }
      default:
        TextField("说明", text: $text).textFieldStyle(.roundedBorder)
      }
      HStack {
        Spacer()
        Button(maintainer ? "修改" : "提交提议") {
          actions.propose(spaceID, eventID, kind, text, other)
        }
        .buttonStyle(ZhijiCapsuleButtonStyle(prominent: true))
        .disabled(
          kind == "merge" ? other == nil : text.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
  }
}
