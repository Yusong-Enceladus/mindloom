import AppKit
import BestASRMemory
import SwiftUI
import XCTest

@testable import BestASRMemoryUI

/// Renders the real memory pages, fed with the synthetic fixture, to PNGs at
/// 1280×820 in light and dark. Off unless `BESTASR_UI_SNAPSHOT_DIR` names an
/// output directory, so ordinary test runs write nothing.
@MainActor
final class MemorySnapshotTests: XCTestCase {
  private struct Scene {
    let name: String
    let navigation: MemoryNavigation
    let state: MemoryScreenState
    var accessory: AnyView? = nil
    /// Taller for a page whose end matters (Home's "显示更多").
    var height: CGFloat = 820
  }

  private func state(
    _ projection: MemoryProjection?, mode: MemoryScreenState.Mode = .spark,
    toast: MemoryToast? = nil, capture: MemoryCaptureIndicator? = nil,
    issues: [MemoryIssue] = []
  ) -> MemoryScreenState {
    MemoryScreenState(
      mode: mode, projection: projection, personReviews: MemorySnapshotFixture.personReviews,
      toast: toast, capture: capture, issues: issues, now: MemorySnapshotFixture.now,
      calendar: MemorySnapshotFixture.calendar, thumbnail: MemorySnapshotFixture.thumbnail)
  }

  /// First run with setup incomplete: the permission step above the empty
  /// Home, drawn with the same public setup components the App uses.
  private var setupAccessory: AnyView {
    AnyView(
      ZhijiSetupCard(
        step: 1, stepTitle: "允许录音与回写", title: "让织机听见，并把结果送回原处",
        detail: "麦克风只用于你主动开始的录音；辅助功能让快捷键在任何 App 中生效，并在结束后把文字写回原来的输入位置。"
      ) {
        VStack(alignment: .leading, spacing: 10) {
          ZhijiSetupRow(
            symbol: "mic", title: "麦克风", state: "已允许", done: true, actionTitle: nil)
          ZhijiSetupRow(
            symbol: "cursorarrow.motionlines", title: "辅助功能", state: "还没允许", done: false,
            actionTitle: "打开系统设置")
        }
        HStack {
          Spacer()
          Button("跳过首次设置") {}
        }
      }
      .frame(maxWidth: 900, alignment: .leading))
  }

  private var scenes: [Scene] {
    let fixture = MemorySnapshotFixture.self
    let recording = MemoryCaptureIndicator(
      kind: .systemAudio, title: ZhijiCopy.recording, detail: "腾讯会议 · 12:04")
    let toast = MemoryToast(
      message: "已收进来 · 来自 微信", itemID: fixture.item(1), sourceName: "微信")
    return [
      Scene(
        name: "home", navigation: MemoryNavigation(),
        state: state(fixture.sparkProjection(questions: false), toast: toast, capture: recording)),
      Scene(
        name: "home-question", navigation: MemoryNavigation(),
        state: state(fixture.sparkProjection(questions: true), capture: recording)),
      Scene(
        name: "event",
        navigation: MemoryNavigation(
          path: [.event("ev-rent")], expandedItems: [fixture.item(4)]),
        state: state(fixture.sparkProjection(questions: true))),
      Scene(
        // The screenshot row open: the device's summary on its own line.
        name: "event-screenshot",
        navigation: MemoryNavigation(path: [.event("ev-mom")], expandedItems: [fixture.item(14)]),
        state: state(fixture.sparkProjection(questions: false))),
      Scene(
        name: "person", navigation: MemoryNavigation(path: [.person(fixture.wang)]),
        state: state(fixture.sparkProjection(questions: false))),
      Scene(
        name: "unfiled", navigation: MemoryNavigation(path: [.unfiled]),
        state: state(fixture.sparkProjection(questions: false))),
      Scene(
        name: "home-empty", navigation: MemoryNavigation(),
        state: state(MemoryProjection(events: [], records: [], now: fixture.now), mode: .local)),
      Scene(
        name: "home-local", navigation: MemoryNavigation(),
        state: state(fixture.localProjection, mode: .local)),
      Scene(
        name: "home-setup", navigation: MemoryNavigation(),
        state: state(MemoryProjection(events: [], records: [], now: fixture.now), mode: .local),
        accessory: setupAccessory),
      Scene(
        name: "home-unfiled-only", navigation: MemoryNavigation(),
        state: state(fixture.unfiledOnlyProjection, mode: .local)),
      Scene(
        name: "home-issues", navigation: MemoryNavigation(),
        state: state(fixture.sparkProjection(questions: false), issues: fixture.issues)),
      Scene(
        name: "people-index", navigation: MemoryNavigation(tab: .people),
        state: state(fixture.sparkProjection(questions: false))),
      Scene(
        name: "event-local", navigation: MemoryNavigation(path: [.event("ev-mom")]),
        state: state(fixture.localProjection, mode: .local)),
    ] + scaleScenes
  }

