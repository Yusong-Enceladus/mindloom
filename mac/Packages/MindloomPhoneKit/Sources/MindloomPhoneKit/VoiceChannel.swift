import Darwin
import Foundation

/// Why the app cannot take dictation right now. Content-free; the keyboard
/// shows it in plain words.
public enum VoiceProblem: String, Codable, Sendable, CaseIterable {
  case microphoneDenied = "mic-denied"
  case speechDenied = "speech-denied"
  /// No on-device Chinese recognizer on this phone.
  case recognizerUnavailable = "unavailable"
  /// The on-device Chinese model is still downloading.
  case preparingModel = "preparing"
  /// A phone call or another app took the microphone.
  case interrupted
}

/// `voice/state.json`, written only by the app (PHONE-CONTRACT §2):
/// `{session_alive_until, recording, seq}` plus the time of the app's last
/// heartbeat, so the keyboard can tell a live session from a stale file left
/// by an app the system has since ended.
public struct VoiceState: Codable, Equatable, Sendable {
  /// How often the app rewrites the state while a session is alive.
  public static let heartbeatInterval: TimeInterval = 4
  /// A session whose heartbeat is older than this is treated as gone.
  public static let heartbeatGrace: TimeInterval = 12

  /// Seconds since 1970; 0 when no session is alive.
  public var sessionAliveUntil: Double
  /// True only while the mic key is held (or toggled on): audio is being
  /// transcribed.
  public var recording: Bool
  /// The number of the current or last utterance. Never decreases.
  public var seq: Int
  public var heartbeatAt: Double
  /// Which on-device recognizer the session uses (diagnostics only).
  public var recognizer: String?
  public var problem: VoiceProblem?

  enum CodingKeys: String, CodingKey {
    case recording, seq, recognizer, problem
    case sessionAliveUntil = "session_alive_until"
    case heartbeatAt = "heartbeat_at"
  }

  public init(
    sessionAliveUntil: Double = 0, recording: Bool = false, seq: Int = 0, heartbeatAt: Double = 0,
    recognizer: String? = nil, problem: VoiceProblem? = nil
  ) {
    self.sessionAliveUntil = sessionAliveUntil
    self.recording = recording
    self.seq = seq
    self.heartbeatAt = heartbeatAt
    self.recognizer = recognizer
    self.problem = problem
  }

  /// A session is alive when it has not timed out and the app has written a
  /// heartbeat recently.
  public func isAlive(at now: Date) -> Bool {
    let time = now.timeIntervalSince1970
    return sessionAliveUntil > time && time - heartbeatAt < Self.heartbeatGrace
      && heartbeatAt <= time + Self.heartbeatGrace
  }
}

/// How an utterance ended.
public enum VoiceOutcome: String, Codable, Sendable {
  case text
  /// Nothing was said (or nothing was recognized).
  case empty
  /// The recognizer failed.
  case failed
}

/// `{seq, text}`: one partial or final transcript (PHONE-CONTRACT §2).
public struct VoiceText: Codable, Equatable, Sendable {
  public var seq: Int
  public var text: String
  public var outcome: VoiceOutcome?
  /// When it was written, seconds since 1970 (for scrubbing old finals).
  public var at: Double?

  public init(seq: Int, text: String, outcome: VoiceOutcome? = nil, at: Double? = nil) {
    self.seq = seq
    self.text = text
    self.outcome = outcome
    self.at = at
  }
}

/// `voice/final.json`: `{seq, text}` of the latest final, plus the few
/// before it. Darwin notifications coalesce, so two quick utterances can
/// arrive as one `.final`; the keyboard reads `recent` and inserts every
/// final newer than the last one it handled, in order.
public struct VoiceFinals: Codable, Equatable, Sendable {
  public static let recentLimit = 8

  public var seq: Int
  public var text: String
  public var outcome: VoiceOutcome?
  public var recent: [VoiceText]

  public init(
    seq: Int = 0, text: String = "", outcome: VoiceOutcome? = nil, recent: [VoiceText] = []
  ) {
    self.seq = seq
    self.text = text
    self.outcome = outcome
    self.recent = recent
  }

  /// All known finals, oldest first (at least the latest one).
  public var entries: [VoiceText] {
    var list = recent
    if seq > 0, !list.contains(where: { $0.seq == seq }) {
      list.append(VoiceText(seq: seq, text: text, outcome: outcome))
    }
    return list.sorted { $0.seq < $1.seq }
  }

  /// Adds a final as the latest one.
  public mutating func append(_ final: VoiceText) {
    seq = final.seq
    text = final.text
    outcome = final.outcome
    recent.append(final)
    recent.sort { $0.seq < $1.seq }
    if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
  }

