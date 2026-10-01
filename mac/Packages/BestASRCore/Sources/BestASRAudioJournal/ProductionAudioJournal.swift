import BestASRAudioJournalProbe
import BestASRDictation
import BestASRDomain
import BestASRInference
import CryptoKit
import Foundation

public enum ProductionAudioJournalError: Error, Equatable, Sendable {
  case committedSourceCannotBeCancelled
  case destinationExists
  case digestMismatch
  case fileOperation(String)
  case formatChanged
  case invalidFrameCount
  case invalidMetadata
  case invalidSequence(expected: UInt64, actual: UInt64)
  case inferenceDerivationInvalid
  case missingSession
  case sourceRangeMismatch
  case sourceChunkEmpty
  case unsupportedSourceExport
}

public enum ProductionAudioJournalState: String, Codable, Sendable {
  case recording
  case sealed
  case stoppedForDiskPressure
}

public struct ProductionAudioJournalMetadata: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let sessionID: SessionID
  public let trackID: TrackID
  public let descriptor: MicrophoneCaptureDescriptor
  public var trackDescriptors: [CaptureTrackDescriptor]?
  public var state: ProductionAudioJournalState
  public var timeline: [DictationTimelineMarker]

  public init(
    schemaVersion: Int = 1,
    sessionID: SessionID,
    trackID: TrackID,
    descriptor: MicrophoneCaptureDescriptor,
    trackDescriptors: [CaptureTrackDescriptor]? = nil,
    state: ProductionAudioJournalState,
    timeline: [DictationTimelineMarker]
  ) {
    self.schemaVersion = schemaVersion
    self.sessionID = sessionID
    self.trackID = trackID
    self.descriptor = descriptor
    self.trackDescriptors = trackDescriptors
    self.state = state
    self.timeline = timeline
  }
}

public struct ProductionAudioJournalRecoveryReport: Codable, Equatable, Sendable {
  public let sessionID: SessionID
  public let state: ProductionAudioJournalState
  public let readableCommittedChunkCount: Int
  public let quarantinedByteCount: UInt64
  public let issueCount: Int
  public let ranges: [AudioRangeInput]

  public init(
    sessionID: SessionID,
    state: ProductionAudioJournalState,
    readableCommittedChunkCount: Int,
    quarantinedByteCount: UInt64,
    issueCount: Int,
    ranges: [AudioRangeInput]
  ) {
    self.sessionID = sessionID
    self.state = state
    self.readableCommittedChunkCount = readableCommittedChunkCount
    self.quarantinedByteCount = quarantinedByteCount
    self.issueCount = issueCount
    self.ranges = ranges
  }
}

public struct StagedSessionDeletion: Sendable {
  public let sessionID: SessionID
  let originalURL: URL
  let stagedURL: URL
}

public struct ProductionSourceTrackExport: Codable, Equatable, Sendable {
  public let sessionID: SessionID
  public let trackID: TrackID
  public let role: SourceTrackRole
  public let sampleRateHertz: UInt32
  public let channelCount: UInt16
  public let frameCount: UInt64
  public let byteCount: UInt64
  public let destinationDigest: BestASRDomain.SHA256Digest

  public init(
    sessionID: SessionID,
    trackID: TrackID,
    role: SourceTrackRole,
    sampleRateHertz: UInt32,
    channelCount: UInt16,
    frameCount: UInt64,
    byteCount: UInt64,
    destinationDigest: BestASRDomain.SHA256Digest
  ) {
    self.sessionID = sessionID
    self.trackID = trackID
    self.role = role
    self.sampleRateHertz = sampleRateHertz
    self.channelCount = channelCount
    self.frameCount = frameCount
    self.byteCount = byteCount
    self.destinationDigest = destinationDigest
  }
}

public struct ProductionAudioTrackProgress: Codable, Equatable, Sendable {
  public let trackID: TrackID
  public let committedChunkCount: UInt64
  public let committedFrameCount: UInt64

  public init(
    trackID: TrackID,
    committedChunkCount: UInt64,
    committedFrameCount: UInt64
  ) {
    self.trackID = trackID
    self.committedChunkCount = committedChunkCount
    self.committedFrameCount = committedFrameCount
  }
}

