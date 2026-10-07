import Darwin
import Foundation
import GRDB

/// One finished dictation, as numbers only: when it ended, how long each
/// stage took, how much memory the App held. No text, audio, session
/// identifier, application or dictionary content is ever stored here
/// (ALIGNMENT 收1-2, 收1-5).
public struct DictationTiming: Equatable, Sendable {
  public enum Mode: Int, Sendable, CaseIterable {
    case dictate = 0
    case translate = 1
    case command = 2
  }

  public enum Outcome: Int, Sendable, CaseIterable {
    /// The words were seen to land in the field.
    case written = 0
    /// The words were kept on the clipboard or in history.
    case kept = 1
    /// Processing failed; the audio is kept for a retry.
    case failed = 2
    /// The recording held no speech.
    case noSpeech = 3
  }

  public var recordedAt: Date
  public var mode: Mode
  public var outcome: Outcome
  /// The recognizer had to be loaded for this dictation.
  public var recognizerWasCold: Bool
  public var audioMilliseconds: Int?
  /// Key down (the key event's own time) to recording started (the capture
  /// coordinator running): the definition ALIGNMENT 收1-19 is judged by.
  public var pressToRecordingMilliseconds: Int?
  /// Key up (the key event's own time) to the words written (or kept): what
  /// the user waits for.
  public var releaseToTextMilliseconds: Int?
  /// Key up to the audio sealed on disk.
  public var sealMilliseconds: Int?
  /// The final recognizer, including any wait for a decode already running.
  public var recognitionMilliseconds: Int?
  /// The cleanup model's share (bounded by its insertion budget).
  public var cleanupMilliseconds: Int?
  /// Translation or instruction (翻译、指令) before delivery.
  public var transformMilliseconds: Int?
  /// The paste and its confirmation.
  public var deliveryMilliseconds: Int?
  /// Everything else between key up and the words: hand-offs between
  /// threads, database commits, waiting for the live captions to finish.
  public var queueMilliseconds: Int?
  /// The App's physical memory footprint when the words were written.
  public var footprintMegabytes: Int?
  /// The highest footprint since the App started, at that moment.
  public var peakFootprintMegabytes: Int?

  public init(
    recordedAt: Date, mode: Mode = .dictate, outcome: Outcome,
    recognizerWasCold: Bool = false, audioMilliseconds: Int? = nil,
    pressToRecordingMilliseconds: Int? = nil, releaseToTextMilliseconds: Int? = nil,
    sealMilliseconds: Int? = nil, recognitionMilliseconds: Int? = nil,
    cleanupMilliseconds: Int? = nil, transformMilliseconds: Int? = nil,
    deliveryMilliseconds: Int? = nil, queueMilliseconds: Int? = nil,
    footprintMegabytes: Int? = nil, peakFootprintMegabytes: Int? = nil
  ) {
    self.recordedAt = recordedAt
    self.mode = mode
    self.outcome = outcome
    self.recognizerWasCold = recognizerWasCold
    self.audioMilliseconds = audioMilliseconds
    self.pressToRecordingMilliseconds = pressToRecordingMilliseconds
    self.releaseToTextMilliseconds = releaseToTextMilliseconds
    self.sealMilliseconds = sealMilliseconds
    self.recognitionMilliseconds = recognitionMilliseconds
    self.cleanupMilliseconds = cleanupMilliseconds
    self.transformMilliseconds = transformMilliseconds
    self.deliveryMilliseconds = deliveryMilliseconds
    self.queueMilliseconds = queueMilliseconds
    self.footprintMegabytes = footprintMegabytes
    self.peakFootprintMegabytes = peakFootprintMegabytes
  }

  /// The part of key-up-to-text that is none of the named stages.
  public static func queue(
    releaseToText: Int?, seal: Int?, recognition: Int?, cleanup: Int?, transform: Int?,
    delivery: Int?
  ) -> Int? {
    guard let releaseToText else { return nil }
    let named = [seal, recognition, cleanup, transform, delivery].compactMap { $0 }
      .reduce(0, +)
    return max(0, releaseToText - named)
  }
}

/// Count, median and 95th percentile of key-up-to-text over a period.
public struct DictationLatencySummary: Equatable, Sendable {
  public let count: Int
  public let p50Milliseconds: Int?
  public let p95Milliseconds: Int?

  public init(count: Int, p50Milliseconds: Int?, p95Milliseconds: Int?) {
    self.count = count
    self.p50Milliseconds = p50Milliseconds
    self.p95Milliseconds = p95Milliseconds
  }

  public init(_ values: [Int]) {
    self.init(
      count: values.count,
      p50Milliseconds: Self.percentile(values, 0.50),
      p95Milliseconds: Self.percentile(values, 0.95))
  }

  /// Nearest-rank percentile: the smallest value at or below which at least
  /// `fraction` of the values fall. Nil for no values.
  public static func percentile(_ values: [Int], _ fraction: Double) -> Int? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let rank = Int((fraction * Double(sorted.count)).rounded(.up))
    return sorted[min(sorted.count, max(1, rank)) - 1]
  }
}

