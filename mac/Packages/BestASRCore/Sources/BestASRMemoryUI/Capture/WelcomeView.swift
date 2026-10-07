import MindloomDesign
import SwiftUI

// OWNER: mac-capture. S17 · Welcome (MAC-SPEC §10): a 680 × 600 window with
// three steps — the title cinch (the stacked lockup tightening, the word
// wiped in, the current tagline (docs/TAGLINES.md, docs/UI-COPY.md §4), 开始), permissions (麦克风, 设备控制和数据访问,
// and the preview's 识别模型), devices (DGX Spark, iPhone with the QR) — and
// the three dots.

/// The welcome window's words that are fixed product copy.
public enum WelcomeCopy {
  /// The permissions step's sentence.
  public static let permissionsText = "说出的内容会输入到光标所在位置，并添加到 Mindloom。声音在这台 Mac 上转写。"
  /// The same step after the switch from bestASR: macOS knows Mindloom as a
  /// new App, so both permissions are asked again (2026-10-06).
  public static let permissionsTextAfterBestASR =
    "从 bestASR 换到 Mindloom 后，需要重新允许下面两项。说出的内容会输入到光标所在位置，声音在这台 Mac 上转写。"

  /// The permissions step's title. Not 「按住 fn 说话」: fn does not dictate
  /// while Welcome is open, and the title must not invite trying it (review
  /// of 10-6).
  public static let permissionsTitle = "设置口述"

  /// Under the permissions step's cards: what fn does once Welcome is done,
  /// or plainly that it does nothing without 设备控制和数据访问 (Welcome's
  /// 继续 does not wait for it; the main window and the menu bar keep
  /// saying so until it is allowed).
  public static func fnLine(accessibilityOn: Bool) -> String {
    accessibilityOn
      ? "完成欢迎设置后，按住 fn 键即可口述。"
      : "未允许“设备控制和数据访问”时，按住 fn 键不能口述。也可以以后在菜单栏中允许。"
  }

  /// The devices step's sentence: with the DGX Spark card, or without it
  /// when this library may not be sent to a DGX Spark (no Spark named, or a
  /// release that keeps the owner's library on this Mac; review of 10-6).
  public static func devicesText(sparkAvailable: Bool) -> String {
    sparkAvailable
      ? "转写的文字会发送到你的 DGX\u{00A0}Spark，整理成一件件事；发送前隐藏手机号和证件号。声音和词典储存在这台 Mac 上。"
      : "在 iPhone 上口述和分享的内容会发送到这台 Mac。声音和词典储存在这台 Mac 上。"
  }
}

public enum WelcomeStep: Int, CaseIterable, Sendable {
  case title
  case permissions
  case devices
}

/// The preview's model card (「使用这台 Mac 上已装的识别模型」).
public enum WelcomeModels: Equatable, Sendable {
  case offered
  case working
  case ready
  case failed(String)
}

public struct WelcomeInput: Equatable, Sendable {
  public var step: WelcomeStep
  public var microphoneOn: Bool
  public var accessibilityOn: Bool
  public var sparkConnected: Bool
  /// A DGX Spark the link knows how to reach (「在同一个网络里找到了 1 台」).
  public var sparkFound: Bool
  /// Connecting right now.
  public var sparkConnecting: Bool
  /// The paired iPhone's name, if any.
  public var iphoneName: String?
  /// The pairing QR is open in the iPhone card.
  public var qrShown: Bool
  /// The preview's model card; nil hides it.
  public var models: WelcomeModels?
  /// The owner came from bestASR (its settings were imported): the
  /// permissions are asked again, and the step says so.
  public var fromBestASR: Bool
  /// This library may be sent to a DGX Spark from here: otherwise the
  /// devices step has no Spark card (review of 10-6).
  public var sparkAvailable: Bool
  /// Seconds since step 0 appeared (the cinch is a function of time; a still
  /// image passes the frame it wants, nil = settled).
  public var time: Double?
  /// The tagline under the lockup (docs/TAGLINES.md): the App passes the
  /// current line, picked as the window opened; nil (still images) is the line
  /// a new install shows first.
  public var tagline: MindloomTagline?

