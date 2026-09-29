import AppKit
import Foundation
import PDFKit

/// Draws an SVG into a PNG on this Mac, only when the SVG names nothing
/// outside itself: an external link, a stylesheet import, or an entity
/// declaration makes it stay a file (its source is read on the organizing
/// device) so drawing can never reach the network or another file.
enum SVGRasterizer {
  static let maximumSourceBytes = 5 * 1_024 * 1_024
  /// Long side of the drawing; the normalizer then fits it to its limit.
  static let longSide: CGFloat = 2_048

  static func rasterize(fileURL: URL) -> Data? {
    guard
      let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
      data.count <= maximumSourceBytes,
      let source = IntakeTextExtractor.decodedText(data),
      isSelfContained(source)
    else { return nil }
    return rasterize(data)
  }

  static func isSelfContained(_ source: String) -> Bool {
    let lowered = source.lowercased()
    if lowered.contains("<!entity") || lowered.contains("<!doctype") && lowered.contains("system")
    {
      return false
    }
    if lowered.contains("@import") { return false }
    // Any reference that is not a fragment (#id) or inline data.
    let pattern = #"(?:href|src)\s*=\s*["']\s*([^"'\s]*)|url\(\s*["']?\s*([^"')\s]*)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    let range = NSRange(lowered.startIndex..., in: lowered)
    for match in regex.matches(in: lowered, range: range) {
      for group in 1...2 {
        guard let valueRange = Range(match.range(at: group), in: lowered) else { continue }
        let value = String(lowered[valueRange])
        if value.isEmpty || value.hasPrefix("#") || value.hasPrefix("data:") { continue }
        return false
      }
    }
    return true
  }

  private static func rasterize(_ data: Data) -> Data? {
    guard let image = NSImage(data: data) else { return nil }
    var size = image.size
    guard size.width > 0, size.height > 0 else { return nil }
    let scale = longSide / max(size.width, size.height)
    size = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
  }
}

/// Whether a PDF needs a password (never asked for; such a PDF is kept as a
/// file and the organizing device reports it as encrypted).
enum PDFLock {
  static func isLocked(data: Data) -> Bool { PDFDocument(data: data)?.isLocked ?? false }
  static func isLocked(fileURL: URL) -> Bool { PDFDocument(url: fileURL)?.isLocked ?? false }
}
