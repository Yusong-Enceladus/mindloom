import BestASRDomain
import BestASRMemory
import Foundation

// OWNER: mac-home. State and actions only mac-home's pages need (Home, search, 置顶, 分组 pages, person page, the matter menu, group sheets).
// Add fields here (not to MemoryScreenState / MemoryActions) so the three
// v11 branches never edit the same lines; the App fills them in
// App/MindloomWiring+Home.swift.

/// Extra values for mac-home's pages (`MemoryScreenState.homeExtras`).
public struct MemoryHomeExtras {
  /// The Home row whose context menu is open (tinted). Still images only:
  /// the system menu tints nothing by itself.
  public var menuEventID: String?
  /// v12 (理1-4): records not organized yet, all of them (「刚收进来」 shows
  /// the newest few); 0 when there is nothing waiting or the DGX Spark is
  /// connected and organizing.
  public var waitingTotal: Int
  /// The person whose voice is playing (「听一段」).
  public var playingVoice: String?

  public init(menuEventID: String? = nil, waitingTotal: Int = 0, playingVoice: String? = nil) {
    self.menuEventID = menuEventID
    self.waitingTotal = waitingTotal
    self.playingVoice = playingVoice
  }
}

/// Extra actions for mac-home's pages (`MemoryActions.home`); every
/// default does nothing.
public struct MemoryHomeActions {
  /// 「听一段」: about three seconds of a person's own voice (v12, 理3-1).
  public var playVoice: @MainActor (_ personID: String) -> Void = { _ in }

  public init(playVoice: @escaping @MainActor (String) -> Void = { _ in }) {
    self.playVoice = playVoice
  }
}

extension MemoryWaitingCapture {
  /// A capture as 「刚收进来」 shows it (§4.1): the first line of its words
  /// (never a file name), the kind word (口述 · 微信 · 截图 · PDF ·
  /// 视频 · 42 分钟 · 录音 · 12 分钟 · 会议记录 · 会议录音 · 粘贴 · 文件) and its
  /// glyph. A meeting recorded from the microphone alone says so.
  public init(record: MemoryItemRecord) {
    let id = record.sessionID.rawValue.uuidString.uppercased()
    let source = MemoryItemSource.words(record)
    var kind = source.word
    var symbol = source.symbol
    var thumbnail: Thumbnail?
    let type = (record.uniformType ?? record.mediaType ?? "").lowercased()
    switch record.inputMode {
    case .roomMicrophone:
      kind = "会议录音 · " + MemoryItemSource.microphoneOnlyNote
      symbol = "person.3"
    case .systemAudio:
      kind = "会议录音"
      symbol = "person.3"
    case .importedMedia:
      let media = MemoryMediaKind.of(record)
      let minutes = Int(((Double(record.durationNanoseconds ?? 0) / 1e9) / 60).rounded())
      kind = minutes > 0 ? "\(media.word) · \(minutes) 分钟" : media.word
      symbol = media.symbol
      thumbnail = media == .video ? .video : nil
    case .dictation:
      kind = "口述"
      symbol = "mic"
    case .userItem:
      switch record.itemKind {
      case .image?:
        kind = "截图"
        symbol = "photo"
        thumbnail = .photo
      case .file?, .document?:
        if type.contains("pdf") {
          kind = "PDF"
          symbol = "doc"
          thumbnail = .pdf
        } else if source.word == "会议记录" {
          symbol = "person.3"
        } else if source.word != "文件" && source.symbol != "doc" {
          break
        } else {
          kind = "文件"
          symbol = "doc"
        }
      case .text?, nil:
        if source.word == "文字" || source.word == "未知来源" {
          kind = "粘贴"
          symbol = "clipboard"
        }
      }
    }
    if symbol == "bubble" { symbol = "bubble.left" }
    self.init(
      id: id, firstLine: Self.firstLine(record), kind: kind, symbol: symbol,
      capturedAt: record.startedAt, thumbnail: thumbnail,
      thumbnailPath: record.itemKind == .image ? record.thumbnailAssetPath : nil)
  }

  /// The first non-empty line of what was said or taken in (a screenshot's
  /// reading; for a file its text, never its name).
  static func firstLine(_ record: MemoryItemRecord) -> String {
    for text in [record.text, record.localReading] {
      guard let text, text != UserItemLimits.noTextLayerPlaceholder else { continue }
      if let line = firstLine(of: text) {
        return record.inputMode == .dictation ? MemoryQuoteLines.punctuated(line) : line
      }
    }
    return record.itemKind == .image ? "一张截图" : "一个文件"
  }

  /// The first line 「刚收进来」 shows of a text: a meeting App's transcript
  /// as people read it (its title, else 「名字：话」; never 「WEBVTT」, a cue
  /// number or a speaker's header line), else the first line of words.
  public static func firstLine(of text: String) -> String? {
    let readable = MemoryTranscriptText.readable(text) ?? text
    let line = MemoryQuoteLines.lines(readable).first.map {
      ($0.speaker.map { $0 + "：" } ?? "") + $0.words
    }
    guard let line, !line.isEmpty else { return nil }
    return line
  }

  /// 「刚收进来」 from what the organizer has not put anywhere: captures from
  /// yesterday and today, newest first, at most eight.
  public static func waiting(
    unfiled: [MemoryUnfiledItem], now: Date, calendar: Calendar, limit: Int = 8
  ) -> [MemoryWaitingCapture] {
    let since = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
    return unfiled.compactMap(\.item.record)
      .filter { $0.startedAt >= since && !$0.isKeyframe }
      .sorted { $0.startedAt > $1.startedAt }
      .prefix(limit)
      .map(MemoryWaitingCapture.init(record:))
  }
}

/// v12 (ALIGNMENT 理1-4): which records wait to be organized while the DGX
/// Spark is not organizing (link off, not connected, or never set up).
/// Nothing is organized on this Mac meanwhile; Home lists the newest few
/// under 「刚收进来」 and says how many there are.
public enum MemoryWaitingRecords {
  public struct Candidate: Equatable, Sendable {
    /// Upper-case item ID.
    public let id: String
    public let createdAt: Date
    /// Failed captures never wait (nothing to organize).
    public let failed: Bool

    public init(id: String, createdAt: Date, failed: Bool = false) {
      self.id = id.uppercased()
      self.createdAt = createdAt
      self.failed = failed
    }
  }

  /// Without the organizing device ever (no mirror of its work): the last
  /// 14 days, as the local unfiled list has always kept.
  public static let localWindowDays = 14

  /// Where waiting starts. With the organizing device's mirror: after its
  /// last pull this run, else after the newest record it knows, else since
  /// yesterday. Without one: `localWindowDays` back.
  public static func since(
    mirror: Bool, lastOrganizedAt: Date?, newestKnown: Date?, now: Date, calendar: Calendar
  ) -> Date {
    if !mirror {
      return calendar.date(byAdding: .day, value: -localWindowDays, to: now) ?? now
    }
    if let last = lastOrganizedAt ?? newestKnown { return last }
    return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
  }

  /// Records after `since` that nothing organized (`organized`: the
  /// organizer's records, or the local events' items), newest first; each
  /// once.
  public static func waiting(_ candidates: [Candidate], organized: Set<String>, since: Date)
    -> [Candidate]
  {
    var seen = Set<String>()
    return candidates.filter {
      !$0.failed && $0.createdAt > since && !organized.contains($0.id)
        && seen.insert($0.id).inserted
    }
    .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
  }
}
