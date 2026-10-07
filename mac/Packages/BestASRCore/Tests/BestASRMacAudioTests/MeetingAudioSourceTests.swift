import BestASRDictation
import BestASRMacAudio
import XCTest

/// 开始记录会议 must not regress (v12 1C, ALIGNMENT 收2-2): v11 recorded the
/// whole computer whatever was playing, and with no 屏幕与系统录音 it
/// silently recorded the microphone alone. Synthetic sources only.
final class MeetingAudioSourceTests: XCTestCase {
  private let meeting = SystemAudioSource(
    id: "bundle:com.tencent.meeting", displayName: "腾讯会议", bundleID: "com.tencent.meeting",
    isRunningOutput: true)
  private let music = SystemAudioSource(
    id: "bundle:com.apple.Music", displayName: "音乐", bundleID: "com.apple.Music",
    isRunningOutput: true)
  private let idleZoom = SystemAudioSource(
    id: "bundle:us.zoom.xos", displayName: "zoom.us", bundleID: "us.zoom.xos",
    isRunningOutput: false)

  /// The meeting App that is playing sound is chosen by itself.
  func testAutomaticPicksTheMeetingAppThatIsPlaying() {
    let pick = MeetingAudioSourcePolicy.pick(.automatic, sources: [music, meeting])
    XCTAssertEqual(pick.sourceID, meeting.id)
    XCTAssertEqual(pick.title, "腾讯会议")
    XCTAssertTrue(pick.automatic)
    XCTAssertEqual(pick.scope, .application(identity: meeting.id))
  }

  /// A meeting App that plays nothing (the call may be in a browser) is
  /// never picked: the whole computer is recorded then.
  func testAutomaticFallsBackToTheWholeComputer() {
    for sources in [[music], [idleZoom, music], []] {
      let pick = MeetingAudioSourcePolicy.pick(.automatic, sources: sources)
      XCTAssertTrue(pick.isEntireSystem)
      XCTAssertEqual(pick.title, "整台电脑")
      XCTAssertEqual(pick.scope, .entireSystem)
    }
  }

  /// The menu's choice wins; a chosen App that is gone falls back to the
  /// rule.
  func testAChoiceWinsUntilItsAppIsGone() {
    let chosen = MeetingAudioSourcePolicy.pick(
      .application(id: music.id), sources: [meeting, music])
    XCTAssertEqual(chosen.sourceID, music.id)
    XCTAssertFalse(chosen.automatic)
    let whole = MeetingAudioSourcePolicy.pick(.entireSystem, sources: [meeting])
    XCTAssertTrue(whole.isEntireSystem)
    XCTAssertFalse(whole.automatic)
    let gone = MeetingAudioSourcePolicy.pick(.application(id: "bundle:gone"), sources: [meeting])
    XCTAssertEqual(gone.sourceID, meeting.id)
    XCTAssertTrue(gone.automatic)
  }

  /// 「录：… ›」: 整台电脑 first, then Apps playing (meeting Apps first), then
  /// the others; at most eight Apps.
  func testMenuOptionsOrder() {
    let options = MeetingAudioSourcePolicy.options(sources: [idleZoom, music, meeting])
    XCTAssertEqual(options.map(\.title), ["整台电脑", "腾讯会议", "音乐", "zoom.us"])
    XCTAssertEqual(options.map(\.playing), [false, true, true, false])
    let many = (0..<12).map {
      SystemAudioSource(
        id: "app-\($0)", displayName: "App \($0)", bundleID: nil, isRunningOutput: true)
    }
    XCTAssertEqual(MeetingAudioSourcePolicy.options(sources: many).count, 1 + 8)
  }

  func testMeetingAppsAreRecognised() {
    for (bundle, name) in [
      ("com.tencent.meeting", "腾讯会议"), ("com.tencent.voovmeeting", "VooV Meeting"),
      ("us.zoom.xos", "zoom.us"), ("com.microsoft.teams2", "Microsoft Teams"),
      ("com.electron.lark", "飞书"), ("com.alibaba.DingTalkMac", "钉钉"),
    ] {
      XCTAssertTrue(
        MeetingAudioSourcePolicy.isLikelyMeeting(
          SystemAudioSource(id: bundle, displayName: name, bundleID: bundle, isRunningOutput: true)),
        name)
    }
    XCTAssertFalse(MeetingAudioSourcePolicy.isLikelyMeeting(music))
  }

  /// Asked once (the system's prompt) when never asked; granted records the
  /// computer's sound; anything else records the microphone and says so.
  func testPlanByPermission() {
    XCTAssertTrue(MeetingCapturePlan.asksFirst(.notDetermined))
    for state in [
      DictationPermissionState.denied, .granted, .restricted, .revoked, .restartRequired,
    ] {
      XCTAssertFalse(MeetingCapturePlan.asksFirst(state), state.rawValue)
    }
    XCTAssertEqual(MeetingCapturePlan.plan(systemAudio: .granted), .computerSound)
    XCTAssertEqual(
      MeetingCapturePlan.plan(systemAudio: .restartRequired), .microphoneOnly(.relaunch))
    for state in [DictationPermissionState.notDetermined, .denied, .restricted, .revoked] {
      XCTAssertEqual(
        MeetingCapturePlan.plan(systemAudio: state), .microphoneOnly(.notAllowed), state.rawValue)
    }
  }
}