  /// Blanks the text of every final written before `cutoff` (seconds since
  /// 1970), keeping their numbers. Returns whether anything changed.
  public mutating func scrub(before cutoff: Double) -> Bool {
    var changed = false
    recent.removeAll { entry in
      let old = (entry.at ?? 0) < cutoff
      if old { changed = true }
      return old
    }
    if !text.isEmpty, !recent.contains(where: { $0.seq == seq }) {
      text = ""
      changed = true
    }
    return changed
  }
}

/// The App Group files between the keyboard and the app (PHONE-CONTRACT §2):
///
/// ```
/// voice/state.json     VoiceState, written by the app
/// voice/partial.json   VoiceText of the utterance being spoken
/// voice/final.json     VoiceFinals
/// voice/level.bin      4 bytes: the current input level (0…1) for the waveform
/// ```
///
/// Transcripts sit here only long enough for the keyboard to insert them: the
/// app removes the partial when the final lands, blanks finals after a
/// minute, and clears both when the session ends. Audio is never written.
public final class VoiceChannel: @unchecked Sendable {
  public let directory: URL
  private let lock = NSLock()
  private var levelWriter: Int32 = -1
  private var levelReader: Int32 = -1

  public var stateFile: URL { directory.appendingPathComponent("state.json") }
  public var partialFile: URL { directory.appendingPathComponent("partial.json") }
  public var finalFile: URL { directory.appendingPathComponent("final.json") }
  public var levelFile: URL { directory.appendingPathComponent("level.bin") }

  public init(directory: URL, fileManager: FileManager = .default) throws {
    self.directory = directory
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    var excluded = URLResourceValues()
    excluded.isExcludedFromBackup = true
    var mutable = directory
    try? mutable.setResourceValues(excluded)
  }

  /// The channel in the App Group container.
  public static func appGroup(fileManager: FileManager = .default) throws -> VoiceChannel {
    guard let container = PhoneAppGroup.containerURL(fileManager: fileManager) else {
      throw PhoneAppGroup.AppGroupError.containerUnavailable
    }
    return try VoiceChannel(
      directory: PhoneAppGroup.voiceDirectory(in: container), fileManager: fileManager)
  }

  deinit {
    if levelWriter >= 0 { close(levelWriter) }
    if levelReader >= 0 { close(levelReader) }
  }

  // MARK: - JSON files

  public func readState() -> VoiceState? { read(VoiceState.self, from: stateFile) }
  public func writeState(_ state: VoiceState) throws { try write(state, to: stateFile) }

  public func readPartial() -> VoiceText? { read(VoiceText.self, from: partialFile) }
  public func writePartial(_ partial: VoiceText) throws { try write(partial, to: partialFile) }
  public func removePartial() { try? FileManager.default.removeItem(at: partialFile) }

  public func readFinals() -> VoiceFinals? { read(VoiceFinals.self, from: finalFile) }
  public func writeFinals(_ finals: VoiceFinals) throws { try write(finals, to: finalFile) }

  /// The highest utterance number found in any file (0 if none), so a
  /// restarted app keeps counting up and the keyboard never mistakes a new
  /// final for one it already inserted.
  public func highestSeq() -> Int {
    max(readState()?.seq ?? 0, readFinals()?.seq ?? 0, readPartial()?.seq ?? 0)
  }

  private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  private func write<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    var options: Data.WritingOptions = [.atomic]
    #if os(iOS)
      options.insert(.completeFileProtectionUntilFirstUserAuthentication)
    #endif
    try data.write(to: url, options: options)
  }

  // MARK: - Level

  /// Writes the input level (0…1) in place: 4 bytes, no rename, no sync.
  /// Called about 20 times a second while recording.
  public func writeLevel(_ level: Float) {
    var value = max(0, min(1, level)).bitPattern.littleEndian
    lock.lock()
    defer { lock.unlock() }
    if levelWriter < 0 {
      levelWriter = open(levelFile.path, O_WRONLY | O_CREAT, 0o600)
      guard levelWriter >= 0 else { return }
    }
    _ = withUnsafeBytes(of: &value) { pwrite(levelWriter, $0.baseAddress, 4, 0) }
  }

  /// The last written level, or 0.
  public func readLevel() -> Float {
    lock.lock()
    defer { lock.unlock() }
    if levelReader < 0 {
      levelReader = open(levelFile.path, O_RDONLY)
      guard levelReader >= 0 else { return 0 }
    }
    var raw: UInt32 = 0
    let count = withUnsafeMutableBytes(of: &raw) { pread(levelReader, $0.baseAddress, 4, 0) }
    guard count == 4 else { return 0 }
    let level = Float(bitPattern: UInt32(littleEndian: raw))
    return level.isFinite ? max(0, min(1, level)) : 0
  }
}
