import Foundation

/// What the user pasted or dragged into bestASR (PRD §0.3.2). Audio and video
/// files are not user items: they go through the media import pipeline and
/// become `importedMedia` sessions (a video's keyframes become image items
/// whose parent is that session).
public enum UserItemKind: String, Codable, CaseIterable, Hashable, Sendable {
  case text
  case image
  /// A file whose text this Mac read completely (plain text, RTF, HTML, a
  /// PDF with a text layer on every page); only that text is sent.
  case document
  /// Any other file: kept byte for byte, with whatever text this Mac could
  /// read natively (maybe none). The file itself (at most
  /// `UserItemLimits.maximumSendableFileBytes`) is what the organizing
  /// device reads.
  case file
}

/// The App an item came from, as the user would name it. Recorded at capture
/// time and changeable later (a change is a new item revision).
public struct ItemSourceApplication: Codable, Equatable, Hashable, Sendable {
  public let bundleID: String?
  public let name: String

  /// Nil when there is nothing to show (no name and no bundle ID).
  public init?(bundleID: String?, name: String?) {
    let bundle = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let normalizedBundle = (bundle?.isEmpty ?? true) ? nil : bundle
    let resolvedName =
      trimmed.isEmpty
      ? normalizedBundle.flatMap { $0.split(separator: ".").last.map(String.init) } ?? ""
      : trimmed
    guard !resolvedName.isEmpty else { return nil }
    self.bundleID = normalizedBundle
    self.name = resolvedName
  }
}

/// How the source label was decided, kept so a later reader knows whether it
/// was inferred or chosen by the user.
public enum ItemSourceOrigin: String, Codable, CaseIterable, Sendable {
  /// The App that was frontmost just before bestASR became active (paste).
  case previousFrontmost
  /// The frontmost App while bestASR was inactive during a drop.
  case dragSource
  /// Files dropped from Finder.
  case finder
  /// Set or changed by the user after capture.
  case user
  case unknown
}

public enum UserItemAttachmentRole: String, Codable, Sendable {
  /// The exact bytes the user provided, kept as provenance.
  case original
  /// A downscaled PNG/JPEG made from an image original; this is what may be
  /// sent to the user's own organizer device.
  case normalizedImage
  /// Further distinct frames of an animated image (GIF), normalized the
  /// same way and sent with the item as extra images.
  case animationFrame1
  case animationFrame2
  case animationFrame3

  /// The extra-frame roles in order.
  public static let animationFrames: [UserItemAttachmentRole] = [
    .animationFrame1, .animationFrame2, .animationFrame3,
  ]

  public var isNormalizedImage: Bool { self != .original }
}

/// A file already copied into the library's asset root, with its digest.
public struct UserItemAttachment: Equatable, Sendable {
  public let role: UserItemAttachmentRole
  /// Relative to the asset root, `sessions/<id>/source/...`.
  public let relativePath: String
  public let originalFilename: String
  public let mediaType: String
  public let digest: SHA256Digest
  public let sizeBytes: UInt64

  public init(
    role: UserItemAttachmentRole, relativePath: String, originalFilename: String,
    mediaType: String, digest: SHA256Digest, sizeBytes: UInt64
  ) {
    self.role = role
    self.relativePath = relativePath
    self.originalFilename = originalFilename
    self.mediaType = mediaType
    self.digest = digest
    self.sizeBytes = sizeBytes
  }
}

/// Text read on this Mac from an item whose source is not text (a
/// screenshot's on-device text recognition). Stored as a derived text
/// revision next to the source; it never replaces the item's own text.
public struct UserItemReading: Equatable, Sendable {
  public let text: String
  /// Names the local reader, e.g. `vision-text-v1`.
  public let reader: String

  public init(text: String, reader: String) {
    self.text = text
    self.reader = reader
  }
}

/// Everything needed to commit one captured item in one transaction.
public struct UserItemDraft: Equatable, Sendable {
  public let id: SessionID
  public let kind: UserItemKind
  public let capturedAt: Date
  public let source: ItemSourceApplication?
  public let sourceOrigin: ItemSourceOrigin
  /// Pasted text or text extracted on this Mac. Empty for an image.
  public let text: String
  /// Identifies how `text` was produced, e.g. `pasteboard-text-v1`, `pdfkit-v1`.
  public let extractor: String
  public let pageCount: Int?
  public let pixelWidth: Int?
  public let pixelHeight: Int?
  /// Name of the file the user provided; nil for pasted text or image data.
  public let originalFilename: String?
  public let attachments: [UserItemAttachment]
  /// A screenshot's on-device reading, if any.
  public let reading: UserItemReading?
  /// The file's Uniform Type Identifier (e.g. `org.openxmlformats.
  /// spreadsheetml.sheet`), for a file or document item.
  public let uniformType: String?
  /// A video keyframe: the recording (an `importedMedia` session) it was
  /// taken from, and where in it.
  public let parentSessionID: SessionID?
  public let frameMilliseconds: Int64?

