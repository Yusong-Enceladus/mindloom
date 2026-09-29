import BestASRCandidateAdapters
import BestASRFluidRuntime
import BestASRInference
import BestASRModelManager
import BestASRRecognition
import CryptoKit
import Foundation
import OSLog

private let qwenTimingLogger = Logger(subsystem: "com.bestasr.app", category: "qwen-final-asr")

/// Logs one stage duration and the audio length only; never text or audio.
func logQwenStage(_ stage: String, since start: ContinuousClock.Instant, samples: Int) {
  let elapsed = ContinuousClock.now - start
  let milliseconds =
    elapsed.components.seconds * 1_000
    + elapsed.components.attoseconds / 1_000_000_000_000_000
  qwenTimingLogger.notice(
    "dictation timing stage=\(stage, privacy: .public) ms=\(milliseconds, privacy: .public) audio_ms=\(samples / 16, privacy: .public)"
  )
}

/// Final recognition for every input mode. Audio comes exclusively from the
/// authenticated journal derivative loader; no original source is rewritten.
public struct QwenASRRuntime: CandidateASRRuntime {
  private let audioLoader: any SenseVoiceAudioSampleLoading
  private let backend: any QwenASRSampleTranscribing
  private let aligner: any QwenWordsAligning
  private let speculation: QwenSpeculativeDecodeCache?
  private let dictionary = SenseVoiceDictionaryNormalizer()

  public init(
    audioLoader: any SenseVoiceAudioSampleLoading,
    backend: any QwenASRSampleTranscribing,
    aligner: any QwenWordsAligning,
    speculation: QwenSpeculativeDecodeCache? = nil
  ) {
    self.audioLoader = audioLoader
    self.backend = backend
    self.aligner = aligner
    self.speculation = speculation
  }

  /// Drops every speculative decode, e.g. when a new dictation starts.
  public func clearSpeculation() async {
    await speculation?.clear()
  }

  /// Drops the pause decode when speech resumes; completed windows stay.
  public func clearPauseSpeculation() async {
    await speculation?.clearPause()
  }

  /// Decodes and aligns the dictation window still being filled when the
  /// speaker pauses (see `QwenSpeculativeDecodeCache`). Returns at once; the
  /// work runs in the background until finished, replaced or cleared.
  public func speculate(
    samples: [Float], dictionaryTerms: [String],
    onText: (@Sendable (String) async -> Void)? = nil
  ) async {
    guard let speculation, samples.count >= QwenSpeculativeDecodeCache.minimumSamples,
      samples.count <= QwenASRPinnedArtifact.maximumSamples
    else { return }
    await speculation.startPause(
      samples: samples,
      speculativeWork(samples: samples, dictionaryTerms: dictionaryTerms, onText: onText))
  }

  /// Decodes a dictation window that is already final while the user keeps
  /// speaking, so release only has to decode the last window.
  public func precomputeWindow(
    samples: [Float], dictionaryTerms: [String],
    onText: (@Sendable (String) async -> Void)? = nil
  ) async {
    guard let speculation, !samples.isEmpty,
      samples.count <= QwenASRPinnedArtifact.maximumSamples
    else { return }
    await speculation.startWindow(
      samples: samples,
      speculativeWork(samples: samples, dictionaryTerms: dictionaryTerms, onText: onText))
  }

  /// `onText` receives the recognized text (no timings) once the decode
  /// finishes uncancelled, e.g. to show it while the user is still speaking.
  private func speculativeWork(
    samples: [Float], dictionaryTerms: [String],
    onText: (@Sendable (String) async -> Void)?
  ) -> @Sendable () async -> QwenSpeculativeDecodeCache.Decoded? {
    let backend = backend
    let aligner = aligner
    return {
      let started = ContinuousClock.now
      guard
        let recognized = try? await backend.transcribe(
          samples: samples, dictionaryTerms: dictionaryTerms)
      else { return nil }
      let raw = recognized.text.trimmingCharacters(in: .whitespacesAndNewlines)
      var words: [TranscriptAlignmentWord] = []
      if !raw.isEmpty {
        guard
          let aligned = try? await aligner.align(
            samples: samples, text: raw, language: recognized.language)
        else { return nil }
        words = aligned
      }
      guard !Task.isCancelled else { return nil }
      logQwenStage("qwen-speculate", since: started, samples: samples.count)
      await onText?(raw)
      return QwenSpeculativeDecodeCache.Decoded(
        samples: samples, dictionaryTerms: dictionaryTerms, recognized: recognized,
        words: words)
    }
  }

  /// Loads the aligner in the background, so the first dictation after the
  /// App has been idle does not pay for it on the insert path.
  public func warmAlignment() async {
    try? await aligner.prepare()
  }

