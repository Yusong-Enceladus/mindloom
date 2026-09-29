import Foundation

/// Only these values may cross the explicitly enabled link to the user's Spark.
/// Audio, embeddings, dictionary entries, and window titles have no fields here.
public struct RemoteOrganizerItem: Codable, Equatable, Sendable {
  public struct SourceApp: Codable, Equatable, Sendable {
    public let bundleID: String?
    public let name: String

    public init(bundleID: String?, name: String) {
      self.bundleID = bundleID
      self.name = name
    }

    enum CodingKeys: String, CodingKey {
      case bundleID = "bundle_id"
      case name
    }
  }

  public struct Segment: Codable, Equatable, Sendable {
    public let startMS: Int64
    public let endMS: Int64
    public let personID: String?
    public let text: String

    public init(startMS: Int64, endMS: Int64, personID: String?, text: String) {
      self.startMS = startMS
      self.endMS = endMS
      self.personID = personID
      self.text = text
    }

    enum CodingKeys: String, CodingKey {
      case startMS = "start_ms"
      case endMS = "end_ms"
      case personID = "person_id"
      case text
    }
  }

  public struct Person: Codable, Equatable, Sendable {
    public let personID: String
    public let displayName: String?

    public init(personID: String, displayName: String?) {
      self.personID = personID
      self.displayName = displayName
    }

    enum CodingKeys: String, CodingKey {
      case personID = "person_id"
      case displayName = "display_name"
    }
  }

  public let itemID: UUID
  public let revision: Int64
  public let kind: String
  public let sourceApp: SourceApp
  public let startedAt: String
  public let endedAt: String?
  public let text: String?
  public let segments: [Segment]?
  public let persons: [Person]?
  public let imageBase64: String?
  /// Local only: which stored image the runtime reads into `imageBase64` at
  /// send time. It is never part of what is sent (`wireItem`).
  public let imageAsset: RemoteOrganizerImageAsset?
  public let sha256: String
  /// Kind `file` (and a file too large to send, sent as `text`): the file's
  /// name, type, media type and size. Kind `file` carries the bytes.
  public let filename: String?
  public let uniformType: String?
  public let mediaType: String?
  public let sizeBytes: Int64?
  public let fileBase64: String?
  /// Local only: the stored original read into `fileBase64` at send time.
  public let fileAsset: RemoteOrganizerImageAsset?
  /// What this Mac could read from the file natively; absent when nothing.
  public let localText: String?
  /// When the item was taken in (the same instant as `startedAt`).
  public let capturedAt: String?
  /// A video keyframe: the recording's item ID and where in it.
  public let parentItemID: String?
  public let frameMilliseconds: Int64?
  /// An animated image's further distinct frames (PNG/JPEG).
  public let extraImagesBase64: [String]?
  /// Local only: the stored frames read into `extraImagesBase64`.
  public let extraImageAssets: [RemoteOrganizerImageAsset]?

  public init(
    itemID: UUID, revision: Int64, kind: String, sourceApp: SourceApp,
    startedAt: String, endedAt: String? = nil, text: String? = nil,
    segments: [Segment]? = nil, persons: [Person]? = nil,
    imageBase64: String? = nil, imageAsset: RemoteOrganizerImageAsset? = nil,
    sha256: String, filename: String? = nil, uniformType: String? = nil,
    mediaType: String? = nil, sizeBytes: Int64? = nil, fileBase64: String? = nil,
    fileAsset: RemoteOrganizerImageAsset? = nil, localText: String? = nil,
    capturedAt: String? = nil, parentItemID: String? = nil, frameMilliseconds: Int64? = nil,
    extraImagesBase64: [String]? = nil, extraImageAssets: [RemoteOrganizerImageAsset]? = nil
  ) {
    self.itemID = itemID
    self.revision = revision
    self.kind = kind
    self.sourceApp = sourceApp
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.text = text
    self.segments = segments
    self.persons = persons
    self.imageBase64 = imageBase64
    self.imageAsset = imageAsset
    self.sha256 = sha256
    self.filename = filename
    self.uniformType = uniformType
    self.mediaType = mediaType
    self.sizeBytes = sizeBytes
    self.fileBase64 = fileBase64
    self.fileAsset = fileAsset
    self.localText = localText
    self.capturedAt = capturedAt
    self.parentItemID = parentItemID
    self.frameMilliseconds = frameMilliseconds
    self.extraImagesBase64 = extraImagesBase64
    self.extraImageAssets = extraImageAssets
  }

  /// A copy with another revision (everything else the same).
  public func withRevision(_ revision: Int64) -> RemoteOrganizerItem {
    replacing(revision: revision)
  }

  /// What may cross the link: every local file reference replaced by the
  /// bytes it names; nothing else is added.
  public func wireItem(
    imageBase64: String?, fileBase64: String? = nil, extraImagesBase64: [String]? = nil
  ) -> RemoteOrganizerItem {
    RemoteOrganizerItem(
      itemID: itemID, revision: revision, kind: kind, sourceApp: sourceApp,
      startedAt: startedAt, endedAt: endedAt, text: text, segments: segments,
      persons: persons, imageBase64: imageBase64 ?? self.imageBase64,
      imageAsset: nil, sha256: sha256, filename: filename, uniformType: uniformType,
      mediaType: mediaType, sizeBytes: sizeBytes, fileBase64: fileBase64 ?? self.fileBase64,
      fileAsset: nil, localText: localText, capturedAt: capturedAt,
      parentItemID: parentItemID, frameMilliseconds: frameMilliseconds,
      extraImagesBase64: extraImagesBase64 ?? self.extraImagesBase64, extraImageAssets: nil
    )
  }

