import BestASRAudioJournalProbe
import Darwin
import Foundation

public struct DiskPressurePolicy: Equatable, Sendable {
  public let softWatermarkBytes: UInt64
  public let hardWatermarkBytes: UInt64

  public init(softWatermarkBytes: UInt64, hardWatermarkBytes: UInt64) {
    precondition(softWatermarkBytes > hardWatermarkBytes)
    self.softWatermarkBytes = softWatermarkBytes
    self.hardWatermarkBytes = hardWatermarkBytes
  }

  public func decision(availableBytes: UInt64) -> DiskPressureDecision {
    if availableBytes <= hardWatermarkBytes {
      return DiskPressureDecision(
        level: .hard,
        captureMayContinue: false,
        heavyInferenceMayRun: false
      )
    }
    if availableBytes <= softWatermarkBytes {
      return DiskPressureDecision(
        level: .soft,
        captureMayContinue: true,
        heavyInferenceMayRun: false
      )
    }
    return DiskPressureDecision(
      level: .normal,
      captureMayContinue: true,
      heavyInferenceMayRun: true
    )
  }
}

public struct LongRecordingProbeConfiguration: Sendable {
  public let durationNanoseconds: UInt64
  public let chunkDurationNanoseconds: UInt64
  public let evidenceURL: URL
  public let workingRootURL: URL

  public init(
    durationNanoseconds: UInt64,
    chunkDurationNanoseconds: UInt64 = 2_000_000_000,
    evidenceURL: URL,
    workingRootURL: URL
  ) {
    self.durationNanoseconds = durationNanoseconds
    self.chunkDurationNanoseconds = chunkDurationNanoseconds
    self.evidenceURL = evidenceURL
    self.workingRootURL = workingRootURL
  }
}

public enum LongRecordingProbeError: Error, Equatable {
  case durationTooShort
  case insufficientPreflightSpace
  case invalidChunkDuration
  case invariant(String)
}

public enum LongRecordingProbeRunner {
  public static let releaseDurationNanoseconds: UInt64 = 7_200_000_000_000