  /// Releases every model this runtime holds. The next dictation loads them
  /// again; `warmUp` and `warmAlignment` cover that before the user speaks.
  public func releaseModels() async {
    await speculation?.clear()
    await backend.release()
    await aligner.release()
    QwenRuntimeMemory.trimNow()
  }

  /// Runs one throwaway decode on 0.3 s of a faint synthetic tone. After a
  /// long idle the OS may have reclaimed model pages, and the first decode
  /// after launch compiles GPU kernels; paying either cost while the user is
  /// still speaking keeps it off the End-to-insert path. The backend actor
  /// serializes this with any real decode that follows.
  public func warmUp() async {
    let samples = (0..<4_800).map { Float(sin(Double($0) * 0.07)) * 0.002 }
    let started = ContinuousClock.now
    _ = try? await backend.transcribe(samples: samples, dictionaryTerms: [])
    logQwenStage("qwen-warmup", since: started, samples: samples.count)
  }

  public func networkPolicy() async -> CandidateRuntimeNetworkPolicy {
    .modelManagerVerifiedArtifactsOnly
  }

  public func transcribe(_ request: ASRRequest, candidateID: String) async throws
    -> CandidateRuntimeOutput
  {
    try InferenceCancellation.check()
    guard candidateID == QwenASRPinnedArtifact.candidateID,
      request.metadata.modelArtifactID == QwenASRPinnedArtifact.artifactID,
      request.mode != .streaming,
      request.audio.sampleRateHertz == 16_000, request.audio.channelCount == 1,
      request.audio.monotonicEndNanoseconds > request.audio.monotonicStartNanoseconds
    else { throw qwenFailure(.invalidRequest, "qwen-final-request-invalid", false) }
    let loadStarted = ContinuousClock.now
    let samples = try await audioLoader.loadSamples(for: request.audio)
    logQwenStage("qwen-load-audio", since: loadStarted, samples: samples.count)
    try InferenceCancellation.check()
    guard !samples.isEmpty, samples.count <= QwenASRPinnedArtifact.maximumSamples,
      samples.allSatisfy(\.isFinite)
    else {
      throw qwenFailure(.corruptInput, "qwen-final-audio-invalid", false)
    }
    // Only digital silence can be skipped without asking the ASR model.
    // Absolute RMS/peak gates discarded real quiet speech in the public
    // corpus. Qwen itself handles non-speech; keep full context and amplitude.
    guard samples.contains(where: { $0 != 0 }) else {
      return CandidateRuntimeOutput(
        revisionID: identifier("revision", request: request, text: ""), segments: [])
    }
    do {
      let decodeStarted = ContinuousClock.now
      let terms = request.recognitionContext.dictionaryTerms
      let speculated = await speculation?.take(matching: samples, dictionaryTerms: terms)
      if speculation != nil, speculated == nil, await speculation?.hadCandidate == true {
        qwenTimingLogger.notice("speculation not reused: audio or dictionary differs")
      }
      let result: QwenRecognizedText
      if let speculated {
        result = speculated.recognized
        logQwenStage("qwen-speculative-hit", since: decodeStarted, samples: samples.count)
      } else {
        result = try await backend.transcribe(samples: samples, dictionaryTerms: terms)
        logQwenStage("qwen-decode", since: decodeStarted, samples: samples.count)
      }
      try InferenceCancellation.check()
      let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if raw.isEmpty {
        return CandidateRuntimeOutput(
          revisionID: identifier("revision", request: request, text: ""), segments: [],
          detectedLanguage: canonicalLanguage(result.language))
      }
      let words: [TranscriptAlignmentWord]
      if let speculated {
        words = speculated.words
      } else {
        let alignStarted = ContinuousClock.now
        words = try await aligner.align(samples: samples, text: raw, language: result.language)
        logQwenStage("qwen-align", since: alignStarted, samples: samples.count)
      }
      try InferenceCancellation.check()
      let duration = Double(samples.count) / 16_000
      let phrases = try AlignedTranscriptAssembler().assemble(
        text: raw, words: words, durationSeconds: duration,
        quantizationSeconds: QwenAlignmentPinnedArtifact.quantizationSeconds)
      let span = request.audio.monotonicEndNanoseconds - request.audio.monotonicStartNanoseconds
      func offset(_ seconds: Double) -> UInt64 {
        min(span, UInt64((seconds / duration * Double(span)).rounded()))
      }
      let segments = try phrases.enumerated().map { index, phrase in
        let text = dictionary.normalize(
          phrase.text.trimmingCharacters(in: .whitespacesAndNewlines),
          dictionaryTerms: request.recognitionContext.dictionaryTerms,
          dictionaryHints: request.recognitionContext.dictionaryHints)
        let start = offset(phrase.startSeconds)
        let end = offset(phrase.endSeconds)
        guard !text.isEmpty, start < end else {
          throw qwenFailure(.transientRuntime, "qwen-final-segment-invalid", true)
        }
        return CandidateRuntimeSegment(
          segmentID: identifier("segment-\(index)-\(start)-\(end)", request: request, text: text),
          monotonicStartNanoseconds: request.audio.monotonicStartNanoseconds + start,
          monotonicEndNanoseconds: request.audio.monotonicStartNanoseconds + end,
          text: text, confidence: nil)
      }
      try InferenceCancellation.check()
      return CandidateRuntimeOutput(
        revisionID: identifier("revision", request: request, text: raw), segments: segments,
        detectedLanguage: canonicalLanguage(result.language))
    } catch is CancellationError { throw InferenceEngineError.cancelled } catch let error
      as InferenceEngineError
    { throw error } catch is TranscriptAlignmentError {
      // Reject the entire candidate result; the caller's old local final-ASR
      // route remains available with its own honest artifact provenance.
      throw qwenFailure(.transientRuntime, "qwen-final-alignment-invalid", true)
    } catch { throw qwenFailure(.transientRuntime, "qwen-final-runtime-failed", true) }
  }

