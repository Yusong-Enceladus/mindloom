import BestASRDomain
import Compression
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Makes the copy of a file item's bytes that may be sent for organizing
/// (privacy review F3). Before, a file went byte for byte, so pictures and
/// recordings inside it reached the organizing device unredacted: an image or
/// a zip of images renamed `.xlsx`, a scanned PDF, a Word file with a pasted
/// screenshot, a Keynote preview, a slide deck with a recording.
///
/// What the bytes are decides, never the name:
/// - an image: normalized and redacted like a screenshot;
/// - a zip (every OOXML, OpenDocument, EPUB and zipped iWork file, or a zip
///   under any name): rebuilt member by member (limits of `ZipArchiveReader`):
///   pictures normalized and redacted, audio and video emptied, embedded
///   binary objects this Mac cannot inspect (OLE) emptied, nested zips and
///   PDFs sanitized the same way (depth at most two), everything else kept;
///   entries this Mac cannot read (encrypted, other methods) are left out;
/// - a PDF: pages with a text layer and no pictures are copied as they are;
///   every other page is rendered, redacted and put back as a picture (the
///   Mac's own text of the file still goes along as its local text); a
///   password-locked PDF goes as it is (nobody without the password reads it);
/// - anything else (text, calendars, contacts, legacy binary Office files):
///   as it is, and the organizing device reads no picture in it.
///
/// Every copy made here is marked `picturesRedacted`; the organizing device
/// reads pictures in a file only then. A copy that cannot be made, or that
/// would exceed the send limit, throws: the item stays on the Mac.
public struct FileSendCopySanitizer: RemoteOrganizerFileSanitizing {
  public enum SanitizeError: Error, Equatable, Sendable {
    case audioOrVideo
    case unreadable
    case tooLarge
  }

  public let redactor: VisionSendCopyRedactor
  public let normalizer: ImageNormalizer
  public let reader: ZipArchiveReader
  public let maximumBytes: Int

  public init(
    redactor: VisionSendCopyRedactor = VisionSendCopyRedactor(),
    normalizer: ImageNormalizer = ImageNormalizer(),
    reader: ZipArchiveReader = ZipArchiveReader(),
    maximumBytes: Int = Int(UserItemLimits.maximumSendableFileBytes)
  ) {
    self.redactor = redactor
    self.normalizer = normalizer
    self.reader = reader
    self.maximumBytes = maximumBytes
  }

  public func sendCopy(of data: Data, filename: String) throws -> RemoteOrganizerFileSendCopy {
    let copy = try sanitized(data, depth: 1)
    guard copy.data.count <= maximumBytes else { throw SanitizeError.tooLarge }
    return copy
  }

  func sanitized(_ data: Data, depth: Int) throws -> RemoteOrganizerFileSendCopy {
    if MediaContentSniffer.isAudioOrVideo(data) { throw SanitizeError.audioOrVideo }
    if Self.isPDF(data) { return try sanitizedPDF(data) }
    if ZipArchiveReader.looksLikeZip(data) {
      return RemoteOrganizerFileSendCopy(
        data: try sanitizedZip(data, depth: depth), picturesRedacted: true)
    }
    if Self.isDecodableImage(data) {
      return RemoteOrganizerFileSendCopy(data: try redactedImage(data), picturesRedacted: true)
    }
    return RemoteOrganizerFileSendCopy(data: data, picturesRedacted: false)
  }

  // MARK: - Pictures

  /// Normalized (no metadata, long side at most 2,560 px, PNG or JPEG) and
  /// redacted.
  func redactedImage(_ data: Data) throws -> Data {
    let normalized = try normalizer.normalize(data)
    return try redactor.redactedSendCopy(of: normalized.data, mediaType: normalized.mediaType)
  }

