import AppKit
import BestASRDomain
import BestASRMemory
import SwiftUI

/// One original item in time order: source tile, "20:14 · 微信" meta, the
/// first line (or all of it when expanded), a play pill for audio and a
/// thumbnail for screenshots. Clicking (or Return) expands it in place; its
/// corrections are in the context menu and, for VoiceOver, named actions.
struct TimelineRow: View {
  @Environment(\.zhiji) private var palette
  let item: MemoryEventItem
  let state: MemoryScreenState
  let expanded: Bool
  var people: [MemoryPersonRef] = []
  /// The event the row is shown in; nil on the Unfiled page.
  let eventID: String?
  let actions: MemoryActions
  let toggle: () -> Void
  /// Opens another event (the other parts of a split record).
  var open: ((MemoryRoute) -> Void)? = nil
  @State private var picking = false

  var body: some View {
    let kind = ItemKind(item)
    HStack(alignment: .top, spacing: 12) {
      SourceTile(kind: kind)
      VStack(alignment: .leading, spacing: expanded ? 8 : 2) {
        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: expanded ? 8 : 2) {
            HStack(alignment: .center) {
              Text(meta(kind))
                .metaStyle(palette)
                .lineLimit(1)
              Spacer(minLength: 8)
              if item.playbackAvailable {
                PlayButton(playing: state.playingItemID == item.itemID) {
                  if state.playingItemID == item.itemID {
                    actions.stop()
                  } else {
                    actions.play(item.itemID)
                  }
                }
              }
            }
            .frame(minHeight: item.playbackAvailable ? 26 : 0)
            if case .file = kind {
              FilePreview(item: item, expanded: expanded)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
              TranscriptPreview(item: item, expanded: expanded, people: people)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let record = item.record, !record.keyframes.isEmpty {
              KeyframeStrip(keyframes: record.keyframes, expanded: expanded, state: state)
            }
            if !item.siblings.isEmpty {
              SiblingsLink(item: item, open: open)
            }
          }
          if !expanded, let image = thumbnail {
            thumb(image, width: 88, height: 60)
          }
        }
        if expanded, let image = thumbnail {
          thumb(image, width: 360, height: 240, fit: true)
        }
      }
    }
    .padding(expanded ? 10 : 0)
    .padding(.horizontal, expanded ? 0 : 10)
    .padding(.vertical, expanded ? 0 : 8)
    .background {
      if expanded {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(palette.isDark ? Color.white.opacity(0.05) : .hex(0xF7F7F9))
      }
    }
    .zhijiActivatable(toggle)
    .contextMenu {
      ItemMenu(
        itemID: item.itemID, segID: item.segment?.segID, eventID: eventID, state: state,
        actions: actions
      ) {
        picking = true
      }
    }
    .popover(isPresented: $picking, arrowEdge: .trailing) {
      EventPicker(entries: ItemMenu.targets(state, excluding: eventID)) { target in
        picking = false
        actions.moveItem(item.itemID, target, eventID, item.segment?.segID)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityText(kind))
    .accessibilityValue(expanded ? ZhijiCopy.expanded : ZhijiCopy.collapsed)
    .modifier(
      ItemAccessibilityActions(
        item: item, eventID: eventID, state: state, actions: actions, pick: { picking = true })
    )
    .accessibilityIdentifier("bestASR.memory.item")
  }

  private func accessibilityText(_ kind: ItemKind) -> String {
    if case .file = kind, let record = item.record {
      let reading = item.fileReading
      return [
        meta(kind), FilePreview.filename(item), MemoryFileText.facts(record, reading: reading),
        reading?.summary ?? FilePreview.note(item) ?? "",
      ].filter { !$0.isEmpty }.joined(separator: "，")
    }
    let text = TranscriptPreview.text(of: item)
    let summary = TranscriptPreview.readingSummary(of: item).map(ZhijiCopy.readingSummary)
    let siblings =
      item.siblings.isEmpty
      ? "" : ZhijiCopy.sameRecordAlso(SiblingsLink.recordWord(item), item.siblings.count)
    return [
      meta(kind), summary ?? "", text.isEmpty ? (item.record?.title ?? "") : text, siblings,
    ]
    .filter { !$0.isEmpty }.joined(separator: "，")
  }

