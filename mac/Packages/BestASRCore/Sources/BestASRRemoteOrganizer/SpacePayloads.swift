import BestASRDomain
import CryptoKit
import Foundation
import MindloomSpaces

/// The organizing payload of one shared item (SPACES-CONTRACT §0 rule 1):
/// the v6 item format, every text field masked with the **space's** mask
/// key (never the personal library's), a screenshot only as its redacted
/// copy. Members read the item's own fields, numbers as they are; the
/// Spark sees placeholders only.
public struct SpaceOrganizerPayloads: SpacePayloadBuilding {
  private let imageRedactor: (any RemoteOrganizerImageRedacting)?

  public init(imageRedactor: (any RemoteOrganizerImageRedacting)? = nil) {
    self.imageRedactor = imageRedactor
  }

  public func payload(
    item: SpaceSharedItem, fields: SpaceItemFields, maskKey: Data,
    original: @escaping @Sendable (SpaceBlobRef) async throws -> Data?
  ) async throws -> Data? {
    let masking = RemoteOrganizerWireMasking(masker: try PrivacyMasker(maskKey: maskKey))
    var base = Self.organizerItem(item, fields)
    var image: String?
    if base.kind == "image" {
      if let redactor = imageRedactor,
        let blob = item.blobs.first(where: { $0.role == "image" || $0.role == "original" }),
        let bytes = try await original(blob)
      {
        let mediaType = fields.mediaType ?? Self.sniffImage(bytes)
        let copy = try redactor.redactedSendCopy(of: bytes, mediaType: mediaType)
        image = copy.base64EncodedString()
        base = base.withWireText(
          text: base.text, segments: base.segments, persons: base.persons,
          sourceName: base.sourceApp.name, filename: base.filename, localText: base.localText,
          sha256: Self.hex(SHA256.hash(data: copy)))
      } else {
        // No redacted copy can be made here: the picture stays with the
        // members and the organizer reads the text the contributor's Mac read.
        base = Self.organizerItem(item, fields, forceText: true)
      }
    }
    let (masked, _) = masking.mask(base, sha256: image == nil ? nil : base.sha256)
    let wire = masked.wireItem(imageBase64: image)
    var json = try SpaceJSON.decode(JSONEncoder().encode(wire))
    if let matter = fields.originMatterID, !matter.isEmpty, matter.count <= 64 {
      json = json.setting("origin_matter_id", .string(matter))
    }
    return try json.encoded()
  }

  /// The text the organizer reads for an item (the same choice when the
  /// placeholders are put back).
  public static func organizerText(_ fields: SpaceItemFields) -> String {
    let text = fields.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !text.isEmpty { return fields.text ?? "" }
    if let reading = fields.reading, !reading.isEmpty { return reading }
    return fields.title ?? ""
  }

  /// The v6 item for a shared item's fields (not yet masked). People are
  /// names: a person id is made from the name, never a voice cluster id.
  public static func organizerItem(
    _ item: SpaceSharedItem, _ fields: SpaceItemFields, forceText: Bool = false
  ) -> RemoteOrganizerItem {
    let kind: String
    switch item.kind {
    case "dictation", "meeting_online", "meeting_offline", "imported_media", "text", "document":
      kind = item.kind
    case "image":
      kind = forceText ? "text" : "image"
    case "audio_segment":
      let parent = fields.parentKind ?? "meeting_offline"
      kind =
        ["meeting_online", "meeting_offline", "imported_media"].contains(parent)
        ? parent : "meeting_offline"
    default:
      // A link, a snapshot, a file: its text (file bytes stay with members).
      kind = "text"
    }
    var personIDs: [String: String] = [:]
    for name in fields.persons ?? [] where !name.isEmpty { personIDs[name] = "n-\(name)" }
    for segment in fields.segments ?? [] {
      if let speaker = segment.speaker, !speaker.isEmpty { personIDs[speaker] = "n-\(speaker)" }
    }
    let persons = personIDs.keys.sorted().map {
      RemoteOrganizerItem.Person(personID: personIDs[$0]!, displayName: $0)
    }
    let segments = (fields.segments ?? []).map {
      RemoteOrganizerItem.Segment(
        startMS: $0.startMS, endMS: $0.endMS, personID: $0.speaker.flatMap { personIDs[$0] },
        text: $0.text)
    }
    let started = fields.startedAt ?? SpaceTime.string(item.firstSharedAt)
    let text = organizerText(fields)
    return RemoteOrganizerItem(
      itemID: UUID(uuidString: item.itemID) ?? UUID(), revision: Int64(item.revision), kind: kind,
      sourceApp: .init(
        bundleID: fields.sourceBundleID, name: fields.sourceName ?? SpaceCopy.sharedSource),
      startedAt: started, endedAt: fields.endedAt, text: text,
      segments: segments.isEmpty ? nil : segments, persons: persons.isEmpty ? nil : persons,
      sha256: hex(SHA256.hash(data: Data(text.utf8))),
      filename: kind == "text" ? nil : fields.filename)
  }

