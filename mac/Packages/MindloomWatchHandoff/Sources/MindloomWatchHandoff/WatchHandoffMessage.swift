import Foundation

/// The small messages between the watch and the iPhone (WatchConnectivity user info, messages and
/// the application context). Property-list values only; anything else is ignored.
public enum WatchHandoffMessage: Equatable, Sendable {
  /// iPhone → watch: the iPhone has stored these originals (size and SHA-256 checked). The watch
  /// removes its copies.
  case stored([String])
  /// Watch → iPhone: these recordings are still on the watch. The iPhone answers with `reply`.
  /// Sent while the watch app runs (it also wakes Mindloom on the iPhone, which then takes what
  /// WatchConnectivity holds for it).
  case holding([String])
  /// iPhone → watch, the answer to `holding`: the ones it has stored, and the ones it does not
  /// have although WatchConnectivity had nothing more for it when it answered (`missing` is empty
  /// when it could not tell). The watch sends a missing one again; the others it leaves alone.
  case reply(stored: [String], missing: [String])

  /// At most this many ids in one message.
  public static let maximumIDs = 500

  public var dictionary: [String: Any] {
    var dictionary: [String: Any] = [WatchRecording.marker: WatchRecording.currentVersion]
    switch self {
    case .stored(let ids):
      dictionary["stored"] = Array(ids.prefix(Self.maximumIDs))
    case .holding(let ids):
      dictionary["holding"] = Array(ids.prefix(Self.maximumIDs))
    case .reply(let stored, let missing):
      dictionary["stored"] = Array(stored.prefix(Self.maximumIDs))
      dictionary["missing"] = Array(missing.prefix(Self.maximumIDs))
    }
    return dictionary
  }

  /// Nil for anything that is not one of ours. Invalid ids are dropped.
  public init?(dictionary: [String: Any]?) {
    guard let dictionary,
      (dictionary[WatchRecording.marker] as? NSNumber)?.intValue == WatchRecording.currentVersion
    else { return nil }
    func ids(_ key: String) -> [String]? {
      guard let list = dictionary[key] as? [Any] else { return nil }
      var seen = Set<String>()
      return list.prefix(Self.maximumIDs).compactMap { $0 as? String }
        .filter { WatchRecordingID.isValid($0) && seen.insert($0).inserted }
    }
    if let stored = ids("stored"), let missing = ids("missing") {
      self = .reply(stored: stored, missing: missing.filter { !stored.contains($0) })
    } else if let stored = ids("stored") {
      self = .stored(stored)
    } else if let holding = ids("holding") {
      self = .holding(holding)
    } else {
      return nil
    }
  }
}