  private var thumbnail: NSImage? {
    item.record?.itemKind == .image ? item.thumbnailAssetPath.flatMap(state.thumbnail) : nil
  }

  /// Collapsed: cropped from the top like the covers. Expanded: all of it.
  @ViewBuilder
  private func thumb(_ image: NSImage, width: CGFloat, height: CGFloat, fit: Bool = false)
    -> some View
  {
    Group {
      if fit {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: width, maxHeight: height)
      } else {
        ScreenshotCrop(image: image).frame(width: width, height: height)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.hairline))
  }

  private func meta(_ kind: ItemKind) -> String {
    var parts: [String] = []
    if let date = item.startedAt { parts.append(state.time(date)) }
    guard let record = item.record else { return parts.joined(separator: " · ") }
    let app = record.sourceLabel
    switch kind {
    case .dictation:
      parts.append(ZhijiCopy.dictationKind)
      if let name = record.sourceDisplayName, !name.isEmpty { parts.append(ZhijiCopy.inApp(app)) }
    case .inPerson:
      parts.append(ZhijiCopy.inPerson)
      if let duration = record.durationNanoseconds {
        parts.append(MemoryDateText.duration(nanoseconds: duration))
      }
    case .online:
      parts.append(app)
      if let duration = record.durationNanoseconds {
        parts.append(MemoryDateText.duration(nanoseconds: duration))
      }
    case .imported:
      parts.append(ZhijiCopy.importKind)
      if let duration = record.durationNanoseconds {
        parts.append(MemoryDateText.duration(nanoseconds: duration))
      }
    case .chat:
      parts.append(app)
    case .text:
      parts.append(ZhijiCopy.textKind)
      parts.append(ZhijiCopy.fromApp(app))
    case .image:
      parts.append(ZhijiCopy.imageKind)
      parts.append(ZhijiCopy.fromApp(app))
    case .document:
      parts.append(ZhijiCopy.documentKind)
      parts.append(ZhijiCopy.fromApp(app))
    case .file(let fileKind):
      parts.append(fileKind.label)
      parts.append(ZhijiCopy.fromApp(app))
    case .keyframe:
      parts.append(
        record.frameMilliseconds.map { ZhijiCopy.keyframeAt(MemoryDateText.clock($0)) }
          ?? ZhijiCopy.keyframeKind)
    case .transcript:
      parts.append(ZhijiCopy.transcriptKind)
      parts.append(ZhijiCopy.fromApp(app))
    case .missing:
      break
    }
    return parts.joined(separator: " · ")
  }
}

/// What kind of original an item is, for its tile and meta line.
enum ItemKind {
  case dictation
  case inPerson
  case online
  case imported
  case chat
  case text
  case image
  case document
  /// Any other file, by what it is (a table, an email, …).
  case file(MemoryFileKind)
  /// A frame taken from a video recording.
  case keyframe
  /// A pasted or dropped transcript exported by a meeting App.
  case transcript
  case missing

  /// The file's kind, for a file row.
  var fileKind: MemoryFileKind? {
    if case .file(let kind) = self { return kind }
    return nil
  }

  var isKeyframe: Bool {
    if case .keyframe = self { return true }
    return false
  }

  /// A row's kind: a file by the organizing device's reading type when it
  /// sent one, else by its extension.
  init(_ item: MemoryEventItem) {
    if let record = item.record, record.inputMode == .userItem, record.itemKind == .file {
      self = .file(
        MemoryFileKind(
          readingType: item.remoteReadingFacts?.type,
          filename: record.sourceIdentifier ?? record.title))
    } else {
      self.init(item.record)
    }
  }

  /// Chat Apps whose pasted text reads as a message.
  static let chatBundles: Set<String> = [
    "com.tencent.xinWeChat", "com.apple.MobileSMS", "com.tinyspeck.slackmacgap",
    "ru.keepcoder.Telegram", "net.whatsapp.WhatsApp", "com.bytedance.macos.feishu",
    "com.electron.lark", "com.alibaba.DingTalkMac", "com.tencent.qq",
  ]