  private func replacing(revision: Int64) -> RemoteOrganizerItem {
    RemoteOrganizerItem(
      itemID: itemID, revision: revision, kind: kind, sourceApp: sourceApp,
      startedAt: startedAt, endedAt: endedAt, text: text, segments: segments,
      persons: persons, imageBase64: imageBase64, imageAsset: imageAsset, sha256: sha256,
      filename: filename, uniformType: uniformType, mediaType: mediaType,
      sizeBytes: sizeBytes, fileBase64: fileBase64, fileAsset: fileAsset,
      localText: localText, capturedAt: capturedAt, parentItemID: parentItemID,
      frameMilliseconds: frameMilliseconds, extraImagesBase64: extraImagesBase64,
      extraImageAssets: extraImageAssets
    )
  }

  enum CodingKeys: String, CodingKey {
    case itemID = "item_id"
    case revision, kind
    case sourceApp = "source_app"
    case startedAt = "started_at"
    case endedAt = "ended_at"
    case text, segments, persons
    case imageBase64 = "image_b64"
    case imageAsset = "local_image_asset"
    case sha256
    case filename
    case uniformType = "uti"
    case mediaType = "mime"
    case sizeBytes = "size"
    case fileBase64 = "bytes_b64"
    case fileAsset = "local_file_asset"
    case localText = "local_text"
    case capturedAt = "captured_at"
    case parentItemID = "parent_item_id"
    case frameMilliseconds = "frame_ms"
    case extraImagesBase64 = "extra_images_b64"
    case extraImageAssets = "local_extra_image_assets"
  }
}

/// A normalized PNG/JPEG in the library's asset root, identified by digest.
/// Stays on the Mac; the runtime reads and re-verifies it at send time.
public struct RemoteOrganizerImageAsset: Codable, Equatable, Sendable {
  public let assetID: String
  /// Relative to the asset root (`sessions/<id>/source/...`).
  public let relativePath: String
  public let sha256: String
  public let sizeBytes: Int64
  public let mediaType: String

  public init(
    assetID: String, relativePath: String, sha256: String, sizeBytes: Int64,
    mediaType: String
  ) {
    self.assetID = assetID
    self.relativePath = relativePath
    self.sha256 = sha256
    self.sizeBytes = sizeBytes
    self.mediaType = mediaType
  }

  enum CodingKeys: String, CodingKey {
    case assetID = "asset_id"
    case relativePath = "relative_path"
    case sha256
    case sizeBytes = "size_bytes"
    case mediaType = "media_type"
  }
}

/// Reads a stored image for an item send. Implementations must stay inside
/// the provenance-checked asset root, refuse links, and verify size and digest.
public protocol RemoteOrganizerItemAssetReading: Sendable {
  func imageData(for asset: RemoteOrganizerImageAsset) throws -> Data
  /// A file item's original, at most `UserItemLimits.maximumSendableFileBytes`.
  func fileData(for asset: RemoteOrganizerImageAsset) throws -> Data
}

/// The stable ID is a delivery receipt key. Replays cannot apply a correction twice.
public struct RemoteOrganizerDecision: Codable, Equatable, Sendable {
  public let decisionID: UUID
  public let questionID: String?
  public let kind: String
  public let eventID: String?
  public let itemID: String?
  public let toEventID: String?
  public let title: String?
  public let a: String?
  public let b: String?
  public let answer: Bool?
  public let personID: String?
  public let displayName: String?
  public let pinned: Bool?
  /// `file_item_new_event` only: the client-generated ID (lower-case UUID)
  /// of the new event, so the local overlay and the Spark use the same ID.
  public let newEventID: String?
  /// `remove_item`, `move_item` and `unfile_item` only: the part of the item
  /// (`RemoteOrganizerEvent.Segment.segID`) the correction is about. Absent
  /// means the whole item, as before.
  public let segID: String?

  public init(
    decisionID: UUID = UUID(), kind: String, questionID: String? = nil,
    eventID: String? = nil,
    itemID: String? = nil, toEventID: String? = nil, title: String? = nil,
    a: String? = nil, b: String? = nil, answer: Bool? = nil,
    personID: String? = nil, displayName: String? = nil, pinned: Bool? = nil,
    newEventID: String? = nil, segID: String? = nil
  ) {
    self.decisionID = decisionID
    self.questionID = questionID
    self.kind = kind
    self.eventID = eventID
    self.itemID = itemID
    self.toEventID = toEventID
    self.title = title
    self.a = a
    self.b = b
    self.answer = answer
    self.personID = personID
    self.displayName = displayName
    self.pinned = pinned
    self.newEventID = newEventID
    self.segID = segID
  }

  public static let maximumTitleScalars = 80
  public static let maximumSegmentIDScalars = 64
  public static let maximumDisplayNameScalars = 128

