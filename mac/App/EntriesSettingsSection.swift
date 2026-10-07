import AppKit
import BestASREntries
import SwiftUI

/// 设置 → 入口 (V8 contract §A): every way into 织机 with its own switch, in
/// plain words, and what the background ones watch. Folder, calendar, Git
/// and Zotero are off until the owner turns them on.
struct EntriesSettingsSections: View {
  @ObservedObject var model: DictationAppModel
  @ObservedObject var entries: EntriesModel

  init(model: DictationAppModel) {
    self.model = model
    entries = model.entries
  }

  var body: some View {
    Section {
      Text(
        "这些入口与粘贴、拖放相同：添加的内容都会记录来源和时间，并按同一规则处理（隐藏号码后发送整理，音视频储存在这台 Mac 上）。在后台自动添加内容的入口（文件夹、日历、Git、Zotero）默认关闭，打开后可以随时关闭。"
      )
      .font(.callout)
      if !entries.isReady {
        Text("资料库打开后才能设置入口。").font(.caption).foregroundStyle(.secondary)
      }
    }
    ForEach(EntryKind.settingsOrder) { kind in
      Section {
        entryToggle(kind)
        details(kind)
        if let note = entries.notes[kind] {
          Text(note).font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("bestASR.settings.entry.\(kind.rawValue).note")
        }
      }
    }
  }

  private func entryToggle(_ kind: EntryKind) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Toggle(
        isOn: Binding(
          get: { entries.isOn(kind) }, set: { model.setEntry(kind, on: $0) })
      ) {
        HStack(spacing: 6) {
          Text(kind.title).font(.headline)
          if kind.capturesInBackground {
            Text("后台").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
              .background(Color.secondary.opacity(0.15), in: Capsule())
          }
        }
      }
      .disabled(!entries.isReady)
      .accessibilityIdentifier("bestASR.settings.entry.\(kind.rawValue)")
      Text(kind.detail).font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private func details(_ kind: EntryKind) -> some View {
    switch kind {
    case .shareSheet:
      Text("首次使用：请在“系统设置”>“通用”>“登录项与扩展”>“共享”中勾选“Mindloom”。")
        .font(.caption).foregroundStyle(.secondary)
    case .services:
      Text("如果菜单中没有此项：请在“系统设置”>“键盘”>“键盘快捷键”>“服务”>“文本”中勾选“添加到 Mindloom”。")
        .font(.caption).foregroundStyle(.secondary)
    case .browserExtension:
      browserDetails
    case .shortcuts:
      Text("在“快捷指令”App 中搜索“Mindloom”即可找到这两个操作；也可以对 Siri 说“添加到 Mindloom”。")
        .font(.caption).foregroundStyle(.secondary)
    case .commandLine:
      if entries.isOn(.commandLine) {
        LabeledContent("程序") {
          Text(model.agentAccess.helperPath).font(.caption.monospaced()).textSelection(.enabled)
            .lineLimit(2)
        }
        HStack {
          Button("拷贝安装命令") { model.copyCommandLineInstall() }
          Spacer()
        }
        Text(
          "mindloom add \"一段话\" · mindloom add --file 路径 · echo 文字 | mindloom add · mindloom due"
        )
        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
      }
    case .folderWatch:
      if entries.isOn(.folderWatch) { folderDetails }
    case .calendar:
      if entries.isOn(.calendar) { calendarDetails }
    case .reminders:
      Text("打开一件事后，按钮位于步骤中。首次点按时，系统会请求提醒事项权限。")
        .font(.caption).foregroundStyle(.secondary)
    case .git:
      if entries.isOn(.git) { gitDetails }
    case .tencentMeeting:
      Text("连接腾讯会议和查看状态：“设置”>“入口”>“腾讯会议”。")
        .font(.caption).foregroundStyle(.secondary)
    case .zotero:
      if entries.isOn(.zotero) {
        Text("需要 Zotero 7 正在运行，并在 Zotero 设置 >“高级”中勾选“允许此电脑上的其他应用程序与 Zotero 通信”。仅添加打开此入口之后的新条目。")
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button("现在检查") { model.checkEntryNow(.zotero) }
          Spacer()
        }
      }
    }
  }

  // MARK: Chrome extension

  @ViewBuilder
  private var browserDetails: some View {
    let on = entries.isOn(.browserExtension)
    switch (on, entries.browserHost) {
    case (true, .installed):
      Text("Chrome 连接：已安装。打开开关时，Mindloom 会在 Chrome 的设置文件夹中添加一个连接文件；关闭开关时删除该文件。")
        .font(.caption).foregroundStyle(.secondary)
    case (true, .otherHelper), (true, .absent), (true, .unreadable):
      Text("找不到 Chrome 连接文件，或连接文件指向其他位置的 Mindloom。")
        .font(.caption).foregroundStyle(.orange)
      HStack {
        Button("重新连接 Chrome") { model.reinstallBrowserHost() }
        Spacer()
      }
    case (false, .installed), (false, .otherHelper), (false, .unreadable):
      Text("开关已关闭，但 Chrome 文件夹中仍有 Mindloom 的连接文件。")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("删除连接文件") { model.removeBrowserHost() }
        Spacer()
      }
    case (false, .absent):
      EmptyView()
    }
    Text(
      "安装扩展：在 Chrome 中打开 chrome://extensions，打开右上角的“开发者模式”，点按“加载已解压的扩展程序”，然后选择下方的文件夹。之后可以在网页上右键点按，或点按工具栏中的“添加到 Mindloom”按钮。"
    )
    .font(.caption).foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
    HStack {
      Button("在访达中显示扩展文件夹") { model.revealChromeExtension() }
        .disabled(model.bundledChromeExtension == nil)
        .accessibilityIdentifier("bestASR.settings.entry.revealChromeExtension")
      Spacer()
    }
    .onAppear { model.refreshBrowserHostStatus() }
  }

  // MARK: Folders

  @ViewBuilder
  private var folderDetails: some View {
    Toggle(
      "全部暂停",
      isOn: Binding(
        get: { entries.settings.foldersPaused },
        set: {
          entries.settings.foldersPaused = $0
          model.entrySettingsChanged()
        }))
    if entries.settings.folders.isEmpty {
      Text("未选择文件夹。").font(.caption).foregroundStyle(.secondary)
    }
    ForEach(entries.settings.folders) { folder in
      FolderRow(
        folder: folder, update: { model.updateWatchedFolder($0) },
        remove: { model.removeWatchedFolder(folder.id) })
    }
    HStack {
      Button("添加文件夹…") { model.addWatchedFolders() }
        .accessibilityIdentifier("bestASR.settings.entry.addFolder")
      Button("现在检查") { model.checkEntryNow(.folderWatch) }
      Spacer()
    }
    if !entries.folderSkips.isEmpty {
      DisclosureGroup("未添加的文件（\(entries.folderSkips.count)）") {
        ForEach(Array(entries.folderSkips.enumerated()), id: \.offset) { _, line in
          Text(line).font(.caption).foregroundStyle(.secondary)
        }
      }
      .font(.caption)
    }
  }

  // MARK: Calendar

  @ViewBuilder
  private var calendarDetails: some View {
    switch entries.calendarAccess {
    case .granted:
      if entries.calendars.isEmpty {
        Text("没有可读取的日历。").font(.caption).foregroundStyle(.secondary)
      }
      ForEach(entries.calendars) { calendar in
        Toggle(
          "\(calendar.title)\(calendar.source.isEmpty ? "" : "（\(calendar.source)）")",
          isOn: Binding(
            get: { entries.settings.calendarIDs.contains(calendar.id) },
            set: { model.setCalendar(calendar.id, chosen: $0) }))
      }
      Text("读取过去 7 天到未来 30 天的日程。")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("现在同步") { model.checkEntryNow(.calendar) }
        Spacer()
      }
    case .notDetermined:
      Button("允许读取日历…") { Task { await model.requestCalendarAccess() } }
    case .denied:
      Text("Mindloom 没有日历访问权限。请在“系统设置”>“隐私与安全”>“日历”中允许。")
        .font(.caption).foregroundStyle(.orange)
    }
  }

  // MARK: Git

  @ViewBuilder
  private var gitDetails: some View {
    if entries.gitRunner == nil {
      Text("在这台 Mac 上找不到 git。请安装 Xcode 或命令行工具。")
        .font(.caption).foregroundStyle(.orange)
    }
    ForEach(entries.settings.repositories) { repository in
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(repository.displayName).font(.callout.weight(.semibold))
          Spacer()
          Button("移除", role: .destructive) { model.removeWatchedRepository(repository.id) }
            .buttonStyle(.borderless)
        }
        Text(repository.path).font(.caption2.monospaced()).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle)
        let branches = entries.repositoryBranches[repository.id] ?? repository.branches
        ForEach(branches, id: \.self) { branch in
          Toggle(
            branch,
            isOn: Binding(
              get: { repository.branches.contains(branch) },
              set: { model.setRepositoryBranch(repository.id, branch: branch, watched: $0) })
          )
          .font(.caption)
        }
      }
    }
    HStack {
      Button("添加仓库…") { model.addWatchedRepository() }
        .accessibilityIdentifier("bestASR.settings.entry.addRepository")
      Button("现在检查") { model.checkEntryNow(.git) }
      Spacer()
    }
    .onAppear { model.loadRepositoryBranches() }
    Text("添加打开此入口之后的新提交。")
      .font(.caption).foregroundStyle(.secondary)
  }
}

