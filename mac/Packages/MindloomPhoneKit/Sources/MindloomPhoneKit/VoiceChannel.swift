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
  /// The microphone is turned off in iOS Settings (written even while no session is alive), so
  /// the keyboard reads 「麦克风没有打开 去设置」 instead of 「轻点开启语音」.
  public var microphoneDenied: Bool?

  enum CodingKeys: String, CodingKey {
    case recording, seq, recognizer, problem
    case microphoneDenied = "mic_denied"
    case sessionAliveUntil = "session_alive_until"
    case heartbeatAt = "heartbeat_at"
  }

  public init(
    sessionAliveUntil: Double = 0, recording: Bool = false, seq: Int = 0, heartbeatAt: Double = 0,
    recognizer: String? = nil, problem: VoiceProblem? = nil, microphoneDenied: Bool? = nil
  ) {
    self.microphoneDenied = microphoneDenied
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

/// What the keyboard did with finals (`voice/ack`), so the **app** keeps keyboard speech for the
/// Mac (PHONE-SPEC §7.1: 「键盘说的话也送到 Mac」 → an outbox item, source 键盘). The app has the
/// final text already; the keyboard only says which utterances it actually inserted, and which
/// of them the user took back with 「撤销」. Numbers only, never text.
public struct VoiceAck: Codable, Equatable, Sendable {
  public static let limit = 16
  /// Utterance numbers whose final was inserted into a field, oldest first.
  public var inserted: [Int]
  /// Utterance numbers taken back within the undo window.
  public var withdrawn: [Int]
  /// When `inserted.last` was inserted (seconds since 1970): the undo window runs from here.
  public var at: Double?

  public init(inserted: [Int] = [], withdrawn: [Int] = [], at: Double? = nil) {
    self.inserted = inserted
    self.withdrawn = withdrawn
    self.at = at
  }

  public mutating func insert(_ seq: Int, at time: Double) {
    if !inserted.contains(seq) { inserted.append(seq) }
    if inserted.count > Self.limit { inserted.removeFirst(inserted.count - Self.limit) }
    at = time
  }

  public mutating func withdraw(_ seq: Int) {
    if !withdrawn.contains(seq) { withdrawn.append(seq) }
    if withdrawn.count > Self.limit { withdrawn.removeFirst(withdrawn.count - Self.limit) }
  }
}

/// The records between the keyboard and the app (PHONE-CONTRACT §2), in the App Group's
/// `voice/` folder or, without an App Group, in the shared keychain group (`SharedRecords`):
///
/// ```
/// state      VoiceState, written by the app
/// partial    VoiceText of the utterance being spoken
/// final      VoiceFinals
/// ack        VoiceAck, written by the keyboard
/// keyboard   KeyboardStatus, written by the keyboard
/// level      the current input level (0…1) for the listening animation (`LevelLine`)
/// ```
///
/// Transcripts sit here only long enough for the keyboard to insert them: the app removes the
/// partial when the final lands, blanks finals after a minute, and clears both when the session
/// ends. Audio is never written.
public final class VoiceChannel: @unchecked Sendable {
  public let records: any SharedRecords
  public let level: any LevelLine

  public init(records: any SharedRecords, level: any LevelLine) {
    self.records = records
    self.level = level
  }

  /// Files in `directory` (the App Group's `voice/`, or a test folder).
  public convenience init(directory: URL, fileManager: FileManager = .default) throws {
    let files = try FileRecords(directory: directory, fileManager: fileManager)
    self.init(records: files, level: FileLevelLine(file: directory.appendingPathComponent("level.bin")))
  }

  /// The channel in the App Group container.
  public static func appGroup(fileManager: FileManager = .default) throws -> VoiceChannel {
    guard let container = PhoneAppGroup.containerURL(fileManager: fileManager) else {
      throw PhoneAppGroup.AppGroupError.containerUnavailable
    }
    return try VoiceChannel(
      directory: PhoneAppGroup.voiceDirectory(in: container), fileManager: fileManager)
  }

  /// True when the records are App Group files (false: the keychain fallback).
  public var isAppGroup: Bool { records.isAppGroup }

  // MARK: - Records

  public func readState() -> VoiceState? { records.readJSON(VoiceState.self, "state") }
  public func writeState(_ state: VoiceState) throws { try records.writeJSON(state, as: "state") }

  public func readPartial() -> VoiceText? { records.readJSON(VoiceText.self, "partial") }
  public func writePartial(_ partial: VoiceText) throws {
    try records.writeJSON(partial, as: "partial")
  }
  public func removePartial() { records.remove("partial") }

  public func readFinals() -> VoiceFinals? { records.readJSON(VoiceFinals.self, "final") }
  public func writeFinals(_ finals: VoiceFinals) throws { try records.writeJSON(finals, as: "final") }

  public func readAck() -> VoiceAck? { records.readJSON(VoiceAck.self, "ack") }
  public func writeAck(_ ack: VoiceAck) throws { try records.writeJSON(ack, as: "ack") }

  public func readKeyboardStatus() -> KeyboardStatus? {
    records.readJSON(KeyboardStatus.self, "keyboard")
  }
  public func writeKeyboardStatus(_ status: KeyboardStatus) throws {
    try records.writeJSON(status, as: "keyboard")
  }

  /// DEBUG builds only: the keyboard state the screenshot harness wants frozen.
  /// The screenshot harness's frozen keyboard state (`<state>|<unix seconds>`). A record older
  /// than `debugRecordLifetime`, or one without its time, is ignored: a forgotten screenshot state
  /// must never freeze the real keyboard.
  public func readDebugKeyboardScreen(now: Date = Date()) -> String? {
    guard let raw = records.read("debug-keyboard").flatMap({ String(data: $0, encoding: .utf8) })
    else { return nil }
    let parts = raw.split(separator: "|")
    guard parts.count == 2, let written = Double(parts[1]),
      now.timeIntervalSince1970 - written < Self.debugRecordLifetime
    else { return nil }
    return String(parts[0])
  }

  public func writeDebugKeyboardScreen(_ screen: String?, now: Date = Date()) {
    if let screen {
      try? records.write(
        Data("\(screen)|\(Int(now.timeIntervalSince1970))".utf8), as: "debug-keyboard")
    } else {
      records.remove("debug-keyboard")
    }
  }

  public static let debugRecordLifetime: TimeInterval = 10 * 60

  /// The highest utterance number found in any record (0 if none), so a restarted app keeps
  /// counting up and the keyboard never mistakes a new final for one it already inserted.
  public func highestSeq() -> Int {
    max(readState()?.seq ?? 0, readFinals()?.seq ?? 0, readPartial()?.seq ?? 0)
  }

  // MARK: - Level

  /// Writes the input level (0…1). Called about 40 times a second while listening.
  public func writeLevel(_ value: Float) { level.write(value) }

  /// The last written level, or 0.
  public func readLevel() -> Float { level.read() }
}