  public init(
    step: WelcomeStep = .title, microphoneOn: Bool = false, accessibilityOn: Bool = false,
    sparkConnected: Bool = false, sparkFound: Bool = true, sparkConnecting: Bool = false,
    iphoneName: String? = nil, qrShown: Bool = false, models: WelcomeModels? = nil,
    fromBestASR: Bool = false, sparkAvailable: Bool = true, time: Double? = nil,
    tagline: MindloomTagline? = nil
  ) {
    self.step = step
    self.microphoneOn = microphoneOn
    self.accessibilityOn = accessibilityOn
    self.sparkConnected = sparkConnected
    self.sparkFound = sparkFound
    self.sparkConnecting = sparkConnecting
    self.iphoneName = iphoneName
    self.qrShown = qrShown
    self.models = models
    self.fromBestASR = fromBestASR
    self.sparkAvailable = sparkAvailable
    self.time = time
    self.tagline = tagline
  }
}

/// What Welcome can do (the App wires the real permission prompts, the link
/// and the pairing code).
public struct WelcomeActions {
  public var setStep: @MainActor (WelcomeStep) -> Void
  public var allowMicrophone: @MainActor () -> Void
  public var allowAccessibility: @MainActor () -> Void
  public var importModels: @MainActor () -> Void
  public var connectSpark: @MainActor () -> Void
  public var toggleQR: @MainActor () -> Void
  /// 完成 / 以后再说: closes Welcome and opens the main window.
  public var finish: @MainActor () -> Void
  /// The pairing QR while it is open.
  public var qr: CGImage?

  public init(
    setStep: @escaping @MainActor (WelcomeStep) -> Void = { _ in },
    allowMicrophone: @escaping @MainActor () -> Void = {},
    allowAccessibility: @escaping @MainActor () -> Void = {},
    importModels: @escaping @MainActor () -> Void = {},
    connectSpark: @escaping @MainActor () -> Void = {},
    toggleQR: @escaping @MainActor () -> Void = {},
    finish: @escaping @MainActor () -> Void = {}, qr: CGImage? = nil
  ) {
    self.setStep = setStep
    self.allowMicrophone = allowMicrophone
    self.allowAccessibility = allowAccessibility
    self.importModels = importModels
    self.connectSpark = connectSpark
    self.toggleQR = toggleQR
    self.finish = finish
    self.qr = qr
  }
}

public struct WelcomeView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.zhijiSnapshot) private var snapshot
  let input: WelcomeInput
  let actions: WelcomeActions

  public init(input: WelcomeInput, actions: WelcomeActions = WelcomeActions()) {
    self.input = input
    self.actions = actions
  }

  public var body: some View {
    ZStack {
      Rectangle().fill(MLColor.paper)
      Group {
        switch input.step {
        case .title: WelcomeTitleStep(input: input, actions: actions)
        case .permissions: WelcomePermissionsStep(input: input, actions: actions)
        case .devices: WelcomeDevicesStep(input: input, actions: actions)
        }
      }
      .padding(.horizontal, 64)
      .padding(.bottom, 24)
      .id(input.step)
      .transition(.opacity)
      VStack {
        Spacer()
        HStack(spacing: 8) {
          ForEach(WelcomeStep.allCases, id: \.self) { step in
            Circle().fill(step == input.step ? MLColor.ink2 : MLColor.ink4)
              .frame(width: 6, height: 6)
          }
        }
        .padding(.bottom, 26)
        .accessibilityHidden(true)
      }
    }
    .frame(width: 680, height: 600)
    .foregroundStyle(MLColor.ink)
    .environment(\.mlPlatform, .mac)
    .overlay(alignment: .topLeading) { WelcomeTrafficLights() }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("欢迎使用 Mindloom")
  }
}

/// Step 0: the lockup cinches (M1–M3), then the tagline (M4, 1.30 s) and
/// 开始 (M5, 1.46 s) fade in.
struct WelcomeTitleStep: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.zhijiSnapshot) private var snapshot
  let input: WelcomeInput
  let actions: WelcomeActions
  @State private var start = Date()

  var body: some View {
    Group {
      if let fixed = input.time ?? (snapshot ? WelcomeCinch.settledAfter : nil) {
        content(at: fixed)
      } else {
        TimelineView(.animation(minimumInterval: nil, paused: false)) { context in
          let t = context.date.timeIntervalSince(start)
          content(at: t)
        }
      }
    }
    .onAppear { start = Date() }
  }

  private func content(at t: Double) -> some View {
    VStack(spacing: 0) {
      WelcomeCinch(cap: 26, time: min(t, WelcomeCinch.settledAfter), reduceMotion: reduceMotion)
      // 17/26: the 44 pt to 开始 is measured from the tagline's 26 pt line
      // box (or from its source's, for a quotation).
      if let line = input.tagline ?? MindloomTaglineBoard.first(interfaceLanguage: "zh-Hans") {
        WelcomeTagline(line: line)
          .padding(.top, 32)
          .opacity(fade(t, at: 1.30, over: 0.36))
      }
      Button {
        actions.setStep(.permissions)
      } label: {
        WideLabel(text: "开始")
      }
      .buttonStyle(MLButtonStyle(.primary))
      .keyboardShortcut(.defaultAction)
        .padding(.top, 44)
        .opacity(fade(t, at: 1.46, over: 0.36))
    }
  }

  private func fade(_ t: Double, at start: Double, over duration: Double) -> Double {
    if reduceMotion { return MLMotion.curveOut(min(1, max(0, t / 0.2))) }
    return MLMotion.curveOut(min(1, max(0, (t - start) / duration)))
  }
}

