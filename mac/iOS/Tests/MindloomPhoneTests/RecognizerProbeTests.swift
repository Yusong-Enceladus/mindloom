import AVFoundation
import Foundation
import Speech
import XCTest

@testable import MindloomPhone

/// Step-by-step record of what the simulator's Speech framework does for
/// zh-CN, so the honest-limits notes can say exactly where it stops.
@MainActor
final class RecognizerProbeTests: XCTestCase {
  func testStepByStepAnalyzerSetup() async throws {
    var log: [String] = []
    func note(_ line: String) {
      log.append(line)
      print("MINDLOOM-PROBE \(line)")
    }
    let locale = Locale(identifier: "zh-CN")
    let english = Locale(identifier: "en-US")
    note(
      "en-US speechTranscriber supported=\(await SpeechTranscriber.supportedLocale(equivalentTo: english)?.identifier ?? "none")"
    )
    for choice in [
      RecognizerChoice.speechTranscriber(locale), RecognizerChoice.dictationTranscriber(locale),
      RecognizerChoice.speechTranscriber(english), RecognizerChoice.dictationTranscriber(english),
    ] {
      guard let module = TranscriberModule.make(choice)?.module else { continue }
      let status = await AssetInventory.status(forModules: [module])
      note("\(choice.kindName)[\(choice.localeID)] status=\(status)")
      let started = Date()
      do {
        let request = try await AssetInventory.assetInstallationRequest(supporting: [module])
        note(
          "\(choice.kindName)[\(choice.localeID)] installationRequest=\(request == nil ? "none-needed" : "present")"
        )
        if let request {
          do {
            try await request.downloadAndInstall()
            note(
              "\(choice.kindName)[\(choice.localeID)] downloadAndInstall=ok after \(Int(Date().timeIntervalSince(started)))s"
            )
          } catch {
            note("\(choice.kindName)[\(choice.localeID)] downloadAndInstall error=\(error)")
          }
        }
      } catch {
        note("\(choice.kindName)[\(choice.localeID)] installationRequest error=\(error)")
      }
      let after = await AssetInventory.status(forModules: [module])
      note("\(choice.kindName)[\(choice.localeID)] statusAfter=\(after)")
      let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
      note(
        "\(choice.kindName)[\(choice.localeID)] bestFormat=\(format.map { "\($0.sampleRate)Hz/\($0.channelCount)ch/\($0.commonFormat.rawValue)" } ?? "nil")"
      )
    }
    // Straight from the file, the simplest SpeechAnalyzer path there is.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "probe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = try await SyntheticSpeech.makeFile(
      SyntheticSpeech.mandarinSentence, language: "zh-CN", in: directory)
    let englishURL = try await SyntheticSpeech.makeFile(
      SyntheticSpeech.englishSentence, language: "en-US", in: directory)
    note("synthetic speech: \(url.lastPathComponent), \(englishURL.lastPathComponent)")
    for (choice, url) in [
      (RecognizerChoice.speechTranscriber(locale), url),
      (RecognizerChoice.dictationTranscriber(locale), url),
      (RecognizerChoice.speechTranscriber(english), englishURL),
      (RecognizerChoice.dictationTranscriber(english), englishURL),
    ] {
      guard let module = TranscriberModule.make(choice) else { continue }
      let formats = await module.module.availableCompatibleAudioFormats
      note("\(choice.kindName)[\(choice.localeID)] compatibleFormats=\(formats.count)")
      let started = Date()
      let collector = Task { () -> String in
        let text = TranscriptAccumulator()
        try? await module.results { piece, isFinal in _ = text.update(piece, isFinal: isFinal) }
        return text.text
      }
      do {
        let file = try AVAudioFile(forReading: url)
        let analyzer = try await SpeechAnalyzer(
          inputAudioFile: file, modules: [module.module], finishAfterFile: true)
        _ = analyzer
        let text = await withTaskGroup(of: String?.self) { group in
          group.addTask { await collector.value }
          group.addTask {
            try? await Task.sleep(for: .seconds(60))
            return nil
          }
          let first = await group.next() ?? nil
          group.cancelAll()
          return first
        }
        note(
          "\(choice.kindName)[\(choice.localeID)] fileAnalysis text=\(text ?? "<timeout>") after \(Int(Date().timeIntervalSince(started)))s"
        )
      } catch {
        collector.cancel()
        note(
          "\(choice.kindName)[\(choice.localeID)] fileAnalysis error=\(error) after \(Int(Date().timeIntervalSince(started)))s"
        )
      }
    }
    let attachment = XCTAttachment(string: log.joined(separator: "\n"))
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
