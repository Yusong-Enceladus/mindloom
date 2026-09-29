import AppKit
import XCTest

@testable import BestASRDelivery

/// Verifies read notification and waiter ownership. A request alone does
/// not establish which consumer read the pasteboard or whether text landed.
final class PasteboardPromiseTests: XCTestCase {
  private func privatePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("bestASR.tests.\(UUID().uuidString)"))
  }

  func testWritingAndListingAreNotRequestsButReadingIs() {
    let promise = PromisedPasteboardText("dictated")
    let pasteboard = privatePasteboard()
    defer { pasteboard.releaseGlobally() }
    XCTAssertTrue(promise.write(to: pasteboard))
    let posted = Date()
    XCTAssertFalse(promise.requested(after: posted), "Writing the promise is not a request")
    _ = pasteboard.types
    XCTAssertFalse(promise.requested(after: posted), "Listing the types is not a request")
    XCTAssertEqual(pasteboard.string(forType: .string), "dictated")
    XCTAssertTrue(promise.requested(after: posted), "Reading the text is")
  }

  /// Reads before the keystroke are excluded. Reads after it can still come
  /// from another consumer; this timestamp does not establish target identity.
  func testARequestBeforeTheKeystrokeDoesNotCount() {
    let promise = PromisedPasteboardText("dictated")
    let pasteboard = privatePasteboard()
    defer { pasteboard.releaseGlobally() }
    XCTAssertTrue(promise.write(to: pasteboard))
    _ = pasteboard.string(forType: .string)
    XCTAssertFalse(promise.requested(after: Date().addingTimeInterval(0.01)))
  }

  func testMaterializingTheOfferKeepsAPendingConsumersItemValid() throws {
    let pasteboard = privatePasteboard()
    defer { pasteboard.releaseGlobally() }
    let promise = PromisedPasteboardText("dictated")
    let offered = try XCTUnwrap(promise.offer(to: pasteboard))
    let consumerItem = try XCTUnwrap(pasteboard.pasteboardItems?.first)
    let ownership = pasteboard.changeCount
    XCTAssertTrue(offered.setString("dictated", forType: .string))
    XCTAssertEqual(pasteboard.changeCount, ownership)
    XCTAssertEqual(consumerItem.string(forType: .string), "dictated")
    XCTAssertEqual(pasteboard.string(forType: .string), "dictated")
  }

  func testMaterializingAStaleOfferDoesNotReplaceANewerClipboard() throws {
    let pasteboard = privatePasteboard()
    defer { pasteboard.releaseGlobally() }
    let offered = try XCTUnwrap(PromisedPasteboardText("dictated").offer(to: pasteboard))
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString("a newer user copy", forType: .string))
    let ownership = pasteboard.changeCount
    XCTAssertFalse(offered.setString("dictated", forType: .string))
    XCTAssertEqual(pasteboard.changeCount, ownership)
    XCTAssertEqual(pasteboard.string(forType: .string), "a newer user copy")
  }

  func testWaitingResolvesWhenTheTextIsTaken() async {
    let promise = PromisedPasteboardText("dictated")
    let name = NSPasteboard.Name("bestASR.tests.\(UUID().uuidString)")
    XCTAssertTrue(promise.write(to: NSPasteboard(name: name)))
    let posted = Date()
    let reader = Task.detached {
      try? await Task.sleep(for: .milliseconds(60))
      return NSPasteboard(name: name).string(forType: .string)
    }
    let started = Date()
    let taken = await promise.awaitRequest(after: posted, timeout: 2)
    XCTAssertTrue(taken)
    XCTAssertLessThan(Date().timeIntervalSince(started), 1, "Resolves on the read, not the timeout")
    let read = await reader.value
    XCTAssertEqual(read, "dictated")
    NSPasteboard(name: name).releaseGlobally()
  }

  func testWaitingGivesUpAtTheDeadlineWhenNothingAsks() async {
    let promise = PromisedPasteboardText("dictated")
    let pasteboard = privatePasteboard()
    defer { pasteboard.releaseGlobally() }
    XCTAssertTrue(promise.write(to: pasteboard))
    let started = Date()
    let taken = await promise.awaitRequest(after: Date(), timeout: 0.1)
    XCTAssertFalse(taken)
    XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.09)
  }

  func testRequestImmediatelyBeforeWaiterInstallationIsNotLost() async {
    let promise = PromisedPasteboardText("dictated")
    let name = "bestASR.tests.\(UUID().uuidString)"
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
    defer { pasteboard.releaseGlobally() }
    XCTAssertTrue(promise.write(to: pasteboard))
    let posted = Date()
    let taken = await promise.awaitRequest(
      after: posted, timeout: 0.1,
      beforeInstallingWaiter: {
        // Reproduce a provider callback in the former check/install gap,
        // synchronously: no timing or run-loop race is needed for this test.
        let item = NSPasteboardItem()
        promise.pasteboard(
          NSPasteboard(name: NSPasteboard.Name(name)),
          item: item, provideDataForType: .string)
        XCTAssertEqual(item.string(forType: .string), "dictated")
      }
    )
    XCTAssertTrue(promise.requested(after: posted))
    XCTAssertTrue(taken, "A request already observed at registration must not wait for a timeout")
  }

  func testCancellationBeforeInstallationCompletesWithoutARequest() async {
    let promise = PromisedPasteboardText("dictated")
    let pasteboard = privatePasteboard()
    defer { pasteboard.releaseGlobally() }
    XCTAssertTrue(promise.write(to: pasteboard))
    let reachedWait = expectation(description: "cancelled wait returned")
    let task = Task {
      // Stay suspended until the test cancels us, then enter awaitRequest
      // with cancellation already set.
      try? await Task.sleep(for: .seconds(30))
      let taken = await promise.awaitRequest(after: Date(), timeout: 5)
      XCTAssertFalse(taken)
      reachedWait.fulfill()
    }
    task.cancel()
    await fulfillment(of: [reachedWait], timeout: 1)
    await task.value
  }

  func testCancelledWaitDoesNotTimeOutTheNextWait() async {
    let promise = PromisedPasteboardText("dictated")
    let name = "bestASR.tests.\(UUID().uuidString)"
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
    defer { pasteboard.releaseGlobally() }
    XCTAssertTrue(promise.write(to: pasteboard))
    let registering = expectation(description: "first waiter registering")
    let cancelled = Task {
      await promise.awaitRequest(
        after: Date(), timeout: 0.1,
        beforeInstallingWaiter: { registering.fulfill() })
    }
    await fulfillment(of: [registering], timeout: 1)
    cancelled.cancel()
    let cancelledResult = await cancelled.value
    XCTAssertFalse(cancelledResult)

    let posted = Date()
    let reader = Task {
      try? await Task.sleep(for: .milliseconds(200))
      let item = NSPasteboardItem()
      promise.pasteboard(
        NSPasteboard(name: NSPasteboard.Name(name)),
        item: item, provideDataForType: .string)
      return item.string(forType: .string)
    }
    let taken = await promise.awaitRequest(after: posted, timeout: 2)
    XCTAssertTrue(taken, "An earlier wait's timeout must not complete this wait")
    let read = await reader.value
    XCTAssertEqual(read, "dictated")
  }

  func testRequestAfterTimeoutStillServesDataWithoutCompletingTwice() async {
    let promise = PromisedPasteboardText("dictated")
    let pasteboard = privatePasteboard()
    defer { pasteboard.releaseGlobally() }
    XCTAssertTrue(promise.write(to: pasteboard))
    let posted = Date()
    let timedOut = await promise.awaitRequest(after: posted, timeout: 0.01)
    XCTAssertFalse(timedOut)
    let item = NSPasteboardItem()
    promise.pasteboard(pasteboard, item: item, provideDataForType: .string)
    XCTAssertEqual(item.string(forType: .string), "dictated")
    let requested = await promise.awaitRequest(after: posted, timeout: 0.01)
    XCTAssertTrue(requested)
  }

  func testTheUsersClipboardComesBackItemForItem() {
    let pasteboard = privatePasteboard()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("theirs", forType: .string)
    let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
    XCTAssertTrue(PromisedPasteboardText("ours").write(to: pasteboard))
    XCTAssertTrue(snapshot.restore(to: pasteboard))
    XCTAssertEqual(pasteboard.string(forType: .string), "theirs")
  }

  func testConfirmedDeliveryRestoresOnlyItsOwnClipboardOffer() throws {
    let pasteboard = privatePasteboard()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString("original user copy", forType: .string))
    let prior = PasteboardSnapshot(pasteboard: pasteboard)
    let offer = try XCTUnwrap(PromisedPasteboardText("dictated").offer(to: pasteboard))
    let ownership = pasteboard.changeCount
    _ = offer.string(forType: .string)
    XCTAssertTrue(prior.restore(to: pasteboard, ifOwnedBy: ownership))
    XCTAssertEqual(pasteboard.string(forType: .string), "original user copy")
  }

  func testConfirmedDeliveryDoesNotOverwriteACopyMadeDuringFieldVerification() throws {
    let pasteboard = privatePasteboard()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString("original user copy", forType: .string))
    let prior = PasteboardSnapshot(pasteboard: pasteboard)
    let offer = try XCTUnwrap(PromisedPasteboardText("dictated").offer(to: pasteboard))
    let ownership = pasteboard.changeCount
    _ = offer.string(forType: .string)
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString("newer user copy", forType: .string))
    let newerOwnership = pasteboard.changeCount
    XCTAssertFalse(prior.restore(to: pasteboard, ifOwnedBy: ownership))
    XCTAssertEqual(pasteboard.changeCount, newerOwnership)
    XCTAssertEqual(pasteboard.string(forType: .string), "newer user copy")
  }
}