/// The local table of dictation timings, kept 90 days, in its own small
/// database next to the library (`metrics/dictation-timings.sqlite`). It is
/// this Mac's measurement of itself: not part of the library's history,
/// never exported, migrated or sent anywhere.
public actor DictationMetricsStore {
  public static let retentionDays = 90
  public static let directoryName = "metrics"
  public static let fileName = "dictation-timings.sqlite"

  public static func databaseURL(dataRoot: URL) -> URL {
    dataRoot.appendingPathComponent(directoryName, isDirectory: true)
      .appendingPathComponent(fileName)
  }

  private let queue: DatabaseQueue

  public init(databaseURL: URL) throws {
    let directory = databaseURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    queue = try DatabaseQueue(path: databaseURL.path)
    try Self.migrator.migrate(queue)
  }

  private static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("m1-dictation-timings") { db in
      try db.execute(
        sql: """
          CREATE TABLE dictation_timings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            recorded_at REAL NOT NULL,
            mode INTEGER NOT NULL CHECK (mode BETWEEN 0 AND 2),
            outcome INTEGER NOT NULL CHECK (outcome BETWEEN 0 AND 3),
            recognizer_cold INTEGER NOT NULL CHECK (recognizer_cold IN (0, 1)),
            audio_ms INTEGER,
            press_to_recording_ms INTEGER,
            release_to_text_ms INTEGER,
            seal_ms INTEGER,
            recognition_ms INTEGER,
            cleanup_ms INTEGER,
            transform_ms INTEGER,
            delivery_ms INTEGER,
            queue_ms INTEGER,
            footprint_mb INTEGER,
            peak_footprint_mb INTEGER
          );
          CREATE INDEX dictation_timings_recorded_at ON dictation_timings(recorded_at);
          """)
    }
    return migrator
  }

  /// Adds one dictation and drops everything older than 90 days.
  public func record(_ timing: DictationTiming, now: Date = Date()) throws {
    let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO dictation_timings (
            recorded_at, mode, outcome, recognizer_cold, audio_ms, press_to_recording_ms,
            release_to_text_ms, seal_ms, recognition_ms, cleanup_ms, transform_ms,
            delivery_ms, queue_ms, footprint_mb, peak_footprint_mb
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          timing.recordedAt.timeIntervalSince1970, timing.mode.rawValue,
          timing.outcome.rawValue, timing.recognizerWasCold ? 1 : 0,
          timing.audioMilliseconds, timing.pressToRecordingMilliseconds,
          timing.releaseToTextMilliseconds, timing.sealMilliseconds,
          timing.recognitionMilliseconds, timing.cleanupMilliseconds,
          timing.transformMilliseconds, timing.deliveryMilliseconds,
          timing.queueMilliseconds, timing.footprintMegabytes,
          timing.peakFootprintMegabytes,
        ])
      try db.execute(
        sql: "DELETE FROM dictation_timings WHERE recorded_at < ?",
        arguments: [cutoff.timeIntervalSince1970])
    }
  }

  /// Every dictation recorded at or after `since`, oldest first.
  public func timings(since: Date) throws -> [DictationTiming] {
    try queue.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM dictation_timings WHERE recorded_at >= ? ORDER BY recorded_at, id
          """,
        arguments: [since.timeIntervalSince1970]
      ).map(Self.timing)
    }
  }

  /// Key up to text over the last `days` days, counting only dictations
  /// whose words were written or kept (a failure or a silent take has no
  /// text to wait for), of one `mode`: plain dictation by default, since a
  /// translation or an instruction also waits for a text model and would
  /// blur the dictation figure Settings shows (review 2026-10-06).
  public func releaseToTextSummary(
    lastDays days: Int, mode: DictationTiming.Mode = .dictate, now: Date = Date()
  ) throws -> DictationLatencySummary {
    let since = now.addingTimeInterval(-Double(days) * 86_400)
    let values = try queue.read { db in
      try Int.fetchAll(
        db,
        sql: """
          SELECT release_to_text_ms FROM dictation_timings
          WHERE recorded_at >= ? AND mode = ? AND release_to_text_ms IS NOT NULL
            AND outcome IN (0, 1)
          """,
        arguments: [since.timeIntervalSince1970, mode.rawValue])
    }
    return DictationLatencySummary(values)
  }

  private static func timing(_ row: Row) -> DictationTiming {
    DictationTiming(
      recordedAt: Date(timeIntervalSince1970: row["recorded_at"]),
      mode: DictationTiming.Mode(rawValue: row["mode"]) ?? .dictate,
      outcome: DictationTiming.Outcome(rawValue: row["outcome"]) ?? .failed,
      recognizerWasCold: (row["recognizer_cold"] as Int) == 1,
      audioMilliseconds: row["audio_ms"],
      pressToRecordingMilliseconds: row["press_to_recording_ms"],
      releaseToTextMilliseconds: row["release_to_text_ms"],
      sealMilliseconds: row["seal_ms"],
      recognitionMilliseconds: row["recognition_ms"],
      cleanupMilliseconds: row["cleanup_ms"],
      transformMilliseconds: row["transform_ms"],
      deliveryMilliseconds: row["delivery_ms"],
      queueMilliseconds: row["queue_ms"],
      footprintMegabytes: row["footprint_mb"],
      peakFootprintMegabytes: row["peak_footprint_mb"])
  }
}

/// This process's physical memory footprint, the number Activity Monitor
/// shows as "Memory" and the system uses for memory pressure.
public enum ProcessFootprint {
  /// Current and lifetime-peak footprint in bytes; nil if the kernel does
  /// not answer.
  public static func current() -> (bytes: UInt64, peakBytes: UInt64)? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    let peak = UInt64(max(0, Int64(info.ledger_phys_footprint_peak)))
    return (info.phys_footprint, max(info.phys_footprint, peak))
  }

  public static func megabytes(_ bytes: UInt64) -> Int { Int(bytes / 1_048_576) }
}
