import Foundation

/// The one line Settings shows for the Tencent Meeting entry, and the
/// action next to it.
public struct TencentMeetingStatusLine: Equatable, Sendable {
  public enum Action: Equatable, Sendable {
    /// 「连接…」: show the QR code.
    case connect
    /// 「重新连接…」: a new login (made beside the one in use while it holds).
    case reconnect
    /// 「进一步了解…」: Tencent's page about tmeet and account editions.
    case learnMore
    /// 「重试」: check again now (the system then asks to allow access).
    case retry
  }

  public let text: String
  public let action: Action?
  /// Shown in the warning colour.
  public let isProblem: Bool
}

/// A meeting the account may not read yet, one without transcript text, or
/// one whose transcript could not be added yet. One row per meeting.
public struct TencentMeetingListRow: Equatable, Identifiable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// `can_apply`: the owner can ask on the recording's page.
    case canApply
    case passwordRequired
    case noTranscript
    /// Tried and not added yet; tried again once a day.
    case notAdded
  }

  /// A record file number of the meeting (the one whose page opens).
  public let id: String
  public let title: String
  public let date: Date?
  public let kind: Kind
  public let pageURL: URL?
}

/// Settings copy (docs/UI-COPY.md): what is happening, and what the owner
/// can do. Never shown on Home.
public enum TencentMeetingStatus {
  /// Tencent's page about the command-line tool and which accounts may use it.
  public static let learnMoreURL = URL(
    string: "https://meeting.tencent.com/support/topic/2236/index.html")!

  public static let connectTitle = "连接腾讯会议"
  public static let connectMessage =
    "用 iPhone 的相机扫描二维码，在手机上登录腾讯会议并允许。也可以在这台 Mac 的浏览器中打开，用腾讯会议 App 扫描网页上的二维码。"
  public static let codeExpired = "二维码已过期"
  public static let connectFailed = "无法连接腾讯会议。请稍后再试。"
  public static let helperMissing = "无法启动腾讯会议连接。请重新安装 Mindloom。"
  public static let keyUnavailable = "无法读取这台 Mac 上的腾讯会议登录信息。"
  public static let listingUnreadable = "无法读取腾讯会议的会议列表。稍后将重试。"

