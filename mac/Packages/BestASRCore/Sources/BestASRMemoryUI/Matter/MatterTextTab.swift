import AppKit
import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: mac-matter. S8 · 原文 (MAC-SPEC §4.10): only the parts of items about
// this matter, newest first, by day; source line, speaker prefixes, the
// quote highlighted, 「展开」, the item 「⋯」 menu (复制 · 移到别的事… /
// 不属于这件事; none in member view), the revealed row. The words are
// selectable (drag, double-click, ⌘C); a right-click still opens the item
// menu (`MindloomRightClickMenu`). Entries: `MatterTexts`
// (`projection.matterTexts`).

public struct MatterTextTabInput: Equatable, Sendable {
  public let eventID: String
  public let revealRow: String?
  public let memberView: Bool

  public init(eventID: String, revealRow: String?, memberView: Bool) {
    self.eventID = eventID
    self.revealRow = revealRow
    self.memberView = memberView
  }
}

extension MemoryScreenState {
  /// A matter's 原文 entries as its page shows them (a member does not see
  /// the owner's dictations).
  func matterTexts(_ eventID: String, keep: String? = nil, memberView: Bool = false)
    -> [MatterTextEntry]
  {
    guard let matter = matter(eventID), let projection else { return [] }
    let entries = projection.matterTexts(
      matter, ownerNames: digest?.ownerNames ?? [], keep: keep.map { [$0] } ?? [])
    return memberView ? entries.filter { !$0.ownerSpoken } : entries
  }
}

public struct MatterTextTab: View {
  let context: MindloomPageContext
  let input: MatterTextTabInput

  public init(context: MindloomPageContext, input: MatterTextTabInput) {
    self.context = context
    self.input = input
  }

  public var body: some View {
    let state = context.state
    let entries = state.matterTexts(
      input.eventID, keep: input.revealRow, memberView: input.memberView)
    Group {
      if entries.isEmpty {
        Text("这件事尚无原文。")
          .mlFont(\.sub, lineBox: true)
          .foregroundStyle(MLColor.ink2)
          .frame(maxWidth: .infinity)
          .padding(.top, 60)
      } else {
        ScrollViewReader { reader in
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(days(entries).enumerated()), id: \.element.day) { index, group in
              Text(dayHeader(group.day))
                .mlFont(\.section, lineBox: true)
                .foregroundStyle(MLColor.ink2)
                .padding(.top, index == 0 ? 4 : 20)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
              ForEach(group.entries) { entry in
                MatterTextItem(
                  context: context, eventID: input.eventID, entry: entry, withDay: false,
                  highlighted: input.revealRow == entry.id, actions: !input.memberView
                )
                .id(entry.id)
              }
            }
          }
          .task(id: input.revealRow) {
            // After the page has restored its own scroll position.
            guard let row = input.revealRow else { return }
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(MLMotion.easeOut(MLMotion.durSlow)) {
              reader.scrollTo(row, anchor: .center)
            }
          }
        }
      }
    }
    .frame(maxWidth: 680, alignment: .leading)
    .padding(.top, 24)
  }

  private func days(_ entries: [MatterTextEntry]) -> [(day: Date, entries: [MatterTextEntry])] {
    let calendar = context.state.calendar
    var out: [(day: Date, entries: [MatterTextEntry])] = []
    for entry in entries {
      let day = calendar.startOfDay(for: entry.time)
      if out.last?.day == day {
        out[out.count - 1].entries.append(entry)
      } else {
        out.append((day, [entry]))
      }
    }
    return out
  }

  private func dayHeader(_ day: Date) -> String {
    let state = context.state
    return day == state.today ? "今天" : MindloomDates.dayTitle(day, calendar: state.calendar)
  }
}

/// One 原文 item (§4.10): source line with the hover 「⋯」, a mail's subject,
/// the lines with speaker prefixes and the quoted span marked, a two-line
/// clamp with 「展开」.
struct MatterTextItem: View {
  @Environment(\.colorScheme) private var scheme
  @Environment(\.zhijiSnapshot) private var snapshot
  let context: MindloomPageContext
  let eventID: String
  let entry: MatterTextEntry
  /// Search and the small page prefix the day (「今天 」, 「9月12日 」).
  let withDay: Bool
  let highlighted: Bool
  let actions: Bool
  @State private var hovering = false
  /// The real item menu is open (right-click or 「⋯」).
  @State private var menuShown = false

