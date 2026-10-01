import SwiftUI

/// The privacy promises in plain words (PHONE-CONTRACT §0), each one true in
/// the code: on-device recognition with audio kept only in memory, sealing to
/// the Mac's key before anything leaves the phone, a Spark that only relays
/// sealed bytes, and a phone key that can only drop entries into the inbox.
struct PrivacyView: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text("说的话、分享的东西，去了哪里")
          .font(.loom(24, .semibold))
          .foregroundStyle(Loom.ink)
          .padding(.top, 8)
          .padding(.bottom, 4)
        Promise(
          symbol: "waveform", title: "声音只在手机上转成文字，不保存",
          detail: "按住麦克风时，声音在这台手机上直接转成文字。声音只在内存里停留到这句话转完，不写进存储，也不发给任何人。")
        Promise(
          symbol: "lock.fill", title: "内容在手机上就锁好，只有你的 Mac 能打开",
          detail: "每一条在离开手机之前，都用你的 Mac 的钥匙锁上。锁好的内容只有那台 Mac 能打开。")
        Promise(
          symbol: "arrow.left.arrow.right", title: "Spark 只负责转交，读不到",
          detail: "锁好的内容经你自己的 Spark 转交。Spark 手里没有钥匙，读不到内容；Mac 取走之后，Spark 就把它删掉。")
        Promise(
          symbol: "key.fill", title: "这把钥匙只能往收件箱里放东西",
          detail:
            "手机上用来连接 Spark 的钥匙只能做一件事：往收件箱里放锁好的内容。它读不到任何内容，不能删除，也不能做别的。在 Mac 上断开 iPhone，这把钥匙就作废。")

        VStack(alignment: .leading, spacing: 10) {
          Text("还要知道的").font(.loom(15, .semibold)).foregroundStyle(Loom.ink)
          Note("开着语音时，屏幕顶部会一直亮着麦克风指示。这时织机在等你按键；没按住时说的话不会被转写。10 分钟不用会自动关闭。")
          Note("织机键盘看不到你用其他键盘打的字，只收你用麦克风说出、写进输入框的那几句。")
          Note("录音和视频不从手机分享，请在 Mac 上导入。")
          Note("分享的图片会先重新存一遍，去掉拍摄地点、设备等信息。")
          Note("送出之后，手机上只留一行文字提示，7 天后自动删掉；图片不留。")
          Note("你的词典和声音特征只在 Mac 上，不会到手机上。")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Loom.well, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.top, 6)
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 32)
    }
    .background(Loom.page.ignoresSafeArea())
    .navigationTitle("隐私")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct Promise: View {
  let symbol: String
  let title: String
  let detail: String

  var body: some View {
    LoomCard(padding: 18) {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: symbol)
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(Loom.accent)
          .frame(width: 40, height: 40)
          .background(Loom.accentTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        VStack(alignment: .leading, spacing: 6) {
          Text(title)
            .font(.loom(17, .semibold))
            .foregroundStyle(Loom.ink)
            .fixedSize(horizontal: false, vertical: true)
          Text(detail)
            .font(.loom(14))
            .foregroundStyle(Loom.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }
}

private struct Note: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Circle().fill(Loom.tertiary).frame(width: 4, height: 4).offset(y: -3)
      Text(text)
        .font(.loom(13))
        .foregroundStyle(Loom.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