  /// The same correction under a new receipt key, as a plain decision (never
  /// a question answer). Used when the user retries a correction the Spark did
  /// not take: the Spark keeps a receipt per decision ID, so only a new ID is
  /// evaluated again, and a new commit position keeps the local overlay order
  /// equal to the send order.
  public func reissued(as id: UUID = UUID()) -> RemoteOrganizerDecision {
    RemoteOrganizerDecision(
      decisionID: id, kind: kind, questionID: questionID, eventID: eventID,
      itemID: itemID, toEventID: toEventID, title: title, a: a, b: b,
      answer: answer, personID: personID, displayName: displayName, pinned: pinned,
      newEventID: newEventID, segID: segID
    )
  }

  /// Corrections about people use IDs that are the same in every Spark store
  /// (Mac person IDs, name-derived chat person IDs); every other kind refers
  /// to one store's events, items, or questions.
  public var isPersonScoped: Bool { kind == "name_person" || kind == "same_person" }

  /// Mirrors the v1 service limits so an invalid correction is refused before
  /// it is stored instead of being rejected later by the Spark.
  public var isWellFormed: Bool {
    func present(_ value: String?) -> Bool {
      guard let value else { return false }
      return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if let segID {
      guard ["remove_item", "move_item", "unfile_item"].contains(kind), present(segID),
        segID.unicodeScalars.count <= Self.maximumSegmentIDScalars
      else { return false }
    }
    switch kind {
    case "rename_event":
      guard present(eventID), let title else { return false }
      let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
      return !trimmed.isEmpty && title.unicodeScalars.count <= Self.maximumTitleScalars
    case "remove_item": return present(eventID) && present(itemID)
    case "move_item": return present(itemID) && present(toEventID)
    // Takes the item out of every event into Unfiled; never re-filed by itself.
    case "unfile_item": return present(itemID)
    // Files the item as a new event of its own (the ID is optional on the wire).
    case "file_item_new_event": return present(itemID)
    case "same_event", "same_person": return present(a) && present(b) && answer != nil
    case "name_person":
      guard present(personID), present(displayName), let displayName else { return false }
      return displayName.unicodeScalars.count <= Self.maximumDisplayNameScalars
    case "pin_event": return present(eventID) && pinned != nil
    case "feature_less", "delete_event": return present(eventID)
    default: return false
    }
  }

  enum CodingKeys: String, CodingKey {
    case decisionID = "decision_id"
    case questionID = "question_id"
    case kind
    case eventID = "event_id"
    case itemID = "item_id"
    case toEventID = "to_event_id"
    case title, a, b, answer
    case personID = "person_id"
    case displayName = "display_name"
    case pinned
    case newEventID = "new_event_id"
    case segID = "seg_id"
  }
}

public struct RemoteOrganizerFieldProvenance: Codable, Equatable, Sendable {
  public let source: String?
  public let skill: String?
  public let version: String?
  public let model: String?
  public let promptHash: String?
  public let runID: String?
  public let decisionID: Int64?

  enum CodingKeys: String, CodingKey {
    case source, skill, version, model
    case promptHash = "prompt_hash"
    case runID = "run_id"
    case decisionID = "decision_id"
  }
}

public struct RemoteOrganizerEvent: Codable, Equatable, Identifiable, Sendable {
  public struct StatusFact: Codable, Equatable, Sendable {
    public let text: String
    public let itemIDs: [String]
    /// `planned`, `in_progress`, `done`, `cancelled` or `info`; absent from
    /// older services.
    public let state: String?
    /// `YYYY-MM-DD` or empty.
    public let date: String?
    /// A short verbatim evidence clause for done, in-progress and cancelled facts.
    public let quote: String?

    public init(
      text: String, itemIDs: [String], state: String? = nil, date: String? = nil,
      quote: String? = nil
    ) {
      self.text = text
      self.itemIDs = itemIDs
      self.state = state
      self.date = date
      self.quote = quote
    }

    enum CodingKeys: String, CodingKey {
      case text
      case itemIDs = "item_ids"
      case state, date, quote
    }
  }

  /// One part of an item that covers several matters (a meeting transcript,
  /// a long note): `start`/`end` are character offsets (Unicode scalars) in
  /// the item's text as it was sent, turn-aligned for a transcript. An item
  /// with no segment in an event is in it whole.
  public struct Segment: Codable, Equatable, Sendable {
    public let itemID: String
    public let segID: String
    public let start: Int
    public let end: Int
    /// The organizer's short description of the part (not source text).
    public let gist: String

    public init(itemID: String, segID: String, start: Int, end: Int, gist: String) {
      self.itemID = itemID
      self.segID = segID
      self.start = start
      self.end = end
      self.gist = gist
    }

    enum CodingKeys: String, CodingKey {
      case itemID = "item_id"
      case segID = "seg_id"
      case start, end, gist
    }

    /// Longest gist kept; a longer one is cut.
    public static let maximumGistLength = 60
  }

