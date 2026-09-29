import BestASRAudio
import BestASRAudioJournalProbe
import BestASRDictation
import BestASRDomain
import BestASRInference
import CryptoKit
import Foundation

private let inferenceAudioSchemaVersion = 2
private let inferenceAudioAlgorithm =
  "pcm-to-16khz-mono-f32le-v3-pause-aligned-windows"

private struct InferenceAudioFingerprint: Codable {
  let schemaVersion: Int
  let algorithm: String
  let sessionID: SessionID
  let sourceAudio: [AudioRangeInput]
  let descriptor: MicrophoneCaptureDescriptor
  let maximumWindowNanoseconds: UInt64
}

private struct InferenceAudioDerivationManifest: Codable {
  let schemaVersion: Int
  let algorithm: String
  let fingerprintSHA256: String
  let sourceAudio: [AudioRangeInput]
  let outputAudio: [AudioRangeInput]
}

extension ProductionAudioJournal: DictationInferenceAudioPort {
  public func prepareInferenceAudio(
    sessionID: SessionID,
    sourceAudio: [AudioRangeInput]
  ) async throws -> [AudioRangeInput] {
    let metadata = try metadata(sessionID: sessionID)
    let availableSourceAudio: [AudioRangeInput]
    switch metadata.state {
    case .recording:
      // The capture actor already publishes only newline-committed blocks.
      // Running full recovery for every live ASR cadence would rescan every
      // retained file and rewrite the growing manifest, recreating O(n²)
      // recording work. Individual PCM blocks are still authenticated below
      // when the inference derivative reads them.
      availableSourceAudio = try await committedAudioSnapshot(
        sessionID: sessionID
      )
    case .sealed:
      let recovery = try recover(sessionID: sessionID)
      guard recovery.state == .sealed else {
        throw ProductionAudioJournalError.inferenceDerivationInvalid
      }
      availableSourceAudio = recovery.ranges
    case .stoppedForDiskPressure:
      throw ProductionAudioJournalError.inferenceDerivationInvalid
    }
    guard
      !sourceAudio.isEmpty,
      sourceAudio.allSatisfy({ availableSourceAudio.contains($0) })
    else {
      throw ProductionAudioJournalError.sourceRangeMismatch
    }
    try validateOrdered(sourceAudio)

    let fingerprint = InferenceAudioFingerprint(
      schemaVersion: inferenceAudioSchemaVersion,
      algorithm: inferenceAudioAlgorithm,
      sessionID: sessionID,
      sourceAudio: sourceAudio,
      descriptor: metadata.descriptor,
      maximumWindowNanoseconds: inferenceWindowNanoseconds
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let fingerprintDigest = Self.sha256(try encoder.encode(fingerprint))
    let derivationDirectory =
      assetRootURL
      .appendingPathComponent("sessions", isDirectory: true)
      .appendingPathComponent(
        sessionID.rawValue.uuidString.lowercased(),
        isDirectory: true
      )
      .appendingPathComponent("inference", isDirectory: true)
      .appendingPathComponent(fingerprintDigest, isDirectory: true)
    let manifestURL = derivationDirectory.appendingPathComponent("manifest.json")

    if let existing = try? JSONDecoder().decode(
      InferenceAudioDerivationManifest.self,
      from: Data(contentsOf: manifestURL)
    ),
      existing.schemaVersion == inferenceAudioSchemaVersion,
      existing.algorithm == inferenceAudioAlgorithm,
      existing.fingerprintSHA256 == fingerprintDigest,
      existing.sourceAudio == sourceAudio,
      (try? verifyDerivedRanges(existing.outputAudio)) == true
    {
      retainInferenceAudio(at: derivationDirectory)
      return existing.outputAudio
    }

    let derivationKey = derivationDirectory.standardizedFileURL.path
    if inferenceBuilds.contains(derivationKey) {
      await withCheckedContinuation { continuation in
        inferenceBuildWaiters[derivationKey, default: []].append(continuation)
      }
      return try await prepareInferenceAudio(
        sessionID: sessionID,
        sourceAudio: sourceAudio
      )
    }
    inferenceBuilds.insert(derivationKey)
    defer { finishInferenceBuild(derivationKey) }

    do {
      try fileManager.createDirectory(
        at: derivationDirectory,
        withIntermediateDirectories: true
      )
      let journal = try AudioJournal.open(at: journalRootURL(sessionID: sessionID))
      let allEntries = journal.manifest.committedChunks.sorted { $0.sequence < $1.sequence }
      let entriesByReference = Dictionary(
        uniqueKeysWithValues: allEntries.map { entry in
          (
            "sessions/\(sessionID.rawValue.uuidString.lowercased())/journal/\(entry.relativePath)",
            entry
          )
        })
      let entries = sourceAudio.compactMap { entriesByReference[$0.assetReference] }
      guard entries.count == sourceAudio.count else {
        throw ProductionAudioJournalError.sourceRangeMismatch
      }
      let pairedInputs = Array(zip(sourceAudio, entries))
      var orderedTrackIDs = (metadata.trackDescriptors ?? []).map {
        $0.id.rawValue
      }.filter { trackID in
        sourceAudio.contains(where: { $0.trackID == trackID })
      }
      for range in sourceAudio where !orderedTrackIDs.contains(range.trackID) {
        orderedTrackIDs.append(range.trackID)
      }

      let converter = try BoundedPCMConverter()
      var outputRanges: [AudioRangeInput] = []
      var windowBytes = Data()
      var windowFrameCount: UInt64 = 0
      var windowStart: UInt64?
      var windowSourceID: UUID?
      var windowTrackID: UUID?

      /// Emits the first `frames` samples (all when nil) as one window and
      /// keeps the rest as the start of the next window on the same track.
      func flushWindow(frames: UInt64? = nil) throws {
        guard
          let start = windowStart,
          let sourceID = windowSourceID,
          let trackID = windowTrackID,
          windowFrameCount > 0,
          !windowBytes.isEmpty
        else { return }
        let emittedFrames = min(frames ?? windowFrameCount, windowFrameCount)
        let emittedBytes = windowBytes.prefix(Int(emittedFrames) * 4)
        let index = outputRanges.count
        let filename = String(format: "window-%05d.f32le", index)
        let destination = derivationDirectory.appendingPathComponent(filename)
        try ProductionDurableFileIO.atomicWrite(Data(emittedBytes), to: destination)
        let duration = UInt64(
          (Double(emittedFrames) * 1_000_000_000 / 16_000).rounded()
        )
        let relative =
          "sessions/\(sessionID.rawValue.uuidString.lowercased())/inference/\(fingerprintDigest)/\(filename)"
        outputRanges.append(
          AudioRangeInput(
            sourceID: sourceID,
            trackID: trackID,
            assetReference: relative,
            contentDigest: Self.sha256(Data(emittedBytes)),
            monotonicStartNanoseconds: start,
            monotonicEndNanoseconds: start + duration,
            sampleRateHertz: 16_000,
            channelCount: 1
          )
        )
        guard emittedFrames < windowFrameCount else {
          windowBytes.removeAll(keepingCapacity: true)
          windowFrameCount = 0
          windowStart = nil
          windowSourceID = nil
          windowTrackID = nil
          return
        }
        windowBytes = Data(windowBytes.dropFirst(Int(emittedFrames) * 4))
        windowFrameCount -= emittedFrames
        windowStart = start + duration
      }

      let windowLimitFrames = Int(inferenceWindowNanoseconds / 62_500)

      /// Ends windows at pauses once they are long enough; never lets one
      /// exceed the inference limit.
      func flushAtPauses() throws {
        while let cut = windowBytes.withUnsafeBytes({ raw in
          PauseAlignedWindowing.cut(raw.bindMemory(to: Float.self), limit: windowLimitFrames)
        }) {
          try flushWindow(frames: UInt64(max(1, cut)))
        }
      }

      // Interleaved callbacks from a system-output track and a microphone
      // track must not force a new inference window at every callback. Build
      // bounded windows independently per track, then restore timeline order
      // for recognition. This also keeps each resampler's state isolated when
      // the two devices use different native sample rates.
      for trackID in orderedTrackIDs {
        try flushWindow()
        await converter.resetForFormatChange()
        var previousSourceEnd: UInt64?
        for (range, entry) in pairedInputs where range.trackID == trackID {
          try InferenceCancellation.check()
          let sourceDescriptor = try formatDescriptor(
            for: TrackID(range.trackID),
            metadata: metadata
          )
          let discontinuity: Bool
          if let previousSourceEnd {
            let tolerance = UInt64(
              (2_000_000_000 / max(1, sourceDescriptor.sampleRateHertz))
            )
            discontinuity =
              range.monotonicStartNanoseconds
              > previousSourceEnd + tolerance
          } else {
            discontinuity = false
          }
          if discontinuity {
            try flushWindow()
            await converter.resetForFormatChange()
          }

          let sourceURL = assetRootURL.appendingPathComponent(range.assetReference)
          let sourceBytes = try Data(
            contentsOf: sourceURL,
            options: [.mappedIfSafe]
          )
          guard Self.sha256(sourceBytes) == range.contentDigest else {
            throw ProductionAudioJournalError.inferenceDerivationInvalid
          }
          let converted = try await converter.convert(
            CapturedPCMChunk(
              trackID: TrackID(range.trackID),
              sequence: entry.sequence,
              monotonicStartNanoseconds: entry.monotonicStartNanoseconds,
              frameCount: UInt64(entry.frameCount),
              sampleRateHertz: entry.sampleRateHertz,
              channelCount: sourceDescriptor.channelCount,
              encoding: sourceDescriptor.encoding,
              interleaved: sourceDescriptor.interleaved,
              bytes: sourceBytes
            )
          )
          guard
            converted.sampleRateHertz == 16_000,
            converted.channelCount == 1,
            converted.encoding == .float32LittleEndian,
            converted.interleaved,
            converted.bytes.count == Int(converted.frameCount) * 4
          else {
            throw ProductionAudioJournalError.inferenceDerivationInvalid
          }
          if !converted.bytes.isEmpty {
            if windowStart == nil {
              windowStart = range.monotonicStartNanoseconds
              windowSourceID = range.sourceID
              windowTrackID = range.trackID
            }
            windowBytes.append(converted.bytes)
            windowFrameCount += converted.frameCount
            try flushAtPauses()
          }
          previousSourceEnd = range.monotonicEndNanoseconds
        }
        try flushWindow()
      }
      outputRanges.sort {
        if $0.monotonicStartNanoseconds != $1.monotonicStartNanoseconds {
          return $0.monotonicStartNanoseconds < $1.monotonicStartNanoseconds
        }
        if $0.trackID != $1.trackID {
          return $0.trackID.uuidString < $1.trackID.uuidString
        }
        return $0.assetReference < $1.assetReference
      }
      guard !outputRanges.isEmpty else {
        throw ProductionAudioJournalError.inferenceDerivationInvalid
      }

      let manifest = InferenceAudioDerivationManifest(
        schemaVersion: inferenceAudioSchemaVersion,
        algorithm: inferenceAudioAlgorithm,
        fingerprintSHA256: fingerprintDigest,
        sourceAudio: sourceAudio,
        outputAudio: outputRanges
      )
      try ProductionDurableFileIO.atomicWrite(
        try encoder.encode(manifest),
        to: manifestURL
      )
      retainInferenceAudio(at: derivationDirectory)
      return outputRanges
    } catch {
      if inferenceLeaseCounts[derivationKey] == nil {
        try? fileManager.removeItem(at: derivationDirectory)
      }
      throw error
    }
  }

  public func discardInferenceAudio(
    sessionID: SessionID,
    preparedAudio: [AudioRangeInput]
  ) async {
    for directory in inferenceDirectories(
      sessionID: sessionID,
      preparedAudio: preparedAudio
    ) {
      let key = directory.standardizedFileURL.path
      if let leaseCount = inferenceLeaseCounts[key], leaseCount > 1 {
        inferenceLeaseCounts[key] = leaseCount - 1
        continue
      }
      inferenceLeaseCounts[key] = nil
      try? fileManager.removeItem(at: directory)
    }
  }

  private func retainInferenceAudio(at directory: URL) {
    let key = directory.standardizedFileURL.path
    inferenceLeaseCounts[key, default: 0] += 1
  }

  private func finishInferenceBuild(_ key: String) {
    inferenceBuilds.remove(key)
    let waiters = inferenceBuildWaiters.removeValue(forKey: key) ?? []
    for waiter in waiters { waiter.resume() }
  }

  private func inferenceDirectories(
    sessionID: SessionID,
    preparedAudio: [AudioRangeInput]
  ) -> Set<URL> {
    let sessionComponent = sessionID.rawValue.uuidString.lowercased()
    var directories = Set<URL>()
    for range in preparedAudio {
      let components = range.assetReference.split(separator: "/").map(String.init)
      guard
        components.count == 5,
        components[0] == "sessions",
        components[1] == sessionComponent,
        components[2] == "inference",
        components[3].count == 64,
        components[3].allSatisfy({ $0.isHexDigit }),
        components[4].hasPrefix("window-"),
        components[4].hasSuffix(".f32le")
      else { continue }
      directories.insert(
        assetRootURL
          .appendingPathComponent("sessions", isDirectory: true)
          .appendingPathComponent(sessionComponent, isDirectory: true)
          .appendingPathComponent("inference", isDirectory: true)
          .appendingPathComponent(components[3], isDirectory: true)
      )
    }
    return directories
  }

  private func validateOrdered(_ ranges: [AudioRangeInput]) throws {
    var previousEndByTrack: [UUID: UInt64] = [:]
    var references = Set<String>()
    for range in ranges {
      guard
        range.monotonicStartNanoseconds < range.monotonicEndNanoseconds,
        !range.assetReference.isEmpty,
        !range.assetReference.hasPrefix("/"),
        !range.assetReference.contains(".."),
        URL(string: range.assetReference)?.scheme == nil,
        references.insert(range.assetReference).inserted,
        previousEndByTrack[range.trackID].map({
          range.monotonicStartNanoseconds >= $0
        }) ?? true
      else {
        throw ProductionAudioJournalError.sourceRangeMismatch
      }
      previousEndByTrack[range.trackID] = range.monotonicEndNanoseconds
    }
  }

  private func verifyDerivedRanges(_ ranges: [AudioRangeInput]) throws -> Bool {
    guard !ranges.isEmpty else { return false }
    for range in ranges {
      guard
        range.sampleRateHertz == 16_000,
        range.channelCount == 1,
        range.monotonicStartNanoseconds < range.monotonicEndNanoseconds,
        !range.assetReference.hasPrefix("/"),
        !range.assetReference.contains(".."),
        URL(string: range.assetReference)?.scheme == nil
      else { return false }
      let data = try Data(
        contentsOf: assetRootURL.appendingPathComponent(range.assetReference),
        options: [.mappedIfSafe]
      )
      guard
        !data.isEmpty,
        data.count.isMultiple(of: 4),
        Self.sha256(data) == range.contentDigest
      else { return false }
    }
    return true
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