  private func canonicalLanguage(_ language: String?) -> String? {
    switch language?.lowercased() {
    case "chinese", "mandarin", "zh": "zh-CN"
    case "english", "en": "en-US"
    case "cantonese", "yue": "yue-HK"
    case "japanese", "ja": "ja-JP"
    case "korean", "ko": "ko-KR"
    default: nil
    }
  }

  private func identifier(_ namespace: String, request: ASRRequest, text: String) -> UUID {
    let seed = [
      namespace, QwenASRPinnedArtifact.pipelineRevision, QwenASRPinnedArtifact.treeSHA256,
      QwenAlignmentPinnedArtifact.treeSHA256,
      request.metadata.jobID.uuidString.lowercased(), String(request.metadata.inputRevision),
      request.metadata.configHash, request.audio.contentDigest,
      String(request.audio.monotonicStartNanoseconds),
      String(request.audio.monotonicEndNanoseconds),
      request.mode.rawValue, request.supersedesRevisionID?.uuidString.lowercased() ?? "none", text,
    ].joined(separator: "\u{1f}")
    var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
}

public enum QwenASRRuntimeFactory {
  public static func make(modelManager: LocalModelManager, audioAssetRoot: URL) async throws
    -> QwenASRRuntime
  {
    try await make(
      modelManager: modelManager,
      audioLoader: try Float32PCMFileLoader(
        rootDirectory: audioAssetRoot,
        maximumSamples: QwenASRPinnedArtifact.maximumSamples),
      speculation: QwenSpeculativeDecodeCache())
  }

  /// The same verified artifacts and backends as the App, with a
  /// caller-supplied sample loader for offline evaluation over local files.
  public static func makeForEvaluation(
    modelManager: LocalModelManager,
    audioLoader: any SenseVoiceAudioSampleLoading
  ) async throws -> QwenASRRuntime {
    try await make(modelManager: modelManager, audioLoader: audioLoader)
  }

  private static func make(
    modelManager: LocalModelManager,
    audioLoader: any SenseVoiceAudioSampleLoading,
    speculation: QwenSpeculativeDecodeCache? = nil
  ) async throws -> QwenASRRuntime {
    let asr = try await modelManager.discoverActive(
      artifactID: QwenASRPinnedArtifact.artifactID, healthCheck: FileSetModelHealthCheck())
    let alignment = try await modelManager.discoverActive(
      artifactID: QwenAlignmentPinnedArtifact.artifactID, healthCheck: FileSetModelHealthCheck())
    guard asr.descriptor.version == QwenASRPinnedArtifact.sourceRevision,
      asr.descriptor.treeSHA256 == QwenASRPinnedArtifact.treeSHA256,
      alignment.descriptor.version == QwenAlignmentPinnedArtifact.sourceRevision,
      alignment.descriptor.treeSHA256 == QwenAlignmentPinnedArtifact.treeSHA256
    else {
      throw qwenFailure(.incompatibleArtifact, "qwen-final-active-artifact-mismatch", true)
    }
    let backend = QwenASRBackend(verifiedModelDirectory: asr.directory)
    let aligner = QwenForcedAlignmentBackend(verifiedModelDirectory: alignment.directory)
    try await backend.prepare()
    // Not the aligner: word timestamps are history metadata, so its 1.3 GB
    // loads when a dictation actually needs them, warmed in the background
    // as the user starts speaking.
    return QwenASRRuntime(
      audioLoader: audioLoader, backend: backend, aligner: aligner, speculation: speculation)
  }
}