  init(_ record: MemoryItemRecord?) {
    guard let record else {
      self = .missing
      return
    }
    switch record.inputMode {
    case .dictation: self = .dictation
    case .roomMicrophone: self = .inPerson
    case .systemAudio: self = .online
    case .importedMedia: self = .imported
    case .userItem:
      let transcript =
        (record.itemKind == .document || record.itemKind == .text)
        && MemoryTranscriptText.parse(record.text ?? "") != nil
      switch record.itemKind {
      case .image? where record.parentSessionID != nil: self = .keyframe
      case .image?: self = .image
      case .file?:
        self = .file(
          MemoryFileKind(readingType: nil, filename: record.sourceIdentifier ?? record.title))
      case _ where transcript: self = .transcript
      case .document?: self = .document
      default:
        self = Self.chatBundles.contains(record.sourceBundleID ?? "") ? .chat : .text
      }
    }
  }
}

/// A 30 pt tile with the kind of source.
struct SourceTile: View {
  @Environment(\.zhiji) private var palette
  let kind: ItemKind

  var body: some View {
    let (symbol, lightInk, fill) = look
    // Dark mode lightens the ink so the glyph keeps 3:1 on its own tint.
    let ink = palette.sourceInk(lightInk)
    Image(systemName: symbol)
      .font(.system(size: 13, weight: .regular))
      .foregroundStyle(ink)
      .frame(width: 30, height: 30)
      .background(
        palette.isDark ? ink.opacity(0.18) : fill,
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .accessibilityHidden(true)
  }

  private var look: (String, Color, Color) {
    switch kind {
    case .dictation: ("mic", .hex(0x3F6FB5), .hex(0xEEF1F7))
    case .inPerson: ("person.2", .hex(0xB5452F), .hex(0xFBEFE9))
    case .online: ("video", .hex(0x4F5E80), .hex(0xEEF0F5))
    case .imported: ("waveform", .hex(0x6E6E73), .hex(0xF2F2F4))
    case .chat: ("bubble.left", .hex(0x4F8A5B), .hex(0xEEF3EE))
    case .text: ("doc.text", .hex(0x6E6E73), .hex(0xF2F2F4))
    case .image: ("photo", .hex(0x8E4A8C), .hex(0xF4F0F6))
    case .document: ("doc.richtext", .hex(0x6E6E73), .hex(0xF2F2F4))
    case .file(let fileKind):
      switch fileKind {
      case .spreadsheet: (fileKind.symbol, .hex(0x2F7D4F), .hex(0xEAF4EE))
      case .slides: (fileKind.symbol, .hex(0xB3592B), .hex(0xFBEFE7))
      case .pdf, .scannedPDF: (fileKind.symbol, .hex(0xB23A3A), .hex(0xFAECEC))
      case .email: (fileKind.symbol, .hex(0x3F6FB5), .hex(0xEEF1F7))
      case .calendar: (fileKind.symbol, .hex(0xC0392B), .hex(0xFBEDEB))
      case .contact: (fileKind.symbol, .hex(0x4F8A5B), .hex(0xEEF3EE))
      case .archive: (fileKind.symbol, .hex(0x8A6D3B), .hex(0xF6F1E7))
      case .image, .video: (fileKind.symbol, .hex(0x8E4A8C), .hex(0xF4F0F6))
      default: (fileKind.symbol, .hex(0x6E6E73), .hex(0xF2F2F4))
      }
    case .keyframe: ("film", .hex(0x8E4A8C), .hex(0xF4F0F6))
    case .transcript: ("person.2.wave.2", .hex(0x4F5E80), .hex(0xEEF0F5))
    case .missing: ("questionmark", .hex(0xAEAEB2), .hex(0xF2F2F4))
    }
  }
}

/// The first line collapsed; everything expanded, a transcript with a
/// coloured tick and the name of each speaker.
struct TranscriptPreview: View {
  @Environment(\.zhiji) private var palette
  let item: MemoryEventItem
  let expanded: Bool
  /// The event's people, so a speaker's tick matches their avatar colour.
  var people: [MemoryPersonRef] = []

