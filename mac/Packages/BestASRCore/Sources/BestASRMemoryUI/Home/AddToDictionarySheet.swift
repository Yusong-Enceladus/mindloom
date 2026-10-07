import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: v12 find. 加进词典 from a 历史 record (ALIGNMENT 收1-7): the record's
// words as buttons; click the misheard ones (each click adds the word to
// 「听成了」, so a word cut in two is two clicks), write 「应该写成」, done.
// Saved through `actions.history.addToDictionary`.

public struct AddToDictionarySheetInput: Equatable, Sendable {
  /// The record's upper-case item ID.
  public let itemID: String
  /// Already filled (still images).
  public var heard: String
  public var written: String

  public init(itemID: String, heard: String = "", written: String = "") {
    self.itemID = itemID
    self.heard = heard
    self.written = written
  }
}

public struct AddToDictionarySheet: View {
  let context: MindloomPageContext
  let input: AddToDictionarySheetInput
  @State private var heard: String
  @State private var written: String
  @FocusState private var writtenFocused: Bool
  @FocusState private var heardFocused: Bool

  public init(context: MindloomPageContext, input: AddToDictionarySheetInput) {
    self.context = context
    self.input = input
    _heard = State(initialValue: input.heard)
    _written = State(initialValue: input.written)
  }

  private var text: String {
    context.state.history.rows.first { $0.itemID == input.itemID }?.fullText ?? ""
  }

  private var canSave: Bool {
    let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
    let w = written.trimmingCharacters(in: .whitespacesAndNewlines)
    return !w.isEmpty && h != w
  }

  public var body: some View {
    MindloomSheetChrome(width: 480) {
      Text("添加到词典").mlFont(\.title2).foregroundStyle(MLColor.ink).padding(.bottom, 6)
      Text("选择识别错误的词，然后输入正确的写法。之后口述时会使用这个写法。")
        .mlFont(\.sub).foregroundStyle(MLColor.ink2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 12)
      let words = SearchText.displayWords(text, limit: 120)
      if !words.isEmpty {
        ZhijiScroll {
          FlowRows(spacing: 4) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
              Button {
                heard += word
              } label: {
                Text(word)
                  .mlFont(\.control)
                  .foregroundStyle(MLColor.ink)
                  .padding(.horizontal, 6)
                  .frame(height: 24)
                  .background(
                    MLColor.fill2, in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                  )
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 150)
        .padding(.bottom, 14)
      }
      HStack(spacing: 10) {
        Text("识别为").mlFont(\.control).foregroundStyle(MLColor.ink2).frame(
          width: 56, alignment: .leading)
        MindloomSheetField(placeholder: "点按上方的词，或直接输入", text: $heard, focused: $heardFocused)
          .accessibilityLabel("识别为")
        if !heard.isEmpty {
          Button {
            heard = ""
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(MLColor.ink3)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("清空")
        }
      }
      HStack(spacing: 10) {
        Text("正确写法").mlFont(\.control).foregroundStyle(MLColor.ink2).frame(
          width: 56, alignment: .leading)
        MindloomSheetField(placeholder: "正确的写法", text: $written, focused: $writtenFocused)
          .accessibilityLabel("正确写法")
          .onSubmit(save)
      }
      .padding(.top, 8)
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        Button("取消") { context.navigator.present(nil) }
          .buttonStyle(MLButtonStyle(.standard))
          .keyboardShortcut(.cancelAction)
        Button("添加到词典", action: save)
          .buttonStyle(MLButtonStyle(.primary))
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave)
      }
      .padding(.top, 20)
    }
    .onAppear { writtenFocused = true }
  }

  private func save() {
    guard canSave else { return }
    context.navigator.present(nil)
    context.actions.history.addToDictionary(
      heard.trimmingCharacters(in: .whitespacesAndNewlines),
      written.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}
