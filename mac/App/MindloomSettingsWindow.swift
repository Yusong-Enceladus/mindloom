import AppKit
import BestASRAgentAccess
import BestASRDomain
import BestASREntries
import BestASRMemory
import BestASRMemoryUI
import BestASRPersistence
import BestASRRemoteOrganizer
import Combine
import SwiftUI
import SystemConfiguration

// OWNER: mac-capture. The Settings scene (MAC-SPEC §9): `SettingsWindowView`
// from the package, filled from the App's models and wired to the real
// actions (entries, the DGX Spark link, iPhone pairing, agent grants, the
// original recordings, the preview's model import).

/// Which Settings pane to show; menus and toasts (「去设置」) set it before
/// opening the window.
@MainActor
final class SettingsRouter: ObservableObject {
  static let shared = SettingsRouter()
  @Published var pane: SettingsPane = .devices
  /// SwiftUI's own way to open the Settings scene, handed over by the main
  /// window (live-mac: on macOS 14 and later `showSettingsWindow:` no
  /// longer opens it, so 设置 did nothing).
  var opener: OpenSettingsAction?

  /// Opens Settings on a pane (nil keeps the current one).
  func open(_ pane: SettingsPane? = nil) {
    if let pane { self.pane = pane }
    NSApp.activate(ignoringOtherApps: true)
    if let opener {
      opener()
    } else {
      NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
  }

  /// A pane by the names the pages use (「entries」, 「devices」 …).
  func open(named name: String?) {
    open(name.flatMap(SettingsPane.init(rawValue:)))
  }
}

/// Titles the Settings and consent surfaces name (matter and group IDs →
/// what the pages show), refreshed by the main window as it draws. Not
/// observed: Settings reads it when it draws.
@MainActor
final class MindloomTitles {
  static let shared = MindloomTitles()
  var matters: [String: String] = [:]
  var groups: [String: String] = [:]
  /// Matter ID (upper-case) → its group ID.
  var groupOfMatter: [String: String] = [:]

  func update(_ state: MemoryScreenState) {
    guard let digest = state.digest else { return }
    var titles: [String: String] = [:]
    for matter in digest.matters { titles[matter.eventID.uppercased()] = matter.title }
    if titles != matters { matters = titles }
    var names: [String: String] = [:]
    var membership: [String: String] = [:]
    for group in state.groups {
      names[group.routeID] = group.name
      for id in group.eventIDs { membership[id.uppercased()] = group.routeID }
    }
    if names != groups { groups = names }
    if membership != groupOfMatter { groupOfMatter = membership }
  }

  func matter(_ id: String) -> String? { matters[id.uppercased()] }
}

struct MindloomSettingsScene: View {
  @ObservedObject var model: DictationAppModel
  @ObservedObject private var router = SettingsRouter.shared
  @ObservedObject private var phone: PhoneLinkModel
  @ObservedObject private var agents: AgentAccessModel
  @ObservedObject private var entries: EntriesModel
  @ObservedObject private var tencent: TencentMeetingModel
  @ObservedObject private var capture = CaptureState.shared
  /// 口述 › 词典 (v12 find).
  @ObservedObject private var dictionary: DictionaryModel
  /// 设备与隐私 › 从网络补充信息.
  @ObservedObject private var webLookup: WebLookupModel
  @State private var dictionaryNote: String?
  @State private var dictionaryStatus: String?
  @State private var pairingOpenedAt: Date?
  @Environment(\.openWindow) private var openWindow

  init(model: DictationAppModel) {
    self.model = model
    phone = model.phoneLink
    agents = model.agentAccess
    entries = model.entries
    tencent = model.entries.tencent
    dictionary = model.dictionary
    webLookup = model.webLookup
  }