  /// Turns shown while collapsed; the rest is behind "…还有 N 句".
  static let collapsedTurns = 2

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // The device's own summary of a screenshot, apart from what it read;
      // only when the row is open.
      if expanded, let summary = Self.readingSummary(of: item) {
        Text(ZhijiCopy.readingSummary(summary))
          .font(.zhiji(12))
          .foregroundStyle(palette.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      content
    }
  }

  @ViewBuilder
  private var content: some View {
    let turns = self.turns
    if item.record == nil {
      Text(ZhijiCopy.removedItem)
        .font(.zhiji(13))
        .foregroundStyle(palette.secondary)
    } else if !turns.isEmpty {
      let shown = expanded ? turns : Array(turns.prefix(Self.collapsedTurns))
      VStack(alignment: .leading, spacing: expanded ? 6 : 3) {
        ForEach(Array(shown.enumerated()), id: \.offset) { _, turn in
          HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
              .fill(turn.colorIndex.map { palette.person($0) } ?? palette.tertiary)
              .frame(width: 3)
            (Text(turn.name).fontWeight(.semibold) + Text("　" + turn.text))
              .font(.zhiji(13))
              .lineSpacing(3)
              .lineLimit(expanded ? nil : 1)
              .fixedSize(horizontal: false, vertical: true)
          }
          // The tick is as tall as its text, not as the space offered.
          .fixedSize(horizontal: false, vertical: true)
        }
        if !expanded, turns.count > shown.count {
          Text(ZhijiCopy.moreTurns(turns.count - shown.count))
            .font(.zhiji(12))
            .foregroundStyle(palette.secondary)
            .padding(.leading, 13)
        }
      }
    } else {
      Text(expanded ? fullText : collapsedText)
        .font(.zhiji(13))
        .lineSpacing(3)
        .foregroundStyle(fullText.isEmpty ? palette.secondary : palette.label)
        .lineLimit(expanded ? nil : 2)
        .truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var fullText: String { Self.text(of: item) }

  /// The item's words: its text, else what a screenshot's reading read
  /// (without the organizing device's summary, and without a time stamp
  /// every message repeats).
  static func text(of item: MemoryEventItem) -> String {
    if let text = ownText(item) { return text }
    return item.reading?.body ?? ""
  }

  /// The organizing device's summary of a screenshot whose reading stands in
  /// for its text; nil otherwise.
  static func readingSummary(of item: MemoryEventItem) -> String? {
    guard item.record?.itemKind == .image, ownText(item) == nil else { return nil }
    return item.reading?.summary
  }

  /// The part this event holds when it holds one, else all of it.
  private static func ownText(_ item: MemoryEventItem) -> String? {
    let text = item.shownText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return text.isEmpty || text == UserItemLimits.noTextLayerPlaceholder ? nil : text
  }

  /// The text on as many lines as fit in two, cut with "…" when there is
  /// more (never silently after the second line).
  private var collapsedText: String {
    let text = fullText
    guard !text.isEmpty else { return item.record?.title ?? ZhijiCopy.noText }
    let flat = text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
      .joined(separator: " ")
    // Two lines never hold more than this; the rest need not be laid out.
    return flat.count > 240 ? String(flat.prefix(240)) + "…" : flat
  }

  struct Turn: Equatable {
    let name: String
    let colorIndex: Int?
    var text: String
    /// Who said it, when that is known: the recording's speaker, or the
    /// event's person a transcript or chat name is.
    var personID: String? = nil
    /// Where the turn starts in a recording.
    var offsetMilliseconds: Int64? = nil
  }

  /// A recording's speakers, else a meeting App's exported transcript, else
  /// a pasted chat or a screenshot's reading whose lines start with "名："
  /// (one such line is enough when the name is one of the event's people).
  var turns: [Turn] {
    let spoken = segmentTurns
    if !spoken.isEmpty { return spoken }
    let meeting = transcriptTurns
    return meeting.isEmpty ? chatTurns : meeting
  }

  /// A transcript text or file (腾讯会议, 飞书, Zoom, subtitles), or the part
  /// of one this event holds.
  private var transcriptTurns: [Turn] {
    guard let record = item.record, record.inputMode == .userItem,
      record.itemKind == .text || record.itemKind == .document,
      let transcript = MemoryTranscriptText.parse(Self.text(of: item))
    else { return [] }
    return transcript.turns.map { turn in
      let isOwner = MemoryProjection.ownerNames.contains(turn.speaker.lowercased())
      let color = isOwner ? nil : Self.person(named: turn.speaker, in: people)?.colorIndex
      let said = turn.text.split(whereSeparator: \.isNewline).joined(separator: " ")
      return Turn(
        name: turn.speaker, colorIndex: color, text: said,
        personID: Self.person(named: turn.speaker, in: people)?.personID)
    }
  }

  /// The event's named person a transcript speaker is: the same name, or
  /// the same first word ("王珂 Wang KE" is 王珂).
  static func person(named speaker: String, in people: [MemoryPersonRef]) -> MemoryPersonRef? {
    let named = people.filter(\.isNamed)
    if let exact = named.first(where: { $0.name == speaker }) { return exact }
    func head(_ value: String) -> Substring {
      value.split(whereSeparator: \.isWhitespace).first ?? Substring(value)
    }
    return named.first { head($0.name) == head(speaker) }
  }

  private var chatTurns: [Turn] {
    guard let record = item.record, record.inputMode == .userItem,
      record.itemKind == .text || record.itemKind == .image,
      let parsed = MemoryChatText.turns(
        in: Self.text(of: item),
        // The device's summary is already split off; one made on this Mac
        // may still open with one.
        leadingSummary: record.itemKind == .image && (item.remoteReading ?? "").isEmpty,
        knownNames: Set(people.filter(\.isNamed).map(\.name)))
    else { return [] }
    return parsed.map { turn in
      let isOwner = MemoryProjection.ownerNames.contains(turn.name.lowercased())
      let person = people.first { $0.isNamed && $0.name == turn.name }
      let color = isOwner ? nil : person?.colorIndex
      return Turn(name: turn.name, colorIndex: color, text: turn.text, personID: person?.personID)
    }
  }

  /// Consecutive segments of one person joined into one turn. A recording
  /// this event holds only part of shows that part's text instead.
  private var segmentTurns: [Turn] {
    guard item.segment == nil, let record = item.record,
      record.segments.contains(where: { $0.personID != nil })
    else { return [] }
    var result: [Turn] = []
    var lastKey: String?
    for segment in record.segments {
      let key = segment.personID?.rawValue.uuidString.uppercased()
      let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      if let lastKey, lastKey == key, !result.isEmpty {
        result[result.count - 1].text += trimmed
        continue
      }
      let name = key.flatMap { item.speakerNames[$0] } ?? MemoryProjection.unnamed
      let named = name != MemoryProjection.unnamed
      // The user's own turns take no person colour (a neutral tick).
      let isOwner = key.map { item.ownerSpeakers.contains($0) } ?? false
      let color =
        named && !isOwner
        ? (people.first { $0.name == name }?.colorIndex ?? key.map(MemoryPersonColor.index(for:)))
        : nil
      result.append(
        Turn(
          name: name, colorIndex: color, text: trimmed, personID: key,
          offsetMilliseconds: segment.startMilliseconds))
      lastKey = key
    }
    return result
  }
}

/// "同一段会议还涉及 N 件事 ›": the other events holding parts of the same
/// record. One opens directly; several open a menu of their titles.
struct SiblingsLink: View {
  @Environment(\.zhiji) private var palette
  @Environment(\.zhijiSnapshot) private var snapshot
  let item: MemoryEventItem
  let open: ((MemoryRoute) -> Void)?

