import Darwin
import Foundation
import MindloomLink

/// One thing the user sent from this iPhone, as the app's Home shows it (PHONE-SPEC §8): only what
/// the user sent, never anything organized. The sealed copies that travel to the Mac are outbox
/// entries (`entryIDs`); this record is the phone's own view of the same item, kept on the phone for
/// seven days after it was delivered.
public struct PhoneItem: Codable, Equatable, Sendable, Identifiable {
  public enum Kind: String, Codable, Sendable, CaseIterable {
    case text
    case photos
    case link
    case file
  }

  /// One glyph and one word on Home: 键盘, 口述, 分享, Apple Watch. Never an app name.
  public enum Source: String, Codable, Sendable, CaseIterable {
    case keyboard
    case voice
    case share
    /// Recorded on Apple Watch, transcribed on this iPhone (WATCH-005).
    case watch

    /// The payload's `source`: always a name every Mac since v11 knows (a recording from Apple
    /// Watch goes as 「口述」 with its origin, `payloadOrigin`).
    public var payloadSource: InboxItemSource {
      switch self {
      case .keyboard: .keyboard
      case .voice, .watch: .voice
      case .share: .share
      }
    }

    /// The payload's `origin`, which a Mac from v12 on shows as the source.
    public var payloadOrigin: InboxItemOrigin? {
      self == .watch ? .appleWatch : nil
    }

    /// An outbox entry's source (entries without an item, from before items existed).
    public init(_ source: InboxItemSource) {
      switch source {
      case .keyboard: self = .keyboard
      case .voice: self = .voice
      default: self = .share
      }
    }
  }

  public struct Link: Codable, Equatable, Sendable {
    public var url: String
    /// The page title, only when the sharing app provided it (links are never fetched).
    public var title: String?

    public init(url: String, title: String? = nil) {
      self.url = url
      self.title = title
    }

    /// The host shown under the title, without `www.`.
    public var domain: String {
      guard let host = URL(string: url)?.host() else { return url }
      return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
  }

  public static let currentVersion = 1

  public let v: Int
  /// Stable id (an `EntryID`); the outbox entries are separate ids.
  public let id: String
  public let createdAt: Date
  public var kind: Kind
  public var source: Source
  /// Text items: the final text, including its 「。」.
  public var text: String?
  /// Photos: how many (previews are files next to the record).
  public var photoCount: Int
  public var link: Link?
  /// Files: the document's title (never a size or path).
  public var fileTitle: String?
  /// 「加一句」 from the share card.
  public var note: String?
  /// The outbox entries that carry this item to the Mac.
  public var entryIDs: [String]
  /// Kept unsealed on this iPhone because no Mac was paired yet; sealed and sent after pairing.
  public var awaitingPairing: Bool
  /// Only on a build without the App Group: the share extension keeps and sends this item itself
  /// (`ShareHandoff`); true while it is still on the phone, false once the Mac has it.
  public var sharedOnPhone: Bool?
  /// Items from Apple Watch: the id of the original recording this iPhone keeps (the item's own
  /// id is the same). Such an item is never pruned (WATCH-004).
  public var recordingID: String?
  /// Seconds of audio in that recording.
  public var recordingSeconds: Double?
  /// The recording arrived and its text is not there yet (「正在转写…」); it stays on this iPhone.
  public var awaitingTranscription: Bool?
  /// Items of a kept recording: when the Mac had every part. Kept on the item because the outbox
  /// forgets a sent part after `OutboxEntry.sentRetention` while the item stays.
  public var sentAt: Date?

  enum CodingKeys: String, CodingKey {
    case v, id, kind, source, text, link, note
    case sharedOnPhone = "shared_on_phone"
    case recordingID = "recording_id"
    case recordingSeconds = "recording_seconds"
    case awaitingTranscription = "awaiting_transcription"
    case sentAt = "sent_at"
    case createdAt = "created_at"
    case photoCount = "photo_count"
    case fileTitle = "file_title"
    case entryIDs = "entry_ids"
    case awaitingPairing = "awaiting_pairing"
  }