/// The primary button's minimum width (140) with the label centred.
private struct WideLabel: View {
  let text: String
  var body: some View { Text(text).frame(minWidth: 140 - 28) }
}

/// Step 1: 设置口述 — 麦克风, 设备控制和数据访问 (and the preview's 识别模型),
/// then what fn does once Welcome is done.
struct WelcomePermissionsStep: View {
  let input: WelcomeInput
  let actions: WelcomeActions

  var body: some View {
    VStack(spacing: 0) {
      WelcomeHeading(
        title: WelcomeCopy.permissionsTitle,
        text: input.fromBestASR
          ? WelcomeCopy.permissionsTextAfterBestASR : WelcomeCopy.permissionsText)
      VStack(spacing: 10) {
        WelcomeCard(symbol: "mic", title: "麦克风", detail: "用于录制你的口述") {
          doneOr(input.microphoneOn, done: "已允许", title: "允许", action: actions.allowMicrophone)
        }
        WelcomeCard(
          symbol: "keyboard", title: "设备控制和数据访问", detail: "用于识别 fn 键，并将文字输入到其他 App"
        ) {
          doneOr(
            input.accessibilityOn, done: "已允许", title: "允许", action: actions.allowAccessibility)
        }
        if let models = input.models {
          WelcomeCard(symbol: "waveform", title: "识别模型", detail: modelDetail(models)) {
            switch models {
            case .working: ProgressView().controlSize(.small)
            case .ready: doneOr(true, done: "已就绪", title: "", action: {})
            case .offered, .failed:
              doneOr(false, done: "", title: "使用", action: actions.importModels)
            }
          }
        }
      }
      .frame(width: 460)
      .padding(.top, 28)
      Text(WelcomeCopy.fnLine(accessibilityOn: input.accessibilityOn))
        .mlFont(\.foot)
        .foregroundStyle(input.accessibilityOn ? MLColor.ink2 : MLColor.alert)
        .multilineTextAlignment(.center)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 14)
      Button {
        actions.setStep(.devices)
      } label: {
        WideLabel(text: "继续")
      }
      .buttonStyle(MLButtonStyle(.primary))
      .keyboardShortcut(.defaultAction)
      .padding(.top, 30)
    }
  }

  private func modelDetail(_ models: WelcomeModels) -> String {
    switch models {
    case .failed(let why): why
    case .ready: "声音在这台 Mac 上转写"
    default: "使用这台 Mac 上已安装的识别模型"
    }
  }
}

/// Step 2: 连接你的设备 — DGX Spark (连接) and iPhone (显示二维码).
struct WelcomeDevicesStep: View {
  let input: WelcomeInput
  let actions: WelcomeActions

