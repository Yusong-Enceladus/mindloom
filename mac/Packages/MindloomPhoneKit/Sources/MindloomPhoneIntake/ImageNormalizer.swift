import CoreGraphics
import Foundation
import ImageIO
import MindloomLink
import UniformTypeIdentifiers

/// Re-encodes a shared image before it is sealed (PHONE-CONTRACT §0.5): the
/// pixels are decoded, rotated upright, scaled to at most `maximumPixelSize`
/// on the long edge and written into a new JPEG (or PNG when the image has
/// transparency) with no metadata at all: no EXIF, GPS, camera, maker notes,
/// captions or edit history. If the result is larger than 12 MiB it is
/// scaled down and compressed further until it fits.
public enum ImageNormalizer {
  public struct Output: Equatable, Sendable {
    public let bytes: Data
    public let mime: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// The source carried a location (GPS), now removed.
    public let removedLocation: Bool
  }

  public enum NormalizeError: Error, Equatable, Sendable {
    case unreadable
    case tooLarge
  }

  public static let maximumPixelSize = 4096
  public static let jpegQuality = 0.85

  public static func normalize(
    contentsOf url: URL, maximumBytes: Int = InboxLimits.maximumImageBytes
  ) throws -> Output {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
      throw NormalizeError.unreadable
    }
    return try normalize(source: source, maximumBytes: maximumBytes)
  }

  public static func normalize(
    data: Data, maximumBytes: Int = InboxLimits.maximumImageBytes
  ) throws -> Output {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
      throw NormalizeError.unreadable
    }
    return try normalize(source: source, maximumBytes: maximumBytes)
  }

  static func normalize(source: CGImageSource, maximumBytes: Int) throws -> Output {
    guard CGImageSourceGetCount(source) > 0,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
    else { throw NormalizeError.unreadable }

    let hadLocation = properties[kCGImagePropertyGPSDictionary] != nil
    var edge = min(max(width, height), maximumPixelSize)
    var quality = jpegQuality
    for _ in 0..<8 {
      let image = try autoreleasepool { () throws -> CGImage in
        let thumbnailOptions =
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Applies the EXIF orientation to the pixels, so dropping the
            // orientation tag keeps the picture upright.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceShouldCacheImmediately: true,
          ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
          throw NormalizeError.unreadable
        }
        return image
      }
      let transparent = hasAlpha(image)
      let type = transparent ? UTType.png : UTType.jpeg
      guard let bytes = encode(image, as: type, quality: quality) else {
        throw NormalizeError.unreadable
      }
      if bytes.count <= maximumBytes {
        return Output(
          bytes: bytes, mime: transparent ? "image/png" : "image/jpeg",
          pixelWidth: image.width, pixelHeight: image.height, removedLocation: hadLocation)
      }
      edge = max(256, Int(Double(edge) * 0.75))
      quality = max(0.6, quality - 0.08)
    }
    throw NormalizeError.tooLarge
  }

  static func hasAlpha(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: false
    default: true
    }
  }

  /// Writes only the pixels. No properties dictionary is passed except the
  /// compression quality, so nothing from the source file is copied.
  static func encode(_ image: CGImage, as type: UTType, quality: Double) -> Data? {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data as CFMutableData, type.identifier as CFString, 1, nil)
    else { return nil }
    var properties: [CFString: Any] = [:]
    if type == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = quality }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }
}
