import AppKit
import BestASRDomain
import BestASRPersistence
import Foundation
import UniformTypeIdentifiers

/// The dictionary's behaviour, on the dictionary's own state. It needs two
/// things from outside: the store, and whether a capture is running (a bulk
/// import while recording would race the recogniser's term list). Both are
/// handed in by the app model, so this object can be exercised without it.
extension DictionaryModel {
  func search() {
    requestedPageIndex = 0
    queueRefresh(debounce: true)
  }

  func loadNextPage() {
    guard hasNextPage, !isLoadingEntries else { return }
    requestedPageIndex = pageIndex + 1
    queueRefresh(debounce: false)
  }

  func loadPreviousPage() {
    guard pageIndex > 0, !isLoadingEntries else { return }
    requestedPageIndex = pageIndex - 1
    queueRefresh(debounce: false)
  }

  private func queueRefresh(debounce: Bool) {
    queryTask?.cancel()
    queryGeneration += 1
    let generation = queryGeneration
    isLoadingEntries = true
    queryTask = Task { [weak self] in
      if debounce {
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
      }
      guard let self, !Task.isCancelled, generation == queryGeneration else { return }
      await refreshEntries()
    }
  }

  func beginNewEntry() {
    editingDictionaryEntryID = nil
    canonicalDraft = ""
    spokenFormsDraft = ""
    dictionaryStatusMessage = "请输入标准写法；口语读法可选"
  }

  func beginEditing(_ entry: DictionaryEntry) {
    editingDictionaryEntryID = entry.id
    canonicalDraft = entry.canonicalForm
    spokenFormsDraft = entry.spokenForms.joined(separator: ", ")
    dictionaryStatusMessage = "正在编辑本机词条"
  }

  /// A correction the user made in a transcript becomes a draft entry:
  /// what was heard as the spoken form, what they typed as the standard.
  func beginEntry(fromCorrection original: String, corrected: String) {
    canonicalDraft = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
    spokenFormsDraft = original.trimmingCharacters(in: .whitespacesAndNewlines)
    editingDictionaryEntryID = nil
    dictionaryStatusMessage = "已从纠错带入词条；确认标准写法后保存"
  }

  func saveDraft() {
    let canonical = canonicalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    let spokenForms = Self.spokenForms(spokenFormsDraft)
    guard !canonical.isEmpty else {
      dictionaryStatusMessage = "标准写法不能为空"
      return
    }
    guard !saveInProgress else { return }
    saveInProgress = true
    dictionaryStatusMessage = "正在保存到本机词典…"
    Task { [weak self] in
      guard let self else { return }
      defer { saveInProgress = false }
      guard let repository else {
        dictionaryStatusMessage = "本机词典存储暂不可用"
        return
      }
      do {
        if let editingDictionaryEntryID {
          guard let current = entries.first(where: { $0.id == editingDictionaryEntryID }) else {
            dictionaryStatusMessage = "词条已发生变化；已刷新，请再次修改"
            await refreshEntries()
            return
          }
          _ = try await repository.updateDictionaryEntry(
            id: current.id, expectedRevision: current.revision,
            canonicalForm: canonical, spokenForms: spokenForms)
        } else {
          _ = try await repository.createDictionaryEntry(
            canonicalForm: canonical, spokenForms: spokenForms)
        }
        self.editingDictionaryEntryID = nil
        canonicalDraft = ""
        spokenFormsDraft = ""
        dictionaryStatusMessage = "词典已保存在本机"
        await refreshEntries(preserveStatus: true)
      } catch {
        dictionaryStatusMessage = "词典修改未保存；请检查重复词条、长度或版本冲突"
        await refreshEntries(preserveStatus: true)
      }
    }
  }

  func setEntryEnabled(_ entry: DictionaryEntry, enabled: Bool) {
    setEntriesEnabled([entry], enabled: enabled)
  }

  /// One operation owns the batch; it publishes one refreshed result after
  /// every attempted write instead of starting N racing reads and tasks.
  @discardableResult
  func setEntriesEnabled(
    _ selected: [DictionaryEntry], enabled: Bool
  ) -> Task<Void, Never>? {
    guard !mutationInProgress, let repository else { return nil }
    let changes = selected.filter { $0.enabled != enabled }
    guard !changes.isEmpty else { return nil }
    mutationInProgress = true
    return Task { [weak self] in
      guard let self else { return }
      defer { mutationInProgress = false }
      var updated = 0
      for entry in changes {
        do {
          _ = try await repository.setDictionaryEntryEnabled(
            id: entry.id, expectedRevision: entry.revision, enabled: enabled
          )
          updated += 1
        } catch {
          // Optimistic revisions protect entries changed by another operation.
        }
      }
      let action = enabled ? "启用" : "停用"
      dictionaryStatusMessage =
        updated == changes.count
        ? "已\(action) \(updated) 个词；之后的识别会使用新设置"
        : "已\(action) \(updated) 个词；\(changes.count - updated) 个未更新，请重试"
      await refreshEntries(preserveStatus: true)
    }
  }