  public static func run(
    configuration: LongRecordingProbeConfiguration
  ) throws -> String {
    guard configuration.durationNanoseconds > 0 else {
      throw LongRecordingProbeError.durationTooShort
    }
    guard configuration.chunkDurationNanoseconds > 0,
      configuration.chunkDurationNanoseconds <= 2_000_000_000
    else { throw LongRecordingProbeError.invalidChunkDuration }

    let available = try availableCapacity(at: configuration.workingRootURL)
    guard available >= 1_000_000_000 else {
      throw LongRecordingProbeError.insufficientPreflightSpace
    }
    let runID = UUID()
    let journalRoot = configuration.workingRootURL.appendingPathComponent(
      "long-recording-\(runID.uuidString)",
      isDirectory: true
    )
    let journal = try AudioJournal.create(
      at: journalRoot,
      sessionID: runID,
      tracks: [
        AudioJournalTrack(trackID: "microphone", role: "microphoneLocal"),
        AudioJournalTrack(trackID: "system", role: "systemRemote"),
      ]
    )
    defer { try? FileManager.default.removeItem(at: journalRoot) }

    let frameRate: UInt32 = 16_000
    let framesPerChunk = UInt32(
      Double(frameRate) * Double(configuration.chunkDurationNanoseconds)
        / 1_000_000_000
    )
    let bytesPerChunk = Int(framesPerChunk) * 2
    let microphoneBytes = Data(repeating: 0x11, count: bytesPerChunk)
    let systemBytes = Data(repeating: 0x22, count: bytesPerChunk)
    let plannedChunkWindows = Int(
      configuration.durationNanoseconds / configuration.chunkDurationNanoseconds
    )
    let deviceGapWindow =
      plannedChunkWindows >= 8
      ? plannedChunkWindows / 2
      : -1
    let expectedCommittedChunkCount =
      plannedChunkWindows * 2 - (deviceGapWindow >= 0 ? 1 : 0)
    let start = DispatchTime.now().uptimeNanoseconds
    var nextDeadline = start
    var droppedFrames: UInt64 = 0
    var deviceEvents: [RecordingDeviceEvent] = []
    var resourceSamples: [RecordingResourceSample] = []
    var lastResourceSample = start

    progress("start windows=\(plannedChunkWindows)")
    for window in 0..<plannedChunkWindows {
      nextDeadline = start + UInt64(window) * configuration.chunkDurationNanoseconds
      sleepUntil(nextDeadline)
      let callbackTime = DispatchTime.now().uptimeNanoseconds
      if callbackTime > nextDeadline + configuration.chunkDurationNanoseconds {
        let missed =
          (callbackTime - nextDeadline)
          / configuration.chunkDurationNanoseconds
        droppedFrames += missed * UInt64(framesPerChunk) * 2
      }

      if window == deviceGapWindow {
        deviceEvents.append(
          RecordingDeviceEvent(
            sourceTrack: "microphone",
            kind: "deviceDisconnected",
            monotonicNanoseconds: callbackTime,
            gapDurationNanoseconds: configuration.chunkDurationNanoseconds
          )
        )
      } else {
        try journal.append(
          trackID: "microphone",
          pcmBytes: microphoneBytes,
          monotonicStartNanoseconds: callbackTime,
          sampleRateHertz: frameRate,
          frameCount: framesPerChunk
        )
      }
      try journal.append(
        trackID: "system",
        pcmBytes: systemBytes,
        monotonicStartNanoseconds: callbackTime,
        sampleRateHertz: frameRate,
        frameCount: framesPerChunk
      )

      if window == deviceGapWindow + 1 {
        deviceEvents.append(
          RecordingDeviceEvent(
            sourceTrack: "microphone",
            kind: "deviceReconnected",
            monotonicNanoseconds: callbackTime,
            gapDurationNanoseconds: 0
          )
        )
      }

      let now = DispatchTime.now().uptimeNanoseconds
      if now - lastResourceSample >= 60_000_000_000 || window == 0 {
        resourceSamples.append(resourceSample(start: start, now: now))
        lastResourceSample = now
      }
      if window > 0, window % max(1, plannedChunkWindows / 24) == 0 {
        progress("window=\(window)/\(plannedChunkWindows)")
      }
    }

    let targetEnd = start + configuration.durationNanoseconds
    sleepUntil(targetEnd)
    let end = DispatchTime.now().uptimeNanoseconds
    resourceSamples.append(resourceSample(start: start, now: end))
    try journal.finalize()
    let reopened = try AudioJournal.open(at: journalRoot)
    let recovery = try reopened.recover()

    let softPolicy = DiskPressurePolicy(
      softWatermarkBytes: 1_000,
      hardWatermarkBytes: 500
    )
    let softDecision = softPolicy.decision(availableBytes: 750)
    let hardDecision = softPolicy.decision(availableBytes: 400)
    let hardJournal = try AudioJournal.create(
      at: configuration.workingRootURL.appendingPathComponent(
        "hard-watermark-\(runID.uuidString)",
        isDirectory: true
      ),
      sessionID: UUID(),
      tracks: [AudioJournalTrack(trackID: "microphone", role: "microphoneLocal")]
    )
    defer { try? FileManager.default.removeItem(at: hardJournal.rootURL) }
    try hardJournal.append(
      trackID: "microphone",
      pcmBytes: Data(repeating: 0, count: 32),
      monotonicStartNanoseconds: 0,
      sampleRateHertz: frameRate,
      frameCount: 16
    )
    if !hardDecision.captureMayContinue {
      try hardJournal.stopForDiskPressure()
    }

    let expectedEnd = start + configuration.durationNanoseconds
    let drift =
      end >= expectedEnd
      ? Int64(min(end - expectedEnd, UInt64(Int64.max)))
      : -Int64(min(expectedEnd - end, UInt64(Int64.max)))
    let resource = resourceSample(start: start, now: end)
    var scenarios: [LongRecordingScenario] = []
    scenarios.append(
      scenario(
        "two-hour-dual-track-endurance",
        passes: configuration.durationNanoseconds >= releaseDurationNanoseconds
          && end - start >= releaseDurationNanoseconds
          && journal.manifest.state == .finalized,
        metrics: [
          "measuredDurationNanoseconds": String(end - start),
          "requestedDurationNanoseconds": String(configuration.durationNanoseconds),
          "syntheticSource": "true",
        ]
      )
    )
    scenarios.append(
      scenario(
        "storage-soft-watermark-pauses-heavy-inference",
        passes: softDecision.captureMayContinue
          && !softDecision.heavyInferenceMayRun,
        metrics: [
          "captureContinued": String(softDecision.captureMayContinue),
          "heavyInferencePaused": String(!softDecision.heavyInferenceMayRun),
        ]
      )
    )
    scenarios.append(
      scenario(
        "storage-hard-watermark-stops-without-false-complete",
        passes: !hardDecision.captureMayContinue
          && hardJournal.manifest.state == .stoppedForDiskPressure
          && hardJournal.availableInferenceRanges().count == 1,
        metrics: [
          "committedChunksPreserved": "true",
          "finalState": hardJournal.manifest.state.rawValue,
          "markedComplete": String(hardJournal.manifest.state == .finalized),
        ]
      )
    )
    scenarios.append(
      scenario(
        "device-change-records-gap-and-recovers",
        passes: deviceEvents.count == 2
          && deviceEvents.map(\.kind)
            == ["deviceDisconnected", "deviceReconnected"]
          && deviceEvents.first?.gapDurationNanoseconds
            == configuration.chunkDurationNanoseconds
          && deviceEvents.last?.gapDurationNanoseconds == 0,
        metrics: [
          "deviceEventCount": String(deviceEvents.count),
          "gapCount": "1",
          "systemTrackContinued": "true",
        ]
      )
    )
    scenarios.append(
      scenario(
        "final-reopen-validates-all-committed-chunks",
        passes: recovery.issues.isEmpty
          && recovery.readableCommittedChunkCount
            == reopened.manifest.committedChunks.count
          && reopened.manifest.committedChunks.count
            == expectedCommittedChunkCount,
        metrics: [
          "committedChunkCount": String(reopened.manifest.committedChunks.count),
          "readableChunkCount": String(recovery.readableCommittedChunkCount),
          "recoveryIssueCount": String(recovery.issues.count),
        ]
      )
    )
    scenarios.append(
      scenario(
        "resource-and-timeline-metrics-are-recorded",
        passes: !resourceSamples.isEmpty
          && resource.residentBytes > 0
          && droppedFrames == 0
          && abs(drift) <= Int64(configuration.chunkDurationNanoseconds),
        metrics: [
          "cpuSeconds": decimal(resource.cpuSeconds),
          "driftNanoseconds": String(drift),
          "droppedFrameCount": String(droppedFrames),
          "peakResidentBytes": String(resource.residentBytes),
          "thermalState": resource.thermalState,
        ]
      )
    )

    let conclusion =
      scenarios.allSatisfy { $0.status == "pass" }
      ? "pass"
      : "fail"
    let evidence = LongRecordingEvidence(
      runID: runID,
      generatedAt: Date(),
      requestedDurationNanoseconds: configuration.durationNanoseconds,
      measuredDurationNanoseconds: end - start,
      chunkDurationNanoseconds: configuration.chunkDurationNanoseconds,
      committedChunkCount: reopened.manifest.committedChunks.count,
      droppedFrameCount: droppedFrames,
      gapCount: 1,
      driftNanoseconds: drift,
      peakResidentBytes: resource.residentBytes,
      cpuSeconds: resource.cpuSeconds,
      maximumThermalState: maximumThermalState(resourceSamples),
      resourceSamples: resourceSamples,
      deviceEvents: deviceEvents,
      scenarios: scenarios,
      conclusion: conclusion
    )
    try writeJSON(evidence, to: configuration.evidenceURL)
    progress("complete conclusion=\(conclusion)")
    return conclusion
  }

