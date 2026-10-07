import BestASRMemory
import Foundation

/// What the pages can ask the App for (navigation is `MindloomNavigator`).
/// Every correction is one `MemoryCorrection` sent through `correct`: the
/// App routes it through the undo window (`MemoryCorrectionQueue`) to the
/// DGX Spark's decisions, the local organizer, or the user-organizing store.
/// All run on the main actor; every default does nothing (snapshots).
public struct MemoryActions {
  /// Any correction: move, take out, new matter, 标为完成 / 已经定了, rename,
  /// delete, group, pin.
  public var correct: @MainActor (MemoryCorrection) -> Void
  /// 撤销 (toast, ⌘Z, 编辑 › 撤销…).
  public var undo: @MainActor () -> Void
  /// 新建分组 `name`; `moving` joins it (移到分组 › 新建分组…). The App opens
  /// the new group's page when nothing moves.
  public var createGroup: @MainActor (_ name: String, _ moving: String?) -> Void
  public var renameGroup: @MainActor (_ groupID: String, _ name: String) -> Void
  public var deleteGroup: @MainActor (_ groupID: String) -> Void
  /// 复制为文本 (title, status and steps as plain text; toast 「已复制」).
  public var copyText: @MainActor (_ eventID: String) -> Void
  public var exportText: @MainActor (_ eventID: String) -> Void
  /// The 历史 page's query changed (or it appeared): the App reads the
  /// query, searches every record, and fills `MemoryScreenState.history`.
  public var searchText: @MainActor (_ query: String) -> Void
  /// 重新连接 (Home's offline line, the menu bar extra, Settings).
  public var reconnect: @MainActor () -> Void
  /// Opens the Settings window, on a pane (`entries`, `devices`, `apps`,
  /// `about`) or the last one.
  public var openSettings: @MainActor (_ pane: String?) -> Void
  /// The toast's lifetime is over, or its action ran.
  public var dismissToast: @MainActor (_ id: UUID) -> Void
  /// The pointer is over the toast (its timer and a held correction wait).
  public var holdToast: @MainActor (_ id: UUID, _ hovering: Bool) -> Void
  public var play: @MainActor (_ itemID: String) -> Void
  /// Plays one stretch of a recording (monotonic nanoseconds).
  public var playRange:
    @MainActor (_ itemID: String, _ startNanoseconds: UInt64, _ endNanoseconds: UInt64) -> Void
  public var stop: @MainActor () -> Void
  /// 改来源 on a 原文 row.
  public var changeSource: @MainActor (_ itemID: String, _ name: String) -> Void
  /// A page appeared: refresh the read model if it is old.
  public var refresh: @MainActor () -> Void
  /// A correction the DGX Spark did not take: send it again, or drop it.
  public var retryIssue: @MainActor (_ issueID: String) -> Void
  public var discardIssue: @MainActor (_ issueID: String) -> Void
  /// v8: 把下一步加到提醒事项 — one reminder, written only on this click
  /// (V8 contract A5). Nil hides the button.
  public var addToReminders: (@MainActor (MemoryReminderRequest) -> Void)?
  /// Each v11 branch's own actions (Home/, Matter/, Capture/ files).
  /// The 历史 page's own actions (paging, playing, copying, the dictionary).
  public var history = MemoryHistoryActions()
  public var home = MemoryHomeActions()
  public var matter = MemoryMatterActions()
  public var capture = MemoryCaptureActions()

  public init(
    correct: @escaping @MainActor (MemoryCorrection) -> Void = { _ in },
    undo: @escaping @MainActor () -> Void = {},
    createGroup: @escaping @MainActor (String, String?) -> Void = { _, _ in },
    renameGroup: @escaping @MainActor (String, String) -> Void = { _, _ in },
    deleteGroup: @escaping @MainActor (String) -> Void = { _ in },
    copyText: @escaping @MainActor (String) -> Void = { _ in },
    exportText: @escaping @MainActor (String) -> Void = { _ in },
    searchText: @escaping @MainActor (String) -> Void = { _ in },
    reconnect: @escaping @MainActor () -> Void = {},
    openSettings: @escaping @MainActor (String?) -> Void = { _ in },
    dismissToast: @escaping @MainActor (UUID) -> Void = { _ in },
    holdToast: @escaping @MainActor (UUID, Bool) -> Void = { _, _ in },
    play: @escaping @MainActor (String) -> Void = { _ in },
    playRange: @escaping @MainActor (String, UInt64, UInt64) -> Void = { _, _, _ in },
    stop: @escaping @MainActor () -> Void = {},
    changeSource: @escaping @MainActor (String, String) -> Void = { _, _ in },
    refresh: @escaping @MainActor () -> Void = {},
    retryIssue: @escaping @MainActor (String) -> Void = { _ in },
    discardIssue: @escaping @MainActor (String) -> Void = { _ in },
    addToReminders: (@MainActor (MemoryReminderRequest) -> Void)? = nil
  ) {
    self.correct = correct
    self.undo = undo
    self.createGroup = createGroup
    self.renameGroup = renameGroup
    self.deleteGroup = deleteGroup
    self.copyText = copyText
    self.exportText = exportText
    self.searchText = searchText
    self.reconnect = reconnect
    self.openSettings = openSettings
    self.dismissToast = dismissToast
    self.holdToast = holdToast
    self.play = play
    self.playRange = playRange
    self.stop = stop
    self.changeSource = changeSource
    self.refresh = refresh
    self.retryIssue = retryIssue
    self.discardIssue = discardIssue
    self.addToReminders = addToReminders
  }

