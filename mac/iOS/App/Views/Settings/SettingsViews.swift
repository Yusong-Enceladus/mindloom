import MindloomDesign
import MindloomPhoneKit
import SwiftUI
import UIKit

/// The pages pushed from Home's gear (PHONE-SPEC §5.6–5.11), on the system navigation stack.
enum SettingsRoute: Hashable {
  case settings
  case autoEnd
  case mac
  case privacy
  case keyboard
  case about
  case licenses
}

extension View {
  /// Grouped page styling: `paper2` behind inset lists of `surface` rows.
  func groupedPage(_ title: String, large: Bool = true) -> some View {
    self
      .scrollContentBackground(.hidden)
      .background(MLColor.paper2.dynamicColor.ignoresSafeArea())
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(large ? .large : .inline)
      .listSectionSpacing(32)
      .environment(\EnvironmentValues.defaultMinListRowHeight, 52)
      .navigationGutter()
  }

  /// A row on `surface` with the v10 separators.
  func surfaceRow() -> some View {
    self.listRowBackground(MLColor.surface.dynamicColor)
      .listRowSeparatorTint(MLColor.rule.dynamicColor)
  }
}

/// A plain section footer / header in the v10 type.
struct ListNote: View {
  let text: String
  var body: some View {
    Text(PhoneText.keepingWordsWhole(text))
      .font(.system(size: 13))
      .lineSpacing(PhoneLine.spacing(size: 13, lineHeight: 18))
      .foregroundStyle(MLColor.ink2)
      .textCase(nil)
  }
}

struct ListHeader: View {
  let text: String
  var body: some View {
    Text(text)
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(MLColor.ink2)
      .textCase(nil)
  }
}

/// 设置.
struct SettingsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    List {
      Section {
        macRow
      }
      Section {
        if model.voice.isAlive, !model.voice.indicatorShown {
          // No Live Activity carries the session's 「结束」: it is here (and on Home).
          VoiceSessionRow(endsAt: model.voice.endsAt ?? model.voice.aliveUntil) {
            model.voice.end()
          }
          .surfaceRow()
        }
        NavigationLink(value: SettingsRoute.autoEnd) {
          ValueRow(title: "自动结束", value: "闲置 \(model.settings.idleMinutes) 分钟")
        }
        .surfaceRow()
        Toggle(isOn: chargingBinding) { RowTitle("充电时保持开启") }
          .tint(MLColor.accentFill.dynamicColor)
          .surfaceRow()
        Toggle(isOn: keyboardSpeechBinding) { RowTitle("将键盘口述发送到 Mac") }
          .tint(MLColor.accentFill.dynamicColor)
          .surfaceRow()
      } header: {
        ListHeader(text: "语音")
      } footer: {
        ListNote(text: "语音开启时，屏幕顶部显示橙色圆点。")
      }
      Section {
        NavigationLink(value: SettingsRoute.keyboard) {
          IconRow(symbol: "keyboard", title: "Mindloom 键盘", value: keyboardValue)
        }
        .surfaceRow()
        NavigationLink(value: SettingsRoute.privacy) {
          IconRow(symbol: "shield", title: "隐私")
        }
        .surfaceRow()
        NavigationLink(value: SettingsRoute.about) {
          IconRow(symbol: "info.circle", title: "关于")
        }
        .surfaceRow()
      }
    }
    .groupedPage("设置")
  }

  @ViewBuilder
  private var macRow: some View {
    if let name = model.macName {
      NavigationLink(value: SettingsRoute.mac) {
        MacRow(
          title: name, sub: model.delivery.unreachable ? "未连接" : "已连接",
          subIsAlert: model.delivery.unreachable)
      }
      // Only the row's own 66 pt: no list insets on top of it.
      .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
      .surfaceRow()
    } else {
      Button {
        model.startPairing(fromFirstRun: false)
      } label: {
        HStack {
          MacRow(
            title: "连接 Mac", sub: model.settings.disconnected ? "已断开" : "尚未连接", subIsAlert: false)
          Image(systemName: "chevron.right")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(MLColor.ink3)
        }
      }
      .buttonStyle(.plain)
      .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 20))
      .surfaceRow()
    }
  }

  private var keyboardValue: String {
    if !model.keyboardAdded { return "未添加" }
    return model.keyboardFullAccess ? "已添加" : "未允许完全访问"
  }

  private var chargingBinding: Binding<Bool> {
    Binding(
      get: { model.settings.stayOnWhileCharging },
      set: { model.voice.setStayOnWhileCharging($0) })
  }

  private var keyboardSpeechBinding: Binding<Bool> {
    Binding(
      get: { model.settings.sendKeyboardSpeech },
      set: { model.settings.sendKeyboardSpeech = $0 })
  }
}

