import BestASRAudio
import BestASRAudioJournalProbe
import BestASRDictation
import BestASRDomain
import CryptoKit
import Foundation

/// One stretch of a session's recording after compaction: the samples of a run
/// of chunks that were contiguous in time, in one file.
public struct CompactedSourceAudioRun: Equatable, Sendable {
  public let trackID: TrackID
  public let sequence: UInt64
  /// Relative to the asset root, as the audio index stores it.
  public let assetReference: String
  public let monotonicStartNanoseconds: UInt64
  public let monotonicEndNanoseconds: UInt64
  public let frameCount: UInt32
  public let byteCount: UInt64
  public let contentDigest: String
  /// What this run replaced, so the transcript provenance can be moved onto it.
  public let replacedAssetReferences: [String]
}

public struct SourceAudioCompactionOutcome: Equatable, Sendable {
  public let sessionID: SessionID
  public let originalByteCount: UInt64
  public let compactedByteCount: UInt64
  public let runs: [CompactedSourceAudioRun]
  public let tracks: [CaptureTrackDescriptor]
  /// True when the session already held nothing but compacted audio.
  public let alreadyCompact: Bool
}

public enum SourceAudioCompactionError: Error, Equatable, Sendable {
  case sessionNotSealed
  case sourceChunkMissing(String)
  case sourceChunkCorrupt(String)
  case unsupportedSource
}

/// Rewrites a finished dictation's recording in the one format everything
/// downstream already uses.
///
/// Capture stores what the microphone hands over — 44.1 kHz float32, about
/// 173 KB per second. Nothing reads it that way: recognition converts every
/// chunk to 16 kHz mono before it sees a sample, and playback is speech.
/// Keeping the wide original costs about five and a half times the disk for
/// audio nobody consumes at that rate, so a sealed session's chunks are
/// replaced by a 16 kHz mono copy, quantized to 16-bit — the exact format the
/// recognizer's evaluation set is stored in. The copy is made with a
/// band-limited resampler (`BandLimitedResampler`), so the 0–7 kHz band is
/// kept as recorded and nothing from above 8 kHz folds into it.
///
/// Chunks that were contiguous in time become one file (cut every five
/// minutes, `maximumPieceNanoseconds`), so a pause stays a gap and the
/// recorded duration does not change. Compaction runs only on a
/// sealed session, verifies every source digest before reading it, and writes
/// the replacements before deleting anything.
public enum SourceAudioCompaction {
  public static let sampleRateHertz: UInt32 = BoundedPCMConverter.targetSampleRateHertz
  public static let channelCount: UInt16 = 1
  public static let encoding: PCMEncoding = .int16LittleEndian

  /// Two chunks belong to the same run when the next one starts within this
  /// much of the previous one's end. Capture timestamps come from the audio
  /// clock, so consecutive blocks line up to well under a millisecond.
  static let runJoinToleranceNanoseconds: UInt64 = 1_000_000

  public static func compact(
    sessionID: SessionID,
    assetRoot: URL,
    dryRun: Bool = false,
    fileManager: FileManager = .default
  ) async throws -> SourceAudioCompactionOutcome {
    let (outcome, staged) = try await stage(
      sessionID: sessionID, assetRoot: assetRoot, dryRun: dryRun, fileManager: fileManager)
    try staged?.commit(fileManager: fileManager)
    return outcome
  }