/// One watched folder: exclusions, size limit, pause, remove.
private struct FolderRow: View {
  let folder: WatchedFolder
  let update: (WatchedFolder) -> Void
  let remove: () -> Void
  @State private var exclusions = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(folder.displayName).font(.callout.weight(.semibold))
        Spacer()
        Toggle(
          "暂停",
          isOn: Binding(
            get: { folder.paused },
            set: {
              var changed = folder
              changed.paused = $0
              update(changed)
            })
        )
        .toggleStyle(.checkbox)
        Button("移除", role: .destructive, action: remove).buttonStyle(.borderless)
      }
      Text(folder.path).font(.caption2.monospaced()).foregroundStyle(.secondary)
        .lineLimit(1).truncationMode(.middle)
      HStack {
        TextField("排除项，例如 *.dmg, 私人*", text: $exclusions)
          .font(.caption)
          .onSubmit { saveExclusions() }
        Stepper(
          "上限 \(folder.maximumMegabytes) MB",
          value: Binding(
            get: { folder.maximumMegabytes },
            set: {
              var changed = folder
              changed.maximumMegabytes = min(max($0, 1), 200)
              update(changed)
            }), in: 1...200, step: 5
        )
        .font(.caption)
        .fixedSize()
      }
    }
    .onAppear { exclusions = folder.exclusions.joined(separator: ", ") }
    .onDisappear { saveExclusions() }
  }

  private func saveExclusions() {
    let patterns = exclusions.split(whereSeparator: { $0 == "," || $0 == "，" })
      .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard patterns != folder.exclusions else { return }
    var changed = folder
    changed.exclusions = patterns
    update(changed)
  }
}
