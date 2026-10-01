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
    SpaceSheetFrame(title: "素材和权限", actions: actions) {
      if let space {
        Text(rulesLine(space)).font(.zhiji(12)).foregroundStyle(palette.secondary)
      }
      ForEach(info?.items ?? []) { row in
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            Text(row.kindLabel).font(.zhiji(11))
              .padding(.horizontal, 6).frame(height: 18)
              .background(row.isMine ? palette.quietFill : palette.mateFill, in: Capsule())
            Text(row.title).font(.zhiji(13, .semibold)).lineLimit(1)
            Spacer()
            Text(row.isMine ? "你共享的" : "\(row.contributor) 共享的")
              .font(.zhiji(11)).foregroundStyle(row.isMine ? palette.secondary : palette.mateInk)
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
              Button(state.playingItem == row.itemID ? "停止" : "听这段原音") {
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
        Text("这件事在空间里还没有素材。").font(.zhiji(12)).foregroundStyle(palette.secondary)
      }
    }
  }

  private func rulesLine(_ space: SpaceLocalState) -> String {
    let withdraw =
      space.policy.withdrawWindowHours.map { "共享后 \($0) 小时内可以撤回，之后删除会变成下架申请" }
      ?? "共享的人随时可以撤回或删除"
    return "\(space.ownerKind.title)：\(withdraw)。别人的素材你不能删，可以只对自己隐藏，或因隐私申请下架。你是\(space.role.title)。"
  }

  @ViewBuilder
  private func confirmation(
    _ row: SpaceItemRow, _ action: SpaceRules.ItemAction, space: SpaceLocalState?
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      switch action {
      case .delete:
        Text("删除这条素材？").font(.zhiji(13, .semibold))
        Text(
          row.windowNote == nil && space?.policy.withdrawWindowHours != nil
            ? "已经过了撤回期限：会向维护者提出下架申请，他们同意后才会从空间里移除。你自己的空间里它还在。"
            : "它会从空间里消失，成员的 Mac 也会删掉它的副本；你自己的空间里它还在。"
        )
        .font(.zhiji(12)).foregroundStyle(palette.secondary)
      case .requestPrivacyTakedown:
        Text("因隐私申请下架").font(.zhiji(13, .semibold))
        Text(
          "维护者要在 \(space?.policy.takedownWindowHours ?? 72) 小时内处理：可以写明理由不同意；没人处理会到期自动下架。理由只给维护者看。"
        )
        .font(.zhiji(12)).foregroundStyle(palette.secondary)
        TextField("理由（可不填）", text: $reason).textFieldStyle(.roundedBorder)
      default:
        Text("移除这条素材？").font(.zhiji(13, .semibold))
        Text("它会从空间里移除并清除，署名留在记录里。共享的人自己的空间里它还在。")
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
    .background(palette.mateFill, in: RoundedRectangle(cornerRadius: 8))
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
        Text("维护者和管理员处理这里的提议和下架申请；你可以看到自己提过的。")
          .font(.zhiji(12)).foregroundStyle(palette.secondary)
      }
      SpaceSection(title: "成员的提议") {
        let proposals = state.proposals[spaceID]?.proposals ?? []
        if proposals.isEmpty { empty }
        ForEach(proposals, id: \.proposalID) { proposal in
          let local = space?.proposals[proposal.proposalID]
          VStack(alignment: .leading, spacing: 6) {
            Text(proposalLine(proposal, local: local, titles: titles)).font(.zhiji(13))
            Text("\(space?.name(of: proposal.author) ?? "成员") 提的").font(.zhiji(11))
              .foregroundStyle(palette.secondary)
            if maintainer {
              HStack {
                Button("采纳") { actions.resolveProposal(spaceID, proposal.proposalID, true) }
                  .buttonStyle(ZhijiCapsuleButtonStyle(prominent: true))
                Button("不采纳") { actions.resolveProposal(spaceID, proposal.proposalID, false) }
                  .buttonStyle(ZhijiCapsuleButtonStyle())
              }
            }
          }
          .padding(10)
          .background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
        }
      }
      SpaceSection(title: "整理设备的提议") {
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
      SpaceSection(title: "下架申请") {
        let takedowns = state.takedowns[spaceID] ?? []
        if takedowns.isEmpty { empty }
        ForEach(takedowns, id: \.takedownID) { takedown in
          let item = space?.items[takedown.itemID.lowercased()]
          let reason = space?.takedowns[takedown.takedownID]?.reason
          VStack(alignment: .leading, spacing: 6) {
            Text(
              (takedown.kind == "privacy" ? "因隐私申请下架：" : "共享的人想删除：")
                + (item?.fields?.title ?? "一条素材")
            )
            .font(.zhiji(13))
            Text(
              [
                "\(space?.name(of: takedown.requester) ?? "成员") 提出",
                reason.map { "理由：\($0)" },
                takedown.dueAt.flatMap(SpaceTime.date).map {
                  "须在 \(MemoryDateText.day($0, calendar: .current, now: Date())) \(MemoryDateText.time($0, calendar: .current)) 前处理，否则自动下架"
                },
              ].compactMap { $0 }.joined(separator: " · ")
            )
            .font(.zhiji(11)).foregroundStyle(palette.secondary)
            if maintainer {
              HStack {
                Button("同意下架") { actions.resolveTakedown(spaceID, takedown.takedownID, true) }
                  .buttonStyle(ZhijiCapsuleButtonStyle(prominent: true))
                if takedown.kind != "privacy" {
                  Button("不同意") { actions.resolveTakedown(spaceID, takedown.takedownID, false) }
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
                    "不同意的理由（申请人会看到）",
                    text: Binding(
                      get: { rejectReasons[takedown.takedownID] ?? "" },
                      set: { rejectReasons[takedown.takedownID] = $0 })
                  )
                  .textFieldStyle(.roundedBorder)
                  Button("不同意") {
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
    Text("没有。").font(.zhiji(12)).foregroundStyle(palette.secondary)
  }

  private func proposalLine(
    _ proposal: SpaceProposalRecord, local: SpaceProposal?, titles: [String: String]
  ) -> String {
    let matters = proposal.targets?["matter_ids"]?.array?.compactMap(\.string) ?? []
    let names = matters.map { titles[$0].map { "「\($0)」" } ?? "一件事" }
    let detail = local?.details
    switch proposal.kind {
    case "rename":
      return "把\(names.first ?? "这件事")改名为「\(detail?["title"]?.string ?? "…")」"
    case "merge":
      return "把\(names.joined(separator: "和"))合成一件事"
    case "split":
      return "把\(names.first ?? "这件事")拆开" + (detail?["note"]?.string.map { "：\($0)" } ?? "")
    case "move_to_rope":
      return "把\(names.first ?? "这件事")移到另一根绳上"
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
      SpaceNote(text: "记录里只有谁、在什么时候、做了什么和数量；没有任何内容，管理员也看不到素材本身。")
      let records = (state.audit[spaceID] ?? []).reversed()
      if records.isEmpty {
        Text("还没有记录。").font(.zhiji(12)).foregroundStyle(palette.secondary)
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
          Text(record.actorMember.map { space?.name(of: $0) ?? "成员" } ?? "整理设备")
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
        "withdrawn": "条撤回", "epoch": "号钥匙", "blobs": "个原件",
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
          ? "你是维护者：修改直接生效，并留在空间记录里。"
          : "提议会交给维护者，他们采纳后才生效。你自己的空间不受影响。"
      )
      .font(.zhiji(12)).foregroundStyle(palette.secondary)
      Picker("", selection: $kind) {
        Text("改名").tag("rename")
        Text("和另一件事合并").tag("merge")
        Text("拆开").tag("split")
        Text("其他").tag("other")
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      switch kind {
      case "rename":
        TextField("新的名字", text: $text).textFieldStyle(.roundedBorder)
      case "merge":
        Picker("和哪件事合并", selection: $other) {
          Text("选一件事").tag(String?.none)
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
