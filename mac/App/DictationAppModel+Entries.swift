import AppKit
import BestASRDomain
import BestASREntries
import BestASRIntake
import BestASRMemory
import BestASRMemoryUI
import BestASRRemoteOrganizer
import EventKit
import Foundation
import MindloomAgentProtocol
import MindloomShareDrop

/// Every way into 织机 besides paste and drop (V8 contract §A, PRD §12.12
/// ENTRY-001–012): the share extension 「收进织机」, the Services menu, the
/// Chrome extension, Shortcuts, the `mindloom` command line, watched folders,
/// the calendar,
/// Reminders write-back, Git and Zotero. Each one hands its things to the
/// same intake path as a paste or a drop (`EntryCommitter`: the intake
/// processor, the store's `createUserItem`, the staged files' commit), keeps
/// its source and time, and is listed in Settings → 入口 with its own switch.
/// Nothing captures in the background until the owner switches it on.
extension DictationAppModel {
  // MARK: Setup

  /// Called once the durable library is open, with the root it was opened on.
  func configureEntries(dataRoot: URL) {
    guard !BestASRProcessEnvironment.isXCTestHost, entries.folder == nil else { return }
    let folder = EntryFolder(dataRoot: dataRoot)
    folder.prepare()
    entries.folder = folder
    entries.settings = folder.loadSettings()
    entries.folderState =
      folder.loadState(.folderWatch, as: FolderWatchState.self) ?? FolderWatchState()
    entries.calendarState =
      folder.loadState(.calendar, as: CalendarSyncState.self) ?? CalendarSyncState()
    entries.gitState = folder.loadState(.git, as: GitWatchState.self) ?? GitWatchState()
    entries.zoteroState = folder.loadState(.zotero, as: ZoteroWatchState.self) ?? ZoteroWatchState()
    entries.dropbox = ShareDropbox.inLibrary(dataRoot)
    entries.calendarAccess = entries.calendarReader.access()
    refreshBrowserHostStatus()
    entries.isReady = true
    EntryHub.shared.model = self
    applyEntrySettings()
  }

  /// The owner's command line (A3) and the Chrome extension's native
  /// messaging host (A6) on the agents' private socket, each behind its own
  /// switch.
  func entryOwnerChannel() -> OwnerEntryChannel {
    OwnerEntryChannel(
      isEnabled: { [weak self] kind in
        await MainActor.run { self?.entries.isOn(kind) ?? false }
      },
      add: { [weak self] request in
        guard let self else { return .notReady }
        return await self.ownerAdd(request)
      },
      due: { [weak self] days in
        guard let self else { return .notReady }
        return await self.ownerDue(days)
      },
      browserAdd: { [weak self] request in
        guard let self else { return .notReady }
        return await self.ownerBrowserAdd(request)
      })
  }

  // MARK: Switches

  func setEntry(_ kind: EntryKind, on: Bool) {
    guard entries.isOn(kind) != on else { return }
    if kind == .browserExtension {
      setBrowserEntry(on: on)
      return
    }
    entries.settings.set(kind, on: on)
    if !on, kind.capturesInBackground {
      // Switching on again starts from then, never from what happened
      // while it was off.
      entries.folder?.clearState(kind)
      switch kind {
      case .folderWatch: entries.folderState = FolderWatchState()
      case .calendar: entries.calendarState = CalendarSyncState()
      case .git: entries.gitState = GitWatchState()
      case .zotero: entries.zoteroState = ZoteroWatchState()
      default: break
      }
      entries.note(kind, nil)
    }
    saveEntrySettings()
    applyEntrySettings()
    if on, kind == .calendar {
      Task { [weak self] in await self?.requestCalendarAccess() }
    }
  }

  /// After the owner changed what an entry watches.
  func entrySettingsChanged() {
    saveEntrySettings()
    applyEntrySettings()
  }

  func saveEntrySettings() {
    do {
      try entries.folder?.save(entries.settings)
    } catch {
      intake.show("入口设置没能保存；请再试一次")
    }
  }