  var body: some View {
    SettingsWindowView(state: state, actions: actions)
      .mindloomWindowChrome()
      .environment(\.locale, Locale(identifier: "zh-Hans"))
      .onAppear {
        model.refreshPermissions()
        agents.requestRefresh()
        model.refreshModelImportOffer()
        model.refreshLibraryStorage()
        model.webLookup.refresh()
        dictionary.searchQuery = ""
        dictionary.search()
        Task { await model.refreshAutomaticDictionaryEntries() }
      }
      .onDisappear { closePairing() }
      // 10 minutes after a pairing code was shown, it is put away (and
      // forgotten); opening it again makes a new one.
      .task(id: pairingOpenedAt) {
        guard pairingOpenedAt != nil else { return }
        try? await Task.sleep(for: .seconds(600))
        guard !Task.isCancelled else { return }
        closePairing()
      }
  }

  private var state: MindloomSettingsState {
    var state = MindloomSettingsState(
      pane: router.pane, link: MemoryScreenModel.link(model),
      linkNote: Self.linkNote(model.remoteOrganizerLinkStatus, enabled: model.remoteOrganizerEnabled),
      macName: Self.macName, iphoneName: phone.paired == nil ? nil : "iPhone",
      iphoneDetail: phone.paired.map { Self.phoneDetail($0.pairedAt, last: model.lastPhoneDelivery) },
      version: Self.version, entries: entryRows,
      fnNote: model.fnHeldByOtherApp ? FnHUDHint.fnTakenLine : nil,
      agentApps: agentApps, agentDetail: agentDetail,
      modelImport: model.modelImportOffer, hasRawAudio: true)
    state.otherAppsCanRead = agents.otherAppsCanRead
    state.agentWaiting = agents.waitingNames
    state.agentCommand = model.agentInstallCommand
    state.link.waiting = model.waitingForSpark
    state.dictationCaptions = model.dictationCaptionsEnabled
    state.dictationMetrics = model.dictationMetrics
    state.timeZone = SettingsTimeZone(
      current: model.productTimeZone.identifier,
      choices: model.productTimeZoneChoices.map {
        SettingsTimeZone.Choice(id: $0.id, label: $0.label)
      })
    state.qrShown = phone.pairingCode != nil || phone.working
    state.pairingQR = phone.pairingCode.flatMap { PhonePairingQRCode.image(for: $0) }
    state.dictionary = dictionary.entries.map { entry in
      let automatic = model.automaticDictionaryEntries[entry.id]
      return SettingsDictionaryWord(
        id: entry.id.rawValue.uuidString, written: entry.canonicalForm, heard: entry.spokenForms,
        enabled: entry.enabled,
        learned: automatic.flatMap { $0.learnedForms.isEmpty ? Self.learnedLine($0) : nil },
        learnedForms: automatic?.learnedForms ?? [])
    }
    state.dictionaryNote = dictionaryNote
    state.dictionaryStatus = dictionaryStatus
    state.storage = DictationAppModel.settingsStorage(model.libraryStorage)
    if entries.isReady {
      state.tencentMeeting = tencent.settings(isOn: entries.isOn(.tencentMeeting))
      state.tencentQR = tencent.qr
    }
    state.webLookup = webLookup.state
    return state
  }

  /// 「更正过 2 次 · 用于识别和替换」.
  static func learnedLine(_ entry: AutomaticDictionaryEntry) -> String {
    "更正过 \(entry.times) 次 · " + (entry.usedForRecognition ? "用于识别和替换" : "用于替换")
  }

