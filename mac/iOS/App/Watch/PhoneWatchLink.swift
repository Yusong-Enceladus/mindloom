import Foundation
import MindloomPhoneKit
import MindloomWatchHandoff
import UIKit
import WatchConnectivity
import os

/// The iPhone's end of the Apple Watch link (WATCH-004): receives each recording, keeps the
/// original (size and SHA-256 checked) and tells the watch it has stored it, which is the only
/// thing that lets the watch remove its copy.
///
/// WatchConnectivity calls the delegate on its own queue, possibly in a launch in the background;
/// the received file is removed when `session(_:didReceive:)` returns, so it is copied before.
/// Nothing here reads or logs the audio's content.
///
/// What brings a file in: WatchConnectivity hands a file to this app only while it runs; a file
/// that reaches the iPhone meanwhile waits in WatchConnectivity's queue. The watch's "holding"
/// (sent while its app runs) launches this app in the background; it then stays up while
/// WatchConnectivity hands over what it holds and while a recording the watch holds may still
/// arrive (bounded), and only then answers. Otherwise the file comes in the next time the app
/// runs (opened, or a background refresh).
final class PhoneWatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
  static let shared = PhoneWatchLink()

  private let log = Logger(subsystem: PhoneNames.appLog, category: "watch")
  private let lock = NSLock()
  private var inbox: WatchRecordingInbox?
  private var onStored: (@Sendable (WatchRecording) -> Void)?
  #if DEBUG
    private var debugImport: DispatchSourceTimer?
  #endif

  /// Starts the session (once per launch). `onStored` runs for every newly stored original.
  func activate(inbox: WatchRecordingInbox, onStored: @escaping @Sendable (WatchRecording) -> Void)
  {
    lock.lock()
    let first = self.inbox == nil
    self.inbox = inbox
    self.onStored = onStored
    lock.unlock()
    guard first, WCSession.isSupported() else { return }
    let session = WCSession.default
    session.delegate = self
    session.activate()
  }

  private var current: (WatchRecordingInbox?, (@Sendable (WatchRecording) -> Void)?) {
    lock.lock()
    defer { lock.unlock() }
    return (inbox, onStored)
  }

  // MARK: - Receiving

  func session(_ session: WCSession, didReceive file: WCSessionFile) {
    receive(file.fileURL, metadata: file.metadata, session: session)
  }

  /// Stores one received recording and confirms it. Returns once the file is copied (the caller's
  /// file may be removed right after).
  private func receive(_ url: URL, metadata: [String: Any]?, session: WCSession) {
    let (inbox, onStored) = current
    guard let inbox else { return }
    do {
      switch try inbox.accept(file: url, metadata: metadata) {
      case .stored(let recording):
        log.notice("watch recording stored (\(recording.bytes, privacy: .public) bytes)")
        acknowledge([recording.id], session: session)
        onStored?(recording)
      case .duplicate(let recording):
        log.notice("watch recording received again; confirmed")
        acknowledge([recording.id], session: session)
      }
    } catch {
      // The watch keeps its copy and sends it again.
      log.error("watch recording not stored: \(String(describing: error), privacy: .public)")
    }
  }

  /// "stored" for `ids`: queued for the watch (delivered even when its app is not running), sent
  /// at once when it is reachable, and the latest stored ids in the application context.
  private func acknowledge(_ ids: [String], session: WCSession) {
    guard session.activationState == .activated else { return }
    let message = WatchHandoffMessage.stored(ids).dictionary
    session.transferUserInfo(message)
    if session.isReachable {
      session.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }
    publishContext(session)
  }

  private func publishContext(_ session: WCSession) {
    guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
      let inbox = current.0
    else { return }
    try? session.updateApplicationContext(WatchHandoffMessage.stored(inbox.recentIDs()).dictionary)
  }

  /// The watch asks which of the recordings it still holds are here. Answered once
  /// WatchConnectivity has handed over what it holds for this app (bounded), so a recording
  /// reported missing is really not here; then the app stays up a little longer for what the
  /// watch has not handed over yet.
  func session(
    _ session: WCSession, didReceiveMessage message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void
  ) {
    guard case .holding(let ids) = WatchHandoffMessage(dictionary: message), let inbox = current.0
    else {
      replyHandler([:])
      return
    }
    nonisolated(unsafe) let reply = replyHandler
    Task { @MainActor in
      let stay = BackgroundStay(name: "watch-holding")
      let drained = await Self.waitUntilDrained(WCSession.default, seconds: Self.drainWait)
      let stored = inbox.storedIDs(among: ids)
      let missing = drained ? ids.filter { !stored.contains($0) } : []
      reply(WatchHandoffMessage.reply(stored: stored, missing: missing).dictionary)
      if stored.count < ids.count {
        // The watch sends what it lacks now; stay up for it (each one stored ends the wait).
        var waited: Double = 0
        while waited < Self.arrivalWait, inbox.storedIDs(among: ids).count < ids.count {
          try? await Task.sleep(for: .milliseconds(250))
          waited += 0.25
        }
      }
      stay.end()
    }
  }

  /// How long an answer waits for WatchConnectivity to hand over what it holds (a reply that
  /// takes too long reaches the watch as an error; the watch asks again).
  static let drainWait: Double = 5
  /// How long the app stays up after answering, for a recording still coming from the watch.
  static let arrivalWait: Double = 20

  /// Until WatchConnectivity has nothing more for this app (or `seconds` passed). True when it
  /// has nothing more.
  @MainActor
  static func waitUntilDrained(_ session: WCSession, seconds: Double) async -> Bool {
    var waited: Double = 0
    while waited < seconds {
      if session.activationState == .activated, !session.hasContentPending { return true }
      try? await Task.sleep(for: .milliseconds(200))
      waited += 0.2
    }
    return session.activationState == .activated && !session.hasContentPending
  }

  /// The background refresh: lets WatchConnectivity hand over what it holds first.
  @MainActor
  func waitUntilDrained(seconds: Double) async {
    guard WCSession.isSupported(), current.0 != nil else { return }
    _ = await Self.waitUntilDrained(WCSession.default, seconds: seconds)
  }

  // MARK: - Session life cycle

  func session(
    _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    if let error {
      log.error("watch session: \(String(describing: error), privacy: .public)")
      return
    }
    publishContext(session)
    #if DEBUG
      startDebugImport(session: session)
    #endif
  }

  func sessionWatchStateDidChange(_ session: WCSession) {
    publishContext(session)
  }

  func sessionDidBecomeInactive(_ session: WCSession) {}

  /// Switching to another watch: activate again for the new one.
  func sessionDidDeactivate(_ session: WCSession) {
    session.activate()
  }

  #if DEBUG
    /// DEBUG only (`-MindloomWatchImport <folder>`). Paired simulators pass WatchConnectivity
    /// messages, user info and the application context, but not files: the watch is told a file
    /// was delivered and the app never receives it (seen with iOS 26.5 and watchOS 26.5
    /// simulators; Apple developer forums thread 770957). The paired-simulator end-to-end stands in
    /// for that one hop: it puts each recording the watch handed to WatchConnectivity in the folder
    /// (`<id>.aac`, then its transfer metadata as `<id>.plist`). Each is taken through the same
    /// path as a received file and removed from the folder; the "stored" goes back to the watch
    /// over WatchConnectivity as usual.
    private func startDebugImport(session: WCSession) {
      // Kept in the app's own defaults, so a launch in the background by the watch's message
      // (no launch arguments) imports too; an empty value turns it off again.
      let defaults = UserDefaults.standard
      if let given = defaults.volatileDomain(forName: UserDefaults.argumentDomain)[
        "MindloomWatchImport"] as? String
      {
        defaults.set(given.isEmpty ? nil : given, forKey: "MindloomWatchImport")
      }
      guard debugImport == nil,
        let folder = defaults.string(forKey: "MindloomWatchImport"), !folder.isEmpty
      else { return }
      let directory = URL(fileURLWithPath: folder, isDirectory: true)
      let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "watch-import"))
      timer.schedule(deadline: .now(), repeating: 1)
      timer.setEventHandler { [weak self] in self?.importDebugFolder(directory, session: session) }
      timer.resume()
      debugImport = timer
    }

    private func importDebugFolder(_ directory: URL, session: WCSession) {
      let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
      for name in names where name.hasSuffix(".plist") {
        let plist = directory.appendingPathComponent(name)
        let audio = plist.deletingPathExtension().appendingPathExtension(
          WatchRecording.fileExtension)
        let metadata =
          (try? Data(contentsOf: plist)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil)
          } as? [String: Any]
        receive(audio, metadata: metadata, session: session)
        try? FileManager.default.removeItem(at: plist)
        try? FileManager.default.removeItem(at: audio)
      }
    }
  #endif
}

/// Keeps the app running in the background for a short job (`UIApplication` background task),
/// ended by `end()` or by the system when the time is up.
@MainActor
final class BackgroundStay {
  private var id: UIBackgroundTaskIdentifier = .invalid

  init(name: String) {
    id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
      MainActor.assumeIsolated { self?.end() }
    }
  }

  func end() {
    guard id != .invalid else { return }
    UIApplication.shared.endBackgroundTask(id)
    id = .invalid
  }
}
