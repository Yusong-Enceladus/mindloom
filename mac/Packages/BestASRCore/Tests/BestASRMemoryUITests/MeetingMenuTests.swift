import BestASRDomain
import BestASRMemory
import XCTest

@testable import BestASRMemoryUI

/// The menu bar's meeting rows and 「刚收进来」's words for meetings and
/// imports (v12 1C, ALIGNMENT 收2-2, 收2-3, 收2-6).
final class MeetingMenuTests: XCTestCase {
  private let link = MemoryLinkState(status: .connected)
  private let recording = MemoryCaptureIndicator(
    kind: .room, title: "正在记录会议", detail: "12:04", elapsed: 724)

  private func titles(_ rows: [MenuBarExtraRow]) -> [String] {
    rows.compactMap {
      switch $0 {
      case .action(_, let title, _, _), .header(let title, _, _, _), .submenu(_, let title, _, _):
        title
      case .separator: nil
      }
    }
  }

  /// Before a meeting: 「录：腾讯会议 ›」 with the choices, the chosen one ticked.
  func testIdleMenuSaysWhatTheMeetingRecords() throws {
    let options = [
      MenuBarExtraOption(id: "entire-system", title: "整台电脑", checked: false),
      MenuBarExtraOption(id: "bundle:com.tencent.meeting", title: "腾讯会议", checked: true),
    ]
    let rows = MenuBarExtraRow.rows(
      link: link, recording: nil,
      meeting: MenuBarMeetingInput(sound: .computer(source: "腾讯会议", options: options)))
    XCTAssertEqual(titles(rows).prefix(2), ["开始记录会议", "录制：腾讯会议"])
    let submenu = try XCTUnwrap(
      rows.first {
        if case .submenu = $0 { true } else { false }
      })
    guard case .submenu(let id, _, _, let listed) = submenu else { return XCTFail() }
    XCTAssertEqual(id, "source")
    XCTAssertEqual(listed, options)
  }

  /// v12 integration: both submenus before a meeting — what it records
  /// (1C, with its choices) and 最近记录 (find, filled by the App) — one
  /// row kind with the options it has.
  func testIdleMenuHasTheSourceAndTheRecentRecords() {
    let options = [MenuBarExtraOption(id: "entire-system", title: "整台电脑", checked: true)]
    let rows = MenuBarExtraRow.rows(
      link: link, recording: nil,
      meeting: MenuBarMeetingInput(sound: .computer(source: "整台电脑", options: options)))
    let submenus = rows.compactMap { row -> (String, Int)? in
      guard case .submenu(let id, _, _, let listed) = row else { return nil }
      return (id, listed.count)
    }
    XCTAssertEqual(submenus.map(\.0), ["source", "recent"])
    XCTAssertEqual(submenus.map(\.1), [1, 0])
    XCTAssertEqual(titles(rows).prefix(3), ["开始记录会议", "录制：整台电脑", "最近记录"])
  }

  /// Not allowed: says only the microphone can be recorded and offers the
  /// system's setting; allowed but not yet seen: says to open Mindloom again.
  func testIdleMenuWithoutTheComputersSound() {
    let denied = MenuBarExtraRow.rows(
      link: link, recording: nil,
      meeting: MenuBarMeetingInput(sound: .microphoneOnly(needsRelaunch: false)))
    XCTAssertEqual(titles(denied).prefix(3), ["开始记录会议", "仅录制麦克风", "允许录制电脑声音…"])
    XCTAssertTrue(
      denied.contains(.action(id: "allow-computer-sound", title: "允许录制电脑声音…", symbol: nil)))
    let relaunch = MenuBarExtraRow.rows(
      link: link, recording: nil,
      meeting: MenuBarMeetingInput(sound: .microphoneOnly(needsRelaunch: true)))
    XCTAssertEqual(
      titles(relaunch).prefix(3), ["开始记录会议", "仅录制麦克风", "重新打开 Mindloom 后可录制电脑声音"])
  }

