import AppKit
import BestASRAgentAccess
import BestASRDomain
import Combine
import SwiftUI
import UserNotifications

/// 「Claude Code 想读取织机」: its own small window, so it shows whether or not
/// the main window is open, next to a notification (AGENT-CONTRACT §2).
@MainActor
final class AgentRequestPanelController {
  private var panel: NSPanel?
  private weak var model: AgentAccessModel?
  private var observer: AnyCancellable?

  init(model: AgentAccessModel) {
    self.model = model
    // Closes once every request is answered (here or from a notification).
    observer = model.$consents.combineLatest(model.$approvals).sink {
      [weak self] consents, approvals in
      if consents.isEmpty, approvals.isEmpty { self?.close() }
    }
  }

  func show() {
    guard let model else { return }
    guard !model.consents.isEmpty || !model.approvals.isEmpty else {
      close()
      return
    }
    if panel == nil {
      let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
        styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
        backing: .buffered, defer: false)
      panel.title = "Agent 想读取织机"
      panel.isFloatingPanel = true
      panel.level = .floating
      panel.hidesOnDeactivate = false
      panel.isReleasedWhenClosed = false
      panel.contentView = NSHostingView(
        rootView: AgentRequestsView(model: model, close: { [weak self] in self?.dismiss() }))
      panel.center()
      self.panel = panel
    }
    panel?.orderFrontRegardless()
    panel?.makeKey()
  }

  /// The window's close button: nothing is allowed by closing it.
  func dismiss() {
    model?.dismissAll()
    close()
  }

  func close() {
    panel?.orderOut(nil)
  }

}

struct AgentRequestsView: View {
  @ObservedObject var model: AgentAccessModel
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let consent = model.consents.first {
        AgentConsentForm(
          request: consent.request,
          answer: { answer in model.answer(consent.id, with: answer) }
        )
        .id(consent.id)
      } else if !model.approvals.isEmpty {
        AgentApprovalList(model: model)
      } else {
        Text("没有等你决定的请求。").padding(20)
      }
      Divider()
      HStack {
        let waiting = model.consents.count + model.approvals.count
        if waiting > 1 {
          Text("还有 \(waiting - 1) 个请求").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("以后再说", action: close)
          .accessibilityIdentifier("bestASR.agent.later")
      }
      .padding(12)
    }
    .frame(width: 460)
  }
}

/// The owner's choices: 空间 / 范围 / 权限 / 期限 / 号码 / 读新的一件事时先问我.
struct AgentConsentForm: View {
  let request: AgentConsentRequest
  let answer: (AgentConsentAnswer) -> Void

  private enum RangeChoice: String, CaseIterable, Identifiable {
    case all, ropes, matters
    var id: String { rawValue }
    var title: String {
      switch self {
      case .all: "全部"
      case .ropes: "几条绳"
      case .matters: "几件事"
      }
    }
  }

  @State private var spaces: Set<String> = [AgentSpaceID.personal]
  @State private var range = RangeChoice.all
  @State private var ropes: Set<String> = []
  @State private var matters: Set<String> = []
  @State private var canPropose = false
  @State private var duration = AgentGrantDuration.once
  @State private var showNumbers = false
  @State private var askForNewMatters = false

  private var terms: AgentGrantTerms {
    let scope: AgentScopeRange =
      switch range {
      case .all: .all
      case .ropes: .ropes(ropes)
      case .matters: .matters(matters)
      }
    return AgentGrantTerms(
      spaces: spaces, range: scope, canPropose: canPropose, duration: duration,
      showNumbers: showNumbers, askForNewMatters: askForNewMatters)
  }

