import AVFoundation
import BestASRAlphaEvaluation
import BestASRCandidateAdapters
import BestASRFluidRuntime
import BestASRInference
import BestASRQwenRuntime
import CryptoKit
import Foundation
import MLXAudioCore

/// Same final runtime as the App, driven with public/synthetic developer audio.
/// It does not create a user session or write into the installed model store.
actor NativeQwenFileTranscriber: AlphaASRFileTranscribing {
  private let backend: QwenASRBackend
  private let aligner: QwenForcedAlignmentBackend
  private var timingRecords: [TimingRecord] = []

  private struct TimingRecord: Encodable {
    let audioFileName: String
    let durationSeconds: Double
    let sourceStartNanoseconds: UInt64
    let sourceEndNanoseconds: UInt64
    let segments: [CandidateRuntimeSegment]
  }

  init(verifiedASRDirectory: URL, verifiedAlignmentDirectory: URL) {
    backend = QwenASRBackend(verifiedModelDirectory: verifiedASRDirectory)
    aligner = QwenForcedAlignmentBackend(verifiedModelDirectory: verifiedAlignmentDirectory)
  }

  func prepare() async throws {
    try await backend.prepare()
    try await aligner.prepare()
  }

  func transcribe(audioURL: URL, dictionaryTerms: [String]) async throws -> String {
    let file = try AVAudioFile(forReading: audioURL)
    guard file.processingFormat.sampleRate > 0, file.processingFormat.channelCount == 1,
      file.length > 0, Double(file.length) / file.processingFormat.sampleRate <= 600
    else {
      throw QwenASREvaluationError.unsupportedAudio
    }
    let (_, converted) = try loadAudioArray(from: audioURL, sampleRate: 16_000)
    let allSamples = converted.asArray(Float.self)
    let sourceID = UUID()
    let trackID = UUID()
    var pieces: [String] = []
    for start in stride(from: 0, to: allSamples.count, by: QwenASRPinnedArtifact.maximumSamples) {
      try InferenceCancellation.check()
      let end = min(allSamples.count, start + QwenASRPinnedArtifact.maximumSamples)
      let samples = Array(allSamples[start..<end])
      let digest = samples.withUnsafeBytes {
        String(SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined())
      }
      let sourceStart = UInt64(start) * 62_500
      let sourceEnd = UInt64(end) * 62_500
      let input = AudioRangeInput(
        sourceID: sourceID, trackID: trackID,
        assetReference: "in-memory-public-evaluation.raw", contentDigest: digest,
        monotonicStartNanoseconds: sourceStart, monotonicEndNanoseconds: sourceEnd,
        sampleRateHertz: 16_000, channelCount: 1)
      let configuration =
        QwenASRPinnedArtifact.pipelineRevision + "|"
        + QwenASRPinnedArtifact.treeSHA256 + "|" + QwenAlignmentPinnedArtifact.treeSHA256
        + "|" + dictionaryTerms.joined(separator: "\u{1f}")
      let configurationDigest = SHA256.hash(data: Data(configuration.utf8))
        .map { String(format: "%02x", $0) }.joined()
      let runtime = QwenASRRuntime(
        audioLoader: PublicEvaluationSamples(samples: samples), backend: backend, aligner: aligner)
      let adapter = PinnedOfflineASRAdapter(
        candidateID: QwenASRPinnedArtifact.candidateID,
        capabilities: QwenASRPinnedArtifact.descriptor.capabilities, runtime: runtime,
        artifact: QwenASRPinnedArtifact.descriptor)
      let request = ASRRequest(
        metadata: InferenceRequestMetadata(
          jobID: UUID(), inputRevision: 1,
          modelArtifactID: QwenASRPinnedArtifact.artifactID, configHash: configurationDigest),
        audio: input, mode: .final, languageHints: ["zh-CN", "en-US"],
        recognitionContext: ASRRecognitionContext(dictionaryTerms: dictionaryTerms))
      let result = try await adapter.transcribe(request)
      pieces.append(contentsOf: result.segments.map(\.text))
      timingRecords.append(
        TimingRecord(
          audioFileName: audioURL.lastPathComponent,
          durationSeconds: Double(samples.count) / 16_000,
          sourceStartNanoseconds: sourceStart, sourceEndNanoseconds: sourceEnd,
          segments: result.segments.map {
            CandidateRuntimeSegment(
              segmentID: $0.segmentID,
              monotonicStartNanoseconds: $0.monotonicStartNanoseconds,
              monotonicEndNanoseconds: $0.monotonicEndNanoseconds, text: $0.text,
              confidence: $0.confidence)
          }))
    }
    return SenseVoiceDictionaryNormalizer.join(pieces)
  }

  func writeTimings(to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(timingRecords).write(to: url, options: .atomic)
  }
}

private struct PublicEvaluationSamples: SenseVoiceAudioSampleLoading {
  let samples: [Float]
  func loadSamples(for input: AudioRangeInput) -> [Float] { samples }
}