  /// Builds and checks the rewritten journal beside the live one and leaves
  /// the exchange to the caller (nil when there is nothing to exchange: a
  /// dry run, or a session already compact).
  public static func stage(
    sessionID: SessionID,
    assetRoot: URL,
    dryRun: Bool = false,
    fileManager: FileManager = .default
  ) async throws -> (SourceAudioCompactionOutcome, StagedJournalRewrite?) {
    let journalRoot = journalRootURL(sessionID: sessionID, assetRoot: assetRoot)
    let metadata = try decode(
      ProductionAudioJournalMetadata.self,
      at: journalRoot.appendingPathComponent("production-metadata.json"))
    guard metadata.state == .sealed else { throw SourceAudioCompactionError.sessionNotSealed }
    var manifest = try decode(
      AudioJournalManifest.self, at: journalRoot.appendingPathComponent("manifest.json"))

    let descriptors = metadata.trackDescriptors ?? [descriptor(from: metadata)]
    let originalBytes = manifest.committedChunks.reduce(UInt64(0)) { $0 + $1.byteCount }
    guard descriptors.contains(where: { !isCompact($0) }) else {
      // Already rewritten. The runs it holds now are returned all the same:
      // a crash between the rewrite and the index update leaves the index
      // naming the old files, and applying these again repairs it.
      return (
        SourceAudioCompactionOutcome(
          sessionID: sessionID,
          originalByteCount: originalBytes,
          compactedByteCount: originalBytes,
          runs: currentRuns(manifest, sessionID: sessionID),
          tracks: descriptors,
          alreadyCompact: true
        ), nil
      )
    }
    guard descriptors.allSatisfy({ $0.interleaved }) else {
      throw SourceAudioCompactionError.unsupportedSource
    }

    // The replacement is built whole beside the live journal and exchanged
    // with it in one step (`JournalRewrite`): a crash at any point leaves
    // either the original recording or the rewritten one, never both. Each
    // piece is written as soon as it is converted, so memory holds one piece
    // (at most `maximumPieceNanoseconds` of 16 kHz audio) at a time.
    let staging =
      dryRun
      ? nil : try JournalRewrite.prepareStaging(journalRoot: journalRoot, fileManager: fileManager)
    var runs: [CompactedSourceAudioRun] = []
    let compactTracks = descriptors.map(compacted(_:))
    do {
      let ordered = descriptors.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
      for track in ordered {
        let entries = manifest.committedChunks
          .filter { $0.trackID == track.id.rawValue.uuidString }
          .sorted { $0.sequence < $1.sequence }
        // The journal requires chunks/<track>-<sequence>.pcm and rejects
        // anything else on replay, so the pieces continue the track's
        // numbering instead of restarting it: their files cannot then land on
        // a source still to be read.
        let nextSequence = (entries.map(\.sequence).max() ?? 0) + 1
        for (index, piece) in contiguousRuns(entries).flatMap(pieces(of:)).enumerated() {
          let converted = try await samples(of: piece, track: track, journalRoot: journalRoot)
          guard !converted.isEmpty else { continue }
          let bytes = int16LittleEndian(converted)
          let sequence = nextSequence + UInt64(index)
          let relativePath = "chunks/\(track.id.rawValue.uuidString)-\(sequence).pcm"
          if let staging {
            try ProductionDurableFileIO.atomicWrite(
              bytes, to: staging.appendingPathComponent(relativePath))
          }
          runs.append(
            CompactedSourceAudioRun(
              trackID: track.id,
              sequence: sequence,
              assetReference: assetReference(
                sessionID: sessionID, relativePath: relativePath),
              monotonicStartNanoseconds: piece[0].monotonicStartNanoseconds,
              monotonicEndNanoseconds: end(of: piece[piece.count - 1]),
              frameCount: UInt32(converted.count),
              byteCount: UInt64(bytes.count),
              contentDigest: digest(bytes),
              replacedAssetReferences: piece.map {
                assetReference(sessionID: sessionID, relativePath: $0.relativePath)
              }
            )
          )
        }
      }
    } catch {
      JournalRewrite.discardLeftover(journalRoot: journalRoot, fileManager: fileManager)
      throw error
    }

    let compactedBytes = runs.reduce(UInt64(0)) { $0 + $1.byteCount }
    let outcome = SourceAudioCompactionOutcome(
      sessionID: sessionID,
      originalByteCount: originalBytes,
      compactedByteCount: compactedBytes,
      runs: runs,
      tracks: compactTracks,
      alreadyCompact: false
    )
    guard let staging else { return (outcome, nil) }
    manifest.committedChunks = runs.map { run in
      AudioJournalChunkEntry(
        trackID: run.trackID.rawValue.uuidString,
        sequence: run.sequence,
        relativePath: String(run.assetReference.dropFirst(assetPrefix(sessionID).count)),
        monotonicStartNanoseconds: run.monotonicStartNanoseconds,
        sampleRateHertz: Self.sampleRateHertz,
        frameCount: run.frameCount,
        byteCount: run.byteCount,
        contentDigest: run.contentDigest
      )
    }
    do {
      // The commit log is replayed into the manifest on every open and
      // rejects an entry that disagrees with it, so it says the same thing.
      try JournalRewrite.finishStaging(
        staging, liveJournal: journalRoot, manifest: manifest,
        metadata: compacted(metadata, tracks: compactTracks), fileManager: fileManager)
    } catch {
      JournalRewrite.discardLeftover(journalRoot: journalRoot, fileManager: fileManager)
      throw error
    }
    return (outcome, StagedJournalRewrite(staging: staging, journalRoot: journalRoot))
  }

  // MARK: - Reading