struct RowTitle: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text).font(.system(size: 17)).foregroundStyle(MLColor.ink)
  }
}

struct ValueRow: View {
  let title: String
  var value: String? = nil
  var valueColor: MLColor = .ink2
  var body: some View {
    HStack {
      RowTitle(title)
      Spacer(minLength: 12)
      if let value {
        Text(value).font(.system(size: 17).monospacedDigit()).foregroundStyle(valueColor)
      }
    }
  }
}

struct IconRow: View {
  let symbol: String
  let title: String
  var value: String? = nil
  var body: some View {
    HStack(spacing: 0) {
      Image(systemName: symbol)
        .font(.system(size: PhoneGlyph.size(symbol)))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(MLColor.ink2)
        .frame(width: 32, alignment: .leading)
      ValueRow(title: title, value: value)
    }
    .alignmentGuide(.listRowSeparatorLeading) { _ in 32 }
  }
}

struct MacRow: View {
  let title: String
  let sub: String
  let subIsAlert: Bool
  var body: some View {
    HStack(spacing: 0) {
      Image(systemName: "laptopcomputer")
        .font(.system(size: 17))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(MLColor.ink2)
        .frame(width: 32, alignment: .leading)
      VStack(alignment: .leading, spacing: 0) {
        RowTitle(title).frame(height: 24)
        Text(sub)
          .font(.system(size: 15))
          .foregroundStyle(subIsAlert ? MLColor.alert : MLColor.ink2)
          .frame(height: 21)
      }
      Spacer(minLength: 0)
    }
    .frame(height: 66)
  }
}

/// 「语音已开启」 / 「还剩 N 分钟」 and 「结束」 (only without a Live Activity).
struct VoiceSessionRow: View {
  let endsAt: Date?
  let onEnd: () -> Void

  var body: some View {
    TimelineView(.periodic(from: .now, by: 15)) { context in
      HStack(spacing: 0) {
        Image(systemName: "mic")
          .font(.system(size: 18))
          .foregroundStyle(MLColor.ink2)
          .frame(width: 32, alignment: .leading)
        VStack(alignment: .leading, spacing: 0) {
          RowTitle("语音已开启").frame(height: 24)
          if let endsAt {
            Text("还剩 \(max(1, Int(endsAt.timeIntervalSince(context.date) / 60))) 分钟")
              .font(.system(size: 15).monospacedDigit())
              .foregroundStyle(MLColor.ink2)
              .frame(height: 21)
          }
        }
        Spacer(minLength: 8)
        SmallTintedButton(title: "结束", action: onEnd)
      }
    }
  }
}

/// 自动结束.
struct AutoEndView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    List {
      Section {
        ForEach(PhoneSettings.idleChoices, id: \.self) { minutes in
          Button {
            model.voice.setIdleMinutes(minutes)
          } label: {
            HStack {
              RowTitle("闲置 \(minutes) 分钟")
              Spacer()
              if model.settings.idleMinutes == minutes {
                Image(systemName: "checkmark")
                  .font(.system(size: 18, weight: .semibold))
                  .foregroundStyle(MLColor.accent)
              }
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .surfaceRow()
        }
      } footer: {
        ListNote(text: "每次口述后重新计时。")
      }
    }
    .groupedPage("自动结束")
  }
}

/// The Mac page: 状态, 连接于, 最近送出, and 与 Mac 断开 with its sheet.
struct MacPageView: View {
  @Environment(AppModel.self) private var model
  @State private var confirming = false

