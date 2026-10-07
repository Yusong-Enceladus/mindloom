import Foundation
import MindloomWatchHandoff
import Observation
import WatchKit
import os

/// Mindloom on Apple Watch (WATCH-001–007): tap to record, tap to stop; every recording waits on
/// the watch until the iPhone has stored it. Nothing is transcribed here.
@MainActor
@Observable
final class WatchModel {
  enum Phase: Equatable {
    case idle
    case starting
    case recording(since: Date)
  }

  enum Problem: Equatable {
    case microphoneDenied
    case couldNotStart
    /// At the 30-minute mark the next part did not start; what was recorded is kept.
    case couldNotContinue
  }

  static let shared = WatchModel()

  private(set) var phase: Phase = .idle
  private(set) var problem: Problem?
  /// Recordings on the watch that the iPhone has not stored yet.
  private(set) var pendingCount = 0
  /// What waits is on its way (「正在发送到 iPhone…」): the iPhone is in reach with Mindloom and
  /// answers (`WatchLink.isSending`). Otherwise the screen says how many wait on the watch.
  private(set) var sending = false
  /// A recording was finished during this visit (「已发送到 iPhone」 once the count is 0).
  private(set) var recordedThisVisit = false

  @ObservationIgnored let queue: WatchRecordingQueue
  @ObservationIgnored let link: WatchLink
  @ObservationIgnored private let recorder: any WatchAudioRecorder
  @ObservationIgnored private var currentID: String?
  @ObservationIgnored private var currentURL: URL?
  @ObservationIgnored private var limitTimer: Task<Void, Never>?
  @ObservationIgnored private var autoStopTimer: Task<Void, Never>?
  @ObservationIgnored private var retryTimer: Task<Void, Never>?
  /// Until then the app asks the iPhone often (after a recording stopped, while on screen).
  @ObservationIgnored private var askOftenUntil = Date.distantPast
  @ObservationIgnored private let log = Logger(subsystem: "app.mindloom.watchkitapp", category: "model")

  /// One part of a recording is at most this long; the next part starts at once (WATCH-002).
  private static var partLimit: TimeInterval {
    #if DEBUG
      // `-MindloomWatchPartSeconds <seconds>`: shorter parts, to test the continuation.
      let seconds = UserDefaults.standard.double(forKey: "MindloomWatchPartSeconds")
      if seconds > 0 { return seconds }
    #endif
    return WatchRecording.maximumDuration
  }

  /// After a recording stops the app asks the iPhone this often, for `askOftenFor`; then every
  /// `WatchRecordingQueue.firstRetryPause` while it stays on screen.
  static let askEvery: TimeInterval = 10
  static let askOftenFor: TimeInterval = 120

  private init() {
    let queue =
      (try? WatchRecordingQueue.standard())
      ?? (try! WatchRecordingQueue(
        root: FileManager.default.temporaryDirectory.appendingPathComponent("recordings")))
    self.queue = queue
    #if DEBUG
      recorder = SyntheticRecorder.fromLaunchArguments() ?? MicrophoneRecorder()
    #else
      recorder = MicrophoneRecorder()
    #endif
    link = WatchLink(queue: queue)
    // What a forced end left behind becomes a recording like any other.
    let recovered = queue.recover(duration: WatchAudioFormat.duration(of:))
    if !recovered.isEmpty {
      log.notice("recovered \(recovered.count, privacy: .public) recordings")
    }
    recorder.onEnded = { [weak self] in self?.stop(interrupted: true) }
    RecordRequest.handler = { [weak self] in self?.requestStart() }
    link.onChange = { WatchModel.shared.refresh() }
    link.activate()
    refresh()
  }

  var isRecording: Bool {
    if case .recording = phase { return true }
    return false
  }

  /// The one button: record, or stop.
  func toggle() {
    switch phase {
    case .idle: start()
    case .recording: stop(interrupted: false)
    case .starting: break
    }
  }

  /// A link the app was opened with (the complication's `mindloom://record`).
  func open(_ url: URL) {
    if RecordRequest.isRecordURL(url) { requestStart() }
  }

  /// The complication, the control and Siri: start now when the app is active, else as soon as
  /// it is (watchOS lets recording start only in the foreground; a cold launch from the watch face
  /// can bring the link before the app is active).
  func requestStart() {
    if WKApplication.shared().applicationState == .active {
      start()
    } else {
      RecordRequest.pending = true
    }
  }