  static func sniffImage(_ data: Data) -> String {
    data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
  }

  static func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}

/// Plain words the space code shows.
public enum SpaceCopy {
  public static let sharedSource = "共享空间"
}

/// Turning this Mac's items into what a space receives (SPACES-CONTRACT
/// §2): whole items, or for a recording only the parts filed into the
/// matter (each at most 15 minutes), with their review-list lines. The
/// content comes from the same read the organizing link uses, which never
/// reads a capture asset, the dictionary, a speaker embedding or a window
/// title — so none of those can be in a space either.
public enum SpaceShareContent {
  public static let recordingKinds: Set<String> = [
    "meeting_online", "meeting_offline", "imported_media",
  ]

  /// One line of the review list and the item it would send.
  public struct Entry: Sendable {
    public let candidate: SpaceShareCandidate
    public let item: SpaceOutgoingItem
  }

  /// A part of a recording, as character offsets in its text (how the
  /// organizer files parts of an item into matters).
  public struct Part: Sendable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
      self.start = start
      self.end = end
    }
  }

  /// The entries for one local item: a whole item, or the given parts of a
  /// recording (all of it, cut at 15 minutes, when no part is given).
  /// `title` is the user's own title, if they named the item; otherwise one
  /// is made from its first words (a stored title may be a window title,
  /// which never leaves the Mac).
  public static func entries(
    for item: RemoteOrganizerItem, title userTitle: String?, matterID: String?,
    parts: [Part] = [], reading: String? = nil, originals: [(role: String, data: Data)] = []
  ) -> [Entry] {
    let itemID = item.itemID.uuidString.lowercased()
    let title = userTitle.flatMap { $0.isEmpty ? nil : $0 } ?? defaultTitle(item, reading: reading)
    guard recordingKinds.contains(item.kind) else {
      var fields = baseFields(item, title: title, matterID: matterID)
      fields.reading = reading
      if item.kind == "file" || item.kind == "document" {
        fields.filename = item.filename
        fields.mediaType = item.mediaType
        fields.sizeBytes = item.sizeBytes
        if fields.text == nil { fields.text = item.localText }
      }
      let texts = [fields.text, fields.reading, fields.title, fields.filename].compactMap { $0 }
      let candidate = SpaceShareCandidate(
        id: itemID, sourceItemID: itemID, kind: .item, wireKind: item.kind, title: title,
        preview: preview(fields.text ?? fields.reading ?? title), startedAt: date(item.startedAt),
        isPrivateDictation: item.kind == "dictation", numberLabels: numberLabels(texts),
        hasOriginal: !originals.isEmpty)
      return [
        Entry(
          candidate: candidate,
          item: SpaceOutgoingItem(
            itemID: itemID, kind: item.kind, fields: fields, originals: originals))
      ]
    }
    // A recording: only parts, never the whole recording. A part is named by
    // the user's title of its recording, else by its own first words — never
    // by words of the recording outside the part — and carries its own time.
    let lines = item.segments ?? []
    let ranges = msRanges(item: item, parts: parts)
    let named = userTitle.flatMap { $0.isEmpty ? nil : $0 }
    let recordingStart = date(item.startedAt)
    let zone = timeZone(of: item.startedAt)
    return ranges.compactMap { range -> Entry? in
      let inside = lines.filter { $0.endMS > Int64(range.start) && $0.startMS < Int64(range.end) }
      guard !inside.isEmpty || lines.isEmpty else { return nil }
      let names = Dictionary(
        (item.persons ?? []).map { ($0.personID, $0.displayName ?? "") }
      ) { first, _ in first }
      let segments = inside.map {
        SpaceItemFields.Segment(
          startMS: $0.startMS - Int64(range.start), endMS: $0.endMS - Int64(range.start),
          speaker: $0.personID.flatMap { names[$0] }.flatMap { $0.isEmpty ? nil : $0 },
          text: $0.text)
      }
      let text: String
      if lines.isEmpty {
        // A whole-text edit has no timed lines: only the filed characters.
        let whole = item.text ?? ""
        text =
          parts.isEmpty
          ? whole : parts.compactMap { slice(whole, $0) }.joined(separator: "\n")
      } else {
        text = inside.map(\.text).joined(separator: "\n")
      }
      let partID = SpaceID.segment(parent: itemID, startMS: range.start, endMS: range.end)
      let partTitle = named ?? firstWords(text) ?? kindTitle(item.kind)
      var fields = baseFields(item, title: partTitle, matterID: matterID)
      fields.kind = "audio_segment"
      fields.text = text
      fields.segments = segments.isEmpty ? nil : segments
      fields.persons = Array(Set(segments.compactMap(\.speaker))).sorted()
      fields.parentKind = item.kind
      fields.parentTitle = named ?? kindTitle(item.kind)
      fields.title = "\(partTitle)（\(clock(range.start))–\(clock(range.end))）"
      var partStart = recordingStart
      if let recordingStart, !lines.isEmpty {
        let start = recordingStart.addingTimeInterval(Double(range.start) / 1000)
        partStart = start
        fields.startedAt = SpaceTime.string(start, timeZone: zone)
        fields.endedAt = SpaceTime.string(
          recordingStart.addingTimeInterval(Double(range.end) / 1000), timeZone: zone)
      }
      // The recording's length on the same clock (its last line's end): a
      // part of at most 4/5 of it may carry its audio for members (v8 C1,
      // review V8R-15).
      let recordingMS = lines.map { Int($0.endMS) }.max()
      let audioPossible =
        recordingMS.map {
          SpaceAudioCheck.isPart(lengthMS: range.end - range.start, recordingMS: $0)
            && range.end <= $0
        } ?? false
      let candidate = SpaceShareCandidate(
        id: partID, sourceItemID: itemID,
        kind: .segment(parentItemID: itemID, startMS: range.start, endMS: range.end),
        wireKind: "audio_segment", title: fields.title ?? partTitle, preview: preview(text),
        startedAt: partStart, isPrivateDictation: false,
        numberLabels: numberLabels([text]), hasOriginal: false, audioPossible: audioPossible)
      return Entry(
        candidate: candidate,
        item: SpaceOutgoingItem(
          itemID: partID, kind: "audio_segment", fields: fields,
          segment: SpaceSegmentRef(
            parentItemID: itemID, startMS: range.start, endMS: range.end,
            recordingMS: recordingMS)))
    }
  }

  /// The parts' time ranges: each part's lines, merged and cut at 15 minutes.
  static func msRanges(item: RemoteOrganizerItem, parts: [Part]) -> [(start: Int, end: Int)] {
    let lines = item.segments ?? []
    let limit = SpaceEngine.maximumSegmentMS
    guard let last = lines.map(\.endMS).max() else {
      return [(0, min(limit, 60_000))]
    }
    var ranges: [(Int, Int)] = []
    if parts.isEmpty {
      ranges = [(Int(lines.map(\.startMS).min() ?? 0), Int(last))]
    } else {
      let offsets = lineOffsets(text: item.text ?? "", lines: lines)
      for part in parts {
        let covered = zip(lines, offsets).filter { line, span in
          span.end > part.start && span.start < part.end
        }.map(\.0)
        guard let start = covered.map(\.startMS).min(), let end = covered.map(\.endMS).max() else {
          continue
        }
        ranges.append((Int(start), Int(end)))
      }
    }
    // Anything longer than 15 minutes is offered as 15-minute windows to
    // choose from; the review list lets the user tick one per recording, the
    // engine and the Spark refuse more than 15 minutes of one recording.
    var out: [(start: Int, end: Int)] = []
    for (start, end) in ranges.sorted(by: { $0.0 < $1.0 }) where end > start {
      var cursor = start
      while cursor < end {
        let next = min(end, cursor + limit)
        out.append((cursor, next))
        cursor = next
      }
    }
    return out
  }

  /// Where each transcript line sits in the item's text (Unicode scalars),
  /// found in order; a line not found takes the next position.
  static func lineOffsets(text: String, lines: [RemoteOrganizerItem.Segment]) -> [(
    start: Int, end: Int
  )] {
    let scalars = Array(text.unicodeScalars)
    var cursor = 0
    return lines.map { line in
      let needle = Array(line.text.unicodeScalars)
      guard !needle.isEmpty, needle.count <= scalars.count else { return (cursor, cursor) }
      var index = cursor
      while index + needle.count <= scalars.count {
        if Array(scalars[index..<(index + needle.count)]) == needle {
          cursor = index + needle.count
          return (index, cursor)
        }
        index += 1
      }
      return (cursor, cursor)
    }
  }

  static func baseFields(_ item: RemoteOrganizerItem, title: String, matterID: String?)
    -> SpaceItemFields
  {
    SpaceItemFields(
      kind: item.kind, title: title, text: item.text, sourceName: item.sourceApp.name,
      sourceBundleID: item.sourceApp.bundleID, startedAt: item.startedAt, endedAt: item.endedAt,
      persons: (item.persons ?? []).compactMap(\.displayName).filter { !$0.isEmpty },
      originMatterID: matterID)
  }

  /// What the masking rules find in these texts, as their labels.
  public static func numberLabels(_ texts: [String]) -> [String] {
    var labels: [String] = []
    for text in texts {
      for span in PrivacyMasker.detectionOnly.maskWithSpans(text).spans
      where !labels.contains(span.label) {
        labels.append(span.label)
      }
    }
    return labels
  }

  /// The first words of an item, or what kind of item it is.
  static func defaultTitle(_ item: RemoteOrganizerItem, reading: String?) -> String {
    if let words = firstWords(item.text ?? item.localText ?? reading ?? "") { return words }
    if let name = item.filename, !name.isEmpty { return name }
    return kindTitle(item.kind)
  }

  /// The first non-empty line of a text, at most 24 characters.
  static func firstWords(_ text: String) -> String? {
    let line =
      text.split(whereSeparator: \.isNewline).lazy
      .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    guard !line.isEmpty else { return nil }
    return line.count > 24 ? String(line.prefix(24)) + "…" : line
  }

  static func kindTitle(_ kind: String) -> String {
    switch kind {
    case "dictation": return "口述"
    case "image": return "截图"
    case "meeting_offline": return "线下录音"
    case "meeting_online": return "电脑内录"
    case "imported_media": return "导入媒体"
    default: return "素材"
    }
  }

  /// Characters `part.start..<part.end` (Unicode scalars) of a text.
  static func slice(_ text: String, _ part: Part) -> String? {
    let scalars = Array(text.unicodeScalars)
    let start = max(0, min(part.start, scalars.count))
    let end = max(start, min(part.end, scalars.count))
    guard end > start else { return nil }
    var out = String.UnicodeScalarView()
    out.append(contentsOf: scalars[start..<end])
    return String(out)
  }

  /// The UTC offset an item's time was written with (`+08:00`, `Z`).
  static func timeZone(of value: String) -> TimeZone {
    if value.hasSuffix("Z") { return TimeZone(secondsFromGMT: 0) ?? .current }
    let tail = Array(value.suffix(6))
    guard tail.count == 6, tail[0] == "+" || tail[0] == "-", tail[3] == ":",
      let hours = Int(String(tail[1...2])), let minutes = Int(String(tail[4...5]))
    else { return .current }
    let seconds = (hours * 3_600 + minutes * 60) * (tail[0] == "-" ? -1 : 1)
    return TimeZone(secondsFromGMT: seconds) ?? .current
  }

  static func preview(_ text: String) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ")
    return flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
  }

  static func clock(_ ms: Int) -> String {
    let seconds = ms / 1000
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  static func date(_ value: String) -> Date? { SpaceTime.date(value) }
}
