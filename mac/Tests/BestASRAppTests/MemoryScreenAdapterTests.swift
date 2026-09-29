import BestASRDictation
import BestASRDomain
import BestASRMemory
import BestASRMemoryUI
import BestASRPersistence
import XCTest

@testable import bestASR

/// The App side of the memory pages with the link off: which captures show
/// as Unfiled, and which local suggestions become yes/no questions.
/// Synthetic values only; no library is opened.
@MainActor
final class MemoryScreenAdapterTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_790_000_000)

  private func item(_ n: Int, _ mode: SessionInputMode, daysAgo: Double) -> DictationHistoryItem {
    DictationHistoryItem(
      sessionID: SessionID(UUID(uuidString: String(format: "C0000000-0000-4000-8000-%012d", n))!),
      inputMode: mode, revision: 1, phase: .completed, status: .completed, rawText: "虚构 \(n)",
      polishedText: nil, failureCode: nil, canRetry: false, sourceAudioRetained: mode != .userItem,
      createdAt: now.addingTimeInterval(-daysAgo * 86_400),
      updatedAt: now.addingTimeInterval(-daysAgo * 86_400), recoveredAt: nil)
  }

  func testLinkOffUnfiledAndQuestionsComeFromLocalMemory() throws {
    let model = DictationAppModel(preview: true)
    let inEvent = item(1, .userItem, daysAgo: 1)
    let loose = item(2, .userItem, daysAgo: 1)
    let room = item(3, .roomMicrophone, daysAgo: 2)
    let dictation = item(4, .dictation, daysAgo: 1)
    let old = item(5, .userItem, daysAgo: 20)
    model.history.historyItems = [inEvent, loose, room, dictation, old]
    let eventID = EventID(UUID(uuidString: "C1000000-0000-4000-8000-000000000001")!)
    model.events.summaries = [
      EventSummary(
        event: MemoryEvent(
          id: eventID, revision: try Revision(1), title: "虚构事件", startAt: now, endAt: now,
          titleIsUserEdited: false, createdAt: now, updatedAt: now),
        sessionIDs: [inEvent.sessionID], personIDs: [], personDisplayNames: [],
        inputModes: ["userItem"], pendingCandidateCount: 1)
    ]
    model.events.candidates = [
      EventCandidate(
        sessionID: loose.sessionID, candidateEventID: eventID, proposedTitle: "虚构事件",
        evidence: .manual(at: now), createdAt: now, updatedAt: now),
      EventCandidate(
        sessionID: room.sessionID, candidateEventID: nil, proposedTitle: "新的一件事",
        evidence: .manual(at: now), createdAt: now, updatedAt: now),
    ]

    XCTAssertFalse(model.memoryUsesRemote)
    // Items and recordings of the last 14 days in no event; dictation stays
    // under 全部.
    XCTAssertEqual(
      Set(model.localUnfiled(now: now).map(\.itemID)),
      [loose.sessionID.rawValue.uuidString, room.sessionID.rawValue.uuidString])
    let questions = model.localMemoryQuestions()
    // It names the item, as the organizing device's questions do.
    XCTAssertEqual(questions.map(\.prompt), ["这条「虚构 2」和「虚构事件」是同一件事吗？"])
    XCTAssertEqual(questions.first?.kind, .itemIntoEvent)
    XCTAssertEqual(questions.first?.origin, .local)
    XCTAssertEqual(questions.first?.b, eventID.rawValue.uuidString)
  }

  /// 全部 shows one filtered page of 60; Unfiled must not depend on it.
  func testLinkOffUnfiledDoesNotDependOnTheHistoryPage() {
    let model = DictationAppModel(preview: true)
    let loose = item(2, .userItem, daysAgo: 1)
    let room = item(3, .roomMicrophone, daysAgo: 2)
    let newest = item(6, .userItem, daysAgo: 0)
    // The unfiltered set the event memory loads, and a 全部 page filtered
    // down to one newer item.
    model.history.eventAvailableHistoryItems = [loose, room]
    model.history.historyItems = [newest]
    XCTAssertEqual(
      Set(model.localUnfiled(now: now).map(\.itemID)),
      Set([loose, room, newest].map { $0.sessionID.rawValue.uuidString }))
    XCTAssertEqual(model.memoryHistoryItem(room.sessionID)?.sessionID, room.sessionID)
  }

  /// Renaming a voice this Mac knows while Home shows the organizing
  /// device's people also records the decision, so the new name shows at once.
  func testRenameRoutes() {
    let both = DictationAppModel.memoryRenameRoutes(knownLocally: true, usesRemote: true)
    XCTAssertTrue(both.local)
    XCTAssertTrue(both.decision)
    let localOnly = DictationAppModel.memoryRenameRoutes(knownLocally: true, usesRemote: false)
    XCTAssertTrue(localOnly.local)
    XCTAssertFalse(localOnly.decision)
    XCTAssertTrue(
      DictationAppModel.memoryRenameRoutes(knownLocally: false, usesRemote: true).decision)
  }

  /// 移到… takes the record out of the event page it was moved from, even
  /// when another event holds it too.
  func testLocalMoveSourceIsThePageMovedFrom() throws {
    let shared = item(7, .userItem, daysAgo: 1)
    func summary(_ n: Int) throws -> EventSummary {
      let eventID = EventID(UUID(uuidString: String(format: "C2000000-0000-4000-8000-%012d", n))!)
      return EventSummary(
        event: MemoryEvent(
          id: eventID, revision: try Revision(1), title: "虚构 \(n)", startAt: now, endAt: now,
          titleIsUserEdited: false, createdAt: now, updatedAt: now),
        sessionIDs: [shared.sessionID], personIDs: [], personDisplayNames: [],
        inputModes: ["userItem"], pendingCandidateCount: 0)
    }
    let a = try summary(1)
    let b = try summary(2)
    XCTAssertEqual(
      DictationAppModel.memoryLocalMoveSource(
        from: b.id, session: shared.sessionID, summaries: [a, b]), b.id)
    // From Unfiled (no page), the first holder.
    XCTAssertEqual(
      DictationAppModel.memoryLocalMoveSource(
        from: nil, session: shared.sessionID, summaries: [a, b]), a.id)
  }

  /// Corrections the device did not take reach Home with their way out.
  func testUnacceptedDecisionsBecomeHomeIssues() throws {
    let rejected = RemoteOrganizerDecisionIssue(
      decisionID: UUID(uuidString: "C3000000-0000-4000-8000-000000000001")!, kind: "rename_event",
      state: .rejected, errorCategory: "rejected", reason: nil)
    let unknown = RemoteOrganizerDecisionIssue(
      decisionID: UUID(uuidString: "C3000000-0000-4000-8000-000000000002")!, kind: "same_event",
      state: .deliveryUnknown, errorCategory: "in_flight", reason: nil)
    let issues = MemoryScreenModel.issues(
      RemoteOrganizerProjection(
        cursor: 1, events: [], questions: [], persons: [],
        unacceptedDecisions: [rejected, unknown]))
    XCTAssertEqual(issues.map(\.deliveryUnknown), [false, true])
    XCTAssertEqual(issues.first?.title, "整理设备未接受：改标题（整理设备拒绝了这次修改）")
    XCTAssertEqual(issues.first?.id, rejected.decisionID.uuidString)
  }

  func testPinAndFeatureLessNeedTheOrganizingDevice() {
    let model = DictationAppModel(preview: true)
    // No link and no projection: nothing is recorded and nothing crashes.
    model.memoryPin("ev", pinned: true)
    model.memoryFeatureLess("ev")
    XCTAssertNil(model.events.remoteProjection)
  }
}