  public init(
    id: String = EntryID.make(), createdAt: Date, kind: Kind, source: Source, text: String? = nil,
    photoCount: Int = 0, link: Link? = nil, fileTitle: String? = nil, note: String? = nil,
    entryIDs: [String] = [], awaitingPairing: Bool = false
  ) {
    self.v = Self.currentVersion
    self.id = id
    self.createdAt = createdAt
    self.kind = kind
    self.source = source
    self.text = text
    self.photoCount = photoCount
    self.link = link
    self.fileTitle = fileTitle
    self.note = note
    self.entryIDs = entryIDs
    self.awaitingPairing = awaitingPairing
  }
}

/// Where an item is: still on this iPhone (the hollow circle) or with the Mac.
public enum PhoneItemDelivery: Equatable, Sendable {
  /// Held for its undo window, queued, or waiting for a Mac to be paired.
  case onPhone
  /// The Mac has every part; `at` is when the last part arrived (nil when unknown).
  case sent(at: Date?)
  /// A part can no longer be sent: its outbox file is gone or unreadable (moved aside), or it is
  /// sealed to a Mac this iPhone is no longer paired with. Shown as 「没能送出」, never as sent.
  case notSent

  public var isOnPhone: Bool { self == .onPhone }
}

/// The phone's list of what the user sent (`<container>/items/`), one JSON file per item plus
/// metadata-free photo previews and, before pairing, the unsealed payloads:
///
/// ```
/// items/
///   <id>.json                the PhoneItem
///   previews/<id>-<n>.jpg    photo previews (no location, no device), up to ~1280 px
///   unsealed/<id>.json       payloads kept until a Mac is paired, then sealed and removed
///   tmp/                     staging for atomic writes
/// ```
///
/// Files are written atomically and protected until first unlock; the directory is excluded from
/// backups. The app, the keyboard and the share extension all add items; only the app removes them.
public final class PhoneItemStore: @unchecked Sendable {
  /// Delivered items stay on the phone this long (photo previews included).
  public static let retention: TimeInterval = 7 * 24 * 60 * 60

  public let root: URL
  private let fileManager: FileManager
  private let lock = NSLock()

  private var previewsDirectory: URL { root.appendingPathComponent("previews", isDirectory: true) }
  private var unsealedDirectory: URL { root.appendingPathComponent("unsealed", isDirectory: true) }
  private var tmpDirectory: URL { root.appendingPathComponent("tmp", isDirectory: true) }

  public init(root: URL, fileManager: FileManager = .default) throws {
    self.root = root
    self.fileManager = fileManager
    for directory in [root, previewsDirectory, unsealedDirectory, tmpDirectory] {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    var excluded = URLResourceValues()
    excluded.isExcludedFromBackup = true
    var mutableRoot = root
    try mutableRoot.setResourceValues(excluded)
  }

  /// `<container>/items`.
  public static func directory(in container: URL) -> URL {
    container.appendingPathComponent("items", isDirectory: true)
  }

  public static func appGroup(fileManager: FileManager = .default) throws -> PhoneItemStore {
    guard let container = PhoneAppGroup.containerURL(fileManager: fileManager) else {
      throw PhoneAppGroup.AppGroupError.containerUnavailable
    }
    return try PhoneItemStore(root: directory(in: container), fileManager: fileManager)
  }

  // MARK: Items

  /// Every item, newest first.
  public func all() -> [PhoneItem] {
    locked {
      ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [])
        .filter { $0.hasSuffix(".json") }
        .compactMap { name -> PhoneItem? in
          let id = String(name.dropLast(5))
          guard EntryID.isValid(id) else { return nil }
          return readItem(id: id)
        }
        .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    }
  }

  public func item(id: String) -> PhoneItem? {
    guard EntryID.isValid(id) else { return nil }
    return locked { readItem(id: id) }
  }

  public func save(_ item: PhoneItem) throws {
    guard EntryID.isValid(item.id) else { throw PhoneItemError.invalidID }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let data = try encoder.encode(item)
    try locked { try atomicWrite(data, to: itemFile(item.id)) }
  }

