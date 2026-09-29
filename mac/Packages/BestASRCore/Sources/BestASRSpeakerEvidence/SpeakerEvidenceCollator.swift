import BestASRBenchmark
import Foundation

public enum SpeakerEvidenceCandidate: String, Codable, CaseIterable, Sendable {
  case argmax
  case fluid
  case sherpa
}

public struct SpeakerEvidenceCollationRequest: Sendable {
  public let candidate: SpeakerEvidenceCandidate
  public let matrixMode: String
  public let corpusDirectory: URL
  public let candidateOutputDirectory: URL
  public let benchmarkID: String
  public let runID: UUID
  public let implementationRevision: String
  public let artifactID: String
  public let artifactSHA256: String
  public let provider: String
  public let corpusManifestID: String
  public let corpusVersion: String
  public let environmentRef: String
  public let toolchainVersion: String
  public let identityAssignments: [IdentityAssignment]

  public init(
    candidate: SpeakerEvidenceCandidate,
    matrixMode: String,
    corpusDirectory: URL,
    candidateOutputDirectory: URL,
    benchmarkID: String,
    runID: UUID,
    implementationRevision: String,
    artifactID: String,
    artifactSHA256: String,
    provider: String,
    corpusManifestID: String,
    corpusVersion: String,
    environmentRef: String,
    toolchainVersion: String,
    identityAssignments: [IdentityAssignment] = []
  ) {
    self.candidate = candidate
    self.matrixMode = matrixMode
    self.corpusDirectory = corpusDirectory
    self.candidateOutputDirectory = candidateOutputDirectory
    self.benchmarkID = benchmarkID
    self.runID = runID
    self.implementationRevision = implementationRevision
    self.artifactID = artifactID
    self.artifactSHA256 = artifactSHA256
    self.provider = provider
    self.corpusManifestID = corpusManifestID
    self.corpusVersion = corpusVersion
    self.environmentRef = environmentRef
    self.toolchainVersion = toolchainVersion
    self.identityAssignments = identityAssignments
  }
}

public enum SpeakerEvidenceCollatorError: Error, Equatable, Sendable {
  case invalidMatrixMode(String)
  case noReceipts
  case invalidSampleID(String)
  case invalidSampleDuration(String)
  case invalidTiming(String)
  case invalidRTTM(String)
  case invalidFluidResult(String)
  case invalidSherpaResult(String)
}

