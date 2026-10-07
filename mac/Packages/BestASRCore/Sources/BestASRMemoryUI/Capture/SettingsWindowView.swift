import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: mac-capture. S16 · The Settings window (MAC-SPEC §9), 780 × 600 with
// its own sidebar: 通用 (time zone, captions), 口述 (the dictionary, v12 find), 入口 (switches), 设备与隐私 (three sentences, 详细说明,
// 你的 DGX Spark, 这台 Mac, iPhone + 连接 iPhone… QR, 删除原始录音…), 其他 App
// 的访问 (允许读的 + 停止允许, 最近读过), 关于 (icon A, wordmark, 织机, version).
// Also the 「使用这台 Mac 上已装的识别模型」 action (Preview).

public enum SettingsPane: String, CaseIterable, Hashable, Sendable {
  /// v12: the product time zone (ALIGNMENT 根-13).
  case general
  case dictation
  case entries
  case devices
  case apps
  case about

  /// Sidebar label.
  public var title: String {
    switch self {
    case .general: "通用"
    case .dictation: "口述"
    case .entries: "入口"
    case .devices: "设备与隐私"
    case .apps: "其他 App"
    case .about: "关于"
    }
  }

  /// Title bar text.
  public var heading: String {
    switch self {
    case .apps: "其他 App 的访问"
    default: title
    }
  }

  public var symbol: String {
    switch self {
    case .general: "gearshape"
    case .dictation: "mic"
    case .entries: "tray.and.arrow.down"
    case .devices: "shield"
    case .apps: "command"
    case .about: "info.circle"
    }
  }
}

/// One 入口 row (§9.1): icon, title, description and its switch.
public struct SettingsEntry: Identifiable, Equatable, Sendable {
  public let id: String
  public let symbol: String
  public let title: String
  public let detail: String
  public let isOn: Bool
  /// False while the switch cannot change (e.g. fn held by another App).
  public let enabled: Bool

  public init(
    id: String, symbol: String, title: String, detail: String, isOn: Bool, enabled: Bool = true
  ) {
    self.id = id
    self.symbol = symbol
    self.title = title
    self.detail = detail
    self.isOn = isOn
    self.enabled = enabled
  }
}

/// One App in 其他 App (v12 F6): who it is and what it may do now.
public struct SettingsAgentApp: Identifiable, Equatable, Sendable {
  /// The client key.
  public let id: String
  public let name: String
  /// Who signed it and where it is, in plain words.
  public let place: String
  /// 「「TES 论文…」 · 今天 · 只读」; nil when it is not allowed now.
  public let allowed: String?
  /// The grants to stop.
  public let grantIDs: [String]
  /// 「今天 21:12」: its last call.
  public let lastUsed: String?

  public init(
    id: String, name: String, place: String, allowed: String?, grantIDs: [String] = [],
    lastUsed: String? = nil
  ) {
    self.id = id
    self.name = name
    self.place = place
    self.allowed = allowed
    self.grantIDs = grantIDs
    self.lastUsed = lastUsed
  }
}

/// One call of an App, as its page lists it: when, what, how it ended.
public struct SettingsAgentRecord: Identifiable, Equatable, Sendable {
  public let id: String
  public let when: String
  /// 「读一件事 · 「TES 论文…」」, 「找 · 3 件事」, 「读共享空间「实验室」的 2 件事」.
  public let what: String
  /// 「已给」 · 「不允许」 · 「等你决定」 · 「超过一小时的上限」 …
  public let outcome: String
  /// Refused, waiting or over the limit (drawn in the alert colour).
  public let refused: Bool

  public init(id: String, when: String, what: String, outcome: String, refused: Bool) {
    self.id = id
    self.when = when
    self.what = what
    self.outcome = outcome
    self.refused = refused
  }
}

/// One change an App made, with 撤销.
public struct SettingsAgentChange: Identifiable, Equatable, Sendable {
  public let id: String
  public let when: String
  public let summary: String
  public let undone: Bool

  public init(id: String, when: String, summary: String, undone: Bool) {
    self.id = id
    self.when = when
    self.summary = summary
    self.undone = undone
  }
}

/// An App's own page in 其他 App.
public struct SettingsAgentDetail: Equatable, Sendable {
  public let app: SettingsAgentApp
  public let changes: [SettingsAgentChange]
  public let records: [SettingsAgentRecord]
  /// All its records (the page lists the newest).
  public let recordCount: Int

  public init(
    app: SettingsAgentApp, changes: [SettingsAgentChange], records: [SettingsAgentRecord],
    recordCount: Int
  ) {
    self.app = app
    self.changes = changes
    self.records = records
    self.recordCount = recordCount
  }
}

/// The preview's 「使用这台 Mac 上已装的识别模型」 row.
public enum SettingsModelImport: Equatable, Sendable {
  /// Offered: the models are missing here and the user's library has them.
  case offered
  case working
  /// The models are ready (「识别模型已就绪」).
  case ready
  /// The words of what went wrong.
  case failed(String)
}

/// 通用 › 时区: the zone the library counts days in, and the zones offered.
public struct SettingsTimeZone: Equatable, Sendable {
  public struct Choice: Identifiable, Equatable, Sendable {
    /// The IANA identifier.
    public let id: String
    /// 「新加坡时间（GMT+8）」.
    public let label: String

