import BestASRAudioJournalProbe
import BestASRDictation
import BestASRDomain
import Foundation

public struct SourceAudioArchivalOutcome: Equatable, Sendable {
  public let sessionID: SessionID
  public let originalByteCount: UInt64
  public let archivedByteCount: UInt64
  /// Every chunk the session holds after archival, in the shape compaction
  /// reports, so the same index update applies.
  public let runs: [CompactedSourceAudioRun]
  public let tracks: [CaptureTrackDescriptor]
  public let alreadyArchived: Bool
  /// Lowest loudness correlation between a 16-bit chunk and its Opus copy
  /// (nil when every chunk was near-silent).
  public let minimumEnvelopeCorrelation: Double?
}

public enum SourceAudioArchivalError: Error, Equatable, Sendable {
  case sessionNotSealed
  /// The 16 kHz rewrite has to happen first: Opus is made from the 16-bit
  /// master, never from the capture format.
  case sessionNotCompact
  case sourceChunkMissing(String)
  case sourceChunkCorrupt(String)
  case verificationFailed(String)
}

/// Turns a sealed, already compacted recording (16 kHz, 16-bit) into the
/// form it is kept in after 30 days (`RetainedAudioArchiveFormat`): Apple
/// Lossless, which decodes to exactly the same samples, or Opus 24 kbps. That
/// file is then the recording the App keeps: playback, export and any later
/// re-recognition decode it (`RetainedAudioCodec.pcmBytes`).
///
/// Each 16-bit chunk becomes one `.lossless.caf` or `.caf` with the same
/// start time and frame count, numbered after the track's last sequence so no
/// new file can land on a source still to be read. Each file is decoded again
/// and checked against the chunk it replaces (lossless: the same samples
/// exactly; Opus: length within one frame, the same loudness over time)
/// before anything is swapped; the whole journal is then exchanged in one
/// step (`JournalRewrite`). A chunk that fails its digest, encodes to
/// something that does not decode back, or does not match, stops archival and
/// the recording stays exactly as it was. With `.opus`, chunks already kept
/// losslessly are taken from their exact decoding; an Opus chunk is never
/// rewritten again.
///
/// This is the only place a recording's PCM is removed without the user
/// asking, and only because the copy replacing it has just been checked
/// (PRD §15.6 as amended by §0.3 item 19; AGENTS.md raw-audio invariant).
public enum SourceAudioArchival {
  /// The chunks `format` still has to rewrite.
  static func isPending(
    _ entry: AudioJournalChunkEntry, for format: RetainedAudioArchiveFormat
  ) -> Bool {
    switch RetainedAudioContainer(reference: entry.relativePath) {
    case .pcm: true
    case .losslessCAF: format == .opus
    case .opusCAF, .compressedOriginal: false
    }
  }

  public static func archive(
    sessionID: SessionID,
    assetRoot: URL,
    format: RetainedAudioArchiveFormat = .lossless,
    dryRun: Bool = false,
    fileManager: FileManager = .default
  ) async throws -> SourceAudioArchivalOutcome {
    let (outcome, staged) = try await stage(
      sessionID: sessionID, assetRoot: assetRoot, format: format, dryRun: dryRun,
      fileManager: fileManager)
    try staged?.commit(fileManager: fileManager)
    return outcome
  }

