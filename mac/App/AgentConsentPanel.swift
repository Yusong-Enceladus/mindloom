import AppKit
import BestASRAgentAccess
import BestASRDomain
import BestASRMemoryUI
import Combine
import LocalAuthentication
import MindloomDesign
import SwiftUI
import UserNotifications

// OWNER: mac-capture. The consent panel (MAC-SPEC §11; v12 phase B, B5
// appendix C F2–F4, F9, F11): a floating panel above everything, 170 pt below
// the menu bar and centred, with the package's `AgentConsentView`. It does
// not take the keyboard when it appears (keys typed into the agent's own
// window stay there); clicking it makes it key, and then Esc puts it away
// and refuses nothing. One request at a time; a notification goes with it.

/// The floating panel. It can become key when clicked, never main.
final class AgentConsentWindow: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class AgentRequestPanelController {
  private var panel: AgentConsentWindow?
  private weak var model: AgentAccessModel?
  /// The panel, when it is on screen (the Preview's live verification run).
  var window: NSWindow? { panel?.isVisible == true ? panel : nil }
  private var observer: AnyCancellable?

  init(model: AgentAccessModel) {
    self.model = model
    // Closes once every request is answered (here or from a notification),
    // or when the owner put it away.
    observer = model.$consents.combineLatest(model.$approvals, model.$requestsHidden).sink {
      [weak self] consents, approvals, hidden in
      if hidden || (consents.isEmpty && approvals.isEmpty) { self?.close() }
    }
  }

  func show() {
    guard let model else { return }
    guard !model.consents.isEmpty || !model.approvals.isEmpty, !model.requestsHidden else {
      close()
      return
    }
    if panel == nil {
      let panel = AgentConsentWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false)
      panel.isFloatingPanel = true
      panel.level = .statusBar
      panel.hidesOnDeactivate = false
      panel.isReleasedWhenClosed = false
      panel.backgroundColor = .clear
      panel.isOpaque = false
      panel.hasShadow = false
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      let host = NSHostingView(
        rootView: AgentRequestsView(model: model, hide: { [weak self] in self?.hide() })
          .mlNoAutospace())
      host.sizingOptions = [.intrinsicContentSize]
      panel.contentView = host
      self.panel = panel
    }
    place()
    // Shown, not made key (F11): typing in the agent's window goes on there.
    panel?.orderFrontRegardless()
  }

  /// Horizontally centred on the screen with the pointer, its card 170 pt
  /// below the menu bar.
  private func place() {
    guard let panel else { return }
    panel.layoutIfNeeded()
    let size = panel.contentView?.fittingSize ?? panel.frame.size
    let mouse = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
    guard let screen else { return }
    let top = screen.visibleFrame.maxY - 170 + AgentRequestsView.margin
    panel.setFrame(
      NSRect(
        x: (screen.frame.midX - size.width / 2).rounded(), y: (top - size.height).rounded(),
        width: size.width, height: size.height), display: true)
  }

  /// Esc: put away; nothing is answered (F11).
  func hide() {
    model?.hideRequests()
    close()
  }

  func close() {
    panel?.orderOut(nil)
  }
}

/// The first waiting request as the consent card.
struct AgentRequestsView: View {
  /// Room around the card for its shadow.
  static let margin: CGFloat = 20
  @ObservedObject var model: AgentAccessModel
  let hide: () -> Void

  var body: some View {
    Group {
      if let consent = model.consents.first {
        AgentConsentView(input: Self.input(consent.request)) { choice in
          Self.decide(choice, consent: consent, model: model)
        }
        .id(consent.id)
      } else if let approval = model.approvals.first,
        let matter = approval.unanswered.first
      {
        AgentApprovalCard(
          appName: approval.request.client.displayName, whoLine: approval.request.client.whoLine,
          matterTitle: MindloomTitles.shared.matter(matter.id) ?? matter.title
        ) { allowed in
          model.answer(approval: approval.id, matterID: matter.id, allowed: allowed)
        }
        .id(approval.id.uuidString + matter.id)
      }
    }
    .padding(Self.margin)
    .environment(\.colorScheme, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light)
    .onExitCommand(perform: hide)
  }

  static func input(_ request: AgentConsentRequest) -> AgentConsentInput {
    let matter = request.requestedMatter
    let group = matter.flatMap { MindloomTitles.shared.groupOfMatter[$0.id.uppercased()] }
    return AgentConsentInput(
      appName: request.client.displayName, whoLine: request.client.whoLine,
      lookalikePath: request.lookalike?.path,
      matterTitle: matter.map { MindloomTitles.shared.matter($0.id) ?? $0.title } ?? "",
      groupName: group.flatMap { MindloomTitles.shared.groups[$0] },
      matterChoices: matter == nil
        ? request.options.matters.prefix(6).map {
          .init(id: $0.id, title: MindloomTitles.shared.matter($0.id) ?? $0.title)
        } : [],
      spaces: request.options.spaces.filter { $0.id != AgentSpaceID.personal }.map {
        .init(id: $0.id, title: $0.name)
      },
      appBundlePath: bundlePath(request.client.executable),
      wantsToChange: request.wantsToChange)
  }

