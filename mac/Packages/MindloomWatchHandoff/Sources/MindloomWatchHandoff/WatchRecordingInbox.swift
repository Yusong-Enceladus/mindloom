import Darwin
import Foundation

/// An original the iPhone received from the watch, and where its transcription stands.
public struct ReceivedRecording: Codable, Equatable, Sendable, Identifiable {
  public enum Transcription: String, Codable, Sendable {
    /// Not transcribed yet (tried again until it is, with a pause after each failed try).
    case pending
    /// Transcribed; the text is the iPhone's item with the same id.
    case done
    /// Transcribed and nothing was said.
    case noSpeech = "no_speech"
    /// Could not be transcribed: the file does not read, or `maximumAttempts` tries failed. The
    /// item says 「无法转写音频」; 「重新转写」 makes it pending again.
    case failed
  }

  /// A recording whose tries keep failing is marked failed after this many, so it never holds up
  /// the others (and is not tried forever).
  public static let maximumAttempts = 3
  public static let firstRetryPause: TimeInterval = 5 * 60

  public let recording: WatchRecording
  public let receivedAt: Date
  public var transcription: Transcription
  /// Transcription attempts that ran and failed (a recognizer not ready yet does not count).
  public var attempts: Int
  public var lastAttemptAt: Date?
  /// The person deleted this recording: its audio is gone and only this note stays, so a copy
  /// the watch sends again is confirmed and not stored a second time.
  public var deletedAt: Date?
  /// The text it gave (`done`), kept with the original: the Home item is in the App Group, which
  /// is not in backups, so after a restore from a backup the item is made again from this
  /// (WATCH-009). Nil before it is transcribed, when nothing was said, after the person deletes
  /// the recording, and on records written before 2026-10-06 evening.
  public var text: String?

  public var id: String { recording.id }

  public init(recording: WatchRecording, receivedAt: Date) {
    self.recording = recording
    self.receivedAt = receivedAt
    self.transcription = .pending
    self.attempts = 0
  }

  enum CodingKeys: String, CodingKey {
    case recording, transcription, attempts, text
    case receivedAt = "received_at"
    case lastAttemptAt = "last_attempt_at"
    case deletedAt = "deleted_at"
  }

  /// Pending, and past the pause after its last failed try (5 minutes, doubling).
  public func isDueForTranscription(now: Date) -> Bool {
    guard transcription == .pending, deletedAt == nil else { return false }
    guard attempts > 0, let lastAttemptAt else { return true }
    let pause = Self.firstRetryPause * pow(2, Double(attempts - 1))
    return now.timeIntervalSince(lastAttemptAt) >= pause
  }
}

/// The iPhone's originals from Apple Watch (WATCH-004): kept as received, never removed by the app
/// on its own; only the person's own deletion (「删除录音…」, `delete`) removes one.
///
/// ```
/// <root>/
///   <id>.aac    the original, byte for byte what the watch recorded
///   <id>.json   its ReceivedRecording
///   tmp/        staging (excluded from backups)
/// ```
///
/// The originals, and the text each gave, are included in the iPhone's own backups (WATCH-009):
/// until device sync carries them to the Mac and the encrypted iCloud copy, a backup is the second
/// copy, when the person has iCloud Backup or a computer backup turned on (the app cannot tell).
/// Builds before 2026-10-06 excluded the directory; every open clears any exclusion found here
/// (`includeInBackups`).
public final class WatchRecordingInbox: @unchecked Sendable {
  public enum AcceptOutcome: Equatable, Sendable {
    /// Newly stored.
    case stored(WatchRecording)
    /// Already here with the same bytes (the watch sent it again): nothing changed.
    case duplicate(WatchRecording)
  }

  public enum AcceptError: Error, Equatable, Sendable {
    case invalidDescription
    case sizeMismatch
    case digestMismatch
    /// The same id with different bytes. The one already here is kept; the watch keeps its copy.
    case conflict
  }

  public let root: URL
  private let lock = NSLock()
  private var tmpDirectory: URL { root.appendingPathComponent("tmp", isDirectory: true) }

  public init(root: URL) throws {
    self.root = root
    try FileManager.default.createDirectory(at: tmpDirectory, withIntermediateDirectories: true)
    Self.includeInBackups(root: root, staging: tmpDirectory)
  }

