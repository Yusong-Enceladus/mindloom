import AppKit
import BestASRDomain
import BestASRPersistence
import SwiftUI

/// Colors for the main window: a warm grey canvas with the sidebar drawn
/// directly on it, and content on one raised panel.
enum BestASRPalette {
  static let accent = Color(red: 0x1F / 255, green: 0x5D / 255, blue: 0xF2 / 255)
  static let canvas = dynamic(light: 0xF2F1EE, dark: 0x1B1A19)
  static let panel = dynamic(light: 0xFFFFFF, dark: 0x252422)
  static let panelBorder = dynamic(light: 0xE6E4E0, dark: 0x34322F)
  static let rowHover = dynamic(light: 0xF6F5F3, dark: 0x2D2B29)
  static let sidebarSelection = dynamic(light: 0xFFFFFF, dark: 0x2E2C2A)
  static let quietFill = dynamic(light: 0xF4F3F0, dark: 0x2B2A28)
  static let heatEmpty = dynamic(light: 0xEBE9E5, dark: 0x302E2B)

  private static func dynamic(light: UInt32, dark: UInt32) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(
          srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
          green: CGFloat((hex >> 8) & 0xFF) / 255,
          blue: CGFloat(hex & 0xFF) / 255,
          alpha: 1
        )
      })
  }
}

struct SidebarNavigationButton: View {
  let title: String
  let symbol: String
  let selected: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: symbol)
          .font(.system(size: 14, weight: .medium))
          .frame(width: 20)
        Text(title)
          .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
        Spacer(minLength: 0)
      }
      .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.72))
      .padding(.horizontal, 10)
      .frame(height: 34)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background {
      RoundedRectangle(cornerRadius: 9)
        .fill(
          selected
            ? BestASRPalette.sidebarSelection
            : hovering ? Color.primary.opacity(0.05) : .clear
        )
        .shadow(color: .black.opacity(selected ? 0.06 : 0), radius: 1.5, y: 0.5)
    }
    .onHover { hovering = $0 }
    .accessibilityLabel(title)
  }
}

/// The raised content panel every main-window page sits on.
struct MainContentPanel<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(BestASRPalette.panel, in: RoundedRectangle(cornerRadius: 14))
      .overlay {
        RoundedRectangle(cornerRadius: 14).strokeBorder(BestASRPalette.panelBorder)
      }
      .clipShape(RoundedRectangle(cornerRadius: 14))
      .shadow(color: .black.opacity(0.04), radius: 6, y: 1)
  }
}

struct PageHeader<Trailing: View>: View {
  let title: String
  var subtitle: String?
  var subtitleIdentifier = "bestASR.page.subtitle"
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.system(size: 24, weight: .semibold))
        if let subtitle {
          Text(subtitle)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(subtitleIdentifier)
        }
      }
      Spacer(minLength: 12)
      trailing
        .fixedSize()
    }
  }
}

extension PageHeader where Trailing == EmptyView {
  init(title: String, subtitle: String? = nil) {
    self.init(title: title, subtitle: subtitle) { EmptyView() }
  }
}

struct SearchField: View {
  let prompt: String
  @Binding var text: String
  var identifier: String
  /// Fills the space it is given instead of a fixed 240 points. A library
  /// search is the page's primary control, not a widget in the corner.
  var fillsWidth = false

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
      TextField(prompt, text: $text)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .accessibilityIdentifier(identifier)
      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("清除搜索")
      }
    }
    .padding(.horizontal, 10)
    .frame(width: fillsWidth ? nil : 240)
    .frame(maxWidth: fillsWidth ? .infinity : nil)
    .frame(height: 30)
    .background(BestASRPalette.quietFill, in: RoundedRectangle(cornerRadius: 8))
  }
}

struct KeyCap: View {
  let label: String

  var body: some View {
    Text(label)
      .font(.system(size: 12, weight: .semibold, design: .rounded))
      .padding(.horizontal, 7)
      .frame(minWidth: 24, minHeight: 22)
      .background(BestASRPalette.panel, in: RoundedRectangle(cornerRadius: 6))
      .overlay {
        RoundedRectangle(cornerRadius: 6).strokeBorder(BestASRPalette.panelBorder)
      }
      .shadow(color: .black.opacity(0.08), radius: 0, y: 1)
  }
}

