import Foundation

/// What kind of thing the phone collected.
public enum InboxItemKind: String, Codable, Sendable, CaseIterable {
  case text
  case link
  case image
  case file
}

/// Where on the phone it came from; the Mac shows this as the source app.
public enum InboxItemSource: String, Codable, Sendable, CaseIterable {
  case keyboard = "iPhone 键盘"
  case share = "iPhone 分享"
}

/// Limits for what one inbox entry may carry. They match what the Spark
/// organizer accepts once the Mac forwards the item (`spark/organizer/
/// schemas.py`: 400,000 text characters, 12 MiB images, 25 MiB files), so an
/// entry the phone accepts is never refused later.
public enum InboxLimits {
  /// Unicode scalars, which is how Python's `len` counts on the Spark.
  public static let maximumTextCharacters = 400_000
  public static let maximumImageBytes = 12 * 1024 * 1024
  public static let maximumFileBytes = 25 * 1024 * 1024
  public static let maximumURLBytes = 8 * 1024
  public static let maximumTitleCharacters = 1_000
  public static let maximumFilenameBytes = 255
  public static let maximumMIMEBytes = 255
  /// Normalized images from the phone. The share extension re-encodes every
  /// image, which also drops its metadata.
  public static let imageMIMETypes: Set<String> = ["image/jpeg", "image/png", "image/heic"]
}

/// The plaintext of one sealed inbox entry (PHONE-CONTRACT §3):
///
/// ```
/// {"v":1,"kind":"text"|"link"|"image"|"file","source":"iPhone 键盘"|"iPhone 分享",
///  "created_at":"<ISO-8601 with local offset>","text":…,"url":…,"title":…,
///  "filename":…,"mime":…,"bytes_b64":…}
/// ```
///
/// Absent fields are omitted from the JSON. `validate()` runs on every encode
/// and decode, so neither side ever handles an entry that breaks the rules.
public struct InboxItemPayload: Codable, Equatable, Sendable {
  public static let currentVersion = 1

  public let v: Int
  public let kind: InboxItemKind
  public let source: InboxItemSource
  public let createdAt: String
  public let text: String?
  public let url: String?
  public let title: String?
  public let filename: String?
  public let mime: String?
  public let bytesB64: String?

