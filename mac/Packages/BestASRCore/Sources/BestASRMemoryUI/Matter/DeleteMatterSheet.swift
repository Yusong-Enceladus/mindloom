import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: mac-matter. S14 · 删除「{title}」？ (MAC-SPEC §7.4): 「这件事的进展会删掉。
// 你收进来的原文和文件还在。」 · 取消 · 删除 (destructive filled). Result:
// `actions.correct(.delete)`, Home, toast 「已删除」 · 撤销.

public struct DeleteMatterSheetInput: Equatable, Sendable {
  public let eventID: String

  public init(eventID: String) { self.eventID = eventID }
}

public struct DeleteMatterSheet: View {
  let context: MindloomPageContext
  let input: DeleteMatterSheetInput

  public init(context: MindloomPageContext, input: DeleteMatterSheetInput) {
    self.context = context
    self.input = input
  }

  public var body: some View {
    let matter = context.state.matter(input.eventID)
    VStack(alignment: .leading, spacing: 0) {
      Text("删除“\(MLAutospace.apply(matter?.title ?? ""))”？")
        .mlFont(\.title2, lineBox: true)
        .foregroundStyle(MLColor.ink)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 6)
      Text("这件事的进展将被删除。你添加的原文和文件会保留。")
        .mlFont(\.callout, lineBox: true)
        .foregroundStyle(MLColor.ink2)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        Button("取消") { context.navigator.present(nil) }
          .buttonStyle(MLButtonStyle(.standard))
          .keyboardShortcut(.cancelAction)
        Button("删除") {
          context.navigator.present(nil)
          guard let matter else { return }
          if context.navigation.openMatter == matter.eventID { context.navigator.openRoot(.home) }
          context.actions.correct(.delete(eventID: matter.eventID, title: matter.title))
        }
        .buttonStyle(MLButtonStyle(.destructivePrimary))
        .disabled(matter == nil)
      }
      .padding(.top, 20)
    }
    .padding(.top, 22)
    .padding(.horizontal, 24)
    .padding(.bottom, 18)
    .frame(width: 400, alignment: .leading)
    .background(MLColor.surface)
  }
}
