import Foundation
import MindloomLink

/// The share extension on a build without the App Group (a free Personal Team; IOS-CODE-MAP §3b):
/// it cannot reach the app's outbox, so it keeps and sends what was shared itself, from its own
/// container. Two small records in the shared keychain group connect it to the app:
///
/// - app → extension: the pairing (no secrets) and the phone's SSH key, so the extension can seal
///   to the Mac and deliver;
/// - extension → app: the items it took (`PhoneItem`, no previews) and whether each is still on the
///   phone, so Home lists them with the right hollow circle.
///
/// With the App Group none of this is used: the extension writes the shared outbox and the app
/// sends.
public struct ShareHandoff: Sendable {
  public struct Entry: Codable, Equatable, Sendable {
    public var item: PhoneItem
    public var onPhone: Bool

    public init(item: PhoneItem, onPhone: Bool) {
      self.item = item
      self.onPhone = onPhone
    }
  }

  /// The newest this many items are handed over.
  public static let limit = 40

  public let records: any SharedRecords
  /// Where the phone's key goes: a group only the app and the share extension have (the keyboard,
  /// which runs with Full Access, must not read it). The shared records when no such group.
  public let keyRecords: any SharedRecords

  public init(records: any SharedRecords, keyRecords: (any SharedRecords)? = nil) {
    self.records = records
    self.keyRecords = keyRecords ?? records
  }

  /// The handoff in the shared keychain group, or nil when the build has none.
  public static func keychain() -> ShareHandoff? {
    guard let group = PhoneLink.keychainGroup() else { return nil }
    let records = KeychainRecords(accessGroup: group, service: PhoneNames.shareService)
    guard records.isUsable() else { return nil }
    var keyRecords: KeychainRecords?
    if let keyGroup = PhoneLink.keychainGroup(infoKey: PhoneLink.shareKeyGroupInfoKey) {
      let candidate = KeychainRecords(accessGroup: keyGroup, service: PhoneNames.shareService)
      if candidate.isUsable() { keyRecords = candidate }
    }
    return ShareHandoff(records: records, keyRecords: keyRecords)
  }

  // MARK: App → extension

  public func writePairing(_ record: PairingRecord, phoneKey: Data) throws {
    try keyRecords.writeJSON(record, as: "pairing")
    try keyRecords.write(phoneKey, as: "phone-key")
    if keyRecords !== records {
      // A copy left in the shared group by an earlier build goes.
      records.remove("pairing")
      records.remove("phone-key")
    }
  }

  public func readPairing() -> (record: PairingRecord, phoneKey: Data)? {
    guard let record = keyRecords.readJSON(PairingRecord.self, "pairing"),
      record.macSealKey != nil,
      let key = keyRecords.read("phone-key"), !key.isEmpty
    else { return nil }
    return (record, key)
  }

  public func clearPairing() {
    keyRecords.remove("pairing")
    keyRecords.remove("phone-key")
    records.remove("pairing")
    records.remove("phone-key")
  }

  // MARK: Extension → app

  /// The extension's item list is still in the keychain (a build without the App Group wrote it,
  /// and the extension has not yet moved its own storage into the group).
  public var hasItems: Bool { records.read("items") != nil }

  public func readItems() -> [Entry] {
    guard let data = records.read("items") else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return (try? decoder.decode([Entry].self, from: data)) ?? []
  }

  /// Replaces the handed-over list with `entries` (newest first, at most `limit`).
  public func writeItems(_ entries: [Entry]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let newest = entries.sorted { ($0.item.createdAt, $0.item.id) > ($1.item.createdAt, $1.item.id) }
      .prefix(Self.limit)
    try records.write(try encoder.encode(Array(newest)), as: "items")
  }

  /// The app's side: brings the handed-over items into the app's own list (added, or their
  /// delivery updated). Items the app removed (「撤回」) stay removed only if the extension no
  /// longer lists them. Returns how many changed.
  @discardableResult
  public func importItems(into store: PhoneItemStore) -> Int {
    var changed = 0
    for entry in readItems() {
      var item = entry.item
      item.sharedOnPhone = entry.onPhone
      item.entryIDs = []
      item.awaitingPairing = false
      if let existing = store.item(id: item.id) {
        // Only a mirror is updated: the extension's real item (moved into the App Group, with its
        // outbox entries) is never overwritten by its summary.
        guard existing.sharedOnPhone != nil else { continue }
        guard existing.sharedOnPhone != entry.onPhone || existing.note != item.note else { continue }
      }
      if (try? store.save(item)) != nil { changed += 1 }
    }
    return changed
  }
}