  private var actions: MindloomSettingsActions {
    let model = model
    let actions = MindloomSettingsActions(
      select: { SettingsRouter.shared.pane = $0 },
      setEntry: { id, on in model.setMindloomEntry(id, on: on) },
      disconnectSpark: { model.setRemoteOrganizerEnabled(false) },
      reconnectSpark: { model.reconnectRemoteOrganizer() },
      forgetOnSpark: { model.forgetRemoteOrganizerContent() },
      deleteRawAudio: { model.deleteAllOriginalRecordings() },
      disconnectIPhone: { model.disconnectIPhone() },
      openPairing: { [self] in openPairing() },
      closePairing: { [self] in closePairing() },
      revoke: { id in
        guard let uuid = UUID(uuidString: id) else { return }
        let name = model.agentAccess.grants.first { $0.grantID == uuid }?.clientName ?? ""
        model.agentAccess.revoke(uuid)
        CaptureFeedback.shared.show(MemoryToast("已停止允许 \(name)", icon: .symbol("checkmark")))
      },
      importModels: { model.importInstalledModels() },
      copyAgentCommand: { model.copyAgentInstallCommand() },
      openAdvanced: { [openWindow] in
        openWindow(id: "advanced-settings")
        NSApp.activate(ignoringOtherApps: true)
      },
      setTimeZone: { model.setProductTimeZone($0) },
      setDictationCaptions: { model.setDictationCaptions($0) },
      saveWord: { [self] id, written, heard in
        Task {
          dictionaryNote = await model.saveDictionaryWord(id: id, written: written, heard: heard)
        }
      },
      deleteWord: { [self] id in
        Task {
          await model.deleteDictionaryWord(id: id)
          dictionaryNote = nil
        }
      })
    var wired = actions
    wired.forgetLearnedForms = { [self] id in
      Task {
        await model.forgetLearnedForms(id: id)
        dictionaryNote = nil
      }
    }
    wired.setOtherAppsCanRead = { model.setOtherAppsCanRead($0) }
    wired.openAgentApp = { model.agentAccess.openApp = $0 }
    wired.stopAgentApp = { key in
      let name = Self.appName(key, agents: model.agentAccess)
      model.agentAccess.stop(clientKey: key)
      CaptureFeedback.shared.show(MemoryToast("已停止允许 \(name)", icon: .symbol("checkmark")))
    }
    wired.undoAgentChange = { id in
      guard let uuid = UUID(uuidString: id) else { return }
      model.undoAgentChange(uuid)
    }
    wired.exportAgentRecords = { model.exportAgentRecords(clientKey: $0) }
    wired.setWordEnabled = { [self] id, on in
      Task {
        dictionaryNote = await model.setDictionaryWordEnabled(id: id, on: on)
        dictionaryStatus = nil
      }
    }
    wired.importWords = { [self] in
      Task {
        let outcome = await model.importDictionaryWords()
        dictionaryNote = outcome.note
        dictionaryStatus = outcome.status
      }
    }
    wired.exportWords = { [self] json in
      Task {
        let outcome = await model.exportDictionaryWords(json: json)
        dictionaryNote = outcome.note
        dictionaryStatus = outcome.status
      }
    }
    wired.showAgentRequests = { model.agentAccess.showRequests() }
    var meeting = SettingsTencentMeetingActions()
    meeting.setOn = { model.setEntry(.tencentMeeting, on: $0) }
    meeting.act = { model.actOnTencentStatus() }
    meeting.openInBrowser = { model.openTencentAuthorizationInBrowser() }
    meeting.cancelConnecting = { model.cancelTencentConnecting() }
    meeting.retryConnecting = { model.connectTencentMeeting() }
    meeting.answer = { model.answerTencentBackfill(add: $0) }
    meeting.checkNow = { model.checkTencentMeetingNow() }
    meeting.openRow = { model.openTencentRecordingPage($0) }
    wired.tencentMeeting = meeting
    wired.refreshDictationMetrics = { model.refreshDictationMetrics() }
    let web = model.webLookup
    wired.setWebLookup = { web.setEnabled($0) }
    wired.addSearchKey = { web.addKey(service: $0, key: $1) }
    wired.removeSearchKey = { web.removeKey(service: $0) }
    wired.likelySearchService = { web.likelyService(forKey: $0) }
    wired.clearNetworkActivity = { web.clearActivity() }
    return wired
  }

  private func openPairing() {
    guard phone.pairingCode == nil, !phone.working else { return }
    model.connectIPhone()
    pairingOpenedAt = Date()
  }

  private func closePairing() {
    model.finishPhonePairingCode()
    pairingOpenedAt = nil
  }

  // MARK: Rows

  private var entryRows: [SettingsEntry] {
    MindloomSettingsState.defaultEntries.map { row in
      SettingsEntry(
        id: row.id, symbol: row.symbol, title: row.title, detail: row.detail,
        isOn: model.isMindloomEntryOn(row.id), enabled: row.id != "fn" || !model.fnHeldByOtherApp)
    }
  }

  // MARK: 其他 App (v12 F6)