  func deleteEntry(_ entry: DictionaryEntry) {
    Task { [weak self] in
      guard let self, let repository else { return }
      do {
        _ = try await repository.deleteDictionaryEntry(
          id: entry.id, expectedRevision: entry.revision)
        if editingDictionaryEntryID == entry.id { beginNewEntry() }
        dictionaryStatusMessage = "词条已删除并在本机保留删除标记"
      } catch {
        dictionaryStatusMessage = "词条已发生变化；已刷新且没有误删"
      }
      await refreshEntries(preserveStatus: true)
    }
  }

  func deleteEntries(_ selected: [DictionaryEntry]) {
    Task { [weak self] in
      guard let self, let repository else { return }
      var deleted = 0
      for entry in selected {
        guard
          (try? await repository.deleteDictionaryEntry(
            id: entry.id, expectedRevision: entry.revision)) != nil
        else { continue }
        deleted += 1
        if editingDictionaryEntryID == entry.id { beginNewEntry() }
      }
      dictionaryStatusMessage =
        deleted == selected.count
        ? "已删除 \(deleted) 个词"
        : "已删除 \(deleted) 个词；\(selected.count - deleted) 个已发生变化，没有删除"
      await refreshEntries(preserveStatus: true)
    }
  }

  func importFile() {
    guard !captureIsActive() else {
      dictionaryStatusMessage = "请先结束当前录音或导入，再批量更新词典"
      return
    }
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.commaSeparatedText, .json]
    guard panel.runModal() == .OK, let source = panel.url else { return }
    dictionaryStatusMessage = "正在校验并合并词典文件…"
    Task { [weak self] in
      guard let self, let repository else { return }
      do {
        let decoded = try await transferWorker.decode(url: source)
        let imported = try await repository.importDictionaryEntries(decoded)
        dictionaryStatusMessage = "已原子合并 \(imported.count) 个词条；之后的识别和整理会使用新版本"
        await refreshEntries(preserveStatus: true)
      } catch {
        dictionaryStatusMessage = "词典文件格式、重复词条或内容无效；整个导入已回滚"
      }
    }
  }

  func exportFile(_ format: LocalDictionaryTransferFormat) {
    guard let repository else {
      dictionaryStatusMessage = "本地词典存储暂不可用"
      return
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = format == .csv ? [.commaSeparatedText] : [.json]
    panel.nameFieldStringValue = "bestASR-dictionary.\(format.rawValue)"
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    dictionaryStatusMessage = "正在导出本地词典…"
    Task { [weak self] in
      guard let self else { return }
      do {
        let all = try await repository.allDictionaryEntries()
        let data = try await transferWorker.encode(entries: all, format: format)
        try data.write(to: destination, options: .atomic)
        dictionaryStatusMessage = "已导出 \(all.count) 个词条；文件中不含音频、历史或人物信息"
      } catch {
        dictionaryStatusMessage = "词典导出失败；原词典没有变化"
      }
    }
  }

  func refreshEntries(preserveStatus: Bool = false) async {
    queryGeneration += 1
    let generation = queryGeneration
    let query = searchQuery
    let requestedPage = requestedPageIndex
    isLoadingEntries = true
    defer {
      if generation == queryGeneration { isLoadingEntries = false }
    }
    guard let repository else {
      entries = []
      hasNextPage = false
      pageIndex = 0
      return
    }
    do {
      let result = try await repository.searchDictionaryEntries(
        query: query, includeDisabled: true,
        limit: Self.pageSize + 1, offset: requestedPage * Self.pageSize
      )
      guard !Task.isCancelled, generation == queryGeneration, query == searchQuery else { return }
      if result.isEmpty, requestedPage > 0 {
        requestedPageIndex = 0
        await refreshEntries(preserveStatus: preserveStatus)
        return
      }
      entries = Array(result.prefix(Self.pageSize))
      pageIndex = requestedPage
      hasNextPage = result.count > Self.pageSize
      if !preserveStatus {
        dictionaryStatusMessage =
          entries.isEmpty
          ? "没有匹配的本地词典条目" : "已启用的词条会用于本地识别和事实保护"
      }
    } catch {
      guard !Task.isCancelled, generation == queryGeneration, query == searchQuery else { return }
      requestedPageIndex = pageIndex
      dictionaryStatusMessage = "无法读取本地词典，请重试"
    }
  }

  /// "a, b；c" → ["a", "b", "c"], deduplicated case- and width-insensitively.
  nonisolated static func spokenForms(_ value: String) -> [String] {
    let separators = CharacterSet(charactersIn: ",，;；\n")
    var seen = Set<String>()
    return value.components(separatedBy: separators).compactMap { component in
      let term = component.trimmingCharacters(in: .whitespacesAndNewlines)
      let key = term.precomposedStringWithCompatibilityMapping.lowercased()
      guard !term.isEmpty, seen.insert(key).inserted else { return nil }
      return term
    }
  }
}