  public let eventID: String
  public var title: String
  public let titleUserEdited: Bool
  public var statusLine: String
  public let statusFacts: [StatusFact]
  public var importance: Double
  public let startedAt: String?
  public let updatedAt: String?
  public var itemIDs: [String]
  public let personIDs: [String]
  public var pinned: Bool
  public var deleted: Bool
  public let provenance: [String: RemoteOrganizerFieldProvenance]
  /// A short `E<n>` ID, stable per Spark store; absent from older services.
  public let handle: String?
  /// The fixed object the event is about; absent from older services.
  public let anchor: String?
  /// The parts of items this event holds when an item covers several
  /// matters; absent from older services (every item is held whole).
  public var segments: [Segment]

  public var id: String { eventID }

  public init(
    eventID: String, title: String, titleUserEdited: Bool = false, statusLine: String = "",
    statusFacts: [StatusFact] = [], importance: Double = 0.5, startedAt: String? = nil,
    updatedAt: String? = nil, itemIDs: [String] = [], personIDs: [String] = [],
    pinned: Bool = false, deleted: Bool = false,
    provenance: [String: RemoteOrganizerFieldProvenance] = [:], handle: String? = nil,
    anchor: String? = nil, segments: [Segment] = []
  ) {
    self.eventID = eventID
    self.title = title
    self.titleUserEdited = titleUserEdited
    self.statusLine = statusLine
    self.statusFacts = statusFacts
    self.importance = importance
    self.startedAt = startedAt
    self.updatedAt = updatedAt
    self.itemIDs = itemIDs
    self.personIDs = personIDs
    self.pinned = pinned
    self.deleted = deleted
    self.provenance = provenance
    self.handle = handle
    self.anchor = anchor
    self.segments = segments
  }

  enum CodingKeys: String, CodingKey {
    case eventID = "event_id"
    case title
    case titleUserEdited = "title_user_edited"
    case statusLine = "status_line"
    case statusFacts = "status_facts"
    case importance
    case startedAt = "started_at"
    case updatedAt = "updated_at"
    case itemIDs = "item_ids"
    case personIDs = "person_ids"
    case pinned, deleted, provenance, handle, anchor, segments
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    eventID = try container.decode(String.self, forKey: .eventID)
    title = try container.decode(String.self, forKey: .title)
    titleUserEdited = try container.decode(Bool.self, forKey: .titleUserEdited)
    statusLine = try container.decode(String.self, forKey: .statusLine)
    statusFacts = try container.decode([StatusFact].self, forKey: .statusFacts)
    importance = try container.decode(Double.self, forKey: .importance)
    startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
    updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    itemIDs = try container.decode([String].self, forKey: .itemIDs)
    personIDs = try container.decode([String].self, forKey: .personIDs)
    pinned = try container.decode(Bool.self, forKey: .pinned)
    deleted = try container.decode(Bool.self, forKey: .deleted)
    provenance = try container.decode(
      [String: RemoteOrganizerFieldProvenance].self, forKey: .provenance)
    handle = try container.decodeIfPresent(String.self, forKey: .handle)
    anchor = try container.decodeIfPresent(String.self, forKey: .anchor)
    // Additive: a malformed field or entry is dropped, never the event.
    let entries =
      (try? container.decodeIfPresent([LenientSegment].self, forKey: .segments)) ?? nil
    segments = Self.validSegments(entries?.compactMap(\.value) ?? [], itemIDs: itemIDs)
  }

  /// Segments of items this event holds, with a non-empty range and ID,
  /// each (item, segment ID) once, the gist on one line and cut to length.
  static func validSegments(_ segments: [Segment], itemIDs: [String]) -> [Segment] {
    let held = Set(itemIDs.map { $0.uppercased() })
    var seen = Set<String>()
    return segments.compactMap { segment in
      let segID = segment.segID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard held.contains(segment.itemID.uppercased()), !segID.isEmpty,
        segID.unicodeScalars.count <= RemoteOrganizerDecision.maximumSegmentIDScalars,
        segment.start >= 0, segment.end > segment.start,
        seen.insert(segment.itemID.uppercased() + "#" + segID).inserted
      else { return nil }
      let gist = segment.gist.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        .joined(separator: " ")
      return Segment(
        itemID: segment.itemID, segID: segID, start: segment.start, end: segment.end,
        gist: String(gist.prefix(Segment.maximumGistLength)))
    }
  }

  private struct LenientSegment: Decodable {
    let value: Segment?
    init(from decoder: Decoder) throws { value = try? Segment(from: decoder) }
  }
}

/// An item the Spark keeps outside every event: it judged it not a matter
/// (`none`), the user removed it from its event (`removed_by_user`), or the
/// user unfiled it (`user`). `/v1/state` returns the complete set each pull.
public struct RemoteOrganizerUnfiledItem: Codable, Equatable, Sendable {
  public let itemID: String
  public let reason: String
  public let since: String?

  public init(itemID: String, reason: String, since: String? = nil) {
    self.itemID = itemID
    self.reason = reason
    self.since = since
  }

  enum CodingKeys: String, CodingKey {
    case itemID = "item_id"
    case reason, since
  }
}

public struct RemoteOrganizerQuestion: Codable, Equatable, Identifiable, Sendable {
  public let questionID: String
  public let kind: String
  public let a: String
  public let b: String
  public let promptZH: String
  public let createdAt: String

  public var id: String { questionID }

