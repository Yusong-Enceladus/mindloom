import BestASRDomain
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Paints over identifiers in the copy of a screenshot that may be sent
/// (privacy contract §4). It runs the same on-device recognizer as local
/// search (Apple Vision, Simplified Chinese and English) on the normalized
/// send copy and covers each value the masking detectors find with an opaque
/// rectangle padded by 2 px. The original on the Mac is never touched; the
/// output carries no metadata. Fails closed: an image it cannot read or
/// re-encode throws, and the item stays on the Mac.
///
/// After the v6 privacy review (finding F2) it reads more than one way and
/// joins more than one way:
/// - passes: the whole image with and without language correction, plus an
///   enlarged pass for small or narrow images (a long chat screenshot shrunk
///   to 2,560 px, digits in form boxes, a vertical column): tall images are
///   read in enlarged tiles along their length, others enlarged whole;
/// - joins: each recognized line alone; lines stacked under one another; a
///   line and the next one in reading order even without horizontal overlap
///   (a wrapped card number); observations on one baseline, left to right
///   (table cells); and columns of single characters, top to bottom
///   (vertical text);
/// - what is covered: every masking detector's value (spec v3), and any run
///   of seven or more digits once spaces, dots, middle dots and dashes are
///   ignored (dates, times and two-decimal amounts excepted); a value found
///   across several observations of one row or column is covered from its
///   first to its last observation, so digits Vision missed in between are
///   covered too. Look-alike separators (・ • ‧ ∙ ⋅ ．) are read as `·`.
public struct VisionSendCopyRedactor: RemoteOrganizerImageRedacting {
  public enum RedactionError: Error, Equatable, Sendable, RemoteOrganizerAssetErrorClassifying {
    case unreadableImage
    case recognitionFailed
    case encodingFailed

    /// Vision failing outright may pass on the next try; an image that
    /// cannot be read or written will not.
    public var isTransient: Bool { self == .recognitionFailed }
  }

  /// One covered region, in pixels from the top-left corner.
  public struct Region: Equatable, Sendable {
    public let type: String
    public let rect: CGRect
  }

  public static let padding: CGFloat = 2

  /// Detection only needs the rules, not the library's tags.
  private let detector = PrivacyMasker.detectionOnly
  private let maximumBytes: Int

  public init(maximumBytes: Int = UserItemLimits.maximumSendableImageBytes) {
    self.maximumBytes = maximumBytes
  }

