import BestASRDomain
import BestASRMemory
import CoreImage
import CoreImage.CIFilterBuiltins
import MindloomDesign
import MindloomSpaces
import SwiftUI

@testable import BestASRMemoryUI

// OWNER: mac-capture. Scenes for S11, S16–S20, S22 and the spaces' sheets
// (MAC-SPEC §1.2). Synthetic values only (the prototype's lab scenario).

extension V11Scenes {
  @MainActor static var capture: [V11Scene] {
    let welcome = CGSize(width: 680, height: 600)
    let settings = CGSize(width: 780, height: 600)
    let panel = CGSize(width: 560, height: 440)
    let hud = FnHUDGeometry.panelSize
    let menu = CGSize(width: 360, height: 280)
    func settingsScene(
      _ id: String, _ pane: SettingsPane, link: MemoryLinkState? = nil, details: Bool = false,
      qr: Bool = false, scroll: CGFloat = 0, appPage: Bool = false
    ) -> V11Scene {
      V11Scene(id: id, size: settings) { _ in
        AnyView(
          SettingsWindowView(
            state: MindloomSettingsState(
              pane: pane,
              link: link
                ?? MemoryLinkState(
                  status: .connected, lastOrganizedAt: V11Fixture.now.addingTimeInterval(-360)),
              macName: "小林的 MacBook Pro", iphoneName: "小林的 iPhone",
              iphoneDetail: "9月18日起连接 · 最近一次送来 21:58", version: "1.0（10）",
              entries: MindloomSettingsState.defaultEntries,
              agentApps: CaptureFixture.agentApps,
              agentDetail: appPage ? CaptureFixture.agentPage : nil,
              detailsOpen: details, qrShown: qr, snapshotScroll: scroll,
              dictionary: CaptureFixture.dictionary
            ).withAgents(on: true, command: CaptureFixture.agentCommand).withTimeZone(
              SettingsTimeZone(
                current: "Asia/Singapore",
                choices: [
                  .init(id: "Asia/Singapore", label: "新加坡时间（GMT+8）"),
                  .init(id: "America/Los_Angeles", label: "洛杉矶时间（GMT-7）"),
                  .init(id: "Asia/Shanghai", label: "中国大陆时间（GMT+8）"),
                ])),
            snapshotQR: CaptureFixture.qr))
      }
    }
    func sheet(_ id: String, _ build: @escaping @MainActor (V11Fixture.Loaded) -> some View)
      -> V11Scene
    {
      V11Scene(id: id, size: panel) { loaded in
        V11Page.surface { VStack { build(loaded).padding(.top, 40); Spacer() } }
      }
    }
    func hudScene(_ id: String, _ input: FnHUDInput, at time: Double?, release: Double? = nil)
      -> V11Scene
    {
      V11Scene(id: id, size: hud) { _ in
        let model = time.map { CaptureFixture.listener(at: $0, release: release) }
        return AnyView(
          ZStack {
            Rectangle().fill(MLColor.paper)
            FnHUDView(input: input, listener: model, time: time.map { $0 + 100 })
          })
      }
    }
    let recording = MemoryCaptureIndicator(
      kind: .room, title: "正在记录会议", detail: "12:04", elapsed: 724)
    return [
      V11Scene(id: "first-run", size: welcome) { _ in AnyView(WelcomeView(input: WelcomeInput())) },
      // Other days' taglines on the first screen (docs/TAGLINES.md).
      V11Scene(id: "x-first-run-quote", size: welcome) { _ in
        AnyView(WelcomeView(input: WelcomeInput(tagline: MindloomTaglineBoard.line(id: "zh-01"))))
      },
      V11Scene(id: "x-first-run-long", size: welcome) { _ in
        AnyView(WelcomeView(input: WelcomeInput(tagline: MindloomTaglineBoard.line(id: "zh-11"))))
      },
      V11Scene(id: "x-first-run-en", size: welcome) { _ in
        AnyView(WelcomeView(input: WelcomeInput(tagline: MindloomTaglineBoard.line(id: "en-15"))))
      },
      V11Scene(id: "x-first-run-en-quote", size: welcome) { _ in
        AnyView(WelcomeView(input: WelcomeInput(tagline: MindloomTaglineBoard.line(id: "en-12"))))
      },
      V11Scene(id: "x-first-run-en-long", size: welcome) { _ in
        AnyView(WelcomeView(input: WelcomeInput(tagline: MindloomTaglineBoard.line(id: "en-04"))))
      },
      V11Scene(id: "x-first-run-motion", size: welcome) { _ in
        AnyView(WelcomeView(input: WelcomeInput(time: 0.5)))
      },
      V11Scene(id: "x-first-run-1", size: welcome) { _ in
        AnyView(WelcomeView(input: WelcomeInput(time: 0.9)))
      },
      V11Scene(id: "x-first-run-015", size: welcome) { _ in
        AnyView(WelcomeView(input: WelcomeInput(time: 0.15)))
      },
      V11Scene(id: "x-first-run-035", size: welcome) { _ in
        AnyView(WelcomeView(input: WelcomeInput(time: 0.35)))
      },
      V11Scene(id: "x-first-run-12", size: welcome) { _ in
        AnyView(WelcomeView(input: WelcomeInput(time: 1.2)))
      },
      V11Scene(id: "first-run-2", size: welcome) { _ in
        AnyView(WelcomeView(input: WelcomeInput(step: .permissions, microphoneOn: true)))
      },
      V11Scene(id: "x-first-run-2-models", size: welcome) { _ in
        AnyView(
          WelcomeView(input: WelcomeInput(step: .permissions, microphoneOn: true, models: .offered)))
      },
      V11Scene(id: "first-run-3", size: welcome) { _ in
        AnyView(WelcomeView(input: WelcomeInput(step: .devices)))
      },
      // The product on the owner's library: no DGX Spark card (review of 10-6).
      V11Scene(id: "x-first-run-3-no-spark", size: welcome) { _ in
        AnyView(WelcomeView(input: WelcomeInput(step: .devices, sparkAvailable: false)))
      },
      V11Scene(id: "x-first-run-2-allowed", size: welcome) { _ in
        AnyView(
          WelcomeView(
            input: WelcomeInput(step: .permissions, microphoneOn: true, accessibilityOn: true)))
      },
      V11Scene(id: "first-run-qr", size: welcome) { _ in
        AnyView(
          WelcomeView(
            input: WelcomeInput(step: .devices, sparkConnected: true, qrShown: true),
            actions: WelcomeActions(qr: CaptureFixture.qr)))
      },
      V11Scene(id: "space") {
        V11Page.window(V11Fixture.state($0), MemoryNavigation(root: .space("sp1")))
      },
      V11Scene(id: "x-space-empty") {
        var state = V11Fixture.state($0)
        state.sharing = [:]
        return V11Page.window(state, MemoryNavigation(root: .space("sp1")))
      },
      V11Scene(id: "space-member") {
        V11Page.matter($0, "E2", from: .space("sp1")).window(V11Fixture.state($0))
      },
      sheet("space-members") { loaded in
        let (space, _) = V11Fixture.space(loaded)
        let input = SpaceMembersInput(
          spaceID: space.id, spaceName: space.name, youAreAdmin: true,
          members: space.memberNames.map {
            SpaceMembersInput.Member(
              id: $0, name: $0, admin: space.admins.contains($0), removable: false)
          }, canInvite: true)
        return SpaceMembersSheet(input: input, actions: .inert)
      },
      sheet("space-new") { _ in
        NewSpaceSheet(state: CaptureFixture.spaces, actions: .inert)
      },
      sheet("invite") { _ in
        SpaceInviteSheet(
          spaceID: "sp1", state: CaptureFixture.spaces, actions: .inert, snapshotCode: "4MQ7-K2XP",
          snapshotSpaceName: "实验室")
      },
      sheet("error-code") { _ in
        var spaces = CaptureFixture.spaces
        spaces.joinError = "邀请码无法识别或已过期"
        return JoinSpaceSheet(state: spaces, actions: .inert, code: "R8DW-3TQN")
      },
      sheet("share") { loaded in CaptureFixture.share(loaded, "E25", looking: false) },
      sheet("share-look") { loaded in CaptureFixture.share(loaded, "E25", looking: true) },
      sheet("share-shared") { loaded in
        CaptureFixture.share(loaded, "E6", looking: false, shared: true)
      },
      sheet("consent") { _ in
        AgentConsentView(
          input: AgentConsentInput(
            appName: "Claude Code", whoLine: CaptureFixture.claudeWho,
            matterTitle: "TES论文RoboPrior大修返修", groupName: "论文",
            spaces: [.init(id: "lab", title: "实验室")]))
      },
      // v12: the same card with the bigger choices ticked (Touch ID line).
      sheet("consent-more") { _ in
        AgentConsentView(
          input: AgentConsentInput(
            appName: "Claude Code", whoLine: CaptureFixture.claudeWho,
            matterTitle: "TES论文RoboPrior大修返修", groupName: "论文",
            spaces: [.init(id: "lab", title: "实验室")]),
          initial: AgentConsentChoice(group: true, duration: .always, canChange: true))
      },
      // v12 F2: the first call named no matter (a search): nothing is ticked.
      sheet("x-consent-search") { _ in
        AgentConsentView(
          input: AgentConsentInput(
            appName: "Claude Code", whoLine: CaptureFixture.claudeWho, matterTitle: "",
            matterChoices: [
              .init(id: "E25", title: "TES论文RoboPrior大修返修"),
              .init(id: "E6", title: "SkillKnit论文投稿"),
              .init(id: "E9", title: "Twin-7 真机实验"),
            ],
            spaces: [.init(id: "lab", title: "实验室")]))
      },
      // v12 F3: same name, another program.
      sheet("x-consent-lookalike") { _ in
        AgentConsentView(
          input: AgentConsentInput(
            appName: "Claude Code", whoLine: "没有开发者签名的程序 · /tmp/x/claude",
            lookalikePath: "~/.local/share/claude/versions/*/claude",
            matterTitle: "TES论文RoboPrior大修返修", wantsToChange: true),
          initial: AgentConsentChoice(duration: .always, canChange: true))
      },
      // v12: 通用 › 时区 (the product time zone, 根-13).
      settingsScene("x-settings-general", .general),
      settingsScene("settings-entries", .entries),
      settingsScene("x-settings-dictation", .dictation),
      settingsScene("settings-privacy", .devices),
      settingsScene("settings-privacy-more", .devices, details: true),
      settingsScene("settings-devices", .devices, scroll: 88),
      settingsScene("settings-iphone", .devices, qr: true, scroll: 236),
      settingsScene(
        "settings-offline", .devices, link: MemoryLinkState(status: .notConnected, waiting: 3),
        scroll: 88),
      settingsScene("settings-apps", .apps),
      // v12 F6: one App's page (its changes with 撤销, every call, export).
      settingsScene("x-settings-app-page", .apps, appPage: true),
      settingsScene("settings-about", .about),
      // The prototype's frozen times count from the page, with fn down at 0.3 s
      // (and up at 4.2 s): the listener's own clock starts at the press.
      hudScene("dictation", FnHUDInput(), at: 2.3),
      hudScene("x-dictation-press", FnHUDInput(), at: 0.3),
      hudScene("x-dictation-gather", FnHUDInput(), at: 4.32, release: 3.9),
      hudScene("dictation-plain", FnHUDInput(caption: "", pending: "跟高原说一声，cover"), at: 3.1),
      hudScene("dictation-saved", FnHUDInput(), at: 4.9, release: 3.9),
      // v12 B1: a short tap leaves the take listening hands-free (it used to
      // drop it and show a hint); the words show during every take.
      hudScene("fn-tap", FnHUDInput(caption: ""), at: 2.3),
      hudScene(
        "x-dictation-translate",
        FnHUDInput(
          caption: "", pending: "下周三之前把三组数据跑完",
          badge: FnHUDBadge(text: "英", label: "翻译成英语")), at: 2.3),
      hudScene(
        "x-dictation-translate-missing",
        FnHUDInput(
          caption: "", pending: "下周三之前把三组数据跑完",
          badge: FnHUDBadge(text: "日", note: "未下载", label: "翻译成日语，日语还没下载")), at: 2.3),
      hudScene(
        "x-dictation-command",
        FnHUDInput(caption: "", badge: FnHUDBadge(text: "指令", label: "指令")), at: 2.3),
      hudScene(
        "x-dictation-copied",
        FnHUDInput(
          caption: "跟高原说一声，cover 第一段我又删了两句。",
          notice: FnHUDNotice(symbol: "doc.on.clipboard", text: "已拷贝", detail: "⌘V 粘贴")),
        at: nil),
      hudScene(
        "x-dictation-nothing-heard",
        FnHUDInput(notice: FnHUDNotice(symbol: "mic.slash", text: "未检测到语音")), at: nil),
      hudScene(
        "x-dictation-failed",
        FnHUDInput(
          notice: FnHUDNotice(symbol: "exclamationmark.circle", text: "无法转写，录音已保存。可以在“历史”中重试")),
        at: nil),
      hudScene(
        "x-dictation-untranslated",
        FnHUDInput(
          caption: "下周三之前把三组数据跑完。",
          notice: FnHUDNotice(symbol: "translate", text: "日语还没下载，先写了原文")),
        at: nil),
      hudScene("error-mic", FnHUDInput(hint: .microphoneOff), at: nil),
      hudScene("x-fn-taken", FnHUDInput(hint: .fnTaken), at: nil),
      V11Scene(id: "meeting-menu", size: menu) { _ in
        V11Page.surface {
          MenuBarExtraContent(input: MenuBarExtraInput(link: MemoryLinkState(status: .connected)))
        }
      },
      V11Scene(id: "meeting", size: menu) { _ in
        V11Page.surface {
          MenuBarExtraContent(
            input: MenuBarExtraInput(
              link: MemoryLinkState(status: .connected), recording: recording))
        }
      },
      V11Scene(id: "meeting-bar", size: CGSize(width: 360, height: 60)) { _ in
        V11Page.surface {
          MenuBarExtraContent(
            input: MenuBarExtraInput(
              link: MemoryLinkState(status: .connected), recording: recording, menuOpen: false))
        }
      },
      sheet("meeting-discard") { _ in DiscardRecordingAlert() },
      // v12 1C: what the meeting records, and its caption strip.
      V11Scene(id: "x-meeting-menu-source", size: CGSize(width: 360, height: 300)) { _ in
        V11Page.surface {
          MenuBarExtraContent(
            input: MenuBarExtraInput(
              link: MemoryLinkState(status: .connected), meeting: CaptureFixture.meetingSound))
        }
      },
      V11Scene(id: "x-meeting-menu-mic-only", size: CGSize(width: 360, height: 300)) { _ in
        V11Page.surface {
          MenuBarExtraContent(
            input: MenuBarExtraInput(
              link: MemoryLinkState(status: .connected),
              meeting: MenuBarMeetingInput(sound: .microphoneOnly(needsRelaunch: false))))
        }
      },
      V11Scene(id: "x-meeting-recording-source", size: CGSize(width: 360, height: 300)) { _ in
        V11Page.surface {
          MenuBarExtraContent(
            input: MenuBarExtraInput(
              link: MemoryLinkState(status: .connected), recording: recording,
              meeting: MenuBarMeetingInput(sound: .computer(source: "腾讯会议", options: []))))
        }
      },
      V11Scene(id: "x-meeting-recording-mic-only", size: CGSize(width: 360, height: 300)) { _ in
        V11Page.surface {
          MenuBarExtraContent(
            input: MenuBarExtraInput(
              link: MemoryLinkState(status: .connected), recording: recording,
              meeting: MenuBarMeetingInput(
                sound: .microphoneOnly(needsRelaunch: false), captionsShown: false)))
        }
      },
      V11Scene(id: "x-meeting-captions", size: CGSize(width: 640, height: 104)) { _ in
        V11Page.surface {
          MeetingCaptionView(
            input: MeetingCaptionInput(lines: [
              .init(speaker: "说话人 A", words: "下周三之前把 Twin-7 的三组数据跑完，周五和明澜对一下结果"),
              .init(speaker: "我", words: "好，那 cover 第一段我再删两句"),
            ]))
        }
      },
      V11Scene(id: "x-meeting-captions-saved", size: CGSize(width: 640, height: 104)) { _ in
        V11Page.surface {
          MeetingCaptionView(
            input: MeetingCaptionInput(
              lines: [.init(words: "下周三之前把 Twin-7 的三组数据跑完，周五和明澜对一下结果。好，那 cover 第一段我再删两句。")],
              status: "已收好", live: false))
        }
      },
      V11Scene(id: "x-home-meetings-waiting") {
        var state = V11Fixture.state($0, link: MemoryLinkState(status: .notConnected, waiting: 4))
        state.waitingCaptures = CaptureFixture.meetingsWaiting
        return V11Page.window(state)
      },
      V11Scene(id: "offline-menu", size: menu) { _ in
        V11Page.surface {
          MenuBarExtraContent(input: MenuBarExtraInput(link: MemoryLinkState(status: .notConnected)))
        }
      },
      V11Scene(id: "drop") { V11Page.window(V11Fixture.state($0), dropTargeted: true) },
      V11Scene(id: "drop-video") {
        var state = V11Fixture.state($0)
        if let id = $0.handles["E45"] {
          state.highlightedEventID = id
          state.toast = MemoryToast(
            "已归进「博士中期考核」", icon: .none, action: .view(eventID: id, stepID: nil))
        }
        return V11Page.window(state)
      },
      V11Scene(id: "drop-dup") {
        var state = V11Fixture.state($0)
        state.toast = MemoryToast(
          "此文件已添加过", icon: .symbol("checkmark"),
          action: $0.handles["E6"].map { .view(eventID: $0, stepID: nil) })
        return V11Page.window(state)
      },
    ]
  }
}

