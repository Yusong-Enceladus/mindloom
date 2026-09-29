import AppKit
import XCTest

@MainActor
final class BestASRUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testMenuBarCompletionHandoffExposesTwoDistinctActions() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--ui-testing", "--capture-handoff-ui-testing",
    ]
    app.launch()

    let statusItem = app.descendants(matching: .any)["bestASR.menuBar"]
    XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
    statusItem.click()

    let openRecord = app.buttons["bestASR.menu.handoff.openRecord"]
    let nextCapture = app.buttons["bestASR.menu.handoff.next"]
    XCTAssertTrue(openRecord.waitForExistence(timeout: 3))
    XCTAssertTrue(nextCapture.waitForExistence(timeout: 3))
    XCTAssertNotEqual(openRecord.identifier, nextCapture.identifier)

    nextCapture.click()
    XCTAssertTrue(
      app.buttons["bestASR.menuStartEnd"].waitForExistence(timeout: 3),
      "Dismissing the completed handoff should restore the menu-bar start action."
    )
  }

  func testMenuBarActiveDictationControlsEndAndCancel() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--menu-bar-content-ui-testing"]
    app.launch()

    let start = app.buttons["bestASR.menuStartEnd"]
    XCTAssertTrue(start.waitForExistence(timeout: 5))
    start.click()

    let end = app.buttons["bestASR.menu.dictation.end"]
    let discard = app.buttons["bestASR.menu.dictation.discard"]
    XCTAssertTrue(end.waitForExistence(timeout: 3))
    XCTAssertTrue(discard.waitForExistence(timeout: 3))
    // 继续 appears only for a dictation the system paused by itself, on sleep
    // or when the microphone went away; a running one is never offered 暂停.
    XCTAssertFalse(app.buttons["bestASR.menu.dictation.pauseResume"].exists)
    XCTAssertFalse(app.buttons["bestASR.menu.dictation.resume"].exists)

    discard.click()
    let confirm = app.buttons["bestASR.menu.destructive.confirm"]
    let keep = app.buttons["bestASR.menu.destructive.keep"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 3))
    XCTAssertTrue(keep.waitForExistence(timeout: 3))
    confirm.click()
    XCTAssertTrue(
      app.buttons["bestASR.menuStartEnd"].waitForExistence(timeout: 5),
      "Canceling from the menu bar should restore its idle start action."
    )
  }

  func testLocalHistoryShowsRawPolishedCopyAndRecoverableRetry() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing"]
    app.launch()

    let history = app.descendants(matching: .any)["bestASR.sidebar.history"]
    XCTAssertTrue(history.waitForExistence(timeout: 5))
    history.click()

    let list = app.descendants(matching: .any)["bestASR.history.list"]
    XCTAssertTrue(list.waitForExistence(timeout: 5))
    let rows = historyRows(in: app)
    let completedRow = rows.firstMatch
    XCTAssertTrue(completedRow.waitForExistence(timeout: 5))
    completedRow.click()

    let currentText =
      app.descendants(matching: .any)["bestASR.history.currentText"]
    XCTAssertTrue(currentText.waitForExistence(timeout: 5))
    XCTAssertEqual(currentText.value as? String, "Fixture raw dictation.")

    let rawDisclosure =
      app.descendants(matching: .any)["bestASR.history.rawDisclosure"]
    XCTAssertTrue(rawDisclosure.waitForExistence(timeout: 5))
    rawDisclosure.click()
    let rawText = app.descendants(matching: .any)["bestASR.history.rawText"]
    XCTAssertTrue(rawText.waitForExistence(timeout: 5))
    XCTAssertEqual(rawText.value as? String, "fixture raw dictation")

    let back = app.buttons["bestASR.history.back"]
    XCTAssertTrue(back.waitForExistence(timeout: 2))
    back.click()
    XCTAssertTrue(
      list.waitForExistence(timeout: 5),
      "The detail page must lead back to the History list."
    )
    XCTAssertFalse(currentText.exists)

    let recoveredRow = rows.containing(textPredicate("Recovered fixture.")).firstMatch
    XCTAssertTrue(
      recoveredRow.waitForExistence(timeout: 5),
      "A recovered record must stay listed with its text."
    )
    XCTAssertFalse(
      recoveredRow.descendants(matching: .any)
        .matching(textPredicate("已恢复")).firstMatch.exists,
      "Completed and recovered rows read as plain text, without status words."
    )
    let attentionRows = rows.containing(textPredicate("可恢复"))
    XCTAssertTrue(attentionRows.firstMatch.waitForExistence(timeout: 5))
    XCTAssertEqual(
      attentionRows.count, 2,
      "The failed and the interrupted processing record must each show their status in the row."
    )

    completedRow.hover()
    XCTAssertTrue(
      completedRow.buttons["bestASR.history.play"].waitForExistence(timeout: 2),
      "A row with retained source audio offers playback on hover."
    )
    let copy = completedRow.buttons["bestASR.history.copy"]
    XCTAssertTrue(copy.waitForExistence(timeout: 2))
    copy.click()
    let status = app.staticTexts["bestASR.history.status"]
    XCTAssertTrue(status.waitForExistence(timeout: 2))
    XCTAssertTrue(
      status.waitForValue("已复制所选本地口述", timeout: 2),
      "History copy must complete without freezing the installed UI."
    )

    let recoverableRow = attentionRows.firstMatch
    recoverableRow.hover()
    let details = recoverableRow.buttons["bestASR.history.details"]
    XCTAssertTrue(details.waitForExistence(timeout: 5))
    details.click()
    let retry = app.buttons["bestASR.history.recoverSelected"]
    XCTAssertTrue(retry.waitForExistence(timeout: 5))
    XCTAssertTrue(retry.isEnabled)
    retry.click()
    XCTAssertTrue(back.waitForExistence(timeout: 2))
    back.click()
    XCTAssertTrue(list.waitForExistence(timeout: 5))
    XCTAssertTrue(
      status.waitForValue("测试记录已完成本机恢复", timeout: 2),
      "A recoverable history item must expose and complete its retry action."
    )
  }

  func testLibraryPrimaryControlsRemainInsideMinimumWindow() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--history-playback-ui-testing"]
    app.launch()

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 5))
    let history = app.descendants(matching: .any)["bestASR.sidebar.history"]
    XCTAssertTrue(history.waitForExistence(timeout: 5))
    history.click()

    let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
      .withOffset(CGVector(dx: -2, dy: -2))
    let destination = window.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: 800, dy: 500))
    corner.press(forDuration: 0.1, thenDragTo: destination)
    XCTAssertEqual(window.frame.width, 1000, accuracy: 4)
    XCTAssertGreaterThanOrEqual(window.frame.height, 680)
    XCTAssertLessThanOrEqual(window.frame.height, 720)

    let search = app.textFields["bestASR.history.search"]
    let filters = app.descendants(matching: .any)["bestASR.history.filters"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    XCTAssertTrue(filters.waitForExistence(timeout: 2))
    XCTAssertGreaterThanOrEqual(
      history.frame.minX,
      window.frame.minX,
      "The minimum window must not clip the leading Library navigation control."
    )
    XCTAssertLessThanOrEqual(
      search.frame.maxX,
      window.frame.maxX,
      "The minimum window must not clip the Library search."
    )
    XCTAssertLessThanOrEqual(
      filters.frame.maxX,
      window.frame.maxX,
      "The minimum window must not clip the Library filters."
    )
    let options = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "bestASR.history.option."))
    XCTAssertEqual(options.count, 0, "The closed bar contains summaries, not all filter choices.")
    for field in ["mode", "source", "date", "status"] {
      let summary = app.buttons["bestASR.history.filter.\(field)"]
      XCTAssertTrue(summary.exists)
      XCTAssertTrue(summary.isHittable)
      XCTAssertGreaterThanOrEqual(summary.frame.minX, window.frame.minX)
      XCTAssertLessThanOrEqual(summary.frame.maxX, window.frame.maxX)
    }
    let inspector = app.descendants(matching: .any)["bestASR.history.filterInspector"]
    for (field, value) in [("date", "today"), ("status", "completed")] {
      app.buttons["bestASR.history.filter.\(field)"].click()
      XCTAssertTrue(inspector.waitForExistence(timeout: 2))
      let option = app.buttons["bestASR.history.option.\(field).\(value)"]
      XCTAssertTrue(option.waitForExistence(timeout: 2))
      XCTAssertTrue(option.isHittable, "Filter choices must be directly available in the page.")
      option.click()
      XCTAssertTrue(option.isSelected, "Filters apply immediately after selection.")
      app.buttons["bestASR.history.option.\(field).all"].click()
    }
    app.buttons["bestASR.history.filter.source"].click()
    let sourceSearch = app.textFields["bestASR.history.sourceSearch"]
    XCTAssertTrue(sourceSearch.waitForExistence(timeout: 2))
    XCTAssertTrue(sourceSearch.isHittable)
    XCTAssertGreaterThanOrEqual(inspector.frame.minX, window.frame.minX)
    XCTAssertLessThanOrEqual(inspector.frame.maxX, window.frame.maxX)
    XCTAssertLessThanOrEqual(inspector.frame.maxY, window.frame.maxY)
    XCTAssertLessThanOrEqual(sourceSearch.frame.maxX, window.frame.maxX)
    XCTAssertTrue(app.buttons["bestASR.history.option.source.all"].isHittable)
    XCTAssertFalse(app.menuButtons["筛选"].exists, "Filter choices use the page inspector.")
    XCTAssertFalse(
      app.buttons["应用筛选"].exists,
      "Filters apply immediately; there must be no separate apply step."
    )
    app.buttons["bestASR.history.closeFilters"].click()
    XCTAssertFalse(inspector.exists)
    XCTAssertEqual(options.count, 0)

    let row = historyRows(in: app).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    row.click()
    let readingPane = app.scrollViews["bestASR.history.readingPane"]
    XCTAssertTrue(readingPane.waitForExistence(timeout: 5))
    let titleEditor = app.textFields["bestASR.history.title"]
    XCTAssertFalse(titleEditor.exists, "Browsing a transcript must not start a title form.")
    let rename = app.buttons["bestASR.history.rename"]
    XCTAssertTrue(rename.isHittable)
    rename.click()
    XCTAssertTrue(titleEditor.waitForExistence(timeout: 2))
    app.buttons["bestASR.history.cancelTitle"].click()
    XCTAssertFalse(titleEditor.exists)
    XCTAssertTrue(app.buttons["bestASR.history.playPause"].isHittable)
    XCTAssertGreaterThanOrEqual(
      readingPane.frame.height, 260,
      "The page heading and fixed player must leave useful space for reading."
    )
    app.radioButtons["整理"].click()
    XCTAssertGreaterThanOrEqual(readingPane.frame.height, 260)
    XCTAssertTrue(app.buttons["bestASR.history.playPause"].isHittable)

    let back = app.buttons["bestASR.history.back"]
    XCTAssertTrue(back.exists)
    XCTAssertTrue(back.isHittable)
    XCTAssertGreaterThanOrEqual(
      back.frame.minX,
      window.frame.minX,
      "The minimum window must not clip the way back to the Library list."
    )
    back.click()
    XCTAssertTrue(filters.waitForExistence(timeout: 2))
    XCTAssertFalse(readingPane.exists, "The list and the reading page are separate pages.")
    row.click()
    XCTAssertTrue(readingPane.waitForExistence(timeout: 5))
    XCTAssertGreaterThanOrEqual(
      readingPane.frame.height, 260,
      "Returning to a record must restore its full reading space."
    )
  }

  func testLibraryRetainedAudioPlaysSeeksAndFollowsTranscript() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--history-playback-ui-testing"]
    app.launch()

    let history = app.descendants(matching: .any)["bestASR.sidebar.history"]
    XCTAssertTrue(history.waitForExistence(timeout: 5))
    history.click()
    let completedRow = historyRows(in: app).firstMatch
    XCTAssertTrue(completedRow.waitForExistence(timeout: 5))
    completedRow.click()

    let waveform = app.descendants(matching: .any)["bestASR.history.waveform"]
    let playbackStatus = app.staticTexts["bestASR.history.playbackStatus"]
    let duration = app.staticTexts["bestASR.history.playbackDuration"]
    let position = app.staticTexts["bestASR.history.playbackPosition"]
    let playPause = app.buttons["bestASR.history.playPause"]
    XCTAssertTrue(waveform.waitForExistence(timeout: 5))
    XCTAssertTrue(
      playbackStatus.waitForValue("本机原音和波形已就绪", timeout: 5)
    )
    XCTAssertTrue(duration.waitForValue("0:32", timeout: 2))
    XCTAssertTrue(playPause.waitForExistence(timeout: 2))

    playPause.click()
    XCTAssertTrue(playPause.waitForLabel("暂停", timeout: 5))
    XCTAssertTrue(position.waitForPlaybackSeconds(atLeast: 1, timeout: 4))
    playPause.click()
    XCTAssertTrue(playPause.waitForLabel("播放", timeout: 3))
    let pausedSeconds = try XCTUnwrap(position.playbackSeconds)
    RunLoop.current.run(until: Date().addingTimeInterval(1.1))
    XCTAssertEqual(position.playbackSeconds, pausedSeconds)

    let forward = app.buttons["bestASR.history.seekForward15"]
    let backward = app.buttons["bestASR.history.seekBackward15"]
    XCTAssertTrue(forward.waitForExistence(timeout: 2))
    XCTAssertTrue(backward.exists)
    forward.click()
    XCTAssertTrue(
      position.waitForPlaybackSeconds(
        atLeast: min(32, pausedSeconds + 15),
        timeout: 3
      )
    )
    let forwardSeconds = try XCTUnwrap(position.playbackSeconds)
    backward.click()
    XCTAssertTrue(
      position.waitForPlaybackSeconds(
        atMost: max(0, forwardSeconds - 15),
        timeout: 3
      )
    )

    forward.click()
    XCTAssertTrue(position.waitForPlaybackSeconds(atLeast: 15, timeout: 3))
    let firstSegment = app.links[
      "bestASR.history.playSegment.43000000-0000-4000-8000-000000000001"
    ]
    XCTAssertTrue(firstSegment.waitForExistence(timeout: 3))
    firstSegment.click()
    XCTAssertTrue(playPause.waitForLabel("暂停", timeout: 5))
    XCTAssertTrue(position.waitForPlaybackSeconds(atMost: 2, timeout: 3))
    playPause.click()
    XCTAssertTrue(playPause.waitForLabel("播放", timeout: 3))

    XCTAssertTrue(
      app.staticTexts["bestASR.history.detailStatus"].firstMatch.waitForValue(
        "已定位到这段逐字稿对应的原音", timeout: 3),
      "Segment feedback describes the location, not a stale playing state after pause."
    )

    let firstSegmentID = "43000000-0000-4000-8000-000000000001"
    let edit = app.buttons["bestASR.history.editSegment.\(firstSegmentID)"]
    XCTAssertTrue(edit.waitForExistence(timeout: 3))
    edit.click()
    let editor = app.textFields[
      "bestASR.history.segmentEditor.\(firstSegmentID)"
    ]
    XCTAssertTrue(editor.waitForExistence(timeout: 2))
    editor.click()
    editor.typeKey("a", modifierFlags: .command)
    editor.typeText("第一段已经完成就地校对。")
    let save = app.buttons["bestASR.history.saveSegment.\(firstSegmentID)"]
    XCTAssertTrue(save.waitUntilEnabled(timeout: 2))
    save.click()
    XCTAssertFalse(editor.waitForExistence(timeout: 1))
    let editedSegment = app.staticTexts["bestASR.history.segment.\(firstSegmentID)"]
    XCTAssertTrue(
      editedSegment.waitForValue("第一段已经完成就地校对。", timeout: 3),
      "A successful inline correction must remain timestamped in the transcript."
    )
    XCTAssertTrue(duration.waitForValue("0:32", timeout: 2))
    XCTAssertTrue(firstSegment.exists)

    let originalDisclosure = app.descendants(matching: .any)["bestASR.history.rawDisclosure"]
    XCTAssertTrue(originalDisclosure.waitForExistence(timeout: 3))
    originalDisclosure.click()
    let originalText = app.descendants(matching: .any)["bestASR.history.rawText"]
    XCTAssertTrue(originalText.waitForExistence(timeout: 3))
    XCTAssertTrue((originalText.value as? String)?.contains("第一段本地播放测试逐字稿。") == true)
    XCTAssertFalse((originalText.value as? String)?.contains("第一段已经完成就地校对。") == true)
    originalDisclosure.click()

    let firstOccurrenceID = "47000000-0000-4000-8000-000000000001"
    let firstSpeakerID = "46000000-0000-4000-8000-000000000001"
    let candidate = app.menuButtons[
      "bestASR.history.inlineSpeaker.\(firstOccurrenceID)"
    ]
    XCTAssertTrue(candidate.waitForExistence(timeout: 3))
    XCTAssertEqual(candidate.accessibleName, "可能是 王芳")
    candidate.click()
    let confirm = app.descendants(matching: .any)[
      "bestASR.history.confirmSpeaker.\(firstSpeakerID)"
    ]
    XCTAssertTrue(confirm.waitForExistence(timeout: 2))
    confirm.click()
    XCTAssertTrue(candidate.waitForLabel("王芳", timeout: 3))
    let speakerStatus = app.staticTexts[
      "bestASR.history.inlineSpeakerStatus"
    ]
    XCTAssertTrue(
      speakerStatus.waitForValue(
        "人物匹配已保存，并会用于之后的本地识别",
        timeout: 3
      )
    )
    let undo = app.buttons["bestASR.history.inlineSpeakerUndo"]
    XCTAssertTrue(undo.waitForExistence(timeout: 2))
    undo.click()
    XCTAssertTrue(candidate.waitForLabel("可能是 王芳", timeout: 3))
    XCTAssertTrue(
      speakerStatus.waitForValue("最近一次人物修改已撤销", timeout: 3)
    )
  }

  func testPeopleReviewCandidateReturnsToExactAudioAndSupportsUndo() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--history-playback-ui-testing"]
    app.launch()

    openSidebarSection("人物", in: app)

    let reviewQueue = app.descendants(matching: .any)[
      "bestASR.people.reviewQueue"
    ]
    XCTAssertTrue(reviewQueue.waitForExistence(timeout: 3))
    XCTAssertFalse(app.staticTexts["可能是 王芳"].exists)
    XCTAssertLessThan(reviewQueue.frame.height, 85)
    reviewQueue.click()
    XCTAssertTrue(app.staticTexts["可能是 王芳"].exists)
    let speakerID = "46000000-0000-4000-8000-000000000001"
    let openCandidate = app.buttons[
      "bestASR.people.review.open.\(speakerID)"
    ]
    XCTAssertTrue(openCandidate.waitForExistence(timeout: 2))
    openCandidate.click()

    let candidateMenu = app.menuButtons[
      "bestASR.history.inlineSpeaker.47000000-0000-4000-8000-000000000001"
    ]
    XCTAssertTrue(candidateMenu.waitForExistence(timeout: 5))
    XCTAssertTrue(candidateMenu.waitForLabel("可能是 王芳", timeout: 2))
    let playPause = app.buttons["bestASR.history.playPause"]
    XCTAssertTrue(playPause.waitForLabel("暂停", timeout: 5))

    candidateMenu.click()
    let reject = app.descendants(matching: .any)[
      "bestASR.history.rejectSpeaker.\(speakerID)"
    ]
    XCTAssertTrue(reject.waitForExistence(timeout: 2))
    reject.click()
    let speakerStatus = app.staticTexts[
      "bestASR.history.inlineSpeakerStatus"
    ]
    XCTAssertTrue(
      speakerStatus.waitForValue(
        "已拒绝这个人物候选；本次记录不会再关联到该人物",
        timeout: 3
      )
    )

    let returnToPeople = app.descendants(matching: .any)[
      "bestASR.history.returnToMemory"
    ]
    XCTAssertTrue(returnToPeople.waitForExistence(timeout: 2))
    XCTAssertEqual(returnToPeople.label, "返回人物：王芳")
    returnToPeople.click()
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.people.search"]
        .waitForExistence(timeout: 3)
    )
    XCTAssertFalse(reviewQueue.waitForExistence(timeout: 1))

    let more = app.descendants(matching: .any)["bestASR.people.more"]
    XCTAssertTrue(more.waitForExistence(timeout: 2))
    more.click()
    let undo = app.descendants(matching: .any)["bestASR.people.undo"]
    XCTAssertTrue(undo.waitForExistence(timeout: 2))
    undo.click()
    XCTAssertTrue(reviewQueue.waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["可能是 王芳"].exists)
  }

  func testEventReviewPlaysEvidenceBeforeConfirmAndRestoresOnUndo() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--ui-testing", "--history-playback-ui-testing",
      "--event-review-ui-testing",
    ]
    app.launch()

    openSidebarSection("事件", in: app)

    let reviewQueue = app.descendants(matching: .any)[
      "bestASR.events.reviewQueue"
    ]
    XCTAssertTrue(reviewQueue.waitForExistence(timeout: 3))
    let candidateTitle = app.staticTexts["bestASR.events.candidate.title"]
    XCTAssertFalse(candidateTitle.exists)
    XCTAssertLessThan(reviewQueue.frame.height, 85)
    reviewQueue.click()
    XCTAssertTrue(candidateTitle.waitForExistence(timeout: 2))
    XCTAssertEqual(candidateTitle.value as? String, "播放进度与交互复盘")
    let candidateID = "49000000-0000-4000-8000-000000000001"
    let openCandidate = app.buttons[
      "bestASR.events.candidate.open.\(candidateID)"
    ]
    XCTAssertTrue(openCandidate.waitForExistence(timeout: 2))
    openCandidate.click()

    let playPause = app.buttons["bestASR.history.playPause"]
    let position = app.staticTexts["bestASR.history.playbackPosition"]
    XCTAssertTrue(playPause.waitForLabel("暂停", timeout: 5))
    XCTAssertTrue(
      position.waitForPlaybackSeconds(atLeast: 10, timeout: 3),
      "Review must start from the most relevant retained-audio segment."
    )
    let accept = app.buttons["bestASR.history.eventCandidate.accept"]
    XCTAssertTrue(accept.waitForExistence(timeout: 2))
    XCTAssertTrue(app.buttons["bestASR.history.eventCandidate.dismiss"].exists)
    accept.click()
    XCTAssertFalse(accept.waitForExistence(timeout: 1))

    let returnToEvent = app.descendants(matching: .any)[
      "bestASR.history.returnToMemory"
    ]
    XCTAssertTrue(returnToEvent.waitForExistence(timeout: 2))
    XCTAssertEqual(returnToEvent.label, "返回事件：播放进度与交互复盘")
    returnToEvent.click()
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.events.timeline"]
        .waitForExistence(timeout: 3)
    )
    XCTAssertFalse(reviewQueue.waitForExistence(timeout: 1))
    let earlierSource = app.buttons[
      "bestASR.events.timeline.open.41000000-0000-4000-8000-000000000003"
    ]
    let reviewedSource = app.buttons[
      "bestASR.events.timeline.open.41000000-0000-4000-8000-000000000001"
    ]
    XCTAssertTrue(earlierSource.waitForExistence(timeout: 2))
    XCTAssertTrue(reviewedSource.waitForExistence(timeout: 2))
    XCTAssertLessThan(
      earlierSource.frame.minY,
      reviewedSource.frame.minY,
      "The event timeline must remain chronological after confirmation."
    )

    let more = app.descendants(matching: .any)["bestASR.events.more"]
    XCTAssertTrue(more.waitForExistence(timeout: 2))
    more.click()
    let undo = app.descendants(matching: .any)["bestASR.events.undo"]
    XCTAssertTrue(undo.waitForExistence(timeout: 2))
    undo.click()
    XCTAssertTrue(reviewQueue.waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["播放进度与交互复盘"].exists)
  }

  func testSettingsExposeShortcutsComponentsAndAppFormattingControls() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--settings-ui-testing"]
    app.launch()
    let category = app.descendants(matching: .any)["bestASR.settings.category"]
    XCTAssertTrue(category.waitForExistence(timeout: 5))
    // Settings itself shows four of these; 本地组件 and 文字格式 are operator
    // tooling in the 高级 window. This launch mode shows all six so each pane
    // is still walked.
    let expectedCategoryLabels = [
      "general": "通用",
      "shortcuts": "快捷键",
      "recording": "麦克风",
      "models": "本地组件",
      "language": "文字格式",
      "data": "数据",
    ]
    for (identifier, label) in expectedCategoryLabels {
      let button = app.buttons["bestASR.settings.category.\(identifier)"]
      XCTAssertTrue(button.exists)
      XCTAssertEqual(button.label, label)
    }
    let shortcuts = app.buttons["bestASR.settings.category.shortcuts"]
    XCTAssertTrue(shortcuts.waitForExistence(timeout: 2))
    shortcuts.click()
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.settings.startEndHotkey"].exists
    )
    XCTAssertNotEqual(
      app.descendants(matching: .any)["bestASR.settings.startEndHotkey"].value
        as? String,
      "等待输入新快捷键",
      "Opening Settings must not silently start shortcut capture."
    )
    // There is only one global shortcut now: nothing pauses a dictation, and
    // the two other modes are chords on the dictation key itself.
    XCTAssertFalse(
      app.descendants(matching: .any)["bestASR.settings.pauseResumeHotkey"].exists
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.settings.spokenModes"].exists
        || app.descendants(matching: .any)["bestASR.settings.spokenModesUnavailable"]
          .exists,
      "Settings must say how 翻译 and 指令 are reached."
    )
    let applyHotkeys = app.buttons["bestASR.settings.applyHotkeys"]
    XCTAssertTrue(applyHotkeys.exists)
    applyHotkeys.click()
    XCTAssertEqual(
      app.staticTexts["bestASR.settings.hotkeyStatus"].value as? String,
      "快捷键配置已在本机验证"
    )

    let models = app.buttons["bestASR.settings.category.models"]
    XCTAssertTrue(models.waitForExistence(timeout: 2))
    models.click()
    let license = app.descendants(matching: .any)[
      "bestASR.settings.modelLicenseAccepted"
    ]
    XCTAssertTrue(
      license.waitForExistence(timeout: 5)
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.settings.funASRLicense"].exists
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.settings.qwenLicense"].exists
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.settings.speakerLicense"].exists
    )
    XCTAssertTrue(
      app.buttons["bestASR.settings.downloadRecommendedModels"].exists
    )

    let language = app.buttons["bestASR.settings.category.language"]
    XCTAssertTrue(language.exists)
    language.click()
    XCTAssertTrue(
      app.descendants(matching: .any)[
        "bestASR.settings.appPolicyApplication"
      ].exists
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.settings.appPolicyFormat"].exists
    )
    XCTAssertTrue(
      app.buttons["bestASR.settings.appPolicySave"].exists
    )

    let data = app.buttons["bestASR.settings.category.data"]
    XCTAssertTrue(data.exists)
    data.click()
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.settings.archiveSecret"].exists
    )
    XCTAssertTrue(
      app.descendants(matching: .any)[
        "bestASR.settings.archiveSecretConfirmation"
      ].exists
    )
  }

  func testGuidedSetupRequiresConsentAndReachesOfflineReadyState() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--ui-testing", "--settings-ui-testing", "--model-setup-ui-testing",
    ]
    app.launch()
    let models = app.buttons["bestASR.settings.category.models"]
    XCTAssertTrue(models.waitForExistence(timeout: 5))
    models.click()
    let download = app.buttons["bestASR.settings.downloadRecommendedModels"]
    XCTAssertTrue(download.waitForExistence(timeout: 5))
    XCTAssertFalse(download.isEnabled)

    app.descendants(matching: .any)["bestASR.settings.modelLicenseAccepted"].click()
    app.descendants(matching: .any)["bestASR.settings.polishModelLicenseAccepted"].click()
    app.descendants(matching: .any)["bestASR.settings.speakerModelLicenseAccepted"].click()
    XCTAssertTrue(download.isEnabled)
    download.click()

    XCTAssertTrue(
      app.staticTexts["bestASR.settings.modelReadiness"]
        .waitForExistence(timeout: 2)
    )
    XCTAssertEqual(
      app.staticTexts["bestASR.settings.modelReadiness"].value as? String,
      "本机语音识别测试组件已就绪"
    )
    XCTAssertEqual(
      app.staticTexts["bestASR.settings.speakerReadiness"].value as? String,
      "本机多人识别测试组件已就绪"
    )
  }

  func testFirstLaunchIsOneHonestThreeStepJourney() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--onboarding-ui-testing"]
    app.launch()

    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.onboarding.step1"]
        .waitForExistence(timeout: 5)
    )
    XCTAssertTrue(dictationTrialButton(in: app).exists)
    assertSidebarSections(["线下录音", "电脑内录", "文件导入"], in: app)
    let microphone = app.buttons["bestASR.permission.microphone"]
    let accessibility = app.buttons["bestASR.permission.accessibility"]
    XCTAssertTrue(microphone.exists)
    XCTAssertTrue(accessibility.exists)
    microphone.click()
    accessibility.click()

    let microphoneCheck = app.buttons[
      "bestASR.onboarding.microphoneCheck"
    ]
    XCTAssertTrue(microphoneCheck.waitForExistence(timeout: 2))
    microphoneCheck.click()

    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.onboarding.step2"]
        .waitForExistence(timeout: 2)
    )
    let license = app.descendants(matching: .any)[
      "bestASR.setup.licensesAccepted"
    ]
    XCTAssertTrue(license.waitForExistence(timeout: 2))
    license.click()
    let download = app.buttons["bestASR.setup.download"]
    XCTAssertTrue(download.isEnabled)
    download.click()

    let practice = app.descendants(matching: .any)[
      "bestASR.onboarding.step3"
    ]
    XCTAssertTrue(practice.waitForExistence(timeout: 2))
    let editor = app.descendants(matching: .any)[
      "bestASR.onboarding.practiceEditor"
    ]
    XCTAssertTrue(editor.exists)
    editor.click()
    editor.typeText("manual typing is not dictation")
    XCTAssertTrue(
      practice.exists,
      "Typing into the practice field must not pretend a dictation succeeded."
    )

    app.buttons["bestASR.onboarding.deferPractice"].click()
    XCTAssertFalse(practice.waitForExistence(timeout: 1))
    XCTAssertTrue(
      dictationTrialButton(in: app).waitForExistence(timeout: 2),
      "Deferring practice should expose the product without recording false completion."
    )
    XCTAssertTrue(app.buttons["bestASR.onboarding.resume"].exists)
  }

  func testFirstLaunchCanBeDeferredAndResumedWithoutADeadEnd() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--onboarding-ui-testing"]
    app.launch()

    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.onboarding.step1"]
        .waitForExistence(timeout: 5)
    )
    let deferPermissions = app.buttons[
      "bestASR.onboarding.deferPermissions"
    ]
    XCTAssertTrue(deferPermissions.waitForExistence(timeout: 2))
    deferPermissions.click()

    XCTAssertTrue(
      dictationTrialButton(in: app)
        .waitForExistence(timeout: 2)
    )
    XCTAssertFalse(
      app.descendants(matching: .any)["bestASR.onboarding.step2"].exists
    )
    XCTAssertFalse(
      app.descendants(matching: .any)["bestASR.onboarding.step3"].exists
    )
    let resume = app.buttons["bestASR.onboarding.resume"]
    XCTAssertTrue(resume.waitForExistence(timeout: 2))
    resume.click()

    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.onboarding.step1"]
        .waitForExistence(timeout: 2)
    )
    app.buttons["bestASR.permission.microphone"].click()
    app.buttons["bestASR.permission.accessibility"].click()
    let microphoneCheck = app.buttons[
      "bestASR.onboarding.microphoneCheck"
    ]
    XCTAssertTrue(microphoneCheck.waitForExistence(timeout: 2))
    microphoneCheck.click()
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.onboarding.step2"]
        .waitForExistence(timeout: 2)
    )
    let deferModels = app.buttons["bestASR.onboarding.deferModels"]
    XCTAssertTrue(deferModels.waitForExistence(timeout: 2))
    deferModels.click()
    XCTAssertFalse(
      app.descendants(matching: .any)[
        "bestASR.onboarding.practiceEditor"
      ].exists,
      "A practice editor that cannot possibly complete must not be presented as ready."
    )
    XCTAssertTrue(
      dictationTrialButton(in: app).waitForExistence(timeout: 2),
      "Deferring optional setup must expose the rest of the local product."
    )
    XCTAssertTrue(app.buttons["bestASR.onboarding.resume"].exists)
  }

  func testIncompleteOnboardingSurvivesExistingHistory() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--ui-testing",
      "--onboarding-ui-testing",
      "--onboarding-existing-history-ui-testing",
    ]
    app.launch()

    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.onboarding.step1"]
        .waitForExistence(timeout: 5),
      "An existing record must not silently dismiss unfinished setup."
    )
    let deferPermissions = app.buttons[
      "bestASR.onboarding.deferPermissions"
    ]
    XCTAssertTrue(deferPermissions.exists)
    deferPermissions.click()
    XCTAssertTrue(
      app.buttons["bestASR.onboarding.resume"].waitForExistence(timeout: 2),
      "Deferred setup must remain resumable after History is no longer empty."
    )
  }

  func testPrimaryAudioMemoryWorkspacesRemainReachable() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing"]
    app.launch()

    openSidebarSection("人物", in: app)
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.people.search"]
        .waitForExistence(timeout: 2)
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.people.selectionPlaceholder"]
        .waitForExistence(timeout: 2)
    )

    openSidebarSection("事件", in: app)
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.events.search"]
        .waitForExistence(timeout: 2)
    )
    XCTAssertTrue(app.buttons["bestASR.events.new"].exists)
    let eventMore = app.descendants(matching: .any)["bestASR.events.more"]
    XCTAssertTrue(eventMore.exists)
    eventMore.click()
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.events.refresh"]
        .waitForExistence(timeout: 2)
    )
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.events.emptyState"]
        .waitForExistence(timeout: 2)
    )
    app.buttons["bestASR.events.new"].click()
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.events.createTitle"]
        .waitForExistence(timeout: 2)
    )
    XCTAssertTrue(app.buttons["bestASR.events.createCancel"].exists)
    app.buttons["bestASR.events.createCancel"].click()
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.events.emptyState"]
        .waitForExistence(timeout: 2)
    )

    app.descendants(matching: .any)["bestASR.sidebar.dictionary"].click()
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.settings.dictionarySearch"]
        .waitForExistence(timeout: 2)
    )
    let newDictionaryEntry = app.buttons["bestASR.dictionary.new"]
    XCTAssertTrue(newDictionaryEntry.waitForExistence(timeout: 2))
    newDictionaryEntry.click()
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.settings.dictionaryCanonical"]
        .exists
    )
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.dictionary.status"]
        .exists
    )
    XCTAssertTrue(app.buttons["bestASR.dictionary.cancelEdit"].exists)
    let canonical = app.descendants(matching: .any)[
      "bestASR.settings.dictionaryCanonical"
    ]
    canonical.click()
    canonical.typeText("bestASRUITestTerm")
    let save = app.buttons["bestASR.settings.dictionarySave"]
    XCTAssertTrue(save.isEnabled)
    save.click()
    XCTAssertTrue(
      app.staticTexts["bestASR.dictionary.status"]
        .waitForValue("本机词典存储暂不可用", timeout: 2)
    )
    XCTAssertTrue(
      canonical.exists,
      "A failed asynchronous save must keep the editor and draft available."
    )
    XCTAssertEqual(canonical.value as? String, "bestASRUITestTerm")
  }

  func testLinkedLibraryRecordReturnsToItsMemoryContext() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--history-origin-ui-testing"]
    app.launch()

    let returnToMemory = app.descendants(matching: .any)[
      "bestASR.history.returnToMemory"
    ]
    XCTAssertTrue(
      returnToMemory.waitForExistence(timeout: 5),
      "A record opened from a person must show where it came from on its detail page."
    )
    XCTAssertTrue(
      app.buttons["bestASR.history.back"].exists,
      "The origin bar belongs to the record detail page, which also leads back to the list."
    )
    XCTAssertEqual(returnToMemory.label, "返回人物：测试人物")
    returnToMemory.click()

    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.people.search"]
        .waitForExistence(timeout: 2),
      "A linked recording must return to the person or event the user came from."
    )
    XCTAssertFalse(returnToMemory.exists)
  }

  func testLibrarySearchResultOpensTheUnderlyingRecording() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing"]
    app.launch()

    let history = app.descendants(matching: .any)["bestASR.sidebar.history"]
    XCTAssertTrue(history.waitForExistence(timeout: 5))
    history.click()
    let search = app.textFields["bestASR.history.search"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.click()
    search.typeText("Fixture raw")

    let result = historyRows(in: app)
      .containing(textPredicate("Fixture raw dictation.")).firstMatch
    XCTAssertTrue(result.waitForExistence(timeout: 2))
    result.click()

    let currentText =
      app.descendants(matching: .any)["bestASR.history.currentText"]
    XCTAssertTrue(
      currentText.waitForExistence(timeout: 2),
      "Search must land on the source record, not a dead-end result."
    )
    XCTAssertEqual(currentText.value as? String, "Fixture raw dictation.")
  }

  func testPrimaryWorkspacesSupportStandardKeyboardNavigation() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing"]
    app.launch()

    XCTAssertTrue(homeHeadline(in: app).waitForExistence(timeout: 5))

    app.typeKey("2", modifierFlags: .command)
    let historyList = app.descendants(matching: .any)["bestASR.history.list"]
    XCTAssertTrue(historyList.waitForExistence(timeout: 2))
    let historySearch = app.textFields["bestASR.history.search"]
    XCTAssertTrue(historySearch.exists)
    historySearch.click()
    historySearch.typeText("project")
    XCTAssertEqual(
      historySearch.value as? String,
      "project"
    )
    app.typeKey("a", modifierFlags: .command)
    app.typeKey(.delete, modifierFlags: [])
    app.typeKey(.return, modifierFlags: [])
    let currentText =
      app.descendants(matching: .any)["bestASR.history.currentText"]
    XCTAssertTrue(
      currentText.waitForExistence(timeout: 2),
      "Return from Library search should open the first matching record."
    )

    app.typeKey("2", modifierFlags: .command)
    XCTAssertTrue(
      historyList.waitForExistence(timeout: 2),
      "Command-2 from a record must return to the History list."
    )
    XCTAssertFalse(currentText.exists)

    app.typeKey("3", modifierFlags: .command)
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.settings.dictionarySearch"]
        .waitForExistence(timeout: 2)
    )

    app.typeKey("1", modifierFlags: .command)
    guard homeHeadline(in: app).waitForExistence(timeout: 2) else {
      XCTFail("Command-1 did not return to Today.\n\(app.debugDescription)")
      return
    }
  }

  func testRoomPreviewAndImportDropZoneHaveCompleteBasicInteraction() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing"]
    app.launch()

    XCTAssertTrue(homeHeadline(in: app).waitForExistence(timeout: 5))
    openSidebarSection("线下录音", in: app)
    let preview = app.buttons["bestASR.room.levelPreview"]
    XCTAssertTrue(preview.waitForExistence(timeout: 2))
    preview.click()
    XCTAssertTrue(preview.waitForLabel("停止音量预览", timeout: 2))
    preview.click()
    XCTAssertTrue(preview.waitForLabel("检查音量", timeout: 2))
    XCTAssertTrue(
      app.staticTexts["bestASR.room.status"]
        .waitForValue("已停止音量预览；可以开始线下录音", timeout: 2)
    )

    app.descendants(matching: .any)["bestASR.sidebar.home"].click()
    XCTAssertTrue(homeHeadline(in: app).waitForExistence(timeout: 2))
    openSidebarSection("电脑内录", in: app)
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.systemAudio.source"]
        .waitForExistence(timeout: 2)
    )
    let systemPreview = app.buttons["bestASR.systemAudio.levelPreview"]
    XCTAssertTrue(systemPreview.exists)
    XCTAssertTrue(app.buttons["bestASR.systemAudio.startEnd"].exists)
    systemPreview.click()
    XCTAssertTrue(systemPreview.waitForLabel("停止音量预览", timeout: 2))
    XCTAssertTrue(
      app.staticTexts["bestASR.systemAudio.status"]
        .waitForValue("正在预听输出电平；此操作不保存音频", timeout: 2)
    )
    systemPreview.click()
    XCTAssertTrue(systemPreview.waitForLabel("检查音量", timeout: 2))
    XCTAssertTrue(
      app.staticTexts["bestASR.systemAudio.status"]
        .waitForValue("已停止电脑输出音量预览；可以开始电脑内录", timeout: 2)
    )

    app.typeKey("1", modifierFlags: .command)
    XCTAssertTrue(
      homeHeadline(in: app).waitForExistence(timeout: 2),
      "Command-1 must leave a frozen capture section for Home."
    )
    openSidebarSection("文件导入", in: app)
    XCTAssertTrue(
      app.descendants(matching: .any)["bestASR.import.dropZone"]
        .waitForExistence(timeout: 2)
    )
    XCTAssertTrue(app.buttons["bestASR.import.choose"].exists)
    app.buttons["bestASR.import.choose"].click()
    let importSheet = app.sheets.firstMatch
    XCTAssertTrue(
      importSheet.waitForExistence(timeout: 3),
      "File selection must stay attached to the current workspace."
    )
    XCTAssertEqual(app.windows.count, 1)
    importSheet.buttons["CancelButton"].click()
    XCTAssertTrue(app.buttons["bestASR.import.choose"].waitUntilEnabled(timeout: 2))
  }

  func testFinderOpenWithReusesTheExistingWorkspace() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing"]
    app.launch()
    XCTAssertTrue(homeHeadline(in: app).waitForExistence(timeout: 5))
    XCTAssertEqual(app.windows.count, 1)
    let runningApplication = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
    XCTAssertTrue(
      ["com.bestasr.app.debug", "com.bestasr.app"].contains(
        runningApplication.bundleIdentifier ?? ""
      )
    )
    let applicationURL = try XCTUnwrap(runningApplication.bundleURL)
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("bestasr-window-routing-\(UUID().uuidString).txt")
    try Data("Synthetic unsupported file; must not create a recording.".utf8)
      .write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    // The app claims public.audio and public.movie and nothing else, so
    // LaunchServices refuses a text file before the app ever sees it. That
    // refusal is the correct outcome — the point of the test is that no
    // second window appears either way.
    let opened = expectation(description: "Finder-style open is answered")
    NSWorkspace.shared.open(
      [file],
      withApplicationAt: applicationURL,
      configuration: NSWorkspace.OpenConfiguration()
    ) { _, error in
      let refusal = (error as NSError?)?.underlyingErrors.first as NSError?
      XCTAssertEqual(
        refusal?.code, -10820,
        "An unsupported file is refused rather than opened: \(String(describing: error))"
      )
      opened.fulfill()
    }
    wait(for: [opened], timeout: 5)
    let duplicate = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in app.windows.count > 1 },
      object: nil
    )
    duplicate.isInverted = true
    wait(for: [duplicate], timeout: 2)
    XCTAssertEqual(app.windows.count, 1)
  }

  /// The word is the control. Clicking one selects it; what can be done to a
  /// word appears once one is selected. There used to be a 选择 button that
  /// put the page into a mode, and a hover-only ⋯ menu on every chip carrying
  /// the same three actions — two ways to the same place, neither of them the
  /// thing the pointer was already over.
  func testClickingAWordSelectsItAndRevealsWhatCanBeDoneToIt() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--dictionary-ui-testing"]
    app.launch()
    XCTAssertTrue(
      app.textFields["bestASR.settings.dictionarySearch"]
        .waitForExistence(timeout: 5)
    )
    XCTAssertFalse(
      app.buttons["bestASR.dictionary.select"].exists,
      "Selection is not a mode to enter."
    )

    let entryPrefix = "bestASR.dictionary.entry."
    let chips = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", entryPrefix)
    )
    XCTAssertTrue(chips.firstMatch.waitForExistence(timeout: 5))
    XCTAssertEqual(chips.count, 6, "Every fixture word must be laid out as a chip.")

    let chip = chips.containing(textPredicate("Typeless")).firstMatch
    XCTAssertTrue(chip.exists)
    let count = app.descendants(matching: .any)["bestASR.dictionary.selectionCount"]
    XCTAssertFalse(count.exists, "Nothing is offered until a word is chosen.")

    chip.click()
    XCTAssertTrue(count.waitForExistence(timeout: 2))
    XCTAssertEqual(count.value as? String, "已选 1 个词")
    for action in [
      "bestASR.dictionary.editSelected", "bestASR.dictionary.enableSelected",
      "bestASR.dictionary.deleteSelected", "bestASR.dictionary.selectAll",
    ] {
      XCTAssertTrue(app.buttons[action].exists, "Missing \(action)")
    }

    app.buttons["bestASR.dictionary.deleteSelected"].click()
    let confirmDelete = app.buttons["bestASR.dictionary.confirmDeleteSelected"]
    XCTAssertTrue(
      confirmDelete.waitForExistence(timeout: 2),
      "Deleting a word must ask for confirmation first."
    )
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertFalse(confirmDelete.waitForExistence(timeout: 1))
    XCTAssertEqual(chips.count, 6)

    // Clicking it again puts it back, so there is no mode left behind.
    chip.click()
    XCTAssertFalse(count.waitForExistence(timeout: 1))

    chip.doubleClick()
    let canonical = app.textFields["bestASR.settings.dictionaryCanonical"]
    XCTAssertTrue(
      canonical.waitForExistence(timeout: 2),
      "Double-clicking a chip opens it for editing."
    )
    XCTAssertEqual(canonical.value as? String, "Typeless")
    app.buttons["bestASR.dictionary.cancelEdit"].click()
    XCTAssertFalse(canonical.waitForExistence(timeout: 1))
  }

  // MARK: - Navigation helpers

  /// Headline of the Home page header.
  private func homeHeadline(in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(identifier: "bestASR.home.headline").firstMatch
  }

  /// Home's shortcut card: the product itself, visible once setup is out
  /// of the way. (The in-window "try a sentence" button is gone; a dictation
  /// is started from the keyboard and reported by the capsule.)
  private func dictationTrialButton(in app: XCUIApplication) -> XCUIElement {
    app.staticTexts["bestASR.home.shortcuts"]
  }

  /// The active dictation workspace's 结束并保存 / 结束并输入 button.
  private func dictationEndButton(in app: XCUIApplication) -> XCUIElement {
    app.buttons["bestASR.main.startEnd"]
  }

  private func historyRows(in app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "bestASR.history.item")
  }

  /// Extended workspaces remain directly reachable from stable sidebar buttons.
  private func sidebarSectionButton(_ title: String, in app: XCUIApplication) -> XCUIElement {
    let identifiers = [
      "线下录音": "roomRecording", "电脑内录": "systemAudio", "文件导入": "importMedia",
      "人物": "people", "事件": "events",
    ]
    return app.buttons["bestASR.sidebar.\(identifiers[title] ?? title)"]
  }

  private func openSidebarSection(
    _ title: String,
    in app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let button = sidebarSectionButton(title, in: app)
    XCTAssertTrue(
      button.waitForExistence(timeout: 5),
      "The sidebar must offer \(title) directly.", file: file, line: line
    )
    XCTAssertTrue(button.isHittable, file: file, line: line)
    button.click()
  }

  private func assertSidebarSections(
    _ titles: [String],
    in app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for title in titles {
      let button = sidebarSectionButton(title, in: app)
      XCTAssertTrue(
        button.waitForExistence(timeout: 5),
        "The sidebar must list \(title) directly.", file: file, line: line
      )
      XCTAssertTrue(button.isHittable, file: file, line: line)
    }
    XCTAssertFalse(
      app.descendants(matching: .any)["bestASR.sidebar.more"].exists,
      "Extended workspaces must not require a More menu.", file: file, line: line
    )
  }
}

