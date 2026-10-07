import MindloomDesign
import SwiftUI

/// Settings › 入口 › 腾讯会议 (ENTRY-013): one switch, one status line, the
/// QR code while connecting, the first question, and the meetings that need
/// the owner. Plain values; the App fills them from the entry's state.
public struct SettingsTencentMeeting: Equatable, Sendable {
  public enum Connecting: Equatable, Sendable {
    /// Waiting for Tencent's address.
    case starting
    /// The QR code is shown (the authorization address).
    case code(URL)
    case expired
    case failed(String)
  }

  public struct Row: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    /// 「10月2日」.
    public let date: String
    /// 「申请查看…」, 「需要密码」, 「这场会没有转写文字」, 「未能添加，稍后将重试」.
    public let label: String
    /// The row opens the recording's page on meeting.tencent.com.
    public let opensPage: Bool

    public init(id: String, title: String, date: String, label: String, opensPage: Bool) {
      self.id = id
      self.title = title
      self.date = date
      self.label = label
      self.opensPage = opensPage
    }
  }

  public struct Question: Equatable, Sendable {
    public let title: String
    public let message: String

    public init(title: String, message: String) {
      self.title = title
      self.message = message
    }
  }

  public var isOn: Bool
  public var status: String
  public var statusIsProblem: Bool
  /// 「连接…」, 「重新连接…」, 「进一步了解…」 or 「重试」.
  public var actionTitle: String?
  /// The list's title: 「有 2 个会议需要申请查看」 (by meeting), else
  /// 「有 1 个会议的转写尚未添加」 or 「有 3 个会议没有转写文字」.
  public var permissionLine: String?
  public var rows: [Row]
  /// 「腾讯会议未列出 1 个会议的全部录制」.
  public var incompleteLine: String?
  public var connecting: Connecting?
  public var question: Question?
  public var working: Bool

  public init(
    isOn: Bool, status: String, statusIsProblem: Bool = false, actionTitle: String? = nil,
    permissionLine: String? = nil, rows: [Row] = [], incompleteLine: String? = nil,
    connecting: Connecting? = nil, question: Question? = nil, working: Bool = false
  ) {
    self.isOn = isOn
    self.status = status
    self.statusIsProblem = statusIsProblem
    self.actionTitle = actionTitle
    self.permissionLine = permissionLine
    self.rows = rows
    self.incompleteLine = incompleteLine
    self.connecting = connecting
    self.question = question
    self.working = working
  }

  public static let title = "腾讯会议"
  public static let switchTitle = "自动添加会议转写"
  public static let footer =
    "会议结束后，自动添加你的腾讯会议账户可以查看的会议转写，包括其他人主持并向你共享转写的会议。连接储存在这台 Mac 上；关闭后，这台 Mac 上的腾讯会议登录会被移除。"
}

/// What the group can do (the App wires each).
public struct SettingsTencentMeetingActions {
  public var setOn: @MainActor (Bool) -> Void = { _ in }
  /// The status line's button.
  public var act: @MainActor () -> Void = {}
  public var openInBrowser: @MainActor () -> Void = {}
  public var cancelConnecting: @MainActor () -> Void = {}
  public var retryConnecting: @MainActor () -> Void = {}
  public var answer: @MainActor (_ add: Bool) -> Void = { _ in }
  public var checkNow: @MainActor () -> Void = {}
  public var openRow: @MainActor (_ id: String) -> Void = { _ in }

  public init() {}
}

struct SettingsTencentMeetingGroup: View {
  let meeting: SettingsTencentMeeting
  let qr: CGImage?
  let actions: SettingsTencentMeetingActions
  @State private var listOpen = false

