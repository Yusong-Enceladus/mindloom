import Foundation
import MindloomLink
import UniformTypeIdentifiers

/// One thing handed to 收进织机, already loaded from its item provider.
public enum ShareInput: Sendable, Equatable {
  case text(String)
  /// A web link, never fetched.
  case link(URL, title: String?)
  /// An image file on disk (a temporary copy the extension owns).
  case image(ShareFile)
  /// Any other file on disk.
  case file(ShareFile)
  /// Recognized as audio or video without loading its bytes.
  case audioOrVideo(name: String?)
}

public struct ShareFile: Sendable, Equatable {
  public let url: URL
  public let typeIdentifier: String?
  public let suggestedName: String?

  public init(url: URL, typeIdentifier: String?, suggestedName: String?) {
    self.url = url
    self.typeIdentifier = typeIdentifier
    self.suggestedName = suggestedName
  }

  var contentType: UTType? {
    typeIdentifier.flatMap(UTType.init) ?? UTType(filenameExtension: url.pathExtension)
  }

  /// A safe display and payload name, with an extension when one is known.
  var name: String {
    var candidate = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if candidate.isEmpty { candidate = url.lastPathComponent }
    if (candidate as NSString).pathExtension.isEmpty {
      let ext =
        url.pathExtension.isEmpty
        ? (contentType?.preferredFilenameExtension ?? "") : url.pathExtension
      if !ext.isEmpty { candidate += "." + ext }
    }
    return InboxItemPayload.sanitizedFilename(candidate)
  }
}

/// Why an item was not taken in, in the words the share sheet shows.
public enum ShareRefusal: Error, Equatable, Sendable {
  /// Audio and video are imported on the Mac (PHONE-CONTRACT §0.5).
  case audioOrVideo
  case fileTooLarge
  case imageUnreadable
  case empty
  case unreadable

  public var message: String {
    switch self {
    case .audioOrVideo: "音视频请在 Mac 上导入"
    case .fileTooLarge: "超过 25 MB，请在 Mac 上导入"
    case .imageUnreadable: "这张图片打不开"
    case .empty: "没有可收进的内容"
    case .unreadable: "这个文件读不出来"
    }
  }
}

/// A converted item, ready to seal, with what the confirmation shows.
public struct ShareConversion: Sendable, Equatable {
  public enum Kind: String, Sendable {
    case text, link, image, file
  }

  public let payload: InboxItemPayload
  public let kind: Kind
  /// One line for the confirmation list (text start, link title or host,
  /// file name). Images show a thumbnail instead.
  public let summary: String
  public let byteCount: Int?
  /// The normalized image, for the thumbnail (memory only).
  public let imageBytes: Data?
  /// An image whose location (GPS) was removed.
  public var removedLocation = false
}

/// Turns share-sheet inputs into validated inbox payloads (PHONE-CONTRACT
/// §0.5, §3): text, links (never fetched), images (normalized, no metadata,
/// ≤ 12 MiB) and documents (≤ 25 MiB). Audio and video are refused by type,
/// by file extension and by content.
public struct ShareItemConverter: Sendable {
  public let source: InboxItemSource
  public let timeZone: TimeZone

  public init(source: InboxItemSource = .share, timeZone: TimeZone = .current) {
    self.source = source
    self.timeZone = timeZone
  }

  public func convert(_ input: ShareInput, now: Date = Date()) -> Result<
    ShareConversion, ShareRefusal
  > {
    do {
      return .success(try convertOrThrow(input, now: now))
    } catch let refusal as ShareRefusal {
      return .failure(refusal)
    } catch InboxItemPayload.ValidationError.audioOrVideoRefused {
      return .failure(.audioOrVideo)
    } catch InboxItemPayload.ValidationError.fileTooLarge {
      return .failure(.fileTooLarge)
    } catch InboxItemPayload.ValidationError.emptyText {
      return .failure(.empty)
    } catch {
      return .failure(.unreadable)
    }
  }

