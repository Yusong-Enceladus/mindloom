import AVFoundation
import BestASRAlphaEvaluation
import BestASRModelManager
import Foundation
import MLXAudioCore

enum QwenAlignmentControls {
  static func run(options: [String: String]) async throws {
    guard options["--network-denied"] == "true" else {
      throw AlignmentEvaluationError.invalidArguments
    }
    let corpus = try AlphaASRLocalRun.decode(
      Data(
        contentsOf:
          QwenAlignmentEvaluation.path("--local-run", options)))
    let transcripts = try JSONDecoder().decode(
      AlphaASRLocalDiagnostics.self,
      from: Data(
        contentsOf:
          QwenAlignmentEvaluation.path("--transcript-diagnostics", options)))
    let byID = Dictionary(
      uniqueKeysWithValues: transcripts.samples.map { ($0.sampleUUID, $0.hypothesis) })
    let audioRoot = try QwenAlignmentEvaluation.path("--audio-root", options)
    let outputRoot = try QwenAlignmentEvaluation.externalPath("--output-root", options)
    let shiftedRoot = outputRoot.appendingPathComponent("shifted-audio")
    try FileManager.default.createDirectory(at: shiftedRoot, withIntermediateDirectories: true)
    let registry = try ManagedModelRegistry.decode(
      Data(
        contentsOf:
          QwenAlignmentEvaluation.path("--model-registry", options)))
    let manager = try LocalModelManager(
      rootDirectory:
        QwenAlignmentEvaluation.externalPath("--model-store", options), registry: registry)
    let active: ActiveManagedModel
    do {
      active = try await manager.discoverActive(
        artifactID: QwenAlignmentBackend.artifactID,
        healthCheck: FileSetModelHealthCheck())
    } catch {
      _ = try await manager.activate(
        artifactID: QwenAlignmentBackend.artifactID,
        version: QwenAlignmentBackend.revision,
        from: QwenAlignmentEvaluation.path("--model-source", options),
        healthCheck: FileSetModelHealthCheck())
      active = try await manager.discoverActive(
        artifactID: QwenAlignmentBackend.artifactID,
        healthCheck: FileSetModelHealthCheck())
    }
    let backend = QwenAlignmentBackend()
    try await backend.prepare(directory: active.directory)
    var chosen: [String: Int] = [:]
    var diagnostics: [[String: Any]] = []
    var deviations: [Double] = []
    var outOfRangeWords = 0
    var zeroDurationWords = 0
    for sample in corpus.samples {
      guard let text = byID[sample.sampleUUID], !text.isEmpty else { continue }
      let mixed = sample.tags.contains("mixed-language")
      let chinese = text.unicodeScalars.contains { (0x4e00...0x9fff).contains(Int($0.value)) }
      let group = mixed ? "mixed" : (chinese ? "chinese" : "english")
      guard mixed || sample.tags.contains("real-human"),
        chosen[group, default: 0] < (mixed ? 2 : 6),
        !sample.relativeAudioPath.hasPrefix("/"),
        !sample.relativeAudioPath.split(separator: "/").contains("..")
      else { continue }
      let original = audioRoot.appendingPathComponent(sample.relativeAudioPath)
      let file = try AVAudioFile(
        forReading: original, commonFormat: .pcmFormatFloat32, interleaved: false)
      guard file.processingFormat.sampleRate.isFinite, file.processingFormat.sampleRate > 0,
        file.processingFormat.channelCount == 1, file.length > 0,
        Double(file.length) / file.processingFormat.sampleRate <= 15
      else { continue }
      // Exactly the native conversion used by the existing ASR comparison,
      // before applying the known translation. Never resample the two control
      // variants separately or silently omit the original 22.05 kHz fixtures.
      let (_, converted) = try loadAudioArray(from: original, sampleRate: 16_000)
      let samples = converted.asArray(Float.self)
      let translatedSamples = Array(repeating: Float.zero, count: 16_000) + samples
      let duration = Double(samples.count) / 16_000
      let shifted = shiftedRoot.appendingPathComponent("\(sample.sampleUUID.uuidString).wav")
      guard !FileManager.default.fileExists(atPath: shifted.path),
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
        let target = AVAudioPCMBuffer(
          pcmFormat: format, frameCapacity: AVAudioFrameCount(translatedSamples.count)),
        let targetData = target.floatChannelData?[0]
      else { throw AlignmentEvaluationError.invalidAudio }
      translatedSamples.withUnsafeBufferPointer { pointer in
        targetData.update(from: pointer.baseAddress!, count: pointer.count)
      }
      target.frameLength = AVAudioFrameCount(translatedSamples.count)
      do {
        let writer = try AVAudioFile(forWriting: shifted, settings: format.settings)
        try writer.write(from: target)
      }
      let language = chinese ? "Chinese" : "English"
      let baseline = try await backend.align(samples: samples, text: text, language: language)
      let translated = try await backend.align(
        samples: translatedSamples, text: text, language: language)
      guard !baseline.isEmpty, baseline.map(\.text) == translated.map(\.text) else {
        throw AlignmentEvaluationError.wordCoverageMismatch
      }
      var localDeviations: [Double] = []
      for (a, b) in zip(baseline, translated) {
        guard a.startSeconds.isFinite, a.endSeconds.isFinite,
          b.startSeconds.isFinite, b.endSeconds.isFinite
        else {
          throw AlignmentEvaluationError.invalidAudio
        }
        for (word, length) in [(a, duration), (b, duration + 1)] {
          if word.startSeconds < 0 || word.endSeconds < word.startSeconds
            || word.endSeconds > length + 1.0 / 16_000
          {
            outOfRangeWords += 1
          }
          if word.startSeconds == word.endSeconds { zeroDurationWords += 1 }
        }
        localDeviations.append(abs(b.startSeconds - a.startSeconds - 1) * 1_000)
        localDeviations.append(abs(b.endSeconds - a.endSeconds - 1) * 1_000)
      }
      deviations += localDeviations
      chosen[group, default: 0] += 1
      func object(_ word: AlignmentWord) -> [String: Any] {
        ["text": word.text, "startSeconds": word.startSeconds, "endSeconds": word.endSeconds]
      }
      diagnostics.append([
        "sampleUUID": sample.sampleUUID.uuidString, "group": group, "durationSeconds": duration,
        "baseline": baseline.map(object), "shifted": translated.map(object),
        "meanTranslationDeviationMilliseconds": localDeviations.reduce(0, +)
          / Double(localDeviations.count),
        "maximumTranslationDeviationMilliseconds": localDeviations.max() ?? 0,
      ])
    }
    guard chosen["chinese"] == 6, chosen["english"] == 6, chosen["mixed"] == 2 else {
      throw AlignmentEvaluationError.invalidCorpus
    }
    deviations.sort()
    let summary: [String: Any] = [
      "schemaVersion": 1, "kind": "forced-alignment-translation-controls",
      "sourceCorpusManifestID": corpus.manifestID, "sourceCorpusVersion": corpus.version,
      "runtimeRevision": QwenASREvaluationArtifact.runtimeRevision,
      "modelArtifactID": QwenAlignmentBackend.artifactID,
      "modelRevision": QwenAlignmentBackend.revision,
      "modelTreeSHA256": active.descriptor.treeSHA256, "containsPrivateContent": false,
      "networkDenied": true, "releaseHoldout": false, "selectionEligible": false,
      "groups": chosen, "samples": diagnostics.count, "prefixSilenceSeconds": 1,
      "outOfRangeWords": outOfRangeWords, "zeroDurationWords": zeroDurationWords,
      "wordComparisons": deviations.count / 2,
      "meanTranslationDeviationMilliseconds": deviations.reduce(0, +) / Double(deviations.count),
      "medianTranslationDeviationMilliseconds": deviations[
        Int(ceil(Double(deviations.count) * 0.5)) - 1],
      "p95TranslationDeviationMilliseconds": deviations[
        Int(ceil(Double(deviations.count) * 0.95)) - 1],
      "maximumTranslationDeviationMilliseconds": deviations.last ?? 0,
      "fractionWithin160Milliseconds": Double(deviations.filter { $0 <= 160 }.count)
        / Double(deviations.count),
      "limitations": [
        "This checks a known one-second audio translation, not absolute phonetic-boundary truth.",
        "Text is taken from the existing Qwen ASR run; ASR accuracy is not rescored here.",
        "Six public Chinese, six public English and two synthetic mixed-language clips are a bounded tuning check only.",
        "Zero-duration quantized words must be coalesced before producing playable transcript segments.",
      ],
    ]
    for (name, object) in [
      ("local-diagnostics.json", diagnostics as Any), ("summary.json", summary as Any),
    ] {
      try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        .write(to: outputRoot.appendingPathComponent(name), options: .atomic)
    }
    print(
      "alignment translation controls measured: \(diagnostics.count) samples; not an accuracy/release claim"
    )
  }
}