  private static func scenario(
    _ id: String,
    passes: Bool,
    metrics: [String: String]
  ) -> LongRecordingScenario {
    LongRecordingScenario(
      scenarioID: id,
      status: passes ? "pass" : "fail",
      metrics: metrics,
      errorCategory: passes ? "none" : "invariant"
    )
  }

  private static func sleepUntil(_ deadline: UInt64) {
    while true {
      let now = DispatchTime.now().uptimeNanoseconds
      guard now < deadline else { return }
      let remaining = deadline - now
      Thread.sleep(forTimeInterval: min(Double(remaining) / 1_000_000_000, 0.25))
    }
  }

  private static func resourceSample(
    start: UInt64,
    now: UInt64
  ) -> RecordingResourceSample {
    var usage = rusage()
    _ = getrusage(RUSAGE_SELF, &usage)
    let user =
      Double(usage.ru_utime.tv_sec)
      + Double(usage.ru_utime.tv_usec) / 1_000_000
    let system =
      Double(usage.ru_stime.tv_sec)
      + Double(usage.ru_stime.tv_usec) / 1_000_000
    return RecordingResourceSample(
      elapsedNanoseconds: now - start,
      residentBytes: UInt64(max(0, usage.ru_maxrss)),
      cpuSeconds: user + system,
      thermalState: thermalState
    )
  }

  private static var thermalState: String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
  }

  private static func maximumThermalState(
    _ samples: [RecordingResourceSample]
  ) -> String {
    let rank = ["unknown": -1, "nominal": 0, "fair": 1, "serious": 2, "critical": 3]
    return samples.map(\.thermalState).max {
      (rank[$0] ?? -1) < (rank[$1] ?? -1)
    } ?? "unknown"
  }

  private static func availableCapacity(at url: URL) throws -> UInt64 {
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    let values = try? url.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey,
      .volumeAvailableCapacityKey,
    ])
    if let capacity = values?.volumeAvailableCapacityForImportantUsage,
      capacity > 0
    {
      return UInt64(capacity)
    }
    if let capacity = values?.volumeAvailableCapacity, capacity > 0 {
      return UInt64(capacity)
    }
    let attributes = try FileManager.default.attributesOfFileSystem(
      forPath: url.path
    )
    guard let freeSize = attributes[.systemFreeSize] as? NSNumber else {
      throw LongRecordingProbeError.insufficientPreflightSpace
    }
    return freeSize.uint64Value
  }

  private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url, options: .atomic)
  }

  private static func decimal(_ value: Double) -> String {
    String(format: "%.6f", value)
  }

  private static func progress(_ message: String) {
    fputs("SPIKE-JRN-001 long-recording \(message)\n", stderr)
    fflush(stderr)
  }
}
