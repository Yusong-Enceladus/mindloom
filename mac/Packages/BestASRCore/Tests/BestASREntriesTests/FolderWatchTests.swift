import BestASRDomain
import BestASREntries
import BestASRIntake
import Foundation
import XCTest

/// V8 contract A4: watched folders, off by default, with exclusions, a size
/// limit and a pause. Only files that appear after watching starts are
/// taken, once each, after they settle, by the drop rules.
final class FolderWatchTests: XCTestCase {
  private func look(
    _ folder: WatchedFolder, _ state: inout FolderWatchState, paused: Bool = false,
    protected: URL? = nil
  ) -> [FolderWatchDecision] {
    FolderWatchEngine.scan(
      folder, listing: FolderListingEntry.list(folder.url) ?? [], paused: paused, state: &state,
      isProtected: { url in protected.map { url.path.hasPrefix($0.path) } ?? false })
  }

  func testOnlyNewSettledFilesAreTakenOnceAndRulesApply() async throws {
    let root = try makeTemporaryFolder()
    let screens = root.appendingPathComponent("截图", isDirectory: true)
    try FileManager.default.createDirectory(at: screens, withIntermediateDirectories: true)
    try Data("已有的".utf8).write(to: screens.appendingPathComponent("old.txt"))
    let folder = WatchedFolder(
      path: screens.path, exclusions: ["*.dmg", "私人*"], maximumMegabytes: 1)
    var state = FolderWatchState()

    // First look: what is there is accounted for, never taken.
    XCTAssertEqual(look(folder, &state), [])

    try Data("新截图的文字".utf8).write(to: screens.appendingPathComponent("note 1.txt"))
    try Data(count: 10).write(to: screens.appendingPathComponent("installer.dmg"))
    try Data("x".utf8).write(to: screens.appendingPathComponent("私人日记.txt"))
    try Data(count: 2 * 1_024 * 1_024).write(to: screens.appendingPathComponent("huge.bin"))
    try Data("y".utf8).write(to: screens.appendingPathComponent("paper.pdf.crdownload"))
    try Data("z".utf8).write(to: screens.appendingPathComponent(".hidden"))
    // Seen once: waiting to settle.
    XCTAssertEqual(look(folder, &state), [])
    XCTAssertTrue(FolderWatchEngine.hasSettling(state))
    // Seen again unchanged: decided.
    let decisions = look(folder, &state)
    let taken = decisions.compactMap { decision -> String? in
      if case .take(let url, _) = decision { return url.lastPathComponent }
      return nil
    }
    let skipped = Dictionary(
      uniqueKeysWithValues: decisions.compactMap { decision -> (String, String)? in
        if case .skip(let name, let reason) = decision { return (name, reason) }
        return nil
      })
    XCTAssertEqual(taken, ["note 1.txt"])
    XCTAssertEqual(skipped["installer.dmg"], FolderWatchEngine.excludedReason)
    XCTAssertEqual(skipped["私人日记.txt"], FolderWatchEngine.excludedReason)
    XCTAssertEqual(skipped["huge.bin"], FolderWatchEngine.tooLargeReason)
    XCTAssertNil(skipped["paper.pdf.crdownload"])
    XCTAssertNil(skipped[".hidden"])
    XCTAssertNil(skipped["old.txt"])
    // Never twice, even when it grows afterwards.
    try Data("新截图的文字，后来又写了一点".utf8).write(to: screens.appendingPathComponent("note 1.txt"))
    XCTAssertEqual(look(folder, &state), [])
    XCTAssertEqual(look(folder, &state), [])

    // The finished download (renamed) is new, and is taken once settled.
    try FileManager.default.moveItem(
      at: screens.appendingPathComponent("paper.pdf.crdownload"),
      to: screens.appendingPathComponent("paper.txt"))
    XCTAssertEqual(look(folder, &state), [])
    guard case .take(let url, let created)? = look(folder, &state).first else {
      return XCTFail("the renamed download should be taken")
    }
    XCTAssertEqual(url.lastPathComponent, "paper.txt")

    // Through the drop rules, with the folder as the source.
    let (committer, store) = makeCommitter(root: root)
    let summary = await committer.commit([
      FolderWatchEngine.item(url, createdAt: created, folder: folder)
    ])
    XCTAssertEqual(summary.storedCount, 1)
    let firstDraft = await store.drafts.first
    let draft = try XCTUnwrap(firstDraft)
    XCTAssertEqual(draft.source?.name, "文件夹 · 截图")
    XCTAssertEqual(draft.capturedAt, created)
  }