  /// 会议 for a recording or an exported meeting transcript, 口述 for
  /// dictation, else 笔记.
  static func recordWord(_ item: MemoryEventItem) -> String {
    guard let record = item.record else { return ZhijiCopy.noteWord }
    switch record.inputMode {
    case .dictation: return ZhijiCopy.dictationKind
    case .roomMicrophone, .systemAudio, .importedMedia: return ZhijiCopy.meetingWord
    case .userItem:
      let text = record.text ?? ""
      return MemoryTranscriptText.parse(text) != nil ? ZhijiCopy.meetingWord : ZhijiCopy.noteWord
    }
  }

  var body: some View {
    let title = ZhijiCopy.sameRecordAlso(Self.recordWord(item), item.siblings.count)
    if snapshot || open == nil {
      label(title)
    } else if item.siblings.count == 1, let only = item.siblings.first {
      Button {
        open?(.event(only.eventID))
      } label: {
        label(title)
      }
      .buttonStyle(.plain)
      .help(only.title)
    } else {
      Menu {
        ForEach(item.siblings, id: \.eventID) { sibling in
          Button(sibling.gist.isEmpty ? sibling.title : "\(sibling.title) · \(sibling.gist)") {
            open?(.event(sibling.eventID))
          }
        }
      } label: {
        label(title)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
    }
  }

  private func label(_ title: String) -> some View {
    HStack(spacing: 3) {
      Text(title).font(.zhiji(12))
      Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
    }
    .foregroundStyle(palette.secondary)
    .padding(.top, 2)
    .contentShape(Rectangle())
    .accessibilityIdentifier("bestASR.memory.segmentSiblings")
  }
}

/// "▶ 播放" / "■ 停止".
struct PlayButton: View {
  @Environment(\.zhiji) private var palette
  let playing: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: playing ? "stop.fill" : "play.fill")
          .font(.system(size: 9))
        Text(playing ? ZhijiCopy.stop : ZhijiCopy.play)
          .font(.zhiji(12))
      }
      .foregroundStyle(palette.label)
      .padding(.horizontal, 10)
      .frame(height: 26)
      .background(palette.isDark ? palette.surface : .white, in: Capsule())
      .overlay(Capsule().strokeBorder(palette.separator.opacity(0.8)))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(playing ? ZhijiCopy.stop : ZhijiCopy.play)
  }
}

