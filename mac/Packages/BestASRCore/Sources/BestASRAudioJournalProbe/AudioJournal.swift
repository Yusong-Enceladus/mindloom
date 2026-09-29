import CryptoKit
import Foundation

public final class AudioJournal {
  public let rootURL: URL
  public private(set) var manifest: AudioJournalManifest
  private var nextSequenceByTrack: [String: UInt64]

  public var manifestURL: URL {
    rootURL.appendingPathComponent("manifest.json")
  }

  private var chunksURL: URL {
    rootURL.appendingPathComponent("chunks", isDirectory: true)
  }

  private var stagingURL: URL {
    rootURL.appendingPathComponent("staging", isDirectory: true)
  }

  private var quarantineURL: URL {
    rootURL.appendingPathComponent("quarantine", isDirectory: true)
  }

  private var commitLogURL: URL {
    rootURL.appendingPathComponent("commits.jsonl")
  }

  private init(rootURL: URL, manifest: AudioJournalManifest) {
    self.rootURL = rootURL
    self.manifest = manifest
    var nextSequenceByTrack = Dictionary(
      uniqueKeysWithValues: manifest.tracks.map { ($0.trackID, UInt64(0)) }
    )
    for entry in manifest.committedChunks {
      nextSequenceByTrack[entry.trackID] = max(
        nextSequenceByTrack[entry.trackID] ?? 0,
        entry.sequence &+ 1
      )
    }
    self.nextSequenceByTrack = nextSequenceByTrack
  }