  public init(
    id: SessionID = SessionID(), kind: UserItemKind, capturedAt: Date,
    source: ItemSourceApplication?, sourceOrigin: ItemSourceOrigin, text: String,
    extractor: String, pageCount: Int? = nil, pixelWidth: Int? = nil,
    pixelHeight: Int? = nil, originalFilename: String? = nil,
    attachments: [UserItemAttachment] = [], reading: UserItemReading? = nil,
    uniformType: String? = nil, parentSessionID: SessionID? = nil,
    frameMilliseconds: Int64? = nil
  ) {
    self.id = id
    self.kind = kind
    self.capturedAt = capturedAt
    self.source = source
    self.sourceOrigin = sourceOrigin
    self.text = text
    self.extractor = extractor
    self.pageCount = pageCount
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.originalFilename = originalFilename
    self.attachments = attachments
    self.reading = reading
    self.uniformType = uniformType
    self.parentSessionID = parentSessionID
    self.frameMilliseconds = frameMilliseconds
  }

  /// A PDF whose pages have no text layer (a scan): kept with empty text,
  /// titled by its filename, and never sent.
  public var isScanWithoutTextLayer: Bool {
    kind == .document && extractor == UserItemLimits.pdfExtractor && (pageCount ?? 0) > 0
      && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// First non-empty line (at most 40 characters), else the filename, else a
  /// kind label. Never derived from anything but the item itself.
  public var automaticTitle: String {
    UserItemTitle.automatic(kind: kind, text: text, filename: originalFilename)
  }
}

public enum UserItemTitle {
  public static let maximumCharacters = 40

  public static func automatic(kind: UserItemKind, text: String, filename: String?) -> String {
    // A file is named by its filename; its text is only what this Mac read.
    if kind != .image, kind != .file,
      let line = text.split(whereSeparator: \.isNewline)
        .lazy.map({ $0.trimmingCharacters(in: .whitespaces) })
        .first(where: { !$0.isEmpty })
    {
      return line.count > maximumCharacters
        ? String(line.prefix(maximumCharacters)) + "…" : line
    }
    if let filename = filename?.trimmingCharacters(in: .whitespacesAndNewlines),
      !filename.isEmpty
    {
      return filename.count > maximumCharacters
        ? String(filename.prefix(maximumCharacters)) + "…" : filename
    }
    return label(for: kind)
  }

  public static func label(for kind: UserItemKind) -> String {
    switch kind {
    case .text: "文字"
    case .image: "截图"
    case .document: "文档"
    case .file: "文件"
    }
  }
}

/// Bounds shared by intake, storage, and the organizer outbox.
public enum UserItemLimits {
  /// Originals above this are refused at intake (nothing is copied).
  public static let maximumOriginalBytes: UInt64 = 200 * 1_024 * 1_024
  /// Text above this is kept locally but never sent (the service limit).
  public static let maximumSendableTextScalars = 400_000
  /// The organizer's image limit; normalized images are made to fit it.
  public static let maximumSendableImageBytes = 12 * 1_024 * 1_024
  /// Long side of a normalized image.
  public static let normalizedImageLongSide = 2_560
  /// Text above this is refused at intake and at commit.
  public static let maximumStoredTextBytes = 16_000_000
  /// History list rows carry at most this many characters of an item's text.
  public static let historyPreviewCharacters = 20_000
  /// Shown (never stored) for a PDF with no text layer. Older rows stored it
  /// as the text; those are still recognized and never sent.
  public static let noTextLayerPlaceholder = "[无文字层]"
  /// The PDFKit extractor name; a scan from it may have empty text.
  public static let pdfExtractor = "pdfkit-v1"
  /// A file item's bytes are sent to the organizing device up to this size.
  /// A larger file goes as its text (when this Mac read any) with the file
  /// facts, else stays on this Mac with a visible reason.
  public static let maximumSendableFileBytes: Int64 = 25 * 1_024 * 1_024
  /// At most this many keyframes are taken from one video.
  public static let maximumVideoKeyframes = 12
  /// Keyframes are at least this far apart.
  public static let minimumKeyframeSpacingMilliseconds: Int64 = 2_000
  /// An animated image sends its first frame and up to this many more.
  public static let maximumExtraAnimationFrames = 3
  /// Extractor of a file item whose text this Mac could not read.
  public static let fileBytesExtractor = "file-bytes-v1"
  /// Extractor of a video keyframe image item.
  public static let videoKeyframeExtractor = "avfoundation-keyframe-v1"
}

/// Audio and video formats the media import can take (decoded on this Mac;
/// audio never leaves it). Video is read only where AVFoundation can.
public enum MediaImportFormats {
  public static let audioExtensions: Set<String> = [
    "wav", "m4a", "mp3", "aac", "flac", "ogg", "oga", "opus", "amr", "caf", "aif", "aiff",
  ]
  public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm"]
  public static var extensions: Set<String> { audioExtensions.union(videoExtensions) }

  public static func isVideo(_ ext: String) -> Bool { videoExtensions.contains(ext.lowercased()) }
}