  enum CodingKeys: String, CodingKey {
    case questionID = "question_id"
    case kind, a, b
    case promptZH = "prompt_zh"
    case createdAt = "created_at"
  }
}

public struct RemoteOrganizerPerson: Codable, Equatable, Identifiable, Sendable {
  public let personID: String
  public var displayName: String?
  public let aliases: [String]
  public let origin: String?
  public var mergedInto: String?

  public var id: String { personID }

  enum CodingKeys: String, CodingKey {
    case personID = "person_id"
    case displayName = "display_name"
    case aliases, origin
    case mergedInto = "merged_into"
  }
}

/// The Spark's reading of one item it was sent (the text it read in a
/// screenshot), tied to the item revision it read. The Mac shows a reading
/// only while that revision is still the one it last delivered.
public struct RemoteOrganizerItemReading: Codable, Equatable, Sendable {
  /// Longest reading kept; a longer one is cut (the organizer caps a file's
  /// text near 60,000 characters).
  public static let maximumLength = 60_000
  /// Longest summary kept; a longer one is cut.
  public static let maximumSummaryLength = 500

  public let itemID: String
  public let revision: Int64
  /// What was read. From an organizer that sends `summary`, the
  /// transcription only; from an older one, its summary line and then the
  /// transcription.
  public let text: String
  /// The organizer's own one-line summary, which is not source text. Nil
  /// when the organizer does not send the field (older services: the summary
  /// is then the first line of `text`); `""` when it sent none.
  public let summary: String?
  /// A file's reading: what kind of file it read it as, its key fields,
  /// counts, the files inside it, and why it could not read it. Nil for a
  /// screenshot's reading and from older organizers.
  public let facts: RemoteOrganizerReadingFacts?

  public init(
    itemID: String, revision: Int64, text: String, summary: String? = nil,
    facts: RemoteOrganizerReadingFacts? = nil
  ) {
    self.itemID = itemID
    self.revision = revision
    self.text = text
    self.summary = summary
    self.facts = facts
  }

  enum CodingKeys: String, CodingKey {
    case itemID = "item_id"
    case revision, text, summary, facts
  }
}

/// The organizing device's reading of a file beyond its text (files
/// contract §5). Everything is optional and bounded; unknown values are kept
/// as sent but never interpreted as instructions.
public struct RemoteOrganizerReadingFacts: Codable, Equatable, Sendable {
  public struct Attachment: Codable, Equatable, Sendable {
    public let filename: String
    public let type: String?
    public let summary: String?

    public init(filename: String, type: String?, summary: String?) {
      self.filename = filename
      self.type = type
      self.summary = summary
    }
  }

  /// The reading types of the contract.
  public static let types: Set<String> = [
    "text", "document", "spreadsheet", "slides", "pdf", "scanned_pdf", "email", "calendar",
    "contact", "ebook", "archive", "web", "code", "data", "image",
  ]
  /// Why a file could not be read.
  public static let errors: Set<String> = ["encrypted", "unsupported", "too_large", "corrupt"]
  public static let maximumFields = 40
  public static let maximumAttachments = 200
  public static let maximumValueLength = 500

  /// One of `types`, else nil.
  public let type: String?
  /// Key fields (email: from/to/subject/date; calendar: title/start/…),
  /// in the order sent.
  public let fields: [Field]
  /// `pages`, `sheets`, `slides`, `attachments`, `images_read`, …
  public let counts: [String: Int]
  public let attachments: [Attachment]
  /// One of `errors`, else nil.
  public let error: String?
  /// `file-read` for a file's reading.
  public let source: String?

  public struct Field: Codable, Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
      self.name = name
      self.value = value
    }
  }

  public init(
    type: String?, fields: [Field] = [], counts: [String: Int] = [:],
    attachments: [Attachment] = [], error: String? = nil, source: String? = nil
  ) {
    self.type = type.flatMap { Self.types.contains($0) ? $0 : nil }
    self.fields = fields
    self.counts = counts
    self.attachments = attachments
    self.error = error.flatMap { Self.errors.contains($0) ? $0 : nil }
    self.source = source
  }

  /// Fields read in a familiar order (who, what, when, where), then by name.
  public static let preferredFields = [
    "from", "to", "cc", "subject", "date", "title", "summary", "start", "end", "location",
    "organizer", "attendees", "name", "organization", "org", "phone", "tel", "email",
    "address", "vendor", "merchant", "total", "amount", "currency", "author",
  ]

  public static func fieldOrder(_ name: String) -> String {
    let index = preferredFields.firstIndex(of: name.lowercased()) ?? preferredFields.count
    return String(format: "%03d", index) + name.lowercased()
  }

  public var isEmpty: Bool {
    type == nil && fields.isEmpty && counts.isEmpty && attachments.isEmpty && error == nil
  }
}

public struct RemoteOrganizerState: Codable, Equatable, Sendable {
  public let cursor: Int64
  public let events: [RemoteOrganizerEvent]
  public let questions: [RemoteOrganizerQuestion]
  public let persons: [RemoteOrganizerPerson]
  /// Identity of the organizer database that answered. It changes only when
  /// the Spark's store is recreated; older services omit it.
  public let storeID: String?
  /// The complete Unfiled set (not a delta). Older services omit it, which
  /// is read as empty.
  public let unfiled: [RemoteOrganizerUnfiledItem]?
  /// The Spark's readings of items, each with the revision it read. Additive:
  /// older services omit it, and a malformed field or entry is dropped
  /// rather than failing the pull. Merged into what the Mac holds (newest
  /// revision per item wins), whether the service sends all or only changes.
  public let readings: [RemoteOrganizerItemReading]?