  /// Removes the item, its previews and any unsealed payloads.
  public func remove(id: String) {
    guard EntryID.isValid(id) else { return }
    locked {
      try? fileManager.removeItem(at: itemFile(id))
      try? fileManager.removeItem(at: unsealedFile(id))
      for name in (try? fileManager.contentsOfDirectory(atPath: previewsDirectory.path)) ?? []
      where name.hasPrefix(id + "-") {
        try? fileManager.removeItem(at: previewsDirectory.appendingPathComponent(name))
      }
    }
  }

  // MARK: Previews

  public func previewURL(id: String, index: Int) -> URL {
    previewsDirectory.appendingPathComponent("\(id)-\(index).jpg", isDirectory: false)
  }

  /// Stores a preview the caller already re-encoded without metadata.
  public func writePreview(_ jpeg: Data, id: String, index: Int) throws {
    guard EntryID.isValid(id) else { throw PhoneItemError.invalidID }
    try locked { try atomicWrite(jpeg, to: previewURL(id: id, index: index)) }
  }

  // MARK: Unsealed payloads (before pairing)

  public func writeUnsealed(_ payloads: [InboxItemPayload], id: String) throws {
    guard EntryID.isValid(id) else { throw PhoneItemError.invalidID }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(payloads)
    try locked { try atomicWrite(data, to: unsealedFile(id)) }
  }

  public func unsealed(id: String) -> [InboxItemPayload]? {
    guard EntryID.isValid(id) else { return nil }
    return locked {
      guard let data = try? Data(contentsOf: unsealedFile(id)),
        let payloads = try? JSONDecoder().decode([InboxItemPayload].self, from: data)
      else { return nil }
      return payloads.filter { (try? $0.validate()) != nil }
    }
  }

  public func removeUnsealed(id: String) {
    guard EntryID.isValid(id) else { return }
    locked { try? fileManager.removeItem(at: unsealedFile(id)) }
  }

  // MARK: Files

  private func itemFile(_ id: String) -> URL {
    root.appendingPathComponent(id + ".json", isDirectory: false)
  }

  private func unsealedFile(_ id: String) -> URL {
    unsealedDirectory.appendingPathComponent(id + ".json", isDirectory: false)
  }

