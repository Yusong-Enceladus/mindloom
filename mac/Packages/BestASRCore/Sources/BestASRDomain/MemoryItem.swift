import Foundation

/// One source record (a recording, an import, or a pasted/dragged item) as
/// the memory pages and the event export see it. Read-only and local: it is
/// joined from committed rows and never replaces them.
public struct MemoryItemRecord: Equatable, Identifiable, Sendable {
  public struct Segment: Equatable, Sendable {
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let personID: PersonID?
    public let personName: String?
    public let text: String
    /// The segment on the capture's monotonic clock, for playing just this
    /// part of the recording; nil when not known.
    public let monotonicStartNanoseconds: UInt64?
    public let monotonicEndNanoseconds: UInt64?

    public init(
      startMilliseconds: Int64, endMilliseconds: Int64, personID: PersonID?,
      personName: String?, text: String, monotonicStartNanoseconds: UInt64? = nil,
      monotonicEndNanoseconds: UInt64? = nil
    ) {
      self.startMilliseconds = startMilliseconds
      self.endMilliseconds = endMilliseconds
      self.personID = personID
      self.personName = personName
      self.text = text
      self.monotonicStartNanoseconds = monotonicStartNanoseconds
      self.monotonicEndNanoseconds = monotonicEndNanoseconds
    }
  }

  public struct Person: Equatable, Hashable, Sendable {
    public let id: PersonID
    public let name: String

    public init(id: PersonID, name: String) {
      self.id = id
      self.name = name
    }
  }

  /// A frame taken from a video recording, shown under it.
  public struct Keyframe: Equatable, Sendable {
    /// The keyframe's own item (an image item whose parent is the recording).
    public let sessionID: SessionID
    public let frameMilliseconds: Int64
    /// Relative to the asset root.
    public let thumbnailAssetPath: String?

    public init(sessionID: SessionID, frameMilliseconds: Int64, thumbnailAssetPath: String?) {
      self.sessionID = sessionID
      self.frameMilliseconds = frameMilliseconds
      self.thumbnailAssetPath = thumbnailAssetPath
    }
  }

  public let sessionID: SessionID
  public let inputMode: SessionInputMode
  /// Set only for `userItem`.
  public let itemKind: UserItemKind?
  public let title: String
  /// When the item was captured, or when the recording started.
  public let startedAt: Date
  public let updatedAt: Date
  public let sourceBundleID: String?
  public let sourceDisplayName: String?
  /// A filename for files; never sent anywhere.
  public let sourceIdentifier: String?
  /// Latest committed text: a user edit, else the final transcript or the
  /// pasted/extracted text. Nil while nothing is committed.
  public let text: String?
  public let segments: [Segment]
  public let people: [Person]
  public let durationNanoseconds: UInt64?
  /// True when retained source audio (or an imported original) can be played.
  public let playbackAvailable: Bool
  /// Relative to the asset root; the normalized image of an image item.
  public let thumbnailAssetPath: String?
  /// Relative to the asset root; the file the user provided.
  public let originalAssetPath: String?
  public let pageCount: Int?
  /// A screenshot's on-device text reading (a derived revision), if any.
  public let localReading: String?
  /// The user named this record; the export shows the title then.
  public let titleIsUserEdited: Bool
  /// A file or document item: its type, the original's media type and size.
  public var uniformType: String? = nil
  public var mediaType: String? = nil
  public var fileSizeBytes: Int64? = nil
  /// A video keyframe item: its recording and where in it.
  public var parentSessionID: SessionID? = nil
  public var frameMilliseconds: Int64? = nil
  /// Kept only on this Mac and never sent (audio or video, an archive, a
  /// binary the organizing device cannot read; privacy contract §5).
  public var keptOnMac = false
  /// A video recording: the keyframes taken from it, in time order.
  public var keyframes: [Keyframe] = []

  public var id: SessionID { sessionID }

  /// A keyframe of a recording (shown under that recording).
  public var isKeyframe: Bool { parentSessionID != nil }

  public init(
    sessionID: SessionID, inputMode: SessionInputMode, itemKind: UserItemKind?,
    title: String, startedAt: Date, updatedAt: Date, sourceBundleID: String?,
    sourceDisplayName: String?, sourceIdentifier: String?, text: String?,
    segments: [Segment] = [], people: [Person] = [],
    durationNanoseconds: UInt64? = nil, playbackAvailable: Bool = false,
    thumbnailAssetPath: String? = nil, originalAssetPath: String? = nil,
    pageCount: Int? = nil, localReading: String? = nil, titleIsUserEdited: Bool = false
  ) {
    self.sessionID = sessionID
    self.inputMode = inputMode
    self.itemKind = itemKind
    self.title = title
    self.startedAt = startedAt
    self.updatedAt = updatedAt
    self.sourceBundleID = sourceBundleID
    self.sourceDisplayName = sourceDisplayName
    self.sourceIdentifier = sourceIdentifier
    self.text = text
    self.segments = segments
    self.people = people
    self.durationNanoseconds = durationNanoseconds
    self.playbackAvailable = playbackAvailable
    self.thumbnailAssetPath = thumbnailAssetPath
    self.originalAssetPath = originalAssetPath
    self.pageCount = pageCount
    self.localReading = localReading
    self.titleIsUserEdited = titleIsUserEdited
  }

  /// The "来源" label: the App for dictation, online meetings, and items;
  /// otherwise the capture kind. A filename is never the label.
  public var sourceLabel: String {
    SourceLabel.label(
      inputMode: inputMode, bundleID: sourceBundleID, displayName: sourceDisplayName
    )
  }
}

public enum SourceLabel {
  /// Shared by the history chip, the event projection, and the export so the
  /// same record is named the same way everywhere.
  public static func label(
    inputMode: SessionInputMode, bundleID: String?, displayName: String?
  ) -> String {
    let appName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let bundle = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasBundle = !(bundle?.isEmpty ?? true)
    // Only these modes store an App in the display-name field. An import or a
    // room recording names an App only when intake recorded its bundle ID;
    // otherwise its display name is a filename or a device, never a label.
    let namesApp =
      hasBundle || inputMode == .dictation || inputMode == .systemAudio
      || inputMode == .userItem
    if namesApp, let appName, !appName.isEmpty,
      // Older dictation rows stored the bundle ID in the display-name field.
      appName != bundle
    {
      return appName
    }
    if namesApp, let bundle, let last = bundle.split(separator: ".").last, !last.isEmpty {
      return String(last)
    }
    return fallback(for: inputMode)
  }

  public static func fallback(for inputMode: SessionInputMode) -> String {
    switch inputMode {
    case .dictation: "口述"
    case .roomMicrophone: "线下录音"
    case .systemAudio: "电脑内录"
    case .importedMedia: "导入媒体"
    case .userItem: "未知来源"
    }
  }
}