  /// The run's samples at 16 kHz mono through `BandLimitedResampler`: the
  /// same mono mix the recognizer is fed (channels averaged, peaks bounded to
  /// full scale), low-passed before the rate is lowered so nothing above
  /// 8 kHz folds into what is kept (review 10-6 S4). The original is removed
  /// once this copy is in place, so this is the recording from then on.
  private static func samples(
    of run: [AudioJournalChunkEntry],
    track: CaptureTrackDescriptor,
    journalRoot: URL
  ) async throws -> [Float] {
    guard let rate = run.first?.sampleRateHertz, rate > 0, track.channelCount > 0,
      run.allSatisfy({ $0.sampleRateHertz == rate })
    else { throw SourceAudioCompactionError.unsupportedSource }
    var resampler = try BandLimitedResampler(sourceRateHertz: Int(rate))
    var output: [Float] = []
    output.reserveCapacity(
      BandLimitedResampler.outputCount(
        sourceFrames: run.reduce(0) { $0 + Int($1.frameCount) }, sourceRateHertz: Int(rate)))
    for entry in run {
      try Task.checkCancellation()
      let url = journalRoot.appendingPathComponent(entry.relativePath)
      guard let bytes = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
        throw SourceAudioCompactionError.sourceChunkMissing(entry.relativePath)
      }
      guard digest(bytes) == entry.contentDigest.lowercased() else {
        throw SourceAudioCompactionError.sourceChunkCorrupt(entry.relativePath)
      }
      let mono = try monoSamples(
        bytes, frames: Int(entry.frameCount), channels: Int(track.channelCount),
        encoding: track.encoding, chunk: entry.relativePath)
      output.append(contentsOf: resampler.append(mono))
    }
    output.append(contentsOf: resampler.finish())
    return output
  }

  /// One interleaved chunk as mono: channels averaged and bounded to full
  /// scale, as `BoundedPCMConverter` does for recognition.
  static func monoSamples(
    _ bytes: Data, frames: Int, channels: Int, encoding: PCMEncoding, chunk: String
  ) throws -> [Float] {
    let bytesPerSample = encoding == .float32LittleEndian ? 4 : 2
    guard bytes.count == frames * channels * bytesPerSample else {
      throw SourceAudioCompactionError.sourceChunkCorrupt(chunk)
    }
    var mono = [Float](repeating: 0, count: frames)
    try bytes.withUnsafeBytes { raw in
      for frame in 0..<frames {
        var sum: Float = 0
        for channel in 0..<channels {
          let offset = (frame * channels + channel) * bytesPerSample
          switch encoding {
          case .float32LittleEndian:
            let value = Float(
              bitPattern: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian)
            guard value.isFinite else { throw SourceAudioCompactionError.sourceChunkCorrupt(chunk) }
            sum += value
          case .int16LittleEndian:
            let bits = raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
            sum += Float(Int16(bitPattern: bits)) / Float(Int16.max)
          }
        }
        mono[frame] = min(1, max(-1, sum / Float(channels)))
      }
    }
    return mono
  }

  /// Chunks split at the gaps between them. Merging across a pause would turn
  /// silence the user never recorded into recorded duration.
  static func contiguousRuns(
    _ entries: [AudioJournalChunkEntry]
  ) -> [[AudioJournalChunkEntry]] {
    var runs: [[AudioJournalChunkEntry]] = []
    for entry in entries {
      guard let last = runs.last?.last else {
        runs.append([entry])
        continue
      }
      let expected = end(of: last)
      let difference =
        entry.monotonicStartNanoseconds > expected
        ? entry.monotonicStartNanoseconds - expected
        : expected - entry.monotonicStartNanoseconds
      if difference <= runJoinToleranceNanoseconds {
        runs[runs.count - 1].append(entry)
      } else {
        runs.append([entry])
      }
    }
    return runs
  }

  /// Longest a rewritten file may be. A meeting recorded without a pause is
  /// one run; kept as one file, every playback, export and Opus step would
  /// hold all of it in memory (a two-hour meeting is 460 MB of samples), so
  /// a run is cut into pieces of about five minutes, at its own chunk
  /// boundaries (no transcript range is split: each lies within a chunk).
  public static let maximumPieceNanoseconds: UInt64 = 300 * 1_000_000_000

  /// `run` in consecutive pieces of at most `maximumPieceNanoseconds` (one
  /// chunk longer than that is a piece of its own).
  public static func pieces(of run: [AudioJournalChunkEntry]) -> [[AudioJournalChunkEntry]] {
    var pieces: [[AudioJournalChunkEntry]] = []
    var current: [AudioJournalChunkEntry] = []
    for entry in run {
      if let first = current.first,
        end(of: entry) - min(end(of: entry), first.monotonicStartNanoseconds)
          > maximumPieceNanoseconds
      {
        pieces.append(current)
        current = []
      }
      current.append(entry)
    }
    if !current.isEmpty { pieces.append(current) }
    return pieces
  }

  public static func end(of entry: AudioJournalChunkEntry) -> UInt64 {
    entry.monotonicStartNanoseconds
      + UInt64(
        (Double(entry.frameCount) * 1_000_000_000 / Double(entry.sampleRateHertz)).rounded())
  }

  // MARK: - Formats

  static func isCompact(_ track: CaptureTrackDescriptor) -> Bool {
    track.sampleRateHertz == sampleRateHertz && track.channelCount == channelCount
      && track.encoding == encoding
  }

  private static func compacted(_ track: CaptureTrackDescriptor) -> CaptureTrackDescriptor {
    CaptureTrackDescriptor(
      id: track.id,
      role: track.role,
      deviceUID: track.deviceUID,
      sampleRateHertz: sampleRateHertz,
      channelCount: channelCount,
      encoding: encoding,
      interleaved: true
    )
  }

  private static func compacted(
    _ metadata: ProductionAudioJournalMetadata,
    tracks: [CaptureTrackDescriptor]
  ) -> ProductionAudioJournalMetadata {
    ProductionAudioJournalMetadata(
      schemaVersion: metadata.schemaVersion,
      sessionID: metadata.sessionID,
      trackID: metadata.trackID,
      descriptor: MicrophoneCaptureDescriptor(
        sessionID: metadata.descriptor.sessionID,
        deviceUID: metadata.descriptor.deviceUID,
        sampleRateHertz: sampleRateHertz,
        channelCount: channelCount,
        encoding: encoding,
        interleaved: true,
        tracks: metadata.descriptor.tracks == nil ? nil : tracks
      ),
      trackDescriptors: metadata.trackDescriptors == nil ? nil : tracks,
      state: metadata.state,
      timeline: metadata.timeline
    )
  }

  private static func descriptor(
    from metadata: ProductionAudioJournalMetadata
  ) -> CaptureTrackDescriptor {
    CaptureTrackDescriptor(
      id: metadata.trackID,
      role: .microphoneLocal,
      deviceUID: metadata.descriptor.deviceUID,
      sampleRateHertz: metadata.descriptor.sampleRateHertz,
      channelCount: metadata.descriptor.channelCount,
      encoding: metadata.descriptor.encoding,
      interleaved: metadata.descriptor.interleaved
    )
  }

  static func int16LittleEndian(_ samples: [Float]) -> Data {
    var data = Data(capacity: samples.count * 2)
    for sample in samples {
      let clamped = min(1, max(-1, sample))
      let value = Int16(
        (clamped * 32_767).rounded().clamped(to: -32_768...32_767))
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
  }

  /// The runs a session holds now, described the way a rewrite reports
  /// them (nothing replaced).
  static func currentRuns(
    _ manifest: AudioJournalManifest, sessionID: SessionID
  ) -> [CompactedSourceAudioRun] {
    manifest.committedChunks.sorted {
      ($0.trackID, $0.sequence) < ($1.trackID, $1.sequence)
    }.compactMap { entry in
      guard let track = UUID(uuidString: entry.trackID) else { return nil }
      return CompactedSourceAudioRun(
        trackID: TrackID(track),
        sequence: entry.sequence,
        assetReference: assetReference(sessionID: sessionID, relativePath: entry.relativePath),
        monotonicStartNanoseconds: entry.monotonicStartNanoseconds,
        monotonicEndNanoseconds: end(of: entry),
        frameCount: entry.frameCount,
        byteCount: entry.byteCount,
        contentDigest: entry.contentDigest,
        replacedAssetReferences: []
      )
    }
  }

  // MARK: - Paths and files

  public static func journalRootURL(sessionID: SessionID, assetRoot: URL) -> URL {
    assetRoot
      .appendingPathComponent("sessions", isDirectory: true)
      .appendingPathComponent(
        sessionID.rawValue.uuidString.lowercased(), isDirectory: true)
      .appendingPathComponent("journal", isDirectory: true)
  }

  static func assetPrefix(_ sessionID: SessionID) -> String {
    "sessions/\(sessionID.rawValue.uuidString.lowercased())/journal/"
  }

  static func assetReference(sessionID: SessionID, relativePath: String) -> String {
    assetPrefix(sessionID) + relativePath
  }

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func decode<Value: Decodable>(_: Value.Type, at url: URL) throws -> Value {
    try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
  }

}

extension Comparable {
  fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
