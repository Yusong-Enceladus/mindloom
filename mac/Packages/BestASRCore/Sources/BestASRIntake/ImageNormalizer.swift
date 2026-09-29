import BestASRDomain
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes the copy of an image that may be sent for organizing: the long side
/// at most 2,560 px (never enlarged), orientation applied, PNG when the image
/// has alpha and JPEG (quality 0.85) otherwise, stepped down until it fits the
/// organizer's 12 MB limit. The original bytes are kept separately.
public struct ImageNormalizer: Sendable {
  public struct Result: Equatable, Sendable {
    public let data: Data
    /// `image/png` or `image/jpeg`.
    public let mediaType: String
    public let fileExtension: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// The original's size before downscaling.
    public let originalPixelWidth: Int
    public let originalPixelHeight: Int
  }

  public enum NormalizationError: Error, Equatable, Sendable {
    case unreadableImage
    case encodingFailed
    case tooLarge
  }

  public let longSide: Int
  public let maximumBytes: Int

  public init(
    longSide: Int = UserItemLimits.normalizedImageLongSide,
    maximumBytes: Int = UserItemLimits.maximumSendableImageBytes
  ) {
    self.longSide = longSide
    self.maximumBytes = maximumBytes
  }

  public func normalize(_ data: Data) throws -> Result {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw NormalizationError.unreadableImage
    }
    return try normalize(source: source)
  }

  public func normalize(fileURL: URL) throws -> Result {
    guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
      throw NormalizationError.unreadableImage
    }
    return try normalize(source: source)
  }

  /// An animated image's further distinct frames (after the first), at
  /// most `UserItemLimits.maximumExtraAnimationFrames`, in frame order. A
  /// frame is distinct when its small grey picture differs from every frame
  /// already kept by more than `threshold` (mean absolute difference, 0…1).
  /// Deterministic; no model is involved. Empty for a still image.
  public func animationFrames(
    fileURL: URL, maximum: Int = UserItemLimits.maximumExtraAnimationFrames,
    threshold: Double = 0.06
  ) -> [Result] {
    guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return [] }
    return animationFrames(source: source, maximum: maximum, threshold: threshold)
  }

  public func animationFrames(data: Data, maximum: Int, threshold: Double) -> [Result] {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
    return animationFrames(source: source, maximum: maximum, threshold: threshold)
  }

  private func animationFrames(source: CGImageSource, maximum: Int, threshold: Double)
    -> [Result]
  {
    let count = CGImageSourceGetCount(source)
    guard count > 1, maximum > 0 else { return [] }
    // Long animations are looked at in at most 64 evenly spaced frames.
    let step = max(1, count / 64)
    func signature(_ index: Int) -> [UInt8]? {
      guard let image = try? thumbnail(source: source, maxPixelSize: 64, index: index) else {
        return nil
      }
      return FrameSignature.grey(image)
    }
    guard let first = signature(0) else { return [] }
    var kept: [[UInt8]] = [first]
    var result: [Result] = []
    var index = step
    while index < count, result.count < maximum {
      defer { index += step }
      guard let candidate = signature(index),
        kept.allSatisfy({ FrameSignature.difference($0, candidate) > threshold }),
        let frame = try? normalize(source: source, index: index)
      else { continue }
      kept.append(candidate)
      result.append(frame)
    }
    return result
  }

  private func normalize(source: CGImageSource, index: Int = 0) throws -> Result {
    guard CGImageSourceGetCount(source) > index,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
        as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      width > 0, height > 0
    else { throw NormalizationError.unreadableImage }
    let hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false
    var side = min(longSide, max(width, height))
    var quality = 0.85
    // Deterministic steps: lower JPEG quality first, then shrink.
    for _ in 0..<12 {
      let image = try thumbnail(source: source, maxPixelSize: side, index: index)
      let encoded = try encode(image, png: hasAlpha, quality: quality)
      if encoded.count <= maximumBytes {
        return Result(
          data: encoded, mediaType: hasAlpha ? "image/png" : "image/jpeg",
          fileExtension: hasAlpha ? "png" : "jpg", pixelWidth: image.width,
          pixelHeight: image.height, originalPixelWidth: width, originalPixelHeight: height
        )
      }
      if !hasAlpha, quality > 0.56 {
        quality -= 0.15
      } else {
        side = max(64, side * 3 / 4)
      }
    }
    throw NormalizationError.tooLarge
  }

  private func thumbnail(source: CGImageSource, maxPixelSize: Int, index: Int = 0) throws
    -> CGImage
  {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    else { throw NormalizationError.unreadableImage }
    return image
  }

  private func encode(_ image: CGImage, png: Bool, quality: Double) throws -> Data {
    let output = NSMutableData()
    let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
    guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
      throw NormalizationError.encodingFailed
    }
    // No metadata is copied: location and device EXIF stay only in the original.
    let options: [CFString: Any] =
      png ? [:] : [kCGImageDestinationLossyCompressionQuality: quality]
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw NormalizationError.encodingFailed
    }
    return output as Data
  }
}

/// A tiny grey picture of a frame, for telling frames apart without a model.
enum FrameSignature {
  static let side = 16

  static func grey(_ image: CGImage) -> [UInt8]? {
    var pixels = [UInt8](repeating: 0, count: side * side)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return false }
      context.interpolationQuality = .medium
      context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    return drawn ? pixels : nil
  }

  /// Mean absolute difference, 0 (same) … 1 (inverse).
  static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 1 }
    var total = 0
    for index in a.indices { total += abs(Int(a[index]) - Int(b[index])) }
    return Double(total) / Double(a.count * 255)
  }
}
