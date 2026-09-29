import CryptoKit
import Foundation

/// One thing the user sent to their own organizing device from another
/// device (the phone entry: an iOS Shortcut running `zhiji-inbox add` over
/// SSH), waiting there until this Mac takes it in. It stays on the organizing
/// device only until the Mac acknowledges it after its local commit.
///
/// Wire shape (`GET /v1/inbox?since=<cursor>` returns
/// `{"cursor": Int, "items": [entry]}`):
/// `{"inbox_id", "source", "kind": "text"|"image", "text"?, "image_b64"?,
/// "received_at"}`. `id` is read as `inbox_id` and `entries` as `items`.
public struct RemoteOrganizerInboxEntry: Equatable, Sendable {
  public enum Kind: String, Sendable {
    case text
    case image
  }

  /// The organizing device's ID for the entry (acknowledged by it).
  public let inboxID: String
  /// Where it came from as the user named it, e.g. "iPhone".
  public let source: String
  public let kind: Kind
  public let text: String?
  /// An image entry's bytes (PNG/JPEG/HEIC), base64 on the wire.
  public let imageData: Data?
  /// When the organizing device received it; the item's capture time.
  public let receivedAt: Date

  public init(
    inboxID: String, source: String, kind: Kind, text: String?, imageData: Data?,
    receivedAt: Date
  ) {
    self.inboxID = inboxID
    self.source = source
    self.kind = kind
    self.text = text
    self.imageData = imageData
    self.receivedAt = receivedAt
  }

  /// Longest inbox ID accepted; one longer is ignored.
  public static let maximumIDScalars = 128
  /// The name used when an entry names no source.
  public static let defaultSource = "iPhone"

  /// The one local item an entry becomes, whatever number of times it is
  /// pulled: a name-based UUID of the entry ID (SHA-256, RFC 4122 version 5
  /// layout), so a pull repeated after a crash between the local commit and
  /// the acknowledgement finds the item it already made.
  public var sessionID: SessionID {
    var bytes = Array(SHA256.hash(data: Data("bestasr.inbox:\(inboxID)".utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    let uuid = UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
    return SessionID(uuid)
  }
}

/// A page of the inbox as the organizing device returns it. Malformed
/// entries are dropped rather than failing the page.
public struct RemoteOrganizerInboxPage: Decodable, Equatable, Sendable {
  public let cursor: Int64?
  public let entries: [RemoteOrganizerInboxEntry]

  public init(cursor: Int64?, entries: [RemoteOrganizerInboxEntry]) {
    self.cursor = cursor
    self.entries = entries
  }

  enum CodingKeys: String, CodingKey {
    case cursor, items, entries
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    cursor = (try? container.decodeIfPresent(Int64.self, forKey: .cursor)) ?? nil
    let raw =
      ((try? container.decodeIfPresent([Lenient].self, forKey: .items)) ?? nil)
      ?? ((try? container.decodeIfPresent([Lenient].self, forKey: .entries)) ?? nil) ?? []
    entries = raw.compactMap(\.entry)
  }

  private struct Lenient: Decodable {
    let entry: RemoteOrganizerInboxEntry?

    enum Keys: String, CodingKey {
      case inboxID = "inbox_id"
      case id, source, kind, text
      case imageBase64 = "image_b64"
      case receivedAt = "received_at"
    }

    init(from decoder: Decoder) throws {
      guard let container = try? decoder.container(keyedBy: Keys.self) else {
        entry = nil
        return
      }
      func string(_ key: Keys) -> String? {
        if let value = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil {
          return value
        }
        // An integer ID is read as its decimal text.
        return ((try? container.decodeIfPresent(Int64.self, forKey: key)) ?? nil).map(String.init)
      }
      let id = (string(.inboxID) ?? string(.id))?.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let id, !id.isEmpty,
        id.unicodeScalars.count <= RemoteOrganizerInboxEntry.maximumIDScalars,
        let kind = string(.kind).flatMap(RemoteOrganizerInboxEntry.Kind.init(rawValue:)),
        let received = string(.receivedAt).flatMap(Self.date)
      else {
        entry = nil
        return
      }
      let source = string(.source)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let text = string(.text)
      let image = string(.imageBase64).flatMap {
        Data(base64Encoded: $0, options: .ignoreUnknownCharacters)
      }
      switch kind {
      case .text:
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          entry = nil
          return
        }
      case .image:
        guard let image, !image.isEmpty else {
          entry = nil
          return
        }
      }
      entry = RemoteOrganizerInboxEntry(
        inboxID: id,
        source: source.isEmpty
          ? RemoteOrganizerInboxEntry.defaultSource : String(source.prefix(64)),
        kind: kind, text: text, imageData: kind == .image ? image : nil, receivedAt: received)
    }

    static func date(_ value: String) -> Date? {
      let fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = fractional.date(from: value) { return date }
      let plain = ISO8601DateFormatter()
      plain.formatOptions = [.withInternetDateTime]
      if let date = plain.date(from: value) { return date }
      // Python writes microseconds; drop the fraction rather than fail.
      return plain.date(
        from: value.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
    }
  }
}

/// What taking in one inbox entry came to.
public enum RemoteOrganizerInboxOutcome: Equatable, Sendable {
  /// Committed locally now: acknowledge it.
  case committed(SessionID)
  /// Committed by an earlier pull: acknowledge it.
  case alreadyCommitted(SessionID)
  /// Not taken (no usable text or image); it stays on the organizing device
  /// and is skipped until the next launch. The message is content-free.
  case refused(String)

  public var isCommitted: Bool {
    switch self {
    case .committed, .alreadyCommitted: true
    case .refused: false
    }
  }
}

/// Takes one inbox entry in through the Mac's normal intake path as a user
/// item. Idempotent per entry (`RemoteOrganizerInboxEntry.sessionID`).
public protocol RemoteOrganizerInboxIngesting: Sendable {
  func ingest(_ entry: RemoteOrganizerInboxEntry) async throws -> RemoteOrganizerInboxOutcome
}

/// The two store calls intake needs to commit a user item; the durable store
/// conforms. Lets intake code commit without depending on the store type.
public protocol UserItemCommitting: Sendable {
  func createUserItem(_ draft: UserItemDraft) async throws
  func existingSessionIDs(among candidates: [SessionID]) async throws -> Set<SessionID>
}