  /// While recording: 「只录了麦克风」 (or what it records), and the caption
  /// strip's switch.
  func testRecordingMenuSaysMicrophoneOnlyAndOffersCaptions() {
    let micOnly = MenuBarExtraRow.rows(
      link: link, recording: recording,
      meeting: MenuBarMeetingInput(
        sound: .microphoneOnly(needsRelaunch: false), captionsShown: true))
    XCTAssertEqual(
      titles(micOnly),
      ["正在记录会议", "仅录制了麦克风", "暂停", "结束并保存", "放弃此次记录…", "隐藏字幕", "打开 Mindloom", "设置…"])
    let computer = MenuBarExtraRow.rows(
      link: link, recording: recording,
      meeting: MenuBarMeetingInput(
        sound: .computer(source: "腾讯会议", options: []), captionsShown: false))
    XCTAssertEqual(titles(computer)[1], "录制：腾讯会议")
    XCTAssertTrue(
      computer.contains(.action(id: "show-captions", title: "显示字幕", symbol: "captions.bubble")))
    XCTAssertFalse(computer.contains { if case .submenu = $0 { true } else { false } })
  }

  /// Review v12-B #7: demo mode says so first, recording or not; a needed
  /// relaunch says to open the demo way again (a plain reopen would put the
  /// owner's library on screen).
  func testDemoModeSaysSoFirst() {
    for recording in [nil, self.recording] {
      let rows = MenuBarExtraRow.rows(link: link, recording: recording, demo: true)
      XCTAssertEqual(
        rows.first, .header(title: MindloomDemoMarker.menuHeader, symbol: MindloomDemoMarker.symbol)
      )
      XCTAssertEqual(rows.dropFirst().first, .separator)
      XCTAssertEqual(titles(rows).first, "演示中 · 演示资料库")
    }
    let relaunch = MenuBarExtraRow.rows(
      link: link, recording: nil,
      meeting: MenuBarMeetingInput(sound: .microphoneOnly(needsRelaunch: true)), demo: true)
    XCTAssertTrue(titles(relaunch).contains("以演示方式重新打开后可录制电脑声音"))
    XCTAssertFalse(titles(relaunch).contains("重新打开 Mindloom 后可录制电脑声音"))
    XCTAssertFalse(
      titles(MenuBarExtraRow.rows(link: link, recording: nil)).contains(
        MindloomDemoMarker.menuHeader))
    XCTAssertFalse(MemoryScreenState().demo)
  }

  /// Without meeting state the rows are §3.2's, with v12 find's 最近记录.
  func testRowsWithoutMeetingStateAreUnchanged() {
    XCTAssertEqual(
      titles(MenuBarExtraRow.rows(link: link, recording: nil)),
      ["开始记录会议", "最近记录", "DGX Spark 已连接", "打开 Mindloom", "设置…"])
    XCTAssertEqual(
      titles(MenuBarExtraRow.rows(link: link, recording: recording)),
      ["正在记录会议", "暂停", "结束并保存", "放弃此次记录…", "打开 Mindloom", "设置…"])
  }

  /// 「刚收进来」: 录音 · 视频 by what was imported; a microphone-only
  /// meeting says so.
  func testWaitingWords() {
    func record(_ mode: SessionInputMode, filename: String? = nil, minutes: Double = 0)
      -> MemoryItemRecord
    {
      MemoryItemRecord(
        sessionID: SessionID(), inputMode: mode, itemKind: nil, title: "t",
        startedAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
        sourceBundleID: nil, sourceDisplayName: filename, sourceIdentifier: filename,
        text: "下周三之前把三组数据跑完", durationNanoseconds: UInt64(minutes * 60e9))
    }
    let audio = MemoryWaitingCapture(
      record: record(.importedMedia, filename: "周会.m4a", minutes: 12))
    XCTAssertEqual(audio.kind, "录音 · 12 分钟")
    XCTAssertEqual(audio.symbol, "waveform")
    XCTAssertNil(audio.thumbnail)
    let video = MemoryWaitingCapture(
      record: record(.importedMedia, filename: "组会录像.mov", minutes: 42))
    XCTAssertEqual(video.kind, "视频 · 42 分钟")
    XCTAssertEqual(video.thumbnail, .video)
    XCTAssertEqual(MemoryWaitingCapture(record: record(.roomMicrophone)).kind, "会议录音 · 仅录制了麦克风")
    XCTAssertEqual(MemoryWaitingCapture(record: record(.systemAudio)).kind, "会议录音")
  }
}
