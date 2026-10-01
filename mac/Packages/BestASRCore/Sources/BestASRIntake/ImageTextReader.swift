import BestASRDomain
import CoreGraphics
import CoreML
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
    do { try VisionTextRecognition.perform(request, on: image) } catch { return nil }
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
  }
}

/// Runs Vision text recognition for this Mac's readings and send copies.
/// Requests in this process run one at a time: two recognitions at once can
/// leave the Neural Engine path failing ("E5RT … code 13") for the rest of
/// the process, which kept a phone photo from being redacted and sent (v6
/// integration). When a request fails on the default device, it is tried
/// again on the GPU, then on the CPU; the caller sees an error only when all
/// of them fail.
enum VisionTextRecognition {
  private static let lock = NSLock()

  static func perform(_ request: VNRecognizeTextRequest, on image: CGImage) throws {
    try lock.withLock {
      do {
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return
      } catch {
        var last = error
        // The request's own list, else every device this Mac has (the list
        // itself can fail while the Neural Engine path is failing).
        let devices =
          (try? request.supportedComputeStageDevices[.main]) ?? MLComputeDevice.allComputeDevices
        let fallbacks = [devices.first(where: isGPU), devices.first(where: isCPU)]
        for device in fallbacks.compactMap({ $0 }) {
          request.setComputeDevice(device, for: .main)
          do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return
          } catch { last = error }
        }
        throw last
      }
    }
  }

  private static func isGPU(_ device: MLComputeDevice) -> Bool {
    if case .gpu = device { return true }
    return false
  }

  private static func isCPU(_ device: MLComputeDevice) -> Bool {
    if case .cpu = device { return true }
    return false
  }
}
