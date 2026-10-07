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
///
/// While a press is waiting for its recognizer (`arm()`), up to two seconds of
/// buffers are kept in memory only, so the first words are not lost; they go to
/// the utterance when it attaches and are dropped on `disarm()`.
final class AudioRouter: @unchecked Sendable {
  /// At most this much audio is held while armed (a press waiting for its recognizer, or for the
  /// next analyzer to be prepared after a quick second press).
  static let preRollSeconds: Double = 4
  private let lock = NSLock()
  private var sink: (any AudioSink)?
  private var armed = false
  private var preRoll: [AVAudioPCMBuffer] = []
  private var preRollFrames: AVAudioFrameCount = 0

  /// True while buffers are wanted (an utterance is open or a press is armed).
  var isListening: Bool {
    lock.lock()
    defer { lock.unlock() }
    return sink != nil || armed
  }

  var hasSink: Bool {
    lock.lock()
    defer { lock.unlock() }
    return sink != nil
  }

  /// A press started: keep what is said until the utterance attaches.
  func arm() {
    lock.lock()
    armed = true
    preRoll = []
    preRollFrames = 0
    lock.unlock()
  }

  /// Arms unless already armed: keeps what an earlier `arm()` is holding (a speak-bar press that
  /// is still waiting for the recognizer).
  func armKeepingHeld() {
    lock.lock()
    armed = true
    lock.unlock()
  }

  /// The press ended without an utterance: drop the held audio.
  func disarm() {
    lock.lock()
    armed = false
    preRoll = []
    preRollFrames = 0
    lock.unlock()
  }

  func attach(_ sink: any AudioSink) {
    lock.lock()
    self.sink = sink
    let held = preRoll
    armed = false
    preRoll = []
    preRollFrames = 0
    lock.unlock()
    for buffer in held { sink.append(buffer) }
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
    armed = false
    preRoll = []
    preRollFrames = 0
    lock.unlock()
  }

  @discardableResult
  func route(_ buffer: AVAudioPCMBuffer) -> Bool {
    lock.lock()
    let current = sink
    if current == nil, armed, let copy = Self.copy(buffer) {
      preRoll.append(copy)
      preRollFrames += copy.frameLength
      let limit = AVAudioFrameCount(buffer.format.sampleRate * Self.preRollSeconds)
      while preRollFrames > limit, let first = preRoll.first {
        preRollFrames -= first.frameLength
        preRoll.removeFirst()
      }
      lock.unlock()
      return true
    }
    lock.unlock()
    guard let current else { return false }
    current.append(buffer)
    return true
  }

  private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
    else { return nil }
    copy.frameLength = buffer.frameLength
    let source = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: buffer.audioBufferList))
    let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for (from, to) in zip(source, target) {
      if let src = from.mData, let dst = to.mData {
        memcpy(dst, src, Int(min(from.mDataByteSize, to.mDataByteSize)))
      }
    }
    return copy
  }
}

/// The microphone level while listening (PHONE-SPEC §7.9): RMS → dBFS per
/// buffer (≈ 21 ms), handed to the in-app listening animation as dBFS and
/// written to the App Group as raw ℓ = clamp((dBFS + 50) / 34) at ≥ 30 Hz for
/// the keyboard, which runs the envelope and spring itself. Only while an
/// utterance is open or a press is armed; no audio is kept.
final class LevelMeter: @unchecked Sendable {
  private let channel: VoiceChannel
  private let lock = NSLock()
  private var lastWrite: CFAbsoluteTime = 0
  private var handler: (@Sendable (Double) -> Void)?

  init(channel: VoiceChannel) {
    self.channel = channel
  }

  /// Receives dBFS for every buffer, on the audio thread.
  func setHandler(_ handler: (@Sendable (Double) -> Void)?) {
    lock.lock()
    self.handler = handler
    lock.unlock()
  }