/// Matches an element whose visible text is exactly `text`; macOS exposes
/// SwiftUI text as the value, controls as the label.
private func textPredicate(_ text: String) -> NSPredicate {
  NSPredicate(format: "label == %@ OR value == %@", text, text)
}

extension XCUIElement {
  fileprivate func waitUntilEnabled(timeout: TimeInterval) -> Bool {
    let predicate = NSPredicate(format: "enabled == true")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  fileprivate func waitForValue(_ expected: String, timeout: TimeInterval) -> Bool {
    let predicate = NSPredicate(format: "value == %@", expected)
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  /// Matches the control's name wherever AppKit put it.
  ///
  /// A button carries its name in the accessibility label; a pop-up menu
  /// carries it in the title, and its label holds the description of whatever
  /// image it was given. Asserting on the label alone reported a correctly
  /// named menu as wrong — and, before that, reported the SF Symbol's
  /// description, "account", as though it were the person's name.
  fileprivate func waitForLabel(_ expected: String, timeout: TimeInterval) -> Bool {
    let predicate = NSPredicate(format: "label == %@ OR title == %@", expected, expected)
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  /// The control's name, from wherever AppKit exposed it.
  fileprivate var accessibleName: String {
    label.isEmpty ? title : label
  }

  fileprivate var playbackSeconds: Int? {
    let displayedTime = (value as? String) ?? label
    let parts = displayedTime.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2 || parts.count == 3 else { return nil }
    return parts.reduce(0) { $0 * 60 + $1 }
  }

  fileprivate func waitForPlaybackSeconds(
    atLeast minimum: Int,
    timeout: TimeInterval
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let seconds = playbackSeconds, seconds >= minimum { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return playbackSeconds.map { $0 >= minimum } ?? false
  }

  fileprivate func waitForPlaybackSeconds(
    atMost maximum: Int,
    timeout: TimeInterval
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let seconds = playbackSeconds, seconds <= maximum { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return playbackSeconds.map { $0 <= maximum } ?? false
  }
}