    public init(id: String, label: String) {
      self.id = id
      self.label = label
    }
  }

  public var current: String
  public var choices: [Choice]

  public init(current: String = "Asia/Singapore", choices: [Choice] = []) {
    self.current = current
    self.choices = choices
  }

  /// The label of the current zone (its identifier when it is not offered).
  public var currentLabel: String {
    choices.first { $0.id == current }?.label ?? current
  }
}

/// What the Settings panes show (the App fills it).
public struct MindloomSettingsState: Equatable, @unchecked Sendable {
  public var pane: SettingsPane
  /// 通用 › 时区.
  public var timeZone: SettingsTimeZone
  /// 通用 › 口述 › 口述时显示文字 (on by default; ALIGNMENT 收1-17).
  public var dictationCaptions = true
  public var link: MemoryLinkState
  /// One line when the DGX Spark link refuses for a reason the user can act on.
  public var linkNote: String?
  /// This Mac's name (「你的东西都存在这里」).
  public var macName: String
  /// The paired iPhone's name, if any.
  public var iphoneName: String?
  /// 「9月18日起连接 · 最近一次送来 21:58」.
  public var iphoneDetail: String?
  /// 「版本 1.0（10）」's numbers.
  public var version: String
  public var entries: [SettingsEntry]
  /// 入口 › 腾讯会议 (ENTRY-013); nil hides the group.
  public var tencentMeeting: SettingsTencentMeeting?
  /// The QR code of the Tencent Meeting authorization address.
  public var tencentQR: CGImage?
  /// The quiet line while another App holds fn (preview).
  public var fnNote: String?
  /// 其他 App › 允许其他 App 读 (off by default; F1).
  public var otherAppsCanRead = false
  /// Apps allowed now or seen in the records, newest first.
  public var agentApps: [SettingsAgentApp]
  /// The App whose page is open.
  public var agentDetail: SettingsAgentDetail?
  /// Apps waiting for the owner's answer on a card the owner put away.
  public var agentWaiting: [String] = []
  /// The line 「复制命令」 copies for Claude Code (shown before it is copied).
  public var agentCommand = ""
  public var modelImport: SettingsModelImport?
  /// The original recordings kept on this Mac (「删除原始录音…」 is offered
  /// only with some).
  public var hasRawAudio: Bool
  /// Initial disclosure states (still images; the window keeps its own).
  public var detailsOpen: Bool
  /// The pairing QR is open (connecting, or the code is shown).
  public var qrShown: Bool
  /// The pairing code as a QR, once it is made.
  public var pairingQR: CGImage?
  /// Scroll offset for a still image (`settings-devices`).
  public var snapshotScroll: CGFloat
  /// 口述 › 词典: the words dictation writes the user's way.
  public var dictionary: [SettingsDictionaryWord] = []
  /// One line after a dictionary change went wrong (a word already there…).
  public var dictionaryNote: String?
  /// One line after an import or export finished (「已导入 12 个词条。」).
  public var dictionaryStatus: String?
  /// 通用 › 储存空间 (收3-5); nil until it has been measured.
  public var storage: SettingsStorage?
  /// 口述 › 速度与占用.
  public var dictationMetrics = SettingsDictationMetrics()
  /// 设备与隐私 › 从网络补充信息 (off by default; LOOKUP-001).
  public var webLookup = SettingsWebLookup()

  public init(
    pane: SettingsPane = .devices, link: MemoryLinkState = MemoryLinkState(),
    linkNote: String? = nil, macName: String = "", iphoneName: String? = nil,
    iphoneDetail: String? = nil, version: String = "", entries: [SettingsEntry] = [],
    fnNote: String? = nil, agentApps: [SettingsAgentApp] = [],
    agentDetail: SettingsAgentDetail? = nil, modelImport: SettingsModelImport? = nil,
    hasRawAudio: Bool = true, detailsOpen: Bool = false,
    qrShown: Bool = false, snapshotScroll: CGFloat = 0, dictionary: [SettingsDictionaryWord] = []
  ) {
    self.pane = pane
    self.link = link
    self.linkNote = linkNote
    self.macName = macName
    self.iphoneName = iphoneName
    self.iphoneDetail = iphoneDetail
    self.version = version
    self.entries = entries
    self.fnNote = fnNote
    self.agentApps = agentApps
    self.agentDetail = agentDetail
    self.modelImport = modelImport
    self.hasRawAudio = hasRawAudio
    self.detailsOpen = detailsOpen
    self.qrShown = qrShown
    self.pairingQR = nil
    self.snapshotScroll = snapshotScroll
    self.timeZone = SettingsTimeZone()
    self.dictionary = dictionary
  }