  /// Builds and checks the archived journal beside the live one and leaves
  /// the exchange to the caller (nil when there is nothing to exchange).
  public static func stage(
    sessionID: SessionID,
    assetRoot: URL,
    format: RetainedAudioArchiveFormat = .lossless,
    dryRun: Bool = false,
    fileManager: FileManager = .default
  ) async throws -> (SourceAudioArchivalOutcome, StagedJournalRewrite?) {
    let journalRoot = SourceAudioCompaction.journalRootURL(
      sessionID: sessionID, assetRoot: assetRoot)
    let metadata = try SourceAudioCompaction.decode(
      ProductionAudioJournalMetadata.self,
      at: journalRoot.appendingPathComponent("production-metadata.json"))
    guard metadata.state == .sealed else { throw SourceAudioArchivalError.sessionNotSealed }
    var manifest = try SourceAudioCompaction.decode(
      AudioJournalManifest.self, at: journalRoot.appendingPathComponent("manifest.json"))
    let tracks =
      metadata.trackDescriptors ?? [
        CaptureTrackDescriptor(
          id: metadata.trackID, role: .microphoneLocal,
          deviceUID: metadata.descriptor.deviceUID,
          sampleRateHertz: metadata.descriptor.sampleRateHertz,
          channelCount: metadata.descriptor.channelCount,
          encoding: metadata.descriptor.encoding,
          interleaved: metadata.descriptor.interleaved)
      ]
    guard tracks.allSatisfy(SourceAudioCompaction.isCompact) else {
      throw SourceAudioArchivalError.sessionNotCompact
    }
    let originalBytes = manifest.committedChunks.reduce(UInt64(0)) { $0 + $1.byteCount }
    let pending = manifest.committedChunks.filter { isPending($0, for: format) }
    guard !pending.isEmpty else {
      return (
        SourceAudioArchivalOutcome(
          sessionID: sessionID, originalByteCount: originalBytes,
          archivedByteCount: originalBytes,
          runs: SourceAudioCompaction.currentRuns(manifest, sessionID: sessionID),
          tracks: tracks, alreadyArchived: true, minimumEnvelopeCorrelation: nil), nil
      )
    }

    let staging =
      dryRun
      ? nil
      : try JournalRewrite.prepareStaging(journalRoot: journalRoot, fileManager: fileManager)
    let scratch = fileManager.temporaryDirectory.appendingPathComponent(
      "archival-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: scratch) }

    do {
      var nextSequence: [String: UInt64] = [:]
      for entry in manifest.committedChunks {
        nextSequence[entry.trackID] = max(nextSequence[entry.trackID] ?? 0, entry.sequence + 1)
      }
      var replacement: [AudioJournalChunkEntry] = []
      var minimumCorrelation: Double?
      for entry in manifest.committedChunks.sorted(by: {
        ($0.trackID, $0.sequence) < ($1.trackID, $1.sequence)
      }) {
        guard isPending(entry, for: format) else {
          replacement.append(entry)
          if let staging {
            try fileManager.linkItem(
              at: journalRoot.appendingPathComponent(entry.relativePath),
              to: staging.appendingPathComponent(entry.relativePath))
          }
          continue
        }
        let source = journalRoot.appendingPathComponent(entry.relativePath)
        guard fileManager.fileExists(atPath: source.path) else {
          throw SourceAudioArchivalError.sourceChunkMissing(entry.relativePath)
        }
        // The 16-bit master: as stored, or the exact decoding of a chunk
        // kept losslessly. Either way checked against its digest first.
        let bytes: Data
        do {
          bytes = try RetainedAudioCodec.pcmBytes(
            at: source, expectedDigest: entry.contentDigest,
            frameCount: UInt64(entry.frameCount), encoding: .int16LittleEndian)
        } catch {
          throw SourceAudioArchivalError.sourceChunkCorrupt(entry.relativePath)
        }
        guard bytes.count == Int(entry.frameCount) * 2 else {
          throw SourceAudioArchivalError.sourceChunkCorrupt(entry.relativePath)
        }
        let master = RetainedAudioCodec.samples(int16LittleEndian: bytes)
        let sequence = nextSequence[entry.trackID] ?? (entry.sequence + 1)
        nextSequence[entry.trackID] = sequence + 1
        let relativePath = "chunks/\(entry.trackID)-\(sequence)\(format.fileSuffix)"
        let encoded = scratch.appendingPathComponent(
          "\(entry.trackID)-\(sequence)\(format.fileSuffix)")
        do {
          try RetainedAudioCodec.encode(samples: master, to: encoded, format: format)
          let correlation = try RetainedAudioCodec.verify(
            encoded: encoded, master: master, format: format)
          if !correlation.isNaN {
            minimumCorrelation = min(minimumCorrelation ?? correlation, correlation)
          }
        } catch {
          throw SourceAudioArchivalError.verificationFailed(
            "\(entry.relativePath): \(error)")
        }
        let archived = try Data(contentsOf: encoded)
        if let staging {
          try ProductionDurableFileIO.atomicWrite(
            archived, to: staging.appendingPathComponent(relativePath))
        }
        replacement.append(
          AudioJournalChunkEntry(
            trackID: entry.trackID, sequence: sequence, relativePath: relativePath,
            monotonicStartNanoseconds: entry.monotonicStartNanoseconds,
            sampleRateHertz: entry.sampleRateHertz, frameCount: entry.frameCount,
            byteCount: UInt64(archived.count),
            contentDigest: RetainedAudioCodec.digest(archived)))
      }
      manifest.committedChunks = replacement
      let runs = SourceAudioCompaction.currentRuns(manifest, sessionID: sessionID)
      let archivedBytes = replacement.reduce(UInt64(0)) { $0 + $1.byteCount }
      if let staging {
        try JournalRewrite.finishStaging(
          staging, liveJournal: journalRoot, manifest: manifest, metadata: metadata,
          fileManager: fileManager)
      }
      return (
        SourceAudioArchivalOutcome(
          sessionID: sessionID, originalByteCount: originalBytes,
          archivedByteCount: archivedBytes, runs: runs, tracks: tracks,
          alreadyArchived: false, minimumEnvelopeCorrelation: minimumCorrelation),
        staging.map { StagedJournalRewrite(staging: $0, journalRoot: journalRoot) }
      )
    } catch {
      JournalRewrite.discardLeftover(journalRoot: journalRoot, fileManager: fileManager)
      throw error
    }
  }
}