  func applyEntrySettings() {
    guard entries.isReady else { return }
    applyShareEntry()
    for kind in [EntryKind.folderWatch, .calendar, .git, .zotero] {
      if entries.isOn(kind) {
        if entries.loops[kind] == nil { startEntryLoop(kind) }
      } else {
        entries.loops[kind]?.cancel()
        entries.loops[kind] = nil
      }
    }
    if entries.isOn(.folderWatch) {
      if entries.folderMonitor == nil {
        entries.folderMonitor = FolderChangeMonitor { [weak self] in
          Task { @MainActor in self?.scheduleFolderScan(after: .milliseconds(700)) }
        }
      }
      entries.folderMonitor?.watch(entries.settings.folders.map(\.path))
      FolderWatchEngine.prune(&entries.folderState, keeping: entries.settings.folders)
      scheduleFolderScan(after: .milliseconds(300))
    } else {
      entries.folderMonitor?.stop()
      entries.folderMonitor = nil
      entries.folderScan?.cancel()
    }
    if entries.isOn(.calendar), entries.calendarObserver == nil {
      entries.calendarObserver = NotificationCenter.default.addObserver(
        forName: .EKEventStoreChanged, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in await self?.syncCalendar() }
      }
    } else if !entries.isOn(.calendar), let observer = entries.calendarObserver {
      NotificationCenter.default.removeObserver(observer)
      entries.calendarObserver = nil
    }
  }

  private func startEntryLoop(_ kind: EntryKind) {
    let interval: Duration =
      switch kind {
      case .folderWatch: .seconds(60)
      case .calendar: .seconds(600)
      case .git: .seconds(120)
      default: .seconds(180)
      }
    entries.loops[kind] = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        switch kind {
        case .folderWatch: await self.scanFolders()
        case .calendar: await self.syncCalendar()
        case .git: await self.syncGit()
        case .zotero: await self.syncZotero()
        default: return
        }
        try? await Task.sleep(for: interval)
      }
    }
  }

  // MARK: The shared intake path

  /// Commits entry items exactly as a paste or a drop is committed, queues
  /// audio and video for the one-at-a-time import, and (for the entries the
  /// owner triggers) shows the same confirmation.
  @discardableResult
  func commitEntryItems(
    _ items: [EntryIntakeItem], source: ItemSourceApplication?, refused: [String] = [],
    announce: Bool
  ) async -> EntryCommitSummary {
    guard let processor = intakeProcessor, let repository else {
      var summary = EntryCommitSummary()
      summary.rejected = ["资料库尚未打开；未收进来"]
      if announce { intake.show(summary.rejected[0]) }
      return summary
    }
    let ready = intakeReady
    let committer = EntryCommitter(
      processor: processor, store: repository, ready: { await ready?.value })
    var summary = items.isEmpty ? EntryCommitSummary() : await committer.commit(items)
    summary.rejected = refused + summary.rejected
    for url in summary.media {
      intake.pendingMediaImports.append(.init(url: url, source: source))
    }
    let wasImporting = capture.importInProgress
    let refusal = summary.media.isEmpty ? nil : startNextQueuedMediaImport()
    if announce {
      let text = IntakeConfirmation.text(
        stored: summary.storedCount,
        mediaStarted: !summary.media.isEmpty && !wasImporting && capture.importInProgress,
        mediaWaiting: summary.media.isEmpty ? 0 : intake.pendingMediaImports.count,
        rejected: summary.rejected, source: source)
      intake.show(
        refusal.map { summary.storedCount > 0 ? "\(text)；\($0)" : $0 } ?? text,
        item: summary.storedCount == 1 && refusal == nil && summary.rejected.isEmpty
          ? summary.stored.first : nil,
        source: source?.name)
    }
    if summary.storedCount > 0 {
      await refreshHistoryItems(preserveStatus: true, organizeEvents: true)
    }
    return summary
  }

  /// The text a hand-triggered entry answers with.
  private func confirmation(_ summary: EntryCommitSummary, source: ItemSourceApplication?)
    -> String
  {
    IntakeConfirmation.text(
      stored: summary.storedCount, mediaStarted: false, mediaWaiting: summary.media.count,
      rejected: summary.rejected, source: source)
  }

  // MARK: Share extension (A1)

  func applyShareEntry() {
    guard let dropbox = entries.dropbox else { return }
    if entries.isOn(.shareSheet) {
      guard dropbox.prepareFolder() else {
        entries.note(.shareSheet, "分享文件夹没能建立；分享暂时收不进来")
        return
      }
      if entries.dropboxMonitor == nil {
        let monitor = FolderChangeMonitor { [weak self] in
          Task { @MainActor in self?.pickUpShares() }
        }
        monitor.watch([dropbox.directory.path])
        entries.dropboxMonitor = monitor
      }
      pickUpShares()
    } else {
      entries.dropboxMonitor?.stop()
      entries.dropboxMonitor = nil
      // Shares made while it was on are still taken; then the folder goes,
      // so the extension says sharing is off.
      Task { [weak self] in
        guard let self else { return }
        await takeShares(dropbox)
        // Unless it was switched on again meanwhile.
        if !entries.isOn(.shareSheet) { dropbox.removeFolder() }
      }
    }
  }

  /// The extension poked the App (`mindloom://share-inbox`), or the drop
  /// folder changed.
  func pickUpShares() {
    guard entries.isReady, entries.isOn(.shareSheet), let dropbox = entries.dropbox,
      !entries.shareInFlight
    else { return }
    entries.shareInFlight = true
    Task { [weak self] in
      await self?.takeShares(dropbox)
      self?.entries.shareInFlight = false
    }
  }

  private func takeShares(_ dropbox: ShareDropbox) async {
    let (pending, malformed) = await Self.readShares(dropbox)
    for share in pending {
      let (items, refused) = await Self.shareItems(share)
      let source =
        ItemSourceApplication(bundleID: share.entry.sourceBundleID, name: share.entry.sourceName)
        ?? EntrySource.named(EntrySource.shareFallback)
      let summary = await commitEntryItems(items, source: source, refused: refused, announce: true)
      // Taken (or refused for good): the drop is removed. A library that is
      // not open keeps it for later.
      if intakeProcessor != nil, repository != nil { dropbox.remove(share) }
      entries.note(.shareSheet, EntriesModel.took(summary.storedCount))
    }
    if malformed > 0 {
      intake.show("有 \(malformed) 条分享读不出来，没有收进来")
    }
  }

  private nonisolated static func readShares(_ dropbox: ShareDropbox) async -> (
    [ShareDropbox.Pending], Int
  ) {
    let result = dropbox.pending()
    return (result.entries, result.removedMalformed)
  }

  private nonisolated static func shareItems(_ share: ShareDropbox.Pending) async -> (
    [EntryIntakeItem], [String]
  ) {
    let result = HandEntries.items(from: share)
    return (result.items, result.refused)
  }

  // MARK: Services menu (A1)

  /// "收进织机" from another App's Services menu: the selected text, with that
  /// App as the source.
  func receiveServicesText(_ text: String) {
    guard entries.isOn(.services) else {
      intake.show("服务菜单「收进织机」没有打开：在设置 → 入口 里打开")
      return
    }
    let front = NSWorkspace.shared.frontmostApplication
    let source =
      front?.bundleIdentifier == Bundle.main.bundleIdentifier
      ? nil : ItemSourceApplication(bundleID: front?.bundleIdentifier, name: front?.localizedName)
    let items = HandEntries.servicesText(text, source: source, at: Date())
    guard !items.isEmpty else {
      intake.show("选中的内容里没有文字，未收进来")
      return
    }
    Task { [weak self] in
      await self?.commitEntryItems(items, source: source, announce: true)
    }
  }

  // MARK: Shortcuts (A2)

  /// 「添加到织机」.
  func addFromShortcut(text: String?, url: URL?, file: (Data, String, String?)?) async -> String {
    guard entries.isOn(.shortcuts) else { return "快捷指令入口已在织机的 设置 → 入口 里关闭" }
    let items: [EntryIntakeItem]
    do {
      items = try HandEntries.shortcut(
        text: text, url: url?.absoluteString, file: file.map { ($0.0, $0.1, $0.2) }, at: Date())
    } catch {
      return "文件没能读出来，未收进来"
    }
    guard !items.isEmpty else { return "没有要收进来的内容" }
    let source = EntrySource.named(EntrySource.shortcuts)
    let summary = await commitEntryItems(items, source: source, announce: true)
    return confirmation(summary, source: source)
  }

  /// 「织机：今天到期」 and `mindloom due`: read-only, from this Mac's pages.
  func dueText(days: Int) async -> (heading: String, lines: [String]) {
    guard let inputs = await memoryProjectionInputs() else {
      return (OwnerChannel.notReadyMessage, [])
    }
    let due = await Self.dueEntries(inputs, days: days)
    return DueList.render(due, days: days)
  }

  private nonisolated static func dueEntries(_ inputs: MemoryProjectionInputs, days: Int) async
    -> [DueEntry]
  {
    DueList.entries(inputs.projection(), now: inputs.now, days: days)
  }

  // MARK: Command line (A3)

  func ownerAdd(_ request: OwnerAddRequest) async -> OwnerOutcome {
    guard intakeProcessor != nil, repository != nil else { return .notReady }
    let (items, refused) = HandEntries.commandLine(request, at: Date())
    let source = EntrySource.named(EntrySource.commandLine)
    let summary = await commitEntryItems(
      items, source: source, refused: refused, announce: true)
    guard summary.storedCount > 0 || !summary.media.isEmpty else {
      return .refused(summary.rejected.first ?? "没有可收进来的内容")
    }
    return .reply(
      OwnerReply(message: confirmation(summary, source: source), stored: summary.storedCount))
  }

  func ownerDue(_ days: Int) async -> OwnerOutcome {
    guard repository != nil else { return .notReady }
    let (heading, lines) = await dueText(days: days)
    return .reply(OwnerReply(message: heading, lines: lines))
  }

  /// A command that links the bundled helper as `mindloom` in `~/.local/bin`.
  func copyCommandLineInstall() {
    let command =
      "mkdir -p ~/.local/bin && ln -sf \"\(agentAccess.helperPath)\" ~/.local/bin/mindloom"
    let board = NSPasteboard.general
    board.clearContents()
    board.setString(command, forType: .string)
    // 织机's own copy: ⌘V here does not take it in as an item.
    board.setData(Data(), forType: IntakePasteboardMarks.ownOrigin)
    intake.show("已复制安装命令：在终端里运行，然后就能用 mindloom add …")
  }

  // MARK: Chrome extension (A6)

  func ownerBrowserAdd(_ request: BrowserAddRequest) async -> OwnerOutcome {
    guard intakeProcessor != nil, repository != nil else { return .notReady }
    let items = HandEntries.browser(request, at: Date())
    let source = EntrySource.named(EntrySource.browser)
    let summary = await commitEntryItems(items, source: source, announce: true)
    guard summary.storedCount > 0 else {
      return .refused(summary.rejected.first ?? "没有可收进来的内容")
    }
    return .reply(
      OwnerReply(message: confirmation(summary, source: source), stored: summary.storedCount))
  }

  /// The switch is the click that writes (on) or removes (off) Chrome's host
  /// manifest; nothing else touches that file.
  func setBrowserEntry(on: Bool) {
    guard let manifest = BrowserHostManifest.chrome() else {
      entries.note(.browserExtension, "找不到这个账户的用户文件夹")
      return
    }
    if on {
      do {
        try manifest.install(helperPath: agentAccess.helperPath)
        entries.settings.set(.browserExtension, on: true)
        entries.note(.browserExtension, "已经连上 Chrome。在 Chrome 里装好扩展后，就能右键「收进织机」。")
      } catch let error as BrowserHostManifest.ManifestError {
        entries.note(.browserExtension, Self.browserManifestProblem(error))
        refreshBrowserHostStatus()
        return
      } catch {
        entries.note(.browserExtension, Self.browserManifestProblem(.write))
        refreshBrowserHostStatus()
        return
      }
    } else {
      entries.settings.set(.browserExtension, on: false)
      do {
        try manifest.remove()
        entries.note(.browserExtension, nil)
      } catch {
        entries.note(.browserExtension, "已关闭；但 Chrome 文件夹里的连接文件没能删掉，请稍后再关一次")
      }
    }
    saveEntrySettings()
    refreshBrowserHostStatus()
  }

  /// Re-writes the manifest for this copy of the App (it moved, or the file
  /// was removed by hand), only on the owner's click.
  func reinstallBrowserHost() {
    guard let manifest = BrowserHostManifest.chrome() else { return }
    do {
      try manifest.install(helperPath: agentAccess.helperPath)
      entries.note(.browserExtension, "已重新连上 Chrome")
    } catch let error as BrowserHostManifest.ManifestError {
      entries.note(.browserExtension, Self.browserManifestProblem(error))
    } catch {
      entries.note(.browserExtension, Self.browserManifestProblem(.write))
    }
    refreshBrowserHostStatus()
  }

  /// Removes a manifest left behind while the entry is off, on the owner's
  /// click.
  func removeBrowserHost() {
    guard let manifest = BrowserHostManifest.chrome() else { return }
    do {
      try manifest.remove()
      entries.note(.browserExtension, nil)
    } catch {
      entries.note(.browserExtension, "Chrome 文件夹里的连接文件没能删掉")
    }
    refreshBrowserHostStatus()
  }

  func refreshBrowserHostStatus() {
    entries.browserHost =
      BrowserHostManifest.chrome()?.status(helperPath: agentAccess.helperPath) ?? .absent
  }

  /// The extension folder bundled in the App, for Chrome's 「加载已解压的扩展程序」.
  var bundledChromeExtension: URL? {
    Bundle.main.url(forResource: "chrome-extension", withExtension: nil)
  }

  func revealChromeExtension() {
    guard let folder = bundledChromeExtension else {
      intake.show("这个版本的织机没有带 Chrome 扩展文件夹")
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([folder])
  }

  static func browserManifestProblem(_ error: BrowserHostManifest.ManifestError) -> String {
    switch error {
    case .browserMissing: "这台 Mac 上没有找到 Chrome（先装好并打开一次 Chrome）"
    case .helperMissing: "织机自带的连接程序不见了，请重新安装织机"
    case .notAFile: "Chrome 文件夹里同名的东西不是文件，没有改动它"
    case .write, .remove: "没能写入 Chrome 的连接文件"
    }
  }

  // MARK: Folders (A4)

  func addWatchedFolders() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.prompt = "监视这个文件夹"
    panel.message = "选好的文件夹里新出现的文件会被收进织机。已有的文件不收。"
    guard panel.runModal() == .OK else { return }
    let protected = intakeProcessor?.pathPolicy
    for url in panel.urls {
      let path = url.standardizedFileURL.path
      guard !entries.settings.folders.contains(where: { $0.path == path }) else { continue }
      // A folder of the library itself is never watched.
      if let protected, protected.isProtected(url.appendingPathComponent("x")) {
        intake.show("这是织机资料库里的文件夹，不能监视")
        continue
      }
      entries.settings.folders.append(WatchedFolder(path: path))
    }
    entrySettingsChanged()
  }

  func removeWatchedFolder(_ id: UUID) {
    entries.settings.folders.removeAll { $0.id == id }
    entrySettingsChanged()
  }

  func updateWatchedFolder(_ folder: WatchedFolder) {
    guard let index = entries.settings.folders.firstIndex(where: { $0.id == folder.id }) else {
      return
    }
    entries.settings.folders[index] = folder
    entrySettingsChanged()
  }

  func scheduleFolderScan(after delay: Duration) {
    entries.folderScan?.cancel()
    entries.folderScan = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await self?.scanFolders()
    }
  }

  func scanFolders() async {
    guard entries.isOn(.folderWatch), intakeProcessor != nil else { return }
    let settings = entries.settings
    var state = entries.folderState
    let policy = intakeProcessor?.pathPolicy ?? .none
    let decisions = await Self.lookAtFolders(settings, state: &state, policy: policy)
    // Switched off while looking: nothing is taken and nothing remembered.
    guard entries.isOn(.folderWatch) else { return }
    entries.folderState = state
    try? entries.folder?.saveState(state, for: .folderWatch)
    var skipped: [String] = []
    for (folder, list) in decisions {
      var items: [EntryIntakeItem] = []
      for decision in list {
        switch decision {
        case .take(let url, let created):
          items.append(FolderWatchEngine.item(url, createdAt: created, folder: folder))
        case .skip(let name, let reason):
          skipped.append("\(folder.displayName) · \(name)：\(reason)")
        }
      }
      guard !items.isEmpty else { continue }
      let source = EntrySource.named(EntrySource.folder(folder.displayName))
      let summary = await commitEntryItems(items, source: source, announce: true)
      entries.note(.folderWatch, EntriesModel.took(summary.storedCount))
    }
    if !skipped.isEmpty {
      entries.folderSkips = Array((skipped.reversed() + entries.folderSkips).prefix(20))
    }
    if FolderWatchEngine.hasSettling(state) { scheduleFolderScan(after: .seconds(2)) }
  }

  private nonisolated static func lookAtFolders(
    _ settings: EntrySettings, state: inout FolderWatchState, policy: IntakePathPolicy
  ) async -> [(WatchedFolder, [FolderWatchDecision])] {
    var result: [(WatchedFolder, [FolderWatchDecision])] = []
    for folder in settings.folders {
      guard let listing = FolderListingEntry.list(folder.url) else { continue }
      let decisions = FolderWatchEngine.scan(
        folder, listing: listing, paused: settings.foldersPaused || folder.paused, state: &state,
        isProtected: policy.isProtected)
      if !decisions.isEmpty { result.append((folder, decisions)) }
    }
    return result
  }

  // MARK: Calendar (A5)

  func requestCalendarAccess() async {
    let reader = entries.calendarReader
    var granted = reader.access() == .granted
    if !granted { granted = await reader.requestAccess() }
    entries.calendarAccess = reader.access()
    guard granted else {
      entries.settings.set(.calendar, on: false)
      saveEntrySettings()
      applyEntrySettings()
      entries.note(.calendar, "没有得到日历权限；可以在 系统设置 → 隐私与安全性 → 日历 里允许织机")
      return
    }
    entries.calendars = reader.calendars()
    if entries.settings.calendarIDs.isEmpty {
      entries.note(.calendar, "请选择要读取的日历")
    } else {
      await syncCalendar()
    }
  }

  func setCalendar(_ id: String, chosen: Bool) {
    var ids = entries.settings.calendarIDs.filter { $0 != id }
    if chosen { ids.append(id) }
    entries.settings.calendarIDs = ids
    saveEntrySettings()
    Task { [weak self] in await self?.syncCalendar() }
  }

  func syncCalendar() async {
    guard entries.isOn(.calendar) else { return }
    let reader = entries.calendarReader
    entries.calendarAccess = reader.access()
    guard entries.calendarAccess == .granted else {
      entries.note(.calendar, "需要日历权限：系统设置 → 隐私与安全性 → 日历")
      return
    }
    entries.calendars = reader.calendars()
    let chosen = entries.settings.calendarIDs
    guard !chosen.isEmpty else {
      entries.note(.calendar, "请选择要读取的日历")
      return
    }
    let now = Date()
    let events = await Self.readCalendar(reader, chosen: chosen, now: now)
    guard entries.isOn(.calendar) else { return }
    var state = entries.calendarState
    let items = CalendarSync.plan(events, chosen: chosen, state: &state, now: now)
    let summary = await commitEntryItems(
      items, source: EntrySource.named(EntrySource.calendar), announce: false)
    // A failed commit keeps the old state, so the next pass tries again
    // (items with fixed IDs are never taken twice).
    if summary.rejected.isEmpty, entries.isOn(.calendar) {
      entries.calendarState = state
      try? entries.folder?.saveState(state, for: .calendar)
    }
    entries.note(.calendar, EntriesModel.took(summary.storedCount))
  }

  private nonisolated static func readCalendar(
    _ reader: EventKitCalendarReader, chosen: [String], now: Date
  ) async -> [CalendarEventSnapshot] {
    let (start, end) = CalendarSync.window(now: now)
    return reader.events(from: start, to: end, calendarIDs: chosen)
  }

  // MARK: Reminders (A5)

  /// 把下一步加到提醒事项: one reminder, on this click only.
  func addNextStepToReminders(_ request: MemoryReminderRequest) {
    guard entries.isOn(.reminders) else { return }
    let draft = ReminderDraft.nextStep(
      text: request.text, day: request.date, matterTitle: request.matterTitle)
    let writer = entries.remindersWriter
    Task { [weak self] in
      let result = await writer.add(draft)
      guard let self else { return }
      switch result {
      case .added(let list):
        intake.show("已加到提醒事项「\(list)」（只在这台 Mac 上）")
        entries.note(.reminders, "刚加了一条到「\(list)」")
      case .addedSynced(let list, let account):
        // V8R-18: say plainly that this one leaves the Mac through the account.
        intake.show("已加到提醒事项「\(list)」：这个列表经「\(account)」同步，下一步的文字和事情名会跟着同步出去")
        entries.note(.reminders, "刚加了一条到「\(list)」（经\(account)同步）")
      case .denied:
        intake.show("没有得到提醒事项权限；可以在 系统设置 → 隐私与安全性 → 提醒事项 里允许织机")
      case .failed:
        intake.show("没能加到提醒事项；请再试一次")
      }
    }
  }

  // MARK: Git (A7)

  func addWatchedRepository() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "监视这个仓库"
    panel.message = "选一个本机的 Git 仓库（也可以是 Overleaf 的 git 克隆）。只读提交记录，不读文件内容。"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard let runner = entries.gitRunner else {
      intake.show("这台 Mac 上没有找到 git（需要 Xcode 或命令行工具）")
      return
    }
    let path = url.standardizedFileURL.path
    guard !entries.settings.repositories.contains(where: { $0.path == path }) else { return }
    guard let branch = runner.currentBranch(in: url) else {
      intake.show("这个文件夹不是 Git 仓库，或者没有检出分支")
      return
    }
    let repository = WatchedRepository(path: path, branches: [branch])
    entries.settings.repositories.append(repository)
    entries.repositoryBranches[repository.id] = runner.branches(in: url)
    entrySettingsChanged()
  }

  func removeWatchedRepository(_ id: UUID) {
    entries.settings.repositories.removeAll { $0.id == id }
    entrySettingsChanged()
  }

  func setRepositoryBranch(_ id: UUID, branch: String, watched: Bool) {
    guard let index = entries.settings.repositories.firstIndex(where: { $0.id == id }) else {
      return
    }
    var branches = entries.settings.repositories[index].branches.filter { $0 != branch }
    if watched { branches.append(branch) }
    entries.settings.repositories[index].branches = branches
    entrySettingsChanged()
  }

  func loadRepositoryBranches() {
    guard let runner = entries.gitRunner else { return }
    for repository in entries.settings.repositories {
      entries.repositoryBranches[repository.id] = runner.branches(
        in: URL(fileURLWithPath: repository.path, isDirectory: true))
    }
  }

  func syncGit() async {
    guard entries.isOn(.git) else { return }
    guard let runner = entries.gitRunner else {
      entries.note(.git, "这台 Mac 上没有找到 git（需要 Xcode 或命令行工具）")
      return
    }
    var state = entries.gitState
    let (items, problems) = await Self.planGit(
      entries.settings.repositories, runner: runner, state: &state)
    guard entries.isOn(.git) else { return }
    let summary = await commitEntryItems(items, source: nil, announce: false)
    if summary.rejected.isEmpty, entries.isOn(.git) {
      entries.gitState = state
      try? entries.folder?.saveState(state, for: .git)
    }
    entries.note(
      .git,
      problems.first.map { "\($0.repository)：\($0.message)" }
        ?? EntriesModel.took(summary.storedCount))
  }

  private nonisolated static func planGit(
    _ repositories: [WatchedRepository], runner: GitRunner, state: inout GitWatchState
  ) async -> ([EntryIntakeItem], [GitWatch.Status]) {
    let result = GitWatch.plan(repositories, runner: runner, state: &state, now: Date())
    return (result.items, result.problems)
  }

  // MARK: Zotero (A7)

  func syncZotero() async {
    guard entries.isOn(.zotero) else { return }
    var state = entries.zoteroState
    let outcome = await ZoteroWatch.pass(
      transport: entries.zoteroTransport, state: &state, now: Date())
    guard entries.isOn(.zotero) else { return }
    switch outcome {
    case .unavailable:
      entries.note(
        .zotero, "Zotero 没有在运行，或没有开放本地接口（Zotero 设置 → 高级 → 允许此电脑上的其他应用程序与 Zotero 通信）")
    case .items(let items):
      let summary = await commitEntryItems(
        items, source: EntrySource.named(EntrySource.zotero), announce: false)
      if summary.rejected.isEmpty, entries.isOn(.zotero) {
        entries.zoteroState = state
        try? entries.folder?.saveState(state, for: .zotero)
      }
      entries.note(.zotero, EntriesModel.took(summary.storedCount))
    }
  }

  /// "现在检查" in Settings.
  func checkEntryNow(_ kind: EntryKind) {
    Task { [weak self] in
      switch kind {
      case .folderWatch: await self?.scanFolders()
      case .calendar: await self?.syncCalendar()
      case .git: await self?.syncGit()
      case .zotero: await self?.syncZotero()
      case .shareSheet: self?.pickUpShares()
      default: break
      }
    }
  }
}