  public static func line(
    state: TencentMeetingState, helperAvailable: Bool, now: Date = Date(),
    calendar: Calendar = .current
  ) -> TencentMeetingStatusLine {
    if !helperAvailable || state.lastFailure == .helperMissing {
      return TencentMeetingStatusLine(text: helperMissing, action: nil, isProblem: true)
    }
    guard state.connectedAt != nil else {
      return TencentMeetingStatusLine(text: "未连接", action: .connect, isProblem: false)
    }
    switch state.lastFailure {
    case .notConnected?:
      return TencentMeetingStatusLine(text: "需要重新连接", action: .reconnect, isProblem: true)
    case .accountNotAvailable?:
      return TencentMeetingStatusLine(
        text: "此账户暂时无法使用这项功能", action: .learnMore, isProblem: true)
    case .keyUnavailable?:
      return TencentMeetingStatusLine(text: keyUnavailable, action: .retry, isProblem: true)
    default:
      break
    }
    if let paused = state.pausedUntil, paused > now {
      return TencentMeetingStatusLine(text: "今天的查询次数已用完，明天继续", action: nil, isProblem: true)
    }
    if state.lastFailure == .network || state.lastFailure == .timedOut {
      return TencentMeetingStatusLine(text: "无法连接腾讯会议。稍后将重试。", action: nil, isProblem: true)
    }
    if let failure = state.lastFailure, !failure.stopsPass {
      // Only a listing leaves one of these as the pass's failure.
      return TencentMeetingStatusLine(text: listingUnreadable, action: nil, isProblem: true)
    }
    if let ends = state.refreshTokenExpires, state.refreshExtendsLogin != true,
      ends.timeIntervalSince(now) < 3 * 86_400
    {
      let start = calendar.startOfDay(for: now)
      let days =
        calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: ends))
        .day ?? 0
      let text =
        ends <= now
        ? "需要重新连接" : days <= 0 ? "腾讯会议的连接将在今天过期" : "腾讯会议的连接将在 \(days) 天后过期"
      return TencentMeetingStatusLine(text: text, action: .reconnect, isProblem: true)
    }
    if state.recordings.values.contains(where: {
      $0.status == .pending && $0.lastError == .generating
    }) {
      return TencentMeetingStatusLine(
        text: "腾讯会议正在生成转写，完成后自动添加", action: nil, isProblem: false)
    }
    let today = TencentMeetingSync.dayKey(now, calendar: calendar)
    if state.day == today, state.addedToday > 0 {
      return TencentMeetingStatusLine(
        text: "已连接 · 今天添加了 \(state.addedToday) 个会议转写", action: nil, isProblem: false)
    }
    if let last = state.lastSuccess {
      return TencentMeetingStatusLine(
        text: "已连接 · 上次检查：\(when(last, now: now, calendar: calendar))", action: nil,
        isProblem: false)
    }
    return TencentMeetingStatusLine(text: "已连接", action: nil, isProblem: false)
  }

  /// The title of the list in Settings: 「有 2 个会议需要申请查看」, else
  /// 「有 1 个会议的转写尚未添加」, else 「有 3 个会议没有转写文字」; nil
  /// when there is none. Counted by meeting.
  public static func listTitle(state: TencentMeetingState, now: Date = Date()) -> String? {
    let rows = rows(state: state, now: now)
    let asking = rows.filter { $0.kind == .canApply || $0.kind == .passwordRequired }.count
    if asking > 0 { return "有 \(asking) 个会议需要申请查看" }
    let notAdded = rows.filter { $0.kind == .notAdded }.count
    if notAdded > 0 { return "有 \(notAdded) 个会议的转写尚未添加" }
    let empty = rows.filter { $0.kind == .noTranscript }.count
    return empty > 0 ? "有 \(empty) 个会议没有转写文字" : nil
  }

  /// 「有 2 个会议需要申请查看」, or nil (counted by meeting).
  public static func permissionLine(state: TencentMeetingState, now: Date = Date()) -> String? {
    let count = rows(state: state, now: now).filter {
      $0.kind == .canApply || $0.kind == .passwordRequired
    }.count
    return count == 0 ? nil : "有 \(count) 个会议需要申请查看"
  }

  /// 「腾讯会议未列出 1 个会议的全部录制」 for meetings in the window
  /// Tencent counts more recordings for than it lists in full, or nil.
  public static func incompleteLine(state: TencentMeetingState, now: Date = Date()) -> String? {
    let since = now.addingTimeInterval(-30 * 86_400)
    let count = state.recordCounts.values.filter {
      $0.isIncomplete && ($0.start ?? now) >= since
    }.count
    return count == 0 ? nil : "腾讯会议未列出 \(count) 个会议的全部录制"
  }

  /// Meetings of the last 30 days that need the owner or could not be
  /// added, newest first: one row per meeting (and kind), however many of
  /// its recordings it concerns.
  public static func rows(state: TencentMeetingState, now: Date = Date()) -> [TencentMeetingListRow]
  {
    let since = now.addingTimeInterval(-30 * 86_400)
    var byMeeting: [String: (id: String, job: TencentMeetingRecordingJob)] = [:]
    var kinds: [String: TencentMeetingListRow.Kind] = [:]
    for (id, job) in state.recordings {
      guard (job.start ?? job.end ?? now) >= since else { continue }
      let kind: TencentMeetingListRow.Kind
      switch (job.status, job.permission) {
      case (.needsPermission, .passwordRequired): kind = .passwordRequired
      case (.needsPermission, .canView): continue
      case (.needsPermission, _): kind = .canApply
      case (.noContent, _): kind = .noTranscript
      case (.failed, _): kind = .notAdded
      default: continue
      }
      let key = [job.meetingID, job.subMeetingID ?? "", "\(kind)"].joined(separator: "|")
      // The meeting's newest recording with a page stands for it.
      if let known = byMeeting[key] {
        let knownPage = TencentMeetingListingParser.pageURL(known.job.pageURL) != nil
        let page = TencentMeetingListingParser.pageURL(job.pageURL) != nil
        guard
          (page && !knownPage)
            || (page == knownPage
              && (job.start ?? .distantPast, id) > (known.job.start ?? .distantPast, known.id))
        else { continue }
      }
      byMeeting[key] = (id, job)
      kinds[key] = kind
    }
    return byMeeting.compactMap { key, value -> TencentMeetingListRow? in
      guard let kind = kinds[key] else { return nil }
      return TencentMeetingListRow(
        id: value.id, title: value.job.title, date: value.job.start, kind: kind,
        pageURL: TencentMeetingListingParser.pageURL(value.job.pageURL))
    }
    .sorted { ($0.date ?? .distantPast, $0.id) > ($1.date ?? .distantPast, $1.id) }
  }

  /// What a row says on its right.
  public static func rowLabel(_ kind: TencentMeetingListRow.Kind) -> String {
    switch kind {
    case .canApply: "申请查看…"
    case .passwordRequired: "需要密码"
    case .noTranscript: "这场会没有转写文字"
    case .notAdded: "未能添加，稍后将重试"
    }
  }

  /// The first question after connecting.
  public static func backfillTitle(days: Int) -> String { "添加过去 \(days) 天的会议转写？" }
  public static func backfillMessage(count: Int) -> String {
    "找到 \(count) 个你可以查看的会议转写。之后的会议转写会自动添加。"
  }

  static func when(_ date: Date, now: Date, calendar: Calendar) -> String {
    let time = DateFormatter()
    time.locale = Locale(identifier: "zh_CN")
    time.dateFormat = "HH:mm"
    if calendar.isDate(date, inSameDayAs: now) { return "今天 " + time.string(from: date) }
    let day = DateFormatter()
    day.locale = Locale(identifier: "zh_CN")
    day.dateFormat = "M月d日 HH:mm"
    return day.string(from: date)
  }
}