  private var canAllow: Bool {
    !spaces.isEmpty
      && (range == .all || (range == .ropes && !ropes.isEmpty)
        || (range == .matters && !matters.isEmpty))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text("「\(request.client.displayName)」想读取织机")
          .font(.title3.bold())
          .accessibilityIdentifier("bestASR.agent.consentTitle")
        Text("程序位置：\(request.client.path)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        Text(
          "签名：\(request.client.signerLabel)"
            + (request.client.script.map { "；运行的脚本：\($0)" } ?? ""))
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        Label {
          Text(
            "它读到的内容会交给它背后的服务处理，通常在做这个 Agent 的公司的服务器上，也就离开了这台 Mac。只给它这次需要的。"
          )
          .font(.callout)
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

        section("空间") {
          ForEach(request.options.spaces, id: \.id) { space in
            Toggle(space.name, isOn: binding(space.id, in: $spaces))
          }
        }
        section("范围") {
          Picker("范围", selection: $range) {
            ForEach(RangeChoice.allCases) { choice in
              Text(choice.title).tag(choice)
                .disabled(choice == .ropes && request.options.ropes.isEmpty)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          if range == .ropes {
            if request.options.ropes.isEmpty {
              Text("还没有绳。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(request.options.ropes, id: \.id) { rope in
              Toggle(rope.title, isOn: binding(rope.id, in: $ropes))
            }
          }
          if range == .matters {
            ScrollView {
              VStack(alignment: .leading, spacing: 4) {
                ForEach(request.options.matters) { matter in
                  Toggle(
                    matter.title.isEmpty ? "（没有标题）" : matter.title,
                    isOn: binding(matter.id, in: $matters)
                  )
                  .lineLimit(1)
                }
              }
            }
            .frame(maxHeight: 160)
          }
        }
        section("权限") {
          Picker("权限", selection: $canPropose) {
            Text("只读").tag(false)
            Text("只读 + 可以提建议（写进收件箱）").tag(true)
          }
          .labelsHidden()
        }
        section("期限") {
          Picker("期限", selection: $duration) {
            Text("这一次").tag(AgentGrantDuration.once)
            Text("今天").tag(AgentGrantDuration.today)
            Text("一直").tag(AgentGrantDuration.always)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
        }
        section("号码") {
          Picker("号码", selection: $showNumbers) {
            Text("遮住（默认）").tag(false)
            Text("原样").tag(true)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          if showNumbers {
            Text("手机号、邮箱、证件号、卡号、验证码、密码和密钥会原样交给它。")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
        Toggle("读新的一件事时先问我", isOn: $askForNewMatters)
        Text("每读一件没问过的事，都会先发一条通知让你允许或拒绝。")
          .font(.caption)
          .foregroundStyle(.secondary)
        HStack {
          Button("拒绝", role: .destructive) { answer(.deny) }
            .accessibilityIdentifier("bestASR.agent.deny")
          Spacer()
          Button("允许") { answer(.allow(terms)) }
            .keyboardShortcut(.defaultAction)
            .disabled(!canAllow)
            .accessibilityIdentifier("bestASR.agent.allow")
        }
        .padding(.top, 4)
      }
      .padding(20)
    }
    .frame(maxHeight: 620)
  }

  @ViewBuilder
  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.headline)
      content()
    }
  }

  private func binding(_ id: String, in set: Binding<Set<String>>) -> Binding<Bool> {
    Binding(
      get: { set.wrappedValue.contains(id) },
      set: { on in
        if on { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) }
      })
  }
}

/// "读新的一件事时先问我": one row per matter.
struct AgentApprovalList: View {
  @ObservedObject var model: AgentAccessModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        ForEach(model.approvals) { approval in
          Text("「\(approval.request.client.displayName)」想读这些事")
            .font(.headline)
          ForEach(approval.unanswered) { matter in
            HStack {
              Text(matter.title.isEmpty ? matter.id : matter.title).lineLimit(2)
              Spacer()
              Button("拒绝") {
                model.answer(approval: approval.id, matterID: matter.id, allowed: false)
              }
              Button("允许") {
                model.answer(approval: approval.id, matterID: matter.id, allowed: true)
              }
            }
          }
        }
      }
      .padding(20)
    }
    .frame(maxHeight: 480)
  }
}

