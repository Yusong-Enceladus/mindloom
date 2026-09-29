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
/// chunk to 16 kHz mono through `BoundedPCMConverter` before it sees a sample,
/// and playback is speech. Keeping the wide original costs about five and a
/// half times the disk for audio nobody consumes at that rate, so a sealed
/// session's chunks are replaced by that same conversion, quantized to 16-bit
/// — the exact format the recognizer's evaluation set is stored in.
///
/// Chunks that were contiguous in time become one file, so a pause stays a
/// gap and the recorded duration does not change. Compaction runs only on a
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
      return SourceAudioCompactionOutcome(
        sessionID: sessionID,
        originalByteCount: originalBytes,
        compactedByteCount: originalBytes,
        runs: [],
        tracks: descriptors,
        alreadyCompact: true
      )
    }
    guard descriptors.allSatisfy({ $0.interleaved }) else {
      throw SourceAudioCompactionError.unsupportedSource
    }

    var runs: [CompactedSourceAudioRun] = []
    var written: [(url: URL, bytes: Data)] = []
    for track in descriptors.sorted(by: { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }) {
      let entries = manifest.committedChunks
        .filter { $0.trackID == track.id.rawValue.uuidString }
        .sorted { $0.sequence < $1.sequence }
      // The journal requires chunks/<track>-<sequence>.pcm and rejects anything
      // else on replay, so the runs continue the track's numbering instead of
      // restarting it: their files cannot then land on a source still to be
      // read, and a crash before the swap leaves every original in place.
      let nextSequence = (entries.map(\.sequence).max() ?? 0) + 1
      for (index, run) in contiguousRuns(entries).enumerated() {
        let converted = try await samples(of: run, track: track, journalRoot: journalRoot)
        guard !converted.isEmpty else { continue }
        let bytes = int16LittleEndian(converted)
        let sequence = nextSequence + UInt64(index)
        let relativePath = "chunks/\(track.id.rawValue.uuidString)-\(sequence).pcm"
        written.append((journalRoot.appendingPathComponent(relativePath), bytes))
        runs.append(
          CompactedSourceAudioRun(
            trackID: track.id,
            sequence: sequence,
            assetReference: assetReference(
              sessionID: sessionID, relativePath: relativePath),
            monotonicStartNanoseconds: run[0].monotonicStartNanoseconds,
            monotonicEndNanoseconds: end(of: run[run.count - 1]),
            frameCount: UInt32(converted.count),
            byteCount: UInt64(bytes.count),
            contentDigest: digest(bytes),
            replacedAssetReferences: run.map {
              assetReference(sessionID: sessionID, relativePath: $0.relativePath)
            }
          )
        )
      }
    }

    let compactedBytes = runs.reduce(UInt64(0)) { $0 + $1.byteCount }
    let compactTracks = descriptors.map(compacted(_:))
    guard !dryRun else {
      return SourceAudioCompactionOutcome(
        sessionID: sessionID,
        originalByteCount: originalBytes,
        compactedByteCount: compactedBytes,
        runs: runs,
        tracks: compactTracks,
        alreadyCompact: false
      )
    }

    // Write the replacements first: a crash here leaves the originals, their
    // manifest and their index untouched, and the next run starts over.
    for file in written {
      try ProductionDurableFileIO.atomicWrite(file.bytes, to: file.url)
    }
    let replaced = Set(manifest.committedChunks.map(\.relativePath))
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
    try write(manifest, to: journalRoot.appendingPathComponent("manifest.json"))
    // The commit log is replayed into the manifest on every open and rejects
    // an entry that disagrees with it, so it has to say the same thing.
    try writeCommitLog(
      manifest.committedChunks, to: journalRoot.appendingPathComponent("commits.jsonl"))
    try write(
      compacted(metadata, tracks: compactTracks),
      to: journalRoot.appendingPathComponent("production-metadata.json"))
    for path in replaced.subtracting(manifest.committedChunks.map(\.relativePath)) {
      try? fileManager.removeItem(at: journalRoot.appendingPathComponent(path))
    }

    return SourceAudioCompactionOutcome(
      sessionID: sessionID,
      originalByteCount: originalBytes,
      compactedByteCount: compactedBytes,
      runs: runs,
      tracks: compactTracks,
      alreadyCompact: false
    )
  }

  // MARK: - Reading

  /// The run's samples at 16 kHz mono, through the same converter the
  /// recognizer is fed by, so what is stored is what recognition already saw.
  private static func samples(
    of run: [AudioJournalChunkEntry],
    track: CaptureTrackDescriptor,
    journalRoot: URL
  ) async throws -> [Float] {
    let converter = try BoundedPCMConverter(maximumBufferedSourceFrames: 1 << 22)
    var output: [Float] = []
    for entry in run {
      let url = journalRoot.appendingPathComponent(entry.relativePath)
      guard let bytes = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
        throw SourceAudioCompactionError.sourceChunkMissing(entry.relativePath)
      }
      guard digest(bytes) == entry.contentDigest.lowercased() else {
        throw SourceAudioCompactionError.sourceChunkCorrupt(entry.relativePath)
      }
      let converted = try await converter.convert(
        CapturedPCMChunk(
          trackID: track.id,
          sequence: entry.sequence,
          monotonicStartNanoseconds: entry.monotonicStartNanoseconds,
          frameCount: UInt64(entry.frameCount),
          sampleRateHertz: entry.sampleRateHertz,
          channelCount: track.channelCount,
          encoding: track.encoding,
          interleaved: track.interleaved,
          bytes: bytes
        )
      )
      output.append(contentsOf: floats(converted.bytes))
    }
    return output
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

  private static func end(of entry: AudioJournalChunkEntry) -> UInt64 {
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

  private static func floats(_ data: Data) -> [Float] {
    var output = [Float]()
    output.reserveCapacity(data.count / 4)
    data.withUnsafeBytes { raw in
      for index in stride(from: 0, to: data.count - 3, by: 4) {
        let bits = raw.loadUnaligned(fromByteOffset: index, as: UInt32.self).littleEndian
        output.append(Float(bitPattern: bits))
      }
    }
    return output
  }

  // MARK: - Paths and files

  public static func journalRootURL(sessionID: SessionID, assetRoot: URL) -> URL {
    assetRoot
      .appendingPathComponent("sessions", isDirectory: true)
      .appendingPathComponent(
        sessionID.rawValue.uuidString.lowercased(), isDirectory: true)
      .appendingPathComponent("journal", isDirectory: true)
  }

  private static func assetPrefix(_ sessionID: SessionID) -> String {
    "sessions/\(sessionID.rawValue.uuidString.lowercased())/journal/"
  }

  private static func assetReference(sessionID: SessionID, relativePath: String) -> String {
    assetPrefix(sessionID) + relativePath
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func decode<Value: Decodable>(_: Value.Type, at url: URL) throws -> Value {
    try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
  }

  private static func write(_ value: some Encodable, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try ProductionDurableFileIO.atomicWrite(encoder.encode(value), to: url)
  }

  private static func writeCommitLog(
    _ entries: [AudioJournalChunkEntry], to url: URL
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = Data()
    for entry in entries {
      data.append(try encoder.encode(entry))
      data.append(0x0A)
    }
    try ProductionDurableFileIO.atomicWrite(data, to: url)
  }
}

extension Comparable {
  fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
