import CoreGraphics
import Foundation
import ImageIO
import MindloomLink
import UniformTypeIdentifiers
import XCTest

@testable import MindloomPhoneIntake

let shareDate = Date(timeIntervalSince1970: 1_790_730_902)
let shanghai = TimeZone(identifier: "Asia/Shanghai")!

func makeWorkDirectory(_ name: String = #function) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("mindloom-intake-tests", isDirectory: true)
    .appendingPathComponent("\(name.filter(\.isLetter))-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// A synthetic photo: a gradient with a bright corner, so orientation can be
/// checked from the pixels, written with the metadata a phone camera adds.
func makePhoto(
  width: Int = 60, height: Int = 40, orientation: Int = 1, alpha: Bool = false,
  type: UTType = .jpeg, noise: Bool = false
) throws -> Data {
  let space = CGColorSpaceCreateDeviceRGB()
  let info = alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
  let context = try XCTUnwrap(
    CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: space, bitmapInfo: info.rawValue))
  if noise {
    let buffer = try XCTUnwrap(context.data).bindMemory(
      to: UInt8.self, capacity: width * height * 4)
    var seed: UInt32 = 0x9E37_79B9
    for index in 0..<(width * height * 4) {
      seed = seed &* 1_664_525 &+ 1_013_904_223
      buffer[index] = UInt8(truncatingIfNeeded: seed >> 24)
    }
  } else {
    for y in 0..<height {
      context.setFillColor(
        red: CGFloat(y) / CGFloat(height), green: 0.4, blue: 0.7, alpha: alpha ? 0.5 : 1)
      context.fill(CGRect(x: 0, y: y, width: width, height: 1))
    }
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: height - 8, width: 8, height: 8))
  }
  let image = try XCTUnwrap(context.makeImage())
  let data = NSMutableData()
  let destination = try XCTUnwrap(
    CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil))
  let properties: [CFString: Any] = [
    kCGImagePropertyOrientation: orientation,
    kCGImagePropertyGPSDictionary: [
      kCGImagePropertyGPSLatitude: 31.2304, kCGImagePropertyGPSLatitudeRef: "N",
      kCGImagePropertyGPSLongitude: 121.4737, kCGImagePropertyGPSLongitudeRef: "E",
    ],
    kCGImagePropertyTIFFDictionary: [
      kCGImagePropertyTIFFMake: "SyntheticCam", kCGImagePropertyTIFFModel: "Sentinel-9",
    ],
    kCGImagePropertyExifDictionary: [
      kCGImagePropertyExifDateTimeOriginal: "2026:09:29 10:11:12",
      kCGImagePropertyExifUserComment: "metadata-sentinel",
    ],
    kCGImageDestinationLossyCompressionQuality: 0.95,
  ]
  CGImageDestinationAddImage(destination, image, properties as CFDictionary)
  XCTAssertTrue(CGImageDestinationFinalize(destination))
  return data as Data
}

func imageProperties(_ data: Data) throws -> [CFString: Any] {
  let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
  return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
}

final class ShareItemConverterTests: XCTestCase {
  private var work: URL!
  private let converter = ShareItemConverter(timeZone: shanghai)

