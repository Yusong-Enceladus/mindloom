import AppKit
import BestASRDomain
import BestASRIntake
import BestASRMemory
import BestASRMemoryUI
import BestASRPersistence
import SwiftUI
import UniformTypeIdentifiers

// OWNER: mac-home. Wires Home, search, groups, person to the App: fill `MemoryScreenState.homeExtras`
// and `MemoryActions.home` here, so the three v11 branches never
// edit the same lines of ContentView+Memory.swift.
extension ContentView {
  /// Adds this branch's values to the page state: Home's 「刚收进来」 (when
  /// the capture branch has not filled it) and how many records wait.
  ///
  /// v12 (ALIGNMENT 理1-4): while the DGX Spark is not organizing (link off,
  /// not connected, or never set up) nothing is organized on this Mac.
  /// New records of every kind — dictations too — wait under 「刚收进来」,
  /// newest first; Home says how many (`homeExtras.waitingTotal`, and the
  /// offline line's count) and 历史 has them all.
  func patchHomeState(_ state: inout MemoryScreenState) {
    guard state.isLoaded, state.waitingCaptures.isEmpty else { return }
    let now = Date()
    let calendar = state.calendar
    var waiting = MemoryWaitingCapture.waiting(unfiled: state.unfiled, now: now, calendar: calendar)
    if state.link.status != .connected {
      // Runs with every redraw: only the records after `since` are looked at.
      let mirror = model.memoryUsesRemote
      let records = state.projection?.records ?? [:]
      let newestKnown =
        mirror && state.link.lastOrganizedAt == nil
        ? records.values.map(\.startedAt).max() : nil
      let since = MemoryWaitingRecords.since(
        mirror: mirror, lastOrganizedAt: state.link.lastOrganizedAt, newestKnown: newestKnown,
        now: now, calendar: calendar)
      let recent = model.memorySourceItems.filter { $0.createdAt > since }
      let ids = recent.map { $0.sessionID.rawValue.uuidString.uppercased() }
      let organized: Set<String>
      if mirror {
        // The organizer has these.
        organized = Set(ids.filter { records[$0] != nil })
      } else {
        let held = Set(model.events.summaries.flatMap(\.sessionIDs))
        organized = Set(
          recent.filter { held.contains($0.sessionID) }
            .map { $0.sessionID.rawValue.uuidString.uppercased() })
      }
      let byID = Dictionary(zip(ids, recent), uniquingKeysWith: { a, _ in a })
      let pending = MemoryWaitingRecords.waiting(
        recent.map {
          MemoryWaitingRecords.Candidate(
            id: $0.sessionID.rawValue.uuidString, createdAt: $0.createdAt,
            failed: $0.status == .failed || $0.status == .processing)
        },
        organized: organized, since: since)
      let fresh = pending.prefix(Self.waitingShown).compactMap { byID[$0.id] }
        .map(Self.waitingCapture)
      let seen = Set(fresh.map(\.id))
      waiting = fresh + waiting.filter { !seen.contains($0.id) }
      state.link.waiting = pending.count
      state.homeExtras.waitingTotal = pending.count
    }
    state.waitingCaptures = Array(waiting.prefix(Self.waitingShown))
  }

  /// How many of the waiting records Home lists (the rest are in 历史).
  static let waitingShown = 8

  /// Adds this branch's actions.
  func wireHomeActions(_ actions: inout MemoryActions) {
    let model = model
    let screen = memoryScreen
    actions.home.playVoice = { personID in
      model.memoryPlayVoiceSample(personID, projection: screen.projection)
    }
  }