  public init(
    cursor: Int64, events: [RemoteOrganizerEvent],
    questions: [RemoteOrganizerQuestion], persons: [RemoteOrganizerPerson],
    storeID: String? = nil, unfiled: [RemoteOrganizerUnfiledItem]? = nil,
    readings: [RemoteOrganizerItemReading]? = nil
  ) {
    self.cursor = cursor
    self.events = events
    self.questions = questions
    self.persons = persons
    self.storeID = storeID
    self.unfiled = unfiled
    self.readings = readings
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    cursor = try container.decode(Int64.self, forKey: .cursor)
    events = try container.decode([RemoteOrganizerEvent].self, forKey: .events)
    questions = try container.decode([RemoteOrganizerQuestion].self, forKey: .questions)
    persons = try container.decode([RemoteOrganizerPerson].self, forKey: .persons)
    storeID = try container.decodeIfPresent(String.self, forKey: .storeID)
    unfiled = try container.decodeIfPresent([RemoteOrganizerUnfiledItem].self, forKey: .unfiled)
    readings = Self.readings(in: container)
  }

  enum CodingKeys: String, CodingKey {
    case cursor, events, questions, persons, unfiled, readings
    case storeID = "store_id"
  }

  /// `readings` as either an object keyed by item ID or a list of entries
  /// carrying `item_id`; each entry needs an integer `revision` and a
  /// `text` (also read from `derived_text` or `reading`) or a `summary`,
  /// at least one of them not empty. Anything else is ignored.
  private static func readings(
    in container: KeyedDecodingContainer<CodingKeys>
  ) -> [RemoteOrganizerItemReading]? {
    guard container.contains(.readings) else { return nil }
    var entries: [(key: String?, entry: ReadingEntry)] = []
    if let map = try? container.decode([String: Lenient<ReadingEntry>].self, forKey: .readings) {
      entries = map.sorted { $0.key < $1.key }.compactMap { key, value in
        value.value.map { (key, $0) }
      }
    } else if let list = try? container.decode([Lenient<ReadingEntry>].self, forKey: .readings) {
      entries = list.compactMap { $0.value.map { (nil, $0) } }
    } else {
      return nil
    }
    return entries.compactMap { key, entry in
      guard
        let itemID = (entry.itemID ?? key)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !itemID.isEmpty, itemID.count <= 128,
        let revision = entry.revision, revision >= 0
      else { return nil }
      let text = entry.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      // One line: the summary is never read as a message or a header.
      let summary = entry.summary.map(Self.oneLine)
      let facts = entry.facts
      guard !text.isEmpty || !(summary ?? "").isEmpty || facts?.error != nil else { return nil }
      return RemoteOrganizerItemReading(
        itemID: itemID, revision: revision,
        text: String(text.prefix(RemoteOrganizerItemReading.maximumLength)),
        summary: summary.map { String($0.prefix(RemoteOrganizerItemReading.maximumSummaryLength)) },
        facts: facts)
    }
  }

  static func oneLine(_ value: String) -> String {
    value.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private struct ReadingEntry: Decodable {
    let itemID: String?
    let revision: Int64?
    let text: String?
    let summary: String?
    let facts: RemoteOrganizerReadingFacts?

    enum Keys: String, CodingKey {
      case itemID = "item_id"
      case revision, text, reading, summary
      case derivedText = "derived_text"
      case type, fields, counts, attachments, error, source
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: Keys.self)
      itemID = (try? container.decodeIfPresent(String.self, forKey: .itemID)) ?? nil
      revision = (try? container.decodeIfPresent(Int64.self, forKey: .revision)) ?? nil
      text =
        [Keys.text, .derivedText, .reading].lazy.compactMap {
          (try? container.decodeIfPresent(String.self, forKey: $0)) ?? nil
        }.first
      // Present (even null or empty) means the organizer sends it apart.
      summary =
        container.contains(.summary)
        ? ((try? container.decodeIfPresent(String.self, forKey: .summary)) ?? nil) ?? ""
        : nil
      facts = Self.facts(container)
    }

    /// A file reading's extra fields, each read on its own so one malformed
    /// field is dropped without losing the reading. Nil when none is usable.
    private static func facts(_ container: KeyedDecodingContainer<Keys>)
      -> RemoteOrganizerReadingFacts?
    {
      func clamp(_ value: String) -> String {
        String(oneLine(value).prefix(RemoteOrganizerReadingFacts.maximumValueLength))
      }
      let type = (try? container.decodeIfPresent(String.self, forKey: .type)) ?? nil
      var fields: [RemoteOrganizerReadingFacts.Field] = []
      if let object = try? container.decode([String: FieldValue].self, forKey: .fields) {
        for (name, value) in object.sorted(by: {
          RemoteOrganizerReadingFacts.fieldOrder($0.key) < RemoteOrganizerReadingFacts.fieldOrder($1.key)
        }) {
          guard let text = value.text, !text.isEmpty, !name.isEmpty else { continue }
          fields.append(.init(name: clamp(name), value: clamp(text)))
        }
      }
      var counts: [String: Int] = [:]
      if let object = try? container.decode([String: FieldValue].self, forKey: .counts) {
        for (name, value) in object {
          if let number = value.number, number >= 0, !name.isEmpty, name.count <= 40 {
            counts[name] = number
          }
        }
      }
      var attachments: [RemoteOrganizerReadingFacts.Attachment] = []
      if let list = try? container.decode([Lenient<AttachmentEntry>].self, forKey: .attachments) {
        for entry in list.compactMap(\.value)
        where attachments.count < RemoteOrganizerReadingFacts.maximumAttachments {
          guard let name = entry.filename.map(clamp), !name.isEmpty else { continue }
          attachments.append(
            .init(filename: name, type: entry.type.map(clamp), summary: entry.summary.map(clamp)))
        }
      }
      let error = (try? container.decodeIfPresent(String.self, forKey: .error)) ?? nil
      let source = (try? container.decodeIfPresent(String.self, forKey: .source)) ?? nil
      let facts = RemoteOrganizerReadingFacts(
        type: type, fields: Array(fields.prefix(RemoteOrganizerReadingFacts.maximumFields)),
        counts: counts, attachments: attachments, error: error, source: source.map(clamp))
      return facts.isEmpty ? nil : facts
    }
  }

