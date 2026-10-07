import BestASRDomain
import BestASREntries
import BestASRIntake
import Foundation

/// One meeting record to add: its fixed number, the recording's start, the
/// readable transcript and the source file.
public struct TencentMeetingItem: Equatable, Sendable {
  public let id: SessionID
  public let capturedAt: Date
  public let text: String
  public let source: Data

  public init(id: SessionID, capturedAt: Date, text: String, source: Data) {
    self.id = id
    self.capturedAt = capturedAt
    self.text = text
    self.source = source
  }

  /// Where it says it came from: 「会议记录 · 腾讯会议」 (the same source an
  /// exported transcript chosen in 文件 ›“导入会议记录…” gets).
  public static let sourceName = "腾讯会议"
  public static let extractor = "tencent-meeting-transcript-v1"
  public static let sourceFilename = "腾讯会议转写.json"

  /// The item number of a recording's transcript: fixed for the first
  /// version, so a pass cut short between adding it and saving the job
  /// finds it already there; a later version (Tencent changed the
  /// transcript) gets a number of its own.
  public static func id(recordFileID: String, version: Int, digest: String?) -> SessionID {
    let key =
      version == 0
      ? "record:\(recordFileID)" : "record:\(recordFileID):v\(version):\(digest ?? "")"
    return EntryIdentity.itemID(.tencentMeeting, key: key)
  }
}

/// Adds meeting records to the library.
public protocol TencentMeetingItemWriting: Sendable {
  /// Which of these items are in the library (not deleted by the owner).
  func existing(_ ids: [SessionID]) async -> Set<SessionID>
  func add(_ item: TencentMeetingItem) async throws
}

public enum TencentMeetingWriteError: Error, Equatable, Sendable {
  /// The item is already in the library (an earlier run added it).
  case alreadyThere
  case failed
}

/// The library's own path for an item (as a paste or a drop is committed):
/// stage the source file, commit the rows, then the files. A document item:
/// its text is what is sent for organizing; the source JSON stays on this
/// Mac.
public struct TencentMeetingLibraryWriter: TencentMeetingItemWriting {
  public let assetStore: IntakeAssetStore
  public let store: any UserItemCommitting
  /// Awaited before each add (the App's staging sweep).
  public let ready: @Sendable () async -> Void

  public init(
    assetStore: IntakeAssetStore, store: any UserItemCommitting,
    ready: @escaping @Sendable () async -> Void = {}
  ) {
    self.assetStore = assetStore
    self.store = store
    self.ready = ready
  }

  public func existing(_ ids: [SessionID]) async -> Set<SessionID> {
    guard !ids.isEmpty else { return [] }
    return (try? await store.existingSessionIDs(among: ids)) ?? []
  }

  public func add(_ item: TencentMeetingItem) async throws {
    await ready()
    if (try? await store.existingSessionIDs(among: [item.id]))?.contains(item.id) == true {
      throw TencentMeetingWriteError.alreadyThere
    }
    let request = IntakeAssetStore.Request(
      role: .original, source: .data(item.source),
      originalFilename: TencentMeetingItem.sourceFilename, mediaType: "application/json",
      fileExtension: "json")
    let attachments: [UserItemAttachment]
    do {
      attachments = try assetStore.stage(sessionID: item.id, requests: [request])
    } catch IntakeAssetStore.StoreError.alreadyExists {
      // Files staged by a run that stopped before its rows: still marked as
      // staging, so `discard` removes them (a committed item's never).
      assetStore.discard(sessionID: item.id)
      guard let staged = try? assetStore.stage(sessionID: item.id, requests: [request]) else {
        throw TencentMeetingWriteError.failed
      }
      attachments = staged
    } catch {
      throw TencentMeetingWriteError.failed
    }
    let draft = UserItemDraft(
      id: item.id, kind: .document, capturedAt: item.capturedAt,
      source: ItemSourceApplication(bundleID: nil, name: TencentMeetingItem.sourceName),
      sourceOrigin: .unknown, text: item.text, extractor: TencentMeetingItem.extractor,
      originalFilename: TencentMeetingItem.sourceFilename, attachments: attachments,
      uniformType: "public.json")
    do {
      try await store.createUserItem(draft)
      assetStore.commit(sessionID: item.id)
    } catch {
      assetStore.discard(sessionID: item.id)
      if (try? await store.existingSessionIDs(among: [item.id]))?.contains(item.id) == true {
        throw TencentMeetingWriteError.alreadyThere
      }
      throw TencentMeetingWriteError.failed
    }
  }
}
