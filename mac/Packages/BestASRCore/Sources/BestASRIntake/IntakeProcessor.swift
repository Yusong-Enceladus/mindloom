import AVFoundation
import AppKit
import BestASRDomain
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What one candidate became.
public enum IntakeOutcome: Equatable, Sendable {
  /// Files are staged; commit the rows, then `IntakeAssetStore.commit`.
  case item(UserItemDraft)
  /// Audio or video: goes to the existing import pipeline.
  case media(URL)
  /// Not taken; the message says why. Nothing was copied or changed.
  case rejected(String)
}

/// Which files intake must never take in. The App protects the owner's real
/// library and the active data root: a file copied out of either would get a
/// fresh digest, pass the data-root provenance guard, and could be sent.
public struct IntakePathPolicy: Sendable {
  public let isProtected: @Sendable (URL) -> Bool

  public init(isProtected: @escaping @Sendable (URL) -> Bool) {
    self.isProtected = isProtected
  }

  /// Protects nothing; for tests that do not exercise the policy.
  public static let none = IntakePathPolicy { _ in false }
}

/// Turns candidates into drafts: classifies, extracts text locally, normalizes
/// images, and stages files. Runs off the main actor; it only reads the
/// user's files and never opens a network location.
public struct IntakeProcessor: Sendable {
  public static let protectedFileMessage = "这是织机资料库里的文件，未收进来"
  public static let tooMuchTextMessage = "文字超过 16 MB，未收进来"

  public let assetStore: IntakeAssetStore
  public let normalizer: ImageNormalizer
  public let pathPolicy: IntakePathPolicy
  public let imageReader: (any ImageTextReading)?

  public init(
    assetStore: IntakeAssetStore, normalizer: ImageNormalizer = ImageNormalizer(),
    pathPolicy: IntakePathPolicy, imageReader: (any ImageTextReading)? = nil
  ) {
    self.assetStore = assetStore
    self.normalizer = normalizer
    self.pathPolicy = pathPolicy
    self.imageReader = imageReader
  }

  /// Text above the stored-text limit is refused before anything is copied.
  public static func exceedsTextLimit(_ text: String) -> Bool {
    text.utf8.count > UserItemLimits.maximumStoredTextBytes
  }

