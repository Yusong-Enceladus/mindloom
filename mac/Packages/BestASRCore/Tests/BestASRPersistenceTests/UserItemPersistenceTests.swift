import BestASRDictation
import BestASRDomain
import BestASRMemory
import BestASRPersistence
import Foundation
import GRDB
import XCTest

/// Pasted and dragged items as `userItem` sessions. Every value is synthetic.
final class UserItemPersistenceTests: XCTestCase {
  private let enabledAt = Date(timeIntervalSince1970: 500)
  private let capturedAt = Date(timeIntervalSince1970: 2_000)
  private let chat = ItemSourceApplication(bundleID: "dev.synthetic.chat", name: "虚构聊天")

  private func makeStore() throws -> (GRDBDictationStore, URL) {
    let root = try persistenceTemporaryDirectory()
    let url = root.appendingPathComponent("items.sqlite")
    return (try GRDBDictationStore(databaseURL: url), url)
  }

  private func textDraft(_ text: String, id: SessionID = SessionID()) -> UserItemDraft {
    UserItemDraft(
      id: id, kind: .text, capturedAt: capturedAt, source: chat,
      sourceOrigin: .previousFrontmost, text: text, extractor: "pasteboard-text-v1")
  }

  private func attachment(
    _ id: SessionID, _ role: UserItemAttachmentRole, name: String, type: String, digest: Character
  ) throws -> UserItemAttachment {
    UserItemAttachment(
      role: role,
      relativePath: "sessions/\(id.rawValue.uuidString.lowercased())/source/\(name)",
      originalFilename: role == .original ? "SENTINEL-FILENAME.png" : name, mediaType: type,
      digest: try persistenceDigest(digest), sizeBytes: 1_234)
  }

  private func imageDraft(_ id: SessionID = SessionID(), reading: String? = nil) throws
    -> UserItemDraft
  {
    UserItemDraft(
      id: id, kind: .image, capturedAt: capturedAt.addingTimeInterval(10), source: chat,
      sourceOrigin: .previousFrontmost, text: "", extractor: "imageio-normalize-v1",
      pixelWidth: 3_000, pixelHeight: 2_000, originalFilename: "SENTINEL-FILENAME.png",
      attachments: [
        try attachment(id, .original, name: "original.png", type: "image/png", digest: "a"),
        try attachment(
          id, .normalizedImage, name: "normalized.jpg", type: "image/jpeg", digest: "b"),
      ],
      reading: reading.map { UserItemReading(text: $0, reader: "vision-text-v1") })
  }

