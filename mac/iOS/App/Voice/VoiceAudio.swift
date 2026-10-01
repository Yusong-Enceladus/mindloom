@preconcurrency import AVFoundation
import Foundation
import MindloomPhoneKit
import os

/// Receives microphone buffers for one open utterance. Called on the audio
/// thread; implementations must be thread-safe.
protocol AudioSink: AnyObject, Sendable {
  func append(_ buffer: AVAudioPCMBuffer)
}

/// Hands buffers to the open utterance, or drops them. Between utterances
/// there is no sink and every buffer is discarded the moment it arrives:
/// nothing is kept, measured or written (PHONE-CONTRACT §2).
final class AudioRouter: @unchecked Sendable {
  private let lock = NSLock()
  private var sink: (any AudioSink)?

  var hasSink: Bool {
    lock.lock()
    defer { lock.unlock() }
    return sink != nil
  }

  func attach(_ sink: any AudioSink) {
    lock.lock()
    self.sink = sink
    lock.unlock()
  }

  /// Detaches `sink` if it is still the current one.
  func detach(_ sink: any AudioSink) {
    lock.lock()
    if self.sink === sink { self.sink = nil }
    lock.unlock()
  }

  func detachAll() {
    lock.lock()
    sink = nil
    lock.unlock()
  }

  @discardableResult
  func route(_ buffer: AVAudioPCMBuffer) -> Bool {
    lock.lock()
    let current = sink
    lock.unlock()
    guard let current else { return false }
    current.append(buffer)
    return true
  }
}

/// Turns buffers into the waveform level (0…1), written to the App Group
/// about 20 times a second, only while an utterance is open.
final class LevelMeter: @unchecked Sendable {
  private let channel: VoiceChannel
  private let lock = NSLock()
  private var lastWrite: CFAbsoluteTime = 0
  private var smoothed: Float = 0

  init(channel: VoiceChannel) {
    self.channel = channel
  }

  func feed(_ buffer: AVAudioPCMBuffer) {
    guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
    let frames = Int(buffer.frameLength)
    var sum: Float = 0
    let samples = data[0]
    for index in 0..<frames { sum += samples[index] * samples[index] }
    let rms = sqrt(sum / Float(frames))
    let decibels = 20 * log10(max(rms, 1e-7))
    // −55 dB (room) … −12 dB (close speech).
    let level = max(0, min(1, (decibels + 55) / 43))
    lock.lock()
    smoothed = level > smoothed ? level * 0.6 + smoothed * 0.4 : level * 0.2 + smoothed * 0.8
    let now = CFAbsoluteTimeGetCurrent()
    let due = now - lastWrite >= 0.05
    if due { lastWrite = now }
    let value = smoothed
    lock.unlock()
    if due { channel.writeLevel(value) }
  }

  func reset() {
    lock.lock()
    smoothed = 0
    lock.unlock()
    channel.writeLevel(0)
  }
}

/// The voice session's audio: the microphone, running for the whole session
/// so a key press starts transcription at once. Its buffers go only to the
/// open utterance (`AudioRouter`); everything else is dropped on arrival.
///
/// In DEBUG builds, `-MindloomVoiceFile <path>` replaces the microphone with
/// an audio file played into each utterance, so recognition can be exercised
/// in the simulator without a microphone and without real speech.
@MainActor
final class VoiceAudio {
  enum Source: Equatable {
    case microphone
    /// DEBUG only: feed this file into each utterance, in real time when
    /// `paced`, otherwise as fast as possible.
    case file(URL, paced: Bool)
  }

  enum AudioError: Error {
    case microphoneDenied
    case noInput
  }

  let router = AudioRouter()
  let meter: LevelMeter
  let source: Source
  private(set) var isRunning = false
  /// The microphone's format (or the file's), for choosing the recognizer's.
  private(set) var inputFormat: AVAudioFormat?
  var onInterruption: ((_ began: Bool) -> Void)?

  private let engine = AVAudioEngine()
  private var fileFeeder: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []
  private let log = Logger(subsystem: "com.bestasr.phone", category: "voice-audio")

  init(channel: VoiceChannel, source: Source) {
    self.meter = LevelMeter(channel: channel)
    self.source = source
  }

  static func requestMicrophone() async -> Bool {
    switch AVAudioApplication.shared.recordPermission {
    case .granted: return true
    case .denied: return false
    default: return await AVAudioApplication.requestRecordPermission()
    }
  }

