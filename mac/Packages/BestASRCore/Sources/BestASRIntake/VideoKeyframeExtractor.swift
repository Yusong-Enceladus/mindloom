import AVFoundation
import BestASRDomain
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Picks a video's keyframes on this Mac without a model: frames are looked
/// at every second (fewer for a long video), each reduced to a 16×16 grey
/// picture, and a frame whose picture differs from the one before by more
/// than `sceneChangeThreshold` starts a new scene. The first frame and scene
/// starts at least `minimumSpacing` apart are kept, the strongest changes
/// first when there are more than `maximumCount`, then returned in time
/// order as normalized JPEG/PNG images. Only local files are opened.
public struct VideoKeyframeExtractor: Sendable {
  public struct Keyframe: Equatable, Sendable {
    public let milliseconds: Int64
    public let image: ImageNormalizer.Result
  }

  public let maximumCount: Int
  public let minimumSpacingMilliseconds: Int64
  public let sampleIntervalMilliseconds: Int64
  public let maximumSamples: Int
  public let sceneChangeThreshold: Double
  public let normalizer: ImageNormalizer

  public init(
    maximumCount: Int = UserItemLimits.maximumVideoKeyframes,
    minimumSpacingMilliseconds: Int64 = UserItemLimits.minimumKeyframeSpacingMilliseconds,
    sampleIntervalMilliseconds: Int64 = 1_000, maximumSamples: Int = 240,
    sceneChangeThreshold: Double = 0.12, normalizer: ImageNormalizer = ImageNormalizer()
  ) {
    self.maximumCount = maximumCount
    self.minimumSpacingMilliseconds = minimumSpacingMilliseconds
    self.sampleIntervalMilliseconds = sampleIntervalMilliseconds
    self.maximumSamples = maximumSamples
    self.sceneChangeThreshold = sceneChangeThreshold
    self.normalizer = normalizer
  }

  /// One looked-at frame: when, and how different it is from the one before.
  struct Sample: Equatable {
    let milliseconds: Int64
    let change: Double
  }

  public func keyframes(fileURL: URL) async throws -> [Keyframe] {
    guard fileURL.isFileURL else { return [] }
    let asset = AVURLAsset(url: fileURL)
    guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { return [] }
    let duration = try await asset.load(.duration)
    let totalMS = Int64((duration.seconds.isFinite ? duration.seconds : 0) * 1_000)
    guard totalMS > 0 else { return [] }
    let interval = max(sampleIntervalMilliseconds, totalMS / Int64(max(1, maximumSamples)))

    let probe = AVAssetImageGenerator(asset: asset)
    probe.appliesPreferredTrackTransform = true
    probe.maximumSize = CGSize(width: 96, height: 96)
    let tolerance = CMTime(value: interval / 2, timescale: 1_000)
    probe.requestedTimeToleranceBefore = tolerance
    probe.requestedTimeToleranceAfter = tolerance
    var samples: [Sample] = []
    var previous: [UInt8]?
    var time: Int64 = 0
    while time < totalMS {
      defer { time += interval }
      guard let (image, _) = try? await probe.image(at: CMTime(value: time, timescale: 1_000)),
        let signature = FrameSignature.grey(image)
      else { continue }
      let change = previous.map { FrameSignature.difference($0, signature) } ?? 1
      samples.append(Sample(milliseconds: time, change: change))
      previous = signature
    }
    let chosen = Self.select(
      samples, threshold: sceneChangeThreshold, spacing: minimumSpacingMilliseconds,
      maximum: maximumCount)
    guard !chosen.isEmpty else { return [] }

    let full = AVAssetImageGenerator(asset: asset)
    full.appliesPreferredTrackTransform = true
    let side = CGFloat(normalizer.longSide)
    full.maximumSize = CGSize(width: side, height: side)
    full.requestedTimeToleranceBefore = .zero
    full.requestedTimeToleranceAfter = CMTime(value: 100, timescale: 1_000)
    var result: [Keyframe] = []
    for milliseconds in chosen {
      guard let (image, _) = try? await full.image(at: CMTime(value: milliseconds, timescale: 1_000)),
        let encoded = Self.jpeg(image),
        let normalized = try? normalizer.normalize(encoded)
      else { continue }
      result.append(Keyframe(milliseconds: milliseconds, image: normalized))
    }
    return result
  }

  /// The first sample, then scene changes at least `spacing` after the last
  /// kept one; above `maximum`, the strongest changes win. Time order.
  static func select(_ samples: [Sample], threshold: Double, spacing: Int64, maximum: Int)
    -> [Int64]
  {
    guard let first = samples.first, maximum > 0 else { return [] }
    var kept: [Sample] = [first]
    for sample in samples.dropFirst() where sample.change > threshold {
      if sample.milliseconds - kept[kept.count - 1].milliseconds >= spacing {
        kept.append(sample)
      } else if sample.change > kept[kept.count - 1].change, kept.count > 1 {
        // Two changes too close together: the stronger one stands for both.
        let before = kept.count >= 2 ? kept[kept.count - 2].milliseconds : Int64.min
        if sample.milliseconds - before >= spacing { kept[kept.count - 1] = sample }
      }
    }
    if kept.count > maximum {
      let rest = kept.dropFirst().sorted {
        $0.change != $1.change ? $0.change > $1.change : $0.milliseconds < $1.milliseconds
      }.prefix(maximum - 1)
      kept = [first] + rest.sorted { $0.milliseconds < $1.milliseconds }
    }
    return kept.map(\.milliseconds)
  }

  private static func jpeg(_ image: CGImage) -> Data? {
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? output as Data : nil
  }
}

extension IntakeProcessor {
  /// A video's keyframes as image items of its recording (`parent`),
  /// staged like any image; commit the rows, then `assetStore.commit`.
  /// Captured just after the recording so they sort under it.
  public func keyframeDrafts(
    _ keyframes: [VideoKeyframeExtractor.Keyframe], parent: SessionID, videoName: String,
    capturedAt: Date, source: ItemSourceApplication?
  ) -> [UserItemDraft] {
    keyframes.enumerated().compactMap { index, frame in
      let id = SessionID()
      let stamp = Self.clock(frame.milliseconds)
      let ext = frame.image.fileExtension
      do {
        let attachments = try assetStore.stage(
          sessionID: id,
          requests: [
            .init(
              role: .original, source: .data(frame.image.data),
              originalFilename: "keyframe-\(frame.milliseconds).\(ext)",
              mediaType: frame.image.mediaType, fileExtension: ext),
            .init(
              role: .normalizedImage, source: .data(frame.image.data),
              originalFilename: "normalized.\(ext)", mediaType: frame.image.mediaType,
              fileExtension: ext),
          ])
        return UserItemDraft(
          id: id, kind: .image,
          capturedAt: capturedAt.addingTimeInterval(Double(index + 1) * 0.001),
          source: source, sourceOrigin: .unknown, text: "",
          extractor: UserItemLimits.videoKeyframeExtractor,
          pixelWidth: frame.image.pixelWidth, pixelHeight: frame.image.pixelHeight,
          originalFilename: "\(videoName) · \(stamp)", attachments: attachments,
          uniformType: nil, parentSessionID: parent, frameMilliseconds: frame.milliseconds)
      } catch {
        assetStore.discard(sessionID: id)
        return nil
      }
    }
  }

  /// `m:ss` or `h:mm:ss`.
  public static func clock(_ milliseconds: Int64) -> String {
    let seconds = max(0, milliseconds / 1_000)
    let (h, m, s) = (seconds / 3_600, seconds / 60 % 60, seconds % 60)
    return h > 0
      ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
  }
}