public actor ProductionAudioJournal: DictationJournalPort,
  DictationMutableTrackJournalPort,
  DictationCommittedAudioPort
{
  public nonisolated let assetRootURL: URL
  let inferenceWindowNanoseconds: UInt64
  private let sourceIndex: (any SourceAudioIndexRepositoryPort)?

  private struct OpenContext {
    let journal: AudioJournal
    var metadata: ProductionAudioJournalMetadata
  }

  private var contexts: [SessionID: OpenContext] = [:]
  var inferenceLeaseCounts: [String: Int] = [:]
  var inferenceBuilds: Set<String> = []
  var inferenceBuildWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  let fileManager: FileManager
  private let diskSpacePolicy: CaptureDiskSpacePolicy
  private let diskSpaceMonitor = VolumeDiskSpaceMonitor()

  public init(
    assetRootURL: URL,
    inferenceWindowNanoseconds: UInt64 = 30_000_000_000,
    sourceIndex: (any SourceAudioIndexRepositoryPort)? = nil,
    fileManager: FileManager = .default
  ) throws {
    guard
      inferenceWindowNanoseconds >= 1_000_000_000,
      inferenceWindowNanoseconds <= 60_000_000_000
    else {
      throw ProductionAudioJournalError.invalidMetadata
    }
    self.assetRootURL = assetRootURL
    self.inferenceWindowNanoseconds = inferenceWindowNanoseconds
    self.sourceIndex = sourceIndex
    self.fileManager = fileManager
    diskSpacePolicy = try CaptureDiskSpacePolicy()
    let sessionsRoot = assetRootURL.appendingPathComponent(
      "sessions",
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: sessionsRoot,
      withIntermediateDirectories: true
    )
    // Inference derivatives are reproducible scratch, never source evidence.
    // A terminated process cannot hold a valid lease, so remove only these
    // stale directories on launch before accepting new inference work.
    for sessionRoot
      in (try? fileManager.contentsOfDirectory(
        at: sessionsRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )) ?? []
    {
      let inferenceRoot = sessionRoot.appendingPathComponent(
        "inference",
        isDirectory: true
      )
      try? fileManager.removeItem(at: inferenceRoot)
    }
  }

  public func create(
    sessionID: SessionID,
    descriptor: MicrophoneCaptureDescriptor
  ) async throws {
    guard descriptor.sessionID == sessionID else {
      throw ProductionAudioJournalError.invalidMetadata
    }
    let explicitTracks = descriptor.tracks ?? []
    guard explicitTracks.map(\.id).count == Set(explicitTracks.map(\.id)).count,
      explicitTracks.allSatisfy({
        $0.sampleRateHertz > 0 && $0.channelCount > 0
      })
    else { throw ProductionAudioJournalError.invalidMetadata }
    let trackID = explicitTracks.first?.id ?? TrackID()
    let journalTracks =
      explicitTracks.isEmpty
      ? [
        AudioJournalTrack(
          trackID: trackID.rawValue.uuidString,
          role: SourceTrackRole.microphoneLocal.rawValue
        )
      ]
      : explicitTracks.map {
        AudioJournalTrack(
          trackID: $0.id.rawValue.uuidString,
          role: $0.role.rawValue
        )
      }
    let root = journalRoot(for: sessionID)
    let journal = try AudioJournal.create(
      at: root,
      sessionID: sessionID.rawValue,
      tracks: journalTracks
    )
    let metadata = ProductionAudioJournalMetadata(
      sessionID: sessionID,
      trackID: trackID,
      descriptor: descriptor,
      trackDescriptors: explicitTracks.isEmpty ? nil : explicitTracks,
      state: .recording,
      timeline: []
    )
    try persist(metadata, at: root)
    contexts[sessionID] = OpenContext(journal: journal, metadata: metadata)
  }

  public func append(
    sessionID: SessionID,
    chunk: CapturedPCMChunk
  ) async throws {
    try append(sessionID: sessionID, chunk: chunk, faultPoint: .none)
  }

  public func addCaptureTracks(
    sessionID: SessionID,
    tracks: [CaptureTrackDescriptor]
  ) async throws {
    guard !tracks.isEmpty else { return }
    var context = try context(for: sessionID)
    guard context.metadata.state == .recording else {
      throw ProductionAudioJournalError.invalidMetadata
    }
    let existing: [CaptureTrackDescriptor]
    if let trackDescriptors = context.metadata.trackDescriptors {
      existing = trackDescriptors
    } else {
      existing = [
        try formatDescriptor(
          for: context.metadata.trackID,
          metadata: context.metadata
        )
      ]
    }
    let additions = tracks.filter { candidate in
      !existing.contains(where: { $0.id == candidate.id })
    }
    guard !additions.isEmpty,
      additions.allSatisfy({ $0.sampleRateHertz > 0 && $0.channelCount > 0 })
    else { return }
    try context.journal.addTracks(
      additions.map {
        AudioJournalTrack(trackID: $0.id.rawValue.uuidString, role: $0.role.rawValue)
      })
    context.metadata.trackDescriptors = existing + additions
    try persist(context.metadata, at: context.journal.rootURL)
    contexts[sessionID] = context
  }

  public func removeCaptureTracksIfEmpty(
    sessionID: SessionID,
    trackIDs: Set<TrackID>
  ) async throws {
    guard !trackIDs.isEmpty else { return }
    var context = try context(for: sessionID)
    let rawIDs = Set(trackIDs.map { $0.rawValue.uuidString })
    try context.journal.removeTracksIfEmpty(rawIDs)
    context.metadata.trackDescriptors?.removeAll { trackIDs.contains($0.id) }
    try persist(context.metadata, at: context.journal.rootURL)
    contexts[sessionID] = context
  }

  public func append(
    sessionID: SessionID,
    chunk: CapturedPCMChunk,
    faultPoint: AudioJournalFaultPoint
  ) throws {
    var context = try context(for: sessionID)
    guard context.metadata.state == .recording else {
      throw ProductionAudioJournalError.invalidMetadata
    }
    let trackID = chunk.trackID ?? context.metadata.trackID
    let descriptor = try formatDescriptor(for: trackID, metadata: context.metadata)
    guard descriptor.sampleRateHertz == chunk.sampleRateHertz,
      descriptor.channelCount == chunk.channelCount,
      descriptor.encoding == chunk.encoding,
      descriptor.interleaved == chunk.interleaved
    else {
      throw ProductionAudioJournalError.formatChanged
    }
    guard !chunk.bytes.isEmpty else {
      throw ProductionAudioJournalError.sourceChunkEmpty
    }
    guard chunk.frameCount > 0, chunk.frameCount <= UInt64(UInt32.max) else {
      throw ProductionAudioJournalError.invalidFrameCount
    }
    let expected = try context.journal.nextSequence(
      for: trackID.rawValue.uuidString
    )
    guard chunk.sequence == expected else {
      throw ProductionAudioJournalError.invalidSequence(
        expected: expected,
        actual: chunk.sequence
      )
    }
    // Capacity checks are intentionally amortized: capture callbacks remain
    // cheap, while a hard stop still occurs before another bounded chunk write.
    if expected % 64 == 0 {
      let available = try diskSpaceMonitor.availableBytes(at: assetRootURL)
      if diskSpacePolicy.evaluate(availableBytes: available).state == .hardStop {
        try context.journal.stopForDiskPressure()
        context.metadata.state = .stoppedForDiskPressure
        try persist(context.metadata, at: context.journal.rootURL)
        contexts[sessionID] = context
        throw ProductionAudioJournalError.fileOperation("disk-hard-stop")
      }
    }
    _ = try context.journal.append(
      trackID: trackID.rawValue.uuidString,
      pcmBytes: chunk.bytes,
      monotonicStartNanoseconds: chunk.monotonicStartNanoseconds,
      sampleRateHertz: chunk.sampleRateHertz,
      frameCount: UInt32(chunk.frameCount),
      faultPoint: faultPoint
    )
    contexts[sessionID] = context
  }

  public func diskSpaceDecision() throws -> CaptureDiskSpaceDecision {
    diskSpacePolicy.evaluate(
      availableBytes: try diskSpaceMonitor.availableBytes(at: assetRootURL)
    )
  }

  public func append(
    sessionID: SessionID,
    marker: DictationTimelineMarker
  ) async throws {
    var context = try context(for: sessionID)
    guard
      context.metadata.state == .recording
        || context.metadata.state == .stoppedForDiskPressure
    else {
      throw ProductionAudioJournalError.invalidMetadata
    }
    context.metadata.timeline.append(marker)
    try persist(context.metadata, at: context.journal.rootURL)
    contexts[sessionID] = context
  }

  public func seal(sessionID: SessionID) async throws -> [AudioRangeInput] {
    var context = try context(for: sessionID)
    if context.metadata.state == .sealed {
      try await synchronizeSourceIndex(sessionID: sessionID)
      return try ranges(for: context)
    }
    if context.metadata.state == .stoppedForDiskPressure {
      try context.journal.resumeAfterDiskPressure()
      context.metadata.state = .recording
    }
    try context.journal.finalize()
    context.metadata.state = .sealed
    try persist(context.metadata, at: context.journal.rootURL)
    contexts[sessionID] = context
    try await synchronizeSourceIndex(sessionID: sessionID)
    return try ranges(for: context)
  }

  /// Repairs the source metadata projection from the committed journal, without
  /// running inference, rewriting the journal or loading the source audio bytes.
  /// This deliberately stays outside the high-frequency capture append path.
  public func synchronizeSourceIndex(sessionID: SessionID) async throws {
    guard let sourceIndex else { return }
    let context = try context(for: sessionID)
    let tracks = try sourceTrackDescriptors(sessionID: sessionID)
    let chunks = try context.journal.manifest.committedChunks.map { entry in
      guard let trackID = UUID(uuidString: entry.trackID) else {
        throw ProductionAudioJournalError.invalidMetadata
      }
      return CommittedSourceAudioChunk(
        trackID: TrackID(trackID),
        sequence: entry.sequence,
        monotonicStartNanoseconds: entry.monotonicStartNanoseconds,
        frameCount: UInt64(entry.frameCount),
        sampleRateHertz: entry.sampleRateHertz,
        contentDigest: try BestASRDomain.SHA256Digest(entry.contentDigest),
        assetReference: try PortableAssetReference(
          relativePath: relativeAssetPath(
            sessionID: sessionID,
            journalRelativePath: entry.relativePath
          )
        )
      )
    }
    try await sourceIndex.indexCommittedSourceAudio(
      sessionID: sessionID, tracks: tracks, chunks: chunks
    )
  }

  public func committedAudioSnapshot(
    sessionID: SessionID
  ) async throws -> [AudioRangeInput] {
    try ranges(for: context(for: sessionID))
  }

  public func stopForDiskPressure(sessionID: SessionID) throws {
    var context = try context(for: sessionID)
    try context.journal.stopForDiskPressure()
    context.metadata.state = .stoppedForDiskPressure
    try persist(context.metadata, at: context.journal.rootURL)
    contexts[sessionID] = context
  }

  public func resumeAfterDiskPressure(sessionID: SessionID) throws {
    var context = try context(for: sessionID)
    guard context.metadata.state == .stoppedForDiskPressure else {
      throw ProductionAudioJournalError.invalidMetadata
    }
    try context.journal.resumeAfterDiskPressure()
    context.metadata.state = .recording
    try persist(context.metadata, at: context.journal.rootURL)
    contexts[sessionID] = context
  }

  public func resumeAfterRecoverableStop(sessionID: SessionID) async throws {
    let state = try context(for: sessionID).metadata.state
    switch state {
    case .recording:
      return
    case .stoppedForDiskPressure:
      try resumeAfterDiskPressure(sessionID: sessionID)
    case .sealed:
      throw ProductionAudioJournalError.invalidMetadata
    }
  }

  public func cancelEphemeral(sessionID: SessionID) async throws {
    let context = try context(for: sessionID)
    guard context.metadata.state != .sealed,
      context.journal.manifest.state != .finalized
    else {
      throw ProductionAudioJournalError.committedSourceCannotBeCancelled
    }
    let root = sessionRoot(for: sessionID)
    contexts[sessionID] = nil
    if fileManager.fileExists(atPath: root.path) {
      try fileManager.removeItem(at: root)
    }
  }

  public func recover(
    sessionID: SessionID
  ) throws -> ProductionAudioJournalRecoveryReport {
    var context = try openContext(for: sessionID)
    let recovery = try context.journal.recover()
    if context.journal.manifest.state == .finalized,
      context.metadata.state != .sealed
    {
      context.metadata.state = .sealed
      try persist(context.metadata, at: context.journal.rootURL)
    }
    contexts[sessionID] = context
    return ProductionAudioJournalRecoveryReport(
      sessionID: sessionID,
      state: context.metadata.state,
      readableCommittedChunkCount: recovery.readableCommittedChunkCount,
      quarantinedByteCount: recovery.quarantinedByteCount,
      issueCount: recovery.issues.count,
      ranges: try ranges(for: context)
    )
  }

  public func recoveryStatus(
    sessionID: SessionID
  ) async throws -> DictationJournalRecoveryStatus {
    let report = try recover(sessionID: sessionID)
    try await synchronizeSourceIndex(sessionID: sessionID)
    return DictationJournalRecoveryStatus(
      committedChunkCount: report.readableCommittedChunkCount,
      issueCount: report.issueCount,
      sealed: report.state == .sealed
    )
  }

  public func metadata(
    sessionID: SessionID
  ) throws -> ProductionAudioJournalMetadata {
    try context(for: sessionID).metadata
  }

  public func journalRootURL(sessionID: SessionID) -> URL {
    journalRoot(for: sessionID)
  }

  /// Rewrites a sealed session's recording (see `SourceAudioCompaction`) and
  /// forgets what this journal had cached for it.
  ///
  /// Compaction has to go through here rather than run on the files directly:
  /// an open journal keeps each session's manifest in memory, so rewriting
  /// behind its back leaves it handing out ranges whose files are gone — the
  /// recording still plays until the App is restarted, and then cannot be
  /// played at all. Inside the actor nothing can read the session while it is
  /// being replaced, and the next read opens what was written.
  public func compactSealedRecording(
    sessionID: SessionID
  ) async throws -> SourceAudioCompactionOutcome {
    let outcome = try await SourceAudioCompaction.compact(
      sessionID: sessionID, assetRoot: assetRootURL)
    guard !outcome.alreadyCompact else { return outcome }
    contexts[sessionID] = nil
    // Open it once now, so a recording that cannot be read back is a failure
    // here and not the next time the user presses play.
    _ = try openContext(for: sessionID)
    return outcome
  }

  public func sourceTrackDescriptors(
    sessionID: SessionID
  ) throws -> [CaptureTrackDescriptor] {
    let context = try context(for: sessionID)
    if let tracks = context.metadata.trackDescriptors { return tracks }
    return [
      try formatDescriptor(
        for: context.metadata.trackID,
        metadata: context.metadata
      )
    ]
  }

  public func trackProgress(
    sessionID: SessionID,
    trackID: TrackID
  ) throws -> ProductionAudioTrackProgress {
    let entries = try context(for: sessionID).journal.manifest.committedChunks
      .filter { $0.trackID == trackID.rawValue.uuidString }
    return ProductionAudioTrackProgress(
      trackID: trackID,
      committedChunkCount: UInt64(entries.count),
      committedFrameCount: entries.reduce(UInt64(0)) {
        $0 + UInt64($1.frameCount)
      }
    )
  }

  /// Exports the exact committed PCM samples for one retained capture track.
  /// The source chunks are authenticated before they are copied and are never
  /// rewritten. A time selection is represented by a new lossless WAVE file;
  /// it does not trim or replace any source asset in History.
  public func exportSourceTrackAsWave(
    sessionID: SessionID,
    trackID: TrackID,
    to destination: URL,
    monotonicRange: Range<UInt64>? = nil
  ) throws -> ProductionSourceTrackExport {
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw ProductionAudioJournalError.destinationExists
    }
    let context = try context(for: sessionID)
    let descriptor = try formatDescriptor(
      for: trackID,
      metadata: context.metadata
    )
    guard descriptor.interleaved else {
      throw ProductionAudioJournalError.unsupportedSourceExport
    }
    let bytesPerSample: UInt64 =
      switch descriptor.encoding {
      case .float32LittleEndian: 4
      case .int16LittleEndian: 2
      }
    let bytesPerFrame = bytesPerSample * UInt64(descriptor.channelCount)
    guard bytesPerFrame > 0 else {
      throw ProductionAudioJournalError.unsupportedSourceExport
    }
    let entries = context.journal.manifest.committedChunks
      .filter { $0.trackID == trackID.rawValue.uuidString }
      .sorted { $0.sequence < $1.sequence }
    guard !entries.isEmpty else {
      throw ProductionAudioJournalError.sourceChunkEmpty
    }

    struct Slice {
      let source: URL
      let digest: String
      let byteOffset: UInt64
      let byteCount: UInt64
      let frameCount: UInt64
    }
    var slices: [Slice] = []
    var totalFrames: UInt64 = 0
    var totalPCMBytes: UInt64 = 0
    for entry in entries {
      guard entry.sampleRateHertz == descriptor.sampleRateHertz else {
        throw ProductionAudioJournalError.formatChanged
      }
      let entryDuration = UInt64(
        (Double(entry.frameCount) * 1_000_000_000
          / Double(entry.sampleRateHertz)).rounded()
      )
      let entryStart = entry.monotonicStartNanoseconds
      let entryEnd = entryStart + entryDuration
      let selectedStart = max(entryStart, monotonicRange?.lowerBound ?? entryStart)
      let selectedEnd = min(entryEnd, monotonicRange?.upperBound ?? entryEnd)
      guard selectedEnd > selectedStart else { continue }
      let firstFrame = min(
        UInt64(entry.frameCount),
        UInt64(
          (Double(selectedStart - entryStart)
            * Double(entry.sampleRateHertz) / 1_000_000_000).rounded(.down)
        )
      )
      let endFrame = min(
        UInt64(entry.frameCount),
        UInt64(
          (Double(selectedEnd - entryStart)
            * Double(entry.sampleRateHertz) / 1_000_000_000).rounded(.up)
        )
      )
      guard endFrame > firstFrame else { continue }
      let frameCount = endFrame - firstFrame
      let byteOffset = firstFrame * bytesPerFrame
      let byteCount = frameCount * bytesPerFrame
      slices.append(
        Slice(
          source: context.journal.rootURL.appendingPathComponent(entry.relativePath),
          digest: entry.contentDigest,
          byteOffset: byteOffset,
          byteCount: byteCount,
          frameCount: frameCount
        )
      )
      totalFrames += frameCount
      totalPCMBytes += byteCount
    }
    guard !slices.isEmpty, totalPCMBytes <= UInt64(UInt32.max) - 36 else {
      throw ProductionAudioJournalError.unsupportedSourceExport
    }

    let parent = destination.deletingLastPathComponent()
    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    let staging = parent.appendingPathComponent(
      ".\(UUID().uuidString).source-audio-exporting"
    )
    defer { try? fileManager.removeItem(at: staging) }
    guard fileManager.createFile(atPath: staging.path, contents: nil) else {
      throw ProductionAudioJournalError.fileOperation("create-export")
    }
    let output = try FileHandle(forWritingTo: staging)
    do {
      try output.write(
        contentsOf: Self.waveHeader(
          encoding: descriptor.encoding,
          sampleRateHertz: descriptor.sampleRateHertz,
          channelCount: descriptor.channelCount,
          pcmByteCount: UInt32(totalPCMBytes)
        ))
      for slice in slices {
        let sourceDigest = try Self.fileDigest(slice.source)
        guard sourceDigest == slice.digest.lowercased() else {
          throw ProductionAudioJournalError.digestMismatch
        }
        let input = try FileHandle(forReadingFrom: slice.source)
        defer { try? input.close() }
        try input.seek(toOffset: slice.byteOffset)
        var remaining = slice.byteCount
        while remaining > 0 {
          try Task.checkCancellation()
          let count = Int(min(1_048_576, remaining))
          let data = try input.read(upToCount: count) ?? Data()
          guard !data.isEmpty else {
            throw ProductionAudioJournalError.invalidFrameCount
          }
          try output.write(contentsOf: data)
          remaining -= UInt64(data.count)
        }
      }
      try output.synchronize()
      try output.close()
      try fileManager.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: staging.path
      )
      try fileManager.moveItem(at: staging, to: destination)
    } catch {
      try? output.close()
      throw error
    }
    return ProductionSourceTrackExport(
      sessionID: sessionID,
      trackID: trackID,
      role: descriptor.role,
      sampleRateHertz: descriptor.sampleRateHertz,
      channelCount: descriptor.channelCount,
      frameCount: totalFrames,
      byteCount: totalPCMBytes + 44,
      destinationDigest: try BestASRDomain.SHA256Digest(
        Self.fileDigest(destination)
      )
    )
  }

  /// Called only after an explicit user deletion. When retained assets exist,
  /// the whole session directory is first atomically moved aside so the
  /// database transaction can roll it back if any referential check fails.
  /// A session can legitimately have no directory when capture failed before
  /// the first journal was created; in that case the audio side of deletion is
  /// already complete and the database record must still remain deletable.
  public func stageExplicitDeletion(
    sessionID: SessionID
  ) throws -> StagedSessionDeletion? {
    let original = sessionRoot(for: sessionID)
    contexts[sessionID] = nil
    guard fileManager.fileExists(atPath: original.path) else { return nil }
    let stagingRoot = assetRootURL.appendingPathComponent(
      ".explicit-deletion-staging",
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: stagingRoot,
      withIntermediateDirectories: true
    )
    let staged = stagingRoot.appendingPathComponent(
      "\(sessionID.rawValue.uuidString.lowercased())-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.moveItem(at: original, to: staged)
    return StagedSessionDeletion(
      sessionID: sessionID,
      originalURL: original,
      stagedURL: staged
    )
  }

  public func rollbackExplicitDeletion(_ deletion: StagedSessionDeletion) throws {
    guard
      deletion.sessionID.rawValue.uuidString.lowercased()
        == deletion.originalURL.lastPathComponent.lowercased(),
      fileManager.fileExists(atPath: deletion.stagedURL.path),
      !fileManager.fileExists(atPath: deletion.originalURL.path)
    else { throw ProductionAudioJournalError.invalidMetadata }
    try fileManager.moveItem(
      at: deletion.stagedURL,
      to: deletion.originalURL
    )
  }

  public func commitExplicitDeletion(_ deletion: StagedSessionDeletion) throws {
    guard fileManager.fileExists(atPath: deletion.stagedURL.path) else { return }
    try fileManager.removeItem(at: deletion.stagedURL)
    // Bytes shared with no other item any more leave with this one.
    ContentAddressedAssets.prune(assetRoot: assetRootURL)
  }

  private func context(for sessionID: SessionID) throws -> OpenContext {
    if let context = contexts[sessionID] { return context }
    return try openContext(for: sessionID)
  }

  private func openContext(for sessionID: SessionID) throws -> OpenContext {
    let root = journalRoot(for: sessionID)
    guard fileManager.fileExists(atPath: root.path) else {
      throw ProductionAudioJournalError.missingSession
    }
    let journal = try AudioJournal.open(at: root)
    let metadata = try decodeMetadata(at: root)
    guard metadata.schemaVersion == 1,
      metadata.sessionID == sessionID,
      metadata.descriptor.sessionID == sessionID,
      metadata.trackID.rawValue.uuidString == journal.manifest.tracks.first?.trackID,
      Set(
        metadata.trackDescriptors?.map { $0.id.rawValue.uuidString }
          ?? [metadata.trackID.rawValue.uuidString])
        == Set(journal.manifest.tracks.map(\.trackID)),
      journal.manifest.sessionID == sessionID.rawValue
    else {
      throw ProductionAudioJournalError.invalidMetadata
    }
    return OpenContext(journal: journal, metadata: metadata)
  }

  private func ranges(for context: OpenContext) throws -> [AudioRangeInput] {
    var previousEndByTrack: [String: UInt64] = [:]
    var previousRawEndByTrack: [String: UInt64] = [:]
    return try context.journal.manifest.committedChunks
      .sorted {
        if $0.monotonicStartNanoseconds != $1.monotonicStartNanoseconds {
          return $0.monotonicStartNanoseconds < $1.monotonicStartNanoseconds
        }
        if $0.trackID != $1.trackID { return $0.trackID < $1.trackID }
        return $0.sequence < $1.sequence
      }
      .map { entry in
        let duration = UInt64(
          (Double(entry.frameCount) * 1_000_000_000
            / Double(entry.sampleRateHertz)).rounded()
        )
        // AVAudioTime host timestamps can differ from the duration calculated
        // from a buffer's frame count by a fraction of a hardware sample period
        // (notably at 44.1 kHz). Allow the same two-frame tolerance used by the
        // inference materializer, while preserving larger provenance overlaps.
        let timestampTolerance = max(
          UInt64(1),
          2_000_000_000 / UInt64(max(1, entry.sampleRateHertz))
        )
        let start: UInt64
        if let previousEnd = previousEndByTrack[entry.trackID],
          let previousRawEnd = previousRawEndByTrack[entry.trackID],
          (entry.monotonicStartNanoseconds >= previousRawEnd
            ? entry.monotonicStartNanoseconds - previousRawEnd
            : previousRawEnd - entry.monotonicStartNanoseconds)
            <= timestampTolerance
        {
          start = previousEnd
        } else {
          start = entry.monotonicStartNanoseconds
        }
        let end = start + duration
        previousRawEndByTrack[entry.trackID] =
          entry.monotonicStartNanoseconds + duration
        previousEndByTrack[entry.trackID] = end
        guard let rawTrackID = UUID(uuidString: entry.trackID) else {
          throw ProductionAudioJournalError.invalidMetadata
        }
        let trackID = TrackID(rawTrackID)
        let descriptor = try formatDescriptor(
          for: trackID,
          metadata: context.metadata
        )
        return AudioRangeInput(
          sourceID: context.metadata.sessionID.rawValue,
          trackID: trackID.rawValue,
          assetReference: relativeAssetPath(
            sessionID: context.metadata.sessionID,
            journalRelativePath: entry.relativePath
          ),
          contentDigest: entry.contentDigest,
          monotonicStartNanoseconds: start,
          monotonicEndNanoseconds: end,
          sampleRateHertz: entry.sampleRateHertz,
          channelCount: descriptor.channelCount
        )
      }
  }

  func formatDescriptor(
    for trackID: TrackID,
    metadata: ProductionAudioJournalMetadata
  ) throws -> CaptureTrackDescriptor {
    if let descriptor = metadata.trackDescriptors?.first(where: {
      $0.id == trackID
    }) {
      return descriptor
    }
    guard trackID == metadata.trackID else {
      throw ProductionAudioJournalError.invalidMetadata
    }
    let descriptor = metadata.descriptor
    return CaptureTrackDescriptor(
      id: trackID,
      role: .microphoneLocal,
      deviceUID: descriptor.deviceUID,
      sampleRateHertz: descriptor.sampleRateHertz,
      channelCount: descriptor.channelCount,
      encoding: descriptor.encoding,
      interleaved: descriptor.interleaved
    )
  }

  private func persist(
    _ metadata: ProductionAudioJournalMetadata,
    at root: URL
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try ProductionDurableFileIO.atomicWrite(
      encoder.encode(metadata),
      to: root.appendingPathComponent("production-metadata.json")
    )
  }

  private func decodeMetadata(at root: URL) throws -> ProductionAudioJournalMetadata {
    do {
      return try JSONDecoder().decode(
        ProductionAudioJournalMetadata.self,
        from: Data(
          contentsOf: root.appendingPathComponent("production-metadata.json")
        )
      )
    } catch {
      throw ProductionAudioJournalError.invalidMetadata
    }
  }

  private func sessionRoot(for sessionID: SessionID) -> URL {
    assetRootURL
      .appendingPathComponent("sessions", isDirectory: true)
      .appendingPathComponent(
        sessionID.rawValue.uuidString.lowercased(),
        isDirectory: true
      )
  }

  private func journalRoot(for sessionID: SessionID) -> URL {
    sessionRoot(for: sessionID).appendingPathComponent("journal", isDirectory: true)
  }

  private func relativeAssetPath(
    sessionID: SessionID,
    journalRelativePath: String
  ) -> String {
    "sessions/\(sessionID.rawValue.uuidString.lowercased())/journal/\(journalRelativePath)"
  }

  private static func waveHeader(
    encoding: PCMEncoding,
    sampleRateHertz: UInt32,
    channelCount: UInt16,
    pcmByteCount: UInt32
  ) -> Data {
    let bytesPerSample: UInt16 = encoding == .float32LittleEndian ? 4 : 2
    let bitsPerSample = bytesPerSample * 8
    let formatCode: UInt16 = encoding == .float32LittleEndian ? 3 : 1
    let blockAlign = channelCount * bytesPerSample
    let byteRate = sampleRateHertz * UInt32(blockAlign)
    var data = Data()
    data.append(Data("RIFF".utf8))
    data.appendLittleEndian(UInt32(36) + pcmByteCount)
    data.append(Data("WAVEfmt ".utf8))
    data.appendLittleEndian(UInt32(16))
    data.appendLittleEndian(formatCode)
    data.appendLittleEndian(channelCount)
    data.appendLittleEndian(sampleRateHertz)
    data.appendLittleEndian(byteRate)
    data.appendLittleEndian(blockAlign)
    data.appendLittleEndian(bitsPerSample)
    data.append(Data("data".utf8))
    data.appendLittleEndian(pcmByteCount)
    return data
  }

  private static func fileDigest(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: 1_048_576) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

extension Data {
  fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }
}