  public func prepare(
    _ candidate: IntakeCandidate, id: SessionID = SessionID(), capturedAt: Date,
    source: ItemSourceApplication?, origin: ItemSourceOrigin
  ) -> IntakeOutcome {
    let context = Context(id: id, capturedAt: capturedAt, source: source, origin: origin)
    do {
      switch candidate {
      case .text(let text, let extractor):
        guard !Self.exceedsTextLimit(text) else { return .rejected(Self.tooMuchTextMessage) }
        let cleaned = IntakeTextExtractor.sanitized(text)
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          return .rejected("没有可收进来的文字")
        }
        return context.item(kind: .text, text: cleaned, extractor: extractor)
      case .imageData(let data, let typeIdentifier):
        let ext = Self.imageExtension(typeIdentifier: typeIdentifier)
        return try image(
          original: .data(data), normalized: normalizer.normalize(data),
          originalFilename: "pasted.\(ext)", ext: ext, userFilename: nil, context: context
        )
      case .pdfData(let data):
        let extracted = try IntakeTextExtractor.pdfText(data: data)
        guard !Self.exceedsTextLimit(extracted.text) else {
          return .rejected(Self.tooMuchTextMessage)
        }
        // Scanned pages go as the file itself for the organizing device.
        if extracted.hasPagesWithoutText {
          return try fileItem(
            original: .data(data), filename: "pasted.pdf", uniformType: UTType.pdf.identifier,
            mediaType: "application/pdf", localText: extracted, context: context)
        }
        return try document(
          extracted, original: .data(data), originalFilename: "pasted.pdf", ext: "pdf",
          userFilename: nil, context: context
        )
      case .file(let url):
        return try file(url, context: context)
      }
    } catch IntakeAssetStore.StoreError.tooLarge {
      assetStore.discard(sessionID: id)
      return .rejected("文件超过 200 MB，未收进来")
    } catch IntakeTextExtractor.ExtractionError.empty {
      assetStore.discard(sessionID: id)
      return .rejected("没有可读的文字，未收进来")
    } catch IntakeTextExtractor.ExtractionError.tooLong {
      assetStore.discard(sessionID: id)
      return .rejected(Self.tooMuchTextMessage)
    } catch IntakeTextExtractor.ExtractionError.unreadable where Self.isPDF(candidate) {
      // A PDF that needs a password: kept as a file, never opened here.
      assetStore.discard(sessionID: id)
      return (try? lockedPDF(candidate, context: context))
        ?? .rejected("无法读取这个内容，未收进来")
    } catch {
      assetStore.discard(sessionID: id)
      return .rejected("无法读取这个内容，未收进来")
    }
  }

  private struct Context {
    let id: SessionID
    let capturedAt: Date
    let source: ItemSourceApplication?
    let origin: ItemSourceOrigin

    func item(
      kind: UserItemKind, text: String, extractor: String, pageCount: Int? = nil,
      image: ImageNormalizer.Result? = nil, filename: String? = nil,
      attachments: [UserItemAttachment] = [], reading: UserItemReading? = nil,
      uniformType: String? = nil
    ) -> IntakeOutcome {
      .item(
        UserItemDraft(
          id: id, kind: kind, capturedAt: capturedAt, source: source, sourceOrigin: origin,
          text: text, extractor: extractor, pageCount: pageCount,
          pixelWidth: image?.originalPixelWidth, pixelHeight: image?.originalPixelHeight,
          originalFilename: filename, attachments: attachments, reading: reading,
          uniformType: uniformType
        )
      )
    }
  }

  private func file(_ url: URL, context: Context) throws -> IntakeOutcome {
    // A web link dragged from a browser is not a file; reading it would go
    // online (AVFoundation fetches remote media). Checked before anything.
    guard url.isFileURL else { return .rejected("只收本机文件，链接未收进来") }
    guard !pathPolicy.isProtected(url) else { return .rejected(Self.protectedFileMessage) }
    let values = try? url.resourceValues(forKeys: [
      .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey,
    ])
    guard values?.isSymbolicLink != true else { return .rejected("无法读取这个文件，未收进来") }
    let fileClass = IntakeFileClass.classify(url)
    if values?.isDirectory == true {
      // A Pages/Numbers/Keynote package is a folder: its own preview is kept.
      guard fileClass == .iWork else { return .rejected("不支持文件夹，未收进来") }
      return try iWorkPackage(url, context: context)
    }
    guard values?.isRegularFile == true else { return .rejected("无法读取这个文件，未收进来") }
    let filename = url.lastPathComponent
    let ext = url.pathExtension.lowercased()
    let uniformType = IntakeFileClass.uniformType(url)
    let mediaType = IntakeFileClass.mediaType(url)
    // Audio or video by its type or by its first bytes, whatever its name:
    // never sent. What AVFoundation reads is imported and recognized here;
    // anything else is kept only on this Mac (privacy contract §5).
    let sniffedMedia = fileClass.isMedia ? false : Self.sniffsAsMedia(url)
    if fileClass.isMedia || sniffedMedia {
      if fileClass.isMedia, Self.canDecodeMedia(url) { return .media(url) }
      guard UInt64(values?.fileSize ?? 0) <= assetStore.maximumBytes else {
        return .rejected("文件超过 200 MB，未收进来")
      }
      return try localOnlyItem(
        original: .file(url), filename: filename, uniformType: uniformType,
        mediaType: mediaType, context: context)
    }
    guard UInt64(values?.fileSize ?? 0) <= assetStore.maximumBytes else {
      return .rejected("文件超过 200 MB，未收进来")
    }
    // A picture under another name (a screenshot renamed `.xlsx`) is taken in
    // as the picture it is: normalized, read here, and redacted when sent
    // (privacy review F3).
    if fileClass != .image, fileClass != .svg,
      let pictureExtension = Self.sniffedImageExtension(url)
    {
      let normalized = try normalizer.normalize(fileURL: url)
      return try image(
        original: .file(url), normalized: normalized, frames: [],
        originalFilename: filename, ext: pictureExtension, userFilename: filename,
        context: context)
    }
    let extracted: IntakeTextExtractor.Extracted
    switch fileClass {
    case .image:
      let normalized = try normalizer.normalize(fileURL: url)
      let frames = ext == "gif" ? normalizer.animationFrames(fileURL: url) : []
      return try image(
        original: .file(url), normalized: normalized, frames: frames,
        originalFilename: filename, ext: ext, userFilename: filename, context: context
      )
    case .svg:
      // Drawn here only when it names nothing outside itself; otherwise the
      // organizing device reads its source.
      if let raster = SVGRasterizer.rasterize(fileURL: url),
        let normalized = try? normalizer.normalize(raster)
      {
        return try image(
          original: .file(url), normalized: normalized, frames: [],
          originalFilename: filename, ext: ext, userFilename: filename, context: context)
      }
      return try fileItem(
        original: .file(url), filename: filename, uniformType: uniformType,
        mediaType: mediaType, localText: declared(url), context: context)
    case .plainText:
      extracted = try IntakeTextExtractor.plainText(fileURL: url)
    case .rtf:
      extracted = try IntakeTextExtractor.attributedFileText(
        fileURL: url, type: .rtf, extractor: "rtf-attributed-v1"
      )
    case .html:
      extracted = try IntakeTextExtractor.htmlText(fileURL: url)
    case .webArchive:
      extracted = try IntakeTextExtractor.webArchiveText(fileURL: url)
    case .webLocation:
      extracted = try IntakeTextExtractor.webLocationText(fileURL: url)
    case .pdf:
      extracted = try IntakeTextExtractor.pdfText(fileURL: url)
      if extracted.hasPagesWithoutText {
        guard !Self.exceedsTextLimit(extracted.text) else {
          return .rejected(Self.tooMuchTextMessage)
        }
        return try fileItem(
          original: .file(url), filename: filename, uniformType: uniformType,
          mediaType: mediaType, localText: extracted, context: context)
      }
    case .wordProcessing(let format):
      // The text read here is a local hint; the organizing device reads the
      // file itself (tables, embedded pictures).
      let local = try? IntakeTextExtractor.attributedFileText(
        fileURL: url, type: format.documentType, extractor: format.extractor)
      return try fileItem(
        original: .file(url), filename: filename, uniformType: uniformType,
        mediaType: mediaType,
        localText: local.flatMap { Self.exceedsTextLimit($0.text) ? nil : $0 },
        context: context)
    case .iWork, .file:
      let local = declared(url)
      // An archive (a zip's files are taken in one by one by `prepareAll`),
      // or a binary that is neither text nor a document the organizing
      // device reads: kept here only (privacy contract §5).
      if fileClass == .file,
        IntakeFileClass.isArchive(url) || (local == nil && !IntakeFileClass.isSendableFile(url))
      {
        return try localOnlyItem(
          original: .file(url), filename: filename, uniformType: uniformType,
          mediaType: mediaType, context: context)
      }
      return try fileItem(
        original: .file(url), filename: filename, uniformType: uniformType,
        mediaType: mediaType, localText: local, context: context)
    case .audio, .video:
      return .rejected("无法读取这个文件，未收进来")
    }
    guard !Self.exceedsTextLimit(extracted.text) else { return .rejected(Self.tooMuchTextMessage) }
    return try document(
      extracted, original: .file(url), originalFilename: filename, ext: ext,
      userFilename: filename, context: context, uniformType: uniformType
    )
  }

  /// A file that declares itself text (csv, ics, vcf, eml, …): its text,
  /// kept as the file item's local text.
  private func declared(_ url: URL) -> IntakeTextExtractor.Extracted? {
    IntakeTextExtractor.declaredText(fileURL: url).flatMap {
      Self.exceedsTextLimit($0) ? nil : .init(text: $0, extractor: "declared-text-v1")
    }
  }

  /// A file kept only on this Mac: stored byte for byte, never sent, shown
  /// as "只保存在 Mac 上".
  private func localOnlyItem(
    original: IntakeAssetStore.Source, filename: String, uniformType: String?,
    mediaType: String, context: Context
  ) throws -> IntakeOutcome {
    let ext = (filename as NSString).pathExtension.lowercased()
    let attachments = try assetStore.stage(
      sessionID: context.id,
      requests: [
        .init(
          role: .original, source: original, originalFilename: filename, mediaType: mediaType,
          fileExtension: ext)
      ]
    )
    return context.item(
      kind: .file, text: "", extractor: UserItemLimits.localOnlyExtractor, filename: filename,
      attachments: attachments, uniformType: uniformType)
  }

  /// The extension of the picture format the bytes are, whatever the file is
  /// called (nil for anything that is not a picture ImageIO draws; a PDF is
  /// not taken for a picture).
  static func sniffedImageExtension(_ url: URL) -> String? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let type = FileSendCopySanitizer.pictureType(of: source)
    else { return nil }
    return type.preferredFilenameExtension ?? "png"
  }

  /// Audio or video by its first bytes (`MediaContentSniffer`).
  static func sniffsAsMedia(_ url: URL) -> Bool {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return false }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    let prefix = (try? handle.read(upToCount: MediaContentSniffer.prefixLength)) ?? nil
    return prefix.map(MediaContentSniffer.isAudioOrVideo) ?? false
  }

  /// A file item: the exact bytes, with the text this Mac read (maybe none).
  private func fileItem(
    original: IntakeAssetStore.Source, filename: String, uniformType: String?,
    mediaType: String, localText: IntakeTextExtractor.Extracted?, context: Context
  ) throws -> IntakeOutcome {
    let ext = (filename as NSString).pathExtension.lowercased()
    let attachments = try assetStore.stage(
      sessionID: context.id,
      requests: [
        .init(
          role: .original, source: original, originalFilename: filename, mediaType: mediaType,
          fileExtension: ext)
      ]
    )
    return context.item(
      kind: .file, text: localText?.text ?? "",
      extractor: localText?.extractor ?? UserItemLimits.fileBytesExtractor,
      pageCount: localText?.pageCount, filename: filename, attachments: attachments,
      uniformType: uniformType
    )
  }

  /// A Pages/Numbers/Keynote package folder: its own preview (a PDF, else a
  /// JPEG) is kept as the file, named after the package.
  private func iWorkPackage(_ url: URL, context: Context) throws -> IntakeOutcome {
    let candidates: [(String, String, String)] = [
      ("QuickLook/Preview.pdf", "pdf", "application/pdf"),
      ("preview.jpg", "jpg", "image/jpeg"),
      ("QuickLook/Thumbnail.jpg", "jpg", "image/jpeg"),
    ]
    for (relative, ext, mediaType) in candidates {
      let preview = url.appendingPathComponent(relative)
      guard !pathPolicy.isProtected(preview),
        let values = try? preview.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
        values.isRegularFile == true, values.isSymbolicLink != true
      else { continue }
      let name = url.deletingPathExtension().lastPathComponent
      let local = ext == "pdf" ? try? IntakeTextExtractor.pdfText(fileURL: preview) : nil
      return try fileItem(
        original: .file(preview), filename: "\(name).\(url.pathExtension)-preview.\(ext)",
        uniformType: UTType(filenameExtension: ext)?.identifier, mediaType: mediaType,
        localText: local.flatMap { $0.text.isEmpty || Self.exceedsTextLimit($0.text) ? nil : $0 },
        context: context)
    }
    return .rejected("这个 \(url.pathExtension) 文件没有可读的预览，未收进来")
  }

  /// A PDF that needs a password: kept byte for byte as a file.
  private func lockedPDF(_ candidate: IntakeCandidate, context: Context) throws -> IntakeOutcome {
    switch candidate {
    case .pdfData(let data):
      guard PDFLock.isLocked(data: data) else { return .rejected("无法读取这个内容，未收进来") }
      return try fileItem(
        original: .data(data), filename: "pasted.pdf", uniformType: UTType.pdf.identifier,
        mediaType: "application/pdf", localText: nil, context: context)
    case .file(let url):
      guard PDFLock.isLocked(fileURL: url),
        UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
          <= assetStore.maximumBytes
      else { return .rejected("无法读取这个文件，未收进来") }
      return try fileItem(
        original: .file(url), filename: url.lastPathComponent,
        uniformType: UTType.pdf.identifier, mediaType: "application/pdf", localText: nil,
        context: context)
    default:
      return .rejected("无法读取这个内容，未收进来")
    }
  }

  private static func isPDF(_ candidate: IntakeCandidate) -> Bool {
    switch candidate {
    case .pdfData: true
    case .file(let url): IntakeFileClass.classify(url) == .pdf
    default: false
    }
  }

  /// Whether AVFoundation on this Mac can read the file's type.
  public static func canDecodeMedia(_ url: URL) -> Bool {
    guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
    let supported = AVURLAsset.audiovisualTypes().compactMap { UTType($0.rawValue) }
    return supported.contains { type == $0 || type.conforms(to: $0) }
  }

  private func image(
    original: IntakeAssetStore.Source, normalized: ImageNormalizer.Result,
    frames: [ImageNormalizer.Result] = [], originalFilename: String, ext: String,
    userFilename: String?, context: Context
  ) throws -> IntakeOutcome {
    let frameRequests = zip(UserItemAttachmentRole.animationFrames, frames).map { role, frame in
      IntakeAssetStore.Request(
        role: role, source: .data(frame.data),
        originalFilename: "\(role.rawValue).\(frame.fileExtension)",
        mediaType: frame.mediaType, fileExtension: frame.fileExtension)
    }
    let attachments = try assetStore.stage(
      sessionID: context.id,
      requests: [
        .init(
          role: .original, source: original, originalFilename: originalFilename,
          mediaType: Self.imageMediaType(ext), fileExtension: ext
        ),
        normalizedRequest(normalized),
      ] + frameRequests
    )
    // The on-device reading of the normalized copy (what the Spark sees too).
    // Failure or no text simply leaves the screenshot without a reading.
    let reading = imageReader.flatMap { reader -> UserItemReading? in
      guard
        let text = reader.readText(imageData: normalized.data).map(IntakeTextExtractor.sanitized),
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !Self.exceedsTextLimit(text)
      else { return nil }
      return UserItemReading(text: text, reader: reader.readerName)
    }
    return context.item(
      kind: .image, text: "", extractor: "imageio-normalize-v1", image: normalized,
      filename: userFilename, attachments: attachments, reading: reading
    )
  }

  private func document(
    _ extracted: IntakeTextExtractor.Extracted, original: IntakeAssetStore.Source,
    originalFilename: String, ext: String, userFilename: String?, context: Context,
    uniformType: String? = nil
  ) throws -> IntakeOutcome {
    let attachments = try assetStore.stage(
      sessionID: context.id,
      requests: [
        .init(
          role: .original, source: original, originalFilename: originalFilename,
          mediaType: Self.documentMediaType(ext), fileExtension: ext
        )
      ]
    )
    return context.item(
      kind: .document, text: extracted.text, extractor: extracted.extractor,
      pageCount: extracted.pageCount, filename: userFilename, attachments: attachments,
      uniformType: uniformType
    )
  }

  private func normalizedRequest(_ result: ImageNormalizer.Result) -> IntakeAssetStore.Request {
    .init(
      role: .normalizedImage, source: .data(result.data),
      originalFilename: "normalized.\(result.fileExtension)", mediaType: result.mediaType,
      fileExtension: result.fileExtension
    )
  }

  static func imageExtension(typeIdentifier: String) -> String {
    switch typeIdentifier {
    case "public.png": "png"
    case "public.jpeg": "jpg"
    case "public.heic": "heic"
    default: "tiff"
    }
  }

  static func imageMediaType(_ ext: String) -> String {
    switch ext {
    case "png": "image/png"
    case "jpg", "jpeg", "jpe": "image/jpeg"
    case "heic": "image/heic"
    case "heif": "image/heif"
    case "gif": "image/gif"
    case "bmp": "image/bmp"
    case "webp": "image/webp"
    case "svg": "image/svg+xml"
    default: "image/tiff"
    }
  }

  static func documentMediaType(_ ext: String) -> String {
    switch ext {
    case "pdf": "application/pdf"
    case "md", "markdown": "text/markdown"
    case "rtf": "application/rtf"
    case "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    case "html", "htm", "xhtml": "text/html"
    case "webarchive": "application/x-webarchive"
    case "webloc": "application/x-webloc"
    case "url": "application/x-url"
    default: UTType(filenameExtension: ext)?.preferredMIMEType ?? "text/plain"
    }
  }
}