  /// The 入口 rows of §9.1 with their defaults (the App replaces `isOn`).
  public static let defaultEntries: [SettingsEntry] = [
    SettingsEntry(
      id: "fn", symbol: "globe", title: "按住 fn 说话", detail: "说出的内容会输入到光标所在位置，并添加到 Mindloom。",
      isOn: true),
    SettingsEntry(
      id: "meeting", symbol: "record.circle", title: "菜单栏 · 记录会议",
      detail: "开会时从菜单栏开始记录，结束后添加到 Mindloom。", isOn: true),
    SettingsEntry(
      id: "iphone", symbol: "iphone", title: "iPhone 键盘和分享", detail: "在 iPhone 上口述和分享的内容会发送到这台 Mac。",
      isOn: true),
    SettingsEntry(
      id: "share", symbol: "square.and.arrow.up", title: "共享菜单中的 Mindloom",
      detail: "在 Safari、邮件、备忘录或访达的“共享”菜单中选取它。文件会拷贝到 Mindloom，链接按文字添加。",
      isOn: true),
    SettingsEntry(
      id: "services", symbol: "line.3.horizontal", title: "服务菜单“添加到 Mindloom”",
      detail: "选中文字后，在“服务”菜单中选取它。打开后，这台 Mac 上的任何 App 都可以通过它添加文字。", isOn: false),
    SettingsEntry(
      id: "chrome", symbol: "link", title: "Chrome 扩展", detail: "在 Chrome 中右键点按，将所选文字或链接添加到 Mindloom。扩展连接这台 Mac 上的 Mindloom。",
      isOn: false),
    SettingsEntry(
      id: "shortcuts", symbol: "bolt", title: "快捷指令",
      detail: "“添加到 Mindloom”添加文字、文件或链接；“Mindloom：今天到期”列出今天到期的下一步。"
        + "打开后，这台 Mac 上的其他程序也可以运行它们。",
      isOn: false),
    SettingsEntry(
      id: "cli", symbol: "command", title: "命令行 mindloom",
      detail: "在“终端”中使用 mindloom add。打开后，以你的身份运行的程序也可以使用它。", isOn: false),
    SettingsEntry(
      id: "folder", symbol: "folder", title: "文件夹", detail: "添加你所选文件夹中的新文件。", isOn: false),
    SettingsEntry(
      id: "calendar", symbol: "calendar", title: "日历", detail: "读取你所选日历中的日程。", isOn: false),
    SettingsEntry(
      id: "reminders", symbol: "checkmark.circle", title: "提醒事项", detail: "点按“添加到提醒事项”时创建一个提醒事项。",
      isOn: true),
    SettingsEntry(
      id: "git", symbol: "doc.text", title: "Git 仓库", detail: "读取所选分支新提交的标题和说明。", isOn: false),
    SettingsEntry(
      id: "zotero", symbol: "quote.opening", title: "Zotero", detail: "读取 Zotero 中新的文献、笔记和批注。", isOn: false),
  ]
}

/// What Settings can do (the App wires each to the real thing).
public struct MindloomSettingsActions {
  public var select: @MainActor (SettingsPane) -> Void
  /// 通用 › 时区: the library's product time zone (an IANA identifier).
  public var setTimeZone: @MainActor (String) -> Void
  /// 通用 › 口述时显示文字.
  public var setDictationCaptions: @MainActor (Bool) -> Void
  public var setEntry: @MainActor (_ id: String, _ on: Bool) -> Void
  public var disconnectSpark: @MainActor () -> Void
  public var reconnectSpark: @MainActor () -> Void
  /// After the user confirmed: the DGX Spark deletes what it holds of them.
  public var forgetOnSpark: @MainActor () -> Void
  /// After the user confirmed: deletes the original recordings on this Mac.
  public var deleteRawAudio: @MainActor () -> Void
  public var disconnectIPhone: @MainActor () -> Void
  /// 连接 iPhone…: makes a fresh pairing code (the QR appears when it is
  /// ready); 收起 forgets it.
  public var openPairing: @MainActor () -> Void
  public var closePairing: @MainActor () -> Void
  public var revoke: @MainActor (_ grantID: String) -> Void
  public var importModels: @MainActor () -> Void
  /// 其他 App: copies the command that connects Claude Code to Mindloom.
  public var copyAgentCommand: @MainActor () -> Void
  /// 其他 App › 允许其他 App 读.
  public var setOtherAppsCanRead: @MainActor (Bool) -> Void = { _ in }
  /// Opens an App's page (its client key), or closes it (nil).
  public var openAgentApp: @MainActor (String?) -> Void = { _ in }
  /// 停止允许 everything of one App (its client key).
  public var stopAgentApp: @MainActor (String) -> Void = { _ in }
  /// 撤销 one change (its ID).
  public var undoAgentChange: @MainActor (String) -> Void = { _ in }
  /// 导出记录… of one App (its client key).
  public var exportAgentRecords: @MainActor (String) -> Void = { _ in }
  /// Shows the cards the owner put away.
  public var showAgentRequests: @MainActor () -> Void = {}
  /// 关于: the window with the older knobs (shortcut, microphone, storage).
  public var openAdvanced: @MainActor () -> Void
  /// 口述 › 词典: add (id nil) or change a word; how it is written, how it
  /// tends to be heard.
  public var saveWord: @MainActor (_ id: String?, _ written: String, _ heard: [String]) -> Void
  /// After the user confirmed.
  public var deleteWord: @MainActor (_ id: String) -> Void
  /// 口述 › 词典: a word used in dictation, or not (its switch).
  public var setWordEnabled: @MainActor (_ id: String, _ on: Bool) -> Void = { _, _ in }
  /// 导入…: a CSV or JSON file the owner picks, merged into the dictionary.
  public var importWords: @MainActor () -> Void = {}
  /// 导出 › CSV 文件… / JSON 文件….
  public var exportWords: @MainActor (_ json: Bool) -> Void = { _ in }
  /// 入口 › 腾讯会议.
  public var tencentMeeting = SettingsTencentMeetingActions()
  /// 移除 the forms corrections added to one of the user's words.
  public var forgetLearnedForms: @MainActor (_ id: String) -> Void = { _ in }
  /// 口述 › 速度与占用: read the figures again (the pane appeared).
  public var refreshDictationMetrics: @MainActor () -> Void = {}
  /// 设备与隐私 › 从网络补充信息.
  public var setWebLookup: @MainActor (Bool) -> Void = { _ in }
  /// 添加密钥: the chosen service's ID and the pasted key (checked once,
  /// then kept by the App; the result comes back in `webLookup.keyCheck`).
  public var addSearchKey: @MainActor (_ service: String, _ key: String) -> Void = { _, _ in }
  public var removeSearchKey: @MainActor (_ service: String) -> Void = { _ in }
  /// The service a pasted key most likely belongs to, from its shape alone.
  public var likelySearchService: @MainActor (_ key: String) -> String? = { _ in nil }
  /// After the user confirmed: clears 「网络活动」.
  public var clearNetworkActivity: @MainActor () -> Void = {}