  static func appName(_ key: String, agents: AgentAccessModel) -> String {
    agents.connected[key]?.displayName ?? agents.grants.first { $0.clientKey == key }?.clientName
      ?? agents.audit.first { $0.clientKey == key }?.clientName
      ?? agents.changes.first { $0.clientKey == key }?.clientName ?? "此 App"
  }

  /// Every App allowed now or seen in the records, the most recent first.
  private var agentApps: [SettingsAgentApp] {
    var order: [String] = []
    var last: [String: Date] = [:]
    func see(_ key: String, _ at: Date) {
      if last[key] == nil { order.append(key) }
      last[key] = max(last[key] ?? .distantPast, at)
    }
    for grant in agents.grants { see(grant.clientKey, grant.createdAt) }
    for record in agents.audit where record.clientName != "unknown" {
      see(record.clientKey, record.at)
    }
    for change in agents.changes { see(change.clientKey, change.at) }
    return order.sorted { (last[$0] ?? .distantPast) > (last[$1] ?? .distantPast) }.map(app)
  }

  private func app(_ key: String) -> SettingsAgentApp {
    let grants = agents.grants.filter { grant in
      // An old rope grant covers nothing and is dropped at the agent's next
      // request (the owner is asked again); it is not shown as active.
      if case .ropes = grant.terms.range { return false }
      return grant.clientKey == key
    }
    let place =
      agents.connected[key]?.whoLine
      ?? grants.first.map { "程序位置：\($0.clientPath)" } ?? "未连接"
    let lastAt = agents.audit.first { $0.clientKey == key }?.at
    return SettingsAgentApp(
      id: key, name: Self.appName(key, agents: agents), place: place,
      allowed: grants.first.map {
        AgentAccessModel.allowedText($0) { MindloomTitles.shared.matter($0) }
      },
      grantIDs: grants.map(\.grantID.uuidString), lastUsed: lastAt.map(Self.when))
  }

  /// The open App's page.
  private var agentDetail: SettingsAgentDetail? {
    guard let key = agents.openApp else { return nil }
    let spaceNames = Dictionary(
      (agents.spaces?.agentInputs() ?? []).map { ($0.spaceID, $0.name) },
      uniquingKeysWith: { first, _ in first })
    let records = agents.pageAudit.prefix(200).map { record -> SettingsAgentRecord in
      SettingsAgentRecord(
        id: String(record.id), when: Self.when(record.at),
        what: Self.recordWords(record, spaceNames: spaceNames),
        outcome: AgentAccessModel.outcomeName(record.outcome),
        refused: record.outcome != .allowed)
    }
    let changes = agents.changes.filter { $0.clientKey == key }.map {
      SettingsAgentChange(
        id: $0.changeID.uuidString, when: Self.when($0.at), summary: $0.summary,
        undone: $0.state == .undone)
    }
    return SettingsAgentDetail(
      app: app(key), changes: changes, records: Array(records),
      recordCount: agents.pageAuditCount)
  }

  /// 「读一件事 · 「TES 论文…」」, 「找 · 3 件事」, 「找 · 共享空间「实验室」的 2 件事」.
  static func recordWords(_ record: AgentAuditRecord, spaceNames: [String: String]) -> String {
    let tool = AgentAccessModel.toolName(record.tool)
    var mine: [String] = []
    var shared: [String: Int] = [:]
    for id in record.matterIDs {
      if let space = AgentSpaceAccess.space(ofMatter: id) {
        shared[space, default: 0] += 1
      } else {
        mine.append(id)
      }
    }
    var parts: [String] = []
    if mine.count == 1 {
      parts.append("“\(MindloomTitles.shared.matter(mine[0]) ?? "一件事")”")
    } else if mine.count > 1 {
      parts.append("\(mine.count) 件事")
    }
    for (space, count) in shared.sorted(by: { $0.key < $1.key }) {
      parts.append("共享空间“\(spaceNames[space] ?? space)”的 \(count) 件事")
    }
    return parts.isEmpty ? tool : tool + " · " + parts.joined(separator: "、")
  }

  /// 「今天 21:12」 / 「9月18日 21:12」.
  static func when(_ date: Date) -> String {
    let calendar = Calendar.current
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_Hans")
    f.dateFormat = calendar.isDateInToday(date) ? "'今天' HH:mm" : "M月d日 HH:mm"
    return f.string(from: date)
  }