  /// Does nothing; for snapshots and previews.
  public static var inert: MemoryActions { MemoryActions() }
}

/// A matter's next step, for 把下一步加到提醒事项.
public struct MemoryReminderRequest: Equatable, Sendable {
  public let eventID: String
  public let matterTitle: String
  public let text: String
  public let date: Date?

  public init(eventID: String, matterTitle: String, text: String, date: Date?) {
    self.eventID = eventID
    self.matterTitle = matterTitle
    self.text = text
    self.date = date
  }
}

/// The 历史 page's actions (ALIGNMENT 查-1, 查-7, 收1-7, 用-1).
public struct MemoryHistoryActions {
  /// The next page of the list (the last row came into view).
  public var loadMore: @MainActor () -> Void
  /// Plays a record from a point of its recording (the sentence that
  /// matched), or from its start.
  public var play: @MainActor (_ itemID: String, _ fromNanoseconds: UInt64?) -> Void
  /// Space: pause or go on.
  public var togglePlayback: @MainActor () -> Void
  /// ← → : 15 s back or on.
  public var skip: @MainActor (_ seconds: Double) -> Void
  /// 复制 a record's words (toast 「已复制」).
  public var copy: @MainActor (_ itemID: String) -> Void
  /// 加进词典: how it was heard, how it should be written.
  public var addToDictionary: @MainActor (_ heard: String, _ written: String) -> Void
  /// 导出文字与字幕 › 纯文本… (and the other kinds): the system's save panel,
  /// then the record's words in that kind (review v12-B #6; d54's history
  /// detail).
  public var exportText: @MainActor (_ itemID: String, _ kind: MemoryHistoryExport) -> Void
  /// 导出原音…: the record's retained recording, whole.
  public var exportAudio: @MainActor (_ itemID: String) -> Void
  /// 删除…: asks first (仅删除保留原音 · 删除记录和保留原音).
  public var delete: @MainActor (_ itemID: String) -> Void

  public init(
    loadMore: @escaping @MainActor () -> Void = {},
    play: @escaping @MainActor (String, UInt64?) -> Void = { _, _ in },
    togglePlayback: @escaping @MainActor () -> Void = {},
    skip: @escaping @MainActor (Double) -> Void = { _ in },
    copy: @escaping @MainActor (String) -> Void = { _ in },
    addToDictionary: @escaping @MainActor (String, String) -> Void = { _, _ in },
    exportText: @escaping @MainActor (String, MemoryHistoryExport) -> Void = { _, _ in },
    exportAudio: @escaping @MainActor (String) -> Void = { _ in },
    delete: @escaping @MainActor (String) -> Void = { _ in }
  ) {
    self.loadMore = loadMore
    self.play = play
    self.togglePlayback = togglePlayback
    self.skip = skip
    self.copy = copy
    self.addToDictionary = addToDictionary
    self.exportText = exportText
    self.exportAudio = exportAudio
    self.delete = delete
  }
}

/// What 导出文字与字幕 writes one record as. Subtitles need a recording's
/// times, so a pasted item offers the two text kinds only.
public enum MemoryHistoryExport: String, CaseIterable, Sendable {
  case plainText = "txt"
  case markdown = "md"
  case srt
  case vtt

  public var title: String {
    switch self {
    case .plainText: "纯文本…"
    case .markdown: "Markdown…"
    case .srt: "SRT 字幕…"
    case .vtt: "VTT 字幕…"
    }
  }

  public var needsRecording: Bool { self == .srt || self == .vtt }
}

/// A 历史 row's ⋯ / right-click menu, in order (review v12-B #6: the
/// per-record export and delete d54 had are back with the history page).
public enum HistoryRowMenu {
  public enum Entry: Equatable, Sendable {
    case copy
    case share
    case addToDictionary
    case exportText([MemoryHistoryExport])
    case exportAudio
    case openMatter(String)
    case delete
    case divider
  }

  public static func entries(for row: MemoryHistoryRow) -> [Entry] {
    var entries: [Entry] = [.copy, .share, .addToDictionary, .divider]
    entries.append(
      .exportText(MemoryHistoryExport.allCases.filter { row.playable || !$0.needsRecording }))
    if row.playable { entries.append(.exportAudio) }
    if let eventID = row.eventID {
      entries.append(.divider)
      entries.append(.openMatter(eventID))
    }
    entries.append(.divider)
    entries.append(.delete)
    return entries
  }

  /// 「导出文字与字幕」 for a recording, 「导出文字」 for the rest.
  public static func exportTextTitle(_ kinds: [MemoryHistoryExport]) -> String {
    kinds.contains(where: \.needsRecording) ? "导出文字与字幕" : "导出文字"
  }
}