/// A yes/no question in the day of the item it is about.
struct InlineQuestion: View {
  @Environment(\.zhiji) private var palette
  let question: MemoryQuestion
  let answer: @MainActor (MemoryQuestion, Bool) -> Void

  var body: some View {
    HStack(spacing: 12) {
      Text(question.prompt)
        .font(.zhiji(13))
        .foregroundStyle(palette.label)
      Spacer(minLength: 8)
      YesNoButtons(height: 26, fontSize: 12) { answer(question, $0) }
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 12)
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(
        palette.separator.opacity(0.8))
    )
    .padding(.top, 8)
    .accessibilityIdentifier("bestASR.memory.inlineQuestion")
  }
}

/// A file item: its name and facts, the organizing device's summary, and,
/// when open, the key fields, what was read (cut at eight lines until the
/// user asks for all of it) and the files inside it.
struct FilePreview: View {
  @Environment(\.zhiji) private var palette
  let item: MemoryEventItem
  let expanded: Bool
  @State private var fullText = false

  /// Lines of what was read shown before "展开全文".
  static let collapsedLines = 8

  var body: some View {
    let reading = item.fileReading
    VStack(alignment: .leading, spacing: expanded ? 8 : 3) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(Self.filename(item))
          .font(.zhiji(13, .semibold))
          .foregroundStyle(palette.label)
          .lineLimit(1)
          .truncationMode(.middle)
        if let record = item.record {
          Text(MemoryFileText.facts(record, reading: reading, includeKind: false))
            .font(.zhiji(12))
            .foregroundStyle(palette.secondary)
            .lineLimit(1)
        }
      }
      if let summary = reading?.summary {
        Text(summary)
          .font(.zhiji(13))
          .lineSpacing(3)
          .foregroundStyle(palette.label)
          .lineLimit(expanded ? nil : 2)
          .fixedSize(horizontal: false, vertical: true)
      } else if let note = expanded ? Self.status(item) : Self.note(item) {
        Text(note)
          .font(.zhiji(12))
          .foregroundStyle(palette.secondary)
          .lineLimit(expanded ? nil : 2)
      }
      if expanded {
        if let fields = reading?.facts?.fields, !fields.isEmpty {
          VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
              HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(MemoryFileText.fieldName(field.name))
                  .font(.zhiji(12))
                  .foregroundStyle(palette.secondary)
                  .frame(width: 56, alignment: .leading)
                Text(field.value)
                  .font(.zhiji(12.5))
                  .foregroundStyle(palette.label)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        }
        let text = Self.readText(item)
        if !text.isEmpty {
          let long = Self.lineCount(text) > Self.collapsedLines
          VStack(alignment: .leading, spacing: 6) {
            ReadingBody(text: text, full: fullText || !long, lines: Self.collapsedLines)
            if long {
              Button(fullText ? ZhijiCopy.hideFullText : ZhijiCopy.showFullText) {
                fullText.toggle()
              }
              .buttonStyle(.plain)
              .font(.zhiji(12))
              .foregroundStyle(palette.secondary)
            }
          }
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(palette.isDark ? Color.white.opacity(0.04) : .white))
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.hairline))
        }
        if let inside = reading?.facts?.attachments, !inside.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            Text(
              reading?.facts?.type == "email"
                ? ZhijiCopy.attachmentsCount(inside.count) : ZhijiCopy.filesInside(inside.count))
              .font(.zhiji(12))
              .foregroundStyle(palette.secondary)
            ForEach(Array(inside.prefix(12).enumerated()), id: \.offset) { _, attachment in
              HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: MemoryFileKind(
                  readingType: attachment.type, filename: attachment.filename
                ).symbol)
                .font(.system(size: 10))
                .foregroundStyle(palette.secondary)
                Text(attachment.filename)
                  .font(.zhiji(12.5))
                  .foregroundStyle(palette.label)
                  .lineLimit(1)
                  .truncationMode(.middle)
                if let summary = attachment.summary, !summary.isEmpty {
                  Text(summary)
                    .font(.zhiji(12))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
                }
              }
            }
          }
        }
      }
    }
  }

  static func filename(_ item: MemoryEventItem) -> String {
    let name = item.record?.sourceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (name?.isEmpty == false ? name : nil) ?? item.record?.title ?? ZhijiCopy.noText
  }

  /// What was read: the organizing device's reading, else the text read on
  /// this Mac.
  static func readText(_ item: MemoryEventItem) -> String {
    let remote = item.fileReading?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !remote.isEmpty { return remote }
    return item.record?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  /// Without a summary: why it was not read, why it stays here, or the
  /// first line of the text read on this Mac, else that it waits.
  static func note(_ item: MemoryEventItem) -> String? {
    guard let record = item.record else { return nil }
    if let error = item.fileReading?.facts?.error { return MemoryFileText.error(error) }
    if let reason = MemoryFileText.notSentReason(record) { return reason }
    let text = readText(item)
    if !text.isEmpty {
      return text.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        .prefix(2).joined(separator: " ")
    }
    return ZhijiCopy.fileNotReadYet
  }

  /// Open, the text is shown in full below: only why it was not read.
  static func status(_ item: MemoryEventItem) -> String? {
    guard let record = item.record else { return nil }
    if let error = item.fileReading?.facts?.error { return MemoryFileText.error(error) }
    if let reason = MemoryFileText.notSentReason(record) { return reason }
    return readText(item).isEmpty ? ZhijiCopy.fileNotReadYet : nil
  }

  static func lineCount(_ text: String) -> Int {
    text.split(separator: "\n", omittingEmptySubsequences: false).count
  }
}