  private struct AttachmentEntry: Decodable {
    let filename: String?
    let type: String?
    let summary: String?

    enum Keys: String, CodingKey { case filename, name, type, summary }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: Keys.self)
      filename =
        ((try? container.decodeIfPresent(String.self, forKey: .filename)) ?? nil)
        ?? ((try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil)
      type = (try? container.decodeIfPresent(String.self, forKey: .type)) ?? nil
      summary = (try? container.decodeIfPresent(String.self, forKey: .summary)) ?? nil
    }
  }

  /// A field value sent as a string, a number, or a list of strings.
  private struct FieldValue: Decodable {
    let text: String?
    let number: Int?

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let string = try? container.decode(String.self) {
        text = string
        number = Int(string)
      } else if let int = try? container.decode(Int.self) {
        text = String(int)
        number = int
      } else if let double = try? container.decode(Double.self) {
        text = String(double)
        number = double.isFinite ? Int(double) : nil
      } else if let list = try? container.decode([String].self) {
        text = list.joined(separator: ", ")
        number = nil
      } else if let bool = try? container.decode(Bool.self) {
        text = bool ? "是" : "否"
        number = nil
      } else {
        text = nil
        number = nil
      }
    }
  }

  /// One entry that may fail to decode without failing the rest.
  private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
      value = try? Value(from: decoder)
    }
  }
}

/// A user decision the Spark did not take, or that was never sent because the
/// link was turned off. It stays visible until the user retries or discards it.
public struct RemoteOrganizerDecisionIssue: Equatable, Identifiable, Sendable {
  public enum State: String, Sendable {
    /// The Spark refused it permanently (validation, unknown target, ...).
    case rejected
    /// Not delivered: the link was turned off first, it came from an archive
    /// import, or the Spark was reset (see `errorCategory`).
    case notSent
    /// It was in flight when the link was turned off, so the Spark may have
    /// applied it. Retrying resends it under the same ID, which the Spark
    /// answers from its receipt; it cannot be discarded until then.
    case deliveryUnknown
  }

  public let decisionID: UUID
  public let kind: String
  public let state: State
  public let errorCategory: String
  /// Short, content-free reason from the Spark (for example
  /// "unknown or deleted event"); never transcript text.
  public let reason: String?

  public var id: UUID { decisionID }

  public init(
    decisionID: UUID, kind: String, state: State, errorCategory: String,
    reason: String?
  ) {
    self.decisionID = decisionID
    self.kind = kind
    self.state = state
    self.errorCategory = errorCategory
    self.reason = reason
  }
}

public struct RemoteOrganizerProjection: Equatable, Sendable {
  public let cursor: Int64
  public let events: [RemoteOrganizerEvent]
  public let questions: [RemoteOrganizerQuestion]
  public let persons: [RemoteOrganizerPerson]
  public let unacceptedDecisions: [RemoteOrganizerDecisionIssue]
  /// Items in no event, with the user's decisions applied.
  public let unfiled: [RemoteOrganizerUnfiledItem]
  /// The Spark's readings keyed by upper-case item ID, only those made from
  /// the revision of the item the Mac last delivered.
  public let readings: [String: String]
  /// The summaries of those readings the Spark sent apart (`""` for none),
  /// same keys. A reading missing here came from an older Spark, whose
  /// summary is the reading's first line.
  public let readingSummaries: [String: String]
  /// A file reading's type, fields, counts, inner files and error, same keys.
  public let readingFacts: [String: RemoteOrganizerReadingFacts]

  public init(
    cursor: Int64, events: [RemoteOrganizerEvent],
    questions: [RemoteOrganizerQuestion], persons: [RemoteOrganizerPerson],
    unacceptedDecisions: [RemoteOrganizerDecisionIssue] = [],
    unfiled: [RemoteOrganizerUnfiledItem] = [], readings: [String: String] = [:],
    readingSummaries: [String: String] = [:],
    readingFacts: [String: RemoteOrganizerReadingFacts] = [:]
  ) {
    self.cursor = cursor
    self.events = events
    self.questions = questions
    self.persons = persons
    self.unacceptedDecisions = unacceptedDecisions
    self.unfiled = unfiled
    self.readings = readings
    self.readingSummaries = readingSummaries
    self.readingFacts = readingFacts
  }
}

