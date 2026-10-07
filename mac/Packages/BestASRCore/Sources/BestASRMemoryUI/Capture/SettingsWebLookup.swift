import MindloomDesign
import SwiftUI

// 设置 › 设备与隐私 › 从网络补充信息 (PRD LOOKUP-001–003, SETUP-003;
// v12/arch/WEBSEARCH.md §4.9). One switch, off by default; search keys are
// optional and pasted once; 「网络活动」 lists every connection without content.

/// What the group shows. The App fills it from `MindloomLookup`.
public struct SettingsWebLookup: Equatable, Sendable {
  /// A search service with a key.
  public struct Service: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// 「可用」「密钥无效」「额度已用完」「无法连接」…
    public let status: String
    public let isProblem: Bool
    /// 「在你的设备之间同步」 or 「储存在这台 Mac 上」.
    public let detail: String?
    /// The key follows the owner's iCloud Keychain (removing it removes it
    /// from their other devices too).
    public let syncsAcrossDevices: Bool

    public init(
      id: String, name: String, status: String, isProblem: Bool, detail: String?,
      syncsAcrossDevices: Bool = false
    ) {
      self.id = id
      self.name = name
      self.status = status
      self.isProblem = isProblem
      self.detail = detail
      self.syncsAcrossDevices = syncsAcrossDevices
    }
  }

  /// A service the owner can add a key for.
  public struct Choice: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let signUpURL: URL

    public init(id: String, name: String, signUpURL: URL) {
      self.id = id
      self.name = name
      self.signUpURL = signUpURL
    }
  }

  /// One line of 「网络活动」.
  public struct Activity: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let time: String
    public let what: String
    public let host: String
    public let result: String
    public let size: String
    public let notSent: Bool

    public init(
      id: UUID, time: String, what: String, host: String, result: String, size: String,
      notSent: Bool
    ) {
      self.id = id
      self.time = time
      self.what = what
      self.host = host
      self.result = result
      self.size = size
      self.notSent = notSent
    }
  }

  /// Where adding a key stands.
  public enum KeyCheck: Equatable, Sendable {
    case checking
    case added
    case failed(String)
  }

  public var enabled = false
  public var services: [Service] = []
  public var choices: [Choice] = []
  public var activity: [Activity] = []
  /// 「最近 7 天连接 12 次」.
  public var summary: String?
  public var keyCheck: KeyCheck?

  public init() {}
}

/// The 「从网络补充信息」 group of 设备与隐私.
struct SettingsWebLookupGroup: View {
  let state: SettingsWebLookup
  let actions: MindloomSettingsActions
  @State private var adding = false
  @State private var showingActivity = false
  /// The service whose key the owner asked to remove (confirmed first: a
  /// removed key comes back only by pasting it again).
  @State private var removing: SettingsWebLookup.Service?