/// What was read: headings, Markdown tables drawn as tables (a sheet), and
/// plain lines. Closed, it keeps the first `lines` lines of the source.
struct ReadingBody: View {
  @Environment(\.zhiji) private var palette
  let text: String
  let full: Bool
  let lines: Int

  var body: some View {
    let shown = full ? text : Self.head(text, lines: lines)
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(blocks(shown).enumerated()), id: \.offset) { _, block in
        switch block {
        case .heading(let title):
          Text(title)
            .font(.zhiji(12, .semibold))
            .foregroundStyle(palette.secondary)
        case .table(let header, let rows):
          table(header: header, rows: rows)
        case .text(let paragraph):
          Text(paragraph)
            .font(.zhiji(12.5))
            .lineSpacing(3)
            .foregroundStyle(palette.label)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
      if !full, shown.count < text.count {
        Text("…").font(.zhiji(12)).foregroundStyle(palette.secondary)
      }
    }
  }

  /// Cut short, a table whose rows were all cut (and the heading before
  /// it) is left out rather than shown as a bare header.
  private func blocks(_ shown: String) -> [MemoryReadingBlocks.Block] {
    var blocks = MemoryReadingBlocks.parse(shown)
    guard !full else { return blocks }
    if case .table(_, let rows)? = blocks.last, rows.isEmpty {
      blocks.removeLast()
      if case .heading? = blocks.last { blocks.removeLast() }
    }
    return blocks
  }

