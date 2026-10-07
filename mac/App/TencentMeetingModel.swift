import BestASRMemoryUI
import Combine
import CoreGraphics
import Foundation
import MindloomTencentMeeting

/// Settings › 入口 › 腾讯会议 (ENTRY-013): the entry's state as last saved,
/// the QR code while connecting, and the running parts. The work is done
/// by `DictationAppModel+TencentMeeting`.
@MainActor
final class TencentMeetingModel: ObservableObject {
  @Published var state = TencentMeetingState()
  @Published var connecting: SettingsTencentMeeting.Connecting?
  @Published var qr: CGImage?
  @Published var working = false

  var sync: TencentMeetingSync?
  var runner: (any TencentMeetingRunning)?
  /// tmeet, its login folder, the key and the helper check (a new login is
  /// made with the same, in `newLoginDirectory`).
  var environment: TmeetEnvironment?
  var keyStore: (any TencentMeetingKeyStore)?
  var stateDirectory: URL?
  var newLoginDirectory: URL?
  var helper: URL?
  var authorizationURL: URL?
  var loginCancellation: TencentMeetingCancellation?
  var loop: Task<Void, Never>?
  var wakeObserver: NSObjectProtocol?

  /// Regular checks while the Mac is awake (light, or full when the last
  /// full one is three hours old: `TencentMeetingSync.kind(for:state:now:)`).
  static let interval: Duration = .seconds(90 * 60)

  var isConnected: Bool { state.connectedAt != nil }

  /// The Settings group's values.
  func settings(isOn: Bool, now: Date = Date()) -> SettingsTencentMeeting {
    let line = TencentMeetingStatus.line(state: state, helperAvailable: helper != nil, now: now)
    let actionTitle: String? =
      switch line.action {
      case .connect?: "连接…"
      case .reconnect?: "重新连接…"
      case .learnMore?: "进一步了解…"
      case .retry?: "重试"
      case nil: nil
      }
    let day = DateFormatter()
    day.locale = Locale(identifier: "zh_CN")
    day.dateFormat = "M月d日"
    let rows = TencentMeetingStatus.rows(state: state, now: now).map { row in
      SettingsTencentMeeting.Row(
        id: row.id, title: row.title, date: row.date.map(day.string(from:)) ?? "",
        label: TencentMeetingStatus.rowLabel(row.kind),
        opensPage: row.kind == .canApply && row.pageURL != nil)
    }
    var question: SettingsTencentMeeting.Question?
    if isConnected, case .notAsked = state.backfill {
      let waiting = waitingForAnswer(now: now)
      if waiting > 0 {
        question = SettingsTencentMeeting.Question(
          title: TencentMeetingStatus.backfillTitle(days: 30),
          message: TencentMeetingStatus.backfillMessage(count: waiting))
      }
    }
    return SettingsTencentMeeting(
      isOn: isOn, status: isOn ? line.text : "已关闭", statusIsProblem: isOn && line.isProblem,
      actionTitle: isOn ? actionTitle : nil,
      permissionLine: TencentMeetingStatus.listTitle(state: state, now: now), rows: rows,
      incompleteLine: isOn && isConnected
        ? TencentMeetingStatus.incompleteLine(state: state, now: now) : nil,
      connecting: isOn ? connecting : nil, question: isOn ? question : nil, working: working)
  }

  /// Viewable recordings from before the connection, waiting for the answer.
  func waitingForAnswer(now: Date) -> Int {
    guard let connectedAt = state.connectedAt else { return 0 }
    return state.recordings.values.filter {
      $0.status == .pending && ($0.end ?? $0.start ?? .distantPast) < connectedAt
    }.count
  }
}
