import AVFoundation
import AppKit
import BestASRAudioJournal
import BestASRDictation
import BestASRDomain
import BestASRInference
import BestASRPersistence
import BestASRProcessing
import BestASRQwenRuntime
import Darwin
import Foundation
import MindloomIdentity
import OSLog

#if DEBUG
  /// The dictation metrics probe (DICTATION_ARCHITECTURE §15): the four
  /// dictation numbers measured inside the App, on its own runtime, without a
  /// microphone and without writing into any other application.
  ///
  /// Only in a Debug check build (a check identity, `MindloomIdentity.isCheckIdentity`),
  /// only on a data root that `script/make_synthetic_data_root.sh` marked as
  /// synthetic, and only with `-MindloomDictationProbe <folder>`. The folder
  /// holds `audio/*.wav` (16 kHz mono speech made with the system's text to
  /// speech) and receives `probe-summary.json`, numbers only. Each file is
  /// played into a dictation in real time through the same capture
  /// coordinator, journal, live captions, pause decode, final recognizer,
  /// cleanup and timing table the App uses; the words go to a port that
  /// writes nowhere instead of pasting. Afterwards the probe releases the
  /// models the way the residency timers and memory pressure do and reads
  /// the footprint after each step, then quits the App.
  ///
  /// What its speed numbers are not (review 2026-10-06): the user's release
  /// to text. Nothing is pasted (no paste and no landing check), the App's
  /// `end()` is not on the path, the key-up is taken after all audio
  /// including the trailing silence has been played, and a pause decode is
  /// forced 150 ms into that silence. They are recognizer-side numbers:
  /// sealing, recognition, cleanup and hand-offs. The user's numbers come
  /// from the timing table of the installed App.
  enum DictationMetricsProbe {
    static let argument = "-MindloomDictationProbe"

    static func folder(arguments: [String], bundleIdentifier: String?, dataRoot: URL?) -> URL? {
      guard let bundleIdentifier, MindloomIdentity.isCheckIdentity(bundleIdentifier),
        let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1),
        let dataRoot,
        FileManager.default.fileExists(
          atPath: dataRoot.appendingPathComponent("SYNTHETIC_DATA_ROOT").path)
      else { return nil }
      let path = arguments[index + 1]
      guard path.hasPrefix("/") else { return nil }
      return URL(fileURLWithPath: path, isDirectory: true)
    }
  }

  /// Writes nowhere: the probe's words are counted, never pasted.
  actor ProbeInsertionPort: DictationInsertionPort {
    func captureTarget() async throws -> DictationTargetSnapshot {
      DictationTargetSnapshot(
        processIdentifier: 0, bundleIdentifier: "com.bestasr.probe", isSecure: false)
    }

    func insert(_ request: DictationInsertionRequest) async throws -> DictationInsertionResult {
      DictationInsertionResult(
        idempotencyKey: request.idempotencyKey, method: .directWrite, inserted: true,
        evidence: "probe")
    }
  }

  /// Plays 16 kHz mono samples into a dictation in real time, in 100 ms
  /// chunks, like the microphone does.
  actor ProbeFileCapture: MicrophoneCapturePort {
    private let samples: [Float]
    private var continuation: AsyncStream<CapturedPCMChunk>.Continuation?
    private var stream: AsyncStream<CapturedPCMChunk>?
    private var feeding: Task<Void, Never>?
    private var sequence: UInt64 = 0
    private(set) var deliveredSamples = 0
    /// The capture clock at the end of the last chunk played.
    private(set) var playedThroughNanoseconds: UInt64 = 0

    init(samples: [Float]) { self.samples = samples }

    func prepare(sessionID: SessionID) async throws -> MicrophoneCaptureDescriptor {
      let pair = AsyncStream.makeStream(of: CapturedPCMChunk.self)
      stream = pair.stream
      continuation = pair.continuation
      return MicrophoneCaptureDescriptor(
        sessionID: sessionID, deviceUID: "probe-file", sampleRateHertz: 16_000,
        channelCount: 1, encoding: .float32LittleEndian, interleaved: true)
    }

    func start() async throws {
      feeding = Task { await self.feed() }
    }

    private func feed() async {
      let chunk = 1_600
      var offset = 0
      let started = DispatchTime.now().uptimeNanoseconds
      while offset < samples.count, !Task.isCancelled {
        let end = min(samples.count, offset + chunk)
        let slice = Array(samples[offset..<end])
        let bytes = slice.withUnsafeBufferPointer { Data(buffer: $0) }
        continuation?.yield(
          CapturedPCMChunk(
            sequence: sequence,
            monotonicStartNanoseconds: started + UInt64(offset) * 62_500,
            frameCount: UInt64(slice.count), sampleRateHertz: 16_000, channelCount: 1,
            encoding: .float32LittleEndian, interleaved: true, bytes: bytes))
        sequence += 1
        offset = end
        deliveredSamples = offset
        playedThroughNanoseconds = started + UInt64(offset) * 62_500
        try? await Task.sleep(for: .milliseconds(100))
      }
    }

    /// Everything played.
    func waitUntilPlayed() async {
      await feeding?.value
    }

    func chunks() async -> AsyncStream<CapturedPCMChunk> {
      stream ?? AsyncStream { $0.finish() }
    }

    func pause() async throws {}
    func resume() async throws {}
    func stop() async throws {
      feeding?.cancel()
      continuation?.finish()
    }
    func cancel() async {
      feeding?.cancel()
      continuation?.finish()
    }
    func terminalFailure() async -> DictationFailure? { nil }
  }

  /// The highest footprint seen while it runs (every 50 ms).
  actor FootprintSampler {
    private var highest: UInt64 = 0
    private var task: Task<Void, Never>?

    func start() {
      highest = ProcessFootprint.current()?.bytes ?? 0
      task = Task {
        while !Task.isCancelled {
          self.sample()
          try? await Task.sleep(for: .milliseconds(50))
        }
      }
    }

    private func sample() {
      highest = max(highest, ProcessFootprint.current()?.bytes ?? 0)
    }

    func stop() -> UInt64 {
      task?.cancel()
      sample()
      return highest
    }
  }

  struct DictationProbeSummary: Encodable {
    struct Take: Encodable {
      let file: String
      /// Which situation the take stands for.
      let state: String
      let audioMilliseconds: Int?
      let recognizerWasCold: Bool
      /// Probe key-up (all audio played) to text handed to a port that
      /// writes nowhere: seal, recognition, cleanup and hand-offs only.
      let recognizerSideMilliseconds: Int?
      let sealMilliseconds: Int?
      let recognitionMilliseconds: Int?
      let cleanupMilliseconds: Int?
      let deliveryMilliseconds: Int?
      let queueMilliseconds: Int?
      let footprintAtTextMB: Int?
      let highestFootprintDuringMB: Int
      let wordsWritten: Bool
      let characterCount: Int
    }
    struct Memory: Encodable {
      let state: String
      let footprintMB: Int
      let mlxActiveMB: Int
      /// The App's lifetime peak footprint at that moment: where it jumps
      /// tells which step made the peak.
      let lifetimePeakMB: Int
    }
    /// Dictation's sentences timed later (DICTATION_ARCHITECTURE §15.7).
    struct WordTiming: Encodable {
      /// Recognizer windows recorded as one segment, waiting for timings.
      let pendingWindowsAfterDictations: Int
      /// Left when the hour's pass starts (after the export and the press
      /// stages below).
      let pendingWindowsBeforePass: Int
      let pendingWindowsAfterPass: Int
      let windowsTimed: Int
      let sentencesAfterPass: Int
      let passMilliseconds: Int
      /// Footprint while the aligner, alone, timed them.
      let highestFootprintDuringPassMB: Int
    }
    /// A request for one dictation's sentences (review 2026-10-07).
    struct TimingRequest: Encodable {
      /// Which request, in which state.
      let state: String
      let windowsTimed: Int
      let milliseconds: Int
      let highestFootprintDuringMB: Int
      let recognizerResidentAfter: Bool
    }
    /// A press while a pass was loading the aligner (review 2026-10-07).
    struct PressDuringPass: Encodable {
      let pendingWindowsBefore: Int
      /// Windows the pass timed before the press stopped it.
      let windowsTimedBeforeStop: Int
      let pendingWindowsAfter: Int
      /// The take's own numbers are in `takes` (state
      /// "press-during-timing-pass").
      let passEndedBeforeTakeEnded: Bool
    }
    /// A warning that lasted past the recognizer's grace, then normal
    /// (review 2026-10-07).
    struct LastingWarning: Encodable {
      let graceSeconds: Int
      let footprintBeforeMB: Int
      let footprintAfterGraceMB: Int
      let recognizerResidentAfterGrace: Bool
      /// The pass that normal started, the aligner alone.
      let windowsTimedAfterNormal: Int
      let highestFootprintAfterNormalMB: Int
    }
    var schemaVersion = 4
    /// What the take numbers cover (see `DictationMetricsProbe`).
    var scope =
      "recognizer side only: no paste, not through DictationAppModel.end(), key-up after all "
      + "audio played, pause decode forced 150 ms into the trailing silence"
    /// The build's revision (`BestASRBuildRevision`; "+dirty" when built
    /// from a working tree that differed from it) and configuration.
    var build = ""
    var buildConfiguration = "debug"
    var takes: [Take] = []
    var memory: [Memory] = []
    var idleCPUPercent: Double?
    var idleCPUWindowSeconds: Int?
    /// The same, later: windows closed and every model released.
    var idleCPUPercentReleased: Double?
    var highestFootprintMB: Int = 0
    /// The launch installed the memory-pressure watch.
    var watchesMemoryPressure = false
    /// Interrupted installs and quarantined copies left in the model store
    /// after launch housekeeping.
    var modelStoreLeftovers: Int?
    /// The kernel's lifetime peak footprint of the App, launch included.
    var lifetimePeakFootprintMB: Int?
    var wordTiming: WordTiming?
    var timingRequests: [TimingRequest] = []
    var pressDuringPass: PressDuringPass?
    var lastingWarning: LastingWarning?
    /// Retired models (`retiredModelArtifactIDs`) still in the store after
    /// launch housekeeping.
    var retiredModelsLeft: [String] = []
    var weekSummary: [String: Int?] = [:]
    var error: String?
  }

  extension DictationAppModel {
    /// Starts the probe when this launch asked for it (see
    /// `DictationMetricsProbe`); otherwise does nothing.
    func runDictationMetricsProbeIfRequested() {
      guard
        let folder = DictationMetricsProbe.folder(
          arguments: ProcessInfo.processInfo.arguments,
          bundleIdentifier: Bundle.main.bundleIdentifier,
          dataRoot: try? Self.applicationDataRoot())
      else { return }
      Task { [weak self] in
        guard let self else { return }
        var summary = DictationProbeSummary()
        summary.build =
          Bundle.main.object(forInfoDictionaryKey: "BestASRBuildRevision") as? String
          ?? ""
        do {
          try await self.runDictationMetricsProbe(folder: folder, summary: &summary)
        } catch {
          summary.error = String(describing: type(of: error))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(summary).write(
          to: folder.appendingPathComponent("probe-summary.json"), options: .atomic)
        // Not `NSApp.terminate`: called from this main-actor task it spins
        // AppKit's quit loop inside the task, and the App's own quit work,
        // also main-actor, never runs (the first probe run waited ten
        // minutes). The library closes the way quitting closes it.
        await LibraryQuit.close(within: LibraryQuit.quitWaitSeconds)
        exit(0)
      }
    }

    private func probeMemory(_ state: String) -> DictationProbeSummary.Memory {
      let footprint = ProcessFootprint.current()
      return DictationProbeSummary.Memory(
        state: state,
        footprintMB: footprint.map { ProcessFootprint.megabytes($0.bytes) } ?? -1,
        mlxActiveMB: QwenRuntimeMemory.usage().active / 1_048_576,
        lifetimePeakMB: footprint.map { ProcessFootprint.megabytes($0.peakBytes) } ?? -1)
    }

    private func runDictationMetricsProbe(
      folder: URL, summary: inout DictationProbeSummary
    ) async throws {
      // Models first: the probe measures a ready App.
      let deadline = ContinuousClock.now + .seconds(240)
      while !models.modelRuntimeReady, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(500))
      }
      guard models.modelRuntimeReady, let runtime = localRuntime, let journal, let repository
      else { throw CocoaError(.featureUnsupported) }
      await runtime.replaceInsertionForProbe(ProbeInsertionPort())
      summary.watchesMemoryPressure = await runtime.watchesMemoryPressure
      summary.memory.append(probeMemory("launched"))

      // Idle with every window closed: the launch prewarm has run.
      for window in NSApp.windows where window.isVisible { window.close() }
      try await Task.sleep(for: .seconds(20))
      summary.memory.append(probeMemory("idle-window-closed-after-launch"))
      let cpu = Self.processCPUSeconds()
      let cpuStarted = ContinuousClock.now
      try await Task.sleep(for: .seconds(60))
      let cpuElapsed = ContinuousClock.now - cpuStarted
      let wall = Double(cpuElapsed.components.seconds)
      summary.idleCPUPercent =
        ((Self.processCPUSeconds() - cpu) / max(1, wall) * 1_000)
        .rounded() / 10
      summary.idleCPUWindowSeconds = Int(wall)
      summary.memory.append(probeMemory("idle-window-closed-60s-later"))

      let files = try FileManager.default.contentsOfDirectory(
        at: folder.appendingPathComponent("audio"), includingPropertiesForKeys: nil
      ).filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
      let overall = FootprintSampler()
      await overall.start()
      var sessions: [SessionID] = []
      for file in files {
        let (take, sessionID) = try await probeDictation(
          file, state: "warm", runtime: runtime, journal: journal, repository: repository)
        summary.takes.append(take)
        sessions.append(sessionID)
        try await Task.sleep(for: .milliseconds(1_500))
      }
      summary.memory.append(probeMemory("after-dictations-recognizer-resident"))
      let pendingBefore = await Self.pendingWindows(repository)

      // The last dictation opened in History at once (clicking its
      // capsule), the recognizer resident: nothing is timed until it
      // leaves, so the aligner never joins it (review 2026-10-07).
      if let last = sessions.last {
        summary.timingRequests.append(
          await probeTimingRequest(
            "history-open-recognizer-resident", runtime: runtime,
            request: { await runtime.alignDeferredWords(sessionID: last) }))
      }

      // A memory-pressure warning: the others go, the recognizer stays
      // unless the warning lasts a minute.
      await runtime.handleMemoryPressure(.warning)
      try await Task.sleep(for: .seconds(3))
      summary.memory.append(probeMemory("after-pressure-warning-recognizer-kept"))
      await runtime.handleMemoryPressure(.normal)

      // What the residency timer does after ten minutes.
      await runtime.releaseIdleModels([.secondary])
      try await Task.sleep(for: .seconds(3))
      summary.memory.append(probeMemory("after-10-minutes-recognizer-resident"))

      // The first dictation exported, the recognizer resident: it is
      // released first, then the aligner times the sentences alone.
      if let first = sessions.first {
        summary.timingRequests.append(
          await probeTimingRequest(
            "export-recognizer-resident", runtime: runtime,
            request: {
              await runtime.alignDeferredWords(sessionID: first, releasingRecognizer: true)
            }))
      }
      try await Task.sleep(for: .seconds(3))
      summary.memory.append(probeMemory("after-export-timing-aligner-released"))

      // What the residency timer does after an hour.
      await runtime.releaseIdleModels([.recognizer])
      try await Task.sleep(for: .seconds(3))
      summary.memory.append(probeMemory("after-60-minutes-nothing-resident"))

      // A press while the hour's pass loads the aligner: the pass stops,
      // the aligner leaves after its load, then the recognizer loads.
      if files.count > 1 {
        let pendingAtPass = await Self.pendingWindows(repository)
        let pass = await runtime.startDeferredWordAlignment()
        try await Task.sleep(for: .milliseconds(500))
        let (take, sessionID) = try await probeDictation(
          files[1], state: "press-during-timing-pass", runtime: runtime, journal: journal,
          repository: repository)
        summary.takes.append(take)
        sessions.append(sessionID)
        let passRunning = await runtime.wordAlignmentTask != nil
        let timedBeforeStop = await pass?.value ?? -1
        summary.pressDuringPass = DictationProbeSummary.PressDuringPass(
          pendingWindowsBefore: pendingAtPass, windowsTimedBeforeStop: timedBeforeStop,
          pendingWindowsAfter: await Self.pendingWindows(repository),
          passEndedBeforeTakeEnded: !passRunning)
        summary.memory.append(probeMemory("after-press-during-timing-pass"))
      }

      // The hour again, after that take: the sentences are timed with the
      // aligner alone in memory.
      await runtime.releaseIdleModels([.recognizer])
      try await Task.sleep(for: .seconds(3))
      let pendingAtHour = await Self.pendingWindows(repository)
      let passSampler = FootprintSampler()
      await passSampler.start()
      let passStarted = ContinuousClock.now
      let timed = await runtime.startDeferredWordAlignment()?.value ?? -1
      let passTime = ContinuousClock.now - passStarted
      let passHighest = await passSampler.stop()
      try await Task.sleep(for: .seconds(3))
      summary.memory.append(probeMemory("after-sentences-timed-aligner-released"))
      let (pendingAfter, sentences) = await Self.pendingWindowsAndSentences(repository)
      summary.wordTiming = DictationProbeSummary.WordTiming(
        pendingWindowsAfterDictations: pendingBefore, pendingWindowsBeforePass: pendingAtHour,
        pendingWindowsAfterPass: pendingAfter, windowsTimed: timed,
        sentencesAfterPass: sentences, passMilliseconds: Self.milliseconds(passTime),
        highestFootprintDuringPassMB: ProcessFootprint.megabytes(passHighest))
      let releasedCPU = Self.processCPUSeconds()
      try await Task.sleep(for: .seconds(30))
      summary.idleCPUPercentReleased =
        ((Self.processCPUSeconds() - releasedCPU) / 30 * 1_000).rounded() / 10
      summary.memory.append(probeMemory("after-60-minutes-30s-later"))

      // The first dictation after the recognizer was released (the hour's
      // timer, or memory pressure moments after the last dictation): the
      // press warms it again, so the reload runs while the audio plays.
      if let first = files.dropFirst(3).first ?? files.first {
        let (take, sessionID) = try await probeDictation(
          first, state: "after-recognizer-released", runtime: runtime, journal: journal,
          repository: repository)
        summary.takes.append(take)
        sessions.append(sessionID)
      }
      summary.memory.append(probeMemory("after-cold-dictation"))

      // A warning that lasts past the grace: the recognizer goes after it.
      // Normal then times what that take left, the aligner alone.
      let grace = await runtime.residency.recognizerPressureGrace
      let beforeWarning = probeMemory("before-lasting-warning").footprintMB
      await runtime.handleMemoryPressure(.warning)
      try await Task.sleep(for: grace + .seconds(3))
      let afterGrace = probeMemory("after-pressure-warning-lasted")
      summary.memory.append(afterGrace)
      let residentAfterGrace = await runtime.recognizerResident
      let normalSampler = FootprintSampler()
      await normalSampler.start()
      await runtime.handleMemoryPressure(.normal)
      let normalPass = await runtime.wordAlignmentTask
      let timedAfterNormal = await normalPass?.value ?? 0
      let normalHighest = await normalSampler.stop()
      summary.lastingWarning = DictationProbeSummary.LastingWarning(
        graceSeconds: Int(grace.components.seconds), footprintBeforeMB: beforeWarning,
        footprintAfterGraceMB: afterGrace.footprintMB,
        recognizerResidentAfterGrace: residentAfterGrace,
        windowsTimedAfterNormal: timedAfterNormal,
        highestFootprintAfterNormalMB: ProcessFootprint.megabytes(normalHighest))
      try await Task.sleep(for: .seconds(3))
      summary.memory.append(probeMemory("after-normal-pass-aligner-released"))

      // A take cancelled with Esc, then memory pressure: the cancel must
      // give the runtime its dictation back, or the release waits forever
      // (review 2026-10-06).
      if let first = files.first {
        try await probeCancelledDictation(
          first, runtime: runtime, journal: journal, repository: repository)
        summary.memory.append(probeMemory("cancelled-take-models-resident"))
        await runtime.handleMemoryPressure(.critical)
        try await Task.sleep(for: .seconds(3))
        summary.memory.append(probeMemory("cancelled-take-after-memory-pressure-critical"))
        await runtime.handleMemoryPressure(.normal)
        _ = await runtime.wordAlignmentTask?.value
      }
      summary.highestFootprintMB = ProcessFootprint.megabytes(await overall.stop())
      summary.lifetimePeakFootprintMB = ProcessFootprint.current().map {
        ProcessFootprint.megabytes($0.peakBytes)
      }

      if let root = try? Self.applicationDataRoot() {
        let models = root.appendingPathComponent("models", isDirectory: true)
        summary.retiredModelsLeft =
          ((try? FileManager.default.contentsOfDirectory(
            atPath: models.appendingPathComponent("versions").path)) ?? [])
          .filter { LocalDictationRuntime.retiredModelArtifactIDs.contains($0) }.sorted()
        summary.modelStoreLeftovers = ["staging", "quarantine"].reduce(0) {
          $0
            + ((try? FileManager.default.contentsOfDirectory(
              atPath: models.appendingPathComponent($1).path))?.count ?? 0)
        }
      }
      if let store = dictationMetricsStore,
        let week = try? await store.releaseToTextSummary(lastDays: 7)
      {
        summary.weekSummary = [
          "count": week.count, "p50": week.p50Milliseconds, "p95": week.p95Milliseconds,
        ]
      }
    }

    /// One request for a dictation's sentences, with the footprint it made.
    private func probeTimingRequest(
      _ state: String, runtime: LocalDictationRuntime,
      request: @escaping @Sendable () async -> Int
    ) async -> DictationProbeSummary.TimingRequest {
      let sampler = FootprintSampler()
      await sampler.start()
      let started = ContinuousClock.now
      let timed = await request()
      let elapsed = ContinuousClock.now - started
      let highest = await sampler.stop()
      return DictationProbeSummary.TimingRequest(
        state: state, windowsTimed: timed, milliseconds: Self.milliseconds(elapsed),
        highestFootprintDuringMB: ProcessFootprint.megabytes(highest),
        recognizerResidentAfter: await runtime.recognizerResident)
    }

    nonisolated static func milliseconds(_ duration: Duration) -> Int {
      Int(duration.components.seconds * 1_000)
        + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Recognizer windows of the probe's dictations still waiting for their
    /// sentences' timings.
    private static func pendingWindows(_ repository: GRDBDictationStore) async -> Int {
      await pendingWindowsAndSentences(repository).0
    }

    private static func pendingWindowsAndSentences(_ repository: GRDBDictationStore) async
      -> (Int, Int)
    {
      let pending =
        (try? await repository.deferredWordAlignmentWork(
          modelArtifactID: QwenASRPinnedArtifact.artifactID, limit: 1_000))?
        .reduce(0) { $0 + $1.pendingSegments.count } ?? -1
      let history =
        (try? await repository.searchHistory(
          query: "", mode: .dictation, status: nil, limit: 1_000)) ?? []
      var sentences = 0
      for item in history {
        let transcripts = (try? await repository.loadTranscripts(sessionID: item.sessionID)) ?? []
        sentences += transcripts.filter { $0.kind == .final }.reduce(0) {
          $0 + $1.segments.filter { !DeferredWordAlignment.isPending($0.id) }.count
        }
      }
      return (pending, sentences)
    }

    /// Starts a take the way `start()` does, lets it run for three seconds
    /// (long enough for the press to have loaded the models again), and
    /// cancels it the way `cancel()` does.
    private func probeCancelledDictation(
      _ file: URL, runtime: LocalDictationRuntime, journal: ProductionAudioJournal,
      repository: GRDBDictationStore
    ) async throws {
      let capture = ProbeFileCapture(samples: try Self.probeSamples(file))
      let sessionID = SessionID()
      await runtime.warmFinalASRIfIdle()
      await runtime.beginFinalSpeculation(sessionID: sessionID)
      let coordinator = DictationCaptureCoordinator(
        sessionActor: DictationSessionActor(), capture: capture, journal: journal,
        repository: repository, committedChunkObserver: runtime, grantsRemoteEligibility: false)
      _ = try await coordinator.start(sessionID: sessionID, target: nil)
      await runtime.registerLiveSession(sessionID: sessionID, inputMode: .dictation)
      try await Task.sleep(for: .seconds(3))
      _ = try await coordinator.cancel()
      await runtime.clearLiveSession(sessionID: sessionID)
      await runtime.endUnprocessedDictation(sessionID: sessionID)
    }

    private func probeDictation(
      _ file: URL, state: String, runtime: LocalDictationRuntime,
      journal: ProductionAudioJournal, repository: GRDBDictationStore
    ) async throws -> (DictationProbeSummary.Take, SessionID) {
      let speech = try Self.probeSamples(file)
      // A pause is recognised 150 ms into silence; the key comes up about
      // 250 ms after that.
      let pauseAt = speech.count + 2_400
      let capture = ProbeFileCapture(samples: speech + Array(repeating: 0, count: 6_400))
      let sampler = FootprintSampler()
      await sampler.start()
      let sessionID = SessionID()
      await runtime.warmFinalASRIfIdle()
      await runtime.beginFinalSpeculation(sessionID: sessionID)
      let coordinator = DictationCaptureCoordinator(
        sessionActor: DictationSessionActor(), capture: capture, journal: journal,
        repository: repository, committedChunkObserver: runtime, grantsRemoteEligibility: false)
      _ = try await coordinator.start(sessionID: sessionID, target: nil)
      await runtime.registerLiveSession(sessionID: sessionID, inputMode: .dictation)
      while await capture.deliveredSamples < pauseAt {
        try await Task.sleep(for: .milliseconds(20))
      }
      await runtime.requestFinalSpeculation(
        sessionID: sessionID, committedThroughNanoseconds: await capture.playedThroughNanoseconds)
      await capture.waitUntilPlayed()
      let releasedAt = ContinuousClock.now
      let finalization = try await coordinator.end()
      let seal = ContinuousClock.now - releasedAt
      // No key and no microphone here: press to recording is not measured.
      let measured = DictationTimingInputs(
        releasedAt: releasedAt, seal: seal, pressToRecording: nil, mode: .dictate)
      let outcome = try await runtime.process(finalization)
      let highest = await sampler.stop()
      let times = await runtime.takeStageTimes(sessionID: sessionID)
      let inserted = outcome.snapshot.insertion?.inserted == true
      let timing = Self.dictationTiming(
        measured: measured, times: times, outcome: inserted ? .written : .kept,
        audio: finalization.audio, now: Date())
      try? await dictationMetricsStore?.record(timing)
      await runtime.clearLiveSession(sessionID: sessionID)
      let take = DictationProbeSummary.Take(
        file: file.lastPathComponent, state: state, audioMilliseconds: timing.audioMilliseconds,
        recognizerWasCold: timing.recognizerWasCold,
        recognizerSideMilliseconds: timing.releaseToTextMilliseconds,
        sealMilliseconds: timing.sealMilliseconds,
        recognitionMilliseconds: timing.recognitionMilliseconds,
        cleanupMilliseconds: timing.cleanupMilliseconds,
        deliveryMilliseconds: timing.deliveryMilliseconds,
        queueMilliseconds: timing.queueMilliseconds,
        footprintAtTextMB: timing.footprintMegabytes,
        highestFootprintDuringMB: ProcessFootprint.megabytes(highest),
        wordsWritten: inserted,
        characterCount: (outcome.snapshot.polish?.text ?? outcome.snapshot.transcript?.text ?? "")
          .count)
      return (take, sessionID)
    }

    nonisolated static func probeSamples(_ url: URL) throws -> [Float] {
      let file = try AVAudioFile(forReading: url)
      guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
        let buffer = AVAudioPCMBuffer(
          pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
      else { throw CocoaError(.fileReadCorruptFile) }
      try file.read(into: buffer)
      guard let channel = buffer.floatChannelData?[0] else {
        throw CocoaError(.fileReadCorruptFile)
      }
      return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    nonisolated static func processCPUSeconds() -> Double {
      var usage = rusage()
      getrusage(RUSAGE_SELF, &usage)
      return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
  }
#endif
