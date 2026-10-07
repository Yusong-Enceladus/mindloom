import Darwin
import Foundation

/// A recording waiting on the watch, and what happened to its last transfer.
public struct QueuedRecording: Codable, Equatable, Sendable, Identifiable {
  public enum Transfer: String, Codable, Sendable {
    /// Not handed to WatchConnectivity yet.
    case none
    /// Handed to WatchConnectivity; no result yet.
    case sending
    /// WatchConnectivity delivered the file; the iPhone has not said it stored it yet.
    case delivered
    /// The last transfer failed (it is tried again after a pause).
    case failed
  }

  public var recording: WatchRecording
  public var transfer: Transfer
  public var lastSentAt: Date?
  public var deliveredAt: Date?
  public var failures: Int

  public var id: String { recording.id }

  public init(recording: WatchRecording) {
    self.recording = recording
    self.transfer = .none
    self.failures = 0
  }

  enum CodingKeys: String, CodingKey {
    case recording, transfer, failures
    case lastSentAt = "last_sent_at"
    case deliveredAt = "delivered_at"
  }
}

/// The watch's recordings (WATCH-003): each one stays here until the iPhone says it has stored the
/// original, however long that takes.
///
/// ```
/// <root>/
///   recording/<id>.aac     the recording in progress (ADTS: readable even if cut short)
///   recording/<id>.start   when it started
///   ready/<id>.aac         finished, waiting for the iPhone
///   ready/<id>.json        its QueuedRecording
///   tmp/                   staging for atomic writes
/// ```
///
/// A recording is never removed for any other reason than the iPhone's "stored" for its id. After
/// a crash, `recover` turns what is left in `recording/` into ready recordings (marked
/// interrupted), so nothing recorded is lost.
public final class WatchRecordingQueue: @unchecked Sendable {
  /// A delivered file the iPhone has not confirmed is sent again only after this long, as a last
  /// resort. "Delivered" means the file is in the iPhone's WatchConnectivity queue, waiting for
  /// Mindloom there to run: sending it again does not make that happen sooner and costs the
  /// watch's battery. What the iPhone, asked while it runs, says it lacks is sent again at once
  /// (`noteMissing`).
  public static let resendAfterDelivery: TimeInterval = 6 * 60 * 60
  /// A transfer with no result that WatchConnectivity no longer lists is sent again after this long.
  public static let resendAfterSilence: TimeInterval = 30 * 60
  /// Pause after the first failure; it doubles with each failure up to `maximumRetryPause`.
  public static let firstRetryPause: TimeInterval = 30
  public static let maximumRetryPause: TimeInterval = 30 * 60

  public let root: URL
  private let lock = NSLock()

  private var recordingDirectory: URL {
    root.appendingPathComponent("recording", isDirectory: true)
  }
  private var readyDirectory: URL { root.appendingPathComponent("ready", isDirectory: true) }
  private var tmpDirectory: URL { root.appendingPathComponent("tmp", isDirectory: true) }

  public init(root: URL) throws {
    self.root = root
    for directory in [root, recordingDirectory, readyDirectory, tmpDirectory] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
  }

  /// `Application Support/recordings` of the watch app.
  public static func standard() throws -> WatchRecordingQueue {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    return try WatchRecordingQueue(
      root: support.appendingPathComponent("recordings", isDirectory: true))
  }

  // MARK: - Recording

  /// Where the recorder writes a new recording; notes when it started.
  public func beginRecording(id: String = WatchRecordingID.make(), startedAt: Date) throws -> URL {
    guard WatchRecordingID.isValid(id) else { throw WatchRecording.ValidationError.invalidID }
    let start = try WatchFiles.encoder().encode(StartNote(startedAt: startedAt))
    try locked {
      try WatchFiles.atomicWrite(start, to: startFile(id), staging: tmpDirectory)
    }
    return recordingFile(id)
  }

  /// The recorder stopped: the file becomes a ready recording. Nil (and nothing kept) when the
  /// file is missing or empty.
  @discardableResult
  public func finishRecording(id: String, duration: TimeInterval, interrupted: Bool) throws
    -> WatchRecording?
  {
    try locked {
      try finishLocked(id: id, startedAt: nil, duration: duration, interrupted: interrupted)
    }
  }