  static func decibels(_ buffer: AVAudioPCMBuffer) -> Double? {
    guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
    let frames = Int(buffer.frameLength)
    var sum: Float = 0
    let samples = data[0]
    for index in 0..<frames { sum += samples[index] * samples[index] }
    let rms = sqrt(sum / Float(frames))
    return Double(20 * log10(max(rms, 1e-7)))
  }

  /// ℓ = clamp((dBFS + 50) / 34): gate −50 dBFS, span 34 dB.
  static func level(fromDecibels db: Double) -> Float {
    Float(max(0, min(1, (db + 50) / 34)))
  }

  func feed(_ buffer: AVAudioPCMBuffer) {
    guard let db = Self.decibels(buffer) else { return }
    lock.lock()
    let now = CFAbsoluteTimeGetCurrent()
    let due = now - lastWrite >= 1.0 / 40
    if due { lastWrite = now }
    let handler = handler
    lock.unlock()
    handler?(db)
    if due { channel.writeLevel(Self.level(fromDecibels: db)) }
  }

  func reset() {
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
  /// An interruption began, or ended; `recovered` says whether the engine runs again.
  var onInterruption: ((_ began: Bool, _ recovered: Bool) -> Void)?
  #if DEBUG
    /// DEBUG bench only: the file the next utterance plays instead of the
    /// launch file. Must have the launch file's format.
    var debugNextFile: URL?
  #endif

  private var engine = AVAudioEngine()
  private var fileFeeder: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []
  private let log = Logger(subsystem: PhoneNames.appLog, category: "voice-audio")

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
    guard case .file(let launchFile, let paced) = source else { return }
    var url = launchFile
    #if DEBUG
      if let next = debugNextFile { url = next }
    #endif
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
      guard router.isListening else { return }
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

  /// DEBUG file feed: microphone-sized chunks (1024 frames, ≈ 21 ms at 48 kHz) in
  /// real time when paced, as long as `sink` is the open utterance.
  private nonisolated static func feed(
    file url: URL, paced: Bool, to sink: any AudioSink, router: AudioRouter, meter: LevelMeter
  ) async {
    guard let file = try? AVAudioFile(forReading: url) else { return }
    let format = file.processingFormat
    let chunk: AVAudioFrameCount = 1024
    let pace = Double(chunk) / format.sampleRate
    let started = CFAbsoluteTimeGetCurrent()
    var fed = 0.0
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
      fed += pace
      if paced {
        let ahead = fed - (CFAbsoluteTimeGetCurrent() - started)
        if ahead > 0 { try? await Task.sleep(for: .seconds(ahead)) }
      }
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
        forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.rebuildAfterMediaReset() }
      })
    observers.append(
      center.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.restartAfterConfigurationChange() }
      })
  }

  private func handleInterruption(began: Bool) {
    if began {
      onInterruption?(true, false)
      return
    }
    // Restart first, then report what really happened: restarting input from the background
    // after a call often fails (cannotStartRecording), and a dead engine must not look ready.
    if isRunning, !engine.isRunning {
      do {
        try AVAudioSession.sharedInstance().setActive(true)
        try engine.start()
      } catch {
        log.error("restart after interruption failed: \(String(describing: error), privacy: .public)")
      }
    }
    onInterruption?(false, !isRunning || engine.isRunning)
  }

  /// Media services were reset: every audio object is dead (while `isRunning` would still say
  /// true). Tear down, build a new engine and start again if anything was listening; the router
  /// keeps the open utterance's sink.
  private func rebuildAfterMediaReset() {
    let wasRunning = isRunning
    log.notice("media services reset")
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    fileFeeder?.cancel()
    fileFeeder = nil
    if source == .microphone { engine.inputNode.removeTap(onBus: 0) }
    engine.stop()
    isRunning = false
    engine = AVAudioEngine()
    guard wasRunning else { return }
    do {
      try start()
      onInterruption?(false, true)
    } catch {
      log.error("restart after media reset failed: \(String(describing: error), privacy: .public)")
      onInterruption?(false, false)
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
