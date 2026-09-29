import BestASRDomain
import SwiftUI

extension ContentView {
  var dictionaryView: some View {
    DictionaryPage(dictionary: model.dictionary)
  }
}

/// Owns this page's transient interaction state and observes only dictionary changes.
private struct DictionaryPage: View {
  @ObservedObject var dictionary: DictionaryModel
  @State private var selection: Set<DictionaryEntryID> = []
  @State private var route = Route.words
  @State private var pendingDeletion: [DictionaryEntry] = []
  @State private var confirmsDeletion = false
  @State private var exportFormat = LocalDictionaryTransferFormat.csv
  @FocusState private var canonicalIsFocused: Bool

  private enum Route {
    case words
    case editor
    case transfer
  }

  private var chosen: [DictionaryEntry] {
    dictionary.entries.filter { selection.contains($0.id) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      switch route {
      case .words:
        wordsHeader
        DictionarySelectionToolbar(
          entries: dictionary.entries,
          selection: $selection,
          isPaged: dictionary.pageIndex > 0 || dictionary.hasNextPage,
          onEdit: { if let entry = chosen.first { edit(entry) } },
          onToggleEnabled: toggleChosenEnabled,
          onDelete: requestDeletion,
          onTransfer: { route = .transfer }
        )
        .disabled(dictionary.isLoadingEntries || dictionary.mutationInProgress)
        words
      case .editor:
        editor
        Spacer(minLength: 0)
      case .transfer:
        transfer
        Spacer(minLength: 0)
      }
      status
    }
    .padding(.horizontal, 32)
    .padding(.vertical, 28)
    .onChange(of: dictionary.searchQuery) { _, _ in
      selection = []
      dictionary.search()
    }
    .onChange(of: dictionary.entries.map(\.id)) { _, ids in
      selection.formIntersection(ids)
    }
    .onChange(of: dictionary.saveInProgress) { wasSaving, isSaving in
      guard wasSaving, !isSaving,
        dictionary.dictionaryStatusMessage == "词典已保存在本机"
      else { return }
      route = .words
    }
    .onAppear {
      if !dictionary.canonicalDraft.isEmpty { route = .editor }
    }
    .onExitCommand {
      switch route {
      case .words: selection = []
      case .editor: cancelEditing()
      case .transfer: route = .words
      }
    }
    .alert(
      "删除 \(pendingDeletion.count) 个词？",
      isPresented: $confirmsDeletion
    ) {
      Button("删除 \(pendingDeletion.count) 个词", role: .destructive) {
        dictionary.deleteEntries(pendingDeletion)
        selection.subtract(pendingDeletion.map(\.id))
        pendingDeletion = []
      }
      .accessibilityIdentifier("bestASR.dictionary.confirmDeleteSelected")
      Button("取消", role: .cancel) { pendingDeletion = [] }
    } message: {
      Text("之后的识别和整理不再使用这些词；已有原音和逐字稿不会改变。")
    }
  }