  /// A capture not organized yet, as 「刚收进来」 shows it: its first line
  /// (never a file name), the kind word and glyph.
  static func waitingCapture(_ item: DictationHistoryItem) -> MemoryWaitingCapture {
    let id = item.sessionID.rawValue.uuidString.uppercased()
    // A meeting App's transcript shows its title or first 「名字：话」, not
    // its file marks (v12 integration).
    let text = MemoryWaitingCapture.firstLine(of: item.preferredText ?? "")
    let app = item.sourceDisplayName ?? ""
    let chats: Set<String> = ["微信", "企业微信", "飞书", "短信", "信息", "钉钉", "Slack", "Telegram"]
    var kind = "粘贴"
    var symbol = "doc.on.clipboard"
    var thumbnail: MemoryWaitingCapture.Thumbnail?
    switch item.inputMode {
    case .dictation:
      kind = "口述"
      symbol = "mic"
    case .roomMicrophone:
      // 开始记录会议 without 屏幕与系统录音 (ALIGNMENT 收2-2).
      kind = "会议录音 · " + MemoryItemSource.microphoneOnlyNote
      symbol = "person.3"
    case .systemAudio:
      kind = "会议录音"
      symbol = "person.3"
    case .importedMedia:
      // 「录音」 or 「视频」 by the original (ALIGNMENT 收2-6).
      let media = MemoryMediaKind.of(filename: item.sourceIdentifier, mediaType: nil)
      let minutes = Int((Double(item.durationNanoseconds ?? 0) / 6e10).rounded())
      kind = minutes > 0 ? "\(media.word) · \(minutes) 分钟" : media.word
      symbol = media.symbol
      thumbnail = media == .video ? .video : nil
    case .userItem:
      switch item.itemKind {
      case .image?:
        kind = "截图"
        symbol = "photo"
        thumbnail = .photo
      case .document?, .file?:
        // The file's type only (its name is never shown); a meeting App's
        // transcript is a 会议记录 (ALIGNMENT 收2-5).
        if MemoryTranscriptText.parse(item.preferredText ?? "") != nil {
          kind = "会议记录"
          symbol = "person.3"
        } else if (item.sourceIdentifier ?? "").lowercased().hasSuffix(".pdf") {
          kind = "PDF"
          symbol = "doc"
          thumbnail = .pdf
        } else {
          kind = "文件"
          symbol = "doc"
        }
      case .text?, nil:
        if chats.contains(app) {
          kind = app
          symbol = "bubble.left"
        } else if app.hasPrefix(AgentInboxProposal.sourcePrefix) {
          // Another App put it in (AGENT-007): its name, not 「粘贴」.
          kind = SourceLabel.label(
            inputMode: item.inputMode, bundleID: item.sourceApplicationBundleID, displayName: app)
          symbol = "command"
        }
      }
    }
    let first =
      text.map { item.inputMode == .dictation ? MemoryQuoteLines.punctuated($0) : $0 }
      ?? (item.itemKind == .image ? "一张截图" : "一个文件")
    return MemoryWaitingCapture(
      id: id, firstLine: first, kind: kind, symbol: symbol, capturedAt: item.createdAt,
      thumbnail: thumbnail)
  }
}

// OWNER: v12 find. Wires the 历史 page to the App (ALIGNMENT 查-1, 查-7, 收1-7,
// 用-1): paging, playing a record from the sentence that matched (space
// pauses, ← → skip 15 s), copying and sharing one record, and putting a
// misheard word into the dictionary.
extension ContentView {
  func wireHistoryActions(_ actions: inout MemoryActions) {
    let model = model
    let screen = memoryScreen
    let historySearch = historySearch
    actions.history = MemoryHistoryActions(
      loadMore: { historySearch.loadMore() },
      play: { id, from in model.memoryPlayRecord(itemID: id, fromNanoseconds: from) },
      togglePlayback: { model.toggleHistoryPlayback() },
      skip: { seconds in
        let position = model.playback.playbackPosition + seconds
        model.seekHistoryPlayback(to: max(0, min(model.playback.playbackDuration, position)))
      },
      copy: { id in
        guard let row = historySearch.state.rows.first(where: { $0.itemID == id }) else { return }
        model.copyRecordText(row.fullText)
        screen.show(MemoryToast("已拷贝", icon: .symbol("doc.on.doc")))
      },
      addToDictionary: { heard, written in
        Task {
          let note = await model.addHeardWordToDictionary(heard: heard, written: written)
          historySearch.invalidateContext()
          screen.show(MemoryToast(note ?? "已添加到词典", icon: .symbol("character.book.closed")))
        }
      },
      // Per-record export and delete (review v12-B #6; d54's history
      // detail): the same exporter and the same confirmation as before.
      exportText: { id, kind in
        model.exportRecord(itemID: id, format: LocalHistoryExportFormat(rawValue: kind.rawValue)) {
          screen.show(MemoryToast($0, icon: .symbol("square.and.arrow.down")))
        }
      },
      exportAudio: { id in
        model.exportRecord(itemID: id, format: nil) {
          screen.show(MemoryToast($0, icon: .symbol("waveform")))
        }
      },
      delete: { [deletion = $pendingHistoryDeletion] id in
        Task {
          guard let session = model.sessionID(id),
            let item = await model.historyRecordItem(session)
          else { return }
          guard model.canDeleteHistoryItem(item) else {
            screen.show(MemoryToast("此条正在处理，请在处理完成后删除", icon: .symbol("clock")))
            return
          }
          deletion.wrappedValue = item
        }
      })
  }
}