  private func convertOrThrow(_ input: ShareInput, now: Date) throws -> ShareConversion {
    switch input {
    case .audioOrVideo:
      throw ShareRefusal.audioOrVideo
    case .text(let raw):
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { throw ShareRefusal.empty }
      if let url = Self.singleWebURL(text) {
        return try link(url, title: nil, now: now)
      }
      let payload = try InboxItemPayload.text(
        text, source: source, createdAt: now, timeZone: timeZone)
      return ShareConversion(
        payload: payload, kind: .text, summary: payload.preview ?? "", byteCount: nil,
        imageBytes: nil)
    case .link(let url, let title):
      if url.isFileURL {
        return try convertOrThrow(
          .file(ShareFile(url: url, typeIdentifier: nil, suggestedName: nil)), now: now)
      }
      return try link(url, title: title, now: now)
    case .image(let file):
      if Self.isAudioOrVideo(file) { throw ShareRefusal.audioOrVideo }
      let output: ImageNormalizer.Output
      do {
        output = try ImageNormalizer.normalize(contentsOf: file.url)
      } catch {
        throw ShareRefusal.imageUnreadable
      }
      let name = Self.imageName(file.name, mime: output.mime)
      let payload = try InboxItemPayload.image(
        output.bytes, mime: output.mime, filename: name, source: source, createdAt: now,
        timeZone: timeZone)
      return ShareConversion(
        payload: payload, kind: .image, summary: name, byteCount: output.bytes.count,
        imageBytes: output.bytes, removedLocation: output.removedLocation)
    case .file(let file):
      if Self.isAudioOrVideo(file) { throw ShareRefusal.audioOrVideo }
      let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
      if let size, size > InboxLimits.maximumFileBytes { throw ShareRefusal.fileTooLarge }
      if file.contentType?.conforms(to: .image) == true, Self.isNormalizableImage(file) {
        return try convertOrThrow(.image(file), now: now)
      }
      let bytes: Data
      do {
        bytes = try Data(contentsOf: file.url, options: .mappedIfSafe)
      } catch {
        throw ShareRefusal.unreadable
      }
      guard !bytes.isEmpty else { throw ShareRefusal.empty }
      guard bytes.count <= InboxLimits.maximumFileBytes else { throw ShareRefusal.fileTooLarge }
      let mime = file.contentType?.preferredMIMEType ?? "application/octet-stream"
      let payload = try InboxItemPayload.file(
        bytes, filename: file.name, mime: Self.cleanMIME(mime), source: source, createdAt: now,
        timeZone: timeZone)
      return ShareConversion(
        payload: payload, kind: .file, summary: file.name, byteCount: bytes.count, imageBytes: nil)
    }
  }

  private func link(_ url: URL, title: String?, now: Date) throws -> ShareConversion {
    let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    let usableTitle =
      cleanTitle?.isEmpty == false && cleanTitle != url.absoluteString
      ? cleanTitle : nil
    let payload: InboxItemPayload
    do {
      payload = try InboxItemPayload.link(
        url, title: usableTitle.map { String($0.prefix(InboxLimits.maximumTitleCharacters)) },
        source: source, createdAt: now, timeZone: timeZone)
    } catch InboxItemPayload.ValidationError.invalidURL {
      // Not a web link (mailto:, app links…): keep it as text.
      let payload = try InboxItemPayload.text(
        url.absoluteString, source: source, createdAt: now, timeZone: timeZone)
      return ShareConversion(
        payload: payload, kind: .text, summary: payload.preview ?? "", byteCount: nil,
        imageBytes: nil)
    }
    let summary = usableTitle ?? url.host() ?? url.absoluteString
    return ShareConversion(
      payload: payload, kind: .link, summary: String(summary.prefix(80)), byteCount: nil,
      imageBytes: nil)
  }

  // MARK: - Rules

  /// A text that is nothing but one http(s) URL is shared as a link.
  static func singleWebURL(_ text: String) -> URL? {
    guard !text.contains(where: \.isWhitespace), let url = URL(string: text),
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      url.host() != nil
    else { return nil }
    return url
  }

  static func isAudioOrVideo(_ file: ShareFile) -> Bool {
    if let type = file.contentType, Self.isAudioOrVideoType(type) { return true }
    for name in [file.suggestedName, file.url.lastPathComponent].compactMap({ $0 }) {
      let ext = (name as NSString).pathExtension
      if !ext.isEmpty, let type = UTType(filenameExtension: ext), Self.isAudioOrVideoType(type) {
        return true
      }
    }
    return false
  }

  public static func isAudioOrVideoType(_ type: UTType) -> Bool {
    type.conforms(to: .audiovisualContent) || type.conforms(to: .audio)
      || type.conforms(to: .movie) || type.conforms(to: .video)
  }

  /// Images ImageIO can decode (HEIC, JPEG, PNG, GIF, TIFF, RAW, WebP…).
  static func isNormalizableImage(_ file: ShareFile) -> Bool {
    guard let type = file.contentType, type.conforms(to: .image) else { return false }
    // SVG and other vector formats are documents, not pixels.
    return !type.conforms(to: .svg) && type != .pdf
  }

  static func imageName(_ name: String, mime: String) -> String {
    let base = (name as NSString).deletingPathExtension
    let ext = mime == "image/png" ? "png" : "jpg"
    return InboxItemPayload.sanitizedFilename((base.isEmpty ? "图片" : base) + "." + ext)
  }

  static func cleanMIME(_ mime: String) -> String {
    let base = mime.split(separator: ";").first.map(String.init) ?? mime
    let trimmed = base.trimmingCharacters(in: .whitespaces).lowercased()
    return trimmed.isEmpty ? "application/octet-stream" : trimmed
  }
}