public enum SpeakerEvidenceCollator {
  public static func collate(
    _ request: SpeakerEvidenceCollationRequest
  ) throws -> BenchmarkRunInput {
    guard request.matrixMode == "oracle" || request.matrixMode == "automatic" else {
      throw SpeakerEvidenceCollatorError.invalidMatrixMode(request.matrixMode)
    }

    let receipts = try FileManager.default.contentsOfDirectory(
      at: request.corpusDirectory,
      includingPropertiesForKeys: nil
    ).filter {
      $0.lastPathComponent.hasSuffix(".receipt.json")
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !receipts.isEmpty else {
      throw SpeakerEvidenceCollatorError.noReceipts
    }

    let decoder = JSONDecoder()
    var samples = try receipts.map { receiptURL in
      let receipt = try decoder.decode(
        CorpusReceipt.self,
        from: Data(contentsOf: receiptURL)
      )
      guard
        receipt.sampleID.range(
          of: "^spk-v1-[0-9]{3}$", options: .regularExpression
        ) != nil
      else {
        throw SpeakerEvidenceCollatorError.invalidSampleID(receipt.sampleID)
      }
      guard receipt.sampleRate > 0, receipt.sampleCount > 0 else {
        throw SpeakerEvidenceCollatorError.invalidSampleDuration(receipt.sampleID)
      }

      let referenceURL = request.corpusDirectory.appendingPathComponent(
        "\(receipt.sampleID).rttm")
      let sampleOutputDirectory = request.candidateOutputDirectory
        .appendingPathComponent(receipt.sampleID, isDirectory: true)
      let timingURL = sampleOutputDirectory.appendingPathComponent("stderr.log")
      let reference = try parseRTTM(
        Data(contentsOf: referenceURL),
        source: referenceURL.lastPathComponent
      )
      let hypothesis = try parseHypothesis(
        candidate: request.candidate,
        directory: sampleOutputDirectory,
        audioSampleCount: receipt.sampleCount,
        sampleRate: receipt.sampleRate
      )
      let timing = try parseTiming(
        Data(contentsOf: timingURL),
        source: "\(receipt.sampleID)/stderr.log"
      )
      let audioDuration = nanoseconds(
        samples: receipt.sampleCount,
        sampleRate: receipt.sampleRate
      )

      return BenchmarkSampleInput(
        sampleUUID: try sampleUUID(receipt.sampleID),
        diarization: DiarizationEvaluation(
          reference: reference,
          hypothesis: hypothesis
        ),
        audioDurationNanoseconds: audioDuration,
        inferenceDurationNanoseconds: timing.wallNanoseconds,
        latencyNanoseconds: timing.wallNanoseconds,
        peakResidentBytes: timing.peakResidentBytes,
        backlogHighWatermark: 0
      )
    }

    if !request.identityAssignments.isEmpty {
      let first = samples[0]
      samples[0] = BenchmarkSampleInput(
        sampleUUID: first.sampleUUID,
        transcript: first.transcript,
        diarization: first.diarization,
        identityAssignments: request.identityAssignments,
        audioDurationNanoseconds: first.audioDurationNanoseconds,
        inferenceDurationNanoseconds: first.inferenceDurationNanoseconds,
        latencyNanoseconds: first.latencyNanoseconds,
        peakResidentBytes: first.peakResidentBytes,
        backlogHighWatermark: first.backlogHighWatermark,
        failureCategory: first.failureCategory
      )
    }

    return BenchmarkRunInput(
      benchmarkID: request.benchmarkID,
      runID: request.runID,
      task: .speaker,
      protocolVersion: 1,
      implementationRevision: request.implementationRevision,
      modelArtifact: BenchmarkModelArtifact(
        artifactID: request.artifactID,
        sha256: request.artifactSHA256
      ),
      configuration: [
        "candidate": request.candidate.rawValue,
        "matrix-mode": request.matrixMode,
        "network": "denied",
        "overlap-output": "enabled",
        "provider": request.provider,
        "speaker-count-mode": request.matrixMode == "oracle"
          ? "reference-count"
          : "candidate-estimated",
      ],
      corpus: BenchmarkCorpusReference(
        manifestID: request.corpusManifestID,
        version: request.corpusVersion,
        split: .smoke
      ),
      environmentRef: request.environmentRef,
      hardware: BenchmarkHardwareContext(
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        architecture: architecture,
        unifiedMemoryBytes: ProcessInfo.processInfo.physicalMemory,
        toolchainVersion: request.toolchainVersion
      ),
      samples: samples
    )
  }

  private static var architecture: String {
    #if arch(arm64)
      return "arm64"
    #elseif arch(x86_64)
      return "x86_64"
    #else
      return "unknown"
    #endif
  }

  private static func sampleUUID(_ sampleID: String) throws -> UUID {
    guard let suffix = Int(sampleID.suffix(3)),
      let uuid = UUID(
        uuidString: String(
          format: "35000000-0000-4000-8000-%012d", suffix
        ))
    else {
      throw SpeakerEvidenceCollatorError.invalidSampleID(sampleID)
    }
    return uuid
  }

  private static func nanoseconds(samples: Int, sampleRate: Int) -> UInt64 {
    UInt64(
      (Double(samples) / Double(sampleRate) * 1_000_000_000).rounded()
    )
  }

  private static func parseHypothesis(
    candidate: SpeakerEvidenceCandidate,
    directory: URL,
    audioSampleCount: Int,
    sampleRate: Int
  ) throws -> [SpeakerSegment] {
    let durationNanoseconds = nanoseconds(
      samples: audioSampleCount,
      sampleRate: sampleRate
    )
    let raw: [SpeakerSegment]
    switch candidate {
    case .argmax:
      let url = directory.appendingPathComponent("result.rttm")
      raw = try parseRTTM(
        Data(contentsOf: url),
        source: url.lastPathComponent
      )
    case .fluid:
      let url = directory.appendingPathComponent("result.json")
      let result: FluidResult
      do {
        result = try JSONDecoder().decode(
          FluidResult.self,
          from: Data(contentsOf: url)
        )
      } catch {
        throw SpeakerEvidenceCollatorError.invalidFluidResult(
          url.lastPathComponent)
      }
      raw = try result.segments.map { segment in
        try makeSegment(
          speakerID: segment.speakerId,
          startSeconds: segment.startTimeSeconds,
          endSeconds: segment.endTimeSeconds,
          source: url.lastPathComponent
        )
      }
    case .sherpa:
      let url = directory.appendingPathComponent("stdout.log")
      raw = try parseSherpa(
        Data(contentsOf: url),
        source: url.lastPathComponent
      )
    }

    return raw.compactMap { segment in
      let start = min(segment.startNanoseconds, durationNanoseconds)
      let end = min(segment.endNanoseconds, durationNanoseconds)
      guard end > start else { return nil }
      return SpeakerSegment(
        speakerID: segment.speakerID,
        startNanoseconds: start,
        endNanoseconds: end
      )
    }
  }

  private static func parseRTTM(
    _ data: Data,
    source: String
  ) throws -> [SpeakerSegment] {
    let text = String(decoding: data, as: UTF8.self)
    var segments: [SpeakerSegment] = []
    for line in text.split(whereSeparator: \.isNewline) {
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count >= 8, fields[0] == "SPEAKER",
        let start = Double(fields[3]),
        let duration = Double(fields[4])
      else {
        throw SpeakerEvidenceCollatorError.invalidRTTM(source)
      }
      segments.append(
        try makeSegment(
          speakerID: String(fields[7]),
          startSeconds: start,
          endSeconds: start + duration,
          source: source
        ))
    }
    return segments
  }

  private static func parseSherpa(
    _ data: Data,
    source: String
  ) throws -> [SpeakerSegment] {
    let text = String(decoding: data, as: UTF8.self)
    var segments: [SpeakerSegment] = []
    for line in text.split(whereSeparator: \.isNewline) {
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count == 4, fields[1] == "--",
        fields[3].hasPrefix("speaker_")
      else { continue }
      guard let start = Double(fields[0]), let end = Double(fields[2]) else {
        throw SpeakerEvidenceCollatorError.invalidSherpaResult(source)
      }
      segments.append(
        try makeSegment(
          speakerID: String(fields[3]),
          startSeconds: start,
          endSeconds: end,
          source: source
        ))
    }
    guard !segments.isEmpty else {
      throw SpeakerEvidenceCollatorError.invalidSherpaResult(source)
    }
    return segments
  }

  private static func makeSegment(
    speakerID: String,
    startSeconds: Double,
    endSeconds: Double,
    source: String
  ) throws -> SpeakerSegment {
    guard !speakerID.isEmpty,
      startSeconds.isFinite,
      endSeconds.isFinite,
      startSeconds >= 0,
      endSeconds > startSeconds
    else {
      throw SpeakerEvidenceCollatorError.invalidRTTM(source)
    }
    return SpeakerSegment(
      speakerID: speakerID,
      startNanoseconds: UInt64((startSeconds * 1_000_000_000).rounded()),
      endNanoseconds: UInt64((endSeconds * 1_000_000_000).rounded())
    )
  }

  private static func parseTiming(
    _ data: Data,
    source: String
  ) throws -> TimingReceipt {
    let text = String(decoding: data, as: UTF8.self)
    var wallSeconds: Double?
    var peakResidentBytes: UInt64?
    for line in text.split(whereSeparator: \.isNewline) {
      let fields = line.split(whereSeparator: \.isWhitespace)
      if fields.count >= 2, fields[1] == "real",
        let value = Double(fields[0])
      {
        wallSeconds = value
      } else if line.contains("maximum resident set size"),
        let first = fields.first,
        let value = UInt64(first)
      {
        peakResidentBytes = value
      }
    }
    guard let wallSeconds, wallSeconds > 0, let peakResidentBytes else {
      throw SpeakerEvidenceCollatorError.invalidTiming(source)
    }
    return TimingReceipt(
      wallNanoseconds: UInt64((wallSeconds * 1_000_000_000).rounded()),
      peakResidentBytes: peakResidentBytes
    )
  }
}

private struct CorpusReceipt: Decodable {
  let sampleID: String
  let sampleRate: Int
  let sampleCount: Int
}

private struct FluidResult: Decodable {
  let segments: [FluidSegment]
}

private struct FluidSegment: Decodable {
  let speakerId: String
  let startTimeSeconds: Double
  let endTimeSeconds: Double
}

private struct TimingReceipt {
  let wallNanoseconds: UInt64
  let peakResidentBytes: UInt64
}