  public init(
    select: @escaping @MainActor (SettingsPane) -> Void = { _ in },
    setEntry: @escaping @MainActor (String, Bool) -> Void = { _, _ in },
    disconnectSpark: @escaping @MainActor () -> Void = {},
    reconnectSpark: @escaping @MainActor () -> Void = {},
    forgetOnSpark: @escaping @MainActor () -> Void = {},
    deleteRawAudio: @escaping @MainActor () -> Void = {},
    disconnectIPhone: @escaping @MainActor () -> Void = {},
    openPairing: @escaping @MainActor () -> Void = {},
    closePairing: @escaping @MainActor () -> Void = {},
    revoke: @escaping @MainActor (String) -> Void = { _ in },
    importModels: @escaping @MainActor () -> Void = {},
    copyAgentCommand: @escaping @MainActor () -> Void = {},
    openAdvanced: @escaping @MainActor () -> Void = {},
    setTimeZone: @escaping @MainActor (String) -> Void = { _ in },
    setDictationCaptions: @escaping @MainActor (Bool) -> Void = { _ in },
    saveWord: @escaping @MainActor (String?, String, [String]) -> Void = { _, _, _ in },
    deleteWord: @escaping @MainActor (String) -> Void = { _ in }
  ) {
    self.select = select
    self.setTimeZone = setTimeZone
    self.setDictationCaptions = setDictationCaptions
    self.setEntry = setEntry
    self.disconnectSpark = disconnectSpark
    self.reconnectSpark = reconnectSpark
    self.forgetOnSpark = forgetOnSpark
    self.deleteRawAudio = deleteRawAudio
    self.disconnectIPhone = disconnectIPhone
    self.openPairing = openPairing
    self.closePairing = closePairing
    self.revoke = revoke
    self.importModels = importModels
    self.copyAgentCommand = copyAgentCommand
    self.openAdvanced = openAdvanced
    self.saveWord = saveWord
    self.deleteWord = deleteWord
  }
}

public struct SettingsWindowView: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  let state: MindloomSettingsState
  let actions: MindloomSettingsActions
  /// A still image's QR (the App's real code otherwise).
  let snapshotQR: CGImage?

  public init(
    state: MindloomSettingsState, actions: MindloomSettingsActions = MindloomSettingsActions(),
    snapshotQR: CGImage? = nil
  ) {
    self.state = state
    self.actions = actions
    self.snapshotQR = snapshotQR
  }

  public init(state: MindloomSettingsState, select: @escaping (SettingsPane) -> Void) {
    self.init(state: state, actions: MindloomSettingsActions(select: { select($0) }))
  }

  public var body: some View {
    HStack(spacing: 0) {
      SettingsSidebar(current: state.pane, select: actions.select)
      VStack(alignment: .leading, spacing: 0) {
        Text(state.pane.heading).mlFont(\.title2)
          .frame(height: 52)
          .padding(.horizontal, 24)
          .accessibilityAddTraits(.isHeader)
        CaptureScroll(offset: state.snapshotScroll) {
          pane
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .id(state.pane)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(minWidth: 780, minHeight: 600)
    .background(MLColor.paper)
    .foregroundStyle(MLColor.ink)
    .environment(\.mlPlatform, .mac)
    .tint(MLColor.accent)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("设置")
  }

  @ViewBuilder
  private var pane: some View {
    switch state.pane {
    case .general: SettingsGeneralPane(state: state, actions: actions)
    case .dictation: SettingsDictationPane(state: state, actions: actions)
    case .entries: SettingsEntriesPane(state: state, actions: actions)
    case .devices: SettingsDevicesPane(state: state, actions: actions, snapshotQR: snapshotQR)
    case .apps: SettingsAppsPane(state: state, actions: actions)
    case .about: SettingsAboutPane(version: state.version, openAdvanced: actions.openAdvanced)
    }
  }
}

/// A scroll view that, in a still image, draws from `offset` (AppKit scroll
/// views do not draw into `ImageRenderer`).
struct CaptureScroll<Content: View>: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  let offset: CGFloat
  let content: Content

  init(offset: CGFloat = 0, @ViewBuilder content: () -> Content) {
    self.offset = offset
    self.content = content()
  }

  var body: some View {
    if snapshot {
      content
        .fixedSize(horizontal: false, vertical: true)
        .offset(y: -offset)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
    } else {
      ScrollView(.vertical) { content }.scrollIndicators(.never)
    }
  }
}

// MARK: - Sidebar

/// The Settings sidebar: an inset panel 196 wide (as the main sidebar),
/// 入口 · 设备与隐私 · 其他 App · 关于.
struct SettingsSidebar: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  let current: SettingsPane
  let select: @MainActor (SettingsPane) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(SettingsPane.allCases, id: \.self) { pane in
        let on = pane == current
        Button {
          select(pane)
        } label: {
          HStack(spacing: 9) {
            Image(systemName: pane.symbol)
              .font(.system(size: 13, weight: .regular))
              .foregroundStyle(on ? MLColor.accent : MLColor.ink2)
              .frame(width: 16, height: 16)
            Text(pane.title).mlFont(\.control).foregroundStyle(MLColor.ink)
          }
          .padding(.horizontal, 10)
          .frame(height: 30)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            on ? MLColor.accentTint2 : MLColor(fixed: MLRGBA(0, 0, 0, 0)),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
          )
          .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
      }
      Spacer()
    }
    .padding(.top, 46)
    .padding(.horizontal, 10)
    .frame(width: 196)
    .frame(maxHeight: .infinity)
    .background {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(MLColor.sidebarTint)
        .background {
          if !snapshot {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial)
          }
        }
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(
            MLColor.rule, lineWidth: 0.5)
        )
        .mlShadow(.level1)
    }
    .padding([.top, .bottom, .leading], 8)
    .overlay(alignment: .topLeading) { SettingsTrafficLights() }
  }
}

