import XCTest

/// Mindloom on the Apple Watch simulator (WATCH-001, WATCH-002, WATCH-003, WATCH-006): tap to
/// record, tap to stop, the recording waits on the watch; a recording longer than a part goes on in
/// the next part; the quick starts begin recording at once, in a running app and from a cold
/// launch.
///
/// The quick starts are simulated: neither `XCUIApplication.open(_:)` nor `simctl openurl` opens
/// `mindloom://record` on the watchOS 26.5 simulator, and a control or Siri cannot be driven from a
/// test. The DEBUG hooks (`DebugStarts`) call exactly what the app runs once the system hands the
/// link or the intent over (`WatchModel.open(_:)`, `RecordRequest.post()`); the system's own
/// delivery is checked on the real watch.
///
/// The microphone is never used: `-MindloomWatchFakeRecording 1` writes a synthetic tone instead.
final class MindloomWatchUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  private func launch(_ extra: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-MindloomWatchFakeRecording", "1"] + extra
    app.launch()
    return app
  }

  /// What the status line may say once a recording stopped: on its way (the paired iPhone is in
  /// reach), waiting on the watch (it is not), or already stored on the iPhone.
  private func assertStatusAfterStop(_ app: XCUIApplication) {
    let status = app.staticTexts["watch.status"]
    XCTAssertTrue(status.waitForExistence(timeout: 5))
    let label = status.label
    XCTAssertTrue(
      label == "正在发送到 iPhone…" || label.hasSuffix("个录音尚未发送到 iPhone")
        || label == "已发送到 iPhone",
      "status after stopping: \(label)")
  }

  private func waiting(_ app: XCUIApplication) -> Int {
    Int((app.staticTexts["watch.status"].value as? String) ?? "") ?? -1
  }

  func testTapToRecordAndTapToStop() throws {
    let app = launch()
    let button = app.buttons["watch.record"]
    XCTAssertTrue(button.waitForExistence(timeout: 10))
    XCTAssertEqual(button.label, "录音")
    button.tap()

    let elapsed = app.staticTexts["watch.elapsed"]
    XCTAssertTrue(elapsed.waitForExistence(timeout: 5), "recording shows the time")
    XCTAssertEqual(app.staticTexts["watch.status"].label, "正在录制")
    XCTAssertTrue(wait(button, label: "停止"))
    sleep(2)
    button.tap()

    XCTAssertTrue(wait(button, label: "录音"), "back to record")
    assertStatusAfterStop(app)
    attach(app, "after-stop")
  }

  /// Posts one of the DEBUG Darwin notifications the app listens to (`DebugStarts`).
  private func post(_ name: String) {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil,
      true)
  }

  private func assertQuickStartRecords(_ app: XCUIApplication, _ what: String) {
    XCTAssertTrue(app.staticTexts["watch.elapsed"].waitForExistence(timeout: 10), what)
    let button = app.buttons["watch.record"]
    XCTAssertTrue(wait(button, label: "停止"))
    button.tap()
    XCTAssertTrue(wait(button, label: "录音"))
  }

  /// The complication's link in a running app (simulated: `WatchModel.open(_:)`, as `onOpenURL`).
  func testComplicationLinkStartsRecordingInARunningApp() throws {
    let app = launch()
    XCTAssertTrue(app.buttons["watch.record"].waitForExistence(timeout: 10))
    post("app.mindloom.watchkitapp.debug.open-record")
    assertQuickStartRecords(app, "the link records at once")
  }

  /// The complication's link from a cold launch (simulated: the link handed over before the app
  /// is active; recording starts once it is).
  func testComplicationLinkStartsRecordingFromAColdLaunch() throws {
    let app = launch(["-MindloomWatchOpenURL", "mindloom://record"])
    assertQuickStartRecords(app, "a cold launch from the link records")
  }

  /// The control, Siri and Shortcuts (simulated: `RecordRequest.post()`, the body of
  /// `StartRecordingIntent.perform`).
  func testTheIntentStartsRecording() throws {
    let app = launch()
    XCTAssertTrue(app.buttons["watch.record"].waitForExistence(timeout: 10))
    post("app.mindloom.watchkitapp.debug.intent-record")
    assertQuickStartRecords(app, "the intent records at once")
  }

  /// WATCH-002: at the part limit (2 s here, 30 minutes on a watch) the recording goes on in the
  /// next part without a tap; each part is kept.
  func testALongRecordingGoesOnInTheNextPart() throws {
    let app = launch(["-MindloomWatchPartSeconds", "2"])
    let button = app.buttons["watch.record"]
    XCTAssertTrue(button.waitForExistence(timeout: 10))
    sleep(1)
    let before = waiting(app)
    XCTAssertGreaterThanOrEqual(before, 0)
    button.tap()
    XCTAssertTrue(wait(button, label: "停止"))
    sleep(5)
    XCTAssertEqual(button.label, "停止", "still recording after the part limit")
    XCTAssertEqual(app.staticTexts["watch.status"].label, "正在录制")
    button.tap()
    XCTAssertTrue(wait(button, label: "录音"))
    sleep(1)
    let after = waiting(app)
    // Two parts or more were kept (unless the paired iPhone already stored them).
    XCTAssertTrue(
      after - before >= 2 || app.staticTexts["watch.status"].label == "已发送到 iPhone",
      "before \(before), after \(after)")
  }

  private func wait(_ element: XCUIElement, label: String, timeout: TimeInterval = 5) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", label), object: element)
    return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
  }

  private func attach(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}