  /// 60 events, 2000 items, 30 people, a meeting split over three events.
  private var scaleScenes: [Scene] {
    let scale = MemoryScreenState(
      mode: .spark,
      readModel: MemoryReadModel(
        MemoryScaleFixture.projection, calendar: MemorySnapshotFixture.calendar),
      now: MemorySnapshotFixture.now, calendar: MemorySnapshotFixture.calendar,
      thumbnail: MemorySnapshotFixture.thumbnail)
    let meeting = MemorySnapshotFixture.item(MemoryScaleFixture.meetingItem)
    return [
      Scene(name: "scale-home", navigation: MemoryNavigation(), state: scale),
      Scene(name: "scale-home-full", navigation: MemoryNavigation(), state: scale, height: 2_300),
      Scene(
        name: "scale-event-split",
        navigation: MemoryNavigation(path: [.event("ev-1")], expandedItems: ["\(meeting)#s2"]),
        state: scale),
      Scene(
        name: "scale-event-split-market",
        navigation: MemoryNavigation(path: [.event("ev-0")], expandedItems: ["\(meeting)#s1"]),
        state: scale),
      Scene(
        name: "scale-person",
        navigation: MemoryNavigation(path: [.person(MemoryScaleFixture.personID(0))]),
        state: scale),
      Scene(name: "scale-people-index", navigation: MemoryNavigation(tab: .people), state: scale),
      Scene(name: "scale-unfiled", navigation: MemoryNavigation(path: [.unfiled]), state: scale),
    ]
  }

