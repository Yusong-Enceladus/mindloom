import Foundation
import MindloomLink

/// The pairing without its private key, in the App Group (`pairing.json`).
/// The app writes it when the phone is paired; the keyboard and the share
/// extension read it to seal to the Mac. The private key is in the app's
/// Keychain and never here.
public struct PairingRecordStore: Sendable {
  public let file: URL

  public init(file: URL) {
    self.file = file
  }

  public static func appGroup(fileManager: FileManager = .default) throws -> PairingRecordStore {
    guard let container = PhoneAppGroup.containerURL(fileManager: fileManager) else {
      throw PhoneAppGroup.AppGroupError.containerUnavailable
    }
    return PairingRecordStore(file: PhoneAppGroup.pairingRecordFile(in: container))
  }

  public func read() -> PairingRecord? {
    guard let data = try? Data(contentsOf: file),
      let record = try? JSONDecoder().decode(PairingRecord.self, from: data),
      record.macSealKey != nil
    else { return nil }
    return record
  }

  public func write(_ record: PairingRecord) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var options: Data.WritingOptions = [.atomic]
    #if os(iOS)
      options.insert(.completeFileProtectionUntilFirstUserAuthentication)
    #endif
    try encoder.encode(record).write(to: file, options: options)
  }

  public func remove() throws {
    do {
      try FileManager.default.removeItem(at: file)
    } catch CocoaError.fileNoSuchFile {
    }
  }
}

/// Seals what the phone collected to the paired Mac and adds it to the
/// outbox (PHONE-CONTRACT §3, §5). Used by the keyboard (each inserted
/// final), the share extension and the app. Plaintext never reaches the
/// disk: only the sealed wire and a short preview are stored.
public struct InboxCollector: Sendable {
  public enum CollectError: Error, Equatable, Sendable {
    case notPaired
  }

  public let outbox: OutboxStore
  public let pairing: PairingRecordStore
  public let signaling: (any PhoneSignaling)?

  public init(outbox: OutboxStore, pairing: PairingRecordStore, signaling: (any PhoneSignaling)?) {
    self.outbox = outbox
    self.pairing = pairing
    self.signaling = signaling
  }

  /// The collector in the App Group, posting `outbox.changed` over Darwin.
  public static func appGroup() throws -> InboxCollector {
    InboxCollector(
      outbox: try OutboxStore.appGroup(), pairing: try PairingRecordStore.appGroup(),
      signaling: DarwinSignaling.shared)
  }

  public var isPaired: Bool { pairing.read() != nil }

  /// Seals and enqueues one payload. Throws `CollectError.notPaired` when
  /// there is no Mac to seal to.
  @discardableResult
  public func collect(_ payload: InboxItemPayload, now: Date = Date()) throws -> OutboxEntry {
    guard let record = pairing.read(), let macKey = record.macSealKey else {
      throw CollectError.notPaired
    }
    let entry = try OutboxEntry.seal(payload, to: macKey, now: now)
    try outbox.add(entry)
    signaling?.post(PhoneSignal.outboxChanged)
    return entry
  }

  /// Seals several payloads and posts one `outbox.changed`.
  public func collect(_ payloads: [InboxItemPayload], now: Date = Date()) throws -> [OutboxEntry] {
    guard let record = pairing.read(), let macKey = record.macSealKey else {
      throw CollectError.notPaired
    }
    var entries: [OutboxEntry] = []
    for payload in payloads {
      let entry = try OutboxEntry.seal(payload, to: macKey, now: now)
      try outbox.add(entry)
      entries.append(entry)
    }
    if !entries.isEmpty { signaling?.post(PhoneSignal.outboxChanged) }
    return entries
  }

  /// The keyboard's collect step for one inserted final.
  public func collectKeyboardText(_ text: String, now: Date = Date()) -> CollectResult {
    do {
      try collect(InboxItemPayload.text(text, source: .keyboard, createdAt: now), now: now)
      return .collected
    } catch CollectError.notPaired {
      return .notPaired
    } catch {
      return .failed
    }
  }

  /// "已收进织机 · N": entries waiting plus those sent in the last 7 days.
  public func collectedCount(now: Date = Date()) -> Int? {
    guard isPaired, let counts = try? outbox.counts(now: now) else { return nil }
    return counts.queued + counts.sent
  }
}

/// What the keyboard last reported about itself (`keyboard.json`), so the
/// app's setup guide can tell whether 织机键盘 is added and has full access.
public struct KeyboardStatus: Codable, Equatable, Sendable {
  public var hasFullAccess: Bool
  /// Seconds since 1970.
  public var seenAt: Double

  enum CodingKeys: String, CodingKey {
    case hasFullAccess = "has_full_access"
    case seenAt = "seen_at"
  }

  public init(hasFullAccess: Bool, seenAt: Double) {
    self.hasFullAccess = hasFullAccess
    self.seenAt = seenAt
  }

  public static func read(from container: URL) -> KeyboardStatus? {
    guard let data = try? Data(contentsOf: PhoneAppGroup.keyboardStatusFile(in: container)) else {
      return nil
    }
    return try? JSONDecoder().decode(KeyboardStatus.self, from: data)
  }

  public func write(to container: URL) throws {
    let data = try JSONEncoder().encode(self)
    try data.write(to: PhoneAppGroup.keyboardStatusFile(in: container), options: .atomic)
  }
}
