import BestASRMemory
import MindloomDesign
import MindloomSpaces
import SwiftUI

// OWNER: mac-capture. S11 · A shared space's page (MAC-SPEC §4.13): the name,
// 「{members}和你」 / 「只有你」, rows as Home 按时间 (`HomeTimeView`, rows of
// matters someone else shared prefixed 「{name}共享 · 」) or 按截止; empty
// 「还没有共享的事」. Toolbar 成员 and 「…」 (`SpaceMoreMenu`). Wired to the v8
// spaces code (`SpacesScreenState`, `SpacesActions`).

public struct SpacePageInput {
  /// The space ID (`MemorySidebarSpace.id`).
  public let spaceID: String
  /// 按时间 or 按截止.
  public let lens: MemoryHomeLens
  /// The space's own library, once the App has built it (nil: loading).
  public let spaceState: MemoryScreenState?

  public init(spaceID: String, lens: MemoryHomeLens, spaceState: MemoryScreenState?) {
    self.spaceID = spaceID
    self.lens = lens
    self.spaceState = spaceState
  }
}

/// The matters a space page lists: mine shared there (from my library) and
/// the ones members shared (the space's own library), each once.
@MainActor
enum SpacePageModel {
  static func matters(_ context: MindloomPageContext, _ input: SpacePageInput) -> (
    matters: [MatterDigest], sharedBy: [String: String]
  ) {
    var seen = Set<String>()
    var matters: [MatterDigest] = []
    var sharedBy: [String: String] = [:]
    for matter in context.state.digest?.matters ?? [] {
      guard let info = context.state.sharing[matter.eventID], info.spaceID == input.spaceID,
        seen.insert(matter.eventID).inserted
      else { continue }
      matters.append(matter)
      if let by = info.sharedBy { sharedBy[matter.eventID] = by }
    }
    // The space's copy of a matter of mine (the shared package, or the space
    // organizer's matter made only of what I shared) is that matter again
    // under another ID: listed once, as mine (finish-mac live run).
    let mineItems = Set(matters.flatMap(\.itemIDs).map { $0.uppercased() })
    for matter in input.spaceState?.digest?.matters ?? []
    where !isCopy(itemIDs: matter.itemIDs, ofMine: mineItems)
      && seen.insert(matter.eventID).inserted
    {
      matters.append(matter)
      if let by = input.spaceState?.sharing[matter.eventID]?.sharedBy {
        sharedBy[matter.eventID] = by
      }
    }
    return (matters, sharedBy)
  }

  /// A space matter whose every item is one of mine already listed.
  nonisolated static func isCopy(itemIDs: [String], ofMine mine: Set<String>) -> Bool {
    !itemIDs.isEmpty && itemIDs.allSatisfy { mine.contains($0.uppercased()) }
  }

  /// 「周明澜、宋雨桐、高原、韩策、邓子墨和你」 or 「只有你」.
  static func membersLine(_ space: MemorySidebarSpace?) -> String {
    let names = space?.memberNames ?? []
    return names.isEmpty ? "仅你自己" : names.joined(separator: "、") + "和你"
  }
}

public struct SpacePage: View {
  let context: MindloomPageContext
  let input: SpacePageInput

  public init(context: MindloomPageContext, input: SpacePageInput) {
    self.context = context
    self.input = input
  }

  public var body: some View {
    let space = context.state.space(input.spaceID)
    let (matters, sharedBy) = SpacePageModel.matters(context, input)
    MindloomPageScroll(key: context.navigation.scrollKey) {
      VStack(alignment: .leading, spacing: 0) {
        Text(space?.name ?? "").mlFont(\.title).foregroundStyle(MLColor.ink)
          .padding(.top, 10)
          .accessibilityAddTraits(.isHeader)
        Text(SpacePageModel.membersLine(space)).mlFont(\.sub).foregroundStyle(MLColor.ink2)
          .padding(.top, 4)
        if matters.isEmpty {
          VStack(spacing: 10) {
            Text("尚无共享的事").mlFont(\.headline).foregroundStyle(MLColor.ink)
            Text("点按一件事右上角的“共享”，然后选取“\(space?.name ?? "")”。")
              .mlFont(\.sub).foregroundStyle(MLColor.ink2)
          }
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
          .padding(.top, 90)
        } else if input.lens == .deadlines {
          HomeDeadlineView(
            context: context, input: HomeDeadlineInput(eventIDs: Set(matters.map(\.eventID))))
        } else {
          HomeTimeView(
            context: context,
            input: HomeListInput(matters: matters, showsCaptures: false, sharedBy: sharedBy))
        }
      }
    }
  }
}

/// The space's 「…」 menu: 「成员…」 · 「邀请…」 · ─ · 「退出这个共享空间」.
/// The space's owner gets no 「退出这个共享空间」: the DGX Spark refuses an
/// owner leaving (`owner_cannot_leave`) and has no way to delete a space, so
/// the item could only end in a refusal (review finish-ship).
public struct SpaceMoreMenu: View {
  let context: MindloomPageContext
  let spaceID: String

  public init(context: MindloomPageContext, spaceID: String) {
    self.context = context
    self.spaceID = spaceID
  }

  public var body: some View {
    Button {
      context.spacesActions.present(.members(spaceID: spaceID))
    } label: {
      Label("成员…", systemImage: "person.2")
    }
    Button {
      context.spacesActions.present(.invite(spaceID: spaceID))
    } label: {
      Label("邀请…", systemImage: "person.badge.plus")
    }
    let space = context.spaces.space(spaceID)
    if !Self.youOwn(memberID: space?.memberID, members: space?.members ?? []) {
      Divider()
      Button(role: .destructive) {
        context.actions.capture.leaveSpace(spaceID)
      } label: {
        Label("退出共享空间", systemImage: "xmark")
      }
    }
  }

  /// Whether you (`memberID`) own the space.
  static func youOwn(memberID: String?, members: [SpaceMember]) -> Bool {
    guard let memberID else { return false }
    return members.contains { $0.memberID == memberID && $0.owner }
  }
}