  var body: some View {
    SettingsGroup(footer: state.enabled ? SettingsWebLookupText.footer : nil) {
      SettingsRow("globe", "从网络补充信息", detail: SettingsWebLookupText.detail) {
        SettingsSwitch(title: "从网络补充信息", isOn: state.enabled) { on in
          actions.setWebLookup(on)
        }
      }
      if state.enabled {
        ForEach(state.services) { service in
          SettingsSeparator(leading: 44)
          SettingsRow("magnifyingglass", service.name, detail: service.detail) {
            HStack(spacing: 12) {
              Text(service.status).mlFont(\.control)
                .foregroundStyle(service.isProblem ? MLColor.alert : MLColor.ink2)
              Button("移除…") { removing = service }
                .buttonStyle(MLButtonStyle(.standard, small: true))
            }
          }
        }
        SettingsSeparator(leading: 44)
        SettingsRow(
          state.services.isEmpty ? "magnifyingglass" : nil,
          state.services.isEmpty ? "搜索服务" : "添加另一个搜索服务",
          detail: state.services.isEmpty ? SettingsWebLookupText.searchDetail : nil
        ) {
          Button("添加密钥…") { adding = true }
            .buttonStyle(MLButtonStyle(state.services.isEmpty ? .tinted : .standard, small: true))
        }
        SettingsSeparator(leading: 44)
        SettingsRow("list.bullet.rectangle", "网络活动", detail: state.summary) {
          Button("显示…") { showingActivity = true }
            .buttonStyle(MLButtonStyle(.standard, small: true))
        }
      }
    }
    .sheet(isPresented: $adding) {
      SearchKeySheet(state: state, actions: actions) { adding = false }
    }
    .sheet(isPresented: $showingActivity) {
      NetworkActivitySheet(state: state, clear: actions.clearNetworkActivity) {
        showingActivity = false
      }
    }
    .confirmationDialog(
      SettingsWebLookupText.removeTitle(removing?.name ?? ""),
      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
      titleVisibility: .visible, presenting: removing
    ) { service in
      Button("移除", role: .destructive) { actions.removeSearchKey(service.id) }
      Button("取消", role: .cancel) {}
    } message: { service in
      Text(
        service.syncsAcrossDevices
          ? "密钥将从你的所有设备上移除。要再次使用这个服务，请重新粘贴密钥。"
          : "这台 Mac 上的密钥将被移除。要再次使用这个服务，请重新粘贴密钥。")
    }
  }
}

enum SettingsWebLookupText {
  static let detail = "打开后，Mindloom 会为事情查找缺少的公开信息，例如会议截止日期和论文信息。"
  static let footer = "查找时发送公开名称、年份和固定说法，例如“NeurIPS 2026 deadline”。每次连接都记录在“网络活动”中。"
  static let searchDetail = "添加搜索服务的密钥后，还可以查找产品规格、公开通知等信息。"

  /// 「移除 Brave 的密钥？」「移除百度千帆的密钥？」: a space between Han and
  /// Latin text, as in Apple's zh-Hans.
  static func removeTitle(_ name: String) -> String {
    let latinStart = name.first.map { $0.isASCII } ?? false
    let latinEnd = name.last.map { $0.isASCII } ?? false
    return "移除" + (latinStart ? " " : "") + name + (latinEnd ? " " : "") + "的密钥？"
  }
}

/// 添加密钥: choose the service (preselected from the key's shape), paste,
/// 添加. The key is checked once with a fixed public word before it is kept.
struct SearchKeySheet: View {
  let state: SettingsWebLookup
  let actions: MindloomSettingsActions
  let close: () -> Void
  @State private var service: String
  @State private var key = ""
  @State private var submitted = false
  @FocusState private var focused: Bool
  @Environment(\.openURL) private var openURL

  init(state: SettingsWebLookup, actions: MindloomSettingsActions, close: @escaping () -> Void) {
    self.state = state
    self.actions = actions
    self.close = close
    _service = State(initialValue: state.choices.first?.id ?? "")
  }

  private var checking: Bool { submitted && state.keyCheck == .checking }

  private var failure: String? {
    guard submitted, case .failed(let message) = state.keyCheck else { return nil }
    return message
  }

