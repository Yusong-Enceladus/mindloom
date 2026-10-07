@preconcurrency import AVFoundation
import Foundation
import os

/// The watch's microphone recorder (WATCH-002): mono AAC in an ADTS stream, so a recording that is
/// cut short (the app ended) still plays up to where it stopped. It starts only in the foreground
/// (watchOS does not allow starting in the background) and keeps recording with the wrist down
/// (`UIBackgroundModes` audio). A call or Siri ends it; what was recorded is kept. At the part
/// limit the next part starts on the same audio session (`continueRecording`), so a long
/// recording goes on with the wrist down.
@MainActor
protocol WatchAudioRecorder: AnyObject {
  /// Called when the system ended the recording (an interruption, an encoder error).
  var onEnded: (() -> Void)? { get set }
  func start(writingTo url: URL) async throws
  /// Ends the current part and goes on into `url` at once, keeping the audio session (works with
  /// the wrist down). Returns the seconds of the part that ended. Throws when the next part does
  /// not start; recording has then stopped and the ended part is complete.
  func continueRecording(writingTo url: URL) throws -> TimeInterval
  /// Stops and returns the seconds recorded.
  func stop() -> TimeInterval
  /// 0…1, for the level ring.
  func level() -> Double
}

enum WatchRecorderError: Error, Equatable {
  case microphoneDenied
  case couldNotStart
}

/// The settings both the recorder and the DEBUG stand-in write with.
enum WatchAudioFormat {
  static let sampleRate = 24_000.0
  static let bitRate = 48_000

  static var settings: [String: Any] {
    [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: bitRate,
    ]
  }

  /// Seconds of audio in a file (nil when it cannot be read).
  static func duration(of url: URL) -> TimeInterval? {
    guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else {
      return nil
    }
    return Double(file.length) / file.fileFormat.sampleRate
  }
}

@MainActor
final class MicrophoneRecorder: NSObject, WatchAudioRecorder, AVAudioRecorderDelegate {
  var onEnded: (() -> Void)?
  private var recorder: AVAudioRecorder?
  private var interruption: NSObjectProtocol?
  private let log = Logger(subsystem: "app.mindloom.watchkitapp", category: "recorder")

  func start(writingTo url: URL) async throws {
    guard await AVAudioApplication.requestRecordPermission() else {
      throw WatchRecorderError.microphoneDenied
    }
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.record, mode: .default, options: [])
      try session.setActive(true)
      let recorder = try AVAudioRecorder(url: url, settings: WatchAudioFormat.settings)
      recorder.delegate = self
      recorder.isMeteringEnabled = true
      guard recorder.record() else { throw WatchRecorderError.couldNotStart }
      self.recorder = recorder
    } catch {
      log.error("recording did not start: \(String(describing: error), privacy: .public)")
      try? session.setActive(false)
      throw WatchRecorderError.couldNotStart
    }
    interruption = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: session, queue: .main
    ) { [weak self] note in
      let began =
        (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
        .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
      guard began else { return }
      MainActor.assumeIsolated { self?.onEnded?() }
    }
  }

  func continueRecording(writingTo url: URL) throws -> TimeInterval {
    guard let current = recorder else { throw WatchRecorderError.couldNotStart }
    // Ready before the current part ends, so the gap is as short as it can be.
    let next: AVAudioRecorder
    do {
      next = try AVAudioRecorder(url: url, settings: WatchAudioFormat.settings)
      next.delegate = self
      next.isMeteringEnabled = true
      _ = next.prepareToRecord()
    } catch {
      _ = stop()
      throw WatchRecorderError.couldNotStart
    }
    let seconds = current.currentTime
    current.stop()
    guard next.record() else {
      recorder = nil
      endSession()
      log.error("next part did not start")
      throw WatchRecorderError.couldNotStart
    }
    recorder = next
    return seconds
  }

  func stop() -> TimeInterval {
    guard let recorder else { return 0 }
    let seconds = recorder.currentTime
    recorder.stop()
    self.recorder = nil
    endSession()
    return seconds
  }

  private func endSession() {
    if let interruption { NotificationCenter.default.removeObserver(interruption) }
    interruption = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  func level() -> Double {
    guard let recorder else { return 0 }
    recorder.updateMeters()
    // -50 dB → 0, 0 dB → 1.
    return min(1, max(0, (Double(recorder.averagePower(forChannel: 0)) + 50) / 50))
  }

  nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
    Task { @MainActor in self.onEnded?() }
  }

  /// The system stopped the recorder (not `stop()` or the next part): the recording ends here.
  nonisolated func audioRecorderDidFinishRecording(
    _ recorder: AVAudioRecorder, successfully flag: Bool
  ) {
    let ended = ObjectIdentifier(recorder)
    Task { @MainActor in
      guard let current = self.recorder, ObjectIdentifier(current) == ended else { return }
      self.onEnded?()
    }
  }
}