  private func finishLocked(
    id: String, startedAt: Date?, duration: TimeInterval, interrupted: Bool
  ) throws -> WatchRecording? {
    let file = recordingFile(id)
    let started =
      startedAt
      ?? (try? Data(contentsOf: startFile(id))).flatMap {
        try? WatchFiles.decoder().decode(StartNote.self, from: $0).startedAt
      }
      ?? ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.creationDate] as? Date)
      ?? Date()
    guard FileManager.default.fileExists(atPath: file.path) else {
      try? FileManager.default.removeItem(at: startFile(id))
      return nil
    }
    let digest = try WatchFileDigest.of(file)
    guard digest.bytes > 0 else {
      try? FileManager.default.removeItem(at: file)
      try? FileManager.default.removeItem(at: startFile(id))
      return nil
    }
    let recording = WatchRecording(
      id: id, startedAt: started,
      duration: min(max(0, duration.isFinite ? duration : 0), WatchRecording.maximumDuration + 60),
      bytes: digest.bytes, sha256: digest.sha256, interrupted: interrupted)
    // The description first, then the audio: a crash in between leaves the audio in
    // `recording/` with its description already ready, and `recover` finishes the move.
    try write(QueuedRecording(recording: recording))
    try WatchFiles.replace(readyFile(id), with: file)
    try? FileManager.default.removeItem(at: startFile(id))
    return recording
  }

  /// At launch, before any new recording: finishes what a crash or a forced end left behind.
  /// `duration` reads a file's length in seconds (AVFoundation, in the app).
  @discardableResult
  public func recover(duration: (URL) -> TimeInterval?) -> [WatchRecording] {
    locked {
      var recovered: [WatchRecording] = []
      // A recording cut short, or one whose move was interrupted.
      for id in WatchFiles.ids(in: recordingDirectory, suffix: WatchRecording.fileExtension) {
        if let queued = read(id) {
          if (try? WatchFiles.replace(readyFile(id), with: recordingFile(id))) != nil {
            try? FileManager.default.removeItem(at: startFile(id))
            recovered.append(queued.recording)
          }
          continue
        }
        let seconds = duration(recordingFile(id)) ?? 0
        if let recording = try? finishLocked(
          id: id, startedAt: nil, duration: seconds, interrupted: true)
        {
          recovered.append(recording)
        }
      }
      // A start note whose audio never appeared.
      for id in WatchFiles.ids(in: recordingDirectory, suffix: "start")
      where !FileManager.default.fileExists(atPath: recordingFile(id).path) {
        try? FileManager.default.removeItem(at: startFile(id))
      }
      // A description whose audio is gone (nothing to send) is dropped; audio without a
      // description gets one.
      for id in WatchFiles.ids(in: readyDirectory, suffix: "json")
      where !FileManager.default.fileExists(atPath: readyFile(id).path) {
        try? FileManager.default.removeItem(at: descriptionFile(id))
      }
      for id in WatchFiles.ids(in: readyDirectory, suffix: WatchRecording.fileExtension)
      where read(id) == nil {
        guard let digest = try? WatchFileDigest.of(readyFile(id)), digest.bytes > 0 else {
          continue
        }
        let created =
          (try? FileManager.default.attributesOfItem(atPath: readyFile(id).path))?[.creationDate]
          as? Date
        let recording = WatchRecording(
          id: id, startedAt: created ?? Date(), duration: duration(readyFile(id)) ?? 0,
          bytes: digest.bytes, sha256: digest.sha256, interrupted: true)
        if (try? write(QueuedRecording(recording: recording))) != nil {
          recovered.append(recording)
        }
      }
      return recovered
    }
  }

  // MARK: - Waiting recordings

  /// Every recording still on the watch, oldest first.
  public func pending() -> [QueuedRecording] {
    locked {
      WatchFiles.ids(in: readyDirectory, suffix: "json").compactMap { read($0) }
        .filter { FileManager.default.fileExists(atPath: readyFile($0.id).path) }
        .sorted { ($0.recording.startedAt, $0.id) < ($1.recording.startedAt, $1.id) }
    }
  }

  public var pendingCount: Int { pending().count }

  /// The audio of a waiting recording.
  public func fileURL(id: String) -> URL { readyFile(id) }

  public func markSending(id: String, at date: Date = Date()) {
    update(id) {
      $0.transfer = .sending
      $0.lastSentAt = date
    }
  }

  public func markDelivered(id: String, at date: Date = Date()) {
    update(id) {
      $0.transfer = .delivered
      $0.deliveredAt = date
      $0.failures = 0
    }
  }

  public func markFailed(id: String, at date: Date = Date()) {
    update(id) {
      $0.transfer = .failed
      $0.failures += 1
      $0.lastSentAt = $0.lastSentAt ?? date
    }
  }

  /// The iPhone stored these originals: their copies here are removed. Returns the ids removed.
  @discardableResult
  public func removeStored(_ ids: [String]) -> [String] {
    locked {
      ids.filter(WatchRecordingID.isValid).filter { id in
        guard read(id) != nil || FileManager.default.fileExists(atPath: readyFile(id).path) else {
          return false
        }
        try? FileManager.default.removeItem(at: readyFile(id))
        try? FileManager.default.removeItem(at: descriptionFile(id))
        return true
      }
    }
  }

  /// The iPhone answered "holding" and said it lacks these ids although WatchConnectivity had
  /// nothing more for it (`WatchHandoffMessage.reply`'s `missing`). A copy WatchConnectivity
  /// reported delivered (or lost without a result) is not on the iPhone after all: it becomes due
  /// again at once instead of after `resendAfterDelivery`. A copy delivered less than
  /// `missingGrace` ago may still be on its way into the app and is left alone; one
  /// WatchConnectivity is still transferring (`outstanding`) is never sent twice. Returns the ids
  /// made due.
  @discardableResult
  public func noteMissing(_ ids: [String], outstanding: Set<String>, now: Date = Date())
    -> [String]
  {
    locked {
      ids.filter(WatchRecordingID.isValid).filter { id in
        guard !outstanding.contains(id), var queued = read(id) else { return false }
        let since: Date?
        switch queued.transfer {
        case .delivered: since = queued.deliveredAt
        case .sending: since = queued.lastSentAt
        case .none, .failed: return false
        }
        guard now.timeIntervalSince(since ?? .distantPast) >= Self.missingGrace else {
          return false
        }
        queued.transfer = .none
        return (try? write(queued)) != nil
      }
    }
  }

  /// See `noteMissing`.
  public static let missingGrace: TimeInterval = 60

  /// The recordings to hand to WatchConnectivity now. `outstanding` are the ids WatchConnectivity
  /// is still transferring (never sent twice at once).
  public func due(now: Date = Date(), outstanding: Set<String>) -> [QueuedRecording] {
    pending().filter { Self.isDue($0, now: now, outstanding: outstanding) }
  }

  static func isDue(_ queued: QueuedRecording, now: Date, outstanding: Set<String>) -> Bool {
    guard !outstanding.contains(queued.id) else { return false }
    switch queued.transfer {
    case .none:
      return true
    case .sending:
      return now.timeIntervalSince(queued.lastSentAt ?? .distantPast) >= resendAfterSilence
    case .delivered:
      return now.timeIntervalSince(queued.deliveredAt ?? .distantPast) >= resendAfterDelivery
    case .failed:
      let pause = min(
        maximumRetryPause, firstRetryPause * pow(2, Double(max(0, queued.failures - 1))))
      return now.timeIntervalSince(queued.lastSentAt ?? .distantPast) >= pause
    }
  }

  /// When the next waiting recording becomes due (`isDue`), for the background refresh: `now`
  /// when one is due already, nil when nothing waits. One WatchConnectivity is transferring
  /// counts from when it was handed over.
  public func nextDue(after now: Date = Date()) -> Date? {
    pending().map { queued -> Date in
      switch queued.transfer {
      case .none:
        return now
      case .sending:
        return (queued.lastSentAt ?? now).addingTimeInterval(Self.resendAfterSilence)
      case .delivered:
        return (queued.deliveredAt ?? now).addingTimeInterval(Self.resendAfterDelivery)
      case .failed:
        let pause = min(
          Self.maximumRetryPause,
          Self.firstRetryPause * pow(2, Double(max(0, queued.failures - 1))))
        return (queued.lastSentAt ?? now).addingTimeInterval(pause)
      }
    }.map { max($0, now) }.min()
  }

  // MARK: - Files

  private struct StartNote: Codable {
    let startedAt: Date
    enum CodingKeys: String, CodingKey { case startedAt = "started_at" }
  }

  private func recordingFile(_ id: String) -> URL {
    recordingDirectory.appendingPathComponent("\(id).\(WatchRecording.fileExtension)")
  }

  private func startFile(_ id: String) -> URL {
    recordingDirectory.appendingPathComponent("\(id).start")
  }

  private func readyFile(_ id: String) -> URL {
    readyDirectory.appendingPathComponent("\(id).\(WatchRecording.fileExtension)")
  }

  private func descriptionFile(_ id: String) -> URL {
    readyDirectory.appendingPathComponent("\(id).json")
  }

  private func read(_ id: String) -> QueuedRecording? {
    guard let data = try? Data(contentsOf: descriptionFile(id)),
      let queued = try? WatchFiles.decoder().decode(QueuedRecording.self, from: data),
      queued.id == id
    else { return nil }
    return queued
  }

  private func write(_ queued: QueuedRecording) throws {
    let data = try WatchFiles.encoder().encode(queued)
    try WatchFiles.atomicWrite(data, to: descriptionFile(queued.id), staging: tmpDirectory)
  }

  private func update(_ id: String, _ change: (inout QueuedRecording) -> Void) {
    locked {
      guard var queued = read(id) else { return }
      change(&queued)
      try? write(queued)
    }
  }

  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
}