  func testPausedFoldersTakeNothingEvenAfterResuming() throws {
    let root = try makeTemporaryFolder()
    let downloads = root.appendingPathComponent("下载", isDirectory: true)
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let folder = WatchedFolder(path: downloads.path)
    var state = FolderWatchState()
    XCTAssertEqual(look(folder, &state), [])
    // Paused: a file arrives and settles, nothing is taken.
    try Data("暂停时下载的".utf8).write(to: downloads.appendingPathComponent("during-pause.txt"))
    XCTAssertEqual(look(folder, &state, paused: true), [])
    XCTAssertEqual(look(folder, &state, paused: true), [])
    // Resumed: what arrived while paused stays untaken.
    XCTAssertEqual(look(folder, &state), [])
    XCTAssertEqual(look(folder, &state), [])
    // Something new after resuming is taken.
    try Data("恢复后".utf8).write(to: downloads.appendingPathComponent("after.txt"))
    XCTAssertEqual(look(folder, &state), [])
    XCTAssertEqual(look(folder, &state).count, 1)
  }

  func testLinksFoldersAndTheLibraryAreNeverTaken() throws {
    let root = try makeTemporaryFolder()
    let watched = root.appendingPathComponent("watched", isDirectory: true)
    try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
    let folder = WatchedFolder(path: watched.path)
    var state = FolderWatchState()
    XCTAssertEqual(look(folder, &state, protected: watched.appendingPathComponent("lib")), [])
    let secret = root.appendingPathComponent("elsewhere.txt")
    try Data("别处的文件".utf8).write(to: secret)
    try FileManager.default.createSymbolicLink(
      at: watched.appendingPathComponent("link.txt"), withDestinationURL: secret)
    try FileManager.default.createDirectory(
      at: watched.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: watched.appendingPathComponent("lib-file"))
    _ = look(folder, &state, protected: watched.appendingPathComponent("lib"))
    let decisions = look(folder, &state, protected: watched.appendingPathComponent("lib"))
    XCTAssertEqual(decisions, [.skip(name: "lib-file", reason: FolderWatchEngine.protectedReason)])
  }

  func testRulesAndPruning() {
    XCTAssertTrue(FolderWatchRules.isIgnored(".DS_Store"))
    XCTAssertTrue(FolderWatchRules.isIgnored("~$report.docx"))
    XCTAssertTrue(FolderWatchRules.isIgnored("movie.mp4.download"))
    XCTAssertFalse(FolderWatchRules.isIgnored("截屏2026-10-01 10.00.00.png"))
    XCTAssertTrue(FolderWatchRules.isExcluded("Setup.DMG", patterns: ["*.dmg"]))
    XCTAssertFalse(FolderWatchRules.isExcluded("a.png", patterns: ["", "  "]))
    var state = FolderWatchState()
    state.known["gone"] = [:]
    state.settling["gone"] = [:]
    let kept = WatchedFolder(path: "/tmp/x")
    state.known[kept.id.uuidString] = [:]
    FolderWatchEngine.prune(&state, keeping: [kept])
    XCTAssertEqual(Array(state.known.keys), [kept.id.uuidString])
    XCTAssertEqual(Array(state.settling.keys), [])
  }
}