  var body: some View {
    VStack(spacing: 0) {
      WelcomeHeading(
        title: "连接你的设备",
        text: WelcomeCopy.devicesText(sparkAvailable: input.sparkAvailable))
      VStack(spacing: 10) {
        if input.sparkAvailable {
          WelcomeCard(symbol: "device.box", title: "DGX Spark", detail: sparkDetail) {
            if input.sparkConnecting {
              ProgressView().controlSize(.small)
            } else if input.sparkConnected {
              doneOr(true, done: "已连接", title: "", action: {})
            } else {
              Button("连接") { actions.connectSpark() }
                .buttonStyle(MLButtonStyle(.primary, small: true))
            }
          }
        }
        WelcomeCard(
          symbol: "iphone", title: "iPhone",
          detail: input.iphoneName.map { "已连接 · \($0)" } ?? "在 iPhone 上口述和分享的内容会发送到这台 Mac"
        ) {
          if input.iphoneName != nil {
            doneOr(true, done: "已连接", title: "", action: {})
          } else {
            Button(input.qrShown ? "隐藏二维码" : "显示二维码") { actions.toggleQR() }
              .buttonStyle(MLButtonStyle(.tinted, small: true))
          }
        } more: {
          if input.qrShown, input.iphoneName == nil {
            PairingQRBlock(image: actions.qr)
              .padding(.leading, 42)
              .padding(.top, 8)
              .padding(.bottom, 2)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .frame(width: 460)
      .padding(.top, 28)
      if input.sparkConnected || !input.sparkAvailable {
        Button {
          actions.finish()
        } label: {
          WideLabel(text: "完成")
        }
        .buttonStyle(MLButtonStyle(.primary))
        .keyboardShortcut(.defaultAction)
        .padding(.top, 44)
      } else {
        Button {
          actions.finish()
        } label: {
          Text("以后").foregroundStyle(MLColor.ink2).frame(minWidth: 140 - 16)
        }
        .buttonStyle(MLButtonStyle(.plain))
        .padding(.top, 44)
      }
    }
  }

  private var sparkDetail: String {
    if input.sparkConnected { return "已连接 · 同一网络" }
    return input.sparkFound ? "在同一网络中找到 1 台设备" : "未在同一网络中找到设备"
  }
}

/// A step's title (22/28 600) and its sentence (body, `ink2`, max 420).
struct WelcomeHeading: View {
  let title: String
  let text: String

  var body: some View {
    VStack(spacing: 8) {
      Text(title)
        .mlFont(style: MLTextStyle(size: 22, weight: .semibold, lineHeight: 28), lineBox: true)
        .accessibilityAddTraits(.isHeader)
      BalancedText(text, size: 14, maxWidth: 420, alignment: .center)
        .mlFont(\.body).foregroundStyle(MLColor.ink2)
        .multilineTextAlignment(.center)
    }
  }
}

/// A card: `surface`, radius 12, padding 12 14, gap 14, 0.5 ring; icon 20 in
/// `accent` in a 28 column; title `control`, description `foot` `ink2`; a
/// button at the right; optional content below at full width.
struct WelcomeCard<Trailing: View, More: View>: View {
  let symbol: String
  let title: String
  let detail: String
  let trailing: Trailing
  let more: More

  init(
    symbol: String, title: String, detail: String, @ViewBuilder trailing: () -> Trailing,
    @ViewBuilder more: () -> More
  ) {
    self.symbol = symbol
    self.title = title
    self.detail = detail
    self.trailing = trailing()
    self.more = more()
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        SettingsIcon(symbol: symbol, color: .accent, size: 18).frame(width: 28)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).mlFont(\.control).foregroundStyle(MLColor.ink)
          Text(detail).mlFont(\.foot).foregroundStyle(MLColor.ink2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        trailing
      }
      more
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 14)
    .background(MLColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(
        MLColor.rule, lineWidth: 0.5)
    )
    .accessibilityElement(children: .contain)
  }
}

extension WelcomeCard where More == EmptyView {
  init(symbol: String, title: String, detail: String, @ViewBuilder trailing: () -> Trailing) {
    self.init(
      symbol: symbol, title: title, detail: detail, trailing: trailing, more: { EmptyView() })
  }
}

/// 「打开」 (tinted) until it is done, then 「✓ 已打开」 (standard).
@MainActor @ViewBuilder
func doneOr(_ done: Bool, done doneTitle: String, title: String, action: @escaping @MainActor () -> Void)
  -> some View
{
  if done {
    HStack(spacing: 4) {
      Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
      Text(doneTitle)
    }
    .font(MLTypeScale.mac.controlSmall.font)
    .foregroundStyle(MLColor.accent)
    .padding(.horizontal, 10)
    .frame(height: 22)
    .background(MLColor.fill, in: Capsule())
    .accessibilityElement(children: .combine)
  } else {
    Button(title) { action() }.buttonStyle(MLButtonStyle(.tinted, small: true))
  }
}

/// The traffic lights in a still image.
private struct WelcomeTrafficLights: View {
  @Environment(\.zhijiSnapshot) private var snapshot

  var body: some View {
    if snapshot {
      HStack(spacing: 8) {
        ForEach([MLColor.systemRed, .systemYellow, .systemGreen], id: \.self) { color in
          Circle().fill(color).frame(width: 12, height: 12)
        }
      }
      .padding(.leading, 20)
      .padding(.top, 18)
      .allowsHitTesting(false)
    }
  }
}