struct UsageStatTile: View {
  let title: String
  let value: String
  let unit: String
  let footnote: String
  let identifier: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(value)
          .font(.system(size: 26, weight: .semibold, design: .rounded))
          .monospacedDigit()
        Text(unit)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
      }
      Text(footnote)
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(BestASRPalette.quietFill, in: RoundedRectangle(cornerRadius: 12))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(identifier)
  }
}

/// A GitHub-style map of words dictated per day, as many recent weeks as fit.
struct DictationActivityMap: View {
  let wordsByDay: [Date: Int]
  var calendar = Calendar.current
  var now = Date()
  /// The day under the pointer. Its detail is written under the grid the
  /// moment the pointer arrives; a system tooltip took a second to appear
  /// and often did not.
  @State private var hoveredDay: Date?

  private let cell: CGFloat = 12
  private let gap: CGFloat = 3

  var body: some View {
    let levels = Self.levelThresholds(Array(wordsByDay.values))
    GeometryReader { geometry in
      let weeks = min(53, max(8, Int((geometry.size.width + gap) / (cell + gap))))
      let columns = weekColumns(weeks)
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .top, spacing: gap) {
          ForEach(columns.indices, id: \.self) { column in
            VStack(spacing: gap) {
              ForEach(columns[column], id: \.self) { day in
                let words = wordsByDay[day] ?? 0
                RoundedRectangle(cornerRadius: 3)
                  .fill(color(level: day > today ? -1 : Self.level(words, thresholds: levels)))
                  .frame(width: cell, height: cell)
                  .overlay {
                    if hoveredDay == day {
                      RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(0.6))
                    }
                  }
                  .onHover { inside in
                    if inside { hoveredDay = day } else if hoveredDay == day { hoveredDay = nil }
                  }
              }
            }
          }
        }
        HStack(spacing: 4) {
          Text(hoveredDay.map { tooltip(day: $0, words: wordsByDay[$0] ?? 0) } ?? startTitle(columns))
            .font(.system(size: 11))
            .foregroundStyle(hoveredDay == nil ? .secondary : .primary)
            .accessibilityIdentifier("bestASR.home.activityDetail")
          Spacer()
          Text("少").font(.system(size: 11)).foregroundStyle(.secondary)
          ForEach(0..<5) { level in
            RoundedRectangle(cornerRadius: 3)
              .fill(color(level: level))
              .frame(width: 10, height: 10)
          }
          Text("多").font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }
    }
    .frame(height: 7 * cell + 6 * gap + 8 + 14)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("口述活动图")
    .accessibilityIdentifier("bestASR.home.activity")
  }

  private var today: Date { calendar.startOfDay(for: now) }

  /// Columns are weeks (oldest first), each Sunday to Saturday.
  private func weekColumns(_ weeks: Int) -> [[Date]] {
    let weekday = calendar.component(.weekday, from: today) - 1
    guard
      let thisWeekStart = calendar.date(byAdding: .day, value: -weekday, to: today),
      let firstWeekStart = calendar.date(byAdding: .day, value: -7 * (weeks - 1), to: thisWeekStart)
    else { return [] }
    return (0..<weeks).map { week in
      (0..<7).compactMap {
        calendar.date(byAdding: .day, value: week * 7 + $0, to: firstWeekStart)
      }
    }
  }

  private func color(level: Int) -> Color {
    switch level {
    case ..<0: .clear
    case 0: BestASRPalette.heatEmpty
    default: BestASRPalette.accent.opacity([0.25, 0.45, 0.7, 1][min(level, 4) - 1])
    }
  }

  private func tooltip(day: Date, words: Int) -> String {
    let parts = calendar.dateComponents([.month, .day], from: day)
    let date = "\(parts.month ?? 0) 月 \(parts.day ?? 0) 日"
    return words == 0 ? "\(date) · 没有口述" : "\(date) · \(words) 字"
  }

  private func startTitle(_ columns: [[Date]]) -> String {
    guard let first = columns.first?.first else { return "" }
    let parts = calendar.dateComponents([.year, .month], from: first)
    return "\(parts.year ?? 0) 年 \(parts.month ?? 0) 月至今"
  }

  /// Quartile boundaries of the active days, so the map adapts to how much
  /// this person dictates.
  static func levelThresholds(_ values: [Int]) -> [Int] {
    let active = values.filter { $0 > 0 }.sorted()
    guard !active.isEmpty else { return [1, 1, 1] }
    return [0.25, 0.5, 0.75].map { active[min(active.count - 1, Int(Double(active.count) * $0))] }
  }

  static func level(_ words: Int, thresholds: [Int]) -> Int {
    guard words > 0 else { return 0 }
    return 1 + thresholds.filter { words > $0 }.count
  }
}

