import MindloomDesign
import MindloomSpaces
import SwiftUI

// OWNER: mac-capture. 共享 (MAC-SPEC §7.4, shots `share`, `share-look`,
// `share-shared`): 「共享「{title}」给 {space ⇕}」, one sentence, 「查看会共享
// 什么」 (each kind with its count and a tick; 你的口述 never), 取消 · 共享. A
// matter already shared there: 「「{title}」已共享到「{space}」」, 停止共享 · 完成.
// Wired to the v8 share (`SpacesActions.share` / `unshare`).

struct ShareSheet: View {
  let state: SpacesScreenState
  let actions: SpacesActions
  @State private var draft: SpaceShareDraft?
  @State private var looking: Bool

  init(state: SpacesScreenState, actions: SpacesActions, looking: Bool = false) {
    self.state = state
    self.actions = actions
    _draft = State(initialValue: state.shareDraft)
    _looking = State(initialValue: looking)
  }

  var body: some View {
    Group {
      if let draft = Binding($draft) {
        content(draft)
      } else {
        MindloomSheetChrome(width: 480) {
          ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 20)
        }
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
    let spaceID = value.destination ?? value.destinations.first?.spaceID
    if let space = value.destinations.first(where: { $0.spaceID == spaceID }) {
      ShareSheetContent(
        draft: draft, spaces: value.destinations.map { ($0.spaceID, $0.name) },
        selected: space.spaceID,
        memberCount: space.activeMembers.filter { $0.memberID != space.memberID }.count,
        alreadyShared: value.sharedIn[space.spaceID] != nil, looking: $looking,
        canShare: !state.busy && state.linkReady, actions: actions)
    } else {
      MindloomSheetChrome(width: 480) {
        SheetTitle("尚无共享空间")
        SheetText("请先新建共享空间并邀请他人加入，然后共享这件事。")
        SheetActions {
          Button("取消") { actions.present(nil) }.buttonStyle(MLButtonStyle(.standard))
          Button("新建共享空间…") { actions.present(.newSpace) }
            .buttonStyle(MLButtonStyle(.primary))
        }
      }
    }
  }
}

/// The two states of the share sheet, from plain values (still images build
/// it without a space's keys).
struct ShareSheetContent: View {
  @Binding var draft: SpaceShareDraft
  let spaces: [(String, String)]
  let selected: String
  /// The other members of the selected space.
  let memberCount: Int
  let alreadyShared: Bool
  @Binding var looking: Bool
  let canShare: Bool
  let actions: SpacesActions

  private var spaceName: String { spaces.first { $0.0 == selected }?.1 ?? "" }

  var body: some View {
    if alreadyShared { shared } else { share }
  }

  private var share: some View {
    MindloomSheetChrome(width: 480) {
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        Text("共享“\(MLAutospace.apply(draft.title))”给 ").mlFont(\.title2)
        SpacePopup(spaces: spaces, selected: selected) { id in draft.destination = id }
      }
      .padding(.bottom, 6)
      .fixedSize(horizontal: false, vertical: true)
      SheetText("成员可以看到这件事的进展和你选择的原文。")
      if looking {
        ShareIncludes(draft: $draft).padding(.top, 12).transition(.opacity)
      }
      SheetActions {
        Button(looking ? "折叠" : "查看共享内容") {
          withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.24)) { looking.toggle() }
        }
        .buttonStyle(MLButtonStyle(.plain))
      } trailing: {
        Button("取消") { actions.present(nil) }
          .buttonStyle(MLButtonStyle(.standard))
          .keyboardShortcut(.cancelAction)
        Button("共享") {
          var final = draft
          final.destination = selected
          final.scale = .matter(rule: .ask)
          actions.share(final)
        }
        .buttonStyle(MLButtonStyle(.primary))
        .disabled(!canShare)
        .keyboardShortcut(.defaultAction)
      }
    }
  }

  private var shared: some View {
    MindloomSheetChrome(width: 460) {
      SheetTitle("“\(MLAutospace.apply(draft.title))”已共享到“\(spaceName)”")
      SheetText("\(spaceName)的 \(memberCount) 位成员可以看到它的进展和你选择的原文。")
      SheetActions {
        Button("停止共享") { actions.unshare(selected, draft.eventID) }
          .buttonStyle(MLButtonStyle(.destructive))
      } trailing: {
        Button("完成") { actions.present(nil) }
          .buttonStyle(MLButtonStyle(.primary))
          .keyboardShortcut(.defaultAction)
      }
    }
  }
}