/// The traffic lights in a still image (the real window draws its own).
private struct SettingsTrafficLights: View {
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

// MARK: - 通用 (v12)

struct SettingsGeneralPane: View {
  let state: MindloomSettingsState
  let actions: MindloomSettingsActions

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SettingsGroup(footer: SettingsWindowText.timeZoneFooter) {
        SettingsRow("clock", "时区") {
          Picker(
            "时区",
            selection: Binding(
              get: { state.timeZone.current },
              set: { actions.setTimeZone($0) })
          ) {
            ForEach(state.timeZone.choices) { choice in
              Text(choice.label).tag(choice.id)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .fixedSize()
          .accessibilityLabel("时区")
        }
      }
      .padding(.top, 2)
      SettingsGroup("口述", footer: "按住 fn 键说话，松开后文字输入到光标所在位置；也可以轻按 fn 键开始，再次轻按结束；按 Esc 键取消。") {
        SettingsRow(
          "text.bubble", "口述时显示文字", detail: "口述时在屏幕下方显示识别到的文字，结束后显示最终输入的文字。"
        ) {
          SettingsSwitch(title: "口述时显示文字", isOn: state.dictationCaptions) { on in
            actions.setDictationCaptions(on)
          }
        }
      }
      .padding(.top, 18)
      SettingsStorageGroup(storage: state.storage)
        .padding(.top, 18)
    }
  }
}

// MARK: - 入口 (§9.1)

struct SettingsEntriesPane: View {
  let state: MindloomSettingsState
  let actions: MindloomSettingsActions

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SettingsGroup(footer: "粘贴和拖放到窗口始终可用。") {
        ForEach(Array(state.entries.enumerated()), id: \.element.id) { index, entry in
          if index > 0 { SettingsSeparator(leading: 44) }
          SettingsRow(
            entry.symbol, entry.title,
            detail: entry.id == "fn" ? (state.fnNote ?? entry.detail) : entry.detail
          ) {
            SettingsSwitch(title: entry.title, isOn: entry.isOn) { on in
              actions.setEntry(entry.id, on)
            }
            .disabled(!entry.enabled)
          }
        }
      }
      .padding(.top, 2)
      if let meeting = state.tencentMeeting {
        SettingsTencentMeetingGroup(
          meeting: meeting, qr: state.tencentQR, actions: actions.tencentMeeting
        )
        .padding(.top, 18)
      }
      if let modelImport = state.modelImport {
        ModelImportGroup(status: modelImport, run: actions.importModels).padding(.top, 18)
      }
    }
  }
}

/// 「识别模型」: the preview takes the public models already on this Mac.
struct ModelImportGroup: View {
  let status: SettingsModelImport
  let run: @MainActor () -> Void

  var body: some View {
    SettingsGroup("识别模型") {
      SettingsRow("waveform", detailTitle, detail: detail) {
        switch status {
        case .offered, .failed:
          Button("使用这台 Mac 上已安装的识别模型") { run() }
            .buttonStyle(MLButtonStyle(.tinted, small: true))
        case .working:
          ProgressView().controlSize(.small)
        case .ready:
          EmptyView()
        }
      }
    }
  }

  private var detailTitle: String {
    switch status {
    case .ready: "识别模型已就绪"
    case .working: "正在拷贝识别模型"
    default: "未安装识别模型"
    }
  }