  var body: some View {
    MindloomSheetChrome(width: 440, drawsCard: false) {
      Text("添加搜索服务密钥").mlFont(\.title2).foregroundStyle(MLColor.ink)
        .padding(.bottom, 14)
      HStack(spacing: 10) {
        Text("服务").mlFont(\.control).foregroundStyle(MLColor.ink2).frame(
          width: 40, alignment: .leading)
        Picker("服务", selection: $service) {
          ForEach(state.choices) { choice in Text(choice.name).tag(choice.id) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        Spacer(minLength: 0)
        if let choice = state.choices.first(where: { $0.id == service }) {
          Button("获取密钥…") { openURL(choice.signUpURL) }
            .buttonStyle(.plain).mlFont(\.foot).foregroundStyle(MLColor.accent)
        }
      }
      HStack(spacing: 10) {
        Text("密钥").mlFont(\.control).foregroundStyle(MLColor.ink2).frame(
          width: 40, alignment: .leading)
        SecureField("粘贴密钥", text: $key)
          .textFieldStyle(.plain)
          .mlFont(\.control)
          .focused($focused)
          .padding(.horizontal, 10)
          .frame(height: 30)
          .background(MLColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(
              MLColor.rule2, lineWidth: 0.5)
          )
          .accessibilityLabel("密钥")
          .onSubmit(add)
          .onChange(of: key) { _, value in
            if let likely = actions.likelySearchService(value) { service = likely }
          }
      }
      .padding(.top, 8)
      Text(failure ?? "添加时，Mindloom 会用一个公开的词查找一次，以验证密钥。")
        .mlFont(\.foot).foregroundStyle(failure == nil ? MLColor.ink2 : MLColor.alert)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 8)
      HStack(spacing: 8) {
        if checking {
          ProgressView().controlSize(.small)
          Text("正在验证…").mlFont(\.foot).foregroundStyle(MLColor.ink2)
        }
        Spacer(minLength: 0)
        Button("取消", action: close)
          .buttonStyle(MLButtonStyle(.standard))
          .keyboardShortcut(.cancelAction)
        Button("添加", action: add)
          .buttonStyle(MLButtonStyle(.primary))
          .keyboardShortcut(.defaultAction)
          .disabled(
            key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || service.isEmpty
              || checking)
      }
      .padding(.top, 20)
    }
    .onAppear { focused = true }
    .onChange(of: state.keyCheck) { _, check in
      if submitted, check == .added { close() }
    }
  }

  private func add() {
    let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, !service.isEmpty, !checking else { return }
    submitted = true
    actions.addSearchKey(service, clean)
  }
}

/// 网络活动: every connection, newest first.
struct NetworkActivitySheet: View {
  let state: SettingsWebLookup
  let clear: @MainActor () -> Void
  let close: () -> Void
  @State private var confirmClear = false

  var body: some View {
    MindloomSheetChrome(width: 560, drawsCard: false) {
      Text("网络活动").mlFont(\.title2).foregroundStyle(MLColor.ink)
      Text("每次连接的时间、内容类型、服务器、大小和结果，保留 90 天。")
        .mlFont(\.foot).foregroundStyle(MLColor.ink2)
        .padding(.top, 4).padding(.bottom, 12)
      if state.activity.isEmpty {
        Text("没有网络活动").mlFont(\.control).foregroundStyle(MLColor.ink2)
          .frame(maxWidth: .infinity, minHeight: 80)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(Array(state.activity.enumerated()), id: \.element.id) { index, line in
              if index > 0 { Divider() }
              HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(line.time).mlFont(\.foot).foregroundStyle(MLColor.ink2).frame(
                  width: 92, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                  Text(line.what).mlFont(\.control).foregroundStyle(MLColor.ink)
                  Text(line.host).mlFont(\.foot).foregroundStyle(MLColor.ink2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(line.size).mlFont(\.foot).foregroundStyle(MLColor.ink2)
                Text(line.result).mlFont(\.foot)
                  .foregroundStyle(line.notSent ? MLColor.alert : MLColor.ink2)
                  .frame(width: 56, alignment: .trailing)
              }
              .padding(.vertical, 7)
              .accessibilityElement(children: .combine)
            }
          }
        }
        .frame(height: 320)
      }
      HStack(spacing: 8) {
        Button("清除记录…") { confirmClear = true }
          .buttonStyle(MLButtonStyle(.plain))
          .disabled(state.activity.isEmpty)
        Spacer(minLength: 0)
        Button("完成", action: close)
          .buttonStyle(MLButtonStyle(.primary))
          .keyboardShortcut(.defaultAction)
      }
      .padding(.top, 16)
    }
    .confirmationDialog("清除网络活动记录？", isPresented: $confirmClear, titleVisibility: .visible) {
      Button("清除", role: .destructive) { clear() }
      Button("取消", role: .cancel) {}
    } message: {
      Text("这台设备上的网络活动记录将被清除。")
    }
  }
}