/// The space popup in the title (24 high, `surface`, 0.5 ring, radius 7, name
/// + chevron.up.chevron.down 12), a menu of spaces with a checkmark.
struct SpacePopup: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  let spaces: [(String, String)]
  let selected: String
  let choose: (String) -> Void

  var body: some View {
    if snapshot {
      SpacePopupLabel(name: spaces.first { $0.0 == selected }?.1 ?? "")
    } else {
      menu
    }
  }

  private var menu: some View {
    Menu {
      ForEach(spaces, id: \.0) { id, name in
        Button {
          choose(id)
        } label: {
          if id == selected { Label(name, systemImage: "checkmark") } else { Text(name) }
        }
      }
    } label: {
      SpacePopupLabel(name: spaces.first { $0.0 == selected }?.1 ?? "")
    }
    // The label as drawn (name, chevron, ring); `.borderlessButton` on
    // macOS 27 drops its background and puts the chevron first.
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
  }
}

struct SpacePopupLabel: View {
  let name: String

  var body: some View {
    HStack(spacing: 6) {
      Text(name).mlFont(\.control).foregroundStyle(MLColor.ink)
      Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
        .foregroundStyle(MLColor.ink2)
    }
    .padding(.leading, 10)
    .padding(.trailing, 8)
    .frame(height: 24)
    .background(MLColor.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(
        MLColor.rule2, lineWidth: 0.5))
  }
}

/// 「查看会共享什么」: one row per kind with its count and a tick (a kind with
/// nothing says 没有 and cannot be ticked); 你的口述 · 不共享 last.
struct ShareIncludes: View {
  @Binding var draft: SpaceShareDraft

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      kindRow(.progress, count: draft.progressCount, ticked: true, locked: true)
      ForEach([ShareKind.chats, .mail, .files], id: \.self) { kind in
        let ids = ids(kind)
        kindRow(
          kind, count: ids.count, ticked: !ids.isEmpty && ids.allSatisfy(draft.review.ticked.contains),
          locked: ids.isEmpty
        ) { on in
          for id in ids where draft.review.ticked.contains(id) != on { draft.review.toggle(id) }
        }
      }
      HStack(spacing: 8) {
        Image(systemName: ShareKind.dictation.symbol).font(.system(size: 12)).frame(width: 16)
        Text(ShareKind.dictation.title)
        Spacer(minLength: 8)
        Text("不包括")
      }
      .mlFont(\.callout)
      .foregroundStyle(MLColor.ink2)
      .padding(.leading, 21)
      .frame(minHeight: 28)
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 12)
    .background(MLColor.paper2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  /// The candidates of a kind (dictation never; the App's kinds first).
  private func ids(_ kind: ShareKind) -> [String] {
    draft.review.candidates.filter {
      !$0.isPrivateDictation && (draft.kindOf[$0.id] ?? ShareKind.of(wireKind: $0.wireKind)) == kind
    }.map(\.id)
  }

  private func kindRow(
    _ kind: ShareKind, count: Int, ticked: Bool, locked: Bool, set: ((Bool) -> Void)? = nil
  ) -> some View {
    HStack(spacing: 8) {
      ShareCheckbox(on: ticked && count > 0, enabled: count > 0) { if !locked { set?(!ticked) } }
      Image(systemName: kind.symbol).font(.system(size: 12)).foregroundStyle(MLColor.ink2)
        .frame(width: 16)
      Text(kind.title).foregroundStyle(MLColor.ink)
      Spacer(minLength: 8)
      Text(count > 0 ? "\(count) 条" : "无").monospacedDigit().foregroundStyle(MLColor.ink2)
    }
    .mlFont(\.callout)
    .frame(minHeight: 28)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(ticked ? .isSelected : [])
  }
}

/// A 14 pt checkbox in `accentFill`.
struct ShareCheckbox: View {
  let on: Bool
  let enabled: Bool
  let toggle: () -> Void

  var body: some View {
    Button(action: toggle) {
      RoundedRectangle(cornerRadius: 3.5, style: .continuous)
        .fill(on ? MLColor.accentFill : MLColor.surface)
        .overlay(
          RoundedRectangle(cornerRadius: 3.5, style: .continuous).strokeBorder(
            on ? MLColor.accentFill : MLColor.ink3, lineWidth: on ? 0.5 : 1)
        )
        .overlay {
          if on {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
              .foregroundStyle(MLColor.onAccent)
          }
        }
        .frame(width: 14, height: 14)
        .opacity(enabled ? 1 : 0.4)
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
  }
}
