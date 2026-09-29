import BestASRDomain
import Foundation

/// Metadata for a block that has already crossed the source journal's durable
/// commit boundary. No audio or model output is passed to the history index.
public struct CommittedSourceAudioChunk: Equatable, Sendable {
  public let trackID: TrackID
  public let sequence: UInt64
  public let monotonicStartNanoseconds: UInt64
  public let frameCount: UInt64
  public let sampleRateHertz: UInt32
  public let contentDigest: SHA256Digest
  public let assetReference: PortableAssetReference

  public init(
    trackID: TrackID,
    sequence: UInt64,
    monotonicStartNanoseconds: UInt64,
    frameCount: UInt64,
    sampleRateHertz: UInt32,
    contentDigest: SHA256Digest,
    assetReference: PortableAssetReference
  ) {
    self.trackID = trackID
    self.sequence = sequence
    self.monotonicStartNanoseconds = monotonicStartNanoseconds
    self.frameCount = frameCount
    self.sampleRateHertz = sampleRateHertz
    self.contentDigest = contentDigest
    self.assetReference = assetReference
  }
}

/// A seal/recovery boundary can replay a committed prefix after interruption.
/// Implementations add missing metadata atomically, reject conflicting source
/// evidence, and never remove source bytes or resurrect explicitly deleted audio.
public protocol SourceAudioIndexRepositoryPort: Sendable {
  func indexCommittedSourceAudio(
    sessionID: SessionID,
    tracks: [CaptureTrackDescriptor],
    chunks: [CommittedSourceAudioChunk]
  ) async throws
}
