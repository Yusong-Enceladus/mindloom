import SwiftUI

/// How to add 织机键盘, and why it needs full access, in plain words.
struct KeyboardCard: View {
  @Environment(AppModel.self) private var model
  @State private var showsWhy = false

  var body: some View {
    LoomCard(padding: 20) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 10) {
          Text("织机键盘").font(.loom(20, .semibold)).foregroundStyle(Loom.ink)
          if model.keyboardReady {
            Label("已就绪", systemImage: "checkmark.circle.fill")
              .font(.loom(13, .medium))
              .foregroundStyle(Loom.green)
          }
        }
        if model.keyboardReady {
          Text("在任何输入框里点 🌐 切到织机键盘，按住麦克风说话，松开就写进去。再点 🌐 回到你平时的键盘。")
            .font(.loom(14))
            .foregroundStyle(Loom.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          VStack(alignment: .leading, spacing: 10) {
            Step(number: 1, text: "打开「设置」→「通用」→「键盘」→「键盘」")
            Step(number: 2, text: "点「添加新键盘」，在「第三方键盘」里选「织机」")
            Step(number: 3, text: "点「织机键盘 — 织机」，打开「允许完全访问」")
            Step(number: 4, text: "打字时点 🌐 切到织机键盘")
          }
          Button("打开设置") {
            if let url = URL(string: UIApplication.openSettingsURLString) {
              UIApplication.shared.open(url)
            }
          }
          .buttonStyle(LoomSecondaryButtonStyle())
        }
        DisclosureGroup(isExpanded: $showsWhy) {
          Text(
            "织机键盘要和织机 App 共用手机上的一个小文件夹：你说的话由织机转成文字，再经这个文件夹交给键盘写进输入框。iOS 把键盘和 App 之间的这种共享叫作「完全访问」。\n\n织机键盘本身不联网，也看不到你用其他键盘打的字；它只把你用麦克风说出、写进输入框的那几句收进织机。"
          )
          .font(.loom(13))
          .foregroundStyle(Loom.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 8)
        } label: {
          Text("为什么要「允许完全访问」")
            .font(.loom(14, .medium))
            .foregroundStyle(Loom.accent)
        }
        .tint(Loom.accent)
      }
    }
  }
}

struct Step: View {
  let number: Int
  let text: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text("\(number)")
        .font(.loom(12, .semibold).monospacedDigit())
        .foregroundStyle(Loom.accent)
        .frame(width: 22, height: 22)
        .background(Loom.accentTint, in: Circle())
      Text(text)
        .font(.loom(14))
        .foregroundStyle(Loom.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
