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
    switch sheet {
    // v11 sheets (MAC-SPEC §7.4): their own width and chrome.
    case .newSpace: NewSpaceSheet(state: state, actions: actions)
    case .join: JoinSpaceSheet(state: state, actions: actions)
    case .members(let id):
      SpaceMembersSheet(input: SpaceMembersInput(spaceID: id, state: state), actions: actions)
    case .invite(let id): SpaceInviteSheet(spaceID: id, state: state, actions: actions)
    case .share: ShareSheet(state: state, actions: actions)
    default:
      ZhijiThemed {
        Group {
          switch sheet {
          case .items(let s, let e):
            SpaceItemsSheet(spaceID: s, eventID: e, state: state, actions: actions)
          case .review(let id): SpaceReviewSheet(spaceID: id, state: state, actions: actions)
          case .audit(let id): SpaceAuditSheet(spaceID: id, state: state, actions: actions)
          case .handover: HandoverSheet(state: state, actions: actions)
          case .propose(let s, let e):
            SpaceProposeSheet(spaceID: s, eventID: e, state: state, actions: actions)
          default: EmptyView()
          }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 360, idealHeight: 560)
      }
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

