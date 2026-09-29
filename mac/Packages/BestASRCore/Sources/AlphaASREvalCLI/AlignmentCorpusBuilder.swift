import AVFoundation
import CryptoKit
import Foundation

/// Derives a small alignment-only tuning set from the already downloaded,
/// versioned AMI corpus. Never opens the release-holdout meetings or changes
/// the speaker corpus, original WAVs, or source annotations.
enum AlignmentCorpusBuilder {
  private struct Plan: Decodable {
    let schemaVersion: Int
    let datasetVersion: String
    let meetings: [Meeting]
  }
  private struct Meeting: Decodable {
    let meetingID: String
    let split: String
    let speakers: [Speaker]
  }
  private struct Speaker: Decodable {
    let label: String
    let headsetSignal: String
  }

  static func build(options: [String: String]) throws {
    let planURL = try QwenAlignmentEvaluation.path("--plan", options)
    let source = try QwenAlignmentEvaluation.path("--source-root", options)
    let output = try QwenAlignmentEvaluation.externalPath("--output-root", options)
    let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: planURL))
    guard plan.schemaVersion == 1, plan.datasetVersion == "1.6.2",
      !FileManager.default.fileExists(atPath: output.appendingPathComponent("local-run.json").path)
    else { throw AlignmentEvaluationError.invalidArguments }
    let audioRoot = output.appendingPathComponent("audio")
    try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
    var samples: [AlignmentSample] = []
    for meeting in plan.meetings where meeting.split == "tuning" {
      guard safeComponent(meeting.meetingID) else { throw AlignmentEvaluationError.invalidCorpus }
      for speaker in meeting.speakers {
        guard safeComponent(speaker.label), safeComponent(speaker.headsetSignal) else {
          throw AlignmentEvaluationError.invalidCorpus
        }
        let annotations = source.appendingPathComponent("annotations/words")
          .appendingPathComponent("\(meeting.meetingID).\(speaker.label).words.xml")
        let parser = XMLParser(contentsOf: annotations)
        let collector = WordCollector()
        parser?.shouldResolveExternalEntities = false
        parser?.delegate = collector
        guard parser?.parse() == true else { throw AlignmentEvaluationError.invalidCorpus }
        let windows = selectWindows(collector.words)
        guard !windows.isEmpty else { throw AlignmentEvaluationError.invalidCorpus }
        let original = source.appendingPathComponent(
          "\(meeting.meetingID).\(speaker.headsetSignal).wav")
        let file = try AVAudioFile(
          forReading: original, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 16_000,
          file.processingFormat.channelCount == 1
        else { throw AlignmentEvaluationError.invalidAudio }
        for words in windows {
          let lower = AVAudioFramePosition(max(0, floor((words[0].startSeconds - 0.25) * 16_000)))
          let upper = min(
            file.length, AVAudioFramePosition(ceil((words.last!.endSeconds + 0.25) * 16_000)))
          guard upper > lower, upper <= file.length, upper - lower <= 30 * 16_000,
            words.last!.endSeconds <= Double(file.length) / 16_000
          else { throw AlignmentEvaluationError.invalidAudio }
          let name = "\(meeting.meetingID)-\(speaker.label)-\(lower)-\(upper).wav"
          let destination = audioRoot.appendingPathComponent(name)
          guard !FileManager.default.fileExists(atPath: destination.path),
            let buffer = AVAudioPCMBuffer(
              pcmFormat: file.processingFormat,
              frameCapacity: AVAudioFrameCount(upper - lower))
          else { throw AlignmentEvaluationError.invalidArguments }
          file.framePosition = lower
          try file.read(into: buffer, frameCount: AVAudioFrameCount(upper - lower))
          guard buffer.frameLength == AVAudioFrameCount(upper - lower) else {
            throw AlignmentEvaluationError.invalidAudio
          }
          let target = try AVAudioFile(
            forWriting: destination, settings: file.processingFormat.settings)
          try target.write(from: buffer)
          let offset = Double(lower) / 16_000
          samples.append(
            AlignmentSample(
              sampleUUID: stableID(name), relativeAudioPath: name,
              sourceMeeting: meeting.meetingID, sourceSpeaker: speaker.label,
              sourceStartSeconds: offset, durationSeconds: Double(upper - lower) / 16_000,
              words: words.map {
                AlignmentWord(
                  text: $0.text, startSeconds: $0.startSeconds - offset,
                  endSeconds: $0.endSeconds - offset)
              }
            ))
        }
      }
    }
    guard !samples.isEmpty else { throw AlignmentEvaluationError.invalidCorpus }
    let run = AlignmentCorpusRun(
      schemaVersion: 1, manifestID: "ami-public-alignment-tuning-v1",
      version: "1.0.0", datasetVersion: plan.datasetVersion, releaseHoldout: false, samples: samples
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(run).write(
      to: output.appendingPathComponent("local-run.json"), options: .atomic)
    let manifest: [String: Any] = [
      "schemaVersion": 1, "manifestID": run.manifestID, "version": run.version,
      "datasetID": "ami-meeting-corpus", "datasetVersion": plan.datasetVersion,
      "sourcePlan": "config/ami-speaker-evaluation.json", "releaseHoldout": false,
      "referenceTimingProvenance":
        "AMI manual transcripts with automatically forced-aligned word timings; not human phonetic boundary ground truth",
      "referenceTimingDocumentation": "https://groups.inf.ed.ac.uk/ami/corpus/transcription.shtml",
      "license": "CC-BY-4.0", "licenseNotice": "Legal/AMI-Corpus-NOTICE-CC-BY-4.0.txt",
      "selection":
        "First up to four 3–12 second contiguous 8–40 word windows per tuning speaker; gap at most 0.7 seconds; 250 ms audio padding. Selection made before model evaluation.",
      "containsPrivateContent": false,
      "samples": samples.map { sample -> [String: Any] in
        [
          "sampleUUID": sample.sampleUUID.uuidString, "relativeAudioPath": sample.relativeAudioPath,
          "sourceMeeting": sample.sourceMeeting, "sourceSpeaker": sample.sourceSpeaker,
          "sourceStartSeconds": sample.sourceStartSeconds,
          "durationSeconds": sample.durationSeconds,
          "wordCount": sample.words.count,
        ]
      },
    ]
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
    print("alignment tuning corpus prepared: \(samples.count) clips; original corpus untouched")
  }

  private static func selectWindows(_ words: [AlignmentWord]) -> [[AlignmentWord]] {
    var windows: [[AlignmentWord]] = []
    var current: [AlignmentWord] = []
    func finish() {
      if current.count >= 8, let first = current.first, let last = current.last,
        last.endSeconds - first.startSeconds >= 3
      {
        windows.append(current)
      }
      current = []
    }
    for word in words.sorted(by: { $0.startSeconds < $1.startSeconds }) {
      if let first = current.first, let last = current.last,
        word.startSeconds - last.endSeconds > 0.7
          || word.endSeconds - first.startSeconds > 12 || current.count >= 40
      {
        finish()
        if windows.count == 4 { break }
      }
      current.append(word)
    }
    if windows.count < 4 { finish() }
    return Array(windows.prefix(4))
  }

  private static func safeComponent(_ value: String) -> Bool {
    !value.isEmpty
      && value.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || $0 == "-"
      }
  }

  private static func stableID(_ name: String) -> UUID {
    var bytes = Array(
      SHA256.hash(data: Data("ami-public-alignment-tuning-v1/\(name)".utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }

  private final class WordCollector: NSObject, XMLParserDelegate {
    var words: [AlignmentWord] = []
    private var timing: (Double, Double)?
    private var content = ""

    func parser(
      _ parser: XMLParser, didStartElement elementName: String,
      namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]
    ) {
      guard elementName == "w" else { return }
      content = ""
      timing = nil
      guard attributes["punc"] != "true", attributes["trunc"] != "true",
        let start = attributes["starttime"].flatMap(Double.init),
        let end = attributes["endtime"].flatMap(Double.init),
        start.isFinite, end.isFinite, start >= 0, end > start
      else { return }
      timing = (start, end)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
      if timing != nil { content += string }
    }

    func parser(
      _ parser: XMLParser, didEndElement elementName: String,
      namespaceURI: String?, qualifiedName qName: String?
    ) {
      guard elementName == "w" else { return }
      defer {
        timing = nil
        content = ""
      }
      guard let (start, end) = timing else { return }
      // The aligner intentionally ignores punctuation; retain source word
      // timings while applying its documented letter/number/apostrophe form.
      let cleaned = String(content.filter { $0.isLetter || $0.isNumber || $0 == "'" })
      guard !cleaned.isEmpty else { return }
      words.append(AlignmentWord(text: cleaned, startSeconds: start, endSeconds: end))
    }
  }
}