extension MemoryNavigation {
  /// The main window on this navigation.
  @MainActor func window(_ state: MemoryScreenState) -> AnyView { V11Page.window(state, self) }
}

/// Synthetic values the capture scenes share.
@MainActor
enum CaptureFixture {
  /// 「刚收进来」 with a microphone-only meeting, an imported recording and
  /// video, and a transcript taken in from 腾讯会议 (v12 1C). Synthetic.
  @MainActor static var meetingsWaiting: [MemoryWaitingCapture] {
    func record(
      _ mode: SessionInputMode, _ minutes: Double, _ text: String, kind: UserItemKind? = nil,
      file: String? = nil, app: String? = nil, at hour: Int, _ minute: Int
    ) -> MemoryItemRecord {
      MemoryItemRecord(
        sessionID: SessionID(), inputMode: mode, itemKind: kind, title: "t",
        startedAt: V11HomeFixture.at(hour, minute), updatedAt: V11HomeFixture.at(hour, minute),
        sourceBundleID: nil, sourceDisplayName: app ?? file, sourceIdentifier: file, text: text,
        durationNanoseconds: UInt64(minutes * 60e9))
    }
    return [
      MemoryWaitingCapture(
        record: record(
          .roomMicrophone, 38, "下周三之前把三组数据跑完，周五和明澜对一下结果。", at: 22, 41)),
      MemoryWaitingCapture(
        record: record(
          .userItem, 0, "林知夏(00:00:05):\n这周先把三组数据跑完。\n\n高原(00:01:10):\n好，我周五给结果。",
          kind: .document, app: "腾讯会议", at: 22, 30)),
      MemoryWaitingCapture(
        record: record(.importedMedia, 12, "访谈先约在周四下午。", file: "访谈.m4a", at: 22, 20)),
      MemoryWaitingCapture(
        record: record(.importedMedia, 42, "答辩 PPT 先给周老师看一遍。", file: "组会录像.mov", at: 22, 10)),
    ]
  }