  func start() throws {
    guard !isRunning else { return }
    let session = AVAudioSession.sharedInstance()
    switch source {
    case .microphone:
      // Mixes with whatever is playing, so music keeps going while the
      // session waits for the key.
      try session.setCategory(
        .playAndRecord, mode: .default,
        options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
      try session.setActive(true)
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError.noInput }
      inputFormat = format
      input.installTap(
        onBus: 0, bufferSize: 1024, format: format,
        block: Self.makeTap(router: router, meter: meter))
    case .file(let url, _):
      // No microphone at all: a silent output keeps the app running in the
      // background exactly like the microphone session does.
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)
      inputFormat = try AVAudioFile(forReading: url).processingFormat
      let silence = AVAudioSourceNode(renderBlock: Self.makeSilence())
      engine.attach(silence)
      engine.connect(silence, to: engine.mainMixerNode, format: nil)
    }
    engine.prepare()
    try engine.start()
    isRunning = true
    observe()
    log.info("voice audio started")
  }

  func stop() {
    guard isRunning else { return }
    fileFeeder?.cancel()
    fileFeeder = nil
    router.detachAll()
    if source == .microphone { engine.inputNode.removeTap(onBus: 0) }
    engine.stop()
    engine.reset()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    isRunning = false
    meter.reset()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    log.info("voice audio stopped")
  }

  /// An utterance opened: in file mode, start playing the file into it.
  func utteranceDidBegin(_ sink: any AudioSink) {
    router.attach(sink)
    guard case .file(let url, let paced) = source else { return }
    fileFeeder?.cancel()
    let router = router
    let meter = meter
    fileFeeder = Task.detached(priority: .userInitiated) {
      await Self.feed(file: url, paced: paced, to: sink, router: router, meter: meter)
    }
  }

  /// Waits until the DEBUG file has been fed into the open utterance.
  func waitForFileFeed() async {
    await fileFeeder?.value
  }

  func utteranceDidEnd(_ sink: any AudioSink) {
    router.detach(sink)
    meter.reset()
  }

  // MARK: - Audio-thread blocks (built outside the main actor)

  private nonisolated static func makeTap(router: AudioRouter, meter: LevelMeter)
    -> AVAudioNodeTapBlock
  {
    { buffer, _ in
      // Between utterances the buffer is dropped right here.
      guard router.hasSink else { return }
      meter.feed(buffer)
      router.route(buffer)
    }
  }

  private nonisolated static func makeSilence() -> AVAudioSourceNodeRenderBlock {
    { _, _, _, audioBufferList in
      for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
      }
      return noErr
    }
  }

  /// DEBUG file feed: 100 ms chunks, as long as `sink` is the open utterance.
  private nonisolated static func feed(
    file url: URL, paced: Bool, to sink: any AudioSink, router: AudioRouter, meter: LevelMeter
  ) async {
    guard let file = try? AVAudioFile(forReading: url) else { return }
    let format = file.processingFormat
    let chunk = AVAudioFrameCount(format.sampleRate / 10)
    while !Task.isCancelled {
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
      do {
        try file.read(into: buffer, frameCount: chunk)
      } catch {
        return
      }
      if buffer.frameLength == 0 { return }
      guard router.hasSink else { return }
      meter.feed(buffer)
      sink.append(buffer)
      if paced { try? await Task.sleep(for: .milliseconds(100)) }
    }
  }

  // MARK: - Interruptions and route changes

  private func observe() {
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
      ) { [weak self] note in
        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let began = raw == AVAudioSession.InterruptionType.began.rawValue
        MainActor.assumeIsolated { self?.handleInterruption(began: began) }
      })
    observers.append(
      center.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.restartAfterConfigurationChange() }
      })
  }

  private func handleInterruption(began: Bool) {
    onInterruption?(began)
    if !began, isRunning, !engine.isRunning {
      try? AVAudioSession.sharedInstance().setActive(true)
      try? engine.start()
    }
  }

  /// A new route (headphones in or out) resets the input format.
  private func restartAfterConfigurationChange() {
    guard isRunning, source == .microphone else { return }
    let input = engine.inputNode
    input.removeTap(onBus: 0)
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0 else { return }
    inputFormat = format
    input.installTap(
      onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap(router: router, meter: meter))
    try? engine.start()
  }
}
