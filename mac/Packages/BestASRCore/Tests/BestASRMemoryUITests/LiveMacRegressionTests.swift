import AppKit
import BestASRDomain
import BestASRMemory
import MindloomSpaces
import XCTest

@testable import BestASRMemoryUI

/// What the live run of the real App on the real-shaped preview root showed
/// (v11 live-mac, /Users/Shared/mindloom-demo/v11/notes/live-mac.md), kept
/// fixed here. Synthetic data only.
@MainActor
final class LiveMacRegressionTests: XCTestCase {
  /// On Saturday 10月3日 the clamped 「9月14日」 touched 「9月21日」.
  func testAxisLeavesOutAClampedLabelThatWouldTouchItsNeighbour() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let saturday = ISO8601DateFormatter().date(from: "2026-10-03T10:00:00+08:00")!
    let labels = HomeTrackWindow.axis(HomeDays(today: saturday, calendar: calendar))
    XCTAssertEqual(labels.map(\.text), ["9月21日", "9月28日", "10月12日", "今天"])
    let xs = labels.map(\.x).sorted()
    for (a, b) in zip(xs, xs.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, 46) }
  }

  /// A search hit's line never starts on the punctuation where it was cut.
  func testSearchCutNeverStartsOnPunctuation() {
    let long =
      String(repeating: "甲", count: 39) + "，" + String(repeating: "乙", count: 19) + "穹顶"
      + String(repeating: "丙", count: 100)
    let cut = HomeSearch.cut(long, "穹顶")
    // No 「…」 (§2.3): the view fades the cut start in instead.
    XCTAssertFalse(cut.hasPrefix("…"))
    XCTAssertTrue(HomeSearch.isCut(long, "穹顶"))
    XCTAssertFalse(cut.first?.isPunctuation ?? true)
    XCTAssertTrue(cut.contains("穹顶"))
  }

  /// A group made a moment ago flashed 「这个分组已经删掉了」: the App read the
  /// new group at once but the page state carried the user's organizing from
  /// the last (debounced) read-model build. The latest read is laid over it.
  func testANewGroupOpensToItsEmptyPageBeforeTheReadModelIsRebuilt() {
    let derived = MemoryScreenState(user: .empty)
    let made = Date(timeIntervalSince1970: 1_790_000_000)
    let group = UserGroup(id: UUID(), name: "实验室", sortOrder: 0, createdAt: made, updatedAt: made)
    let id = group.id.uuidString.lowercased()
    XCTAssertEqual(GroupPage.content(derived, groupID: id), .gone)

    var shown = derived
    shown.overlayUser(UserOrganizingSnapshot(groups: [group]))
    XCTAssertEqual(GroupPage.content(shown, groupID: id), .empty)
    XCTAssertEqual(GroupPage.content(shown, groupID: id.uppercased()), .empty)
    XCTAssertEqual(shown.groups.map(\.name), ["实验室"])

    // Deleting it still shows the page as gone.
    shown.overlayUser(.empty)
    XCTAssertEqual(GroupPage.content(shown, groupID: id), .gone)
  }

  /// ⌘F (and only ⌘F) goes to the search field before the system's 查找…,
  /// which came back with 拼写和语法 and 替换 in the 编辑 menu.
  func testFindShortcutIsExactlyCommandF() {
    XCTAssertTrue(
      MindloomFindShortcut.isFind(modifierFlags: .command, charactersIgnoringModifiers: "f"))
    XCTAssertTrue(
      MindloomFindShortcut.isFind(
        modifierFlags: [.command, .capsLock], charactersIgnoringModifiers: "F"))
    for flags: NSEvent.ModifierFlags in [[.command, .shift], [.command, .option], [.command, .control], []] {
      XCTAssertFalse(MindloomFindShortcut.isFind(modifierFlags: flags, charactersIgnoringModifiers: "f"))
    }
    XCTAssertFalse(MindloomFindShortcut.isFind(modifierFlags: .command, charactersIgnoringModifiers: "g"))
    XCTAssertTrue(MindloomFindShortcut.showsFindInterface(tag: 1))
    XCTAssertFalse(MindloomFindShortcut.showsFindInterface(tag: 2))
    // Not while a sheet is open on the window (review finish-ship).
    XCTAssertTrue(MindloomFindShortcut.mayFocusSearch(sheetOpen: false))
    XCTAssertFalse(MindloomFindShortcut.mayFocusSearch(sheetOpen: true))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    XCTAssertTrue(MindloomFindShortcut.mayFocusSearch(in: window))
  }

  /// macOS 27 hides menu item images unless asked: window menus ask, and the
  /// destructive items are vermilion with their icon (§7.5).
  func testWindowMenusShowIconsAndPaintDestructiveItems() {
    let menu = NSMenu()
    let pin = NSMenuItem(title: "置顶", action: nil, keyEquivalent: "")
    pin.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
    let delete = NSMenuItem(title: "删除…", action: nil, keyEquivalent: "")
    delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
    let leave = NSMenuItem(title: "退出共享空间", action: nil, keyEquivalent: "")
    menu.addItem(pin)
    menu.addItem(.separator())
    menu.addItem(delete)
    menu.addItem(leave)
    MindloomMenuStyle.style(menu)
    if #available(macOS 27.0, *) {
      XCTAssertEqual(pin.preferredImageVisibility, .visible)
      XCTAssertEqual(delete.preferredImageVisibility, .visible)
    }
    XCTAssertNil(pin.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil))
    XCTAssertNotNil(delete.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil))
    XCTAssertNotNil(leave.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil))
    XCTAssertEqual(delete.title, "删除…")
    XCTAssertTrue(MindloomMenuStyle.isDestructive("删除分组"))
    XCTAssertFalse(MindloomMenuStyle.isDestructive("不属于这件事"))
    XCTAssertFalse(MindloomMenuStyle.isDestructive("拷贝"))
    // A group or space the user named like a destructive action is not one
    // (review finish-ship): exact titles only.
    XCTAssertTrue(MindloomMenuStyle.isDestructive("退出共享空间"))
    XCTAssertFalse(MindloomMenuStyle.isDestructive("删除旧数据"))
    XCTAssertFalse(MindloomMenuStyle.isDestructive("删除"))
    let named = NSMenuItem(title: "删除旧数据", action: nil, keyEquivalent: "")
    named.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
    let groups = NSMenu()
    groups.addItem(named)
    MindloomMenuStyle.style(groups)
    XCTAssertNil(named.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil))
    XCTAssertFalse(named.image is MindloomMenuStyle.TintedImage)
  }

  /// 原文 item › 复制 copies the item's words, a line per speaker line.
  func testItemCopyIsItsWordsWithSpeakers() {
    let lines = [
      MemoryQuoteLine(speaker: "顾安", words: "周五前把数据跑完"),
      MemoryQuoteLine(speaker: "", words: "好的"),
    ]
    XCTAssertEqual(MatterTextItem.plainText(lines), "顾安：周五前把数据跑完\n好的")
  }

  /// 「退出这个共享空间」 by a space's owner crashed the App: the refusal
  /// table listed `last_admin` twice, and a dictionary literal with a repeated
  /// key traps. Reading the table at all is the regression check.
  func testRefusalWordsHaveOneEntryPerCode() {
    XCTAssertEqual(SpaceRefusalWords.text("owner_cannot_leave"), "所有者无法退出自己的空间")
    XCTAssertEqual(SpaceRefusalWords.text("last_admin"), "至少需要保留一位管理员")
    XCTAssertEqual(SpaceRefusalWords.text("no_such_code"), "DGX Spark 未接受（no_such_code）")
    XCTAssertGreaterThan(SpaceRefusalWords.words.count, 30)
  }

  /// The live share run listed the shared matter twice on the space page:
  /// mine, and the space's copy of it (its package, other ID, same items).
  func testSpacePageListsMySharedMatterOnce() {
    let mine: Set<String> = ["A1", "B2", "C3"]
    XCTAssertTrue(SpacePageModel.isCopy(itemIDs: ["a1", "B2"], ofMine: mine))
    XCTAssertFalse(SpacePageModel.isCopy(itemIDs: ["A1", "Z9"], ofMine: mine))
    XCTAssertFalse(SpacePageModel.isCopy(itemIDs: [], ofMine: mine))
  }

  /// review finish-ship: the owner of a space is not offered
  /// 「退出这个共享空间」 (the DGX Spark refuses it and cannot delete a space).
  func testTheOwnerIsNotOfferedToLeaveTheSpace() throws {
    func member(_ id: String, owner: Bool) throws -> SpaceMember {
      let json = """
        {"member_id":"\(id)","role":"admin","outside":false,"status":"active",
         "owner":\(owner),"org_admin":false,"devices":[]}
        """
      let record = try JSONDecoder().decode(SpaceMemberRecord.self, from: Data(json.utf8))
      return SpaceMember(record: record, displayName: nil)
    }
    let members = [try member("m-owner", owner: true), try member("m-guest", owner: false)]
    XCTAssertTrue(SpaceMoreMenu.youOwn(memberID: "m-owner", members: members))
    XCTAssertFalse(SpaceMoreMenu.youOwn(memberID: "m-guest", members: members))
    XCTAssertFalse(SpaceMoreMenu.youOwn(memberID: nil, members: members))
  }
}