extension DictationAppModel {
  /// Plays a record from a point of its recording (the sentence a search
  /// matched) or from its start. A record older than the lists the App
  /// keeps in memory (an imported Typeless dictation) is read from the
  /// library first.
  func memoryPlayRecord(itemID: String, fromNanoseconds: UInt64?) {
    guard let session = sessionID(itemID) else { return }
    Task { [weak self] in
      guard let self else { return }
      playback.stopAt = nil
      playback.voicePersonID = nil
      guard await openRecord(session, forPlaying: true) != nil else {
        intake.show("这段录音暂时无法打开")
        return
      }
      if let from = fromNanoseconds, historyPlaybackPosition(forMonotonicNanoseconds: from) != nil {
        playHistoryPlayback(toMonotonicNanoseconds: from)
      } else if !playback.playbackIsPlaying {
        toggleHistoryPlayback()
      }
    }
  }

  /// The record a 历史 row stands for: from the App's lists, or the library
  /// (an imported Typeless dictation is older than the lists).
  func historyRecordItem(_ session: SessionID) async -> DictationHistoryItem? {
    if let item = memoryHistoryItem(session) { return item }
    return try? await repository?.historyItems(sessionIDs: [session]).first
  }

  /// Makes a record the selected one, its words, assets and recording read,
  /// as ▶ and the row's export need. Nil when it cannot be opened.
  func openRecord(_ session: SessionID, forPlaying: Bool) async -> DictationHistoryItem? {
    guard let item = await historyRecordItem(session) else { return nil }
    let loaded =
      history.selectedHistorySessionID == session
      && (forPlaying
        ? !playback.playbackTrackIDs.isEmpty : !history.selectedHistoryTranscripts.isEmpty)
    if !loaded {
      beginHistoryNavigation(item, returningTo: nil, presentingDetail: false)
      await refreshSelectedSpeakerDetails(sessionID: session)
    }
    guard history.selectedHistorySessionID == session,
      !forPlaying || !playback.playbackTrackIDs.isEmpty
    else { return nil }
    return item
  }

  /// 导出文字与字幕 › … and 导出原音… from a 历史 row (review v12-B #6): the
  /// record is opened as ▶ opens it, then the history exporter writes the
  /// file the owner names in the save panel (the whole recording for 原音).
  /// `report` says how it went.
  func exportRecord(
    itemID: String, format: LocalHistoryExportFormat?,
    report: @escaping @MainActor (String) -> Void
  ) {
    guard let session = sessionID(itemID) else { return }
    Task { [weak self] in
      guard let self else { return }
      guard let item = await openRecord(session, forPlaying: format == nil) else {
        report(format == nil ? "这段录音暂时无法打开" : "这条记录暂时无法打开")
        return
      }
      if let format {
        exportSelectedHistory(format, item: item, report: report)
      } else {
        export.exportSelectionStart = 0
        export.exportSelectionEnd = playback.playbackDuration
        exportSelectedHistorySourceAudio(report: report)
      }
    }
  }

  /// 复制 one record's words (历史, the menu bar's 最近记录), marked as
  /// Mindloom's own copy: ⌘V in Mindloom then says it is its own and does not
  /// take it in again as an item from another App (review v12-B #5; d54's
  /// history copy did the same).
  func copyRecordText(_ text: String) {
    Self.writeRecordText(text, to: .general)
  }

  @discardableResult
  static func writeRecordText(_ text: String, to board: NSPasteboard) -> Bool {
    IntakePasteboardMarks.writeOwnText(text, to: board)
  }

  /// 加进词典: the word as it should be written gains how it was heard (a
  /// new word when the dictionary has none written that way), and dictation
  /// uses it (it is turned on if it was off). Nil when it worked, else the
  /// words to show.
  func addHeardWordToDictionary(heard: String, written: String) async -> String? {
    guard let repository else { return "词典暂时无法打开" }
    do {
      try await DictionaryWordEditing.addHeard(heard: heard, written: written, in: repository)
      await dictionary.refreshEntries(preserveStatus: true)
      return nil
    } catch {
      return "未能添加到词典。写法可能过长，或已有相同的词"
    }
  }

