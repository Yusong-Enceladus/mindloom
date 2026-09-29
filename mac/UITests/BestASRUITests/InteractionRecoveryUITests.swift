import AppKit
import XCTest

@MainActor
final class InteractionRecoveryUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testDictionaryWordsStayStillThroughSingleMultipleAndCancelledSelection() {
    let app = launchFixture(dictionary: true)
    let window = minimumWindow(in: app)
    let words = dictionaryWords(in: app)
    XCTAssertTrue(words.firstMatch.waitForExistence(timeout: 5))
    XCTAssertEqual(words.count, 6)
    let originalFrames = frames(of: words)
    let first = words.element(boundBy: 0)
    let second = words.element(boundBy: 1)
    let count = app.staticTexts["bestASR.dictionary.selectionCount"]

    XCTAssertFalse(count.exists)
    attachWindow(window, named: "Dictionary — no selection")
    first.click()
    assertText("已选 1 个词", in: count)
    assertFrames(originalFrames, in: words)
    XCTAssertTrue(app.buttons["bestASR.dictionary.editSelected"].isEnabled)
    attachWindow(window, named: "Dictionary — one selected word")

    second.click()
    assertText("已选 2 个词", in: count)
    assertFrames(originalFrames, in: words)
    XCTAssertFalse(app.buttons["bestASR.dictionary.editSelected"].isEnabled)

    app.buttons["bestASR.dictionary.clearSelection"].click()
    assertAbsent(count)
    assertFrames(originalFrames, in: words)
    XCTAssertTrue(app.buttons["bestASR.dictionary.transfer"].isHittable)

