import MindloomSpaces
import SwiftUI

/// 共享这件事: where to, how much (只这一条 / 这件事 / 整根绳), and the review
/// list — every item or part that would go, private dictations and items
/// with numbers unticked until the user ticks them.
struct ShareSheet: View {
  @Environment(\.zhiji) private var palette
  let state: SpacesScreenState
  let actions: SpacesActions
  @State private var draft: SpaceShareDraft?

  init(state: SpacesScreenState, actions: SpacesActions) {
    self.state = state
    self.actions = actions
    _draft = State(initialValue: state.shareDraft)
  }

  var body: some View {
    SpaceSheetFrame(title: "共享这件事", actions: actions) {
      if let draft = Binding($draft) {
        content(draft)
      } else if state.shareDraft == nil {
        Text("正在列出这件事的素材…").font(.zhiji(13)).foregroundStyle(palette.secondary)
      }
    }
    .onAppear { if draft == nil { draft = state.shareDraft } }
    .onChange(of: state.shareDraft) { _, value in
      if draft?.eventID != value?.eventID { draft = value }
    }
  }

  @ViewBuilder
  private func content(_ draft: Binding<SpaceShareDraft>) -> some View {
    let value = draft.wrappedValue
    Text(value.title).font(.zhiji(15, .semibold))
    if value.destinations.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("你还没有能共享进去的空间").font(.zhiji(14, .semibold))
        Text("先建一个空间（或请管理员把你设为贡献者），再把这件事放进去。")
          .font(.zhiji(12)).foregroundStyle(palette.secondary)
        Button(SpaceWords.newSpace) { actions.present(.newSpace) }
          .buttonStyle(ZhijiCapsuleButtonStyle(prominent: true))
      }
    } else {
      SpaceSection(title: "共享到") {
        ZhijiSegmented(
          options: value.destinations.map { ($0.spaceID, $0.name) },
          selection: Binding(
            get: { draft.wrappedValue.destination ?? value.destinations[0].spaceID },
            set: { draft.wrappedValue.destination = $0 }),
          height: 26, fontSize: 13, horizontalPadding: 12)
        if let space = value.destinations.first(where: {
          $0.spaceID == (value.destination ?? value.destinations[0].spaceID)
        }) {
          Text(
            "成员：" + space.activeMembers.map { space.name(of: $0.memberID) }.joined(separator: "、")
              + "。素材只是加进空间，你自己的空间里一条也不少。"
              + (value.sharedIn[space.spaceID] != nil ? "这件事已经在「\(space.name)」里。" : "")
          )
          .font(.zhiji(12)).foregroundStyle(palette.secondary)
          if !space.policy.originalsForMembers {
            Text("这个空间只留文字：截图、文件和录音片段的原件留在你的 Mac 上。")
              .font(.zhiji(12)).foregroundStyle(palette.secondary)
          }
        }
      }
      SpaceSection(title: "共享多大范围") {
        scaleOption(draft, .item, "只这一条", "挑一条素材放进空间，别的不动。")
        scaleOption(
          draft, .matter(rule: .ask), "这件事（含以后的新素材）",
          "你勾选的素材，加上你起的标题和做过的更正，作为团队整理时的提示。")
        if case .matter(let rule) = value.scale {
          HStack(spacing: 8) {
            Text("以后归进来的新素材").font(.zhiji(12)).foregroundStyle(palette.secondary)
            ZhijiSegmented(
              options: [(.ask, "每次先问我"), (.auto, "自动共享"), (.off, "不跟进")],
              selection: Binding(
                get: { rule }, set: { draft.wrappedValue.scale = .matter(rule: $0) }),
              height: 24, fontSize: 12, horizontalPadding: 10)
          }
          .padding(.leading, 24)
        }
        if let rope = value.rope {
          scaleOption(
            draft, .rope(rule: .ask), "整根绳「\(rope.title)」",
            "绳上现在有 \(rope.matters) 件事；以后放到这根绳上的事也会共享（每次先问你，或自动）。")
        }
      }
      SpaceSection(title: "会共享的素材 · \(value.review.ticked.count)/\(value.review.candidates.count)")
      {
        ForEach(value.review.candidates) { candidate in
          reviewRow(draft, candidate)
        }
        if value.review.candidates.isEmpty {
          Text("这件事里没有可以共享的素材（录音只能按片段共享）。")
            .font(.zhiji(12)).foregroundStyle(palette.secondary)
        }
      }
      SpaceNote(text: SpaceWords.promise)
      HStack {
        if let space = value.destination ?? value.destinations.first?.spaceID,
          value.sharedIn[space] != nil
        {
          Button("停止跟进这件事") { actions.unshare(space, value.eventID) }
            .buttonStyle(ZhijiCapsuleButtonStyle())
        }
        Spacer()
        Button("取消") { actions.present(nil) }.buttonStyle(ZhijiCapsuleButtonStyle())
        Button(shareTitle(value)) { actions.share(draft.wrappedValue) }
          .buttonStyle(ZhijiCapsuleButtonStyle(prominent: true))
          .disabled(selectedCount(value) == 0 || state.busy || !state.linkReady)
          .accessibilityIdentifier("bestASR.spaces.doShare")
      }
      if !state.linkReady {
        Text(SpaceWords.linkOff).font(.zhiji(12)).foregroundStyle(palette.secondary)
      }
    }
  }

  private func selectedCount(_ value: SpaceShareDraft) -> Int {
    if case .item = value.scale { return value.picked == nil ? 0 : 1 }
    return value.review.ticked.count
  }

  private func shareTitle(_ value: SpaceShareDraft) -> String {
    "共享 \(selectedCount(value)) 条"
  }

  private func isScale(_ a: SpaceShareScale, _ b: SpaceShareScale) -> Bool {
    switch (a, b) {
    case (.item, .item), (.matter, .matter), (.rope, .rope): true
    default: false
    }
  }

  private func scaleOption(
    _ draft: Binding<SpaceShareDraft>, _ scale: SpaceShareScale, _ title: String, _ detail: String
  ) -> some View {
    let selected = isScale(draft.wrappedValue.scale, scale)
    return Button {
      if !selected { draft.wrappedValue.scale = scale }
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(selected ? palette.accent : palette.tertiary)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.zhiji(13, .semibold)).foregroundStyle(palette.label)
          Text(detail).font(.zhiji(12)).foregroundStyle(palette.secondary)
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func reviewRow(_ draft: Binding<SpaceShareDraft>, _ candidate: SpaceShareCandidate)
    -> some View
  {
    let single = isScale(draft.wrappedValue.scale, .item)
    let on =
      single
      ? draft.wrappedValue.picked == candidate.id
      : draft.wrappedValue.review.ticked.contains(candidate.id)
    return Button {
      if single {
        draft.wrappedValue.picked = candidate.id
      } else {
        draft.wrappedValue.review.toggle(candidate.id)
      }
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(
          systemName: single
            ? (on ? "largecircle.fill.circle" : "circle")
            : (on ? "checkmark.square.fill" : "square")
        )
        .foregroundStyle(on ? palette.accent : palette.tertiary)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(SpaceWords.kind(candidate.wireKind)).font(.zhiji(11))
              .padding(.horizontal, 6).frame(height: 18)
              .background(palette.quietFill, in: Capsule())
            Text(candidate.title).font(.zhiji(13)).lineLimit(1)
          }
          if !candidate.preview.isEmpty {
            Text(candidate.preview).font(.zhiji(12)).foregroundStyle(palette.secondary).lineLimit(1)
          }
          if let reason = candidate.untickedReason {
            Text(reason).font(.zhiji(11)).foregroundStyle(palette.mateInk)
          }
        }
        Spacer(minLength: 0)
      }
      .foregroundStyle(palette.label)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(candidate.title)，\(on ? "已勾选" : "未勾选")")
  }
}