/// The source application's icon, or a symbol for records that did not come
/// from typing into an app.
struct HistorySourceIcon: View {
  let bundleID: String?
  let mode: SessionInputMode
  var size: CGFloat = 18

  @MainActor private static var cache: [String: NSImage] = [:]

  var body: some View {
    if let icon = appIcon {
      Image(nsImage: icon)
        .resizable()
        .interpolation(.high)
        .frame(width: size, height: size)
    } else {
      Image(systemName: symbol)
        .font(.system(size: size * 0.62, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: size, height: size)
        .background(BestASRPalette.quietFill, in: RoundedRectangle(cornerRadius: size * 0.25))
    }
  }

  private var symbol: String {
    switch mode {
    case .dictation: "text.cursor"
    case .roomMicrophone: "person.2.wave.2"
    case .systemAudio: "macbook.and.iphone"
    case .importedMedia: "doc.richtext"
    case .userItem: "tray.and.arrow.down"
    }
  }

  @MainActor private var appIcon: NSImage? {
    guard mode == .dictation || mode == .userItem, let bundleID, !bundleID.isEmpty
    else { return nil }
    if let cached = Self.cache[bundleID] { return cached }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    else { return nil }
    let icon = NSWorkspace.shared.icon(forFile: url.path)
    Self.cache[bundleID] = icon
    return icon
  }
}

/// One history entry: time, source icon and text, with actions on hover.
struct HistoryListRow: View {
  let item: DictationHistoryItem
  let text: String
  /// What the user searched for, so the row can show where it matched.
  var highlight: String = ""
  /// The row the keyboard is on. Arrow keys move it; Return opens it.
  var focused = false
  let status: String?
  let isPlaying: Bool
  let onOpen: () -> Void
  let onCopy: (() -> Void)?
  let onPlay: (() -> Void)?
  /// Set for pasted or dragged items: the user corrects the source label.
  var onChangeSource: ((String) -> Void)? = nil
  @State private var hovering = false
  @State private var editingSource = false
  @State private var sourceDraft = ""

  /// A screenshot or a file may have no text of its own until the Spark
  /// reads it.
  private var displayText: String {
    guard text.isEmpty else { return text }
    switch item.itemKind {
    case .image?: return "[截图]"
    case .file?: return "[文件] \(item.title)"
    default: return text
    }
  }

  static func spokenModeLabel(_ mode: String?) -> String? {
    switch mode {
    case "translate": "翻译"
    case "command": "指令"
    default: nil
    }
  }

