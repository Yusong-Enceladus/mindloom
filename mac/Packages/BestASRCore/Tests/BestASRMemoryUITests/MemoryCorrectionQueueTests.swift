import BestASRDomain
import BestASRMemory
import SwiftUI
import XCTest

@testable import BestASRMemoryUI

/// The undo window (MAC-SPEC §5.7, v11 decisions): held 8 s then sent; undo
/// while held sends nothing; ⌘Z after sends the inverse; quit commits what
/// is held. Driven by a hand-cranked clock.
@MainActor
final class MemoryCorrectionQueueTests: XCTestCase {
  /// Scheduled calls, run by `advance`.
  private final class Clock {
    var time: TimeInterval = 0
    var timers: [(at: TimeInterval, id: Int, work: @MainActor () -> Void)] = []
    var cancelled = Set<Int>()
    var next = 0

    @MainActor
    func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void)
      -> MemoryCorrectionQueue.Scheduled
    {
      next += 1
      let id = next
      timers.append((time + delay, id, work))
      return MemoryCorrectionQueue.Scheduled { [weak self] in self?.cancelled.insert(id) }
    }

    @MainActor
    func advance(_ seconds: TimeInterval) {
      time += seconds
      let due = timers.filter { $0.at <= time && !cancelled.contains($0.id) }
      timers.removeAll { $0.at <= time }
      for timer in due { timer.work() }
    }
  }

  private var sent: [MemoryCorrection] = []
  private let move = MemoryCorrection.moveItem(itemID: "i1", segID: nil, from: "E6", to: "E45")

  private func queue(_ clock: Clock) -> MemoryCorrectionQueue {
    MemoryCorrectionQueue(schedule: { clock.schedule($0, $1) }) { [weak self] correction in
      self?.sent.append(correction)
    }
  }

  /// Lets the queue's send tasks run.
  private func settle() async {
    for _ in 0..<5 { await Task.yield() }
  }

  func testAHeldCorrectionGoesAfterEightSeconds() async {
    let clock = Clock()
    let queue = queue(clock)
    queue.submit(move)
    XCTAssertEqual(queue.held, [move], "shown at once")
    XCTAssertEqual(queue.undoState, MemoryUndoState(label: "移动", pending: true))
    clock.advance(7.9)
    await settle()
    XCTAssertEqual(sent, [], "nothing leaves the Mac inside the window")
    clock.advance(0.2)
    await settle()
    XCTAssertEqual(sent, [move])
    XCTAssertEqual(queue.held, [])
    XCTAssertEqual(queue.undoState, MemoryUndoState(label: "移动", pending: false))
  }

  func testUndoInsideTheWindowSendsNothing() async {
    let clock = Clock()
    let queue = queue(clock)
    queue.submit(move)
    XCTAssertEqual(queue.undo(), move)
    clock.advance(10)
    await settle()
    XCTAssertEqual(sent, [])
    XCTAssertNil(queue.undoState)
    XCTAssertNil(queue.undo(), "one slot, now empty")
  }

  func testUndoAfterTheWindowSendsTheInverse() async {
    let clock = Clock()
    let queue = queue(clock)
    queue.submit(move)
    clock.advance(8)
    await settle()
    queue.undo()
    await settle()
    XCTAssertEqual(sent, [move, move.inverse!])
  }

  func testLocalCorrectionsGoAtOnceAndUndoWithTheirInverse() async {
    let clock = Clock()
    let queue = queue(clock)
    let mark = MemoryCorrection.markStep(eventID: "E6", stepID: "st1", state: .done, previous: nil)
    queue.submit(mark)
    await settle()
    XCTAssertEqual(sent, [mark])
    XCTAssertEqual(queue.undoState?.menuTitle, "撤销标记为完成")
    queue.undo()
    await settle()
    XCTAssertEqual(sent.last, mark.inverse)
    // A pin goes at once and is not in the undo slot.
    queue.submit(.pin(eventID: "E6", pinned: true))
    XCTAssertNil(queue.undoState)
  }

  func testADeleteIsUndoableOnlyWhileHeld() async {
    let clock = Clock()
    let queue = queue(clock)
    queue.submit(.delete(eventID: "E6", title: "TES"))
    XCTAssertEqual(queue.undoState?.label, "删除")
    clock.advance(8)
    await settle()
    XCTAssertNil(queue.undoState, "no way back once sent")
  }

  func testHoveringTheToastHoldsTheCorrection() async {
    let clock = Clock()
    let queue = queue(clock)
    let entry = queue.submit(move)
    clock.advance(5)
    queue.pause(entry.id)
    clock.advance(20)
    await settle()
    XCTAssertEqual(sent, [])
    queue.resume(entry.id)
    clock.advance(2.3)
    await settle()
    XCTAssertEqual(sent, [])
    clock.advance(0.2)
    await settle()
    XCTAssertEqual(sent, [move])
  }

  func testQuitCommitsWhatIsHeld() async {
    let clock = Clock()
    let queue = queue(clock)
    let rename = MemoryCorrection.rename(eventID: "E6", from: "a", to: "b")
    queue.submit(move)
    queue.submit(rename)
    await queue.commitAll()
    XCTAssertEqual(sent, [move, rename])
    XCTAssertEqual(queue.held, [])
    clock.advance(10)
    await settle()
    XCTAssertEqual(sent.count, 2, "a timer firing later sends nothing twice")
  }

  func testCorrectionToasts() {
    let id = UUID()
    let titles = ["E45": "博士中期考核与答辩准备工作安排"]
    let toast = MemoryCorrectionToast.toast(for: move, id: id, titles: titles, groups: [:])
    XCTAssertEqual(toast?.text, "已移到“博士中期考核与答辩准备工作安排”")
    XCTAssertEqual(toast?.id, id)
    XCTAssertEqual(toast?.action, .undo)
    XCTAssertEqual(MemoryCorrectionToast.short("一二三四五六七八九十一二三四五六七"), "一二三四五六七八九十一二三四五…")
    XCTAssertEqual(
      MemoryCorrectionToast.toast(
        for: .group(eventID: "E6", from: "g1", to: "g2"), id: id, titles: [:],
        groups: ["g1": "论文", "g2": "生活"])?.text, "已从“论文”移到“生活”")
    XCTAssertNil(
      MemoryCorrectionToast.toast(for: .pin(eventID: "E6", pinned: true), id: id, titles: [:], groups: [:]))
  }
}

