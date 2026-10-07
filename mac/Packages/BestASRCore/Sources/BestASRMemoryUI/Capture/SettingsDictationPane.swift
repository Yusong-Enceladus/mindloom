import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: v12 find. Settings › 口述 › 词典 (ALIGNMENT 收1-7, B7 设计 10): every
// word, how it is written and how it tends to be heard; 添加词… and, on a
// row, 修改… / 删除…. Adding and changing open a small sheet (nothing opens
// in place and pushes the list down, 9/23). Deleting asks first. Each word
// has its switch (used in dictation or not), and the list imports and
// exports CSV or JSON as d54's dictionary page did (review of 10-6: 23 of
// the owner's 64 words were off with no way to see or change it).

/// One dictionary word as Settings lists it.
public struct SettingsDictionaryWord: Equatable, Identifiable, Sendable {
  public let id: String
  /// How it is written.
  public let written: String
  /// How it tends to be heard.
  public let heard: [String]
  /// Dictation uses it (its switch); off words stay in the list.
  public let enabled: Bool
  /// Added from the user's corrections (自动添加, 收1-8): how often and what
  /// it is used for (「更正过 2 次 · 用于识别和替换」). Nil for a word the user
  /// added.
  public let learned: String?
  /// For a word the user added: the 「识别为」 forms their corrections added
  /// to it (自动添加), which can be removed.
  public let learnedForms: [String]

  public init(
    id: String, written: String, heard: [String], enabled: Bool = true,
    learned: String? = nil, learnedForms: [String] = []
  ) {
    self.id = id
    self.written = written
    self.heard = heard
    self.enabled = enabled
    self.learned = learned
    self.learnedForms = learnedForms
  }
}

/// Which words the dictionary list shows.
enum DictionaryFilter: String, CaseIterable, Identifiable {
  case all
  case manual
  case automatic

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: "全部"
    case .manual: "手动添加"
    case .automatic: "自动添加"
    }
  }

  func includes(_ word: SettingsDictionaryWord) -> Bool {
    switch self {
    case .all: true
    case .manual: word.learned == nil
    case .automatic: word.learned != nil || !word.learnedForms.isEmpty
    }
  }
}

/// 口述 › 速度与占用 (ALIGNMENT 收1-2 to 收1-5): what this Mac measured of
/// its own dictations — how long from letting go of the key to the words,
/// how much memory the App holds, and how much space recordings, models and
/// files take. The App fills it when the pane appears.
public struct SettingsDictationMetrics: Equatable, Sendable {
  /// Key up to text over one period.
  public struct Latency: Equatable, Sendable {
    public let count: Int
    public let p50Milliseconds: Int
    public let p95Milliseconds: Int

    public init(count: Int, p50Milliseconds: Int, p95Milliseconds: Int) {
      self.count = count
      self.p50Milliseconds = p50Milliseconds
      self.p95Milliseconds = p95Milliseconds
    }
  }

  public var week: Latency?
  public var month: Latency?
  public var memoryBytes: UInt64?
  public var recordingsBytes: UInt64?
  public var modelsBytes: UInt64?
  public var filesBytes: UInt64?

  public init(
    week: Latency? = nil, month: Latency? = nil, memoryBytes: UInt64? = nil,
    recordingsBytes: UInt64? = nil, modelsBytes: UInt64? = nil, filesBytes: UInt64? = nil
  ) {
    self.week = week
    self.month = month
    self.memoryBytes = memoryBytes
    self.recordingsBytes = recordingsBytes
    self.modelsBytes = modelsBytes
    self.filesBytes = filesBytes
  }

  /// 「一半在 0.42 秒内，95% 在 0.78 秒内（共 56 次）」, or 「暂无记录」.
  public static func latencyText(_ latency: Latency?) -> String {
    guard let latency, latency.count > 0 else { return "暂无记录" }
    return "一半在 \(seconds(latency.p50Milliseconds))内，95% 在 "
      + "\(seconds(latency.p95Milliseconds))内（共 \(latency.count) 次）"
  }

  /// 「0.42 秒」; one decimal from ten seconds on.
  public static func seconds(_ milliseconds: Int) -> String {
    let value = Double(max(0, milliseconds)) / 1_000
    return String(format: value < 10 ? "%.2f 秒" : "%.1f 秒", value)
  }

  /// Disk sizes, as Finder shows them (1 KB = 1,000 bytes).
  public static func byteCount(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
  }

  /// Memory, as Activity Monitor shows it (1 KB = 1,024 bytes): the same
  /// number its 内存 column and the memory budgets use.
  public static func memoryCount(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
  }

  /// 「当前 612 MB」.
  public var memoryText: String {
    memoryBytes.map { "当前 \(Self.memoryCount($0))" } ?? "正在读取…"
  }