  private var detail: String? {
    switch status {
    case .offered: "拷贝这台 Mac 上已安装的公开识别模型。"
    case .failed(let why): why
    case .working: "正在这台 Mac 上拷贝。"
    case .ready: nil
    }
  }
}

// MARK: - 设备与隐私 (§9.2)

struct SettingsDevicesPane: View {
  @Environment(\.timeZone) private var timeZone
  let state: MindloomSettingsState
  let actions: MindloomSettingsActions
  let snapshotQR: CGImage?
  @State private var detailsOpen: Bool
  @State private var confirmForget = false
  @State private var confirmDelete = false

  init(state: MindloomSettingsState, actions: MindloomSettingsActions, snapshotQR: CGImage?) {
    self.state = state
    self.actions = actions
    self.snapshotQR = snapshotQR
    _detailsOpen = State(initialValue: state.detailsOpen)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SettingsGroup {
        bigRow("lock", "声音、声音样本和词典储存在这台 Mac 上。")
        SettingsSeparator(leading: 44)
        bigRow("eye.slash", "转写的文字发送到你的 DGX Spark 进行整理，发送前隐藏手机号和证件号。")
        SettingsSeparator(leading: 44)
        bigRow("shield", "你的内容储存在你的设备和你的 DGX Spark 上。你允许的 App 读取的内容会发送到它使用的模型；共享的事对共享空间的成员可见。")
      }
      .padding(.top, 2)
      DisclosureLink(title: "详细信息", open: detailsOpen) {
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.24)) { detailsOpen.toggle() }
      }
      .padding(.horizontal, 12)
      .padding(.top, 12)
      if detailsOpen { details.transition(.opacity) }
      spark.padding(.top, 18)
      SettingsWebLookupGroup(state: state.webLookup, actions: actions).padding(.top, 18)
      SettingsGroup("这台 Mac") {
        SettingsRow("laptopcomputer", state.macName, detail: "你的资料储存在这里")
      }
      .padding(.top, 18)
      iphone.padding(.top, 18)
    }
    .confirmationDialog(
      "删除 DGX Spark 上的内容？", isPresented: $confirmForget, titleVisibility: .visible
    ) {
      Button("删除", role: .destructive) { actions.forgetOnSpark() }
      Button("取消", role: .cancel) {}
    } message: {
      Text("DGX Spark 上整理的内容将被删除，连接也会断开。这台 Mac 上的资料保持不变；再次连接后会重新整理。")
    }
    .confirmationDialog(
      "删除原始录音？", isPresented: $confirmDelete, titleVisibility: .visible
    ) {
      Button("删除原始录音", role: .destructive) { actions.deleteRawAudio() }
      Button("取消", role: .cancel) {}
    } message: {
      Text("这台 Mac 上的所有原始录音都将被删除。转写的文字和整理出的进展会保留。此操作无法撤销。")
    }
  }

  private func bigRow(_ symbol: String, _ text: String) -> some View {
    SettingsRow(symbol, text, titleStyle: \.body, minHeight: 52, balancedWidth: 430)
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 0) {
      detailGroup("储存在这台 Mac 上", ["原始录音、声音样本、词典，以及你添加的文件原件"])
      detailGroup(
        "发送到你的 DGX Spark", ["转写的文字、你添加的文字和截图中的文字"],
        footer: "通过你打开的加密连接发送；可以随时在下方断开连接。")
      detailGroup(
        "你允许的 App",
        ["读取你允许的事、分组或全部内容，读取的内容会发送到它使用的模型；选择“允许更改”后，它还可以添加内容、更改归属、重新命名和标记为完成"],
        footer: "在“其他 App”中查看它读取和更改的内容，撤销更改或停止允许。")
      detailGroup("共享", ["你共享的事对共享空间的成员可见"], footer: "共享的内容由你逐件选择。")
      if state.webLookup.enabled {
        detailGroup(
          "从网络补充信息", ["公开名称、年份和固定说法发送到搜索服务和公开资料网站；网页由这台 Mac 读取"],
          footer: "在“网络活动”中查看每次连接。")
      }
      SettingsGroup {
        SettingsRow(nil, "原始录音", detail: "删除后无法恢复。整理出的进展会保留。") {
          Button("删除原始录音…") { confirmDelete = true }
            .buttonStyle(MLButtonStyle(.destructive, small: true))
            .disabled(!state.hasRawAudio)
        }
      }
      .padding(.top, 18)
    }
  }

  private func detailGroup(_ header: String, _ rows: [String], footer: String? = nil) -> some View {
    SettingsGroup(header, footer: footer) {
      ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
        if index > 0 { SettingsSeparator() }
        SettingsRow(nil, row)
      }
    }
    .padding(.top, 18)
  }

  private var spark: some View {
    SettingsGroup("你的 DGX Spark") {
      SettingsRow("device.box", "DGX Spark", detail: sparkDetail) {
        sparkTrailing
      }
      SettingsSeparator()
      HStack(spacing: 12) {
        Text("发送到 DGX Spark 前隐藏手机号和证件号；声音、声音样本和词典储存在这台 Mac 上。")
          .mlFont(\.foot).foregroundStyle(MLColor.ink2)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        Button("删除 DGX Spark 上的内容…") { confirmForget = true }
          .buttonStyle(MLButtonStyle(.plain, small: true))
          .disabled(state.link.status == .off)
      }
      .padding(.vertical, 9)
      .padding(.horizontal, 12)
      .frame(minHeight: 44)
    }
  }

  private var sparkDetail: String? {
    switch state.link.status {
    case .connected:
      if let note = state.linkNote { return note }
      return state.link.lastOrganizedAt.map { "上次整理 \(SettingsWindowText.time($0, timeZone))" }
    case .connecting:
      return state.linkNote
    case .notConnected:
      if let note = state.linkNote { return note }
      if state.link.waiting > 0 { return "\(state.link.waiting) 条内容暂存在这台 Mac 上，连接后整理。" }
      return "新添加的内容暂存在这台 Mac 上，连接后整理。"
    case .off:
      if let note = state.linkNote { return note }
      return "连接后，转写的文字会发送到你的 DGX Spark，整理成一件件事。"
    }
  }

  @ViewBuilder
  private var sparkTrailing: some View {
    switch state.link.status {
    case .connected:
      HStack(spacing: 12) {
        Text("已连接").mlFont(\.control).foregroundStyle(MLColor.ink2)
        Button("断开连接") { actions.disconnectSpark() }.buttonStyle(MLButtonStyle(.standard, small: true))
      }
    case .connecting:
      Text("正在连接…").mlFont(\.control).foregroundStyle(MLColor.ink2)
    case .notConnected:
      HStack(spacing: 12) {
        Text("无法连接").mlFont(\.control).foregroundStyle(MLColor.alert)
        Button("重新连接") { actions.reconnectSpark() }
          .buttonStyle(MLButtonStyle(.primary, small: true))
      }
    case .off:
      // The link is simply not on (never turned on, or 断开): a neutral
      // state, never the vermilion 「没连上」 of a link that failed.
      HStack(spacing: 12) {
        Text("未连接").mlFont(\.control).foregroundStyle(MLColor.ink2)
        Button("连接") { actions.reconnectSpark() }
          .buttonStyle(MLButtonStyle(.standard, small: true))
      }
    }
  }

  private var iphone: some View {
    SettingsGroup("iPhone") {
      if let name = state.iphoneName {
        SettingsRow("iphone", name, detail: state.iphoneDetail) {
          Button("断开连接") { actions.disconnectIPhone() }
            .buttonStyle(MLButtonStyle(.standard, small: true))
        }
        SettingsSeparator()
      }
      SettingsRow(
        nil, state.iphoneName == nil ? "连接 iPhone" : "再连接一台 iPhone",
        detail: "在 iPhone 上口述和分享的内容会发送到这台 Mac。"
      ) {
        Button(state.qrShown ? "隐藏二维码" : "连接 iPhone…") {
          withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.24)) {
            if state.qrShown { actions.closePairing() } else { actions.openPairing() }
          }
        }
        .buttonStyle(
          MLButtonStyle(state.iphoneName == nil && !state.qrShown ? .tinted : .standard, small: true))
      }
      if state.qrShown {
        PairingQRBlock(image: snapshotQR ?? state.pairingQR)
          .padding(.horizontal, 12)
          .padding(.bottom, 12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .transition(.opacity)
      }
    }
  }
}

