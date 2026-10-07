import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: mac-home. S4 · Home empty (MAC-SPEC §4.4): 「还没有东西」 /
// 「按住 fn 说一句，或者把文件拖进这个窗口。」, or the waiting captures; the
// offline line above (drawn by `HomePage`) when the DGX Spark is not
// connected. No illustration, no mark.

public struct HomeEmptyView: View {
  let context: MindloomPageContext

  public init(context: MindloomPageContext) {
    self.context = context
  }

  public var body: some View {
    if context.state.waitingCaptures.isEmpty {
      HomeEmptyMessage(title: "尚无内容", message: "按住 fn 键说话，或将文件拖到此窗口。")
        .padding(.top, 140)
    } else {
      HomeTimeView(
        context: context, input: HomeListInput(matters: [], showsCaptures: true, sharedBy: [:]))
        .padding(.top, 14)
    }
  }
}

/// `.ml-empty`: a title (15/21 500) and one sentence (13/18 `ink2`, at most
/// 26 em), centred, 10 apart; an optional tinted button.
struct HomeEmptyMessage: View {
  var title: String? = nil
  var message: String? = nil
  var actionTitle: String? = nil
  var action: (() -> Void)? = nil

  var body: some View {
    VStack(spacing: 10) {
      if let title {
        Text(title).mlFont(\.headline).foregroundStyle(MLColor.ink)
      }
      if let message {
        Text(message).mlFont(\.sub).foregroundStyle(MLColor.ink2).frame(maxWidth: 26 * 13)
      }
      if let actionTitle, let action {
        Button(action: action) {
          HStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
            Text(actionTitle)
          }
        }
        .buttonStyle(MLButtonStyle(.tinted))
        .padding(.top, 6)
      }
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity)
  }
}