  /// 「录音 304 MB · 模型 5.4 GB · 文件 12 MB」.
  public var storageText: String {
    guard let recordingsBytes, let modelsBytes, let filesBytes else { return "正在读取…" }
    return "录音 \(Self.byteCount(recordingsBytes)) · 模型 \(Self.byteCount(modelsBytes)) · "
      + "文件 \(Self.byteCount(filesBytes))"
  }
}

/// The figures of 口述 › 速度与占用.
struct SettingsDictationMetricsGroup: View {
  let metrics: SettingsDictationMetrics

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SettingsGroup(
        "松开按键到文字出现", footer: "统计这台 Mac 上的口述，不含翻译和指令。记录保留 90 天。"
      ) {
        SettingsRow(nil, "最近 7 天") {
          value(SettingsDictationMetrics.latencyText(metrics.week))
        }
        SettingsSeparator()
        SettingsRow(nil, "最近 30 天") {
          value(SettingsDictationMetrics.latencyText(metrics.month))
        }
      }
      SettingsGroup("内存与储存空间") {
        SettingsRow("memorychip", "内存") { value(metrics.memoryText) }
        SettingsSeparator()
        SettingsRow("internaldrive", "储存空间") { value(metrics.storageText) }
      }
      .padding(.top, 18)
    }
    .padding(.bottom, 22)
  }

  private func value(_ text: String) -> some View {
    Text(text).mlFont(\.sub).foregroundStyle(MLColor.ink2)
      .multilineTextAlignment(.trailing)
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct SettingsDictationPane: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  let state: MindloomSettingsState
  let actions: MindloomSettingsActions
  @State private var editing: Editing?
  @State private var deleting: SettingsDictionaryWord?
  @State private var filter: DictionaryFilter = .all

  struct Editing: Identifiable {
    let word: SettingsDictionaryWord?
    var id: String { word?.id ?? "new" }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SettingsDictationMetricsGroup(metrics: state.dictationMetrics)
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text("词典").mlFont(\.headline).foregroundStyle(MLColor.ink)
          Text("口述中出现这些词时，按这里的写法输入。也可以在“历史”中某条记录的菜单里选取“添加到词典…”。")
            .mlFont(\.sub).foregroundStyle(MLColor.ink2)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 12)
        Button {
          editing = Editing(word: nil)
        } label: {
          Label("添加词条…", systemImage: "plus")
        }
        .buttonStyle(MLButtonStyle(.standard))
      }
      .padding(.bottom, 12)
      HStack(spacing: 14) {
        Button("导入…") { actions.importWords() }
        Menu("导出") {
          Button("CSV 文件…") { actions.exportWords(false) }
          Button("JSON 文件…") { actions.exportWords(true) }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(state.dictionary.isEmpty)
        Spacer(minLength: 0)
      }
      .buttonStyle(.plain)
      .mlFont(\.foot)
      .foregroundStyle(MLColor.accent)
      .padding(.bottom, 10)
      if let note = state.dictionaryNote {
        Text(note).mlFont(\.sub).foregroundStyle(MLColor.alert).padding(.bottom, 8)
      }
      if let status = state.dictionaryStatus {
        Text(status).mlFont(\.sub).foregroundStyle(MLColor.ink2).padding(.bottom, 8)
      }
      Picker("显示", selection: $filter) {
        ForEach(DictionaryFilter.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .padding(.bottom, 10)
      if filter == .automatic {
        // How to correct where the field shows no text (review 10-6 S9): for
        // this user Claude and WeChat are most of what is dictated into.
        Text(
          "你在口述后更正的词会添加到这里。更正一次时用于替换；同样的更正出现两次后，也用于识别。删除的词以后不再自动添加。在 Claude、微信等不提供输入框文字的 App 中，选中写错的词，按住 fn 键再按空格键，说出正确的写法。"
        )
        .mlFont(\.foot).foregroundStyle(MLColor.ink2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 8)
      }
      let shown = state.dictionary.filter(filter.includes)
      if shown.isEmpty {
        Text("无词条。").mlFont(\.sub).foregroundStyle(MLColor.ink3).padding(.vertical, 12)
      } else {
        VStack(spacing: 0) {
          ForEach(Array(shown.enumerated()), id: \.element.id) { index, word in
            if index > 0 { Divider().padding(.leading, 14) }
            row(word)
          }
        }
        .background(MLColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(
            MLColor.rule2, lineWidth: 0.5))
      }
    }
    .sheet(item: $editing) { editing in
      DictionaryWordSheet(word: editing.word) { written, heard in
        actions.saveWord(editing.word?.id, written, heard)
        self.editing = nil
      } cancel: {
        self.editing = nil
      }
    }
    .confirmationDialog(
      "删除“\(deleting?.written ?? "")”？",
      isPresented: Binding(
        get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible
    ) {
      Button("删除", role: .destructive) {
        if let word = deleting { actions.deleteWord(word.id) }
        deleting = nil
      }
      Button("取消", role: .cancel) { deleting = nil }
    } message: {
      Text("删除后，口述时不再按这个写法输入。")
    }
    .onAppear { actions.refreshDictationMetrics() }
  }

  private func row(_ word: SettingsDictionaryWord) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(word.written).mlFont(\.control).foregroundStyle(
          word.enabled ? MLColor.ink : MLColor.ink3)
        if !word.heard.isEmpty {
          Text("识别为 " + word.heard.joined(separator: "、")).mlFont(\.foot).foregroundStyle(
            MLColor.ink2)
        }
        if !word.enabled {
          Text(Self.offLine).mlFont(\.foot).foregroundStyle(MLColor.ink3)
        }
        if let learned = word.learned {
          Text("自动添加 · " + learned).mlFont(\.foot).foregroundStyle(MLColor.ink3)
        }
        if !word.learnedForms.isEmpty {
          HStack(spacing: 8) {
            Text("自动添加 · 识别为 " + word.learnedForms.joined(separator: "、"))
              .mlFont(\.foot).foregroundStyle(MLColor.ink3)
            Button("移除") { actions.forgetLearnedForms(word.id) }
              .buttonStyle(.plain).mlFont(\.foot).foregroundStyle(MLColor.accent)
              .accessibilityLabel("移除自动添加的识别写法")
          }
        }
      }
      Spacer(minLength: 8)
      SettingsSwitch(title: "口述时使用“\(word.written)”", isOn: word.enabled) { on in
        actions.setWordEnabled(word.id, on)
      }
      Button("编辑…") { editing = Editing(word: word) }
        .buttonStyle(.plain).mlFont(\.foot).foregroundStyle(MLColor.accent)
      Button("删除…") { deleting = word }
        .buttonStyle(.plain).mlFont(\.foot).foregroundStyle(MLColor.ink2)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
  }
}