  private var menuOpen: Bool { context.state.matterExtras.stillMenuRow == entry.id || menuShown }

  /// The item's words as plain text (「复制」): one line per speaker line,
  /// with its speaker prefix.
  static func plainText(_ lines: [MemoryQuoteLine]) -> String {
    lines.map { ($0.speaker.isEmpty ? "" : $0.speaker + "：") + $0.words }.joined(separator: "\n")
  }
  private var expanded: Bool { context.navigation.expandedItems.contains(entry.id) }
  private var clamped: Bool {
    guard !expanded, !highlighted else { return false }
    // More than two lines as laid out at the column's width (680), or the
    // item goes on past what is shown.
    return entry.more || entry.lines.count > 2 || MatterTextItem.wraps(entry.lines, width: 680)
  }

  /// The lines take more than two lines at `width` (13/14 pt system font).
  static func wraps(_ lines: [MemoryQuoteLine], width: CGFloat) -> Bool {
    let font = MLTextStyle.cascadeNSFont(size: 14, weight: .regular)
    let text = lines.map { ($0.speaker.isEmpty ? "" : $0.speaker + "：") + $0.words }
      .joined(separator: "\n")
    let one = ("中" as NSString).boundingRect(
      with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin],
      attributes: [.font: font, .kern: MLTextStyle.noAutospaceKern]
    ).height
    let all = (text as NSString).boundingRect(
      with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin],
      attributes: [.font: font, .kern: MLTextStyle.noAutospaceKern]
    ).height
    return all > one * 2.5
  }

  private var sourceWords: String {
    let state = context.state
    var day = ""
    if withDay {
      day =
        state.calendar.startOfDay(for: entry.time) == state.today
        ? "今天 " : MindloomDates.monthDay(entry.time, calendar: state.calendar) + " "
    }
    let people = entry.people.isEmpty ? "" : " · " + entry.people.joined(separator: "、")
    return day + MindloomDates.clock(entry.time, calendar: state.calendar) + " · "
      + entry.source.line + people
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        MLSymbol(entry.source.symbol, size: 11, box: 13).frame(width: 14)
        Text(sourceWords).lineLimit(1)
        Spacer(minLength: 0)
        if actions { moreButton }
      }
      .mlFont(\.foot, lineBox: true)
      .monospacedDigit()
      .foregroundStyle(MLColor.ink2)
      .frame(height: 20)
      if let subject = entry.subject {
        Text(subject)
          .mlFont(\.body, weight: .medium, lineBox: true)
          .foregroundStyle(MLColor.ink)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 4)
      }
      words(entry.lines)
        .padding(.top, 4)
      if clamped {
        Button("展开") { context.navigator.toggleExpanded(entry.id) }
          .buttonStyle(.plain)
          .mlFont(\.sub, lineBox: true)
          .foregroundStyle(MLColor.accent)
          .padding(.top, 2)
      }
    }
    .padding(.top, 10)
    .padding(.horizontal, 12)
    .padding(.bottom, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(
          highlighted ? MLColor.accentTint : menuOpen ? MLColor.fill2 : MLColor.transparent)
    )
    .padding(.horizontal, -12)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .overlay {
      // Over the whole item, right-clicks only: the words below keep their
      // selection; the item menu replaces the system's text menu.
      if actions, !snapshot {
        MindloomRightClickMenu(
          sections: menuSections,
          copySelection: { [context] words in context.actions.matter.copyWords(words) }
        ) { menuShown = $0 }
      }
    }
    .overlay(alignment: .topTrailing) {
      if menuOpen && snapshot { MatterItemMenuStill().offset(x: -6, y: 36) }
    }
    .zIndex(menuOpen ? 1 : 0)
  }

  @ViewBuilder
  private func words(_ lines: [MemoryQuoteLine]) -> some View {
    if lines.contains(where: { $0.voice != nil }) {
      voiceLines(lines)
    } else {
      textLines(lines)
    }
  }

  /// A recording's sentences (v12, 理3-5): each speaker's name is a button
  /// that plays just that sentence; right-click it for 「不是{name}…」.
  @ViewBuilder
  private func voiceLines(_ lines: [MemoryQuoteLine]) -> some View {
    let shown = clamped ? Array(lines.prefix(2)) : lines
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
        HStack(alignment: .firstTextBaseline, spacing: 0) {
          if let voice = line.voice, !line.speaker.isEmpty {
            SpeakerNameButton(
              context: context, name: line.speaker, voice: voice, eventID: eventID,
              segID: entry.segID, actions: actions)
          } else if !line.speaker.isEmpty {
            Text(line.speaker + "：").foregroundStyle(MLColor.ink2)
          }
          markedQuote(line.words, quote: entry.quote, scheme: scheme)
            .foregroundStyle(MLColor.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(SelectableWords(enabled: !snapshot))
            .lineLimit(clamped ? 1 : nil)
        }
        .mlFont(\.body, lineBox: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func textLines(_ lines: [MemoryQuoteLine]) -> some View {
    let text = lines.enumerated().reduce(Text("")) { result, pair in
      let line = quoteLine(pair.element, quote: entry.quote, scheme: scheme)
      return pair.offset == 0 ? line : result + Text("\n") + line
    }
    let styled =
      text
      .mlFont(\.body, lineBox: true)
      .foregroundStyle(MLColor.ink)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      // Selectable everywhere (drag, double-click, ⌘C). Where the item has
      // a menu, a right-click is caught above the words and opens it instead
      // of the system's text menu (§7.5).
      .modifier(SelectableWords(enabled: !snapshot))
    if clamped {
      // Two lines; the second fades over its last 4 em (never 「…」).
      styled
        .frame(height: 44, alignment: .top)
        .clipped()
        .mask {
          VStack(spacing: 0) {
            Rectangle().frame(height: 22)
            LinearGradient(
              stops: [
                .init(color: .black, location: 0), .init(color: .black, location: 0.86),
                .init(color: .clear, location: 1),
              ],
              startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 22)
          }
        }
    } else {
      styled
    }
  }

  /// The item menu for the right-click (AppKit, §7.5).
  private var menuSections: [[MindloomMenuEntry]] {
    let context = context
    let eventID = eventID
    let entry = entry
    var sections = [
      [
        MindloomMenuEntry("拷贝", symbol: "doc.on.doc") {
          context.actions.matter.copyWords(Self.plainText(entry.lines))
        }
      ],
      [
        MindloomMenuEntry("移到其他事…", symbol: "arrow.up.right") {
          context.navigator.present(
            .move(.item(eventID: eventID, itemID: entry.itemID, segID: entry.segID)))
        },
        MindloomMenuEntry("不属于这件事", symbol: "xmark") {
          context.actions.correct(.takeOut(itemID: entry.itemID, segID: entry.segID, from: eventID))
        },
      ],
    ]
    let speakers = Self.voiceSpeakers(entry, eventID: eventID)
    if !speakers.isEmpty {
      sections.append(
        speakers.map { subject in
          MindloomMenuEntry("不是\(subject.name)…", symbol: "person.crop.circle.badge.xmark") {
            context.navigator.present(.notPerson(subject))
          }
        })
    }
    return sections
  }

  /// The voices of a recording's lines a 「不是…」 can be about (never 「我」),
  /// each once, with the first sentence of theirs ticked.
  static func voiceSpeakers(_ entry: MatterTextEntry, eventID: String) -> [NotPersonSubject] {
    var seen = Set<String>()
    return entry.lines.compactMap { line in
      guard let voice = line.voice, !line.speaker.isEmpty, line.speaker != "我",
        seen.insert(voice.personID.uppercased()).inserted
      else { return nil }
      return NotPersonSubject(
        eventID: eventID, itemID: voice.itemID, segID: entry.segID, personID: voice.personID,
        name: line.speaker, start: voice.start)
    }
  }

  @ViewBuilder
  private var menuItems: some View {
    Button {
      context.actions.matter.copyWords(Self.plainText(entry.lines))
    } label: {
      Label("拷贝", systemImage: "doc.on.doc")
    }
    Divider()
    Button {
      context.navigator.present(
        .move(.item(eventID: eventID, itemID: entry.itemID, segID: entry.segID)))
    } label: {
      Label("移到其他事…", systemImage: "arrow.up.right")
    }
    Button {
      context.actions.correct(.takeOut(itemID: entry.itemID, segID: entry.segID, from: eventID))
    } label: {
      Label("不属于这件事", systemImage: "xmark")
    }
    let speakers = Self.voiceSpeakers(entry, eventID: eventID)
    if !speakers.isEmpty {
      Divider()
      ForEach(speakers, id: \.personID) { subject in
        Button {
          context.navigator.present(.notPerson(subject))
        } label: {
          Label("不是\(subject.name)…", systemImage: "person.crop.circle.badge.xmark")
        }
      }
    }
  }

  /// 「⋯」: hidden until the item is hovered or its menu is open.
  @ViewBuilder
  private var moreButton: some View {
    let face = Image(systemName: "ellipsis")
      .font(.system(size: 13))
      .foregroundStyle(MLColor.ink2)
      .frame(width: 24, height: 20)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(menuOpen ? MLColor.fill3 : MLColor.transparent)
      )
      .contentShape(Rectangle())
    Group {
      if snapshot {
        face
      } else {
        Menu {
          menuItems
        } label: {
          face
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
      }
    }
    .opacity(hovering || menuOpen ? 1 : 0)
    .animation(MLMotion.easeOut(MLMotion.durFast), value: hovering)
    .accessibilityLabel("此条的更多操作")
  }
}

/// A still image of the item menu (§7.5) for snapshots: the real one is an
/// AppKit menu, which `ImageRenderer` does not draw.
struct MatterItemMenuStill: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      row("doc.on.doc", "拷贝")
      Rectangle().fill(MLColor.rule).frame(height: 0.5).padding(.horizontal, 10).padding(.vertical, 5)
      row("arrow.up.right", "移到其他事…")
      row("xmark", "不属于这件事")
    }
    .padding(6)
    .frame(width: 180, alignment: .leading)
    .mlGlass(.thick, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private func row(_ symbol: String, _ title: String) -> some View {
    HStack(spacing: 8) {
      MLSymbol(symbol, size: 12, box: 13).foregroundStyle(MLColor.ink2).frame(width: 14)
      Text(title).mlFont(\.control).foregroundStyle(MLColor.ink)
    }
    .padding(.horizontal, 10)
    .frame(height: 24)
  }
}

/// `.textSelection(.enabled)` when `enabled` (it takes no Bool).
private struct SelectableWords: ViewModifier {
  let enabled: Bool

  func body(content: Content) -> some View {
    if enabled { content.textSelection(.enabled) } else { content }
  }
}

/// A speaker's name before a recorded sentence (理3-5): 「何静：」 in
/// secondary, accent under the pointer; a click plays that sentence only.
/// Right-click: 播放这一句 · 不是{name}… (which sentences are not theirs).
struct SpeakerNameButton: View {
  let context: MindloomPageContext
  let name: String
  let voice: MemoryQuoteVoice
  let eventID: String
  let segID: String?
  /// The item has its menu (not a member's view): 「不是…」 is offered.
  let actions: Bool
  @State private var hovering = false

  var body: some View {
    Button {
      context.actions.playRange(voice.itemID, voice.start, voice.end)
    } label: {
      Text(name + "：")
        .foregroundStyle(hovering ? MLColor.accent : MLColor.ink2)
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help("播放此句")
    .accessibilityLabel("播放\(name)说的这句话")
    .contextMenu {
      Button {
        context.actions.playRange(voice.itemID, voice.start, voice.end)
      } label: {
        Label("播放此句", systemImage: "play")
      }
      if actions, name != "我" {
        Button {
          context.navigator.present(
            .notPerson(
              NotPersonSubject(
                eventID: eventID, itemID: voice.itemID, segID: segID, personID: voice.personID,
                name: name, start: voice.start)))
        } label: {
          Label("不是\(name)…", systemImage: "person.crop.circle.badge.xmark")
        }
      }
    }
  }
}