  /// 录：腾讯会议 › with the whole computer and two Apps (v12 1C).
  static let meetingSound = MenuBarMeetingInput(
    sound: .computer(
      source: "腾讯会议",
      options: [
        MenuBarExtraOption(id: "entire-system", title: "整台电脑", checked: false),
        MenuBarExtraOption(id: "bundle:com.tencent.meeting", title: "腾讯会议", checked: true),
        MenuBarExtraOption(id: "bundle:com.apple.Music", title: "音乐", checked: false),
      ]))

  /// A QR of a synthetic string (the App shows the real pairing code).
  static let qr: CGImage? = {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data("mindloom-synthetic-pairing-code".utf8)
    filter.correctionLevel = "M"
    guard let image = filter.outputImage else { return nil }
    return CIContext().createCGImage(image, from: image.extent)
  }()

  /// 其他 App (v12 F6): synthetic Apps and one App's page.
  static let claudeWho = "Anthropic PBC 签名的程序 · ~/.local/share/claude/versions/2.1.3/claude"
  static let agentCommand =
    "claude mcp add mindloom -- \"/Applications/Mindloom.app/Contents/Helpers/mindloom-mcp\""
  static let agentApps = [
    SettingsAgentApp(
      id: "k1", name: "Claude Code", place: claudeWho,
      allowed: "「TES论文RoboPrior大修返修」 · 今天 · 也可以改", grantIDs: ["g1"], lastUsed: "今天 22:41"),
    SettingsAgentApp(
      id: "k2", name: "Codex", place: "OpenAI OpCo, LLC 签名的程序 · /Applications/ChatGPT.app",
      allowed: "全部的事 · 一直 · 只读", grantIDs: ["g2"], lastUsed: "今天 21:12"),
  ]
  static let agentPage = SettingsAgentDetail(
    app: agentApps[0],
    changes: [
      SettingsAgentChange(
        id: "c1", when: "今天 22:44", summary: "把「Twin-7 真机实验」改名为「Twin-7 第三组实验」", undone: false),
      SettingsAgentChange(
        id: "c2", when: "今天 22:43", summary: "收进一条「交接：返修要点」，放进「TES论文RoboPrior大修返修」",
        undone: true),
    ],
    records: [
      SettingsAgentRecord(
        id: "r1", when: "今天 22:42", what: "读一件事 · 「TES论文RoboPrior大修返修」", outcome: "已提供",
        refused: false),
      SettingsAgentRecord(
        id: "r2", when: "今天 22:41", what: "找 · 3 件事、共享空间「实验室」的 1 件事", outcome: "已提供",
        refused: false),
      SettingsAgentRecord(id: "r3", when: "今天 22:40", what: "查看今天", outcome: "等待你的决定", refused: true),
    ], recordCount: 3)