    second.click()
    assertText("已选 1 个词", in: count)
    app.typeKey(.escape, modifierFlags: [])
    assertAbsent(count)
    assertFrames(originalFrames, in: words)
    for word in words.allElementsBoundByIndex {
      assertVisible(word, inside: window)
    }
  }

  func testDictionaryTransferIsAPageAndReturnsToTheSameWordLayout() {
    let app = launchFixture(dictionary: true)
    let window = minimumWindow(in: app)
    let words = dictionaryWords(in: app)
    XCTAssertTrue(words.firstMatch.waitForExistence(timeout: 5))
    let originalFrames = frames(of: words)
    let menuCount = app.menus.count
    let transfer = app.buttons["bestASR.dictionary.transfer"]
    XCTAssertTrue(transfer.isHittable)
    transfer.click()

    let back = app.buttons["bestASR.dictionary.backFromTransfer"]
    XCTAssertTrue(back.waitForExistence(timeout: 3))
    for identifier in [
      "bestASR.dictionary.backFromTransfer", "bestASR.dictionary.import",
      "bestASR.dictionary.export",
    ] {
      assertVisible(app.buttons[identifier], inside: window)
    }
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.dictionary.exportFormat"].exists)
    XCTAssertFalse(app.menuButtons["bestASR.dictionary.exportFormat"].exists)
    XCTAssertEqual(app.menus.count, menuCount, "Transfer must not open a popup menu.")
    XCTAssertFalse(words.firstMatch.exists, "Transfer replaces the word page in place.")

    back.click()
    XCTAssertTrue(transfer.waitForExistence(timeout: 3))
    assertFrames(originalFrames, in: words)
    transfer.click()
    XCTAssertTrue(back.waitForExistence(timeout: 3))
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(transfer.waitForExistence(timeout: 3))
    assertFrames(originalFrames, in: words)
  }

  func testHistoryConditionsUseAStableSearchableInspectorAtMinimumSize() {
    let app = launchFixture()
    let window = minimumWindow(in: app)
    app.buttons["bestASR.sidebar.history"].click()
    let fields = ["mode", "source", "date", "status"]
    let optionButtons = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "bestASR.history.option."))
    let inspector = app.descendants(matching: .any)["bestASR.history.filterInspector"]
    let close = app.buttons["bestASR.history.closeFilters"]
    let sourceSearch = app.textFields["bestASR.history.sourceSearch"]
    let filters = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "bestASR.history.filter."))
    XCTAssertTrue(filters.firstMatch.waitForExistence(timeout: 5))
    XCTAssertEqual(filters.count, 4, "Only four condition summaries belong in the closed bar.")
    XCTAssertEqual(optionButtons.count, 0, "The default page must not expose an option wall.")
    XCTAssertFalse(inspector.exists)
    XCTAssertFalse(app.descendants(matching: .any)["bestASR.history.previousResults"].exists)
    let collapsedFrames = frames(of: filters)
    attachWindow(window, named: "History — closed condition bar")

    app.buttons["bestASR.history.filter.status"].click()
    XCTAssertTrue(inspector.waitForExistence(timeout: 3))
    let openFrame = inspector.frame
    let closeFrame = close.frame
    let openFilterFrames = frames(of: filters)
    attachWindow(window, named: "History — open status inspector")
    for value in ["completed", "all"] {
      let option = app.buttons["bestASR.history.option.status.\(value)"]
      XCTAssertTrue(option.waitForExistence(timeout: 3))
      option.click()
      XCTAssertTrue(option.isSelected)
      assertFrame(openFrame, equals: inspector.frame)
      assertFrame(closeFrame, equals: close.frame)
      assertFrames(openFilterFrames, in: filters)
    }

    app.buttons["bestASR.history.filter.date"].click()
    let today = app.buttons["bestASR.history.option.date.today"]
    XCTAssertTrue(today.waitForExistence(timeout: 3))
    today.click()
    XCTAssertTrue(today.isSelected)
    assertFrame(openFrame, equals: inspector.frame)
    assertFrame(closeFrame, equals: close.frame)
    assertFrames(openFilterFrames, in: filters)
    app.buttons["bestASR.history.option.date.all"].click()

    app.buttons["bestASR.history.filter.source"].click()
    XCTAssertTrue(sourceSearch.waitForExistence(timeout: 3))
    let allSources = app.buttons["bestASR.history.option.source.all"]
    XCTAssertTrue(allSources.exists, "Even an empty fixture must offer all Apps and source search.")
    let sourceOptions = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "bestASR.history.option.source."))
    let sourceCount = sourceOptions.count
    sourceSearch.click()
    sourceSearch.typeText("no-such-source-in-fixture")
    XCTAssertTrue(app.staticTexts["没有匹配的 App"].waitForExistence(timeout: 3))
    XCTAssertEqual(sourceOptions.count, 1)
    sourceSearch.typeKey("a", modifierFlags: .command)
    sourceSearch.typeKey(.delete, modifierFlags: [])
    XCTAssertEqual(sourceOptions.count, sourceCount)
    assertFrame(openFrame, equals: inspector.frame)
    assertFrame(closeFrame, equals: close.frame)
    for field in fields {
      assertVisible(app.buttons["bestASR.history.filter.\(field)"], inside: window)
    }
    assertVisible(close, inside: window)
    assertVisible(sourceSearch, inside: window)

    close.click()
    assertAbsent(inspector)
    XCTAssertEqual(optionButtons.count, 0)
    assertFrames(collapsedFrames, in: filters)
    app.buttons["bestASR.history.filter.date"].click()
    XCTAssertTrue(inspector.waitForExistence(timeout: 3))
    assertFrame(openFrame, equals: inspector.frame)
    close.click()
    assertAbsent(inspector)
    assertFrames(collapsedFrames, in: filters)
  }

  func testSecondarySectionsRemainStableSidebarButtonsWithoutMoreMenu() {
    let app = launchFixture()
    let window = minimumWindow(in: app)
    let sections = ["roomRecording", "systemAudio", "importMedia", "people", "events"]
    let buttons = app.buttons.matching(
      NSPredicate(
        format: "identifier IN %@", sections.map { "bestASR.sidebar.\($0)" }))
    XCTAssertEqual(buttons.count, sections.count)
    let originalFrames = frames(of: buttons)
    let menuCount = app.menus.count
    XCTAssertFalse(app.descendants(matching: .any)["bestASR.sidebar.more"].exists)
    for section in sections {
      let button = app.buttons["bestASR.sidebar.\(section)"]
      assertVisible(button, inside: window)
      button.click()
      assertFrames(originalFrames, in: buttons)
      XCTAssertEqual(app.menus.count, menuCount, "Opening \(section) must navigate without a menu.")
      for item in buttons.allElementsBoundByIndex {
        assertVisible(item, inside: window)
      }
    }
  }

  private func attachWindow(_ window: XCUIElement, named name: String) {
    let attachment = XCTAttachment(screenshot: window.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func launchFixture(dictionary: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing"]
    if dictionary { app.launchArguments.append("--dictionary-ui-testing") }
    app.launch()
    XCTAssertTrue(app.buttons["bestASR.sidebar.history"].waitForExistence(timeout: 5))
    addTeardownBlock { app.terminate() }
    return app
  }

  private func minimumWindow(in app: XCUIApplication) -> XCUIElement {
    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 5))
    // Request a size below the declared 1000 x 680 minimum; macOS clamps it.
    let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
      .withOffset(CGVector(dx: -2, dy: -2))
    let destination = window.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: 800, dy: 500))
    corner.press(forDuration: 0.1, thenDragTo: destination)
    XCTAssertEqual(window.frame.width, 1000, accuracy: 4)
    XCTAssertGreaterThanOrEqual(window.frame.height, 680)
    XCTAssertLessThanOrEqual(window.frame.height, 720)
    return window
  }

  private func dictionaryWords(in app: XCUIApplication) -> XCUIElementQuery {
    app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "bestASR.dictionary.entry."))
  }

  private func frames(of query: XCUIElementQuery) -> [String: CGRect] {
    Dictionary(
      uniqueKeysWithValues: query.allElementsBoundByIndex.map { ($0.identifier, $0.frame) })
  }

  private func assertFrames(
    _ expected: [String: CGRect], in query: XCUIElementQuery,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(query.count, expected.count, file: file, line: line)
    for element in query.allElementsBoundByIndex {
      guard let frame = expected[element.identifier] else {
        XCTFail("Unexpected control \(element.identifier)", file: file, line: line)
        continue
      }
      assertFrame(frame, equals: element.frame, file: file, line: line)
    }
  }

  private func assertFrame(
    _ expected: CGRect, equals actual: CGRect,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, file: file, line: line)
    XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, file: file, line: line)
    XCTAssertEqual(actual.width, expected.width, accuracy: 1, file: file, line: line)
    XCTAssertEqual(actual.height, expected.height, accuracy: 1, file: file, line: line)
  }

  private func assertVisible(
    _ element: XCUIElement, inside window: XCUIElement,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(element.exists, file: file, line: line)
    XCTAssertTrue(element.isHittable, file: file, line: line)
    XCTAssertTrue(
      window.frame.insetBy(dx: -1, dy: -1).contains(element.frame), file: file, line: line)
  }

  private func assertText(_ text: String, in element: XCUIElement) {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@ OR value == %@", text, text), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed)
  }

  private func assertAbsent(_ element: XCUIElement) {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed)
  }
}
