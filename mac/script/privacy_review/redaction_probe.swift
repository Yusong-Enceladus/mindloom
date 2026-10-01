import CoreGraphics
import Foundation
import ImageIO
import Vision

// Privacy review probe (FINDINGS.md F2): this checkout's own ImageNormalizer + VisionSendCopyRedactor on
// synthetic screenshots (make_images.py, invented numbers). A verifier reads the redacted send copy in all
// four orientations and reports whether the identifier is still legible. A case Vision cannot read at all
// is sent unchanged, so it counts as a leak too (the organizer's vision model reads more than Vision).
// Exits 1 when any case leaks.
func readAll(_ image: CGImage) -> String {
  var out: [String] = []
  for orientation in [CGImagePropertyOrientation.up, .right, .down, .left] {
    for lc in [true, false] {
      let r = VNRecognizeTextRequest()
      r.recognitionLevel = .accurate
      r.usesLanguageCorrection = lc
      r.recognitionLanguages = ["zh-Hans", "en-US"]
      try? VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]).perform([r]
      )
      out += (r.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
  }
  return out.joined(separator: " | ")
}
func digits(_ s: String) -> String {
  String(s.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.map(Character.init))
}
let cases: [(String, String)] = [
  ("01_control", "13812345678"), ("02_rot90", "13812345678"), ("03_rot180", "13812345678"),
  ("04_rot20", "13812345678"), ("05_long_screenshot", "13812345678"),
  ("06_id_boxes", "11010519491231002"),
  ("07_phone_dots", "13812345678"), ("08_table_cells", "13812345678"),
  ("09_low_contrast", "482913"),
  ("10_vertical", "13812345678"), ("11_tiny_12px", "13812345678"),
  ("12_card_wrap_no_overlap", "6222021234567894"),
  ("13_otp_number_first", "739146"),
]
let dir = CommandLine.arguments[1]
var leaked: [String] = []
let redactor = VisionSendCopyRedactor()
let normalizer = ImageNormalizer()
for (name, secret) in cases {
  let url = URL(fileURLWithPath: "\(dir)/\(name).png")
  let norm = try normalizer.normalize(fileURL: url)
  let src = CGImageSourceCreateWithData(norm.data as CFData, nil)!
  let normImage = CGImageSourceCreateImageAtIndex(src, 0, nil)!
  let regions = try redactor.regions(in: normImage)
  let sent = try redactor.redactedSendCopy(of: norm.data, mediaType: norm.mediaType)
  let sentImage = CGImageSourceCreateImageAtIndex(
    CGImageSourceCreateWithData(sent as CFData, nil)!, 0, nil)!
  let before = readAll(normImage)
  let after = readAll(sentImage)
  let tail = String(secret.suffix(6))
  let legibleBefore = digits(before).contains(tail)
  let legibleAfter = digits(after).contains(tail)
  try sent.write(to: URL(fileURLWithPath: "\(dir)/../out_\(name).\(norm.fileExtension)"))
  print(
    "\(name)\tsize=\(normImage.width)x\(normImage.height)\tregions=\(regions.count)\tunchanged=\(sent == norm.data)\treadable_before=\(legibleBefore)\treadable_after_redaction=\(legibleAfter)"
  )
  if legibleAfter || (!legibleBefore && regions.isEmpty) { leaked.append(name) }
  if legibleAfter { print("   after: \(after.prefix(300))") }
}
print("unredacted or unread: \(leaked.count)/\(cases.count): \(leaked.joined(separator: ", "))")
exit(leaked.isEmpty ? 0 : 1)
