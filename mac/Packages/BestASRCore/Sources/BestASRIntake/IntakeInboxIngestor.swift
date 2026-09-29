import BestASRDomain
import Foundation
import UniformTypeIdentifiers

/// Takes an entry of the organizing device's inbox (sent from the phone) in
/// through the same path as a paste: `IntakeProcessor.prepare`, the store's
/// `createUserItem`, then the staged files' commit. The entry becomes a user
/// item whose source App is the entry's source ("iPhone") and whose capture
/// time is when the organizing device received it.
///
/// Idempotent: the item's ID comes from the entry's ID, so an entry pulled
/// again (a crash between the commit and the acknowledgement) is found, not
/// taken in twice.
public struct IntakeInboxIngestor: RemoteOrganizerInboxIngesting {
  public let processor: IntakeProcessor
  public let store: any UserItemCommitting
  /// Awaited before each commit (the App's staging sweep).
  public let ready: @Sendable () async -> Void
  /// Called after an entry was committed now (for example to refresh lists).
  public let committed: @Sendable (SessionID) async -> Void

  public init(
    processor: IntakeProcessor, store: any UserItemCommitting,
    ready: @escaping @Sendable () async -> Void = {},
    committed: @escaping @Sendable (SessionID) async -> Void = { _ in }
  ) {
    self.processor = processor
    self.store = store
    self.ready = ready
    self.committed = committed
  }

  public static let textExtractor = "inbox-text-v1"

  public func ingest(_ entry: RemoteOrganizerInboxEntry) async throws
    -> RemoteOrganizerInboxOutcome
  {
    let id = entry.sessionID
    if try await store.existingSessionIDs(among: [id]).contains(id) {
      return .alreadyCommitted(id)
    }
    let candidate: IntakeCandidate
    switch entry.kind {
    case .text:
      guard let text = entry.text else { return .refused("没有文字") }
      candidate = .text(text, extractor: Self.textExtractor)
    case .image:
      guard let data = entry.imageData, let type = Self.imageType(data) else {
        return .refused("不是可读的图片")
      }
      candidate = .imageData(data, typeIdentifier: type)
    }
    await ready()
    let outcome = processor.prepare(
      candidate, id: id, capturedAt: entry.receivedAt,
      source: ItemSourceApplication(bundleID: nil, name: entry.source)
        ?? ItemSourceApplication(bundleID: nil, name: RemoteOrganizerInboxEntry.defaultSource),
      origin: .unknown)
    guard case .item(let draft) = outcome else {
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