  /// The row's text with every occurrence of the search term marked.
  ///
  /// A list that silently reorders itself as you type is not a search result:
  /// without this the user has to find, by eye, what the app already knows.
  private var attributedText: AttributedString {
    var attributed = AttributedString(displayText)
    let term = highlight.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return attributed }
    var searched = attributed.startIndex..<attributed.endIndex
    while let found = attributed[searched].range(of: term, options: .caseInsensitive) {
      attributed[found].backgroundColor = BestASRPalette.accent.opacity(0.22)
      attributed[found].font = .system(size: 13.5, weight: .semibold)
      guard found.upperBound < attributed.endIndex else { break }
      searched = found.upperBound..<attributed.endIndex
    }
    return attributed
  }

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Text(item.createdAt, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute())
        .font(.system(size: 12))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(width: 40, alignment: .leading)
        .padding(.top, 1.5)
      HistorySourceIcon(bundleID: item.sourceApplicationBundleID, mode: item.inputMode)
        .padding(.top, 0.5)
        .help(item.sourceDisplayName ?? "")
      VStack(alignment: .leading, spacing: 4) {
        if item.inputMode != .dictation {
          HStack(spacing: 6) {
            Text(item.title)
              .font(.system(size: 13.5, weight: .semibold))
              .lineLimit(1)
            if let duration = item.durationNanoseconds {
              Text(Duration.seconds(Double(duration) / 1_000_000_000).formatted(.time(pattern: .minuteSecond)))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
          }
        }
        // A dictation delivered as 翻译 or 指令 says so, in the quiet size
        // that distinguishes it without competing with the text.
        if item.inputMode == .userItem {
          SourceChip(label: item.sourceLabel)
            .contextMenu {
              if onChangeSource != nil {
                Button("更改来源…") {
                  sourceDraft = item.sourceDisplayName ?? ""
                  editingSource = true
                }
              }
            }
        }
        if let mode = Self.spokenModeLabel(item.spokenMode) {
          Text(mode)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(BestASRPalette.quietFill, in: Capsule())
            .accessibilityLabel("模式：\(mode)")
        }
        Text(attributedText)
          .font(.system(size: 13.5))
          .foregroundStyle(displayText.isEmpty ? .secondary : .primary)
          .lineLimit(3)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
        if let status {
          Text(status)
            .font(.system(size: 12))
            .foregroundStyle(.orange)
        }
      }
      HStack(spacing: 2) {
        if let onPlay {
          rowButton(isPlaying ? "pause.fill" : "play.fill", help: isPlaying ? "暂停" : "播放原音", action: onPlay)
            .accessibilityIdentifier("bestASR.history.play")
        }
        if let onCopy {
          rowButton("doc.on.doc", help: "复制", action: onCopy)
            .accessibilityIdentifier("bestASR.history.copy")
        }
        rowButton("chevron.right", help: "打开详情", action: onOpen)
          .accessibilityIdentifier("bestASR.history.details")
      }
      .opacity(hovering || isPlaying ? 1 : 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .background(
      focused
        ? BestASRPalette.accent.opacity(0.12)
        : hovering ? BestASRPalette.rowHover : .clear
    )
    .contentShape(Rectangle())
    .onTapGesture(perform: onOpen)
    .onHover { hovering = $0 }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(named: "打开详情", onOpen)
    .accessibilityIdentifier("bestASR.history.item")
    .alert("更改来源", isPresented: $editingSource) {
      TextField("App 名称", text: $sourceDraft)
      Button("保存") { onChangeSource?(sourceDraft) }
      Button("取消", role: .cancel) {}
    } message: {
      Text("只改这条内容的来源标签；内容本身不会改变。")
    }
  }

  private func rowButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 12, weight: .medium))
        .frame(width: 26, height: 26)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(help)
    .accessibilityLabel(help)
  }
}

/// A queue of things waiting to be confirmed, collapsed until opened.
///
/// Built from a button rather than a `DisclosureGroup` because that one only
/// responds to its triangle and its text: the rest of the row, which is most
/// of it, does nothing when clicked. Everyone aims at the row.
struct ReviewDisclosure<Content: View>: View {
  let title: String
  @Binding var expanded: Bool
  var identifier: String
  @ViewBuilder let content: Content
  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        expanded.toggle()
      } label: {
        HStack(spacing: 7) {
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
          Text(title)
            .font(.system(size: 13, weight: .medium))
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .background(
        hovering ? BestASRPalette.rowHover : .clear,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .onHover { hovering = $0 }
      .accessibilityLabel(title)
      .accessibilityAddTraits(.isButton)
      // On the header alone. Put on the enclosing stack, an identifier is
      // inherited by every view inside it, which replaced the identifier of
      // each control in the queue with this one — the reason nothing in here
      // could be found by name.
      .accessibilityIdentifier(identifier)
      if expanded { content }
    }
  }
}

/// Lays chips out left to right, wrapping to new lines.
struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(proposal.width ?? .infinity, subviews)
    let height = rows.last.map { $0.y + $0.height } ?? 0
    let width = rows.map(\.width).max() ?? 0
    return CGSize(width: proposal.width ?? width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    for row in arrange(bounds.width, subviews) {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        // Centred in the row rather than hung from its top, so a chip that is
        // taller than its neighbours does not leave them floating.
        let y = bounds.minY + row.y + (row.height - size.height) / 2
        subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
    }
  }

  private struct Row {
    var indices: [Int] = []
    var y: CGFloat = 0
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
    var rows: [Row] = []
    var current = Row()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      if needed > maxWidth, !current.indices.isEmpty {
        rows.append(current)
        current = Row(y: current.y + current.height + spacing)
      }
      current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      current.height = max(current.height, size.height)
      current.indices.append(index)
    }
    if !current.indices.isEmpty { rows.append(current) }
    return rows
  }
}