  private func readItem(id: String) -> PhoneItem? {
    guard let data = try? Data(contentsOf: itemFile(id)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    guard let item = try? decoder.decode(PhoneItem.self, from: data), item.id == id else {
      return nil
    }
    return item
  }

  private func atomicWrite(_ data: Data, to url: URL) throws {
    let staging = tmpDirectory.appendingPathComponent(UUID().uuidString + ".tmp")
    var options: Data.WritingOptions = [.withoutOverwriting]
    #if os(iOS)
      options.insert(.completeFileProtectionUntilFirstUserAuthentication)
    #endif
    try data.write(to: staging, options: options)
    guard rename(staging.path, url.path) == 0 else {
      try? fileManager.removeItem(at: staging)
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
}

public enum PhoneItemError: Error, Equatable, Sendable {
  case invalidID
  case nothingToSend
}

/// Adds what the user sent to the phone's list and to the outbox in one step (PHONE-SPEC §7.5):
/// sealed to the paired Mac and queued (or held for the undo window), or, with no Mac yet, kept
/// unsealed on this iPhone until pairing. Used by the app, the keyboard and the share extension.
public struct PhoneItemCollector: Sendable {
  public let items: PhoneItemStore
  public let outbox: OutboxStore
  public let pairing: PairingRecordStore
  public let signaling: (any PhoneSignaling)?

  public init(
    items: PhoneItemStore, outbox: OutboxStore, pairing: PairingRecordStore,
    signaling: (any PhoneSignaling)?
  ) {
    self.items = items
    self.outbox = outbox
    self.pairing = pairing
    self.signaling = signaling
  }

  /// The collector in the App Group, posting `outbox.changed` over Darwin.
  public static func appGroup() throws -> PhoneItemCollector {
    PhoneItemCollector(
      items: try PhoneItemStore.appGroup(), outbox: try OutboxStore.appGroup(),
      pairing: try PairingRecordStore.appGroup(), signaling: DarwinSignaling.shared)
  }

  /// Records `item` and its payloads. With a paired Mac each payload is sealed into an outbox
  /// entry, held until `heldUntil` when given (the undo window), otherwise queued at once. Without
  /// one the payloads are kept unsealed and the item waits for pairing.
  @discardableResult
  public func collect(
    _ item: PhoneItem, payloads: [InboxItemPayload], heldUntil: Date? = nil, now: Date = Date()
  ) throws -> PhoneItem {
    guard !payloads.isEmpty else { throw PhoneItemError.nothingToSend }
    var item = item
    if let record = pairing.read(), let macKey = record.macSealKey {
      var ids: [String] = []
      for payload in payloads {
        let entry = try OutboxEntry.seal(payload, to: macKey, now: now)
        if let heldUntil {
          try outbox.add(entry, heldUntil: heldUntil)
        } else {
          try outbox.add(entry)
        }
        ids.append(entry.entryID)
      }
      item.entryIDs = ids
      item.awaitingPairing = false
      try items.save(item)
      signaling?.post(PhoneSignal.outboxChanged)
    } else {
      try items.writeUnsealed(payloads, id: item.id)
      item.entryIDs = []
      item.awaitingPairing = true
      try items.save(item)
    }
    return item
  }

  /// Adds one more part to `item` (the caller keeps the returned item for the next part): a share
  /// of many photos is kept one photo at a time, so only one photo's bytes are in memory. The
  /// first part creates the item. Sealed and queued (or held) with a paired Mac, kept unsealed
  /// for pairing otherwise.
  @discardableResult
  public func append(
    _ payload: InboxItemPayload, to item: PhoneItem, heldUntil: Date? = nil, now: Date = Date()
  ) throws -> PhoneItem {
    var item = item
    if let record = pairing.read(), let macKey = record.macSealKey {
      let entry = try OutboxEntry.seal(payload, to: macKey, now: now)
      if let heldUntil {
        try outbox.add(entry, heldUntil: heldUntil)
      } else {
        try outbox.add(entry)
      }
      item.entryIDs.append(entry.entryID)
      item.awaitingPairing = false
      do {
        try items.save(item)
      } catch {
        try? outbox.withdraw(id: entry.entryID)
        throw error
      }
      signaling?.post(PhoneSignal.outboxChanged)
    } else {
      var payloads = items.unsealed(id: item.id) ?? []
      payloads.append(payload)
      try items.writeUnsealed(payloads, id: item.id)
      item.entryIDs = []
      item.awaitingPairing = true
      try items.save(item)
    }
    return item
  }

  /// 「撤销」 / 「撤回」: takes the item back if no part of it has reached the Mac. Returns false
  /// (and changes nothing) when the Mac already has a part.
  @discardableResult
  public func withdraw(id: String) throws -> Bool {
    // An item the share extension keeps itself (no App Group) is not the app's to take back, nor
    // is the item of a kept recording (Apple Watch): its recording stays and would bring it back.
    guard let item = items.item(id: id), item.sharedOnPhone == nil, item.recordingID == nil else {
      return false
    }
    for entryID in item.entryIDs {
      if try outbox.entry(id: entryID)?.state == .sent { return false }
    }
    // Each part answers for itself: a part that left (or is leaving) meanwhile keeps the item.
    var allGone = true
    for entryID in item.entryIDs where try !outbox.withdraw(id: entryID).isWithdrawn {
      allGone = false
    }
    guard allGone else { return false }
    items.remove(id: id)
    return true
  }

  /// Ends the undo window of an item now (its entries become ordinary queued entries).
  public func release(id: String) throws {
    guard let item = items.item(id: id) else { return }
    for entryID in item.entryIDs { try outbox.release(id: entryID) }
    signaling?.post(PhoneSignal.outboxChanged)
  }

  /// Keeps the item's entries back until `until` (「加一句」 on the share card). Returns false when
  /// a part has already left the hold (it is queued or sent).
  @discardableResult
  public func extendHold(id: String, until: Date) throws -> Bool {
    guard let item = items.item(id: id) else { return false }
    if item.awaitingPairing { return true }
    var all = true
    for entryID in item.entryIDs {
      if try !outbox.extendHold(id: entryID, until: until) { all = false }
    }
    return all
  }

  /// 「加一句」 → 「完成」: the note goes onto the item (Home shows it under the item) and travels
  /// to the Mac as one more text part of the same item. An empty note changes nothing.
  @discardableResult
  public func attachNote(id: String, note: String, payload: InboxItemPayload, now: Date = Date())
    throws -> PhoneItem?
  {
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, var item = items.item(id: id) else { return items.item(id: id) }
    item.note = trimmed
    if item.awaitingPairing {
      var payloads = items.unsealed(id: id) ?? []
      payloads.append(payload)
      try items.writeUnsealed(payloads, id: id)
    } else if let record = pairing.read(), let macKey = record.macSealKey {
      let entry = try OutboxEntry.seal(payload, to: macKey, now: now)
      try outbox.add(entry)
      item.entryIDs.append(entry.entryID)
    }
    try items.save(item)
    signaling?.post(PhoneSignal.outboxChanged)
    return item
  }

  /// After pairing: seals every item that was waiting for a Mac and queues it. Returns how many.
  @discardableResult
  public func sealAwaitingItems(now: Date = Date()) throws -> Int {
    guard let record = pairing.read(), let macKey = record.macSealKey else { return 0 }
    var sealed = 0
    for var item in items.all() where item.awaitingPairing {
      guard let payloads = items.unsealed(id: item.id), !payloads.isEmpty else { continue }
      var ids: [String] = []
      for payload in payloads {
        let entry = try OutboxEntry.seal(payload, to: macKey, now: now)
        try outbox.add(entry)
        ids.append(entry.entryID)
      }
      item.entryIDs = ids
      item.awaitingPairing = false
      try items.save(item)
      items.removeUnsealed(id: item.id)
      sealed += 1
    }
    if sealed > 0 { signaling?.post(PhoneSignal.outboxChanged) }
    return sealed
  }

  /// Where `item` is, from the outbox.
  public func delivery(of item: PhoneItem, now: Date = Date()) -> PhoneItemDelivery {
    if let shared = item.sharedOnPhone { return shared ? .onPhone : .sent(at: nil) }
    if item.awaitingPairing || item.awaitingTranscription == true { return .onPhone }
    if item.recordingID != nil, let sentAt = item.sentAt { return .sent(at: sentAt) }
    let currentKey = pairing.read()?.sealKeyID
    var last: Date?
    var onPhone = false
    var lost = false
    for entryID in item.entryIDs {
      guard let entry = try? outbox.entry(id: entryID) else {
        // Sent parts are kept 7 days and the item no longer than that, so a missing part during
        // the item's life was never confirmed sent. An item of a kept recording outlives its
        // parts: once 7 days have passed since it was made, a missing part went the way every
        // sent part goes (it cannot be withdrawn).
        if item.recordingID != nil,
          now.timeIntervalSince(item.createdAt) >= OutboxEntry.sentRetention
        {
          continue
        }
        lost = true
        continue
      }
      if entry.state != .sent {
        if let currentKey, entry.sealKeyID != currentKey { lost = true } else { onPhone = true }
        continue
      }
      if let sentAt = entry.sentAt { last = max(last ?? sentAt, sentAt) }
    }
    if onPhone { return .onPhone }
    if lost { return .notSent }
    return .sent(at: last)
  }

  /// Removes delivered items older than `PhoneItemStore.retention`. Items of a kept recording
  /// (Apple Watch) stay with their recording; their delivery is written onto them first
  /// (`noteKeptItemsSent`), before the outbox forgets the sent parts.
  @discardableResult
  public func prune(now: Date = Date()) -> Int {
    noteKeptItemsSent(now: now)
    var removed = 0
    for item in items.all()
    where now.timeIntervalSince(item.createdAt) >= PhoneItemStore.retention
      && item.recordingID == nil
      && !delivery(of: item, now: now).isOnPhone
    {
      items.remove(id: item.id)
      removed += 1
    }
    return removed
  }
}