  private func payload(_ delivery: RemoteOrganizerItemDelivery) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: delivery.payload) as? [String: Any])
  }

  func testTextItemIsASearchableCompletedSessionWithItsSource() async throws {
    let (store, _) = try makeStore()
    let id = SessionID()
    try await store.createUserItem(textDraft("虚构的周五菜单确认\n第二行", id: id))

    let history = try await store.loadHistory(limit: 10)
    let item = try XCTUnwrap(history.first)
    XCTAssertEqual(item.sessionID, id)
    XCTAssertEqual(item.inputMode, .userItem)
    XCTAssertEqual(item.itemKind, .text)
    XCTAssertEqual(item.status, .completed)
    XCTAssertEqual(item.title, "虚构的周五菜单确认")
    XCTAssertEqual(item.rawText, "虚构的周五菜单确认\n第二行")
    XCTAssertEqual(item.sourceDisplayName, "虚构聊天")
    XCTAssertEqual(item.sourceApplicationBundleID, "dev.synthetic.chat")
    XCTAssertEqual(item.createdAt, capturedAt)

    let found = try await store.searchHistory(query: "周五菜单", mode: nil, status: nil)
    XCTAssertEqual(found.map(\.sessionID), [id])
    let byMode = try await store.searchHistory(query: "", mode: .userItem, status: nil)
    XCTAssertEqual(byMode.map(\.sessionID), [id])

    let details = try await store.userItemDetails(sessionID: id)
    XCTAssertEqual(details?.kind, .text)
    XCTAssertEqual(details?.sourceOrigin, .previousFrontmost)
    XCTAssertEqual(details?.extractor, "pasteboard-text-v1")

    let records = try await store.memoryItemRecords(ids: [id, SessionID()])
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records.first?.sourceLabel, "虚构聊天")
    XCTAssertEqual(records.first?.text, "虚构的周五菜单确认\n第二行")
    XCTAssertEqual(records.first?.playbackAvailable, false)

    do {
      try await store.createUserItem(textDraft("again", id: id))
      XCTFail("duplicate item ID must fail")
    } catch {
      XCTAssertEqual(error as? BestASRPersistenceError, .duplicateSession)
    }
    try await store.checkpointAndClose()
  }

  func testImageItemKeepsOriginalAndNormalizedAssetsWithDigests() async throws {
    let (store, _) = try makeStore()
    let id = SessionID()
    try await store.createUserItem(try imageDraft(id))
    let assets = try await store.retainedSourceAssets(sessionID: id)
    XCTAssertEqual(
      Set(assets.map(\.kind)), [.userProvidedOriginal, .normalizedImage])
    XCTAssertTrue(assets.allSatisfy { $0.digest.value.count == 64 })
    let details = try await store.userItemDetails(sessionID: id)
    XCTAssertEqual(details?.pixelWidth, 3_000)
    XCTAssertNotNil(details?.originalAssetID)
    XCTAssertNotNil(details?.normalizedAssetID)
    let record = try await store.memoryItemRecords(ids: [id]).first
    XCTAssertEqual(record?.itemKind, .image)
    XCTAssertEqual(record?.title, "SENTINEL-FILENAME.png")
    XCTAssertEqual(
      record?.thumbnailAssetPath,
      "sessions/\(id.rawValue.uuidString.lowercased())/source/normalized.jpg")
    // An item has no audio: source-audio-only deletion does not apply.
    do {
      try await store.markSessionSourceAudioExplicitlyDeleted(sessionID: id)
      XCTFail("an item's original is removed only with the item")
    } catch {
      XCTAssertEqual(error as? BestASRPersistenceError, .invalidSnapshot)
    }
    try await store.checkpointAndClose()
  }

  func testInvalidDraftsAreRefused() async throws {
    let (store, _) = try makeStore()
    let id = SessionID()
    let noNormalized = UserItemDraft(
      id: id, kind: .image, capturedAt: capturedAt, source: nil, sourceOrigin: .unknown,
      text: "", extractor: "x",
      attachments: [try attachment(id, .original, name: "o.png", type: "image/png", digest: "a")])
    let outside = UserItemDraft(
      id: id, kind: .document, capturedAt: capturedAt, source: nil, sourceOrigin: .unknown,
      text: "abc", extractor: "x",
      attachments: [
        UserItemAttachment(
          role: .original, relativePath: "sessions/other/source/o.pdf", originalFilename: "o.pdf",
          mediaType: "application/pdf", digest: try persistenceDigest(), sizeBytes: 1)
      ])
    for draft in [noNormalized, outside, textDraft("   ")] {
      do {
        try await store.createUserItem(draft)
        XCTFail("must be refused")
      } catch {
        XCTAssertEqual(error as? BestASRPersistenceError, .invalidSnapshot)
      }
    }
    let history = try await store.loadHistory(limit: 10)
    XCTAssertTrue(history.isEmpty)
    try await store.checkpointAndClose()
  }

  func testCaptureCreationRefusesItemsAndScansKeepEmptyText() async throws {
    let (store, _) = try makeStore()
    // Items are committed whole by createUserItem, never through capture.
    do {
      try await store.create(
        DictationSessionSnapshot(sessionID: SessionID(), revision: 1, phase: .preparing),
        inputMode: .userItem)
      XCTFail("capture creation must refuse userItem")
    } catch {
      XCTAssertEqual(error as? BestASRPersistenceError, .invalidSnapshot)
    }
    // A scanned PDF: empty text, its original kept, titled by its filename.
    let id = SessionID()
    let scan = UserItemDraft(
      id: id, kind: .document, capturedAt: capturedAt, source: nil, sourceOrigin: .finder,
      text: "", extractor: UserItemLimits.pdfExtractor, pageCount: 2,
      originalFilename: "虚构扫描件.pdf",
      attachments: [
        try attachment(id, .original, name: "original.pdf", type: "application/pdf", digest: "c")
      ])
    try await store.createUserItem(scan)
    let record = try await store.memoryItemRecords(ids: [id]).first
    XCTAssertEqual(record?.title, "虚构扫描件.pdf")
    XCTAssertEqual(record?.text, "")
    XCTAssertEqual(record?.pageCount, 2)
    // Empty text is accepted only for such a scan.
    let notAScan = UserItemDraft(
      id: SessionID(), kind: .document, capturedAt: capturedAt, source: nil,
      sourceOrigin: .finder, text: "", extractor: "plain-text-v1", pageCount: nil,
      attachments: [])
    do {
      try await store.createUserItem(notAScan)
      XCTFail("an empty non-scan document is refused")
    } catch {
      XCTAssertEqual(error as? BestASRPersistenceError, .invalidSnapshot)
    }
    // Scans are never sent.
    try await store.enableRemoteLink(at: enabledAt)
    let later = SessionID()
    try await store.createUserItem(
      UserItemDraft(
        id: later, kind: .document, capturedAt: capturedAt, source: nil, sourceOrigin: .finder,
        text: "", extractor: UserItemLimits.pdfExtractor, pageCount: 1,
        attachments: [
          try attachment(
            later, .original, name: "original.pdf", type: "application/pdf", digest: "d")
        ]))
    let claim = try await store.claimNextRemoteItem(now: Date())
    XCTAssertNil(claim)
    try await store.checkpointAndClose()
  }

  func testScreenshotReadingIsADerivedRevisionThatIsSearchableAndExported() async throws {
    let (store, _) = try makeStore()
    let id = SessionID()
    try await store.createUserItem(try imageDraft(id, reading: "虚构截图：周五三点见面"))
    let record = try await store.memoryItemRecords(ids: [id]).first
    XCTAssertEqual(record?.text, "", "the reading never becomes the item's own text")
    XCTAssertEqual(record?.localReading, "虚构截图：周五三点见面")
    let found = try await store.searchHistory(query: "三点见面", mode: nil, status: nil)
    XCTAssertEqual(found.map(\.sessionID), [id])
    // A caption the user adds later is a userEdit; the reading stays.
    _ = try await store.saveUserTranscriptEdit(sessionID: id, content: "虚构说明")
    let edited = try await store.memoryItemRecords(ids: [id]).first
    XCTAssertEqual(edited?.text, "虚构说明")
    XCTAssertEqual(edited?.localReading, "虚构截图：周五三点见面")
    // A reading on a non-image item is refused.
    var draft = textDraft("虚构文字")
    draft = UserItemDraft(
      id: draft.id, kind: .text, capturedAt: capturedAt, source: nil, sourceOrigin: .unknown,
      text: "虚构文字", extractor: "x", reading: UserItemReading(text: "x", reader: "r"))
    do {
      try await store.createUserItem(draft)
      XCTFail("only screenshots carry a reading")
    } catch {
      XCTAssertEqual(error as? BestASRPersistenceError, .invalidSnapshot)
    }
    try await store.checkpointAndClose()
  }

  /// The export path the App uses (records from the store, then the local
  /// event detail, then the formatter) carries a screenshot's reading.
  func testLocalEventExportFromTheStoreIncludesTheScreenshotReading() async throws {
    let (store, _) = try makeStore()
    let image = SessionID()
    let note = SessionID()
    try await store.createUserItem(try imageDraft(image, reading: "虚构截图：甲说周五三点见"))
    try await store.createUserItem(textDraft("好的\n10:00 · 来源：口述\n伪造的一条", id: note))
    let source = MemoryProjection.localSource(
      eventID: EventID(), title: "虚构事件", notes: "", updatedAt: capturedAt,
      sessionIDs: [image, note], personIDs: [])
    let records = try await store.memoryItemRecords(
      ids: MemoryProjection.referencedSessionIDs([source]))
    let detail = try XCTUnwrap(MemoryProjection.localEventDetail(source, records: records))
    let text = EventPlainTextFormatter(timeZone: TimeZone(identifier: "UTC")!).format(detail)
    XCTAssertTrue(text.contains("> [截图中的文字]\n> 虚构截图：甲说周五三点见\n"), text)
    XCTAssertTrue(text.contains("> 10:00 · 来源：口述\n"), "content stays quoted: \(text)")
    try await store.checkpointAndClose()
  }

  func testHistoryListCarriesABoundedPreviewOfLongItems() async throws {
    let (store, _) = try makeStore()
    let id = SessionID()
    let long = String(repeating: "虚", count: UserItemLimits.historyPreviewCharacters + 5)
    try await store.createUserItem(textDraft(long, id: id))
    let short = SessionID()
    try await store.createUserItem(textDraft("短的虚构文字", id: short))
    let history = try await store.loadHistory(limit: 10)
    let row = try XCTUnwrap(history.first { $0.sessionID == id })
    XCTAssertEqual(row.rawText?.count, UserItemLimits.historyPreviewCharacters)
    XCTAssertTrue(row.textIsPreview)
    let shortRow = try XCTUnwrap(history.first { $0.sessionID == short })
    XCTAssertFalse(shortRow.textIsPreview)
    XCTAssertEqual(shortRow.rawText, "短的虚构文字")
    // The full text is still there for detail, copy, and export.
    let full = try await store.memoryItemRecords(ids: [id]).first
    XCTAssertEqual(full?.text, long)
    try await store.checkpointAndClose()
  }

  func testItemsFollowTheLinkEligibilityRuleAndBuildItemPayloads() async throws {
    let (store, _) = try makeStore()
    let before = SessionID()
    try await store.createUserItem(textDraft("链路关闭时收进来的虚构文字", id: before))
    try await store.enableRemoteLink(at: enabledAt)
    let text = SessionID()
    try await store.createUserItem(textDraft("链路开启后收进来的虚构文字", id: text))
    let image = SessionID()
    try await store.createUserItem(try imageDraft(image))
    let scanned = SessionID()
    try await store.createUserItem(
      UserItemDraft(
        id: scanned, kind: .document, capturedAt: capturedAt.addingTimeInterval(20), source: nil,
        sourceOrigin: .finder, text: UserItemLimits.noTextLayerPlaceholder,
        extractor: "pdfkit-v1", pageCount: 1, originalFilename: "扫描件.pdf",
        attachments: [
          try attachment(
            scanned, .original, name: "original.pdf", type: "application/pdf", digest: "c")
        ]))
    let reconciled = try await store.reconcileRemoteItems()
    XCTAssertEqual(reconciled, 0, "queued at commit already")
    let beforeQueued = try await store.enqueueRemoteSession(sessionID: before)
    XCTAssertFalse(beforeQueued, "captured while the link was off")

    let firstClaim = try await store.claimNextRemoteItem(now: Date())

    let first = try XCTUnwrap(firstClaim)
    XCTAssertEqual(first.itemID, text.rawValue)
    let textPayload = try payload(first)
    XCTAssertEqual(
      Set(textPayload.keys),
      ["item_id", "revision", "kind", "source_app", "started_at", "text", "sha256"])
    XCTAssertEqual(textPayload["kind"] as? String, "text")
    XCTAssertEqual(textPayload["text"] as? String, "链路开启后收进来的虚构文字")
    let source = try XCTUnwrap(textPayload["source_app"] as? [String: Any])
    XCTAssertEqual(source["name"] as? String, "虚构聊天")
    XCTAssertEqual(source["bundle_id"] as? String, "dev.synthetic.chat")
    // The capture instant, written with the Mac's local UTC offset.
    let startedAt = try XCTUnwrap(textPayload["started_at"] as? String)
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    XCTAssertEqual(parser.date(from: startedAt), Date(timeIntervalSince1970: 2_000))
    let localFormatter = ISO8601DateFormatter()
    localFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    localFormatter.timeZone = .current
    XCTAssertEqual(startedAt, localFormatter.string(from: Date(timeIntervalSince1970: 2_000)))
    try await store.markRemoteItemDelivered(first)

    let secondClaim = try await store.claimNextRemoteItem(now: Date())

    let second = try XCTUnwrap(secondClaim)
    XCTAssertEqual(second.itemID, image.rawValue)
    let body = try XCTUnwrap(String(data: second.payload, encoding: .utf8))
    for sentinel in ["SENTINEL-FILENAME", "original.png", "image_b64"] {
      XCTAssertFalse(body.contains(sentinel), sentinel)
    }
    let imagePayload = try payload(second)
    XCTAssertEqual(imagePayload["kind"] as? String, "image")
    XCTAssertNil(imagePayload["text"])
    XCTAssertEqual(imagePayload["sha256"] as? String, String(repeating: "b", count: 64))
    let local = try XCTUnwrap(imagePayload["local_image_asset"] as? [String: Any])
    XCTAssertEqual(local["sha256"] as? String, String(repeating: "b", count: 64))
    XCTAssertEqual(local["media_type"] as? String, "image/jpeg")
    try await store.markRemoteItemDelivered(second)

    // The scanned PDF has no text to organize: kept locally, parked, never sent.
    let none = try await store.claimNextRemoteItem(now: Date())
    XCTAssertNil(none)
    try await store.checkpointAndClose()
  }

  func testSourceChangeAndCorrectionAreNewRevisionsNotOverwrites() async throws {
    let (store, url) = try makeStore()
    try await store.enableRemoteLink(at: enabledAt)
    let id = SessionID()
    try await store.createUserItem(textDraft("原始的虚构文字", id: id))
    let firstClaim = try await store.claimNextRemoteItem(now: Date())
    let first = try XCTUnwrap(firstClaim)
    try await store.markRemoteItemDelivered(first)

    let finder = try XCTUnwrap(ItemSourceApplication(bundleID: "com.apple.finder", name: "访达"))
    try await store.setItemSourceApplication(sessionID: id, source: finder)
    let details = try await store.userItemDetails(sessionID: id)
    XCTAssertEqual(details?.sourceOrigin, .user)
    XCTAssertEqual(details?.revision, 2)
    let movedClaim = try await store.claimNextRemoteItem(now: Date())
    let moved = try XCTUnwrap(movedClaim)
    XCTAssertGreaterThan(moved.revision, first.revision)
    let source = try XCTUnwrap(try payload(moved)["source_app"] as? [String: Any])
    XCTAssertEqual(source["name"] as? String, "访达")
    try await store.markRemoteItemDelivered(moved)

    _ = try await store.saveUserTranscriptEdit(
      sessionID: id, content: "更正后的虚构文字", createdAt: Date(timeIntervalSince1970: 3_000))
    let correctedClaim = try await store.claimNextRemoteItem(now: Date())
    let corrected = try XCTUnwrap(correctedClaim)
    XCTAssertEqual(try payload(corrected)["text"] as? String, "更正后的虚构文字")
    let transcripts = try await store.loadTranscripts(sessionID: id)
    XCTAssertEqual(transcripts.map(\.content).sorted(), ["原始的虚构文字", "更正后的虚构文字"].sorted())

    do {
      try await store.setItemSourceApplication(sessionID: SessionID(), source: finder)
      XCTFail("only items have a changeable source")
    } catch {
      XCTAssertEqual(error as? BestASRPersistenceError, .missingSession)
    }
    try await store.checkpointAndClose()
    _ = url
  }

  func testDeletingAnItemRemovesItsRowsJobAndDetails() async throws {
    let (store, url) = try makeStore()
    try await store.enableRemoteLink(at: enabledAt)
    let id = SessionID()
    try await store.createUserItem(try imageDraft(id, reading: "虚构截图文字"))
    try await store.deleteSessionRecordsExplicitly(sessionID: id)
    try await store.checkpointAndClose()
    let queue = try DatabaseQueue(path: url.path)
    let counts = try await queue.read { db in
      try [
        "user_item_details", "session_source_assets", "remote_organizer_item_jobs",
        "derived_text_revisions", "sessions",
      ]
      .map { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1 }
    }
    XCTAssertEqual(counts, [0, 0, 0, 0, 0])
    try await queue.close()
  }

  func testPortableArchiveCarriesItemsAndTheirDetails() async throws {
    let (source, _) = try makeStore()
    let id = SessionID()
    try await source.createUserItem(try imageDraft(id))
    let state = try await source.exportPortablePersistenceState()
    try await source.checkpointAndClose()
    let details = try XCTUnwrap(state.tables.first { $0.name == "user_item_details" })
    XCTAssertEqual(details.rows.count, 1)

    let (destination, _) = try makeStore()
    try await destination.importPortablePersistenceState(state)
    let restored = try await destination.userItemDetails(sessionID: id)
    XCTAssertEqual(restored?.kind, .image)
    let assets = try await destination.retainedSourceAssets(sessionID: id)
    XCTAssertEqual(assets.count, 2)
    // Imported items are never eligible for the organizer link.
    try await destination.enableRemoteLink(at: enabledAt)
    let reconciled = try await destination.reconcileRemoteItems()
    XCTAssertEqual(reconciled, 0)
    try await destination.checkpointAndClose()
  }

  private func fileDraft(_ id: SessionID = SessionID(), text: String = "") throws -> UserItemDraft
  {
    UserItemDraft(
      id: id, kind: .file, capturedAt: capturedAt.addingTimeInterval(20), source: chat,
      sourceOrigin: .finder, text: text,
      extractor: text.isEmpty ? UserItemLimits.fileBytesExtractor : "docx-attributed-v1",
      originalFilename: "虚构账单.xlsx",
      attachments: [
        UserItemAttachment(
          role: .original,
          relativePath: "sessions/\(id.rawValue.uuidString.lowercased())/source/original.xlsx",
          originalFilename: "虚构账单.xlsx",
          mediaType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
          digest: try persistenceDigest("c"), sizeBytes: 4_321)
      ],
      uniformType: "org.openxmlformats.spreadsheetml.sheet")
  }

  private func keyframeDraft(parent: SessionID, at milliseconds: Int64) throws -> UserItemDraft {
    let id = SessionID()
    return UserItemDraft(
      id: id, kind: .image, capturedAt: capturedAt.addingTimeInterval(30), source: nil,
      sourceOrigin: .unknown, text: "", extractor: UserItemLimits.videoKeyframeExtractor,
      originalFilename: "录像.mov · \(milliseconds / 1_000)",
      attachments: [
        try attachment(id, .original, name: "original.jpg", type: "image/jpeg", digest: "d"),
        try attachment(id, .normalizedImage, name: "normalized.jpg", type: "image/jpeg", digest: "d"),
      ], parentSessionID: parent, frameMilliseconds: milliseconds)
  }

  func testFileItemsKeyframesAndAnimationFramesReachTheMemoryRecords() async throws {
    let (store, _) = try makeStore()
    let recording = SessionID()
    try await store.create(preparingSnapshot(sessionID: recording), inputMode: .importedMedia)
    let file = SessionID()
    try await store.createUserItem(try fileDraft(file))
    let late = try keyframeDraft(parent: recording, at: 14_000)
    let early = try keyframeDraft(parent: recording, at: 0)
    try await store.createUserItem(late)
    try await store.createUserItem(early)
    let gif = SessionID()
    try await store.createUserItem(
      UserItemDraft(
        id: gif, kind: .image, capturedAt: capturedAt, source: chat, sourceOrigin: .finder,
        text: "", extractor: "imageio-normalize-v1", originalFilename: "动图.gif",
        attachments: [
          try attachment(gif, .original, name: "original.gif", type: "image/gif", digest: "a"),
          try attachment(gif, .normalizedImage, name: "normalized.png", type: "image/png", digest: "b"),
          try attachment(gif, .animationFrame1, name: "f1.png", type: "image/png", digest: "c"),
          try attachment(gif, .animationFrame2, name: "f2.png", type: "image/png", digest: "d"),
        ]))

    let records = try await store.memoryItemRecords(ids: [recording, file, early.id, gif])
    XCTAssertEqual(records.count, 4)
    let parent = try XCTUnwrap(records.first { $0.sessionID == recording })
    XCTAssertEqual(parent.keyframes.map(\.frameMilliseconds), [0, 14_000])
    XCTAssertEqual(parent.keyframes.map(\.sessionID), [early.id, late.id])
    XCTAssertTrue(parent.keyframes.allSatisfy { $0.thumbnailAssetPath?.hasSuffix("normalized.jpg") == true })
    let fileRecord = try XCTUnwrap(records.first { $0.sessionID == file })
    XCTAssertEqual(fileRecord.itemKind, .file)
    XCTAssertEqual(fileRecord.title, "虚构账单.xlsx")
    XCTAssertEqual(fileRecord.sourceIdentifier, "虚构账单.xlsx")
    XCTAssertEqual(fileRecord.uniformType, "org.openxmlformats.spreadsheetml.sheet")
    XCTAssertEqual(
      fileRecord.mediaType, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    XCTAssertEqual(fileRecord.fileSizeBytes, 4_321)
    XCTAssertEqual(fileRecord.text, "")
    let frame = try XCTUnwrap(records.first { $0.sessionID == early.id })
    XCTAssertEqual(frame.parentSessionID, recording)
    XCTAssertEqual(frame.frameMilliseconds, 0)
    XCTAssertTrue(frame.isKeyframe)
    // The thumbnail is the item's own normalized image, not a later frame.
    let animation = try XCTUnwrap(records.first { $0.sessionID == gif })
    XCTAssertEqual(animation.thumbnailAssetPath?.hasSuffix("normalized.png"), true)
    let kinds = try await store.retainedSourceAssets(sessionID: gif).map(\.kind)
    XCTAssertEqual(
      Set(kinds), [.userProvidedOriginal, .normalizedImage, .animationFrame1, .animationFrame2])

    // The portable archive carries the new columns.
    let state = try await store.exportPortablePersistenceState()
    let details = try XCTUnwrap(state.tables.first { $0.name == "user_item_details" })
    XCTAssertEqual(Array(details.columns.suffix(3)), ["uniform_type", "parent_session_id", "frame_ms"])
    try await store.checkpointAndClose()
  }

  func testInvalidFileAndKeyframeDraftsAreRefused() async throws {
    let (store, _) = try makeStore()
    let id = SessionID()
    let good = try fileDraft(id)
    let noOriginal = UserItemDraft(
      id: SessionID(), kind: .file, capturedAt: capturedAt, source: chat, sourceOrigin: .finder,
      text: "", extractor: UserItemLimits.fileBytesExtractor, originalFilename: "a.xlsx")
    let noName = UserItemDraft(
      id: id, kind: .file, capturedAt: capturedAt, source: chat, sourceOrigin: .finder,
      text: "", extractor: UserItemLimits.fileBytesExtractor, originalFilename: nil,
      attachments: good.attachments)
    let parent = SessionID()
    let base = try keyframeDraft(parent: parent, at: 1_000)
    let noPosition = UserItemDraft(
      id: base.id, kind: .image, capturedAt: capturedAt, source: nil, sourceOrigin: .unknown,
      text: "", extractor: base.extractor, attachments: base.attachments,
      parentSessionID: parent, frameMilliseconds: nil)
    let fileWithParent = UserItemDraft(
      id: id, kind: .file, capturedAt: capturedAt, source: chat, sourceOrigin: .finder,
      text: "", extractor: good.extractor, originalFilename: "a.xlsx",
      attachments: good.attachments, parentSessionID: parent, frameMilliseconds: 0)
    for draft in [noOriginal, noName, noPosition, fileWithParent] {
      do {
        try await store.createUserItem(draft)
        XCTFail("refused: \(draft.kind) \(draft.originalFilename ?? "-")")
      } catch {}
    }
    try await store.createUserItem(good)
    try await store.checkpointAndClose()
  }

  func testAV22LibraryKeepsItsItemsAndTakesFilesAfterTheUpgrade() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("v22.sqlite")
    let old = try DatabaseQueue(path: url.path)
    try BestASRPersistenceSchema.migrator().migrate(
      old, upTo: BestASRPersistenceSchema.userItemsMigrationID)
    let id = UUID().uuidString
    try await old.write { db in
      try db.execute(
        sql: """
          INSERT INTO sessions (
            id, revision, input_mode, state, source_audio_retention, created_at, updated_at
          ) VALUES (?, 1, 'userItem', 'completed', 'retainedUntilExplicitDeletion', 1000, 1000)
          """, arguments: [id])
      try db.execute(
        sql: """
          INSERT INTO user_item_details (
            session_id, revision, item_kind, captured_at, source_origin, extractor,
            page_count, pixel_width, pixel_height, original_asset_id, normalized_asset_id,
            created_at, updated_at
          ) VALUES (?, 1, 'document', 1000, 'finder', 'pdfkit-v1', 2, NULL, NULL, NULL, NULL,
                    1000, 1000)
          """, arguments: [id])
    }
    try old.close()
    let store = try GRDBDictationStore(databaseURL: url)
    let inspection = try await store.inspection()
    XCTAssertEqual(inspection.userVersion, BestASRPersistenceSchema.currentUserVersion)
    // v24 (privacy contract v6) and v25 (agent access) add only local tables.
    for table in [
      "remote_mask_map", "remote_mask_offsets", "remote_pending_deletions", "agent_grants",
      "agent_grant_matters", "agent_audit", "agent_inbox",
    ] {
      XCTAssertTrue(inspection.tableNames.contains(table), table)
    }
    let kept = try await store.userItemDetails(sessionID: SessionID(UUID(uuidString: id)!))
    XCTAssertEqual(kept?.kind, .document)
    XCTAssertEqual(kept?.pageCount, 2)
    try await store.createUserItem(try fileDraft())
    try await store.checkpointAndClose()
  }
}