  override func setUpWithError() throws {
    work = try makeWorkDirectory()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: work)
  }

  private func write(_ data: Data, named name: String) throws -> URL {
    let url = work.appendingPathComponent(name)
    try data.write(to: url)
    return url
  }

  private func convert(_ input: ShareInput) throws -> ShareConversion {
    try converter.convert(input, now: shareDate).get()
  }

  private func refusal(_ input: ShareInput) -> ShareRefusal? {
    if case .failure(let refusal) = converter.convert(input, now: shareDate) { return refusal }
    return nil
  }

  func testTextBecomesATextItemFromTheShareSheet() throws {
    let result = try convert(.text("  合成：下周三和林老师对一下预算\n"))
    XCTAssertEqual(result.kind, .text)
    XCTAssertEqual(result.payload.kind, .text)
    XCTAssertEqual(result.payload.text, "合成：下周三和林老师对一下预算")
    XCTAssertEqual(result.payload.source.rawValue, "iPhone 分享")
    XCTAssertEqual(result.payload.createdAt, "2026-09-30T09:15:02.000+08:00")
    XCTAssertEqual(refusal(.text(" \n ")), .empty)
  }

  func testLinksAreKeptAsLinksAndNeverFetched() throws {
    // A host that cannot resolve: any fetch would fail or hang the test.
    let url = URL(string: "https://unreachable.invalid/article?id=7")!
    let link = try convert(.link(url, title: "合成：一篇文章"))
    XCTAssertEqual(link.kind, .link)
    XCTAssertEqual(link.payload.url, url.absoluteString)
    XCTAssertEqual(link.payload.title, "合成：一篇文章")
    XCTAssertEqual(link.summary, "合成：一篇文章")
    XCTAssertNil(link.payload.bytesB64)

    let bare = try convert(.text("https://unreachable.invalid/x"))
    XCTAssertEqual(bare.kind, .link, "a text that is only a link is a link")
    XCTAssertEqual(bare.summary, "unreachable.invalid")

    let sameAsURL = try convert(.link(url, title: url.absoluteString))
    XCTAssertNil(sameAsURL.payload.title)

    let mail = try convert(.link(URL(string: "mailto:someone@example.com")!, title: nil))
    XCTAssertEqual(mail.kind, .text, "non-web links are kept as text")
  }

  func testImageMetadataIsStrippedAndOrientationApplied() throws {
    let original = try makePhoto(width: 60, height: 40, orientation: 6)
    XCTAssertNotNil(try imageProperties(original)[kCGImagePropertyGPSDictionary])
    let url = try write(original, named: "IMG_0001.HEIC.jpg")
    let result = try convert(
      .image(ShareFile(url: url, typeIdentifier: UTType.jpeg.identifier, suggestedName: "IMG_0001"))
    )
    XCTAssertEqual(result.kind, .image)
    XCTAssertEqual(result.payload.mime, "image/jpeg")
    XCTAssertEqual(result.payload.filename, "IMG_0001.jpg")
    XCTAssertNil(result.payload.preview, "no preview text is kept for images")
    XCTAssertTrue(result.removedLocation, "the confirmation can say the location was removed")
    let bytes = try XCTUnwrap(result.payload.bytes)
    XCTAssertEqual(bytes, result.imageBytes)
    XCTAssertEqual(Array(bytes.prefix(3)), [0xFF, 0xD8, 0xFF])

    let properties = try imageProperties(bytes)
    XCTAssertNil(properties[kCGImagePropertyGPSDictionary], "no location")
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    XCTAssertNil(tiff[kCGImagePropertyTIFFMake])
    XCTAssertNil(tiff[kCGImagePropertyTIFFModel])
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    XCTAssertNil(exif[kCGImagePropertyExifDateTimeOriginal])
    XCTAssertNil(exif[kCGImagePropertyExifUserComment])
    XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int ?? 1, 1)
    // Orientation 6 (rotate 90°) is baked into the pixels.
    XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 40)
    XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 60)
    for sentinel in ["SyntheticCam", "Sentinel-9", "metadata-sentinel", "2026:09:29"] {
      XCTAssertNil(bytes.range(of: Data(sentinel.utf8)), "\(sentinel) must not survive")
    }
  }

  func testTransparentImagesStayPNG() throws {
    let url = try write(try makePhoto(alpha: true, type: .png), named: "sticker.png")
    let result = try convert(
      .image(ShareFile(url: url, typeIdentifier: UTType.png.identifier, suggestedName: nil)))
    XCTAssertEqual(result.payload.mime, "image/png")
    XCTAssertEqual(result.payload.filename, "sticker.png")
    XCTAssertNil(
      try imageProperties(XCTUnwrap(result.payload.bytes))[kCGImagePropertyGPSDictionary])
  }

  func testLargeImagesAreScaledUntilTheyFit() throws {
    let photo = try makePhoto(width: 1200, height: 900, noise: true)
    let url = try write(photo, named: "noise.jpg")
    let limit = 150_000
    XCTAssertGreaterThan(photo.count, limit)
    let output = try ImageNormalizer.normalize(contentsOf: url, maximumBytes: limit)
    XCTAssertLessThanOrEqual(output.bytes.count, limit)
    XCTAssertLessThan(output.pixelWidth, 1200)
    XCTAssertEqual(
      Double(output.pixelWidth) / Double(output.pixelHeight), 1200.0 / 900.0, accuracy: 0.02)
  }

  func testNeverLargerThanTheLongEdgeLimit() throws {
    let url = try write(try makePhoto(width: 5000, height: 100), named: "wide.jpg")
    let output = try ImageNormalizer.normalize(contentsOf: url)
    XCTAssertEqual(output.pixelWidth, ImageNormalizer.maximumPixelSize)
  }

  func testUnreadableImageIsRefused() throws {
    let url = try write(Data("not an image".utf8), named: "broken.jpg")
    XCTAssertEqual(
      refusal(
        .image(ShareFile(url: url, typeIdentifier: UTType.jpeg.identifier, suggestedName: nil))),
      .imageUnreadable)
  }

  func testDocumentsAreTakenUpTo25MiB() throws {
    let pdf = Data("%PDF-1.7\n合成的文档\n%%EOF".utf8)
    let url = try write(pdf, named: "季度计划.pdf")
    let result = try convert(
      .file(ShareFile(url: url, typeIdentifier: UTType.pdf.identifier, suggestedName: "季度计划")))
    XCTAssertEqual(result.kind, .file)
    XCTAssertEqual(result.payload.filename, "季度计划.pdf")
    XCTAssertEqual(result.payload.mime, "application/pdf")
    XCTAssertEqual(result.payload.bytes, pdf)
    XCTAssertEqual(result.byteCount, pdf.count)

    let big = work.appendingPathComponent("big.bin")
    FileManager.default.createFile(atPath: big.path, contents: nil)
    let handle = try FileHandle(forWritingTo: big)
    try handle.truncate(atOffset: UInt64(InboxLimits.maximumFileBytes + 1))
    try handle.close()
    XCTAssertEqual(
      refusal(.file(ShareFile(url: big, typeIdentifier: nil, suggestedName: nil))), .fileTooLarge)

    let exact = work.appendingPathComponent("exact.bin")
    FileManager.default.createFile(atPath: exact.path, contents: nil)
    let exactHandle = try FileHandle(forWritingTo: exact)
    try exactHandle.truncate(atOffset: UInt64(InboxLimits.maximumFileBytes))
    try exactHandle.close()
    XCTAssertEqual(
      try convert(.file(ShareFile(url: exact, typeIdentifier: nil, suggestedName: nil))).byteCount,
      InboxLimits.maximumFileBytes)
  }

  func testUnsafeFileNamesAreCleaned() throws {
    let url = try write(Data("合成".utf8), named: "a.txt")
    let result = try convert(
      .file(
        ShareFile(
          url: url, typeIdentifier: UTType.plainText.identifier, suggestedName: "../../etc/passwd"))
    )
    XCTAssertEqual(result.payload.filename, ".._.._etc_passwd.txt")
  }

  func testAudioAndVideoAreRefusedEveryWay() throws {
    XCTAssertEqual(refusal(.audioOrVideo(name: "会议录音.m4a")), .audioOrVideo)
    XCTAssertEqual(ShareRefusal.audioOrVideo.message, "音视频请在 Mac 上导入")

    // By declared type.
    let movie = try write(Data(repeating: 0, count: 32), named: "clip")
    XCTAssertEqual(
      refusal(
        .file(
          ShareFile(
            url: movie, typeIdentifier: UTType.quickTimeMovie.identifier, suggestedName: nil))),
      .audioOrVideo)
    // By extension, whatever the declared type says.
    let named = try write(Data("x".utf8), named: "voice.m4a")
    XCTAssertEqual(
      refusal(
        .file(ShareFile(url: named, typeIdentifier: UTType.data.identifier, suggestedName: nil))),
      .audioOrVideo)
    XCTAssertEqual(
      refusal(
        .file(
          ShareFile(
            url: try write(Data("x".utf8), named: "a.bin"), typeIdentifier: nil,
            suggestedName: "录音.mp3"))),
      .audioOrVideo)
    // By content: an M4A disguised as a text file.
    var m4a = Data([0, 0, 0, 0x20])
    m4a.append(Data("ftypM4A ".utf8))
    m4a.append(Data(repeating: 0, count: 64))
    let disguised = try write(m4a, named: "notes.txt")
    XCTAssertEqual(
      refusal(
        .file(
          ShareFile(url: disguised, typeIdentifier: UTType.plainText.identifier, suggestedName: nil)
        )),
      .audioOrVideo)
    // An "image" that is a video.
    XCTAssertEqual(
      refusal(
        .image(
          ShareFile(url: movie, typeIdentifier: UTType.mpeg4Movie.identifier, suggestedName: nil))),
      .audioOrVideo)
  }

  func testImagesSharedAsFilesAreNormalizedToo() throws {
    let url = try write(try makePhoto(orientation: 3), named: "scan.jpg")
    let result = try convert(
      .file(ShareFile(url: url, typeIdentifier: UTType.jpeg.identifier, suggestedName: nil)))
    XCTAssertEqual(result.kind, .image)
    XCTAssertNil(
      try imageProperties(XCTUnwrap(result.payload.bytes))[kCGImagePropertyGPSDictionary])
  }
}