  /// Starts recording (the button, or a request once the app is active). Only in the foreground.
  func start() {
    guard phase == .idle else { return }
    problem = nil
    phase = .starting
    let startedAt = Date()
    let id = WatchRecordingID.make()
    Task { [weak self] in
      guard let self else { return }
      do {
        let url = try queue.beginRecording(id: id, startedAt: startedAt)
        try await recorder.start(writingTo: url)
        currentID = id
        currentURL = url
        phase = .recording(since: startedAt)
        WKInterfaceDevice.current().play(.start)
        scheduleLimit()
        #if DEBUG
          // `-MindloomWatchAutoStop <seconds>` (simulator runs without a tap): stops like the button.
          let autoStop = UserDefaults.standard.double(forKey: "MindloomWatchAutoStop")
          if autoStop > 0 {
            autoStopTimer = Task { [weak self] in
              try? await Task.sleep(for: .seconds(autoStop))
              guard !Task.isCancelled else { return }
              self?.stop(interrupted: false)
            }
          }
        #endif
      } catch {
        problem =
          (error as? WatchRecorderError) == .microphoneDenied ? .microphoneDenied : .couldNotStart
        phase = .idle
        _ = try? queue.finishRecording(id: id, duration: 0, interrupted: true)
        log.error("start failed: \(String(describing: error), privacy: .public)")
      }
    }
  }

  private func scheduleLimit() {
    limitTimer?.cancel()
    let limit = Self.partLimit
    limitTimer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(limit))
      guard !Task.isCancelled else { return }
      self?.continueInNextPart()
    }
  }

  /// The part limit: this part is kept (marked as ended without the stop button) and the next one
  /// starts at once, on the same audio session, also with the wrist down. If it cannot start,
  /// recording stops there and the screen says so.
  private func continueInNextPart() {
    guard case .recording = phase, let id = currentID, let url = currentURL else { return }
    let nextID = WatchRecordingID.make()
    let nextStart = Date()
    do {
      let nextURL = try queue.beginRecording(id: nextID, startedAt: nextStart)
      do {
        let seconds = try recorder.continueRecording(writingTo: nextURL)
        currentID = nextID
        currentURL = nextURL
        keep(id: id, url: url, seconds: seconds, interrupted: true)
        scheduleLimit()
        log.notice("recording continues in a new part")
        refresh()
        link.sendDue()
        return
      } catch {
        _ = try? queue.finishRecording(id: nextID, duration: 0, interrupted: true)
        throw error
      }
    } catch {
      log.error("next part did not start: \(String(describing: error), privacy: .public)")
      stop(interrupted: true)
      problem = .couldNotContinue
      WKInterfaceDevice.current().play(.failure)
    }
  }

  /// Stops and keeps the recording; it goes to the iPhone right away when possible.
  func stop(interrupted: Bool) {
    guard case .recording = phase, let id = currentID, let url = currentURL else { return }
    limitTimer?.cancel()
    limitTimer = nil
    autoStopTimer?.cancel()
    autoStopTimer = nil
    let seconds = recorder.stop()
    currentID = nil
    currentURL = nil
    phase = .idle
    keep(id: id, url: url, seconds: seconds, interrupted: interrupted)
    WKInterfaceDevice.current().play(.stop)
    askOftenUntil = Date().addingTimeInterval(Self.askOftenFor)
    refresh()
    link.sendDue()
  }

  /// The finished file becomes a waiting recording. Its length is read from the file: after
  /// the system stopped the recorder (an encoder error), the recorder reports 0.
  private func keep(id: String, url: URL, seconds: TimeInterval, interrupted: Bool) {
    let length = WatchAudioFormat.duration(of: url) ?? seconds
    do {
      if try queue.finishRecording(id: id, duration: length, interrupted: interrupted) != nil {
        recordedThisVisit = true
      }
    } catch {
      log.error("recording not finished: \(String(describing: error), privacy: .public)")
    }
  }

  func level() -> Double { recorder.level() }

  /// Rereads the waiting count and whether the iPhone is in reach; keeps asking while something
  /// waits and the app runs.
  func refresh() {
    pendingCount = queue.pendingCount
    sending = pendingCount > 0 && link.isSending()
    scheduleRetry()
  }

  /// The screen appeared or the app became active: send what is due, take a request that came
  /// before the app was ready.
  func becameActive() {
    askOftenUntil = max(askOftenUntil, Date().addingTimeInterval(Self.askOftenFor / 4))
    link.sendDue()
    if RecordRequest.pending {
      RecordRequest.pending = false
      start()
    }
    refresh()
  }

  private func scheduleRetry() {
    retryTimer?.cancel()
    guard pendingCount > 0 else {
      retryTimer = nil
      return
    }
    let pause =
      Date() < askOftenUntil ? Self.askEvery : WatchRecordingQueue.firstRetryPause
    retryTimer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(pause))
      guard !Task.isCancelled, let self else { return }
      self.link.sendDue()
      self.refresh()
    }
    scheduleBackgroundRefresh()
  }

  /// While recordings wait, the system wakes the app when the next one is due to be sent again
  /// (never sooner than 15 minutes). A refresh cannot reach Mindloom on the iPhone (only a
  /// message while this app runs launches it); it hands over what failed or never left.
  private func scheduleBackgroundRefresh() {
    let earliest = Date(timeIntervalSinceNow: 15 * 60)
    let when = max(earliest, queue.nextDue(after: Date()) ?? earliest)
    WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: when, userInfo: nil) { _ in
    }
  }
}