  static var spaces: SpacesScreenState {
    var state = SpacesScreenState()
    state.linkReady = true
    return state
  }

  /// The listener after a press at 100 s, with the synthetic speech track,
  /// advanced to `time` (+100 s) and released at `release`.
  static func listener(at time: Double, release: Double?) -> ListenerModel {
    let model = ListenerModel(layout: .macHUD(size: FnHUDGeometry.listenerSize))
    let track = ListenerSynthetic.speechTrack(start: 100.9, end: 103.8)
    model.levelTrack = { track($0) }
    model.press(at: 100)
    var t = 100.0
    while t < 100 + time {
      if let release, t >= 100 + release, model.releasedAt == nil { model.release(at: 100 + release) }
      _ = model.frame(at: t)
      t += 1.0 / 60
    }
    if let release, model.releasedAt == nil, time >= release { model.release(at: 100 + release) }
    return model
  }

  /// The share sheet for a prototype matter (E25: 5 steps, 2 chats, 4 mails,
  /// no files; 邮件 unticked in `share-look`).
  static func share(
    _ loaded: V11Fixture.Loaded, _ handle: String, looking: Bool, shared: Bool = false
  ) -> some View {
    let id = loaded.handles[handle] ?? handle
    let title = V11Fixture.state(loaded).matter(id)?.title ?? handle
    func candidate(_ n: Int, _ wire: String) -> SpaceShareCandidate {
      SpaceShareCandidate(
        id: "c\(n)", sourceItemID: "i\(n)", kind: .item, wireKind: wire, title: "", preview: "",
        startedAt: nil, isPrivateDictation: wire == "dictation", numberLabels: [],
        hasOriginal: false)
    }
    let candidates = [
      candidate(1, "text"), candidate(2, "audio_segment"), candidate(3, "mail"),
      candidate(4, "mail"), candidate(5, "mail"), candidate(6, "mail"), candidate(7, "dictation"),
    ]
    var review = SpaceShareReview(candidates: candidates)
    review.ticked = ["c1", "c2"]
    var draft = SpaceShareDraft(
      eventID: id, title: title, destinations: [], destination: "sp1", rope: nil, review: review,
      sharedIn: [:])
    draft.progressCount = 5
    return ShareSheetContent(
      draft: .constant(draft), spaces: [("sp1", "实验室")], selected: "sp1", memberCount: 5,
      alreadyShared: shared, looking: .constant(looking), canShare: true, actions: .inert)
  }
}

extension MindloomSettingsState {
  fileprivate func withAgents(on: Bool, command: String) -> Self {
    var state = self
    state.otherAppsCanRead = on
    state.agentCommand = command
    return state
  }

  fileprivate func withTimeZone(_ zone: SettingsTimeZone) -> Self {
    var state = self
    state.timeZone = zone
    return state
  }
}

extension CaptureFixture {
  /// Settings › 口述's words (v12 find).
  static let dictionary = [
    SettingsDictionaryWord(id: "w1", written: "RoboPrior", heard: ["肉包", "罗博普瑞尔"]),
    SettingsDictionaryWord(id: "w2", written: "穹顶研究院", heard: ["穹鼎研究院"]),
    // An off word (bestASR's library carried 23 of 64 off; review of 10-6).
    SettingsDictionaryWord(id: "w3", written: "SkillKnit", heard: [], enabled: false),
  ]
}