extension SettingsDictationPane {
  /// Under a word that is off.
  static let offLine = "已停用：口述时不使用"
}

/// 添加词 / 修改: 「写成」 and 「常被听成」 (commas or 、 between several).
struct DictionaryWordSheet: View {
  let word: SettingsDictionaryWord?
  let save: (String, [String]) -> Void
  let cancel: () -> Void
  @State private var written: String
  @State private var heard: String
  @FocusState private var focused: Bool
  @FocusState private var heardFocused: Bool

  init(
    word: SettingsDictionaryWord?, save: @escaping (String, [String]) -> Void,
    cancel: @escaping () -> Void
  ) {
    self.word = word
    self.save = save
    self.cancel = cancel
    _written = State(initialValue: word?.written ?? "")
    _heard = State(initialValue: word?.heard.joined(separator: "、") ?? "")
  }

  private var heardList: [String] {
    heard.split(whereSeparator: { "、,，;；".contains($0) || $0.isNewline })
      .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  var body: some View {
    MindloomSheetChrome(width: 420, drawsCard: false) {
      Text(word == nil ? "添加词条" : "编辑“\(word!.written)”").mlFont(\.title2).foregroundStyle(
        MLColor.ink
      )
      .padding(.bottom, 14)
      HStack(spacing: 10) {
        Text("写成").mlFont(\.control).foregroundStyle(MLColor.ink2).frame(
          width: 64, alignment: .leading)
        MindloomSheetField(placeholder: "正确的写法", text: $written, focused: $focused)
          .accessibilityLabel("写成")
      }
      HStack(spacing: 10) {
        Text("常被识别为").mlFont(\.control).foregroundStyle(MLColor.ink2).frame(
          width: 64, alignment: .leading)
        MindloomSheetField(placeholder: "可选；多个之间用顿号分隔", text: $heard, focused: $heardFocused)
          .accessibilityLabel("常被识别为")
          .onSubmit(done)
      }
      .padding(.top, 8)
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        Button("取消", action: cancel)
          .buttonStyle(MLButtonStyle(.standard))
          .keyboardShortcut(.cancelAction)
        Button(word == nil ? "添加" : "保存", action: done)
          .buttonStyle(MLButtonStyle(.primary))
          .keyboardShortcut(.defaultAction)
          .disabled(written.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      .padding(.top, 20)
    }
    .onAppear { focused = true }
  }

  private func done() {
    let clean = written.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    save(clean, heardList.filter { $0 != clean })
  }
}