  /// The originals go into the iPhone's backups; staging does not. Runs at every open: a file
  /// here that reads as excluded (its own mark from an earlier build, or one a received file
  /// brought along; on macOS a parent's exclusion reads the same way) is included, then the
  /// directory, and staging is excluded. The two directories are set every time rather than read
  /// first: the value read back can be stale for a moment. A mark that cannot be cleared now is
  /// tried again at the next open; it never keeps the inbox from opening (receiving outranks it).
  static func includeInBackups(root: URL, staging: URL) {
    var included = URLResourceValues()
    included.isExcludedFromBackup = false
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isExcludedFromBackupKey])) ?? []
    for file in files where file.lastPathComponent != staging.lastPathComponent {
      // The value was read with the listing.
      guard
        (try? file.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup
          == true
      else { continue }
      var file = file
      try? file.setResourceValues(included)
    }
    var mutableRoot = root
    try? mutableRoot.setResourceValues(included)
    var excluded = URLResourceValues()
    excluded.isExcludedFromBackup = true
    var mutableStaging = staging
    try? mutableStaging.setResourceValues(excluded)
  }

  /// `<directory>/watch-recordings`.
  public static func directory(in base: URL) -> URL {
    base.appendingPathComponent("watch-recordings", isDirectory: true)
  }

  // MARK: - Receiving

  /// Stores a received file (WatchConnectivity's copy, which is removed after the delegate
  /// returns) after checking it against its description. Safe to call again for the same id.
  public func accept(file: URL, metadata: [String: Any]?, now: Date = Date()) throws
    -> AcceptOutcome
  {
    let recording: WatchRecording
    do {
      recording = try WatchRecording(transferMetadata: metadata)
    } catch {
      throw AcceptError.invalidDescription
    }
    let digest = try WatchFileDigest.of(file)
    guard digest.bytes == recording.bytes else { throw AcceptError.sizeMismatch }
    guard digest.sha256 == recording.sha256 else { throw AcceptError.digestMismatch }
    return try locked {
      if let existing = read(recording.id), existing.deletedAt != nil {
        // Deleted by the person: confirmed (the watch removes its copy), not stored again.
        return .duplicate(existing.recording)
      }
      if let existing = read(recording.id) {
        guard existing.recording.sha256 == recording.sha256,
          FileManager.default.fileExists(atPath: audioFile(recording.id).path)
        else {
          if existing.recording.sha256 == recording.sha256 {
            // The description survived and the audio did not: take the audio again.
            try place(file, id: recording.id)
            return .stored(existing.recording)
          }
          throw AcceptError.conflict
        }
        return .duplicate(existing.recording)
      }
      // The audio first, then the description: a crash in between leaves audio without a
      // description, which the next copy of the same recording replaces.
      try place(file, id: recording.id)
      try write(ReceivedRecording(recording: recording, receivedAt: now))
      return .stored(recording)
    }
  }

  /// Copies into staging, then renames into place (the received file may be on any volume).
  private func place(_ file: URL, id: String) throws {
    let staging = tmpDirectory.appendingPathComponent(UUID().uuidString + ".aac")
    try FileManager.default.copyItem(at: file, to: staging)
    // A copy keeps the received file's own backup exclusion, and the original goes into backups
    // (WATCH-009). Not clearing it does not stop the original being kept: the next open does it.
    var included = URLResourceValues()
    included.isExcludedFromBackup = false
    var mutableStaging = staging
    try? mutableStaging.setResourceValues(included)
    #if os(iOS) || os(watchOS)
      try? FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: staging.path)
    #endif
    let handle = try FileHandle(forUpdating: staging)
    try handle.synchronize()
    try handle.close()
    do {
      try WatchFiles.replace(audioFile(id), with: staging)
    } catch {
      try? FileManager.default.removeItem(at: staging)
      throw error
    }
  }

  // MARK: - The backup notice (owner's decision 2026-10-06)

  /// The notice the iPhone shows the first time it receives a recording from Apple Watch: the
  /// original is kept only on this iPhone until it is in a backup. Product-standard zh-Hans
  /// (`docs/UI-COPY.md` §3).
  public enum BackupNotice {
    public static let title = "备份 Apple Watch 录音"
    public static let message =
      "来自 Apple Watch 的录音，其原件在备份之前仅存放于这台 iPhone。可在“设置”中打开“iCloud 云备份”，或使用电脑进行加密备份。iPhone 丢失或更换后，未备份的录音无法恢复。"
    public static let button = "好"
  }

  /// True exactly once for this inbox, ever: the caller shows `BackupNotice` when it is true.
  /// The mark is a file beside the originals, so it stays with them (a restore from a backup
  /// brings it back, and the notice does not return). When the mark cannot be written the answer
  /// is false: a notice that cannot be remembered is not shown, so it can never repeat.
  public func claimBackupNotice() -> Bool {
    locked {
      let mark = root.appendingPathComponent("backup-notice-shown", isDirectory: false)
      guard !FileManager.default.fileExists(atPath: mark.path) else { return false }
      return FileManager.default.createFile(atPath: mark.path, contents: Data("1".utf8))
    }
  }

  // MARK: - Reading

  public func record(id: String) -> ReceivedRecording? {
    guard WatchRecordingID.isValid(id) else { return nil }
    return locked { read(id) }
  }

  /// Every stored original, newest first.
  public func all() -> [ReceivedRecording] {
    locked {
      WatchFiles.ids(in: root, suffix: "json").compactMap { read($0) }
        .filter {
          $0.deletedAt == nil && FileManager.default.fileExists(atPath: audioFile($0.id).path)
        }
        .sorted { ($0.recording.startedAt, $0.id) > ($1.recording.startedAt, $1.id) }
    }
  }

  /// The ids of `ids` stored here, or stored and since deleted by the person (the answer to the
  /// watch's "holding": the watch removes its copy of either).
  public func storedIDs(among ids: [String]) -> [String] {
    locked {
      ids.filter { id in
        guard WatchRecordingID.isValid(id), let received = read(id) else { return false }
        return received.deletedAt != nil
          || FileManager.default.fileExists(atPath: audioFile(id).path)
      }
    }
  }

  /// The most recently received ids, for the application context the watch reads at launch.
  public func recentIDs(limit: Int = 200) -> [String] {
    Array(all().sorted { $0.receivedAt > $1.receivedAt }.prefix(limit).map(\.id))
  }

  /// Originals still waiting for their transcription, oldest first.
  public func pendingTranscription() -> [ReceivedRecording] {
    Array(all().filter { $0.transcription == .pending }.reversed())
  }

  /// The waiting originals to try now, oldest first: not in the pause after a failed try.
  public func dueForTranscription(now: Date = Date()) -> [ReceivedRecording] {
    pendingTranscription().filter { $0.isDueForTranscription(now: now) }
  }

  /// The original's audio.
  public func audioURL(id: String) -> URL { audioFile(id) }

  // MARK: - Transcription state

  public func setTranscription(_ transcription: ReceivedRecording.Transcription, id: String) throws
  {
    try update(id) { $0.transcription = transcription }
  }

  /// The original was transcribed: `done` with its text kept here (WATCH-009: a restore from a
  /// backup makes the Home item again from it), or `noSpeech` when nothing was said (nil or
  /// empty).
  public func noteTranscribed(text: String?, id: String) throws {
    let text = text.flatMap { $0.isEmpty ? nil : $0 }
    try update(id) {
      $0.transcription = text == nil ? .noSpeech : .done
      $0.text = text
    }
  }

  /// A transcription attempt ran and failed: tried again after a pause, and marked `failed`
  /// after `ReceivedRecording.maximumAttempts`. Returns the updated record.
  @discardableResult
  public func noteFailedAttempt(id: String, at date: Date = Date()) throws -> ReceivedRecording? {
    try update(id) {
      $0.attempts += 1
      $0.lastAttemptAt = date
      if $0.attempts >= ReceivedRecording.maximumAttempts { $0.transcription = .failed }
    }
  }

  /// 「重新转写」: a failed or silent original waits for its transcription again, from a fresh
  /// count. False when it is not one of those.
  @discardableResult
  public func retryTranscription(id: String) throws -> Bool {
    var changed = false
    try update(id) {
      guard $0.transcription == .failed || $0.transcription == .noSpeech else { return }
      $0.transcription = .pending
      $0.attempts = 0
      $0.lastAttemptAt = nil
      changed = true
    }
    return changed
  }

  /// 「删除录音…」 (the person's own deletion): the audio is removed and a note that it was
  /// deleted stays (`ReceivedRecording.deletedAt`). False when there is no such original.
  @discardableResult
  public func delete(id: String, at date: Date = Date()) throws -> Bool {
    guard WatchRecordingID.isValid(id) else { return false }
    return try locked {
      guard var received = read(id), received.deletedAt == nil else { return false }
      received.deletedAt = date
      received.text = nil
      try write(received)
      try? FileManager.default.removeItem(at: audioFile(id))
      return true
    }
  }

  // MARK: - Files

  private func audioFile(_ id: String) -> URL {
    root.appendingPathComponent("\(id).\(WatchRecording.fileExtension)")
  }

  private func descriptionFile(_ id: String) -> URL {
    root.appendingPathComponent("\(id).json")
  }

  private func read(_ id: String) -> ReceivedRecording? {
    guard let data = try? Data(contentsOf: descriptionFile(id)),
      let received = try? WatchFiles.decoder().decode(ReceivedRecording.self, from: data),
      received.id == id
    else { return nil }
    return received
  }

  private func write(_ received: ReceivedRecording) throws {
    let data = try WatchFiles.encoder().encode(received)
    try WatchFiles.atomicWrite(data, to: descriptionFile(received.id), staging: tmpDirectory)
  }

  @discardableResult
  private func update(_ id: String, _ change: (inout ReceivedRecording) -> Void) throws
    -> ReceivedRecording?
  {
    try locked {
      guard var received = read(id) else { return nil }
      change(&received)
      try write(received)
      return received
    }
  }

  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
}