#if DEBUG
  /// DEBUG only (`-MindloomWatchFakeRecording <path or 1>`): never opens the microphone. Stopping
  /// writes, with the recorder's own settings, the synthetic audio file at `path` (for example
  /// speech from the Mac's `say`), or with `1` a synthetic tone as long as the recording ran. For
  /// simulators and UI tests.
  @MainActor
  final class SyntheticRecorder: WatchAudioRecorder {
    var onEnded: (() -> Void)?
    private let source: String
    private var target: URL?
    private var startedAt: Date?

    init(source: String) {
      self.source = source
    }

    static func fromLaunchArguments() -> SyntheticRecorder? {
      guard let value = UserDefaults.standard.string(forKey: "MindloomWatchFakeRecording"),
        !value.isEmpty
      else { return nil }
      return SyntheticRecorder(source: value)
    }

    func start(writingTo url: URL) async throws {
      target = url
      startedAt = Date()
    }

    func continueRecording(writingTo url: URL) throws -> TimeInterval {
      let seconds = stop()
      target = url
      startedAt = Date()
      return seconds
    }

    func stop() -> TimeInterval {
      guard let target, let startedAt else { return 0 }
      self.target = nil
      let elapsed = Date().timeIntervalSince(startedAt)
      do {
        if source != "1", FileManager.default.fileExists(atPath: source) {
          try Self.encode(URL(fileURLWithPath: source), to: target)
        } else {
          try Self.tone(seconds: max(1, elapsed), to: target)
        }
      } catch {
        return 0
      }
      return WatchAudioFormat.duration(of: target) ?? elapsed
    }

    func level() -> Double {
      0.4 + 0.3 * sin(Date().timeIntervalSinceReferenceDate * 6)
    }

    private static func encode(_ source: URL, to target: URL) throws {
      let input = try AVAudioFile(forReading: source)
      let output = try AVAudioFile(
        forWriting: target, settings: WatchAudioFormat.settings, commonFormat: .pcmFormatFloat32,
        interleaved: false)
      guard
        let converter = AVAudioConverter(from: input.processingFormat, to: output.processingFormat)
      else { throw WatchRecorderError.couldNotStart }
      let chunk: AVAudioFrameCount = 4096
      while input.framePosition < input.length {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk)
        else { break }
        try input.read(into: buffer, frameCount: chunk)
        if buffer.frameLength == 0 { break }
        let ratio = output.processingFormat.sampleRate / input.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard
          let converted = AVAudioPCMBuffer(
            pcmFormat: output.processingFormat, frameCapacity: capacity)
        else { break }
        let given = Given()
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
          if given.value {
            status.pointee = .noDataNow
            return nil
          }
          given.value = true
          status.pointee = .haveData
          return buffer
        }
        if let error { throw error }
        if converted.frameLength > 0 { try output.write(from: converted) }
      }
    }

    private final class Given: @unchecked Sendable {
      var value = false
    }

    private static func tone(seconds: Double, to target: URL) throws {
      let output = try AVAudioFile(
        forWriting: target, settings: WatchAudioFormat.settings, commonFormat: .pcmFormatFloat32,
        interleaved: false)
      let rate = output.processingFormat.sampleRate
      let frames = AVAudioFrameCount(rate * seconds)
      guard
        let buffer = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: frames),
        let samples = buffer.floatChannelData?[0]
      else { return }
      buffer.frameLength = frames
      for index in 0..<Int(frames) {
        samples[index] = Float(0.2 * sin(2 * Double.pi * 220 * Double(index) / rate))
      }
      try output.write(from: buffer)
    }
  }
#endif