/// The navigator's rules (MAC-SPEC §5.1).
@MainActor
final class MindloomNavigatorTests: XCTestCase {
  private var navigation = MemoryNavigation()

  private var navigator: MindloomNavigator {
    MindloomNavigator(
      Binding(get: { self.navigation }, set: { self.navigation = $0 }), reduceMotion: true)
  }

  func testOpeningAndGoingBack() {
    navigator.openRoot(.group("g1"))
    navigator.openMatter("E6", step: "st1")
    XCTAssertEqual(navigation.top, .matter("E6"))
    XCTAssertEqual(navigation.popover, .step("st1"))
    XCTAssertEqual(navigation.backTarget, .group("g1"))
    navigator.setTab(.text)
    XCTAssertNil(navigation.popover)
    navigator.openMatter("E45")
    XCTAssertEqual(navigation.matterTab, .progress, "another matter opens on 进展")
    XCTAssertEqual(navigation.backTarget, .matter("E6"))
    navigator.back()
    navigator.back()
    XCTAssertEqual(navigation.top, .group("g1"))
    navigator.openMatter("E6", revealRow: "item#s1")
    XCTAssertEqual(navigation.matterTab, .text, "打开原文 opens 原文")
  }

  func testSearchReplacesThePageAndEscReturns() {
    navigator.openRoot(.group("g1"))
    navigator.setSearch("雨")
    XCTAssertEqual(navigation.top, .search)
    navigator.setSearch("雨桐")
    navigator.openMatter("E6")
    XCTAssertEqual(navigation.backTarget, .search)
    navigator.back()
    navigator.clearSearch()
    XCTAssertEqual(navigation.top, .group("g1"))
    XCTAssertEqual(navigation.search, "")
  }

  func testLensesAndSidebar() {
    navigator.openMatter("E6")
    navigator.setHomeLens(.deadlines)
    XCTAssertEqual(navigation.top, .home)
    XCTAssertEqual(navigation.scrollKey, "home:deadlines")
    navigator.setListLens(.people)
    XCTAssertEqual(navigation.listLens, .time, "a group or space has no 按人")
    navigator.setSearch("x")
    navigator.openRoot(.space("sp1"))
    XCTAssertEqual(navigation.search, "", "the sidebar clears the query")
    XCTAssertEqual(navigation.top, .space("sp1"))
  }
}