// MARK: - Notifications

/// A notification per request, with 允许/拒绝 on a matter approval. The
/// notification names the client and the matter's title only; the owner's
/// own screen.
@MainActor
final class AgentNotifier: NSObject, AgentNotifying, UNUserNotificationCenterDelegate {
  static let consentCategory = "mindloom.agent.consent"
  static let matterCategory = "mindloom.agent.matter"
  static let proposalCategory = "mindloom.agent.proposal"
  static let allowAction = "mindloom.agent.allow"
  static let denyAction = "mindloom.agent.deny"

  private weak var model: AgentAccessModel?
  private var authorized: Bool?
  private let center: UNUserNotificationCenter?

  init(model: AgentAccessModel) {
    self.model = model
    // A process without a bundle (a test host) has no notification center.
    center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    super.init()
    guard let center else { return }
    center.delegate = self
    let allow = UNNotificationAction(identifier: Self.allowAction, title: "允许")
    let deny = UNNotificationAction(
      identifier: Self.denyAction, title: "拒绝", options: [.destructive])
    center.setNotificationCategories([
      UNNotificationCategory(identifier: Self.consentCategory, actions: [], intentIdentifiers: []),
      UNNotificationCategory(
        identifier: Self.matterCategory, actions: [allow, deny], intentIdentifiers: []),
      UNNotificationCategory(identifier: Self.proposalCategory, actions: [], intentIdentifiers: []),
    ])
  }

  private func post(
    _ identifier: String, title: String, body: String, category: String, info: [String: String]
  ) {
    guard let center else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.categoryIdentifier = category
    content.userInfo = info
    let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    Task {
      if authorized == nil {
        authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
      }
      guard authorized == true else { return }
      try? await center.add(request)
    }
  }

  func consentRequested(_ request: AgentConsentRequest) {
    post(
      request.id.uuidString, title: "「\(request.client.displayName)」想读取织机",
      body: "在织机里选择给它看哪些事，或者拒绝。", category: Self.consentCategory,
      info: ["kind": "consent"])
  }

  func mattersRequested(_ request: AgentMatterApprovalRequest) {
    for matter in request.matters {
      post(
        request.id.uuidString + "|" + matter.id,
        title: "「\(request.client.displayName)」想读一件新的事",
        body: matter.title.isEmpty ? "允许或拒绝" : "「\(matter.title)」",
        category: Self.matterCategory,
        info: ["kind": "matter", "approval": request.id.uuidString, "matter": matter.id])
    }
  }

  func proposalArrived(_ proposal: AgentInboxProposal) {
    post(
      proposal.proposalID.uuidString, title: "「\(proposal.clientName)」提了一条建议",
      body: "在 设置 → Agent 的收件箱里决定收下还是不要。", category: Self.proposalCategory,
      info: ["kind": "proposal"])
  }

  func withdraw(_ requestID: UUID) {
    center?.removeDeliveredNotifications(withIdentifiers: [requestID.uuidString])
  }

  func withdraw(_ requestID: UUID, matterID: String) {
    center?.removeDeliveredNotifications(withIdentifiers: [requestID.uuidString + "|" + matterID])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    let info = response.notification.request.content.userInfo
    let kind = info["kind"] as? String
    let approval = (info["approval"] as? String).flatMap(UUID.init(uuidString:))
    let matter = info["matter"] as? String
    let action = response.actionIdentifier
    await MainActor.run {
      guard let model = self.model else { return }
      switch (kind, action) {
      case ("matter", Self.allowAction), ("matter", Self.denyAction):
        if let approval, let matter {
          model.answer(approval: approval, matterID: matter, allowed: action == Self.allowAction)
        }
      case ("proposal", _):
        NSApp.activate(ignoringOtherApps: true)
        model.showAgentSettings = true
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
      default:
        model.present?()
      }
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }
}
