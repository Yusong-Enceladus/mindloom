import BestASRDictation
import Foundation

// 开始记录会议 (ALIGNMENT 收2-2, v12 1C): which sound a meeting records. The
// meeting App that is producing sound is chosen by itself; the menu bar can
// change it before the meeting starts. Without the 屏幕与系统录音
// permission only the microphone can be recorded, and the menu and the item
// say so (「只录了麦克风」). Pure rules here; the App holds the state.

/// What the user asked the next meeting to record.
public enum MeetingAudioChoice: Equatable, Sendable {
  /// The meeting App producing sound, else the whole computer.
  case automatic
  /// Everything the computer plays.
  case entireSystem
  /// One App (a `SystemAudioSource.id`).
  case application(id: String)
}

/// The sound a meeting records, resolved from a choice and the sources
/// playing now.
public struct MeetingAudioPick: Equatable, Sendable {
  /// `SystemAudioSource.id`, or `MeetingAudioSourcePolicy.entireSystemID`.
  public let sourceID: String
  /// 「腾讯会议」 or 「整台电脑」.
  public let title: String
  /// Chosen by the rule, not by the user.
  public let automatic: Bool

  public init(sourceID: String, title: String, automatic: Bool) {
    self.sourceID = sourceID
    self.title = title
    self.automatic = automatic
  }

  public var isEntireSystem: Bool { sourceID == MeetingAudioSourcePolicy.entireSystemID }

  /// The capture scope for this pick.
  public var scope: SystemAudioCaptureScope {
    isEntireSystem ? .entireSystem : .application(identity: sourceID)
  }
}

/// One row of the menu's 「录：… ›」 list.
public struct MeetingAudioOption: Equatable, Sendable {
  public let id: String
  public let title: String
  /// The App is playing sound now.
  public let playing: Bool

  public init(id: String, title: String, playing: Bool) {
    self.id = id
    self.title = title
    self.playing = playing
  }
}

public enum MeetingAudioSourcePolicy {
  /// The id of 「整台电脑」 (the old capture page's id, kept).
  public static let entireSystemID = "entire-system"
  public static let entireSystemTitle = "整台电脑"
  /// At most this many Apps in the menu (playing ones first).
  public static let menuLimit = 8

  /// Meeting Apps by bundle identifier or name (腾讯会议 and its
  /// international VooV, Zoom, Teams, Webex, 飞书, 钉钉, Google Meet's PWA).
  public static func isLikelyMeeting(_ source: SystemAudioSource) -> Bool {
    let identity = "\(source.bundleID ?? "") \(source.displayName)".lowercased()
    return [
      "wemeet", "tencentmeeting", "tencent meeting", "腾讯会议", "voov",
      "zoom.us", "zoom", "microsoft teams", "com.microsoft.teams", "webex", "feishu",
      "lark", "dingtalk", "钉钉", "飞书", "google meet",
    ].contains(where: identity.contains)
  }

  /// The sound a meeting records. Automatic: the first meeting App that is
  /// playing sound, else the whole computer (an idle meeting App is never
  /// picked: the call may be in a browser). A chosen App that is gone falls
  /// back to the automatic rule.
  public static func pick(_ choice: MeetingAudioChoice, sources: [SystemAudioSource])
    -> MeetingAudioPick
  {
    switch choice {
    case .entireSystem:
      return MeetingAudioPick(sourceID: entireSystemID, title: entireSystemTitle, automatic: false)
    case .application(let id):
      if let source = sources.first(where: { $0.id == id }) {
        return MeetingAudioPick(sourceID: source.id, title: source.displayName, automatic: false)
      }
      return pick(.automatic, sources: sources)
    case .automatic:
      if let meeting = sources.first(where: { $0.isRunningOutput && isLikelyMeeting($0) }) {
        return MeetingAudioPick(sourceID: meeting.id, title: meeting.displayName, automatic: true)
      }
      return MeetingAudioPick(sourceID: entireSystemID, title: entireSystemTitle, automatic: true)
    }
  }

  /// The menu's list: 「整台电脑」, then the Apps playing sound (meeting Apps
  /// first), then the other Apps with sound, at most `menuLimit` Apps.
  public static func options(sources: [SystemAudioSource]) -> [MeetingAudioOption] {
    let playing = sources.filter(\.isRunningOutput)
    let ordered =
      playing.filter(isLikelyMeeting) + playing.filter { !isLikelyMeeting($0) }
      + sources.filter { !$0.isRunningOutput }
    var seen = Set<String>()
    let apps =
      ordered
      .filter { seen.insert($0.id).inserted }
      .prefix(menuLimit)
      .map { MeetingAudioOption(id: $0.id, title: $0.displayName, playing: $0.isRunningOutput) }
    return [MeetingAudioOption(id: entireSystemID, title: entireSystemTitle, playing: false)] + apps
  }
}

/// What 开始记录会议 records, by the 屏幕与系统录音 permission.
public enum MeetingCapturePlan: Equatable, Sendable {
  /// The computer's sound (and the microphone as a second track).
  case computerSound
  /// Only the microphone: the computer's sound is not allowed.
  case microphoneOnly(MeetingMicrophoneOnlyReason)

  /// Never asked: ask once (the system's own prompt) before the first
  /// meeting. Every later state is read only, never asked again.
  public static func asksFirst(_ systemAudio: DictationPermissionState) -> Bool {
    systemAudio == .notDetermined
  }

  public static func plan(systemAudio: DictationPermissionState) -> MeetingCapturePlan {
    switch systemAudio {
    case .granted: .computerSound
    case .restartRequired: .microphoneOnly(.relaunch)
    case .notDetermined, .denied, .restricted, .revoked: .microphoneOnly(.notAllowed)
    }
  }
}

public enum MeetingMicrophoneOnlyReason: Equatable, Sendable {
  /// 屏幕与系统录音 is not allowed for this App.
  case notAllowed
  /// Allowed, but this process sees it only after Mindloom opens again.
  case relaunch
}