  public static func create(
    at rootURL: URL,
    sessionID: UUID,
    tracks: [AudioJournalTrack]
  ) throws -> AudioJournal {
    guard !FileManager.default.fileExists(atPath: rootURL.path) else {
      throw AudioJournalError.journalAlreadyExists
    }
    try validateTracks(tracks)
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true
    )
    for name in ["chunks", "staging", "quarantine"] {
      try FileManager.default.createDirectory(
        at: rootURL.appendingPathComponent(name, isDirectory: true),
        withIntermediateDirectories: false
      )
    }
    let manifest = AudioJournalManifest(
      sessionID: sessionID,
      state: .recording,
      tracks: tracks,
      committedChunks: [],
      recoveryIssues: [],
      gaps: []
    )
    let journal = AudioJournal(rootURL: rootURL, manifest: manifest)
    try journal.persistManifest()
    return journal
  }

  public static func open(at rootURL: URL) throws -> AudioJournal {
    let decoder = JSONDecoder()
    let manifestURL = rootURL.appendingPathComponent("manifest.json")
    let manifest: AudioJournalManifest
    do {
      manifest = try decoder.decode(
        AudioJournalManifest.self,
        from: Data(contentsOf: manifestURL)
      )
    } catch {
      throw AudioJournalError.invalidManifest
    }
    guard manifest.schemaVersion == 1 else {
      throw AudioJournalError.invalidManifest
    }
    try validateTracks(manifest.tracks)
    let replayed = try replayCommitLog(
      at: rootURL.appendingPathComponent("commits.jsonl"),
      into: manifest
    )
    return AudioJournal(rootURL: rootURL, manifest: replayed)
  }

  @discardableResult
  public func append(
    trackID: String,
    pcmBytes: Data,
    monotonicStartNanoseconds: UInt64,
    sampleRateHertz: UInt32,
    frameCount: UInt32,
    faultPoint: AudioJournalFaultPoint = .none
  ) throws -> CommittedInferenceRange {
    guard manifest.state == .recording else {
      throw AudioJournalError.journalNotRecording
    }
    guard manifest.tracks.contains(where: { $0.trackID == trackID }) else {
      throw AudioJournalError.unknownTrack(trackID)
    }
    let sequence = try nextSequence(for: trackID)
    let fileName = "\(trackID)-\(sequence).pcm"
    let temporaryURL = stagingURL.appendingPathComponent(
      "\(fileName).\(UUID().uuidString).partial"
    )
    let finalURL = chunksURL.appendingPathComponent(fileName)

    if faultPoint == .afterPartialStagingWrite {
      try DurableFileIO.write(
        pcmBytes.prefix(max(1, pcmBytes.count / 2)),
        to: temporaryURL
      )
      throw AudioJournalError.injectedCrash(faultPoint)
    }
    try DurableFileIO.write(pcmBytes, to: temporaryURL)
    if faultPoint == .afterStagingSync {
      throw AudioJournalError.injectedCrash(faultPoint)
    }

    try DurableFileIO.atomicRename(from: temporaryURL, to: finalURL)
    try DurableFileIO.synchronizeDirectory(chunksURL)
    if faultPoint == .afterChunkRename {
      throw AudioJournalError.injectedCrash(faultPoint)
    }

    let entry = AudioJournalChunkEntry(
      trackID: trackID,
      sequence: sequence,
      relativePath: "chunks/\(fileName)",
      monotonicStartNanoseconds: monotonicStartNanoseconds,
      sampleRateHertz: sampleRateHertz,
      frameCount: frameCount,
      byteCount: UInt64(pcmBytes.count),
      contentDigest: Self.digest(pcmBytes)
    )
    try appendCommit(entry)
    manifest.committedChunks.append(entry)
    nextSequenceByTrack[trackID] = sequence &+ 1
    if faultPoint == .afterManifestCommit {
      throw AudioJournalError.injectedCrash(faultPoint)
    }
    return CommittedInferenceRange(entry: entry)
  }

  public func availableInferenceRanges() -> [CommittedInferenceRange] {
    var seen: Set<String> = []
    return manifest.committedChunks.compactMap { entry in
      let key = "\(entry.trackID):\(entry.sequence)"
      guard seen.insert(key).inserted,
        (try? validate(entry: entry)) == true
      else { return nil }
      return CommittedInferenceRange(entry: entry)
    }
  }

  public func nextSequence(for trackID: String) throws -> UInt64 {
    guard manifest.tracks.contains(where: { $0.trackID == trackID }),
      let sequence = nextSequenceByTrack[trackID]
    else { throw AudioJournalError.unknownTrack(trackID) }
    return sequence
  }

  public func addTracks(_ tracks: [AudioJournalTrack]) throws {
    guard manifest.state == .recording else {
      throw AudioJournalError.journalNotRecording
    }
    let additions = tracks.filter { candidate in
      !manifest.tracks.contains(where: { $0.trackID == candidate.trackID })
    }
    guard !additions.isEmpty else { return }
    try Self.validateTracks(manifest.tracks + additions)
    manifest.tracks.append(contentsOf: additions)
    for track in additions { nextSequenceByTrack[track.trackID] = 0 }
    try persistManifest()
  }

  public func removeTracksIfEmpty(_ trackIDs: Set<String>) throws {
    guard manifest.state == .recording else {
      throw AudioJournalError.journalNotRecording
    }
    guard !trackIDs.isEmpty,
      manifest.committedChunks.allSatisfy({ !trackIDs.contains($0.trackID) })
    else { return }
    manifest.tracks.removeAll { trackIDs.contains($0.trackID) }
    for trackID in trackIDs { nextSequenceByTrack[trackID] = nil }
    try Self.validateTracks(manifest.tracks)
    try persistManifest()
  }

  public func readCommittedChunk(_ entry: AudioJournalChunkEntry) throws -> Data {
    guard try validate(entry: entry) else {
      throw AudioJournalError.invalidManifest
    }
    return try Data(contentsOf: rootURL.appendingPathComponent(entry.relativePath))
  }

  public func chunkURL(for entry: AudioJournalChunkEntry) -> URL {
    rootURL.appendingPathComponent(entry.relativePath)
  }

  @discardableResult
  public func recover() throws -> AudioJournalRecoveryReport {
    var issues: [AudioJournalRecoveryIssue] = []
    var gaps: [AudioJournalGap] = []
    var readableCount = 0
    var quarantineBytes: UInt64 = 0
    var seen: Set<String> = []

    for entry in manifest.committedChunks {
      let key = "\(entry.trackID):\(entry.sequence)"
      if !seen.insert(key).inserted {
        issues.append(
          AudioJournalRecoveryIssue(
            kind: .duplicateSequence,
            trackID: entry.trackID,
            sequence: entry.sequence
          )
        )
        gaps.append(gap(for: entry, reason: .duplicateSequence))
        continue
      }
      let url = chunkURL(for: entry)
      guard FileManager.default.fileExists(atPath: url.path) else {
        issues.append(
          AudioJournalRecoveryIssue(
            kind: .missingChunk,
            trackID: entry.trackID,
            sequence: entry.sequence
          )
        )
        gaps.append(gap(for: entry, reason: .missingChunk))
        continue
      }
      let data = try Data(contentsOf: url)
      if UInt64(data.count) != entry.byteCount {
        issues.append(
          AudioJournalRecoveryIssue(
            kind: .truncatedChunk,
            trackID: entry.trackID,
            sequence: entry.sequence,
            byteCount: UInt64(data.count)
          )
        )
        gaps.append(gap(for: entry, reason: .truncatedChunk))
        quarantineBytes += try quarantine(url)
      } else if Self.digest(data) != entry.contentDigest {
        issues.append(
          AudioJournalRecoveryIssue(
            kind: .corruptDigest,
            trackID: entry.trackID,
            sequence: entry.sequence,
            byteCount: UInt64(data.count)
          )
        )
        gaps.append(gap(for: entry, reason: .corruptDigest))
        quarantineBytes += try quarantine(url)
      } else {
        readableCount += 1
      }
    }

    let committedPaths = Set(manifest.committedChunks.map(\.relativePath))
    for url in try regularFiles(in: chunksURL) {
      let relativePath = "chunks/\(url.lastPathComponent)"
      guard !committedPaths.contains(relativePath) else { continue }
      let bytes = fileSize(url)
      issues.append(
        AudioJournalRecoveryIssue(
          kind: .orphanCommittedFile,
          byteCount: bytes
        )
      )
      quarantineBytes += try quarantine(url)
    }
    for url in try regularFiles(in: stagingURL) {
      let bytes = fileSize(url)
      issues.append(
        AudioJournalRecoveryIssue(
          kind: .orphanStagingFile,
          byteCount: bytes
        )
      )
      quarantineBytes += try quarantine(url)
    }

    manifest.recoveryIssues = issues
    manifest.gaps = gaps
    if !issues.isEmpty {
      manifest.state = .recoveryRequired
    }
    try persistManifest()
    return AudioJournalRecoveryReport(
      state: manifest.state,
      readableCommittedChunkCount: readableCount,
      quarantinedByteCount: quarantineBytes,
      issues: issues,
      gaps: gaps
    )
  }

  public func finalize() throws {
    guard manifest.state == .recording,
      manifest.recoveryIssues.isEmpty,
      manifest.gaps.isEmpty
    else { throw AudioJournalError.cannotFinalize }
    for track in manifest.tracks {
      let entries = manifest.committedChunks
        .filter { $0.trackID == track.trackID }
        .sorted { $0.sequence < $1.sequence }
      guard !entries.isEmpty else { throw AudioJournalError.cannotFinalize }
      for (offset, entry) in entries.enumerated() {
        guard entry.sequence == UInt64(offset), try validate(entry: entry) else {
          throw AudioJournalError.cannotFinalize
        }
      }
    }
    manifest.state = .finalized
    try persistManifest()
  }

  public func stopForDiskPressure() throws {
    guard manifest.state == .recording else {
      throw AudioJournalError.journalNotRecording
    }
    for entry in manifest.committedChunks {
      guard try validate(entry: entry) else {
        throw AudioJournalError.cannotFinalize
      }
    }
    manifest.state = .stoppedForDiskPressure
    try persistManifest()
  }

  /// Resumes only an intact journal that was deliberately stopped before a
  /// low-disk write. Recovery-required or finalized journals remain closed.
  public func resumeAfterDiskPressure() throws {
    guard manifest.state == .stoppedForDiskPressure,
      manifest.recoveryIssues.isEmpty,
      manifest.gaps.isEmpty
    else { throw AudioJournalError.journalNotRecording }
    for entry in manifest.committedChunks {
      guard try validate(entry: entry) else {
        throw AudioJournalError.cannotFinalize
      }
    }
    manifest.state = .recording
    try persistManifest()
  }

  private func persistManifest() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try DurableFileIO.atomicWrite(encoder.encode(manifest), to: manifestURL)
  }

  private func appendCommit(_ entry: AudioJournalChunkEntry) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var record = try encoder.encode(entry)
    record.append(0x0a)
    try DurableFileIO.append(record, to: commitLogURL)
  }

  private static func replayCommitLog(
    at url: URL,
    into snapshot: AudioJournalManifest
  ) throws -> AudioJournalManifest {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return snapshot
    }
    let data = try Data(contentsOf: url)
    guard let lastNewline = data.lastIndex(of: 0x0a) else {
      // A crash before the first commit record reached its newline leaves no
      // published block. Recovery will classify the renamed PCM as orphaned.
      try DurableFileIO.truncate(url, toByteCount: 0)
      return snapshot
    }
    let complete = data[data.startIndex...lastNewline]
    if complete.count < data.count {
      try DurableFileIO.truncate(url, toByteCount: complete.count)
    }
    let decoder = JSONDecoder()
    var result = snapshot
    var known: [String: AudioJournalChunkEntry] = [:]
    for entry in snapshot.committedChunks {
      let key = "\(entry.trackID):\(entry.sequence)"
      if known[key] == nil { known[key] = entry }
    }
    for line in complete.split(separator: 0x0a, omittingEmptySubsequences: true) {
      let entry: AudioJournalChunkEntry
      do {
        entry = try decoder.decode(AudioJournalChunkEntry.self, from: Data(line))
      } catch {
        throw AudioJournalError.invalidManifest
      }
      guard structurallyValid(entry, tracks: snapshot.tracks) else {
        throw AudioJournalError.invalidManifest
      }
      let key = "\(entry.trackID):\(entry.sequence)"
      if let existing = known[key] {
        guard existing == entry else { throw AudioJournalError.invalidManifest }
        continue
      }
      known[key] = entry
      result.committedChunks.append(entry)
    }
    return result
  }

  private static func structurallyValid(
    _ entry: AudioJournalChunkEntry,
    tracks: [AudioJournalTrack]
  ) -> Bool {
    entry.relativePath == "chunks/\(entry.trackID)-\(entry.sequence).pcm"
      && tracks.contains(where: { $0.trackID == entry.trackID })
      && entry.sampleRateHertz > 0
      && entry.frameCount > 0
      && entry.byteCount > 0
      && entry.contentDigest.count == 64
      && entry.contentDigest.allSatisfy { $0.isHexDigit }
  }

  private func validate(entry: AudioJournalChunkEntry) throws -> Bool {
    let url = chunkURL(for: entry)
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    let data = try Data(contentsOf: url)
    return UInt64(data.count) == entry.byteCount
      && Self.digest(data) == entry.contentDigest
  }

  private func gap(
    for entry: AudioJournalChunkEntry,
    reason: AudioJournalIssueKind
  ) -> AudioJournalGap {
    let duration = UInt64(
      (Double(entry.frameCount) * 1_000_000_000
        / Double(entry.sampleRateHertz)).rounded()
    )
    return AudioJournalGap(
      trackID: entry.trackID,
      sequence: entry.sequence,
      monotonicStartNanoseconds: entry.monotonicStartNanoseconds,
      durationNanoseconds: duration,
      reason: reason
    )
  }

  private func quarantine(_ url: URL) throws -> UInt64 {
    let bytes = fileSize(url)
    let destination = quarantineURL.appendingPathComponent(
      "\(url.lastPathComponent).\(UUID().uuidString).quarantine"
    )
    try FileManager.default.moveItem(at: url, to: destination)
    try DurableFileIO.synchronizeDirectory(quarantineURL)
    return bytes
  }

  private func regularFiles(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ).filter {
      (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
  }

  private func fileSize(_ url: URL) -> UInt64 {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey])
    return UInt64(max(0, values?.fileSize ?? 0))
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func validateTracks(_ tracks: [AudioJournalTrack]) throws {
    guard !tracks.isEmpty, Set(tracks.map(\.trackID)).count == tracks.count else {
      throw AudioJournalError.invalidManifest
    }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    for track in tracks
    where
      track.trackID.isEmpty
      || track.trackID.unicodeScalars.contains(where: { !allowed.contains($0) })
    {
      throw AudioJournalError.invalidTrackID(track.trackID)
    }
  }
}