  /// Settings › 口述 › 词典: add (id nil) or change a word; a changed word
  /// that was off is used in dictation again. Nil when it worked, else the
  /// line to show.
  func saveDictionaryWord(id: String?, written: String, heard: [String]) async -> String? {
    guard let repository else { return "词典暂时无法打开" }
    do {
      try await DictionaryWordEditing.save(
        id: id.flatMap(UUID.init(uuidString:)), written: written, heard: heard, in: repository)
      await dictionary.refreshEntries(preserveStatus: true)
      return nil
    } catch DictionaryWordEditing.Failure.changed {
      await dictionary.refreshEntries(preserveStatus: true)
      return "此词刚被更改，请重试"
    } catch BestASRPersistenceError.duplicateDictionaryEntry {
      return "词典中已有“\(written)”"
    } catch {
      return "未能保存：写法过长，或“识别为”中的写法重复"
    }
  }

  /// Settings › 口述 › 词典: a word's switch. Nil when it worked.
  func setDictionaryWordEnabled(id: String, on: Bool) async -> String? {
    guard let repository, let uuid = UUID(uuidString: id) else { return "词典暂时无法打开" }
    do {
      try await DictionaryWordEditing.setEnabled(id: uuid, on: on, in: repository)
      await dictionary.refreshEntries(preserveStatus: true)
      return nil
    } catch {
      await dictionary.refreshEntries(preserveStatus: true)
      return "此词刚被更改，请重试"
    }
  }

  /// Settings › 口述 › 词典 › 导入…: a CSV or JSON file the owner picks,
  /// merged into the dictionary as one change (all or nothing).
  func importDictionaryWords() async -> (note: String?, status: String?) {
    guard let repository else { return ("词典暂时无法打开", nil) }
    guard !dictionary.captureIsActive() else {
      return ("正在录制或导入时无法导入词典。请结束后再试。", nil)
    }
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.commaSeparatedText, .json]
    guard panel.runModal() == .OK, let source = panel.url else { return (nil, nil) }
    do {
      let decoded = try await dictionary.transferWorker.decode(url: source)
      let imported = try await repository.importDictionaryEntries(decoded)
      await dictionary.refreshEntries(preserveStatus: true)
      return (nil, "已导入 \(imported.count) 个词条。")
    } catch {
      return ("无法导入：文件格式无效，或含有重复的词条。词典保持不变。", nil)
    }
  }

  /// Settings › 口述 › 词典 › 导出: every word (on and off) as CSV or JSON.
  func exportDictionaryWords(json: Bool) async -> (note: String?, status: String?) {
    guard let repository else { return ("词典暂时无法打开", nil) }
    let format: LocalDictionaryTransferFormat = json ? .json : .csv
    let panel = NSSavePanel()
    panel.allowedContentTypes = json ? [.json] : [.commaSeparatedText]
    panel.nameFieldStringValue = "Mindloom 词典.\(format.rawValue)"
    guard panel.runModal() == .OK, let destination = panel.url else { return (nil, nil) }
    do {
      let all = try await repository.allDictionaryEntries()
      let data = try await dictionary.transferWorker.encode(entries: all, format: format)
      try data.write(to: destination, options: .atomic)
      return (nil, "已导出 \(all.count) 个词条。")
    } catch {
      return ("无法导出词典。", nil)
    }
  }

  /// Settings › 口述 › 词典 › 删除 (asked first).
  func deleteDictionaryWord(id: String) async {
    guard let repository, let uuid = UUID(uuidString: id),
      let current = try? await repository.allDictionaryEntries().first(where: {
        $0.id.rawValue == uuid
      })
    else { return }
    _ = try? await repository.deleteDictionaryEntry(
      id: current.id, expectedRevision: current.revision)
    await dictionary.refreshEntries(preserveStatus: true)
  }

  /// The latest records for the menu bar's 最近记录 (newest first).
  var recentRecords: [DictationHistoryItem] {
    Array(
      memorySourceItems.filter { $0.status != .failed }
        .sorted { $0.createdAt > $1.createdAt }
        .prefix(5))
  }
}