  static func isDecodableImage(_ data: Data) -> Bool {
    guard !isPDF(data), let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      return false
    }
    return pictureType(of: source) != nil
  }

  /// Picture formats recognized by their bytes (each has a signature; formats
  /// ImageIO guesses without one, such as TGA, are not taken for pictures).
  static let sniffablePictureTypes: [UTType] =
    [
      .png, .jpeg, .gif, .tiff, .heic, .heif, .webP, .bmp,
    ] + ["public.avif", "public.jpeg-2000"].compactMap { UTType($0) }

  /// The picture type ImageIO reads `source` as, when it is one of those
  /// and has at least one frame.
  static func pictureType(of source: CGImageSource) -> UTType? {
    guard CGImageSourceGetCount(source) > 0,
      let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }),
      sniffablePictureTypes.contains(where: { type.conforms(to: $0) })
    else { return nil }
    return type
  }

  static func isPDF(_ data: Data) -> Bool {
    data.prefix(1_024).range(of: Data("%PDF-".utf8)) != nil
  }

  /// OLE compound file (legacy Office binaries, embedded objects).
  static func isOLE(_ data: Data) -> Bool {
    data.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
  }

  static let pictureExtensions: Set<String> = [
    "png", "jpg", "jpeg", "jpe", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif", "emf",
    "wmf", "emz", "wmz", "svg", "svgz", "pict", "pct", "ico", "jp2", "jxl", "avif", "psd",
  ]

  static func pathExtension(_ path: String) -> String {
    guard let last = path.split(separator: "/").last, let dot = last.lastIndex(of: ".") else {
      return ""
    }
    return String(last[last.index(after: dot)...]).lowercased()
  }

  static func isMediaName(_ path: String) -> Bool {
    let ext = pathExtension(path)
    guard !ext.isEmpty else { return false }
    if MediaImportFormats.audioExtensions.contains(ext)
      || MediaImportFormats.videoExtensions.contains(ext)
    {
      return true
    }
    if let type = UTType(filenameExtension: ext), !type.isDynamic {
      return type.conforms(to: .audiovisualContent)
    }
    return false
  }

  // MARK: - Zip packages

  func sanitizedZip(_ data: Data, depth: Int) throws -> Data {
    let contents: ZipArchiveReader.Contents
    do { contents = try reader.read(data, depth: depth) } catch {
      throw SanitizeError.unreadable
    }
    var members: [(path: String, data: Data)] = []
    for member in contents.members {
      let bytes = member.data
      let replaced: Data
      if Self.isMediaName(member.path) || MediaContentSniffer.isAudioOrVideo(bytes) {
        replaced = Data()  // a recording stays on the Mac
      } else if Self.isOLE(bytes) {
        replaced = Data()  // an embedded object this Mac cannot inspect
      } else if Self.isPDF(bytes) {
        replaced = (try? sanitizedPDF(bytes).data) ?? Data()
      } else if ZipArchiveReader.looksLikeZip(bytes) {
        replaced =
          depth < reader.limits.maximumDepth
          ? ((try? sanitizedZip(bytes, depth: depth + 1)) ?? Data()) : Data()
      } else if Self.isDecodableImage(bytes) {
        replaced = (try? redactedImage(bytes)) ?? Data()
      } else if Self.pictureExtensions.contains(Self.pathExtension(member.path)) {
        replaced = Data()  // a picture format this Mac cannot draw (EMF, WMF, …)
      } else {
        replaced = bytes
      }
      members.append((member.path, replaced))
    }
    // Entries this Mac could not read (encrypted, other methods) are left out.
    return ZipArchiveWriter.write(members)
  }

  // MARK: - PDF

  func sanitizedPDF(_ data: Data) throws -> RemoteOrganizerFileSendCopy {
    guard let provider = CGDataProvider(data: data as CFData),
      let document = CGPDFDocument(provider)
    else { throw SanitizeError.unreadable }
    if document.isEncrypted, !document.isUnlocked {
      // Nobody without the password reads it, there or here.
      return RemoteOrganizerFileSendCopy(data: data, picturesRedacted: false)
    }
    let texts = PDFDocument(data: data)
    let output = NSMutableData()
    guard let consumer = CGDataConsumer(data: output as CFMutableData),
      let context = CGContext(consumer: consumer, mediaBox: nil, nil)
    else { throw SanitizeError.unreadable }
    for index in 0..<document.numberOfPages {
      guard let page = document.page(at: index + 1) else { continue }
      let box = page.getBoxRect(.cropBox)
      let rotated =
        page.rotationAngle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
      var mediaBox = CGRect(origin: .zero, size: rotated)
      let text =
        texts?.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !text.isEmpty, !Self.hasPictures(page) {
        context.beginPage(mediaBox: &mediaBox)
        context.concatenate(
          page.getDrawingTransform(.cropBox, rect: mediaBox, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        context.endPage()
        continue
      }
      let picture = try redactedRendering(of: page, size: rotated)
      context.beginPage(mediaBox: &mediaBox)
      context.draw(picture, in: mediaBox)
      context.endPage()
    }
    context.closePDF()
    return RemoteOrganizerFileSendCopy(data: output as Data, picturesRedacted: true)
  }

  /// The page drawn at 2,560 px on its long side, redacted, and re-read
  /// from JPEG (quality 0.9) so the PDF keeps it compressed.
  func redactedRendering(of page: CGPDFPage, size: CGSize) throws -> CGImage {
    let longSide = max(size.width, size.height)
    let scale = 2_560 / max(longSide, 1)
    let width = max(1, Int((size.width * scale).rounded()))
    let height = max(1, Int((size.height * scale).rounded()))
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw SanitizeError.unreadable }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // getDrawingTransform never enlarges: scale first, then map the page's
    // box (origin, rotation) onto a rect of its own size.
    context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
    context.concatenate(
      page.getDrawingTransform(
        .cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
    context.drawPDFPage(page)
    guard let rendered = context.makeImage() else { throw SanitizeError.unreadable }
    let regions = try redactor.regions(in: rendered)
    let painted =
      regions.isEmpty
      ? rendered : try VisionSendCopyRedactor.painting(regions.map(\.rect), over: rendered)
    let jpeg = try VisionSendCopyRedactor.encode(painted, png: false, quality: 0.9)
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw SanitizeError.unreadable }
    return image
  }

  /// Whether the page draws an image or a form (which may hold one).
  static func hasPictures(_ page: CGPDFPage) -> Bool {
    guard let dictionary = page.dictionary else { return true }
    var resources: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else {
      return false
    }
    var objects: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else {
      return false
    }
    var found = false
    CGPDFDictionaryApplyBlock(
      objects,
      { _, object, _ in
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
          let streamDictionary = CGPDFStreamGetDictionary(stream)
        else { return true }
        var subtype: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(streamDictionary, "Subtype", &subtype), let subtype {
          let name = String(cString: subtype)
          if name == "Image" || name == "Form" {
            found = true
            return false
          }
        }
        return true
      }, nil)
    return found
  }
}

/// Writes a zip (DEFLATE when it helps, else stored), with UTF-8 names.
/// Only for send copies rebuilt from `ZipArchiveReader`'s members.
enum ZipArchiveWriter {
  static func write(_ members: [(path: String, data: Data)]) -> Data {
    var output = Data()
    var central = Data()
    for member in members {
      let name = Data(member.path.utf8)
      let raw = [UInt8](member.data)
      let crc = ZipArchiveReader.crc32(raw)
      let deflated = deflate(raw)
      let (method, body): (UInt16, [UInt8]) =
        deflated.map { $0.count < raw.count ? (8, $0) : (0, raw) } ?? (0, raw)
      let offset = UInt32(output.count)
      output += le32(0x0403_4B50) + le16(20) + le16(0x0800) + le16(method) + le16(0) + le16(0x21)
      output += le32(crc) + le32(UInt32(body.count)) + le32(UInt32(raw.count))
      output += le16(UInt16(name.count)) + le16(0) + name + Data(body)
      central += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0x0800) + le16(method)
      central += le16(0) + le16(0x21) + le32(crc) + le32(UInt32(body.count))
      central += le32(UInt32(raw.count)) + le16(UInt16(name.count)) + le16(0) + le16(0)
      central += le16(0) + le16(0) + le32(0) + le32(offset) + name
    }
    let directoryOffset = UInt32(output.count)
    output += central
    output += le32(0x0605_4B50) + le16(0) + le16(0) + le16(UInt16(members.count))
    output += le16(UInt16(members.count)) + le32(UInt32(central.count)) + le32(directoryOffset)
    output += le16(0)
    return output
  }

  /// Raw DEFLATE (Compression's zlib format is raw DEFLATE), or nil.
  static func deflate(_ input: [UInt8]) -> [UInt8]? {
    guard !input.isEmpty else { return nil }
    var output = [UInt8](repeating: 0, count: input.count + 1_024)
    let written = input.withUnsafeBufferPointer { source in
      output.withUnsafeMutableBufferPointer { destination in
        compression_encode_buffer(
          destination.baseAddress!, destination.count, source.baseAddress!, source.count, nil,
          COMPRESSION_ZLIB)
      }
    }
    return written > 0 ? Array(output.prefix(written)) : nil
  }

  private static func le16(_ value: UInt16) -> Data {
    Data([UInt8(value & 0xFF), UInt8(value >> 8)])
  }

  private static func le32(_ value: UInt32) -> Data {
    Data([
      UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF),
      UInt8(value >> 24),
    ])
  }
}
