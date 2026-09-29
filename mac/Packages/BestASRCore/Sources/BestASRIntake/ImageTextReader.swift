import BestASRDomain
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Reads the text in a screenshot on this Mac. The result is stored as a
/// derived reading next to the image and is never sent anywhere; the Spark
/// reads the image itself.
public protocol ImageTextReading: Sendable {
  /// Stored with the reading so a later reader version can be told apart.
  var readerName: String { get }
  /// The recognized text, lines in reading order, or nil when none was found.
  func readText(imageData: Data) -> String?
}

/// Apple Vision text recognition, which runs on this Mac with the system's
/// own recognizer. Simplified Chinese and English with language correction;
/// lines are joined with newlines in Vision's reading order.
public struct VisionImageTextReader: ImageTextReading {
  public let readerName = "vision-text-v1"

  public init() {}

  public func readText(imageData: Data) -> String? {
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do { try handler.perform([request]) } catch { return nil }
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
  }
}
