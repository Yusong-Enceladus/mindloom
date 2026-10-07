import AppKit
import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: v12 find. 历史 (ALIGNMENT 查-1 to 查-7, B4 §3.4–§3.6, B7 U1/U18):
// one page for the sidebar's 历史 and the toolbar's search field. Nothing
// typed: every record, newest first, under day headers that stay at the top
// while the day scrolls, 100 at a time as the list nears its end. Something
// typed: the conditions read out of it as grey chips (× removes one), then
// 事 · 人 · 原话, records by relevance (by time when only a time, source or
// person was typed), never capped. A record with a recording has ▶, which
// plays from the sentence that matched; space pauses, ← → skip 15 s. Each
// record can be copied, shared, have a misheard word put in the dictionary,
// be exported (words and subtitles, the recording) or deleted.

public struct HistoryPageInput: Equatable, Sendable {
  /// The search field's text ("" is the whole history).
  public let query: String
  /// A record to show and light once (menu bar 最近记录).
  public let revealRow: String?

  public init(query: String, revealRow: String? = nil) {
    self.query = query
    self.revealRow = revealRow
  }
}

public struct HistoryPage: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  @Environment(\.colorScheme) private var scheme
  let context: MindloomPageContext
  let input: HistoryPageInput

  public init(context: MindloomPageContext, input: HistoryPageInput) {
    self.context = context
    self.input = input
  }

  private var history: MemoryHistoryState { context.state.history }
  private var query: String { input.query.trimmingCharacters(in: .whitespacesAndNewlines) }
  /// Results for another query are not shown under this one's title.
  private var current: Bool {
    history.query.trimmingCharacters(in: .whitespacesAndNewlines) == query
  }

  public var body: some View {
    Group {
      if snapshot {
        MindloomPageScroll(key: context.navigation.scrollKey) { content }
      } else {
        ScrollViewReader { proxy in
          ScrollView(.vertical) {
            content
              .frame(maxWidth: .infinity, alignment: .topLeading)
              .padding(.top, 4)
              .padding(.horizontal, 32)
              .padding(.bottom, 48)
          }
          .scrollIndicators(.hidden)
          // The floating toolbar covers the top 52 pt: day headers stop
          // under it.
          .safeAreaPadding(.top, 52)
          .onAppear { reveal(proxy) }
          .onChange(of: history.rows.count) { reveal(proxy) }
        }
      }
    }
    .background {
      // AppKit views do not draw into a still image.
      if !snapshot {
        HistoryKeys(enabled: context.state.playbackItemID != nil) { key in
          switch key {
          case .toggle: context.actions.history.togglePlayback()
          case .back: context.actions.history.skip(-15)
          case .forward: context.actions.history.skip(15)
          }
        }
      }
    }
    .task(id: query) {
      guard !snapshot else { return }
      context.actions.searchText(query)
    }
  }

  private func reveal(_ proxy: ScrollViewProxy) {
    guard let row = input.revealRow, history.rows.contains(where: { $0.itemID == row }) else {
      return
    }
    proxy.scrollTo(row, anchor: .center)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { context.navigator.reveal(nil) }
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: snapshot ? [] : [.sectionHeaders]) {
      title
      if current, !history.chips.isEmpty { chips.padding(.top, 8) }
      if !current || (history.loading && history.rows.isEmpty) {
        Color.clear.frame(height: 200)
      } else if history.rows.isEmpty && history.matters.isEmpty && history.personIDs.isEmpty {
        empty.padding(.top, 70)
      } else {
        results
      }
    }
  }

  private var title: some View {
    Text(query.isEmpty ? "历史" : "“\(query)”")
      .mlFont(\.title)
      .foregroundStyle(MLColor.ink)
      .padding(.top, 10)
      .padding(.leading, query.isEmpty ? 0 : -13)
      .padding(.bottom, 2)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityAddTraits(.isHeader)
  }

  /// 「上周 · 9月21日–9月27日 ×」「微信 ×」: one click takes the words out.
  private var chips: some View {
    FlowRows(spacing: 6) {
      ForEach(history.chips) { chip in
        Button {
          context.navigator.setSearch(SearchQueryParser.removing(chip, from: input.query))
        } label: {
          HStack(spacing: 4) {
            Image(systemName: symbol(chip)).font(.system(size: 10))
            Text(chip.label).mlFont(\.foot)
            Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
              .foregroundStyle(MLColor.ink3)
          }
          .foregroundStyle(MLColor.ink2)
          .padding(.horizontal, 9)
          .frame(height: 22)
          .background(MLColor.fill2, in: Capsule())
          .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("移除此条件")
        .accessibilityLabel("移除“\(chip.label)”")
      }
    }
  }

  private func symbol(_ chip: SearchChip) -> String {
    switch chip.kind {
    case .person: "person"
    case .source: "tray"
    case .time: "calendar"
    }
  }

  @ViewBuilder
  private var empty: some View {
    if query.isEmpty {
      HomeEmptyMessage(title: "尚无记录", message: "口述、会议和添加的内容按日期列在这里。")
    } else {
      VStack(spacing: 14) {
        HomeEmptyMessage(
          title: "无结果",
          message: history.chips.isEmpty
            ? "请尝试其他关键词。" : history.widen.isEmpty ? "移除一个灰色条件可扩大搜索范围。" : nil)
        ForEach(history.widen) { widen in
          Button {
            context.navigator.setSearch(widen.query)
          } label: {
            Text("不限“\(widen.chip.label)”时有 \(widen.count) 条")
              .mlFont(\.sub)
              .foregroundStyle(MLColor.accent)
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  // MARK: - Results

  @ViewBuilder
  private var results: some View {
    if !history.matters.isEmpty { matters }
    if !history.personIDs.isEmpty { people }
    if !history.rows.isEmpty {
      if history.ordersByTime {
        if !query.isEmpty { section("原话", count: history.total) }
        let calendar = SearchClock.productCalendar
        ForEach(MemoryHistoryBuilder.days(history.rows, calendar: calendar)) { day in
          Section {
            ForEach(day.rows) { row in
              HistoryRowView(context: context, row: row, showsDay: false, highlights: [])
            }
          } header: {
            dayHeader(day.day, calendar: calendar)
          }
        }
      } else {
        section("原话", count: history.total)
        ForEach(Array(history.rows.enumerated()), id: \.element.id) { index, row in
          if row.partial, index == 0 || !history.rows[index - 1].partial {
            Text(index == 0 ? "没有同时包含所有词的结果，以下结果包含其中部分词" : "以下结果包含其中部分词")
              .mlFont(\.foot).foregroundStyle(MLColor.ink3)
              .padding(.top, 14).padding(.bottom, 4)
          }
          HistoryRowView(
            context: context, row: row, showsDay: true,
            highlights: history.highlights + row.soundAlikes)
        }
      }
      if history.hasMore {
        ProgressView().controlSize(.small)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 16)
          .onAppear { context.actions.history.loadMore() }
      }
    }
  }

  /// The first matters found; 「还有 N 件」 opens all of them on a page of
  /// their own, so nothing below moves (B7 设计 5, 8; review v12-B #15).
  private var matters: some View {
    let shown = Array(history.matters.prefix(Self.mattersShown))
    return VStack(alignment: .leading, spacing: 0) {
      section("事", count: nil)
      ForEach(shown) { hit in
        HistoryMatterRow(context: context, hit: hit, highlights: history.highlights)
      }
      if history.matters.count > shown.count {
        Button("另有 \(history.matters.count - shown.count) 件") {
          context.navigator.openMatterResults(query)
        }
        .buttonStyle(.plain)
        .mlFont(\.sub)
        .foregroundStyle(MLColor.accent)
        .padding(.vertical, 6)
        .accessibilityHint("打开找到的所有事")
      }
    }
  }

  /// How many matters 历史 shows above 人 and 原话.
  public static let mattersShown = 5

  private var people: some View {
    VStack(alignment: .leading, spacing: 0) {
      section("人", count: nil)
      ForEach(history.personIDs, id: \.self) { id in
        if let person = context.state.people.first(where: { $0.personID == id }) {
          resultButton {
            context.navigator.openPerson(id)
          } label: {
            HStack(spacing: 12) {
              Image(systemName: "person").font(.system(size: 14)).foregroundStyle(MLColor.ink2)
                .frame(width: 16)
              VStack(alignment: .leading, spacing: 2) {
                Text(person.name).mlFont(\.headline).foregroundStyle(MLColor.ink)
                FadingText(
                  Text(
                    person.events.prefix(2).map { MLAutospace.apply($0.title) }.joined(
                      separator: " · ")),
                  fade: 32.5
                )
                .mlFont(\.sub).foregroundStyle(MLColor.ink2)
              }
            }
          }
        }
      }
    }
  }

  private func section(_ title: String, count: Int?) -> some View {
    HStack(spacing: 6) {
      Text(title).mlFont(\.section).foregroundStyle(MLColor.ink2)
      if let count {
        Text("\(count) 条").font(.system(size: 11)).monospacedDigit().foregroundStyle(MLColor.ink3)
      }
    }
    .padding(.top, 22)
    .padding(.bottom, 6)
    .accessibilityAddTraits(.isHeader)
  }

  private func dayHeader(_ day: Date, calendar: Calendar) -> some View {
    let today = calendar.startOfDay(for: context.state.now)
    let n = MemoryDigest.days(from: day, to: today, calendar: calendar)
    let word = n == 0 ? "今天 · " : n == 1 ? "昨天 · " : ""
    let year =
      calendar.component(.year, from: day) == calendar.component(.year, from: today)
      ? "" : "\(calendar.component(.year, from: day))年"
    return Text(word + year + MindloomDates.dayTitle(day, calendar: calendar))
      .mlFont(\.section)
      .foregroundStyle(MLColor.ink2)
      .monospacedDigit()
      .padding(.top, 14)
      .padding(.bottom, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(MLColor.paper)
      .accessibilityAddTraits(.isHeader)
  }

  private func resultButton<Label: View>(
    _ action: @escaping () -> Void, @ViewBuilder label: () -> Label
  ) -> some View {
    label()
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 8)
      .padding(.horizontal, 12)
      .modifier(HomeRowChrome())
      .padding(.horizontal, -12)
      .onTapGesture(perform: action)
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { action() }
  }

  private func highlighted(_ text: String) -> Text {
    HistoryHighlight.text(text, history.highlights, scheme: scheme)
  }
}

/// One record: 「9月27日 15:49 · 微信 · 叠衣服真机实验」, two lines of its
/// words, ▶ when it has a recording, and ⋯ (复制 · 分享… · 加进词典… · 打开所在的事).
struct HistoryRowView: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  @Environment(\.colorScheme) private var scheme
  let context: MindloomPageContext
  let row: MemoryHistoryRow
  /// The date before the time (relevance order has no day headers).
  let showsDay: Bool
  let highlights: [String]

  private var expanded: Bool { context.navigation.expandedItems.contains(row.itemID) }
  private var lit: Bool { context.navigation.revealRow == row.itemID }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          MLSymbol(row.symbol, size: 12, box: 13)
          FadingText(Text(meta), fade: 30)
        }
        .mlFont(\.foot)
        .monospacedDigit()
        .foregroundStyle(MLColor.ink2)
        if expanded {
          HistoryHighlight.text(row.fullText, highlights, scheme: scheme)
            .mlFont(\.body)
            .foregroundStyle(MLColor.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          TwoLineText(
            text: HistoryHighlight.text(
              row.line.isEmpty ? " " : row.line, highlights, scheme: scheme),
            leadFade: row.cutBefore
          )
          .mlFont(\.body)
          .foregroundStyle(row.line.isEmpty ? MLColor.ink3 : MLColor.ink)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if row.playable { playButton }
      menu
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 12)
    .modifier(HomeRowChrome(lit: lit))
    .padding(.horizontal, -12)
    .contentShape(Rectangle())
    .onTapGesture(perform: open)
    .contextMenu { items }
    .id(row.itemID)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { open() }
  }

  /// 「9月27日 15:49 · 微信 · 叠衣服真机实验 · 1 分 12 秒」.
  private var meta: String {
    let calendar = SearchClock.productCalendar
    var parts: [String] = []
    let time = MindloomDates.clock(row.time, calendar: calendar)
    parts.append(
      showsDay ? MindloomDates.monthDay(row.time, calendar: calendar) + " " + time : time)
    parts.append(row.source)
    if let title = row.matterTitle { parts.append(MLAutospace.apply(title)) }
    if let duration = row.duration { parts.append(duration) }
    return parts.joined(separator: " · ")
  }

  private var playing: Bool { context.state.playingItemID?.uppercased() == row.itemID }

  private var playButton: some View {
    Button {
      if context.state.playbackItemID?.uppercased() == row.itemID {
        context.actions.history.togglePlayback()
      } else {
        context.actions.history.play(row.itemID, row.playFrom)
      }
    } label: {
      Image(systemName: playing ? "pause.fill" : "play.fill")
        .font(.system(size: 11))
        .foregroundStyle(MLColor.ink)
        .frame(width: 26, height: 26)
        .background(MLColor.fill2, in: Circle())
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help(row.playFrom == nil ? "播放" : "从这句开始播放")
    .accessibilityLabel(playing ? "暂停" : "播放")
  }

  @ViewBuilder
  private var menu: some View {
    let face = Image(systemName: "ellipsis")
      .font(.system(size: 13))
      .foregroundStyle(MLColor.ink2)
      .frame(width: 26, height: 26)
      .contentShape(Rectangle())
    if snapshot {
      face
    } else {
      Menu {
        items
      } label: {
        face
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("更多")
      .accessibilityLabel("更多")
    }
  }

  @ViewBuilder
  private var items: some View {
    ForEach(Array(HistoryRowMenu.entries(for: row).enumerated()), id: \.offset) { _, entry in
      item(entry)
    }
  }

  @ViewBuilder
  private func item(_ entry: HistoryRowMenu.Entry) -> some View {
    switch entry {
    case .copy:
      Button {
        context.actions.history.copy(row.itemID)
      } label: {
        Label("拷贝", systemImage: "doc.on.doc")
      }
    case .share:
      ShareLink(item: row.fullText) {
        Label("共享…", systemImage: "square.and.arrow.up")
      }
    case .addToDictionary:
      Button {
        context.navigator.present(.addToDictionary(itemID: row.itemID))
      } label: {
        Label("添加到词典…", systemImage: "character.book.closed")
      }
    case .exportText(let kinds):
      Menu {
        ForEach(kinds, id: \.self) { kind in
          Button(kind.title) { context.actions.history.exportText(row.itemID, kind) }
        }
      } label: {
        Label(HistoryRowMenu.exportTextTitle(kinds), systemImage: "square.and.arrow.down")
      }
    case .exportAudio:
      Button {
        context.actions.history.exportAudio(row.itemID)
      } label: {
        Label("导出录音…", systemImage: "waveform")
      }
    case .openMatter(let eventID):
      Button {
        context.navigator.openMatter(eventID, tab: .text, revealRow: row.itemID)
      } label: {
        Label("打开所在的事", systemImage: "arrow.forward.circle")
      }
    case .delete:
      Button(role: .destructive) {
        context.actions.history.delete(row.itemID)
      } label: {
        Label("删除…", systemImage: "trash")
      }
    case .divider:
      Divider()
    }
  }

  /// In a matter: the matter's 原文 at this record. Otherwise its whole text
  /// opens in place (and closes again).
  private func open() {
    if let eventID = row.eventID {
      context.navigator.openMatter(eventID, tab: .text, revealRow: row.itemID)
    } else {
      context.navigator.toggleExpanded(row.itemID)
    }
  }
}

/// The hits of a query on an `accentTint2` ground, every spelling, every
/// place (case and width ignored).
enum HistoryHighlight {
  static func text(_ text: String, _ highlights: [String], scheme: ColorScheme) -> Text {
    guard !highlights.isEmpty else { return Text(text) }
    var attributed = AttributedString(text)
    var marked: [Range<String.Index>] = []
    for key in highlights where !key.isEmpty {
      var from = text.startIndex
      while let range = text.range(
        of: key, options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
        range: from..<text.endIndex)
      {
        if !marked.contains(where: { $0.overlaps(range) }) { marked.append(range) }
        from = range.upperBound
      }
    }
    for range in marked {
      if let lower = AttributedString.Index(range.lowerBound, within: attributed),
        let upper = AttributedString.Index(range.upperBound, within: attributed)
      {
        attributed[lower..<upper].backgroundColor = MLColor.accentTint2.color(for: scheme)
      }
    }
    return Text(attributed)
  }
}

/// Space and ← → while a record's recording is loaded and no text field
/// has the keyboard (the search field keeps its own keys).
struct HistoryKeys: NSViewRepresentable {
  enum Key { case toggle, back, forward }
  let enabled: Bool
  let perform: @MainActor (Key) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    context.coordinator.view = view
    context.coordinator.install()
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.view = nsView
    context.coordinator.enabled = enabled
    context.coordinator.perform = perform
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.remove()
  }

  @MainActor
  final class Coordinator {
    weak var view: NSView?
    var enabled = false
    var perform: (@MainActor (Key) -> Void)?
    private var monitor: Any?

    func install() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        let code = event.keyCode
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let repeated = event.isARepeat
        let window = event.window
        let handled = MainActor.assumeIsolated {
          self?.handle(code: code, flags: flags, repeated: repeated, window: window) ?? false
        }
        return handled ? nil : event
      }
    }

    func remove() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    private func handle(
      code: UInt16, flags: NSEvent.ModifierFlags, repeated: Bool, window: NSWindow?
    ) -> Bool {
      guard enabled, !repeated, let own = view?.window, own.isKeyWindow, window === own,
        !(own.firstResponder is NSText)
      else { return false }
      let key: Key
      switch (code, flags) {
      case (49, []): key = .toggle
      case (123, []), (123, .command): key = .back
      case (124, []), (124, .command): key = .forward
      default: return false
      }
      perform?(key)
      return true
    }
  }
}