enum SettingsWindowText {
  /// 通用 › 时区's footnote: what follows the zone, and that the rest
  /// follows when Mindloom opens again (review v12-B #14).
  static let timeZoneFooter =
    "首页的“今天”“已过期”、到期日、搜索中的“上周”以及其他 App 读取的日期，都按此时区计算。更改后，其余显示的时间在重新打开 Mindloom 后更新。"

  static func time(_ date: Date, _ timeZone: TimeZone = .current) -> String {
    let f = DateFormatter()
    f.timeZone = timeZone
    f.locale = Locale(identifier: "zh_Hans")
    f.dateFormat = "HH:mm"
    return f.string(from: date)
  }
}

// MARK: - 其他 App 的访问 (§9.3; v12 F1, F4, F6)

struct SettingsAppsPane: View {
  let state: MindloomSettingsState
  let actions: MindloomSettingsActions

  var body: some View {
    if let detail = state.agentDetail {
      SettingsAgentPage(detail: detail, actions: actions)
    } else {
      overview
    }
  }

  private var overview: some View {
    VStack(alignment: .leading, spacing: 0) {
      SettingsGroup(
        footer: state.otherAppsCanRead
          ? "Claude Code 等 App 首次读取时，Mindloom 会询问你允许它读取哪些内容以及期限。"
          : "打开后，Claude Code 等 App 可以连接 Mindloom；每个 App 首次读取前都会询问你。"
      ) {
        SettingsRow("lock.open", "允许其他 App 读取") {
          SettingsSwitch(title: "允许其他 App 读取", isOn: state.otherAppsCanRead) { on in
            actions.setOtherAppsCanRead(on)
          }
        }
      }
      .padding(.top, 2)
      if !state.agentWaiting.isEmpty {
        SettingsGroup {
          SettingsRow(
            "hand.raised", "\(state.agentWaiting.joined(separator: "、")) 请求读取 Mindloom，等待你的决定",
            detail: "你关闭了它的请求。点按“查看”以决定。"
          ) {
            Button("查看") { actions.showAgentRequests() }
              .buttonStyle(MLButtonStyle(.tinted, small: true))
          }
        }
        .padding(.top, 18)
      }
      SettingsGroup("App", footer: "点按一个 App，查看它读取和更改的内容，并可撤销更改。停止允许后，它下次读取时会再次询问你；已读取的内容无法收回。") {
        if state.agentApps.isEmpty {
          SettingsRow(nil, "尚无 App 读取。")
        }
        ForEach(Array(state.agentApps.enumerated()), id: \.element.id) { index, app in
          if index > 0 { SettingsSeparator(leading: 44) }
          Button {
            actions.openAgentApp(app.id)
          } label: {
            SettingsRow(
              "command", app.name,
              detail: MLAutospace.apply(app.allowed ?? "未允许")
                + (app.lastUsed.map { " · 最近 \($0)" } ?? "")
            ) {
              Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MLColor.ink3)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(app.name)
        }
      }
      .padding(.top, 18)
      SettingsGroup("连接", footer: state.agentCommand.isEmpty ? nil : state.agentCommand) {
        SettingsRow(
          "terminal", "允许 Claude Code 读取 Mindloom",
          detail: "拷贝下方命令，在“终端”中运行一次。Claude Code 首次读取时，这里会询问你。"
        ) {
          Button("拷贝命令") { actions.copyAgentCommand() }
            .buttonStyle(MLButtonStyle(.standard, small: true))
        }
      }
      .padding(.top, 18)
    }
  }
}

/// One App's page: who it is, what it may do, what it changed (each with
/// 撤销), and every call it made, refusals and shared-space reads included,
/// with 导出记录… and 停止允许 (F6).
struct SettingsAgentPage: View {
  let detail: SettingsAgentDetail
  let actions: MindloomSettingsActions

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        actions.openAgentApp(nil)
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
          Text("其他 App").mlFont(\.control)
        }
        .foregroundStyle(MLColor.accent)
      }
      .buttonStyle(.plain)
      .padding(.bottom, 10)
      SettingsGroup(detail.app.name, footer: detail.app.place) {
        SettingsRow(
          nil, MLAutospace.apply(detail.app.allowed ?? "未允许"),
          detail: detail.app.allowed == nil ? "它下次读取时会先询问你。" : nil
        ) {
          if detail.app.allowed != nil {
            Button("停止允许") { actions.stopAgentApp(detail.app.id) }
              .buttonStyle(MLButtonStyle(.destructive, small: true))
          }
        }
      }
      SettingsGroup("它的更改", footer: "撤销后恢复原状；它添加的内容将被删除。") {
        if detail.changes.isEmpty {
          SettingsRow(nil, "无更改。")
        }
        ForEach(Array(detail.changes.enumerated()), id: \.element.id) { index, change in
          if index > 0 { SettingsSeparator() }
          SettingsRow(nil, MLAutospace.apply(change.summary), detail: change.when) {
            if change.undone {
              Text("已撤销").mlFont(\.control).foregroundStyle(MLColor.ink2)
            } else {
              Button("撤销") { actions.undoAgentChange(change.id) }
                .buttonStyle(MLButtonStyle(.standard, small: true))
            }
          }
        }
      }
      .padding(.top, 18)
      SettingsGroup(
        "读取记录",
        footer: detail.recordCount > detail.records.count
          ? "这里列出最近 \(detail.records.count) 次，共 \(detail.recordCount) 次。导出可获取全部记录。"
          : AgentAuditWords.recordsFooter
      ) {
        if detail.records.isEmpty {
          SettingsRow(nil, "尚无读取记录。")
        }
        ForEach(Array(detail.records.enumerated()), id: \.element.id) { index, record in
          if index > 0 { SettingsSeparator() }
          SettingsRow(nil, MLAutospace.apply(record.what), detail: record.when) {
            Text(record.outcome).mlFont(\.control)
              .foregroundStyle(record.refused ? MLColor.alert : MLColor.ink2)
          }
        }
        SettingsSeparator()
        HStack {
          Spacer()
          Button("导出记录…") { actions.exportAgentRecords(detail.app.id) }
            .buttonStyle(MLButtonStyle(.plain, small: true))
            .disabled(detail.recordCount == 0 && detail.changes.isEmpty)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
      }
      .padding(.top, 18)
    }
  }
}

// MARK: - 关于 (§9.4)

struct SettingsAboutPane: View {
  let version: String
  var openAdvanced: @MainActor () -> Void = {}

  var body: some View {
    VStack(spacing: 0) {
      MindloomAppIcon(platform: .mac, appearance: .light, side: 96)
        .frame(width: 96, height: 96)
        .accessibilityLabel("Mindloom 的图标")
      MindloomWordmark(cap: 17)
        .foregroundStyle(MLColor.wordmark)
        .padding(.top, 18)
        .accessibilityLabel("Mindloom")
      Text("织机")
        .font(MLBrandFont.zhiji(size: 13))
        .tracking(13 * 0.06)
        .foregroundStyle(MLColor.ink2)
        .padding(.top, 8)
      Text("版本 \(version)").mlFont(\.foot).foregroundStyle(MLColor.ink2)
        .monospacedDigit()
        .padding(.top, 14)
      Button("高级设置…") { openAdvanced() }
        .buttonStyle(MLButtonStyle(.plain, small: true))
        .padding(.top, 24)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 64)
  }
}
