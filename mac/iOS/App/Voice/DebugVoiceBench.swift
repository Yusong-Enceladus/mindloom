#if DEBUG
  @preconcurrency import AVFoundation
  import Foundation
  import MindloomPhoneKit
  import Speech
  import UIKit

  /// DEBUG builds only. `-MindloomDebugVoiceBench <dir>` measures on-device
  /// recognition on a real iPhone without a microphone and without the
  /// keyboard, together with the DEBUG audio-file hook
  /// (`-MindloomVoiceFile <dir>/clips/<first>.wav`):
  ///
  /// 1. It records what Speech offers for zh-CN, starts the voice session
  ///    exactly as 开始语音 does (including the AssetInventory download) and
  ///    notes which recognizer won.
  /// 2. For every `<dir>/clips/*.wav` it plays the keyboard's part over the
  ///    real Darwin notify center (`voice.start`, then `voice.stop` 300 ms
  ///    after the file has been fed in real time) and times the first
  ///    partial and the final as the keyboard would see them.
  /// 3. If `<dir>/background/*.wav` exist, it waits for the app to go to the
  ///    background, samples the session every 5 s for 60 s, then runs those
  ///    clips from the background.
  ///
  /// Everything goes to `<dir>/results.json`, rewritten after every step.
  /// The clips are synthetic text-to-speech; nothing leaves the phone.
  @MainActor
  final class DebugVoiceBench {
    static let argument = "-MindloomDebugVoiceBench"
    static let backgroundSeconds: TimeInterval = 60
    /// Keeps the running bench alive.
    static var running: DebugVoiceBench?

    struct Clip: Codable {
      var file: String
      var phase: String
      var durationMs: Int?
      /// From posting `voice.start` until the app reported listening.
      var listeningAfterMs: Int?
      /// From posting `voice.start` until the file was fed (paced).
      var fedAfterMs: Int?
      var firstPartialMs: Int?
      var lastPartialMs: Int?
      var partialUpdates = 0
      var partialCharsAtRelease = 0
      /// From posting `voice.stop` until the final arrived.
      var finalAfterReleaseMs: Int?
      var outcome: String?
      var text: String?
      var error: String?
    }

    struct Sample: Codable {
      var seconds: Double
      var appState: String
      var sessionLive: Bool
      var protectedData: Bool
    }

    struct Background: Codable {
      var status = "waiting for the app to go to the background"
      var enteredAt: String?
      var samples: [Sample] = []
      var clips: [Clip] = []
    }

    struct Report: Codable {
      var device = ""
      var system = ""
      var startedAt = ""
      var diagnosticsBefore: [String: String] = [:]
      var assetsBefore: [String: String] = [:]
      var sessionStatus = "starting"
      var recognizer: String?
      var sessionLiveAfterMs: Int?
      var sawPreparingModel = false
      var preparingModelMs: Int?
      var lastModelProgress: Double?
      var assetsAfter: [String: String] = [:]
      var installedLocalesAfter: String?
      var clips: [Clip] = []
      var background: Background?
      var events: [String] = []
      var done = false
    }

    /// The bench directory from the launch arguments, relative to the app's
    /// home directory unless absolute.
    static func directory(arguments: [String] = ProcessInfo.processInfo.arguments) -> URL? {
      guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count else {
        return nil
      }
      let path = arguments[index + 1]
      return path.hasPrefix("/")
        ? URL(fileURLWithPath: path, isDirectory: true)
        : URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
          .appendingPathComponent(path, isDirectory: true)
    }

    /// Starts the bench if the launch arguments ask for it.
    static func startIfRequested(voice: VoiceSessionModel) {
      guard running == nil, let directory = directory() else { return }
      let bench = DebugVoiceBench(voice: voice, directory: directory)
      running = bench
      Task { await bench.run() }
    }

    private let voice: VoiceSessionModel
    private let directory: URL
    private var report = Report()
    private let clock = ContinuousClock()
    private let began = ContinuousClock.now
    private var observers: [NSObjectProtocol] = []
    private var preparingSince: ContinuousClock.Instant?

    init(voice: VoiceSessionModel, directory: URL) {
      self.voice = voice
      self.directory = directory
    }

    // MARK: - Run

    func run() async {
      report.device = Self.modelIdentifier()
      report.system = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
      report.startedAt = Date().formatted(.iso8601)
      observeLifecycle()
      guard VoiceSessionModel.launchSource() != .microphone else {
        // Never fall back to the microphone: that would ask for permission.
        report.sessionStatus = "no audio file: pass -MindloomVoiceFile <dir>/clips/<clip>.wav"
        report.done = true
        return save()
      }
      let diagnostics = await RecognizerChoice.diagnostics()
      report.diagnosticsBefore = diagnostics
      let assetsBefore = await Self.assetStatuses()
      report.assetsBefore = assetsBefore
      save()

      await startSession()
      let assetsAfter = await Self.assetStatuses()
      report.assetsAfter = assetsAfter
      let installed = await SpeechTranscriber.installedLocales.map(\.identifier)
      report.installedLocalesAfter = installed.sorted().joined(separator: ",")
      save()
      guard voice.isAlive else {
        report.done = true
        return save()
      }

      for url in clips(in: "clips") {
        // Measure first: an access to `report` must not span the await.
        let clip = await measure(url, phase: "foreground")
        report.clips.append(clip)
        save()
        try? await Task.sleep(for: .seconds(1))
      }

      let background = clips(in: "background")
      if !background.isEmpty {
        await runInBackground(background)
      }
      report.done = true
      save()
    }

    private func startSession() async {
      let started = clock.now
      let watcher = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          guard let self else { return }
          if case .preparingModel(let progress) = self.voice.status {
            if self.preparingSince == nil {
              self.preparingSince = self.clock.now
              self.report.sawPreparingModel = true
              self.note("preparing model")
            }
            if let progress { self.report.lastModelProgress = progress }
          }
          try? await Task.sleep(for: .milliseconds(100))
        }
      }
      await voice.start()
      watcher.cancel()
      let liveAt = clock.now
      if let preparingSince { report.preparingModelMs = Self.ms(liveAt - preparingSince) }
      report.sessionLiveAfterMs = Self.ms(liveAt - started)
      report.recognizer = voice.recognizerName
      report.sessionStatus = String(describing: voice.status)
      note("session \(report.sessionStatus) recognizer=\(voice.recognizerName ?? "none")")
    }

    // MARK: - One utterance, as the keyboard does it

    /// Collects what the keyboard would see of one utterance.
    @MainActor
    private final class Watch {
      let after: Int
      let start: ContinuousClock.Instant
      var firstPartial: Duration?
      var lastPartial: Duration?
      var updates = 0
      var latestChars = 0
      var final: VoiceText?
      var finalAt: ContinuousClock.Instant?

      init(after: Int, start: ContinuousClock.Instant) {
        self.after = after
        self.start = start
      }
    }

    private func measure(_ url: URL, phase: String) async -> Clip {
      var clip = Clip(file: url.lastPathComponent, phase: phase)
      clip.durationMs = Self.durationMs(url)
      let channel = voice.channel
      let signaling = DarwinSignaling.shared
      voice.debugPlayNext(url)
      let watch = Watch(after: channel.highestSeq(), start: clock.now)
      let clock = clock
      let partials = signaling.observe(PhoneSignal.voicePartial) {
        guard let partial = channel.readPartial(), partial.seq > watch.after,
          !partial.text.isEmpty
        else { return }
        let now = clock.now - watch.start
        if watch.firstPartial == nil { watch.firstPartial = now }
        watch.lastPartial = now
        watch.updates += 1
        watch.latestChars = partial.text.count
      }
      let finals = signaling.observe(PhoneSignal.voiceFinal) {
        guard watch.final == nil,
          let final = channel.readFinals()?.entries.first(where: { $0.seq > watch.after })
        else { return }
        watch.final = final
        watch.finalAt = clock.now
      }
      defer {
        partials.cancel()
        finals.cancel()
      }

      signaling.post(PhoneSignal.voiceStart)
      guard await waitUntil(seconds: 5, { self.voice.isListening }) else {
        clip.error = "the session did not start listening within 5 s"
        return clip
      }
      clip.listeningAfterMs = Self.ms(clock.now - watch.start)
      await voice.debugWaitForFileFeed()
      clip.fedAfterMs = Self.ms(clock.now - watch.start)
      try? await Task.sleep(for: .milliseconds(300))
      clip.partialCharsAtRelease = watch.latestChars
      let released = clock.now
      signaling.post(PhoneSignal.voiceStop)
      guard await waitUntil(seconds: 30, { watch.final != nil }), let final = watch.final,
        let finalAt = watch.finalAt
      else {
        clip.error = "no final within 30 s of release"
        return clip
      }
      clip.firstPartialMs = watch.firstPartial.map(Self.ms)
      clip.lastPartialMs = watch.lastPartial.map(Self.ms)
      clip.partialUpdates = watch.updates
      clip.finalAfterReleaseMs = Self.ms(finalAt - released)
      clip.outcome = final.outcome?.rawValue
      clip.text = final.text
      note(
        "\(phase) \(clip.file): first partial \(clip.firstPartialMs ?? -1) ms, final \(clip.finalAfterReleaseMs ?? -1) ms after release"
      )
      return clip
    }

    // MARK: - Background

    private func runInBackground(_ files: [URL]) async {
      report.background = Background()
      save()
      note("waiting for background")
      guard
        await waitUntil(seconds: 900, { UIApplication.shared.applicationState == .background })
      else {
        report.background?.status = "the app was not sent to the background within 15 minutes"
        return
      }
      let entered = clock.now
      report.background?.enteredAt = Date().formatted(.iso8601)
      report.background?.status = "in background"
      note("entered background")
      while clock.now - entered < .seconds(Self.backgroundSeconds) {
        report.background?.samples.append(sample(since: entered))
        save()
        try? await Task.sleep(for: .seconds(5))
      }
      report.background?.samples.append(sample(since: entered))
      for url in files {
        let clip = await measure(url, phase: "background")
        report.background?.clips.append(clip)
        save()
        try? await Task.sleep(for: .seconds(1))
      }
      report.background?.samples.append(sample(since: entered))
      report.background?.status = "finished"
    }

    private func sample(since entered: ContinuousClock.Instant) -> Sample {
      Sample(
        seconds: Double(Self.ms(clock.now - entered)) / 1000,
        appState: Self.name(UIApplication.shared.applicationState),
        sessionLive: voice.isAlive,
        protectedData: UIApplication.shared.isProtectedDataAvailable)
    }

    private func observeLifecycle() {
      let center = NotificationCenter.default
      let events: [(Notification.Name, String)] = [
        (UIApplication.didEnterBackgroundNotification, "did enter background"),
        (UIApplication.willEnterForegroundNotification, "will enter foreground"),
        (UIApplication.protectedDataWillBecomeUnavailableNotification, "device locking"),
        (UIApplication.protectedDataDidBecomeAvailableNotification, "device unlocked"),
        (AVAudioSession.interruptionNotification, "audio interruption"),
      ]
      for (name, label) in events {
        observers.append(
          center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
              self?.note(label)
              self?.save()
            }
          })
      }
    }

    // MARK: - Helpers

    private func clips(in folder: String) -> [URL] {
      let folder = directory.appendingPathComponent(folder, isDirectory: true)
      let files =
        (try? FileManager.default.contentsOfDirectory(
          at: folder, includingPropertiesForKeys: nil)) ?? []
      return files.filter { $0.pathExtension.lowercased() == "wav" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func waitUntil(seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
      let deadline = clock.now + .milliseconds(Int(seconds * 1000))
      while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
      }
      return condition()
    }

    private func note(_ event: String) {
      let seconds = Double(Self.ms(clock.now - began)) / 1000
      report.events.append(String(format: "%.1fs %@", seconds, event))
      print("MINDLOOM-BENCH \(String(format: "%.1f", seconds))s \(event)")
    }

    private func save() {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      encoder.keyEncodingStrategy = .convertToSnakeCase
      guard let data = try? encoder.encode(report) else { return }
      try? data.write(to: directory.appendingPathComponent("results.json"), options: .atomic)
    }

    private static func assetStatuses() async -> [String: String] {
      var statuses: [String: String] = [:]
      for choice in [
        RecognizerChoice.speechTranscriber(RecognizerChoice.chinese),
        RecognizerChoice.dictationTranscriber(RecognizerChoice.chinese),
      ] {
        guard let module = TranscriberModule.make(choice)?.module else { continue }
        statuses[choice.kindName] = String(
          describing: await AssetInventory.status(forModules: [module]))
      }
      return statuses
    }

    private static func durationMs(_ url: URL) -> Int? {
      guard let file = try? AVAudioFile(forReading: url) else { return nil }
      return Int((Double(file.length) / file.processingFormat.sampleRate * 1000).rounded())
    }

    private static func ms(_ duration: Duration) -> Int {
      let parts = duration.components
      return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }

    private static func name(_ state: UIApplication.State) -> String {
      switch state {
      case .active: "active"
      case .inactive: "inactive"
      case .background: "background"
      @unknown default: "unknown"
      }
    }

    private static func modelIdentifier() -> String {
      var info = utsname()
      uname(&info)
      return withUnsafeBytes(of: &info.machine) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
      }
    }
  }
#endif