  public enum ValidationError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalidCreatedAt
    case emptyText
    case textTooLong
    case invalidURL
    case titleTooLong
    case missingBytes
    case invalidBytes
    case imageTooLarge
    case fileTooLarge
    case unsupportedImageType
    case invalidFilename
    case invalidMIME
    /// Audio and video are recorded and transcribed on the Mac, never shared
    /// from the phone (PHONE-CONTRACT §0.5).
    case audioOrVideoRefused
    /// A field that does not belong to this kind is set.
    case unexpectedField(String)
    case malformedJSON
  }

  enum CodingKeys: String, CodingKey {
    case v, kind, source, text, url, title, filename, mime
    case createdAt = "created_at"
    case bytesB64 = "bytes_b64"
  }

  init(
    kind: InboxItemKind, source: InboxItemSource, createdAt: String,
    text: String? = nil, url: String? = nil, title: String? = nil,
    filename: String? = nil, mime: String? = nil, bytesB64: String? = nil
  ) {
    self.v = Self.currentVersion
    self.kind = kind
    self.source = source
    self.createdAt = createdAt
    self.text = text
    self.url = url
    self.title = title
    self.filename = filename
    self.mime = mime
    self.bytesB64 = bytesB64
  }

  // MARK: - Builders (validated)

  public static func text(
    _ text: String, source: InboxItemSource, createdAt: Date = Date(),
    timeZone: TimeZone = .current
  ) throws -> InboxItemPayload {
    let payload = InboxItemPayload(
      kind: .text, source: source,
      createdAt: InboxTimestamp.string(from: createdAt, timeZone: timeZone), text: text)
    try payload.validate()
    return payload
  }

  /// A link is kept as text and URL; it is never fetched (§0.5).
  public static func link(
    _ url: URL, title: String? = nil, text: String? = nil, source: InboxItemSource,
    createdAt: Date = Date(), timeZone: TimeZone = .current
  ) throws -> InboxItemPayload {
    let payload = InboxItemPayload(
      kind: .link, source: source,
      createdAt: InboxTimestamp.string(from: createdAt, timeZone: timeZone),
      text: text, url: url.absoluteString, title: title)
    try payload.validate()
    return payload
  }

  /// `bytes` must already be normalized (re-encoded, no metadata).
  public static func image(
    _ bytes: Data, mime: String, filename: String? = nil, text: String? = nil,
    source: InboxItemSource, createdAt: Date = Date(), timeZone: TimeZone = .current
  ) throws -> InboxItemPayload {
    guard bytes.count <= InboxLimits.maximumImageBytes else {
      throw ValidationError.imageTooLarge
    }
    let payload = InboxItemPayload(
      kind: .image, source: source,
      createdAt: InboxTimestamp.string(from: createdAt, timeZone: timeZone),
      text: text, filename: filename, mime: mime, bytesB64: bytes.base64EncodedString())
    try payload.validate()
    return payload
  }

  public static func file(
    _ bytes: Data, filename: String, mime: String = "application/octet-stream",
    source: InboxItemSource, createdAt: Date = Date(), timeZone: TimeZone = .current
  ) throws -> InboxItemPayload {
    guard bytes.count <= InboxLimits.maximumFileBytes else { throw ValidationError.fileTooLarge }
    let payload = InboxItemPayload(
      kind: .file, source: source,
      createdAt: InboxTimestamp.string(from: createdAt, timeZone: timeZone),
      filename: filename, mime: mime, bytesB64: bytes.base64EncodedString())
    try payload.validate()
    return payload
  }

  // MARK: - JSON

  /// Validated UTF-8 JSON with sorted keys, ready to seal.
  public func encoded() throws -> Data {
    try validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  /// Decodes and validates an opened plaintext.
  public static func decode(_ data: Data) throws -> InboxItemPayload {
    let payload: InboxItemPayload
    do {
      payload = try JSONDecoder().decode(InboxItemPayload.self, from: data)
    } catch {
      throw ValidationError.malformedJSON
    }
    try payload.validate()
    return payload
  }

  // MARK: - Derived values

  /// The decoded bytes of an image or file.
  public var bytes: Data? { bytesB64.flatMap(Base64URL.decodeStandard) }

  public var createdDate: Date? { InboxTimestamp.date(from: createdAt) }

  /// A short text-only preview for the phone's "已送出" list. Images have
  /// none: the phone keeps no copy of a shared image.
  public var preview: String? {
    let raw: String?
    switch kind {
    case .text: raw = text
    case .link: raw = (title?.isEmpty == false ? title : nil) ?? url
    case .file: raw = filename
    case .image: raw = nil
    }
    return raw.map { Self.shortPreview($0) }
  }

  public static let previewCharacters = 80

  static func shortPreview(_ text: String) -> String {
    let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
      .joined(separator: " ")
    guard collapsed.count > previewCharacters else { return collapsed }
    return String(collapsed.prefix(previewCharacters)) + "…"
  }

  // MARK: - Validation

  public func validate() throws {
    guard v == Self.currentVersion else { throw ValidationError.unsupportedVersion(v) }
    guard createdAt.contains("T"), InboxTimestamp.date(from: createdAt) != nil else {
      throw ValidationError.invalidCreatedAt
    }
    if let text, text.unicodeScalars.count > InboxLimits.maximumTextCharacters {
      throw ValidationError.textTooLong
    }
    if let title, title.unicodeScalars.count > InboxLimits.maximumTitleCharacters {
      throw ValidationError.titleTooLong
    }
    switch kind {
    case .text:
      guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ValidationError.emptyText
      }
      try forbid(url: true, title: true, filename: true, mime: true, bytes: true)
    case .link:
      guard let url, Self.isAcceptableURL(url) else { throw ValidationError.invalidURL }
      try forbid(url: false, title: false, filename: true, mime: true, bytes: true)
    case .image:
      try forbid(url: true, title: true, filename: false, mime: false, bytes: false)
      guard let mime, InboxLimits.imageMIMETypes.contains(mime) else {
        throw Self.isAudioOrVideoMIME(mime)
          ? ValidationError.audioOrVideoRefused : ValidationError.unsupportedImageType
      }
      if let filename { try Self.validateFilename(filename) }
      let bytes = try decodedBytes(limit: InboxLimits.maximumImageBytes, tooLarge: .imageTooLarge)
      guard MediaSniffer.imageType(of: bytes) == mime else {
        throw MediaSniffer.isAudioOrVideo(bytes)
          ? ValidationError.audioOrVideoRefused : ValidationError.unsupportedImageType
      }
    case .file:
      try forbid(url: true, title: true, filename: false, mime: false, bytes: false)
      guard let filename else { throw ValidationError.invalidFilename }
      try Self.validateFilename(filename)
      guard let mime, Self.isWellFormedMIME(mime) else { throw ValidationError.invalidMIME }
      guard !Self.isAudioOrVideoMIME(mime), !MediaSniffer.isAudioOrVideoFilename(filename) else {
        throw ValidationError.audioOrVideoRefused
      }
      let bytes = try decodedBytes(limit: InboxLimits.maximumFileBytes, tooLarge: .fileTooLarge)
      guard !MediaSniffer.isAudioOrVideo(bytes) else { throw ValidationError.audioOrVideoRefused }
    }
  }

  private func forbid(url: Bool, title: Bool, filename: Bool, mime: Bool, bytes: Bool) throws {
    if url, self.url != nil { throw ValidationError.unexpectedField("url") }
    if title, self.title != nil { throw ValidationError.unexpectedField("title") }
    if filename, self.filename != nil { throw ValidationError.unexpectedField("filename") }
    if mime, self.mime != nil { throw ValidationError.unexpectedField("mime") }
    if bytes, self.bytesB64 != nil { throw ValidationError.unexpectedField("bytes_b64") }
  }

  private func decodedBytes(limit: Int, tooLarge: ValidationError) throws -> Data {
    guard let bytesB64 else { throw ValidationError.missingBytes }
    // Cheap size check before decoding: base64 is 4 characters per 3 bytes.
    guard bytesB64.utf8.count <= (limit + 2) / 3 * 4 else { throw tooLarge }
    guard let bytes = Base64URL.decodeStandard(bytesB64), !bytes.isEmpty else {
      throw ValidationError.invalidBytes
    }
    guard bytes.count <= limit else { throw tooLarge }
    return bytes
  }

  static func isAcceptableURL(_ text: String) -> Bool {
    guard !text.isEmpty, text.utf8.count <= InboxLimits.maximumURLBytes,
      !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
      let url = URL(string: text), let scheme = url.scheme?.lowercased()
    else { return false }
    return scheme == "http" || scheme == "https"
  }

  static func isWellFormedMIME(_ mime: String) -> Bool {
    let parts = mime.split(separator: "/", omittingEmptySubsequences: false)
    return mime.utf8.count <= InboxLimits.maximumMIMEBytes && parts.count == 2
      && parts.allSatisfy { part in
        !part.isEmpty
          && part.unicodeScalars.allSatisfy {
            $0.isASCII
              && (CharacterSet.alphanumerics.contains($0)
                || "!#$&^_.+-".unicodeScalars.contains($0))
          }
      }
  }

  static func isAudioOrVideoMIME(_ mime: String?) -> Bool {
    guard let mime = mime?.lowercased() else { return false }
    return mime.hasPrefix("audio/") || mime.hasPrefix("video/")
      || mime == "application/ogg" || mime == "application/vnd.apple.mpegurl"
      || mime == "application/x-mpegurl"
  }

  /// A plain file name: no path separators, no control characters, not `.`
  /// or `..`, at most 255 UTF-8 bytes.
  public static func validateFilename(_ name: String) throws {
    guard !name.isEmpty, name.utf8.count <= InboxLimits.maximumFilenameBytes,
      name != ".", name != "..",
      !name.unicodeScalars.contains(where: {
        $0 == "/" || $0 == "\\" || $0 == ":" || $0.properties.generalCategory == .control
      })
    else { throw ValidationError.invalidFilename }
  }

  /// Turns any suggested name into one that passes `validateFilename`.
  public static func sanitizedFilename(_ name: String, fallback: String = "文件") -> String {
    var cleaned = String(
      String.UnicodeScalarView(
        name.unicodeScalars.map { scalar -> Unicode.Scalar in
          if scalar == "/" || scalar == "\\" || scalar == ":" { return "_" }
          return scalar
        }.filter { $0.properties.generalCategory != .control }))
    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.utf8.count > InboxLimits.maximumFilenameBytes {
      // Shorten the base name and keep a short extension, on character
      // boundaries so no UTF-8 sequence is cut.
      var base = cleaned
      var ext = ""
      if let dot = cleaned.lastIndex(of: "."), dot != cleaned.startIndex,
        cleaned.distance(from: dot, to: cleaned.endIndex) <= 16
      {
        base = String(cleaned[..<dot])
        ext = String(cleaned[dot...])
      }
      while !base.isEmpty, base.utf8.count + ext.utf8.count > InboxLimits.maximumFilenameBytes {
        base.removeLast()
      }
      cleaned = base + ext
    }
    if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return fallback }
    return cleaned
  }
}