  var body: some View {
    SettingsGroup(SettingsTencentMeeting.title, footer: SettingsTencentMeeting.footer) {
      SettingsRow("person.3", SettingsTencentMeeting.switchTitle, detail: meeting.status) {
        SettingsSwitch(title: SettingsTencentMeeting.switchTitle, isOn: meeting.isOn) { on in
          actions.setOn(on)
        }
      }
      if meeting.isOn {
        if let connecting = meeting.connecting {
          SettingsSeparator()
          connectBlock(connecting)
        } else if let title = meeting.actionTitle {
          SettingsSeparator()
          HStack {
            Spacer()
            Button(title) { actions.act() }
              .buttonStyle(MLButtonStyle(.tinted, small: true))
          }
          .padding(.horizontal, 12).padding(.vertical, 8)
        } else {
          SettingsSeparator()
          HStack {
            if meeting.working { ProgressView().controlSize(.small) }
            Spacer()
            Button("现在检查") { actions.checkNow() }
              .buttonStyle(MLButtonStyle(.standard, small: true))
              .disabled(meeting.working)
          }
          .padding(.horizontal, 12).padding(.vertical, 8)
        }
        if let question = meeting.question {
          SettingsSeparator()
          VStack(alignment: .leading, spacing: 6) {
            Text(question.title).mlFont(\.control).foregroundStyle(MLColor.ink)
            Text(question.message).mlFont(\.foot).foregroundStyle(MLColor.ink2)
              .fixedSize(horizontal: false, vertical: true)
            HStack {
              Spacer()
              Button("不添加") { actions.answer(false) }
                .buttonStyle(MLButtonStyle(.standard, small: true))
              Button("添加") { actions.answer(true) }
                .buttonStyle(MLButtonStyle(.tinted, small: true))
            }
          }
          .padding(.horizontal, 12).padding(.vertical, 10)
        }
        if !meeting.rows.isEmpty {
          SettingsSeparator()
          VStack(alignment: .leading, spacing: 6) {
            DisclosureLink(
              title: meeting.permissionLine ?? "会议", open: listOpen
            ) { listOpen.toggle() }
            if listOpen {
              ForEach(meeting.rows) { row in
                HStack(spacing: 8) {
                  Text(row.title).mlFont(\.control).foregroundStyle(MLColor.ink).lineLimit(1)
                  Text(row.date).mlFont(\.foot).foregroundStyle(MLColor.ink2)
                  Spacer()
                  if row.opensPage {
                    Button(row.label) { actions.openRow(row.id) }
                      .buttonStyle(MLButtonStyle(.standard, small: true))
                  } else {
                    Text(row.label).mlFont(\.foot).foregroundStyle(MLColor.ink2)
                  }
                }
              }
            }
          }
          .padding(.horizontal, 12).padding(.vertical, 10)
        }
        if let incomplete = meeting.incompleteLine {
          SettingsSeparator()
          Text(incomplete).mlFont(\.foot).foregroundStyle(MLColor.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
      }
    }
  }

  @ViewBuilder
  private func connectBlock(_ connecting: SettingsTencentMeeting.Connecting) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      switch connecting {
      case .starting, .code:
        PairingQRBlock(
          image: qr, title: "连接腾讯会议",
          detail: "用 iPhone 的相机扫描二维码，在手机上登录腾讯会议并允许。也可以在这台 Mac 的浏览器中打开，用腾讯会议 App 扫描网页上的二维码。",
          label: "腾讯会议登录二维码")
        HStack {
          Spacer()
          Button("取消") { actions.cancelConnecting() }
            .buttonStyle(MLButtonStyle(.standard, small: true))
          Button("在浏览器中打开") { actions.openInBrowser() }
            .buttonStyle(MLButtonStyle(.tinted, small: true))
            .disabled(qr == nil)
        }
      case .expired, .failed:
        Text(connecting == .expired ? "二维码已过期" : failure(connecting))
          .mlFont(\.control).foregroundStyle(MLColor.ink)
        HStack {
          Spacer()
          Button("取消") { actions.cancelConnecting() }
            .buttonStyle(MLButtonStyle(.standard, small: true))
          Button("重试") { actions.retryConnecting() }
            .buttonStyle(MLButtonStyle(.tinted, small: true))
        }
      }
    }
    .padding(.horizontal, 12).padding(.vertical, 10)
  }

  private func failure(_ connecting: SettingsTencentMeeting.Connecting) -> String {
    if case .failed(let text) = connecting { return text }
    return ""
  }
}