  /// 允许 with 一直, 全部 or 也可以改 asks for Touch ID or the login password
  /// first (F9); a program that clicks the screen cannot pass it.
  @MainActor
  static func decide(
    _ choice: AgentConsentChoice?, consent: AgentAccessModel.PendingConsent,
    model: AgentAccessModel
  ) {
    guard let choice else {
      model.answer(consent.id, with: .deny)
      return
    }
    let answer = Self.answer(choice, request: consent.request)
    guard choice.needsOwnerCheck else {
      model.answer(consent.id, with: answer)
      toast(app: consent.request.client.displayName, choice: choice, request: consent.request)
      return
    }
    let context = LAContext()
    context.localizedCancelTitle = "取消"
    let id = consent.id
    let request = consent.request
    let what = choice.all ? "读取所有事" : "读取 Mindloom"
    let reason = "允许 \(request.client.displayName) \(what)\(choice.canChange ? "并进行更改" : "")"
    context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
      Task { @MainActor in
        // Cancelled: the card stays; nothing is answered.
        guard ok else { return }
        model.answer(id, with: answer)
        toast(app: request.client.displayName, choice: choice, request: request)
      }
    }
  }

  /// The App bundle around a client's executable, for its icon.
  static func bundlePath(_ path: String) -> String? {
    var url = URL(fileURLWithPath: path)
    while url.pathComponents.count > 1 {
      if url.pathExtension == "app" { return url.path }
      url.deleteLastPathComponent()
    }
    return nil
  }

  /// The ticks as grant terms (`AgentConsentChoice.terms`): 全部 brings only
  /// the shared spaces ticked on the card (F2; review v12-B #3).
  static func answer(_ choice: AgentConsentChoice, request: AgentConsentRequest)
    -> AgentConsentAnswer
  {
    let requested = request.requestedMatter?.id
    return .allow(
      choice.terms(
        requestedMatterID: requested,
        groupOfRequestedMatter: requested.flatMap {
          MindloomTitles.shared.groupOfMatter[$0.uppercased()]
        }))
  }

  /// 「已允许 {app} 读「{what}」 · {这次对话|今天|一直}」.
  static func toast(app: String, choice: AgentConsentChoice, request: AgentConsentRequest) {
    let what: String =
      choice.all
      ? "所有事"
      : request.requestedMatter.map { "“\(MLAutospace.apply($0.title))”" }
        ?? "\(choice.matterIDs.count) 件事"
    CaptureFeedback.shared.show(
      MemoryToast(
        "已允许 \(app) 读取\(what) · \(choice.duration.title)\(choice.canChange ? " · 允许更改" : "")",
        icon: .symbol("checkmark")))
  }
}

/// A notification per request and per change. The notification names the
/// App, and for a change the one-line summary; the owner's own screen.
@MainActor
final class AgentNotifier: NSObject, AgentNotifying, UNUserNotificationCenterDelegate {
  static let consentCategory = "mindloom.agent.consent"
  static let matterCategory = "mindloom.agent.matter"
  static let changeCategory = "mindloom.agent.change"
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
      identifier: Self.denyAction, title: "不允许", options: [.destructive])
    center.setNotificationCategories([
      UNNotificationCategory(identifier: Self.consentCategory, actions: [], intentIdentifiers: []),
      UNNotificationCategory(
        identifier: Self.matterCategory, actions: [allow, deny], intentIdentifiers: []),
      UNNotificationCategory(identifier: Self.changeCategory, actions: [], intentIdentifiers: []),
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
      request.id.uuidString, title: "“\(request.client.displayName)”请求读取 Mindloom 中的事",
      body: "点按以选择允许它读取的内容。", category: Self.consentCategory,
      info: ["kind": "consent"])
  }

  func mattersRequested(_ request: AgentMatterApprovalRequest) {
    for matter in request.matters {
      post(
        request.id.uuidString + "|" + matter.id,
        title: "“\(request.client.displayName)”请求读取一件事",
        body: matter.title.isEmpty ? "允许或不允许" : "“\(matter.title)”",
        category: Self.matterCategory,
        info: ["kind": "matter", "approval": request.id.uuidString, "matter": matter.id])
    }
  }

  func changeMade(_ change: AgentChangeRecord) {
    post(
      change.changeID.uuidString, title: "“\(change.clientName)”更改了 Mindloom",
      body: change.summary + "。点按以查看，可以撤销。", category: Self.changeCategory,
      info: ["kind": "change", "client": change.clientKey])
  }

  func limitReached(_ clientName: String) {
    post(
      "limit-" + clientName, title: "“\(clientName)”在一小时内访问次数过多，已暂停",
      body: "稍后它可以继续访问；也可以在“设置”>“其他 App”中停止允许。", category: Self.changeCategory,
      info: ["kind": "limit"])
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
    let client = info["client"] as? String
    let action = response.actionIdentifier
    await MainActor.run {
      guard let model = self.model else { return }
      switch (kind, action) {
      case ("matter", Self.allowAction), ("matter", Self.denyAction):
        if let approval, let matter {
          model.answer(approval: approval, matterID: matter, allowed: action == Self.allowAction)
        }
      case ("change", _), ("limit", _):
        model.openApp = client
        SettingsRouter.shared.open(.apps)
      default:
        model.showRequests()
      }
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }
}
