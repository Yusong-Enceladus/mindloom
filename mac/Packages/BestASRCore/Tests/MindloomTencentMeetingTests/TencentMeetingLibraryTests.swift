import BestASRDomain
import BestASREntries
import BestASRIntake
import BestASRMemory
import BestASRPersistence
import BestASRRemoteOrganizer
import Foundation
import XCTest

@testable import MindloomTencentMeeting

/// The entry's items in a real library (a synthetic root): a document item
/// 「会议记录 · 腾讯会议」 whose text is the transcript and whose source file
/// is the raw JSON, added once.
final class TencentMeetingLibraryTests: XCTestCase {
  var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tencent-library-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data().write(
      to: root.appendingPathComponent(RemoteOrganizerDataProvenance.syntheticMarkerFileName))
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testAPassAddsMeetingRecordsWithTheirSourceFilesToTheLibrary() async throws {
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    let assets = IntakeAssetStore(
      assetRoot: root.appendingPathComponent("assets", isDirectory: true))
    let writer = TencentMeetingLibraryWriter(assetStore: assets, store: store)
    var state = TencentMeetingState()
    state.connectedAt = Fixture.now
    state.backfill = .add
    let folder = EntryFolder(dataRoot: root)
    let sync = TencentMeetingSync(
      state: state, runner: FakeTmeet(FakeTmeet.standard), writer: writer,
      configuration: .init(tmeetVersion: "test"), calendar: Fixture.calendar,
      save: { try? folder.saveState($0, for: .tencentMeeting) })
    let report = await sync.pass(.full, now: Fixture.now)
    XCTAssertEqual(report.added, 3)

    let ids = await sync.snapshot.recordings.values.flatMap(\.itemIDs).compactMap {
      UUID(uuidString: $0).map(SessionID.init)
    }
    XCTAssertEqual(ids.count, 3)
    let records = try await store.memoryItemRecords(ids: ids)
    XCTAssertEqual(records.count, 3)
    for record in records {
      XCTAssertEqual(MemoryItemSource.words(record).line, "会议记录 · 腾讯会议")
      XCTAssertEqual(MemoryItemSource.kind(record), .meeting)
      XCTAssertEqual(record.itemKind, .document)
      XCTAssertNotNil(MemoryTranscriptText.parse(record.text ?? ""))
    }
    let textID = TencentMeetingItem.id(recordFileID: "6000000000000000012", version: 0, digest: nil)
    let fetched = try await store.userItemDetails(sessionID: textID)
    let details = try XCTUnwrap(fetched)
    XCTAssertEqual(details.extractor, TencentMeetingItem.extractor)
    XCTAssertEqual(details.kind, .document)
    XCTAssertNotNil(details.originalAssetID)
    let bytes = try Data(
      contentsOf: assets.sessionDirectory(textID).appendingPathComponent("source/original.json"))
    let source = try XCTUnwrap(TencentMeetingSourceDocument.parse(bytes))
    XCTAssertEqual(source.recordFileID, "6000000000000000012")
    XCTAssertEqual(source.paragraphs.map(\.speakerUserID).compactMap { $0 }.count, 5)

    // The job state is on disk in the entries folder, 0600.
    let saved = try XCTUnwrap(folder.loadState(.tencentMeeting, as: TencentMeetingState.self))
    // The eight the two listings give, and the two more meeting get lists.
    XCTAssertEqual(saved.recordings.count, 10)
    let mode =
      try FileManager.default.attributesOfItem(atPath: folder.stateURL(.tencentMeeting).path)[
        .posixPermissions] as? NSNumber
    XCTAssertEqual(mode?.intValue, 0o600)

    // Adding the same item again is refused as already there.
    let again = TencentMeetingItem(
      id: textID, capturedAt: Fixture.now, text: "x", source: Data("{}".utf8))
    do {
      try await writer.add(again)
      XCTFail("added twice")
    } catch {
      XCTAssertEqual(error as? TencentMeetingWriteError, .alreadyThere)
    }
    try await store.checkpointAndClose()
  }

  func testTheTestKeyFileExistsOnlyInAMarkedSyntheticRoot() throws {
    let store = try SyntheticTencentMeetingKeyStore(
      dataRoot: root, realLibraryRoot: URL(fileURLWithPath: "/nonexistent-library"))
    XCTAssertNil(try store.key())
    let key = try store.existingOrNewKey()
    XCTAssertEqual(key.count, 32)
    XCTAssertEqual(try store.key(), key)
    try store.delete()
    XCTAssertNil(try store.key())
    let unmarked = FileManager.default.temporaryDirectory.appendingPathComponent(
      "unmarked-\(UUID().uuidString)")
    XCTAssertThrowsError(
      try SyntheticTencentMeetingKeyStore(
        dataRoot: unmarked, realLibraryRoot: URL(fileURLWithPath: "/nonexistent-library")))
    XCTAssertThrowsError(try SyntheticTencentMeetingKeyStore(dataRoot: root, realLibraryRoot: root))
  }
}
