import Foundation
import MindloomWatchHandoff
import WatchConnectivity
import os

/// The watch's end of the link to the iPhone (WATCH-003): hands each waiting recording to
/// WatchConnectivity (which keeps transferring after the app leaves the screen), sends again after
/// a failure, a long silence or when the iPhone says it lacks one, and removes a recording only
/// when the iPhone says it stored the original ("stored", by message, queued user info or the
/// application context).
///
/// WatchConnectivity hands a file to Mindloom on the iPhone only while that app runs. While this
/// app runs, "holding" (`sendMessage`) launches it there in the background; nothing else from the
/// watch does. So a recording reaches the iPhone app while this app is on screen (it keeps asking
/// for a while after a recording stops, `WatchModel`), or the next time either app runs.
final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
  let queue: WatchRecordingQueue
  /// Called on the main actor after the waiting recordings changed. Set once, before `activate`.
  var onChange: @MainActor @Sendable () -> Void = {}
  private let log = Logger(subsystem: "app.mindloom.watchkitapp", category: "link")
  private let lock = NSLock()

  init(queue: WatchRecordingQueue) {
    self.queue = queue
  }

  func activate() {
    guard WCSession.isSupported() else { return }
    WCSession.default.delegate = self
    WCSession.default.activate()
  }

  var isActivated: Bool { WCSession.default.activationState == .activated }

  /// When the iPhone last answered "holding", and since when a question has gone unanswered.
  private var lastAnswerAt: Date?
  private var unansweredSince: Date?
  /// Its own lock: an answer may arrive while `sendDue` holds `lock`.
  private let askLock = NSLock()
  /// An answer this recent means the iPhone is taking what waits.
  static let answerCounts: TimeInterval = 60
  /// A question is given this long to be answered before the iPhone counts as away.
  static let answerGrace: TimeInterval = 12

  /// What waits is on its way: the iPhone is in reach with Mindloom and has answered lately (or
  /// a question just went out). WatchConnectivity's own reachability alone is not enough: the
  /// paired simulators report it while the iPhone is shut down, and a message to an iPhone that
  /// is not there may get neither an answer nor an error.
  func isSending(now: Date = Date()) -> Bool {
    let session = WCSession.default
    guard session.activationState == .activated, session.isReachable,
      session.isCompanionAppInstalled
    else { return false }
    askLock.lock()
    defer { askLock.unlock() }
    if let lastAnswerAt, now.timeIntervalSince(lastAnswerAt) < Self.answerCounts { return true }
    if let unansweredSince, now.timeIntervalSince(unansweredSince) < Self.answerGrace {
      return true
    }
    return false
  }

  /// Waits (bounded) until the session is activated: after a launch in the background the
  /// activation has only just been asked for.
  func waitUntilActivated(seconds: Double) async -> Bool {
    var waited: Double = 0
    while !isActivated, waited < seconds {
      try? await Task.sleep(for: .milliseconds(200))
      waited += 0.2
    }
    return isActivated
  }

  /// True while WatchConnectivity still has something for this app.
  var hasContentPending: Bool { WCSession.default.hasContentPending }

  /// Hands every due recording to WatchConnectivity, then asks the iPhone (when it is reachable)
  /// which of the waiting ones it already has.
  func sendDue(now: Date = Date()) {
    sendDue(now: now, ask: true)
  }

  private func sendDue(now: Date, ask: Bool) {
    let session = WCSession.default
    guard session.activationState == .activated else { return }
    lock.lock()
    defer { lock.unlock() }
    let outstanding = Self.outstanding(session)
    for queued in queue.due(now: now, outstanding: outstanding) {
      _ = session.transferFile(
        queue.fileURL(id: queued.id), metadata: queued.recording.transferMetadata)
      queue.markSending(id: queued.id, at: now)
      log.notice(
        "recording handed to WatchConnectivity (\(queued.recording.bytes, privacy: .public) bytes)")
    }
    if ask { askIfReachable(session) }
  }

  /// The ids WatchConnectivity is still transferring.
  private static func outstanding(_ session: WCSession) -> Set<String> {
    Set(session.outstandingFileTransfers.compactMap { $0.file.metadata?["id"] as? String })
  }

  /// "holding" for every waiting recording. It also launches Mindloom on the iPhone in the
  /// background, which then takes what WatchConnectivity holds for it before it answers.
  private func askIfReachable(_ session: WCSession) {
    let waiting = queue.pending().map(\.id)
    guard session.isReachable, !waiting.isEmpty else { return }
    askLock.lock()
    if unansweredSince == nil { unansweredSince = Date() }
    askLock.unlock()
    session.sendMessage(
      WatchHandoffMessage.holding(waiting).dictionary,
      replyHandler: { [weak self] reply in
        self?.noteAnswer(true)
        self?.answered(asked: waiting, reply: reply)
      },
      errorHandler: { [weak self] error in
        self?.log.notice("holding not answered: \(String(describing: error), privacy: .public)")
        self?.noteAnswer(false)
      })
  }

  private func noteAnswer(_ answered: Bool) {
    askLock.lock()
    if answered {
      lastAnswerAt = Date()
      unansweredSince = nil
    } else {
      lastAnswerAt = nil
      unansweredSince = .distantPast
    }
    askLock.unlock()
    notifyChange()
  }

  /// The iPhone's answer to "holding": the ones it stored are removed here; the ones it says it
  /// lacks (it answered once WatchConnectivity had nothing more for it) are sent again at once
  /// (`WatchRecordingQueue.noteMissing`), even when WatchConnectivity reported them delivered.
  private func answered(asked: [String], reply: [String: Any]) {
    guard case .reply(let stored, let missing) = WatchHandoffMessage(dictionary: reply) else {
      return
    }
    handle(WatchHandoffMessage.stored(stored).dictionary)
    let lacking = Set(missing).intersection(asked)
    guard !lacking.isEmpty else { return }
    let again = queue.noteMissing(
      Array(lacking), outstanding: Self.outstanding(WCSession.default))
    guard !again.isEmpty else { return }
    log.notice("\(again.count, privacy: .public) recordings not on iPhone; sending again")
    sendDue(now: Date(), ask: false)
    notifyChange()
  }

  /// Any "stored" from the iPhone removes those recordings here.
  private func handle(_ dictionary: [String: Any]) {
    guard case .stored(let ids) = WatchHandoffMessage(dictionary: dictionary), !ids.isEmpty else {
      return
    }
    // A copy still on its way is no longer needed (and its file is about to go).
    let stored = Set(ids)
    for transfer in WCSession.default.outstandingFileTransfers
    where (transfer.file.metadata?["id"] as? String).map(stored.contains) == true {
      transfer.cancel()
    }
    let removed = queue.removeStored(ids)
    if !removed.isEmpty {
      log.notice("\(removed.count, privacy: .public) recordings stored on iPhone, removed here")
    }
    notifyChange()
  }

  private func notifyChange() {
    let onChange = onChange
    Task { @MainActor in onChange() }
  }

  // MARK: - WCSessionDelegate

  func session(
    _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    if let error {
      log.error("session: \(String(describing: error), privacy: .public)")
      return
    }
    handle(session.receivedApplicationContext)
    sendDue()
    notifyChange()
  }

  func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
    guard let id = fileTransfer.file.metadata?["id"] as? String else { return }
    if let error {
      queue.markFailed(id: id)
      log.error("transfer failed: \(String(describing: error), privacy: .public)")
    } else {
      queue.markDelivered(id: id)
      // The file waits in the iPhone's WatchConnectivity queue until Mindloom there runs: ask,
      // which launches it (only while this app runs).
      askIfReachable(session)
    }
    notifyChange()
  }

  func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    handle(userInfo)
  }

  func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any])
  {
    handle(applicationContext)
  }

  func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    handle(message)
  }

  func sessionReachabilityDidChange(_ session: WCSession) {
    if session.isReachable { sendDue() }
    notifyChange()
  }

  #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {}
  #endif
}
