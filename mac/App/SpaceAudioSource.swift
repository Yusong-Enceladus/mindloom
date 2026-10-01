import AVFoundation
import BestASRAudioJournal
import BestASRDomain
import BestASRInference
import BestASRRemoteOrganizer
import Foundation
import MindloomSpaces

/// A meeting part's audio from the recording kept in this library (v8 C1):
/// every track of the recording (the room, the remote side) read back with
/// its digest checked, mixed to mono, exactly the part's time range cut out
/// (on the same clock as the part's transcript lines), AAC at 16 kHz. Never
/// the whole recording; the recording itself is not changed.
enum SpaceAudioSource {
  enum SourceError: Error {
    case noAudio
  }

  static let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
    "mindloom-audio-parts", isDirectory: true)

  /// The part's audio and the part with the recording's full length.
  @MainActor
  static func part(app: DictationAppModel, segment: SpaceSegmentRef) async throws -> (
    audio: Data, segment: SpaceSegmentRef
  ) {
    guard let repository = app.repository, let journal = app.journal,
      let uuid = UUID(uuidString: segment.parentItemID)
    else { throw SourceError.noAudio }
    let sessionID = SessionID(uuid)
    guard let base = try await repository.spaceShareTimeBase(sessionID: sessionID),
      base.startNS >= 0
    else { throw SourceError.noAudio }
    let descriptors = try await journal.sourceTrackDescriptors(sessionID: sessionID)
    let ranges = try await journal.committedAudioSnapshot(sessionID: sessionID)
    let root = journal.assetRootURL
    let startNS = UInt64(base.startNS)
    return try await Task.detached(priority: .userInitiated) {
      let windowStart = startNS + UInt64(segment.startMS) * 1_000_000
      let windowEnd = startNS + UInt64(segment.endMS) * 1_000_000
      var chunks: [SpaceAudioPart.Chunk] = []
      var lastEnd = UInt64(max(base.endNS, 0))
      for range in ranges {
        lastEnd = max(lastEnd, range.monotonicEndNanoseconds)
        guard range.monotonicEndNanoseconds > windowStart,
          range.monotonicStartNanoseconds < windowEnd,
          let descriptor = descriptors.first(where: { $0.id.rawValue == range.trackID })
        else { continue }
        let url = root.appendingPathComponent(range.assetReference)
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
          continue
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let buffer = try LocalSessionAudioPlayer.decoded(
          data, descriptor: descriptor, expectedDigest: range.contentDigest, frameOffset: 0)
        guard let channels = buffer.floatChannelData else { continue }
        let frames = Int(buffer.frameLength)
        let count = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<count {
          for frame in 0..<frames { mono[frame] += channels[channel][frame] / Float(count) }
        }
        chunks.append(
          .init(
            startNS: range.monotonicStartNanoseconds, endNS: range.monotonicEndNanoseconds,
            sampleRate: Int(range.sampleRateHertz), mono: mono))
      }
      guard !chunks.isEmpty, lastEnd > startNS else { throw SourceError.noAudio }
      let recordingMS = max(
        segment.recordingMS ?? 0, Int((lastEnd - startNS) / 1_000_000))
      let full = SpaceSegmentRef(
        parentItemID: segment.parentItemID, startMS: segment.startMS, endMS: segment.endMS,
        recordingMS: recordingMS)
      let audio = try SpaceAudioPart.make(
        chunks, recordingStartNS: startNS, segment: full, directory: scratch)
      return (audio, full)
    }.value
  }
}
