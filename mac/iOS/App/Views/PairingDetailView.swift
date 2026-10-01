import MindloomLink
import SwiftUI

/// The connected Mac, and a way to forget it on this phone.
struct PairingDetailView: View {
  @Environment(AppModel.self) private var model
  @State private var confirmForget = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let record = model.pairing.record {
          LoomCard(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
              Label(record.label, systemImage: "laptopcomputer")
                .font(.loom(18, .semibold))
                .foregroundStyle(Loom.ink)
              Detail(
                title: "送往", value: record.relay == nil ? "你的 Spark" : "你的 Spark（经中转）",
                monospaced: false)
              Detail(title: "Mac 的钥匙", value: record.sealKeyID ?? "—")
              Detail(title: "这台手机的编号", value: record.phoneKeyID)
            }
          }
          Text("在 Mac 上「断开 iPhone」会让这台手机的钥匙作废。下面的按钮只在这台手机上忘掉配对。")
            .font(.loom(13))
            .foregroundStyle(Loom.secondary)
            .padding(.horizontal, 4)
          Button("在这台手机上忘掉这台 Mac", role: .destructive) { confirmForget = true }
            .buttonStyle(LoomSecondaryButtonStyle(foreground: Loom.red))
        } else {
          LoomCard(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
              Text("还没连接 Mac").font(.loom(18, .semibold)).foregroundStyle(Loom.ink)
              Text("连接之后，织机键盘说的话和「收进织机」分享的东西会锁好送到你的 Mac。")
                .font(.loom(14)).foregroundStyle(Loom.secondary)
              Button("连接 Mac") { model.showsPairing = true }
                .buttonStyle(LoomPrimaryButtonStyle())
            }
          }
        }
      }
      .padding(20)
    }
    .background(Loom.page.ignoresSafeArea())
    .navigationTitle("连接的 Mac")
    .navigationBarTitleDisplayMode(.inline)
    .confirmationDialog("忘掉这台 Mac？", isPresented: $confirmForget, titleVisibility: .visible) {
      Button("忘掉", role: .destructive) { model.pairing.unpair() }
    } message: {
      Text("还没送出的内容会留在手机上，重新连接同一台 Mac 后再送出。")
    }
  }
}

private struct Detail: View {
  let title: String
  let value: String
  var monospaced = true

  var body: some View {
    HStack {
      Text(title).font(.loom(14)).foregroundStyle(Loom.secondary)
      Spacer()
      Text(value)
        .font(monospaced ? .loom(14).monospaced() : .loom(14))
        .foregroundStyle(Loom.ink)
        .lineLimit(1)
    }
  }
}

/// Apache-2.0 notices for the SSH stack (ADR-0007).
struct AcknowledgementsView: View {
  private let text: String = {
    guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else { return "" }
    return text
  }()

  var body: some View {
    ScrollView {
      Text(text)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(Loom.secondary)
        .textSelection(.enabled)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Loom.page.ignoresSafeArea())
    .navigationTitle("开源许可")
    .navigationBarTitleDisplayMode(.inline)
  }
}
