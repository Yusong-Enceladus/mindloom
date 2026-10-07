import BestASRDomain
import Darwin
import Foundation

/// How much of the disk the library takes, by kind and by month, and how
/// much the disk has left (Settings › 储存空间, ALIGNMENT 收3-5).
///
/// Sizes are the files' lengths, each file counted once: identical bytes
/// taken in twice are hard links to one file (`ContentAddressedAssets`), and
/// counting them twice would show space that is not used.
public struct LibraryStorageReport: Equatable, Sendable {
  public struct Month: Equatable, Sendable {
    /// First day of the month, in the calendar the report was made with.
    public let start: Date
    public let bytes: Int64
  }

  public var bytesByKind: [LibraryStorageKind: Int64] = [:]
  /// `history.sqlite` and its journal files.
  public var databaseBytes: Int64 = 0
  /// Installed recognition and text models, and personal models.
  public var modelBytes: Int64 = 0
  /// Everything else under the library folder.
  public var otherBytes: Int64 = 0
  /// What recordings and files added in each of the last months took, oldest
  /// first, ending with the current month.
  public var months: [Month] = []
  public var availableBytes: Int64 = 0
  public var capacityBytes: Int64 = 0

  public init() {}

  public var totalBytes: Int64 {
    bytesByKind.values.reduce(0, +) + databaseBytes + modelBytes + otherBytes
  }

  /// Free space is short (`isLow`).
  public var lowDisk: Bool { Self.isLow(available: availableBytes, capacity: capacityBytes) }

  public static let lowDiskFraction = 0.10
  /// A large disk with less than a tenth free still has room for weeks of
  /// recordings; below this much it is short whatever its size (review 10-6
  /// S11: 42 GB free of 494 GB raised the notice every day).
  public static let lowDiskFloorBytes: Int64 = 20_000_000_000

  /// Less than a tenth of the disk free, and less than `lowDiskFloorBytes`.
  public static func isLow(available: Int64, capacity: Int64) -> Bool {
    guard capacity > 0 else { return false }
    let tenth = Int64((Double(capacity) * lowDiskFraction).rounded(.down))
    return available < min(tenth, lowDiskFloorBytes)
  }

  /// When the low-disk notice was last shown, and how much was free then.
  /// The App keeps it across launches.
  public struct LowDiskNotice: Codable, Equatable, Sendable {
    public var shownAt: Date
    public var availableBytes: Int64

    public init(shownAt: Date, availableBytes: Int64) {
      self.shownAt = shownAt
      self.availableBytes = availableBytes
    }
  }

  /// Whether to show the low-disk notice now, and what to remember (STORE-006).
  /// Shown when free space becomes short; again only once it has recovered
  /// and become short again, or when what is free has halved since the last
  /// notice — and never twice within a day. A relaunch changes nothing.
  public static func lowDiskNotice(
    available: Int64, capacity: Int64, last: LowDiskNotice?, now: Date
  ) -> (show: Bool, remember: LowDiskNotice?) {
    guard isLow(available: available, capacity: capacity) else { return (false, nil) }
    let shown = LowDiskNotice(shownAt: now, availableBytes: available)
    guard let last else { return (true, shown) }
    let dayPassed = now.timeIntervalSince(last.shownAt) >= 24 * 60 * 60
    if dayPassed, available <= last.availableBytes / 2 { return (true, shown) }
    return (false, last)
  }

  /// The free and total space of the volume `url` is on.
  public static func volume(of url: URL) -> (available: Int64, capacity: Int64) {
    let values = try? url.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
    ])
    return (
      values?.volumeAvailableCapacityForImportantUsage ?? 0,
      Int64(values?.volumeTotalCapacity ?? 0)
    )
  }

  /// Walks the library folder once. `classes` says which session each
  /// `assets/sessions/<id>` folder belongs to; a folder with no class counts
  /// under other.
  public static func scan(
    dataRoot: URL,
    classes: [SessionStorageClass],
    monthCount: Int = 6,
    calendar: Calendar = .current,
    now: Date = Date()
  ) -> LibraryStorageReport {
    var report = LibraryStorageReport()
    var seen = Set<[UInt64]>()
    let sessions = dataRoot.appendingPathComponent("assets/sessions", isDirectory: true)
    let monthStarts = (0..<max(1, monthCount)).reversed().compactMap { back -> Date? in
      calendar.date(byAdding: .month, value: -back, to: calendar.startOfMonth(for: now))
    }
    var monthBytes = [Int64](repeating: 0, count: monthStarts.count)
    for item in classes {
      let folder = sessions.appendingPathComponent(
        item.sessionID.rawValue.uuidString.lowercased(), isDirectory: true)
      let bytes = uniqueBytes(under: folder, seen: &seen)
      guard bytes > 0 else { continue }
      report.bytesByKind[item.kind, default: 0] += bytes
      if let index = monthStarts.lastIndex(where: { $0 <= item.createdAt }) {
        monthBytes[index] += bytes
      }
    }
    report.months = zip(monthStarts, monthBytes).map { Month(start: $0, bytes: $1) }
    for name in ["history.sqlite", "history.sqlite-wal", "history.sqlite-shm"] {
      report.databaseBytes += uniqueBytes(
        under: dataRoot.appendingPathComponent(name), seen: &seen)
    }
    // Installed models, and the models trained on this Mac from the user's
    // own dictations (`personal-models`, review 10-6 S15).
    for name in ["models", "personal-models"] {
      report.modelBytes += uniqueBytes(
        under: dataRoot.appendingPathComponent(name, isDirectory: true), seen: &seen)
    }
    report.otherBytes = uniqueBytes(under: dataRoot, seen: &seen)
    let volume = volume(of: dataRoot)
    report.availableBytes = volume.available
    report.capacityBytes = volume.capacity
    return report
  }

  /// Bytes of the regular files at or under `url` not counted yet. Symbolic
  /// links are not followed (a library folder can link to a corpus kept
  /// elsewhere).
  static func uniqueBytes(under url: URL, seen: inout Set<[UInt64]>) -> Int64 {
    var entry = stat()
    guard lstat(url.path, &entry) == 0 else { return 0 }
    if entry.st_mode & S_IFMT == S_IFREG {
      return seen.insert([UInt64(entry.st_dev), UInt64(entry.st_ino)]).inserted
        ? Int64(entry.st_size) : 0
    }
    guard entry.st_mode & S_IFMT == S_IFDIR,
      let walker = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: nil, options: [])
    else { return 0 }
    var total: Int64 = 0
    for case let child as URL in walker {
      var info = stat()
      guard lstat(child.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
      if seen.insert([UInt64(info.st_dev), UInt64(info.st_ino)]).inserted {
        total += Int64(info.st_size)
      }
    }
    return total
  }
}

extension Calendar {
  fileprivate func startOfMonth(for date: Date) -> Date {
    self.date(from: dateComponents([.year, .month], from: date)) ?? date
  }
}
