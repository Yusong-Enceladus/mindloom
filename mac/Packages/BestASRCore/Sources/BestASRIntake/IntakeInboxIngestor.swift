import BestASRDomain
import CryptoKit
import Darwin
import Foundation
import MindloomLink
import UniformTypeIdentifiers

/// Takes an entry of the organizing device's inbox (sent from the phone) in
/// through the same path as a paste: `IntakeProcessor.prepare`, the store's
/// `createUserItem`, then the staged files' commit.
///
/// A legacy plain entry (the retired iOS Shortcut; the organizing device now
/// refuses plain adds, privacy review F9) that was still waiting becomes a
/// user item like a paste, whose source App is the entry's source ("iPhone")
/// and whose capture time is when the organizing device received it. It is
/// masked and redacted when sent like any item; nothing on this Mac makes new
/// plain entries.
///
/// A sealed entry (the iPhone app, PHONE-CONTRACT §5) is opened here with
/// this Mac's seal key; the organizing device never could. Its payload names
/// the source ("iPhone 键盘" / "iPhone 分享") and the time it was made on the
/// phone, and its kind picks the intake path: text as text, a link as its
/// title and URL (never fetched), an image through the image path, a file
/// through the file rules (audio and video are refused on the phone; an
/// archive or unreadable binary stays only on this Mac). An entry that does
/// not open, or opens to something that is not an item, can never be taken
/// in: it is `.discarded`, so the runtime acknowledges it and counts it.
///
/// Idempotent: the item's ID comes from the entry's ID, so an entry pulled
/// again (a crash between the commit and the acknowledgement) is found, not
/// taken in twice.
public struct IntakeInboxIngestor: RemoteOrganizerInboxIngesting {
  /// This Mac's phone seal key for the open library, or nil when there is
  /// none (never paired). Read per sealed entry; never logged.
  public typealias SealKeyProvider = @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey?

  public let processor: IntakeProcessor
  public let store: any UserItemCommitting
  public let sealKey: SealKeyProvider
  /// Awaited before each commit (the App's staging sweep).
  public let ready: @Sendable () async -> Void
  /// Called after an entry was committed now (for example to refresh lists).
  public let committed: @Sendable (SessionID) async -> Void

  public init(
    processor: IntakeProcessor, store: any UserItemCommitting,
    sealKey: @escaping SealKeyProvider = { nil },
    ready: @escaping @Sendable () async -> Void = {},
    committed: @escaping @Sendable (SessionID) async -> Void = { _ in }
  ) {
    self.processor = processor
    self.store = store
    self.sealKey = sealKey
    self.ready = ready
    self.committed = committed
  }

  public static let textExtractor = "inbox-text-v1"
  /// A shared link from the phone: its title, its note and its URL as text.
  public static let linkExtractor = "inbox-link-v1"

  public func ingest(_ entry: RemoteOrganizerInboxEntry) async throws
    -> RemoteOrganizerInboxOutcome
  {
    let id = entry.sessionID
    if try await store.existingSessionIDs(among: [id]).contains(id) {
      return .alreadyCommitted(id)
    }
    var capturedAt = entry.receivedAt
    var sourceName = entry.source
    let candidate: IntakeCandidate
    var scratch: URL?
    defer { scratch.map(Self.removeScratch) }
    switch entry.kind {
    case .text:
      guard let text = entry.text else { return .refused("没有文字") }
      candidate = .text(text, extractor: Self.textExtractor)
    case .image:
      guard let data = entry.imageData, let type = Self.imageType(data) else {
        return .refused("不是可读的图片")
      }
      candidate = .imageData(data, typeIdentifier: type)
    case .sealed:
      // A key store (Keychain) that cannot be read right now throws: the
      // entry stays on the organizing device and is tried again later.
      let key = try sealKey()
      let payload: InboxItemPayload
      switch Self.open(entry, with: key) {
      case .failure(let reason): return .discarded(reason)
      case .success(let opened): payload = opened
      }
      capturedAt = payload.createdDate ?? entry.receivedAt
      sourceName = payload.source.rawValue
      switch Self.candidate(for: payload) {
      case .none:
        return .discarded(.unusable)
      case .some(.ready(let ready)):
        candidate = ready
      case .some(.file(let bytes, let filename)):
        // A local write failure is not the entry's fault: it throws, and
        // the entry is tried again later.
        let staged = try Self.writeScratch(bytes, filename: filename)
        scratch = staged.deletingLastPathComponent()
        candidate = .file(staged)
      }
    }
    await ready()
    let outcome = processor.prepare(
      candidate, id: id, capturedAt: capturedAt,
      source: ItemSourceApplication(bundleID: nil, name: sourceName)
        ?? ItemSourceApplication(bundleID: nil, name: RemoteOrganizerInboxEntry.defaultSource),
      origin: .unknown)
    guard case .item(let draft) = outcome else {
      // Audio or video is never taken in from the phone (PHONE-CONTRACT §0.5).
      if case .media = outcome, entry.kind == .sealed { return .discarded(.unusable) }
      if case .rejected(let message) = outcome { return .refused(message) }
      return .refused("未收进来")
    }
    do {
      try await store.createUserItem(draft)
    } catch {
      processor.assetStore.discard(sessionID: draft.id)
      // A concurrent pull may have committed the same entry first.
      if try await store.existingSessionIDs(among: [id]).contains(id) {
        return .alreadyCommitted(id)
      }
      throw error
    }
    processor.assetStore.commit(sessionID: draft.id)
    await committed(id)
    return .committed(id)
  }