  func testRenderSnapshots() throws {
    guard let directory = ProcessInfo.processInfo.environment["BESTASR_UI_SNAPSHOT_DIR"],
      !directory.isEmpty
    else {
      throw XCTSkip("Set BESTASR_UI_SNAPSHOT_DIR to render the memory page snapshots.")
    }
    let output = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for scene in scenes {
      for scheme in [ColorScheme.light, .dark] {
        let accessory = scene.accessory
        let view = ZhijiShell(
          navigation: .constant(scene.navigation), state: scene.state, actions: .inert,
          slots: MemoryShellSlots(homeAccessory: { accessory })
        )
        .frame(width: 1280, height: scene.height)
        .environment(\.colorScheme, scheme)
        .environment(\.zhijiSnapshot, true)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 1280, height: scene.height)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, scene.name)
        XCTAssertEqual(image.width, 1280)
        XCTAssertEqual(image.height, Int(scene.height))
        let bitmap = NSBitmapImageRep(cgImage: image)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let name = "\(scene.name)-\(scheme == .dark ? "dark" : "light").png"
        try png.write(to: output.appendingPathComponent(name), options: .atomic)
      }
    }
  }

  /// Dropped files of every kind and a video with its keyframes: the event
  /// page closed, open, and Home. Written to `BESTASR_UI_SNAPSHOT_DIR` too.
  func testRenderFileSnapshots() throws {
    guard let directory = ProcessInfo.processInfo.environment["BESTASR_UI_SNAPSHOT_DIR"],
      !directory.isEmpty
    else {
      throw XCTSkip("Set BESTASR_UI_SNAPSHOT_DIR to render the file snapshots.")
    }
    let output = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let fixture = MemorySnapshotFixture.self
    let state = MemoryScreenState(
      mode: .spark, projection: MemoryFilesFixture.projection, now: fixture.now,
      calendar: fixture.calendar, thumbnail: MemoryFilesFixture.thumbnail)
    let scenes: [(String, MemoryNavigation, CGFloat)] = [
      ("files-home", MemoryNavigation(), 900),
      ("files-event", MemoryNavigation(path: [.event("ev-supplier")]), 1_500),
      (
        "files-event-open-table-mail-archive",
        MemoryNavigation(
          path: [.event("ev-supplier")],
          expandedItems: [fixture.item(30), fixture.item(31), fixture.item(34)]), 2_100
      ),
      (
        "files-event-open-scan-locked-calendar-contact",
        MemoryNavigation(
          path: [.event("ev-supplier")],
          expandedItems: [
            fixture.item(33), fixture.item(35), fixture.item(37), fixture.item(38),
            fixture.item(39),
          ]), 2_100
      ),
      ("video-event", MemoryNavigation(path: [.event("ev-demo")]), 820),
      (
        "video-event-open",
        MemoryNavigation(path: [.event("ev-demo")], expandedItems: [fixture.item(40)]), 900
      ),
    ]
    for (name, navigation, height) in scenes {
      for scheme in [ColorScheme.light, .dark] {
        let view = ZhijiShell(
          navigation: .constant(navigation), state: state, actions: .inert,
          slots: MemoryShellSlots(homeAccessory: { nil })
        )
        .frame(width: 1280, height: height)
        .environment(\.colorScheme, scheme)
        .environment(\.zhijiSnapshot, true)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 1280, height: height)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, name)
        let png = try XCTUnwrap(
          NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(
          to: output.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"),
          options: .atomic)
      }
    }
  }

  /// A file row carries the organizing device's reading and facts; the
  /// export quotes what was read and names the file; keyframes sit under
  /// their recording instead of being rows of their own.
  func testFileReadingsAndKeyframesReachTheRowsAndTheExport() throws {
    let fixture = MemorySnapshotFixture.self
    let projection = MemoryFilesFixture.projection
    let supplier = try XCTUnwrap(projection.event(id: "ev-supplier"))
    XCTAssertEqual(supplier.items.count, 10)
    let mail = try XCTUnwrap(supplier.items.first { $0.itemID == fixture.item(31) })
    XCTAssertEqual(ItemKind(mail).fileKind, .email)
    let reading = try XCTUnwrap(mail.fileReading)
    XCTAssertEqual(reading.summary, "林经理发来新报价：3.20 元/个，10 月 8 日前确认")
    XCTAssertEqual(reading.facts?.attachments.count, 2)
    let record = try XCTUnwrap(mail.record)
    XCTAssertEqual(MemoryFileText.facts(record, reading: reading), "邮件 · 182 KB · 2 个附件")

    let locked = try XCTUnwrap(supplier.items.first { $0.itemID == fixture.item(35) })
    XCTAssertEqual(FilePreview.note(locked), "文件有密码，整理设备没有打开")
    let big = try XCTUnwrap(supplier.items.first { $0.itemID == fixture.item(36) })
    XCTAssertEqual(FilePreview.note(big), "超过 25 MB，只留在这台 Mac")
    let waiting = try XCTUnwrap(supplier.items.first { $0.itemID == fixture.item(37) })
    XCTAssertEqual(FilePreview.note(waiting), "验收标准 v2 一、外观：无划痕、无色差。")
    XCTAssertEqual(ItemKind(waiting).fileKind, .document)

    let export = EventPlainTextFormatter(timeZone: fixture.zone).format(supplier)
    XCTAssertTrue(export.contains(EventPlainTextFormatter.preambleWithFileSummary), export)
    XCTAssertTrue(
      export.contains(
        "· Re 包装盒报价.eml\n文件：邮件 · 182 KB · 2 个附件\n文件概要：林经理发来新报价：3.20 元/个，10 月 8 日前确认\n"
          + "> 发件人：林经理 <lin@example.invalid>\n> 收件人：陈姐 <chen@example.invalid>"), export)
    XCTAssertTrue(export.contains("> [附件] 报价单-新尺寸.xlsx：3 档起订量的单价"), export)
    XCTAssertTrue(export.contains("> | 乙印务 | 2.95 | 10,000 | 20 天 |"), export)
    XCTAssertTrue(export.contains("> [文件有密码，整理设备没有打开]"), export)
    XCTAssertTrue(export.contains("> [超过 25 MB，只留在这台 Mac]"), export)
    // Every line the device wrote is either labelled or quoted.
    for line in export.split(separator: "\n") where line.contains("乙印务") {
      XCTAssertTrue(line.hasPrefix("> ") || line.hasPrefix("文件概要："), String(line))
    }

    // Search finds a file by what was read and by its name.
    let home = try XCTUnwrap(projection.home().first { $0.eventID == "ev-supplier" })
    XCTAssertTrue(home.matches("乙印务"))
    XCTAssertTrue(home.matches("全年订单明细"))
    XCTAssertEqual(home.coverText?.heading, "林经理.vcf")

    // A sheet's Markdown tables are drawn as tables, their rule dropped.
    let blocks = MemoryReadingBlocks.parse(MemoryFilesFixture.readings[fixture.item(30)]!)
    XCTAssertEqual(blocks.first, .heading("报价（第 1 页）"))
    guard case .table(let header, let rows) = blocks[1] else { return XCTFail("table") }
    XCTAssertEqual(header, ["供应商", "单价（元）", "起订量", "交期"])
    XCTAssertEqual(rows.count, 3)
    XCTAssertEqual(rows[1], ["乙印务", "2.95", "10,000", "20 天"])
    XCTAssertEqual(blocks.count, 4)

    let demo = try XCTUnwrap(projection.event(id: "ev-demo"))
    XCTAssertEqual(demo.items.map(\.itemID), [fixture.item(40)])
    XCTAssertEqual(demo.items.first?.record?.keyframes.count, 4)
    let video = EventPlainTextFormatter(timeZone: fixture.zone).format(demo)
    XCTAssertTrue(video.contains("> [视频画面 4 张：0:00、0:48、2:11、4:07]"), video)
    // A keyframe whose recording is not in the list is a row of its own.
    let alone = MemoryProjection.withoutShownKeyframes([projection.item(fixture.item(42))])
    XCTAssertEqual(alone.count, 1)
    XCTAssertEqual(ItemKind(alone[0]).isKeyframe, true)
  }

  /// The real pages build their state without a window, so a regression in
  /// the read model shows up in ordinary test runs too.
  func testFixtureDrivesEveryPage() {
    let projection = MemorySnapshotFixture.sparkProjection(questions: true)
    let screen = state(projection)
    XCTAssertEqual(screen.home.count, 6)
    XCTAssertEqual(screen.unfiled.count, 3)
    XCTAssertEqual(screen.bannerQuestion?.questionID, "q-item")
    // 我 is the Mac's user: never one of the people.
    XCTAssertEqual(screen.recentPeople.filter(\.isNamed).count, 5)
    XCTAssertFalse(screen.recentPeople.contains { $0.name == "我" })
    XCTAssertFalse(screen.home.flatMap(\.people).contains { $0.name == "我" })
    XCTAssertNotNil(projection.event(id: "ev-rent"))
    // The Home row, the loom lanes and the cards draw only people who
    // matter; everyone keeps a place on the 人物 page.
    let shown = Set(screen.featuredPeople.map(\.personID))
    XCTAssertFalse(shown.isEmpty)
    XCTAssertTrue(shown.isSubset(of: Set(screen.recentPeople.map(\.personID))))
    for entry in screen.home {
      XCTAssertTrue(Set(entry.shownPeople.map(\.personID)).isSubset(of: shown), entry.title)
    }
    for loom in screen.looms.values {
      for lane in loom.lanes {
        XCTAssertTrue(Set(lane.people.map(\.personID)).isSubset(of: shown), lane.title)
      }
    }
  }

  /// At scale Home shows a page of cards and eight people; the split meeting
  /// shows one part per event with a link to the other two.
  func testScaleFixtureDrivesThePages() throws {
    let model = MemoryReadModel(MemoryScaleFixture.projection)
    XCTAssertEqual(model.home.count, MemoryScaleFixture.eventCount)
    XCTAssertEqual(model.unfiled.count, MemoryScaleFixture.unfiledCount)
    XCTAssertGreaterThan(model.recentPeople.count, LoomPanel.peopleChips)
    // The Home row: in the most matters first, each a name.
    let counts = model.featuredPeople.map(\.events.count)
    XCTAssertEqual(counts, counts.sorted(by: >))
    XCTAssertTrue(
      model.featuredPeople.allSatisfy { MemoryProjection.looksLikePersonName($0.name) })
    XCTAssertGreaterThan(model.home.count, HomePage.pageSize)
    let detail = try XCTUnwrap(model.projection.event(id: "ev-1"))
    let part = try XCTUnwrap(detail.items.first { $0.segment != nil })
    XCTAssertEqual(part.siblings.map(\.eventID), ["ev-0", "ev-2"])
    XCTAssertEqual(SiblingsLink.recordWord(part), "会议")
    let preview = TranscriptPreview(item: part, expanded: true, people: detail.people)
    XCTAssertEqual(preview.turns.map(\.name), ["欧阳帆", "石小满"])
    XCTAssertTrue(TranscriptPreview.text(of: part).contains("货架"))
    XCTAssertFalse(TranscriptPreview.text(of: part).contains("市集"))
    // A speaker named "中文名 English NAME" takes the colour of the person
    // the organizer named 中文名.
    let market = try XCTUnwrap(model.projection.event(id: "ev-0"))
    let marketPart = try XCTUnwrap(market.items.first { $0.segment != nil })
    let marketTurns = TranscriptPreview(item: marketPart, expanded: true, people: market.people)
      .turns
    XCTAssertEqual(marketTurns.first?.name, "苗青禾 Miao QINGHE")
    XCTAssertEqual(
      marketTurns.first?.colorIndex, market.people.first { $0.name == "苗青禾" }?.colorIndex)
  }

  /// The organizing device's reading reaches the timeline row and the
  /// export; a pasted chat and the reading read as turns.
  func testReadingAndChatTurnsReachTheRows() throws {
    let fixture = MemorySnapshotFixture.self
    let projection = fixture.sparkProjection(questions: false)
    let mom = try XCTUnwrap(projection.event(id: "ev-mom"))
    let shot = try XCTUnwrap(mom.items.first { $0.itemID == fixture.item(14) })
    XCTAssertEqual(shot.remoteReading, fixture.screenshotReading)
    // The row shows what was read, without the device's summary and without
    // the time stamp every message repeats; the summary is its own line.
    XCTAssertEqual(
      TranscriptPreview.text(of: shot),
      """
      姐姐：妈妈的号约好了，下周二上午 9:30 市一医院 B 超
      我：好，我请半天假陪她去
      姐姐：医保卡、就诊卡和上次的报告都带上
      """)
    XCTAssertEqual(TranscriptPreview.readingSummary(of: shot), "姐姐约好妈妈周二的 B 超复查，我请假陪同")
    let preview = TranscriptPreview(item: shot, expanded: false, people: mom.people)
    XCTAssertEqual(preview.turns.map(\.name), ["姐姐", "我", "姐姐"])
    let export = EventPlainTextFormatter(timeZone: fixture.zone).format(mom)
    XCTAssertTrue(
      export.contains(
        "· 截图\n读图概要：姐姐约好妈妈周二的 B 超复查，我请假陪同\n"
          + "> [截图中的文字]\n> 姐姐：妈妈的号约好了"), export)
    XCTAssertTrue(export.contains(EventPlainTextFormatter.preambleWithSummary), export)
    XCTAssertFalse(export.contains("[9月25日 20:14]"), export)
    XCTAssertEqual(preview.turns.first?.text, "妈妈的号约好了，下周二上午 9:30 市一医院 B 超")
    // Search reads the reading as sent and its summary.
    let home = try XCTUnwrap(projection.home().first { $0.eventID == "ev-mom" })
    XCTAssertTrue(home.searchText.contains("姐姐：妈妈的号约好了"))
    XCTAssertTrue(home.searchText.contains(fixture.screenshotSummary))

    // One named line of someone in the event reads as their turn.
    let single = try XCTUnwrap(mom.items.first { $0.itemID == fixture.item(6) })
    let singleTurns = TranscriptPreview(item: single, expanded: false, people: mom.people).turns
    XCTAssertEqual(singleTurns.map(\.name), ["妈妈"])
    XCTAssertEqual(singleTurns.first?.colorIndex, mom.people.first { $0.name == "妈妈" }?.colorIndex)
    XCTAssertTrue(TranscriptPreview(item: single, expanded: false, people: []).turns.isEmpty)

    let rent = try XCTUnwrap(projection.event(id: "ev-rent"))
    let chat = try XCTUnwrap(rent.items.first { $0.itemID == fixture.item(1) })
    let turns = TranscriptPreview(item: chat, expanded: false, people: rent.people).turns
    XCTAssertEqual(turns.map(\.name), ["王姐", "我", "王姐"])
    XCTAssertEqual(turns.last?.text, "那我跟家里商量一下， 明天回你。")
    // 王姐 is one of the event's people and keeps her colour; 我 takes none.
    XCTAssertNotNil(turns[0].colorIndex)
    XCTAssertNil(turns[1].colorIndex)
  }

  /// Cards with no screenshot show the first lines of their newest text;
  /// cards with one show no text cover.
  func testCardsWithoutAScreenshotHaveATextCover() throws {
    let home = MemorySnapshotFixture.sparkProjection(questions: false).home()
    func cover(_ id: String) -> MemoryCoverText? { home.first { $0.eventID == id }?.coverText }
    XCTAssertNil(cover("ev-rent"))
    XCTAssertNil(cover("ev-mom"))
    XCTAssertEqual(cover("ev-report"), MemoryCoverText(heading: "汇报.pdf", lines: ["季度汇报草稿 v3"]))
    XCTAssertEqual(cover("ev-camp"), MemoryCoverText(heading: "微信", lines: ["周六出发，帐篷还差一顶。"]))
    XCTAssertEqual(cover("ev-net")?.lines, ["师傅说周日上午来装。"])
  }

  /// A crop that would end inside a line of text ends at the gap above it,
  /// and the frame keeps its shape.
  func testScreenshotCropEndsBetweenLines() throws {
    let image = try XCTUnwrap(
      MemorySnapshotFixture.chatScreenshot().cgImage(
        forProposedRect: nil, context: nil, hints: nil))
    // A Home cover: about 321 × 132 points.
    let aspect: CGFloat = 321.0 / 132.0
    let visible = Int((CGFloat(image.width) / aspect).rounded(.down))
    let row = try XCTUnwrap(ScreenshotCut.gapRow(image, visible: visible))
    XCTAssertLessThan(row, visible)
    XCTAssertGreaterThanOrEqual(row, Int(CGFloat(visible) * ScreenshotCut.lowestShare))
    guard case .clean(let cut) = ScreenshotCut.cut(image, aspect: aspect) else {
      return XCTFail("expected a clean cut")
    }
    XCTAssertEqual(cut.width, image.width)
    XCTAssertEqual(cut.height, visible)
    // A frame taller than the screenshot's shape cuts nothing.
    guard case .whole = ScreenshotCut.cut(image, aspect: 0.3) else {
      return XCTFail("expected the whole screenshot")
    }
  }

  /// Facts in a fixed order, and no date chip beside a text that says it.
  func testFactsAreOrderedAndDatesNotRepeated() throws {
    let rent = try XCTUnwrap(
      MemorySnapshotFixture.sparkProjection(questions: false).event(id: "ev-rent"))
    XCTAssertEqual(
      rent.statusFacts.map(\.text),
      ["周五去签字", "9月28日前把押金转过去", "热水器周六修", "房租涨 200", "押金一个月"])
    XCTAssertEqual(rent.statusFacts.map { $0.chipDay?.day }, [26, nil, nil, nil, nil])
  }

  /// Before the first load nothing is drawn: not the first-run page.
  func testNotLoadedIsNotEmpty() {
    let notLoaded = MemoryScreenState()
    XCTAssertFalse(notLoaded.isLoaded)
    let empty = state(MemoryProjection(events: [], records: [], now: MemorySnapshotFixture.now))
    XCTAssertTrue(empty.isLoaded)
    XCTAssertTrue(empty.home.isEmpty)
  }

  /// A card without a written status shows no excerpt as its status line,
  /// and its meta line says how many items it has instead.
  func testFallbackStatusIsNotShownAsAStatus() throws {
    let local = state(MemorySnapshotFixture.localProjection, mode: .local)
    let mom = try XCTUnwrap(local.home.first { $0.eventID == "ev-mom" })
    XCTAssertTrue(mom.statusIsFallback)
    XCTAssertNil(mom.realStatus)
    XCTAssertTrue(mom.metaLine(local).hasSuffix("3 条"))
    let rent = try XCTUnwrap(local.home.first { $0.eventID == "ev-rent" })
    XCTAssertEqual(rent.realStatus, "周五去签字")
    XCTAssertFalse(rent.metaLine(local).contains("条"))
  }

  /// Search finds what was said, not only titles and names.
  func testHomeSearchFindsWhatWasSaid() {
    let screen = state(MemorySnapshotFixture.sparkProjection(questions: false))
    XCTAssertEqual(screen.home.filter { $0.matches("热水器") }.map(\.eventID), ["ev-rent"])
    XCTAssertEqual(screen.home.filter { $0.matches("合同第 3 页") }.map(\.eventID), ["ev-rent"])
  }

  /// Move targets are every other event, not the first fifteen.
  func testMoveTargetsAreEveryOtherEvent() {
    let screen = state(MemorySnapshotFixture.sparkProjection(questions: false))
    XCTAssertEqual(
      ItemMenu.targets(screen, excluding: "ev-rent").map(\.eventID),
      ["ev-mom", "ev-report", "ev-camp", "ev-car", "ev-net"])
  }

  /// White on the dark accent is about 2.6:1; the on-accent label is not.
  func testLabelsOnTheAccentKeepContrast() {
    for palette in [ZhijiPalette.light, .dark] {
      XCTAssertGreaterThanOrEqual(
        contrast(palette.onAccent, palette.accent), 4.5, palette.isDark ? "dark" : "light")
    }
  }

  private func contrast(_ a: Color, _ b: Color) -> Double {
    func luminance(_ color: Color) -> Double {
      let ns = NSColor(color).usingColorSpace(.sRGB)!
      func channel(_ c: CGFloat) -> Double {
        let v = Double(c)
        return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
      }
      return 0.2126 * channel(ns.redComponent) + 0.7152 * channel(ns.greenComponent)
        + 0.0722 * channel(ns.blueComponent)
    }
    let (la, lb) = (luminance(a), luminance(b))
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  }
}