  var body: some View {
    List {
      Section {
        ValueRow(
          title: "状态", value: model.delivery.unreachable ? "未连接" : "已连接",
          valueColor: model.delivery.unreachable ? .alert : .ink2
        )
        .surfaceRow()
        ValueRow(title: "连接于", value: model.settings.pairedAt.map { PhoneFormat.monthDay($0) } ?? "—")
          .surfaceRow()
        ValueRow(
          title: "最近发送",
          value: model.delivery.lastSentAt.map { PhoneFormat.dayAndTime($0) } ?? "—"
        )
        .surfaceRow()
      }
      Section {
        Button {
          confirming = true
        } label: {
          Text("与 Mac 断开连接")
            .font(.system(size: 17))
            .foregroundStyle(MLColor.alert)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .surfaceRow()
      }
    }
    .groupedPage(model.macName ?? "Mac")
    .sheet(isPresented: $confirming) {
      DisconnectSheet(pending: model.delivery.pendingCount) {
        confirming = false
        model.disconnect()
      } cancel: {
        confirming = false
      }
    }
    .onAppear {
      #if DEBUG
        if DebugLaunch.opensDisconnectSheet { confirming = true }
      #endif
    }
  }
}

/// 「与 Mac 断开？」: thick glass, the words follow the pending count.
struct DisconnectSheet: View {
  let pending: Int
  let confirm: () -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      TrimmedTitle(text: "与 Mac 断开连接？")
        .padding(.top, 30)
      BalancedText(
        text: pending > 0
          ? "还有 \(pending) 条未发送，将保留在这台 iPhone 上，重新连接后发送。"
          : "断开连接后，这台 iPhone 停止发送内容。",
        color: .ink2, alignment: .center, available: 320
      )
      .padding(.top, 6)
      .padding(.bottom, 22)
      BlockButton("断开连接", kind: .destructive, action: confirm)
      BlockButton("取消", kind: .neutral, action: cancel)
        .padding(.top, 10)
    }
    .fittedSheet(estimate: pending > 0 ? 252 : 232)
    .presentationDragIndicator(.visible)
    .presentationCornerRadius(38)
  }
}

/// 隐私: three rows that open in place.
struct PrivacyView: View {
  @Environment(AppModel.self) private var model
  @State private var open: Set<Int> = []

  private var rows: [(String, String)] {
    [
      (
        "声音在这台 iPhone 上转写为文字。",
        "语音开启时，麦克风保持打开（屏幕顶部显示橙色圆点）；你按住时说的话会被转写，转写完成后删除声音。转写使用 iPhone 自带的中文语音识别。"
      ),
      ("你发送的内容会加密传送到你的 Mac。", "内容使用你配对的 Mac 的密钥加密。照片会移除拍摄地点和设备信息，链接按地址发送。"),
      (
        "可以随时断开连接。",
        "在“设置”>“\(model.macName ?? "Mac")”中断开连接。断开后，这台 iPhone 停止发送；未发送的内容保留在这台 iPhone 上。"
      ),
    ]
  }

  var body: some View {
    List {
      Section {
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
          Button {
            withAnimation(MLMotion.springSmooth) {
              if open.contains(index) { open.remove(index) } else { open.insert(index) }
            }
          } label: {
            VStack(alignment: .leading, spacing: 0) {
              HStack(alignment: .top, spacing: 12) {
                BodyText(text: row.0)
                  .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                  .font(.system(size: 14, weight: .semibold))
                  .foregroundStyle(MLColor.ink3)
                  .rotationEffect(.degrees(open.contains(index) ? 180 : 0))
                  .animation(.easeInOut(duration: MLMotion.durBase), value: open.contains(index))
                  .padding(.top, 6)
              }
              if open.contains(index) {
                BodyText(text: row.1, size: 15, lineHeight: 21, color: .ink2)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.top, 12)
                  .padding(.bottom, 2)
                  .transition(.opacity)
              }
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .listRowInsets(EdgeInsets())
          .surfaceRow()
        }
      }
    }
    .groupedPage("隐私")
    .onAppear {
      #if DEBUG
        if let index = DebugLaunch.openPrivacyRow { open = [index] }
      #endif
    }
  }
}