  public func redactedSendCopy(of data: Data, mediaType: String) throws -> Data {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw RedactionError.unreadableImage }
    let regions = try regions(in: image)
    guard !regions.isEmpty else { return data }
    let painted = try Self.painting(regions.map(\.rect), over: image)
    let png = mediaType == "image/png"
    for quality in png ? [1.0] : [0.85, 0.7, 0.55] {
      let encoded = try Self.encode(painted, png: png, quality: quality)
      if encoded.count <= maximumBytes { return encoded }
    }
    throw RedactionError.encodingFailed
  }

  /// One recognized observation in the image's pixel space (origin at the
  /// top left), and where a UTF-16 range of its text is.
  struct Line {
    let text: String
    let rect: CGRect
    let box: (Int, Int) -> CGRect?
  }

  /// The regions `redactedSendCopy` covers (for tests and diagnostics).
  ///
  /// The screenshot is read with and without language correction:
  /// correction helps Chinese text but "corrects" codes (a key's `sk-` read
  /// as `Sk-`, a digit as a letter), and a value missed by one reading is
  /// often found by the other. Small and narrow images are also read
  /// enlarged. Every reading's regions are covered.
  public func regions(in image: CGImage) throws -> [Region] {
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    var passes: [[Line]] = []
    var failures = 0
    for languageCorrection in [true, false] {
      do {
        passes.append(
          try Self.recognize(
            image, languageCorrection: languageCorrection, placedIn: bounds))
      } catch { failures += 1 }
    }
    guard failures < 2 else { throw RedactionError.recognitionFailed }
    passes.append(Self.enlargedPass(image))
    var regions: [Region] = []
    for lines in passes {
      for region in self.regions(for: lines, bounds: bounds) {
        // A value another reading already covered is not painted again with
        // a slightly different box (fewer, cleaner edges near kept text).
        let area = region.rect.width * region.rect.height
        let covered = regions.contains { existing in
          let overlap = existing.rect.intersection(region.rect)
          return !overlap.isNull && overlap.width * overlap.height >= 0.85 * area
        }
        if !covered { regions.append(region) }
      }
    }
    return regions
  }

  // MARK: - Reading

  /// Vision on `image`, whose pixels stand for `placement` in the send copy
  /// (a tile, maybe enlarged); boxes come back in the send copy's pixels.
  static func recognize(
    _ image: CGImage, languageCorrection: Bool, placedIn placement: CGRect
  ) throws -> [Line] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = languageCorrection
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    do { try VisionTextRecognition.perform(request, on: image) } catch {
      throw RedactionError.recognitionFailed
    }
    // Vision's boxes are normalized with the origin at the bottom left.
    func place(_ box: CGRect) -> CGRect {
      CGRect(
        x: placement.minX + box.minX * placement.width,
        y: placement.minY + (1 - box.maxY) * placement.height,
        width: box.width * placement.width, height: box.height * placement.height)
    }
    return (request.results ?? []).compactMap { observation in
      guard let candidate = observation.topCandidates(1).first else { return nil }
      let text = canonicalSeparators(candidate.string)
      let raw = candidate.string
      return Line(
        text: text, rect: place(observation.boundingBox),
        box: { start, end in
          guard let range = Range(NSRange(location: start, length: end - start), in: raw),
            let box = try? candidate.boundingBox(for: range)?.boundingBox
          else { return nil }
          return place(box)
        })
    }
  }

  /// The enlarged reading of a small or narrow image (empty when it would
  /// not help): a tall image in enlarged tiles along its length (its lines
  /// run across), any other enlarged whole. A tile Vision fails on is
  /// skipped; the other passes still count.
  static func enlargedPass(_ image: CGImage) -> [Line] {
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    let short = min(width, height)
    let tall = height >= 1.5 * width
    guard short < 1_000 else { return [] }
    var lines: [Line] = []
    /// Vision now and then fails on one image of a series; one more try.
    func read(_ image: CGImage, _ placement: CGRect) -> [Line] {
      (try? recognize(image, languageCorrection: false, placedIn: placement))
        ?? (try? recognize(image, languageCorrection: false, placedIn: placement)) ?? []
    }
    if tall {
      // Two enlargements: each reads characters the other misses.
      let scales = Set([600 / short, 900 / short].map { min(6, max(1.5, $0)) })
      let tileHeight = (1.5 * width).rounded()
      for scale in scales.sorted() {
        var top: CGFloat = 0
        while top < height {
          let tile = CGRect(x: 0, y: top, width: width, height: min(tileHeight, height - top))
          if let enlarged = enlarge(image, crop: tile, scale: scale) {
            lines += read(enlarged, tile)
          }
          guard tile.maxY < height else { break }
          top += (tileHeight * 0.85).rounded()
        }
      }
    } else {
      let scale = min(3, 4_096 / max(width, height))
      guard scale >= 1.3 else { return [] }
      let whole = CGRect(x: 0, y: 0, width: width, height: height)
      if let enlarged = enlarge(image, crop: whole, scale: scale) {
        lines = read(enlarged, whole)
      }
    }
    return lines
  }

  /// `crop` of `image`, scaled by `scale` with high-quality interpolation.
  static func enlarge(_ image: CGImage, crop: CGRect, scale: CGFloat) -> CGImage? {
    guard let cropped = image.cropping(to: crop.integral) else { return nil }
    let width = Int((CGFloat(cropped.width) * scale).rounded())
    let height = Int((CGFloat(cropped.height) * scale).rounded())
    guard width > 0, height > 0,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }

  // MARK: - Finding and covering

  private func regions(for lines: [Line], bounds: CGRect) -> [Region] {
    var regions: [Region] = []
    func cover(_ type: String, _ rect: CGRect) {
      let padded = rect.insetBy(dx: -Self.padding, dy: -Self.padding).intersection(bounds)
      guard !padded.isNull, !padded.isEmpty else { return }
      regions.append(Region(type: type, rect: padded.integral))
    }
    func part(_ line: Line, _ start: Int, _ end: Int) -> CGRect {
      // No box for the range: cover the whole observation rather than leave it.
      line.box(start, end) ?? line.rect
    }
    for line in lines {
      for span in spans(line.text, digitRuns: true) {
        cover(span.type, part(line, span.start, span.end))
      }
    }
    let rects = lines.map(\.rect)
    enum Kind { case wrapped, row, column }
    // Groups read joined, members in reading order. A row or column is also
    // covered between the first and last touched member; digit runs count in
    // a column, and in a row only across single characters (digits in form
    // boxes), so numeric table cells side by side are not taken for one number.
    var groups: [([Int], Kind)] = Self.stackedBlocks(rects.map { Self.normalized($0, in: bounds) })
      .filter { $0.count > 1 }.map { ($0, .wrapped) }
    groups += Self.readingPairs(rects).map { ($0, .wrapped) }
    groups += Self.rows(rects).map { ($0, .row) }
    groups += Self.columns(rects, texts: lines.map(\.text)).map { ($0, .column) }
    for (group, kind) in groups {
      let fill = kind != .wrapped
      let texts = group.map { lines[$0].text }
      for joiner in ["", " "] {
        var starts: [Int] = []
        var joined = ""
        for (position, text) in texts.enumerated() {
          if position > 0 { joined += joiner }
          starts.append(joined.utf16.count)
          joined += text
        }
        for span in spans(joined, digitRuns: kind != .wrapped) {
          let touched = texts.indices.filter { position in
            span.start < starts[position] + texts[position].utf16.count
              && span.end > starts[position]
          }
          // Values inside one observation were covered above.
          guard touched.count > 1 else { continue }
          if span.type == Self.digitRunType, kind == .row,
            !touched.allSatisfy({ texts[$0].count <= 2 })
          {
            continue
          }
          var hull = CGRect.null
          for position in touched {
            let start = max(span.start - starts[position], 0)
            let end = min(span.end - starts[position], texts[position].utf16.count)
            guard end > start else { continue }
            let rect = part(lines[group[position]], start, end)
            cover(span.type, rect)
            hull = hull.union(rect)
          }
          if fill, !hull.isNull { cover(span.type, hull) }
        }
      }
    }
    return regions
  }

  struct Span {
    let type: String
    let start: Int
    let end: Int
  }

  /// The detectors' matches in recognized text, plus long digit runs.
  /// Detection runs on a copy in which a secret's fixed prefix read with the
  /// wrong case (`Sk-`, `GHP_`) is put back in its own case; the copy has the
  /// same UTF-16 length, so the offsets apply to the recognized line as is.
  private func spans(_ text: String, digitRuns: Bool) -> [Span] {
    let found = detector.maskWithSpans(Self.canonicalSecretPrefixes(text)).spans.map {
      Span(type: $0.type, start: $0.start, end: $0.end)
    }
    guard digitRuns else { return found }
    return found
      + Self.digitRuns(text).map { Span(type: Self.digitRunType, start: $0.0, end: $0.1) }
  }

  /// The region type of a long digit run (not a masking type).
  static let digitRunType = "number"

  // MARK: - Digit runs

  private static let digitRunRegex = try! NSRegularExpression(
    pattern: #"(?<![0-9])[0-9](?:[ .·\-]?[0-9]){6,}(?![0-9])"#)
  /// Dates, times and compact dates are kept (organizing needs them).
  private static let keptRegexes = [
    #"(?<![0-9])(?:19|20)[0-9]{2}[-./·年][0-9]{1,2}[-./·月][0-9]{1,2}(?![0-9])"#,
    #"(?<![0-9])[0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?(?![0-9])"#,
    #"(?<![0-9])(?:19|20)[0-9]{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])(?![0-9])"#,
  ].map { try! NSRegularExpression(pattern: $0) }
  private static let amountRegex = try! NSRegularExpression(pattern: #"^[0-9]+\.[0-9]{2}$"#)

  /// Runs of seven or more digits (spaces, dots, middle dots and dashes
  /// between them ignored), except dates, times and two-decimal amounts; in
  /// UTF-16 offsets of `text`.
  static func digitRuns(_ text: String) -> [(Int, Int)] {
    let ns = NSMutableString(string: text)
    for regex in keptRegexes {
      for match in regex.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)) {
        ns.replaceCharacters(
          in: match.range, with: String(repeating: "#", count: match.range.length))
      }
    }
    let protected = ns as String
    return digitRunRegex.matches(
      in: protected, range: NSRange(location: 0, length: (protected as NSString).length)
    ).compactMap { match in
      let value = (protected as NSString).substring(with: match.range)
      guard
        amountRegex.firstMatch(in: value, range: NSRange(location: 0, length: match.range.length))
          == nil
      else { return nil }
      return (match.range.location, match.range.location + match.range.length)
    }
  }

  // MARK: - Canonical text

  static let secretPrefixes = [
    "sk-", "ghp_", "github_pat_", "xoxa-", "xoxb-", "xoxp-", "xoxr-", "xoxs-", "AKIA", "AIza",
  ]

  public static func canonicalSecretPrefixes(_ text: String) -> String {
    let result = NSMutableString(string: text)
    for prefix in secretPrefixes {
      var searchStart = 0
      while searchStart < result.length {
        let found = result.range(
          of: prefix, options: [.caseInsensitive, .literal],
          range: NSRange(location: searchStart, length: result.length - searchStart))
        guard found.location != NSNotFound else { break }
        if found.length == (prefix as NSString).length {
          result.replaceCharacters(in: found, with: prefix)
        }
        searchStart = found.location + max(found.length, 1)
      }
    }
    return result as String
  }

  /// Separators Vision reads as a look-alike (`・`, `•`, `‧`, `∙`, `⋅`, `．`)
  /// as the middle dot the masking rules know; one UTF-16 unit for one, so
  /// offsets stay the same.
  public static func canonicalSeparators(_ text: String) -> String {
    let lookAlikes: Set<Unicode.Scalar> = [
      "\u{30FB}", "\u{2022}", "\u{2027}", "\u{2219}", "\u{22C5}", "\u{FF0E}",
    ]
    guard text.unicodeScalars.contains(where: { lookAlikes.contains($0) }) else { return text }
    var view = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      view.append(lookAlikes.contains(scalar) ? "\u{00B7}" : scalar)
    }
    return String(view)
  }

  // MARK: - Groups

  /// A pixel rect (origin top left) as Vision's normalized box (origin
  /// bottom left).
  static func normalized(_ rect: CGRect, in bounds: CGRect) -> CGRect {
    CGRect(
      x: rect.minX / bounds.width, y: 1 - rect.maxY / bounds.height,
      width: rect.width / bounds.width, height: rect.height / bounds.height)
  }

  /// Runs of recognized lines that read as one wrapped paragraph: each line
  /// followed by the nearest line directly under it (the gap at most one
  /// line height, the two overlapping horizontally). Boxes are Vision's
  /// (normalized, origin at the bottom left); the result lists indices into
  /// `boxes`, top line first.
  public static func stackedBlocks(_ boxes: [CGRect]) -> [[Int]] {
    var next: [Int: Int] = [:]
    var previous: [Int: Int] = [:]
    var candidates: [(gap: CGFloat, upper: Int, lower: Int)] = []
    for upper in boxes.indices {
      for lower in boxes.indices where lower != upper {
        let a = boxes[upper]
        let b = boxes[lower]
        let lineHeight = max(a.height, b.height)
        let gap = a.minY - b.maxY
        guard b.midY < a.midY, gap >= -0.5 * lineHeight, gap <= lineHeight,
          b.minX < a.maxX, b.maxX > a.minX
        else { continue }
        candidates.append((gap + abs(a.minX - b.minX), upper, lower))
      }
    }
    for candidate in candidates.sorted(by: { $0.gap < $1.gap })
    where next[candidate.upper] == nil && previous[candidate.lower] == nil {
      next[candidate.upper] = candidate.lower
      previous[candidate.lower] = candidate.upper
    }
    var blocks: [[Int]] = []
    for start in boxes.indices where previous[start] == nil {
      var block = [start]
      var current = start
      while let following = next[current], !block.contains(following) {
        block.append(following)
        current = following
      }
      blocks.append(block)
    }
    return blocks
  }

  /// Each observation and the next one in reading order: the nearest one
  /// starting below it within 1.2 line heights, wherever it starts
  /// horizontally (a value wrapped to the start of the next line). Pixel
  /// rects, origin top left.
  static func readingPairs(_ rects: [CGRect]) -> [[Int]] {
    var pairs: [[Int]] = []
    for upper in rects.indices {
      let a = rects[upper]
      var best: (Int, CGFloat)?
      for lower in rects.indices where lower != upper {
        let b = rects[lower]
        let lineHeight = max(a.height, b.height)
        let gap = b.minY - a.maxY
        guard b.midY > a.maxY - 0.25 * lineHeight, gap >= -0.5 * lineHeight,
          gap <= 1.2 * lineHeight, !overlapsVertically(a, b)
        else { continue }
        let score = gap + b.minX / 10_000
        if best == nil || score < best!.1 { best = (lower, score) }
      }
      if let best { pairs.append([upper, best.0]) }
    }
    return pairs
  }

  private static func overlapsVertically(_ a: CGRect, _ b: CGRect) -> Bool {
    let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
    return overlap >= 0.5 * min(a.height, b.height)
  }

  /// Observations on one baseline (vertical overlap at least half the
  /// smaller height), left to right: table cells, digits in form boxes.
  /// Only rows of two or more.
  static func rows(_ rects: [CGRect]) -> [[Int]] {
    var rows: [[Int]] = []
    for index in rects.indices.sorted(by: { rects[$0].midY < rects[$1].midY }) {
      if let row = rows.indices.last(where: { row in
        rows[row].contains { overlapsVertically(rects[$0], rects[index]) }
      }) {
        rows[row].append(index)
      } else {
        rows.append([index])
      }
    }
    return rows.filter { $0.count > 1 }.map { $0.sorted { rects[$0].minX < rects[$1].minX } }
  }

  /// Columns of short observations (at most three characters) read top to
  /// bottom: vertical text. Members overlap horizontally by half the
  /// narrower width and follow one another within 1.5 heights. Only columns
  /// of three or more.
  static func columns(_ rects: [CGRect], texts: [String]) -> [[Int]] {
    let short = rects.indices.filter { texts[$0].count <= 3 }
    var columns: [[Int]] = []
    for index in short.sorted(by: { rects[$0].minY < rects[$1].minY }) {
      let rect = rects[index]
      // The same character read twice (overlapping tiles, two enlargements).
      if columns.contains(where: { column in
        column.contains { member in
          let other = rects[member]
          return other.intersection(rect).width >= 0.5 * min(other.width, rect.width)
            && overlapsVertically(other, rect)
        }
      }) {
        continue
      }
      if let column = columns.indices.last(where: { column in
        let last = rects[columns[column].last!]
        let overlap = min(last.maxX, rect.maxX) - max(last.minX, rect.minX)
        let gap = rect.minY - last.maxY
        return overlap >= 0.5 * min(last.width, rect.width)
          && gap <= 1.5 * max(last.height, rect.height) && gap >= -0.5 * last.height
      }) {
        columns[column].append(index)
      } else {
        columns.append([index])
      }
    }
    return columns.filter { $0.count >= 3 }
  }

  static func painting(_ rects: [CGRect], over image: CGImage) throws -> CGImage {
    let width = image.width
    let height = image.height
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw RedactionError.encodingFailed }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    for rect in rects {
      // CGContext's origin is the bottom left.
      context.fill(
        CGRect(
          x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
    }
    guard let painted = context.makeImage() else { throw RedactionError.encodingFailed }
    return painted
  }

  static func encode(_ image: CGImage, png: Bool, quality: Double = 0.85) throws -> Data {
    let output = NSMutableData()
    let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
    guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
      throw RedactionError.encodingFailed
    }
    // No metadata: the send copy never carries EXIF.
    let options: [CFString: Any] =
      png ? [:] : [kCGImageDestinationLossyCompressionQuality: quality]
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw RedactionError.encodingFailed }
    return output as Data
  }
}