  /// Opens a sealed entry with this Mac's seal key and validates what is
  /// inside. The entry's `inbox_id` is the seal's associated data, so an
  /// entry moved to another ID does not open either.
  public static func open(
    _ entry: RemoteOrganizerInboxEntry, with key: Curve25519.KeyAgreement.PrivateKey?
  ) -> Result<InboxItemPayload, RemoteOrganizerInboxDiscard> {
    guard entry.kind == .sealed, let key, let blob = entry.sealedBlob,
      EntryID.isValid(entry.inboxID),
      let plaintext = try? MindloomSeal.open(blob, entryID: entry.inboxID, with: key)
    else { return .failure(.cannotOpen) }
    guard let payload = try? InboxItemPayload.decode(plaintext), payload.createdDate != nil
    else { return .failure(.unusable) }
    return .success(payload)
  }

  enum SealedCandidate: Equatable {
    case ready(IntakeCandidate)
    /// A document's bytes, handed to the file rules under its (safe) name.
    case file(Data, filename: String)
  }

  /// What intake gets for an opened payload; nil when it carries nothing.
  static func candidate(for payload: InboxItemPayload) -> SealedCandidate? {
    switch payload.kind {
    case .text:
      guard let text = payload.text else { return nil }
      return .ready(.text(text, extractor: textExtractor))
    case .link:
      guard let url = payload.url else { return nil }
      return .ready(
        .text(
          linkText(url: url, title: payload.title, note: payload.text),
          extractor: linkExtractor))
    case .image:
      guard let bytes = payload.bytes, let mime = payload.mime,
        let type = UTType(mimeType: mime), type.conforms(to: .image)
      else { return nil }
      return .ready(.imageData(bytes, typeIdentifier: type.identifier))
    case .file:
      guard let bytes = payload.bytes, let name = payload.filename else { return nil }
      return .file(bytes, filename: InboxItemPayload.sanitizedFilename(name))
    }
  }

  /// A link kept as text: its title and note, then the URL on its own line.
  static func linkText(url: String, title: String?, note: String?) -> String {
    var lines: [String] = []
    for part in [title, note] {
      guard let part = part?.trimmingCharacters(in: .whitespacesAndNewlines), !part.isEmpty,
        part != url, !lines.contains(part)
      else { continue }
      lines.append(part)
    }
    lines.append(url)
    return lines.joined(separator: "\n")
  }

  /// Writes a phone document into a private folder (0700, file 0600) in the
  /// user's temporary directory, so the ordinary file rules can classify and
  /// stage it. The folder is removed as soon as intake has copied it.
  static func writeScratch(_ bytes: Data, filename: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("bestasr-inbox-\(UUID().uuidString)", isDirectory: true)
    guard mkdir(folder.path, S_IRWXU) == 0 else { throw CocoaError(.fileWriteUnknown) }
    let url = folder.appendingPathComponent(filename, isDirectory: false)
    let descriptor = Darwin.open(
      url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      removeScratch(folder)
      throw CocoaError(.fileWriteUnknown)
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do { try handle.write(contentsOf: bytes) } catch {
      removeScratch(folder)
      throw error
    }
    return url
  }

  static func removeScratch(_ folder: URL) {
    try? FileManager.default.removeItem(at: folder)
  }

  /// The pasteboard type of image bytes, from their signature.
  static func imageType(_ data: Data) -> String? {
    let bytes = [UInt8](data.prefix(12))
    if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return UTType.png.identifier }
    if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return UTType.jpeg.identifier }
    if bytes.count >= 12, bytes[4...7] == [0x66, 0x74, 0x79, 0x70][...] {
      return UTType.heic.identifier
    }
    return nil
  }
}
