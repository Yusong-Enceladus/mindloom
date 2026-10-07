import Foundation

/// What a page visit asks of the App (v12, ALIGNMENT 理1-4): read the
/// library again, at most once a minute, and nothing more. The whole-library
/// local organizer (two cores, about 4 GB) used to run on every such visit,
/// also with the DGX Spark connected; it now runs only on its own explicit
/// command.
public struct MemoryPageRefresh: Sendable {
  public enum Work: Equatable, Sendable {
    /// Read events, records and people again.
    case reload
  }

  /// At most one reload per this many seconds.
  public static let interval: TimeInterval = 60
  private var last: Date?

  public init() {}

  /// A page appeared at `now`: the work to do, or nil when the last reload
  /// is recent enough.
  public mutating func visit(at now: Date = Date()) -> Work? {
    if let last, now.timeIntervalSince(last) < Self.interval, now >= last { return nil }
    last = now
    return .reload
  }
}
