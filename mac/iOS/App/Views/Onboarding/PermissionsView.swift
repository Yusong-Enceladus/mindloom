import MindloomDesign
import SwiftUI

/// 「再打开两项」 (PHONE-SPEC §5.3): the microphone and the keyboard, one row each, then 完成.
struct PermissionsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase
  @State private var showsKeyboard = false

  var body: some View {
    GeometryReader { proxy in
      let insets = proxy.safeAreaInsets
      ZStack(alignment: .top) {
        MLColor.paper.dynamicColor
        VStack(alignment: .leading, spacing: 0) {
          Text("还需允许两项")
            .font(PhoneTitleFont.font(28))
            .foregroundStyle(MLColor.ink)
            .frame(height: 34)
            .padding(EdgeInsets(top: 2, leading: 20, bottom: 6, trailing: 20))
          if let name = model.macName {
            Text("已连接 " + name)
              .font(.system(size: 13))
              .foregroundStyle(MLColor.ink2)
              .padding(.horizontal, 20)
          }
          VStack(spacing: 0) {
            PermissionRow(
              symbol: "mic", title: "麦克风", text: "语音开启时保持打开；按住时说的话会被转写。",
              done: model.voice.microphone == .granted, doneText: "已允许", actionTitle: "允许"
            ) {
              Task { await model.voice.requestMicrophone() }
            }
            Rectangle().fill(MLColor.rule).frame(height: 0.5).padding(.leading, 48)
            PermissionRow(
              symbol: "keyboard", title: "Mindloom 键盘", text: "在其他 App 中也可以按住说话。",
              done: model.keyboardAdded && model.keyboardFullAccess, doneText: "已添加",
              actionTitle: "打开设置"
            ) {
              showsKeyboard = true
            }
          }
          .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(MLColor.surface))
          .padding(EdgeInsets(top: 24, leading: 16, bottom: 0, trailing: 16))
          Spacer()
          BlockButton("完成") { model.route = .home }
            .padding(.horizontal, 20)
            .padding(.bottom, insets.bottom + 4)
        }
        .padding(.top, insets.top + 64)
      }
      .ignoresSafeArea()
    }
    .navigationDestination(isPresented: $showsKeyboard) { KeyboardPageView() }
    .toolbar(.hidden, for: .navigationBar)
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { model.refreshKeyboardStatus() }
    }
  }
}

struct PermissionRow: View {
  let symbol: String
  let title: String
  let text: String
  let done: Bool
  let doneText: String
  let actionTitle: String
  let action: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      Image(systemName: symbol)
        .font(.system(size: PhoneGlyph.size(symbol)))
        .foregroundStyle(MLColor.ink2)
        .frame(width: 32, height: 24, alignment: .leading)
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .center) {
          Text(title)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(MLColor.ink)
          Spacer(minLength: 8)
          if done {
            HStack(spacing: 4) {
              Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold))
              Text(doneText).font(.system(size: 15))
            }
            .foregroundStyle(MLColor.ink2)
          } else {
            SmallTintedButton(title: actionTitle, height: 30, action: action)
          }
        }
        // The title line is 24 high in both states (the 30 pt button overhangs it evenly), so the
        // list does not move when a permission is granted.
        .frame(height: 24)
        BalancedText(text: text, available: 260)
      }
    }
    .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
  }
}

/// Optical sizes for the row glyphs: `keyboard` is a wide symbol and reads larger and heavier than
/// `mic`, `shield` or `info.circle` at the same point size.
enum PhoneGlyph {
  static func size(_ symbol: String, base: CGFloat = 18) -> CGFloat {
    symbol == "keyboard" ? base - 3 : base
  }
}
