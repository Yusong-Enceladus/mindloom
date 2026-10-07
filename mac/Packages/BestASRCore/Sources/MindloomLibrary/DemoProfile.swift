import Foundation

/// Who the demo library belongs to (ALIGNMENT 根-10): in demo mode these
/// come from the demo root's `demo-profile.json`, never from the App's own
/// preferences (`identity.local-self-person-id`, `preferences.owner-names`,
/// `bestASR.local-origin-device-id`, `preferences.spark-organizer-*`). The
/// organizing link's key is the root's `organizer-link.key`.
public struct DemoProfile: Codable, Equatable, Sendable {
  /// The scenario owner's names (pages say 我 for them).
  public var ownerNames: [String]
  /// The demo library's own 「我」.
  public var selfPersonID: UUID?
  /// The demo library's own device identity.
  public var originDeviceID: UUID?
  /// The organizing device the demo library talks to, if any.
  public var organizer: Organizer?

  public struct Organizer: Codable, Equatable, Sendable {
    /// An ssh host name or alias.
    public var host: String
    public var socketPath: String?
    public var tokenPath: String?
    public var inboxCommand: String?

    public init(
      host: String, socketPath: String? = nil, tokenPath: String? = nil,
      inboxCommand: String? = nil
    ) {
      self.host = host
      self.socketPath = socketPath
      self.tokenPath = tokenPath
      self.inboxCommand = inboxCommand
    }

    enum CodingKeys: String, CodingKey {
      case host
      case socketPath = "socket_path"
      case tokenPath = "token_path"
      case inboxCommand = "inbox_command"
    }
  }

  public init(
    ownerNames: [String] = [], selfPersonID: UUID? = nil, originDeviceID: UUID? = nil,
    organizer: Organizer? = nil
  ) {
    self.ownerNames = ownerNames
    self.selfPersonID = selfPersonID
    self.originDeviceID = originDeviceID
    self.organizer = organizer
  }

  enum CodingKeys: String, CodingKey {
    case ownerNames = "owner_names"
    case selfPersonID = "self_person_id"
    case originDeviceID = "origin_device_id"
    case organizer
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    ownerNames = (try? container.decodeIfPresent([String].self, forKey: .ownerNames)) ?? []
    selfPersonID = try? container.decodeIfPresent(UUID.self, forKey: .selfPersonID)
    originDeviceID = try? container.decodeIfPresent(UUID.self, forKey: .originDeviceID)
    organizer = try? container.decodeIfPresent(Organizer.self, forKey: .organizer)
    if let host = organizer?.host.trimmingCharacters(in: .whitespacesAndNewlines), host.isEmpty {
      organizer = nil
    }
  }
}

public struct DemoProfileFile: Sendable {
  public static let name = "demo-profile.json"
  public let url: URL

  public init(dataRoot: URL) {
    url = dataRoot.appendingPathComponent(Self.name)
  }

  /// The stored profile, or nil when there is none (or it is unreadable).
  public func load() -> DemoProfile? {
    LibraryFiles.read(url).flatMap { try? JSONDecoder().decode(DemoProfile.self, from: $0) }
  }

  public func save(_ profile: DemoProfile) throws {
    try LibraryFiles.write(profile, to: url)
  }

  /// The profile with its own 「我」 and device identity, made and saved on
  /// first use, so a demo root never borrows the owner's. `existing` fills
  /// in what the root does not say (Mindloom Preview's older identity).
  public func loadEnsuringIdentity(
    existingSelf: UUID? = nil, existingDevice: UUID? = nil
  ) -> DemoProfile {
    var profile = load() ?? DemoProfile()
    var changed = false
    if profile.selfPersonID == nil {
      profile.selfPersonID = existingSelf ?? UUID()
      changed = true
    }
    if profile.originDeviceID == nil {
      profile.originDeviceID = existingDevice ?? UUID()
      changed = true
    }
    if changed { try? save(profile) }
    return profile
  }
}

/// Dictations made in demo mode are typed into other Apps but not kept in
/// the demo library (ALIGNMENT 根-10). Each one is written here before its
/// session exists and removed once the session is gone, so one left behind
/// by a crash is removed at the next launch. Stored as
/// `demo-dictations.json` in the demo root.
public struct DemoDictationLedger: Sendable {
  public static let name = "demo-dictations.json"
  public let url: URL

  public init(dataRoot: URL) {
    url = dataRoot.appendingPathComponent(Self.name)
  }

  private struct Contents: Codable {
    var sessions: [UUID]
  }

  public func pending() -> [UUID] {
    LibraryFiles.read(url).flatMap { try? JSONDecoder().decode(Contents.self, from: $0) }?
      .sessions ?? []
  }

  /// Records a dictation that is about to start. Throws when it cannot be
  /// recorded (the dictation must not start then).
  public func add(_ id: UUID) throws {
    var sessions = pending()
    guard !sessions.contains(id) else { return }
    sessions.append(id)
    try LibraryFiles.write(Contents(sessions: sessions), to: url)
  }

  public func remove(_ id: UUID) {
    let sessions = pending()
    guard sessions.contains(id) else { return }
    try? LibraryFiles.write(Contents(sessions: sessions.filter { $0 != id }), to: url)
  }
}