  private var wordsHeader: some View {
    PageHeader(title: "词典") {
      HStack(spacing: 8) {
        SearchField(
          prompt: "搜索词典",
          text: $dictionary.searchQuery,
          identifier: "bestASR.settings.dictionarySearch"
        )
        Button {
          dictionary.beginNewEntry()
          route = .editor
        } label: {
          Label("新词", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("bestASR.dictionary.new")
      }
    }
  }

  private var words: some View {
    ScrollView {
      if dictionary.entries.isEmpty {
        ContentUnavailableView(
          dictionary.searchQuery.isEmpty ? "还没有词汇" : "没有匹配的词",
          systemImage: "character.book.closed",
          description: Text(
            dictionary.searchQuery.isEmpty
              ? "添加你常说的人名、产品名或术语。"
              : "试试更短的关键词，或添加一个新词。"
          )
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
      } else {
        FlowLayout(spacing: 8) {
          ForEach(dictionary.entries, id: \.id) { entry in
            DictionaryWordButton(
              entry: entry,
              selected: selection.contains(entry.id),
              onSelect: {
                if !selection.insert(entry.id).inserted { selection.remove(entry.id) }
              },
              onEdit: { edit(entry) }
            )
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(2)
      }
    }
    .disabled(dictionary.isLoadingEntries || dictionary.mutationInProgress)
    .safeAreaInset(edge: .bottom, spacing: 12) {
      if dictionary.pageIndex > 0 || dictionary.hasNextPage {
        HStack {
          Text("第 \(dictionary.pageIndex + 1) 页")
            .foregroundStyle(.secondary)
          Spacer()
          Button("上一页") { dictionary.loadPreviousPage() }
            .disabled(dictionary.pageIndex == 0 || dictionary.isLoadingEntries)
            .accessibilityIdentifier("bestASR.dictionary.previousPage")
          Button("下一页") { dictionary.loadNextPage() }
            .disabled(!dictionary.hasNextPage || dictionary.isLoadingEntries)
            .accessibilityIdentifier("bestASR.dictionary.nextPage")
        }
        .font(.system(size: 12))
      }
    }
  }

  private var editor: some View {
    VStack(alignment: .leading, spacing: 20) {
      PageHeader(title: dictionary.editingDictionaryEntryID == nil ? "添加到词典" : "编辑词汇")
      Text("填写标准写法。识别经常出错时，可补充它常被听成的词。")
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
        GridRow {
          Text("写法").foregroundStyle(.secondary)
          TextField("例如：织机、张明", text: $dictionary.canonicalDraft)
            .textFieldStyle(.roundedBorder)
            .focused($canonicalIsFocused)
            .accessibilityIdentifier("bestASR.settings.dictionaryCanonical")
        }
        GridRow {
          Text("常被听成").foregroundStyle(.secondary)
          TextField("可选，用逗号分隔，例如：百思特", text: $dictionary.spokenFormsDraft)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("bestASR.settings.dictionarySpokenForms")
        }
      }
      HStack {
        Spacer()
        Button("取消", action: cancelEditing)
          .keyboardShortcut(.cancelAction)
          .disabled(dictionary.saveInProgress)
          .accessibilityIdentifier("bestASR.dictionary.cancelEdit")
        Button(dictionary.editingDictionaryEntryID == nil ? "添加" : "保存") {
          dictionary.saveDraft()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(
          dictionary.canonicalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || dictionary.saveInProgress
        )
        .accessibilityIdentifier("bestASR.settings.dictionarySave")
      }
    }
    .task { canonicalIsFocused = true }
  }

  private var transfer: some View {
    VStack(alignment: .leading, spacing: 24) {
      Button {
        route = .words
      } label: {
        Label("词典", systemImage: "chevron.left")
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier("bestASR.dictionary.backFromTransfer")
      PageHeader(title: "导入与导出")
      VStack(alignment: .leading, spacing: 10) {
        Text("导入词汇").font(.headline)
        Text("从 CSV 或 JSON 文件合并词汇，已有词典会保留。")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
        Button("选择文件…") { dictionary.importFile() }
          .accessibilityIdentifier("bestASR.dictionary.import")
      }
      Divider()
      VStack(alignment: .leading, spacing: 10) {
        Text("导出全部词汇").font(.headline)
        Text("包含已停用的词汇，仅保存词典内容。")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
        HStack(spacing: 12) {
          Picker("格式", selection: $exportFormat) {
            Text("CSV").tag(LocalDictionaryTransferFormat.csv)
            Text("JSON").tag(LocalDictionaryTransferFormat.json)
          }
          .pickerStyle(.segmented)
          .frame(width: 180)
          .accessibilityIdentifier("bestASR.dictionary.exportFormat")
          Button("导出…") { dictionary.exportFile(exportFormat) }
            .accessibilityIdentifier("bestASR.dictionary.export")
        }
      }
    }
  }

  private var status: some View {
    HStack(spacing: 8) {
      if dictionary.saveInProgress || dictionary.isLoadingEntries || dictionary.mutationInProgress {
        ProgressView().controlSize(.small)
      }
      Text(dictionary.dictionaryStatusMessage)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .help(dictionary.dictionaryStatusMessage)
        .accessibilityIdentifier("bestASR.dictionary.status")
    }
  }

  private func edit(_ entry: DictionaryEntry) {
    dictionary.beginEditing(entry)
    route = .editor
  }

  private func cancelEditing() {
    guard !dictionary.saveInProgress else { return }
    dictionary.beginNewEntry()
    route = .words
  }

  private func toggleChosenEnabled() {
    let entries = chosen
    let enable = !entries.allSatisfy(\.enabled)
    dictionary.setEntriesEnabled(entries, enabled: enable)
  }

  private func requestDeletion() {
    guard !chosen.isEmpty else { return }
    pendingDeletion = chosen
    confirmsDeletion = true
  }
}

/// The count row becomes the selection toolbar in place. Both states participate
/// in measurement, so first selection, deselection and changing counts cannot
/// move the word under the pointer. Hidden controls neither receive input nor
/// appear in accessibility; no empty spacer is used to imitate a toolbar.
struct DictionarySelectionToolbar: View {
  let entries: [DictionaryEntry]
  @Binding var selection: Set<DictionaryEntryID>
  var isPaged = false
  var onEdit: () -> Void = {}
  var onToggleEnabled: () -> Void = {}
  var onDelete: () -> Void = {}
  var onTransfer: () -> Void = {}

  var chosen: [DictionaryEntry] {
    entries.filter { selection.contains($0.id) }
  }

  var body: some View {
    let hasSelection = !chosen.isEmpty
    ZStack {
      HStack(spacing: 12) {
        Text(isPaged ? "本页 \(entries.count) 个词" : "\(entries.count) 个词")
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("bestASR.dictionary.entryCount")
        Spacer(minLength: 12)
        Button(isPaged ? "选择本页" : "全选", action: selectAll)
          .disabled(entries.isEmpty)
          .accessibilityIdentifier("bestASR.dictionary.selectAll")
        Button("导入与导出", action: onTransfer)
          .accessibilityIdentifier("bestASR.dictionary.transfer")
      }
      .opacity(hasSelection ? 0 : 1)
      .allowsHitTesting(!hasSelection)
      .disabled(hasSelection)
      .accessibilityHidden(hasSelection)

      HStack(spacing: 12) {
        Text("已选 \(chosen.count) 个词")
          .accessibilityIdentifier("bestASR.dictionary.selectionCount")
        Spacer(minLength: 12)
        Button("编辑", action: onEdit)
          .disabled(chosen.count != 1)
          .accessibilityIdentifier("bestASR.dictionary.editSelected")
        Button(chosen.allSatisfy(\.enabled) ? "停用" : "启用", action: onToggleEnabled)
          .accessibilityIdentifier("bestASR.dictionary.enableSelected")
        Button("删除…", role: .destructive, action: onDelete)
          .accessibilityIdentifier("bestASR.dictionary.deleteSelected")
        Button(isPaged ? "选择本页" : "全选", action: selectAll)
          .disabled(chosen.count == entries.count)
          .accessibilityIdentifier("bestASR.dictionary.selectAll")
        Button("取消选择") { selection = [] }
          .keyboardShortcut(hasSelection ? KeyboardShortcut.cancelAction : nil)
          .accessibilityIdentifier("bestASR.dictionary.clearSelection")
      }
      .opacity(hasSelection ? 1 : 0)
      .allowsHitTesting(hasSelection)
      .disabled(!hasSelection)
      .accessibilityHidden(!hasSelection)
    }
    .font(.system(size: 12))
    .lineLimit(1)
    .buttonStyle(.borderless)
    .controlSize(.small)
  }

  private func selectAll() {
    selection = Set(entries.map(\.id))
  }
}

/// A real button keeps selection available to keyboard and accessibility users.
/// Selection changes only the border and fill, never the word's size.
struct DictionaryWordButton: View {
  let entry: DictionaryEntry
  let selected: Bool
  let onSelect: () -> Void
  let onEdit: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 6) {
        Text(entry.canonicalForm)
          .font(.system(size: 13, weight: .medium))
          .strikethrough(!entry.enabled)
          .foregroundStyle(entry.enabled ? .primary : .secondary)
        if !entry.spokenForms.isEmpty {
          Text("\(entry.spokenForms.count)")
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(minWidth: 15)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.07), in: Capsule())
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(
        selected
          ? BestASRPalette.accent.opacity(0.14)
          : hovering ? BestASRPalette.rowHover : BestASRPalette.quietFill,
        in: Capsule()
      )
      .overlay {
        Capsule().strokeBorder(
          selected ? BestASRPalette.accent.opacity(0.65) : BestASRPalette.panelBorder
        )
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .simultaneousGesture(TapGesture(count: 2).onEnded { onEdit() })
    .help(
      entry.spokenForms.isEmpty
        ? "单击选择，双击编辑"
        : "常被听成：\(entry.spokenForms.joined(separator: "、"))。双击编辑"
    )
    .accessibilityLabel(entry.canonicalForm)
    .accessibilityValue(
      "\(selected ? "已选择" : "未选择")，\(entry.enabled ? "已启用" : "已停用")"
    )
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityAction(named: "编辑", onEdit)
    .accessibilityIdentifier("bestASR.dictionary.entry.\(entry.id.description)")
  }
}