/// Per-library link record. The link is enabled exactly when `enabledAt` is
/// set; only sessions whose capture started while it was set may be sent
/// automatically.
public struct RemoteOrganizerLinkRecord: Equatable, Sendable {
  public let enabledAt: Date?
  public let storeID: String?

  public init(enabledAt: Date?, storeID: String?) {
    self.enabledAt = enabledAt
    self.storeID = storeID
  }
}

/// One item send, built from the session's current committed content at claim
/// time. `revision` is monotonic per item; `contentSHA256` identifies the
/// content independent of the revision number.
public struct RemoteOrganizerItemDelivery: Sendable, Equatable {
  public let itemID: UUID
  public let revision: Int64
  public let payload: Data
  public let contentSHA256: String
  public let claimedChangeSequence: Int64
  public let retryCount: Int

  public init(
    itemID: UUID, revision: Int64, payload: Data, contentSHA256: String,
    claimedChangeSequence: Int64, retryCount: Int
  ) {
    self.itemID = itemID
    self.revision = revision
    self.payload = payload
    self.contentSHA256 = contentSHA256
    self.claimedChangeSequence = claimedChangeSequence
    self.retryCount = retryCount
  }
}

public enum RemoteOrganizerDecisionJobKind: String, Codable, Sendable {
  case decision
  case question
}

public struct RemoteOrganizerDecisionDelivery: Sendable, Equatable {
  public let decision: RemoteOrganizerDecision
  public let kind: RemoteOrganizerDecisionJobKind
  public let retryCount: Int

  public init(
    decision: RemoteOrganizerDecision, kind: RemoteOrganizerDecisionJobKind,
    retryCount: Int
  ) {
    self.decision = decision
    self.kind = kind
    self.retryCount = retryCount
  }
}

public protocol RemoteOrganizerRepository: Sendable {
  // Link lifecycle (stored with the library, not in app preferences).
  func remoteLinkRecord() async throws -> RemoteOrganizerLinkRecord
  /// Records the enable watermark. Only captures started from now on become
  /// eligible; nothing cancelled at a revoke is queued again.
  func enableRemoteLink(at date: Date) async throws
  /// Stops automatic sending and clears the pending outbox: removes the
  /// watermark, deletes never-delivered item jobs and their eligibility,
  /// cancels pending updates of delivered items (a later change after
  /// re-enabling sends the then-current content), and cancels pending
  /// decisions (an attempted one is marked delivery-unknown).
  func revokeRemoteLink() async throws

  // Items.
  /// Starts tracking a completed session whose capture started while the link
  /// was enabled (recorded as eligible at capture time, never inferred).
  func enqueueRemoteSession(sessionID: SessionID) async throws -> Bool
  /// Tracks completed eligible sessions that have no job yet (recovered or
  /// quit-interrupted sessions). Imported or link-off sessions never qualify.
  func reconcileRemoteItems() async throws -> Int
  func claimNextRemoteItem(now: Date) async throws -> RemoteOrganizerItemDelivery?
  func markRemoteItemDelivered(_ delivery: RemoteOrganizerItemDelivery) async throws
  func markRemoteItemFailed(
    _ delivery: RemoteOrganizerItemDelivery, category: String, retryAt: Date?
  ) async throws

  // Decisions, in local commit order.
  func enqueueRemoteDecision(_ decision: RemoteOrganizerDecision) async throws
  /// Adds jobs for stored decisions that have none (for example after an
  /// archive import). Returns how many were added; undecodable rows are
  /// quarantined as rejected instead of stopping recovery.
  func recoverRemoteDecisionsToOutbox() async throws -> Int
  /// Returns leased jobs left by a previous worker to the queue.
  func resetRemoteLeases() async throws
  func claimNextRemoteDecision(now: Date) async throws -> RemoteOrganizerDecisionDelivery?
  func markRemoteDecisionDelivered(id: UUID) async throws
  func markRemoteDecisionFailed(
    id: UUID, category: String, reason: String?, retryAt: Date?
  ) async throws
  /// A rejected or unsent decision is re-issued under a new ID at the end of
  /// the commit order; a delivery-unknown one is resent under its own ID.
  func retryRemoteDecision(id: UUID) async throws
  /// Only a decision the Spark certainly did not take can be discarded.
  func discardRemoteDecision(id: UUID) async throws

  // Projection of the Spark's derived state.
  func remoteCursor() async throws -> Int64
  /// Returns true when the store identity changed and local mirror state was
  /// reset (projection cleared, cursor 0, delivered items queued again).
  func observeRemoteStoreID(_ storeID: String) async throws -> Bool
  /// Returns true when the pulled state showed a reset; the caller pulls again
  /// from cursor 0.
  func applyRemoteState(_ state: RemoteOrganizerState) async throws -> Bool
  func remoteProjection() async throws -> RemoteOrganizerProjection
}