  private func table(header: [String], rows: [[String]]) -> some View {
    let columns = max(header.count, rows.map(\.count).max() ?? 0)
    return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
      GridRow {
        ForEach(0..<columns, id: \.self) { index in
          Text(index < header.count ? header[index] : "")
            .font(.zhiji(12, .semibold))
            .foregroundStyle(palette.secondary)
        }
      }
      Divider().gridCellUnsizedAxes(.horizontal)
      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        GridRow {
          ForEach(0..<columns, id: \.self) { index in
            Text(index < row.count ? row[index] : "")
              .font(.zhiji(12.5).monospacedDigit())
              .foregroundStyle(palette.label)
              .lineLimit(2)
          }
        }
      }
    }
    .textSelection(.enabled)
  }

  static func head(_ text: String, lines: Int) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).prefix(lines)
      .joined(separator: "\n")
  }
}

/// The frames taken from a video, in time order, each with its position.
struct KeyframeStrip: View {
  @Environment(\.zhiji) private var palette
  let keyframes: [MemoryItemRecord.Keyframe]
  let expanded: Bool
  let state: MemoryScreenState

  var body: some View {
    let shown = expanded ? keyframes : Array(keyframes.prefix(6))
    let size = expanded ? CGSize(width: 132, height: 76) : CGSize(width: 72, height: 42)
    VStack(alignment: .leading, spacing: 4) {
      Text(ZhijiCopy.videoFrames(keyframes.count))
        .font(.zhiji(11))
        .foregroundStyle(palette.secondary)
      // Wraps onto more rows when open, one row when closed.
      FlowRows(spacing: 6) {
        ForEach(shown, id: \.sessionID) { frame in
          VStack(alignment: .leading, spacing: 2) {
            Group {
              if let image = frame.thumbnailAssetPath.flatMap(state.thumbnail) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
              } else {
                Rectangle().fill(palette.hairline)
              }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(palette.hairline))
            if expanded {
              Text(MemoryDateText.clock(frame.frameMilliseconds))
                .font(.zhiji(11).monospacedDigit())
                .foregroundStyle(palette.secondary)
            }
          }
        }
      }
    }
    .padding(.top, 2)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(ZhijiCopy.videoFrames(keyframes.count))
  }
}

/// Lays its children out left to right, wrapping to a new row when full.
struct FlowRows: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var row: CGFloat = 0
    var widest: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        y += row + spacing
        x = 0
        row = 0
      }
      x += size.width + spacing
      row = max(row, size.height)
      widest = max(widest, x - spacing)
    }
    return CGSize(width: widest, height: y + row)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var x = bounds.minX
    var y = bounds.minY
    var row: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX {
        y += row + spacing
        x = bounds.minX
        row = 0
      }
      subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      row = max(row, size.height)
    }
  }
}