  /// 「9月18日起连接 · 最近一次送来 21:58」.
  static func phoneDetail(_ paired: Date, last: Date?) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_Hans")
    f.dateFormat = "M月d日"
    var text = "\(f.string(from: paired))起连接"
    if let last {
      f.dateFormat = Calendar.current.isDateInToday(last) ? "HH:mm" : "M月d日 HH:mm"
      text += " · 最近一次发送 \(f.string(from: last))"
    }
    return text
  }

  /// One line when the link refuses for a reason the user can act on.
  static func linkNote(_ status: RemoteOrganizerLinkController.Status, enabled: Bool) -> String? {
    guard enabled else { return nil }
    switch status {
    case .refused(.refusedRealLibrary), .refused(.refusedNotSynthetic),
      .refused(.refusedLinkedStore):
      return "开发阶段，发送到 DGX Spark 的是演示资料；此资料库的内容保留在这台 Mac 上。"
    case .wrongKey:
      return "DGX Spark 上储存着另一台 Mac 的内容。删除这些内容后，才能整理你的内容。"
    case .unsupportedService, .keyUnavailable, .storageUnavailable:
      return "这台 Mac 暂时无法发送；新添加的内容暂存在这里。"
    default:
      return nil
    }
  }

  static var macName: String {
    (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "这台 Mac"
  }

  /// 「1.0（10）」.
  static var version: String {
    let bundle = Bundle.main
    let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    return "\(short)（\(build)）"
  }
}

// MARK: - 入口 switches

extension DictationAppModel {
  /// The 13 rows of Settings › 入口 (MAC-SPEC §9.1) on the App's switches.
  func isMindloomEntryOn(_ id: String) -> Bool {
    switch id {
    case "fn": return fnEntryEnabled
    case "meeting": return menuBarEnabled
    case "iphone": return iphoneEntryEnabled
    default: return Self.entryKind(id).map { entries.isOn($0) } ?? false
    }
  }

  func setMindloomEntry(_ id: String, on: Bool) {
    switch id {
    case "fn":
      fnEntryEnabled = on
    case "meeting":
      updateMenuBarInsertion(on)
    case "iphone":
      iphoneEntryEnabled = on
    default:
      guard let kind = Self.entryKind(id) else { return }
      setEntry(kind, on: on)
      // A watcher with nothing to watch asks what to watch.
      if on, kind == .folderWatch, entries.settings.folders.isEmpty { addWatchedFolders() }
      if on, kind == .git, entries.settings.repositories.isEmpty { addWatchedRepository() }
    }
  }

  static func entryKind(_ id: String) -> EntryKind? {
    switch id {
    case "share": .shareSheet
    case "services": .services
    case "chrome": .browserExtension
    case "shortcuts": .shortcuts
    case "cli": .commandLine
    case "folder": .folderWatch
    case "calendar": .calendar
    case "reminders": .reminders
    case "git": .git
    case "zotero": .zotero
    default: nil
    }
  }

  /// 「按住 fn 说话」 (Settings › 入口): off means fn is not intercepted at all.
  var fnEntryEnabled: Bool {
    get { LocalPreferenceStore.defaults.object(forKey: Self.fnEntryKey) as? Bool ?? true }
    set {
      LocalPreferenceStore.defaults.set(newValue, forKey: Self.fnEntryKey)
      objectWillChange.send()
      FnGuard.shared.update()
    }
  }

  /// 「iPhone 键盘和分享」: off leaves what the iPhone sends on the DGX Spark
  /// (nothing is taken in here until it is on again).
  var iphoneEntryEnabled: Bool {
    get { LocalPreferenceStore.defaults.object(forKey: Self.iphoneEntryKey) as? Bool ?? true }
    set {
      LocalPreferenceStore.defaults.set(newValue, forKey: Self.iphoneEntryKey)
      objectWillChange.send()
    }
  }

  static let fnEntryKey = "preferences.v11.fn-entry"
  static let iphoneEntryKey = "preferences.v11.iphone-entry"
}