/// Mindloom 键盘: status, the steps while something is left to do, and how to use it.
struct KeyboardPageView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openURL) private var openURL

  var body: some View {
    let added = model.keyboardAdded
    let full = model.keyboardFullAccess
    List {
      Section {
        StatusValueRow(title: "键盘", done: added, doneText: "已添加", todoText: "未添加")
          .surfaceRow()
        StatusValueRow(title: "完全访问", done: full, doneText: "已允许", todoText: "未允许")
          .surfaceRow()
      } footer: {
        if !full { ListNote(text: "打开“允许完全访问”后，才能将口述发送到 Mac。") }
      }
      if !added || !full {
        Section {
          StepRow(number: 1, parts: [("打开 ", false), ("设置 > App > Mindloom", true)]).surfaceRow()
          StepRow(number: 2, parts: [("轻点 ", false), ("键盘", true), ("，打开 ", false), ("Mindloom", true)])
            .surfaceRow()
          StepRow(number: 3, parts: [("打开 ", false), ("允许完全访问", true)]).surfaceRow()
        } header: {
          ListHeader(text: "在“设置”里")
        } footer: {
          ListNote(text: "iOS 会提示键盘可以读取你键入的文字。Mindloom 键盘读取的是在它上面键入的文字。")
        }
        Section {
          BlockButton("打开设置") {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
          }
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)
        }
      }
      Section {
        HStack(alignment: .center, spacing: 0) {
          Image(systemName: "globe")
            .font(.system(size: 20))
            .foregroundStyle(MLColor.ink2)
            .frame(width: 32, alignment: .leading)
          BodyText(text: "在任意输入框中轻点地球仪键，切换到 Mindloom 键盘，然后按住说话。")
            .padding(.vertical, 6)
        }
        .surfaceRow()
      } header: {
        ListHeader(text: "使用方法")
      }
    }
    .groupedPage("Mindloom 键盘")
    .onAppear { model.refreshKeyboardStatus() }
  }
}

struct StatusValueRow: View {
  let title: String
  let done: Bool
  let doneText: String
  let todoText: String
  var body: some View {
    HStack {
      RowTitle(title)
      Spacer()
      if done {
        Image(systemName: "checkmark")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(MLColor.ink2)
      }
      Text(done ? doneText : todoText)
        .font(.system(size: 17))
        .foregroundStyle(MLColor.ink2)
    }
  }
}

struct StepRow: View {
  let number: Int
  let parts: [(String, Bool)]
  var body: some View {
    HStack(spacing: 12) {
      Text("\(number)")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(MLColor.ink2)
        .frame(width: 24, height: 24)
        .background(Circle().fill(MLColor.fill))
      parts.reduce(Text("")) { text, part in
        text + Text(part.0).font(.system(size: 17, weight: part.1 ? .medium : .regular))
      }
      .foregroundStyle(MLColor.ink)
    }
    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
  }
}

/// 关于.
struct AboutView: View {
  @Environment(\.colorScheme) private var scheme

  private var version: String {
    let info = Bundle.main.infoDictionary ?? [:]
    let short = info["CFBundleShortVersionString"] as? String ?? "1.0"
    let build = info["CFBundleVersion"] as? String ?? "1"
    return "版本 \(short)（\(build)）"
  }

  var body: some View {
    List {
      Section {
        VStack(spacing: 0) {
          MindloomAppIcon(
            platform: .ios, appearance: scheme == .dark ? .dark : .light, side: 76
          )
          .frame(width: 76, height: 76)
          .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
              .strokeBorder(MLColor.rule2, lineWidth: 0.5)
          )
          .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
          MindloomWordmark(cap: 20)
            .padding(.top, 18)
          Text("织机")
            .font(MLBrandFont.zhiji(size: 14))
            .tracking(0.06 * 14)
            .foregroundStyle(MLColor.ink2)
            .padding(.top, 9)
          Text(version)
            .font(.system(size: 13).monospacedDigit())
            .foregroundStyle(MLColor.ink2)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 0)
        .padding(.bottom, 4)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
      }
      Section {
        NavigationLink(value: SettingsRoute.licenses) { RowTitle("开源许可") }
          .surfaceRow()
      }
    }
    .groupedPage("关于", large: false)
    .contentMargins(.top, 0, for: .scrollContent)
    .toolbar {
      ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
    }
  }
}

/// 开源许可: the bundled acknowledgements.
struct LicensesView: View {
  private var text: String {
    guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else { return "" }
    return text
  }

  var body: some View {
    ScrollView {
      Text(text)
        .font(.system(size: 13))
        .foregroundStyle(MLColor.ink2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .textSelection(.enabled)
    }
    .background(MLColor.paper2.dynamicColor.ignoresSafeArea())
    .navigationTitle("开源许可")
    .navigationBarTitleDisplayMode(.inline)
  }
}
