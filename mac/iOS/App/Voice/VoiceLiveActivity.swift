import ActivityKit
import Foundation
import MindloomPhoneKit
import UIKit
import os

/// Starts, updates and ends the voice session's Live Activity (PHONE-SPEC §5.14, §7.4): started
/// when the session starts, updated at the change of minute (and at once when 「充电时保持开启」
/// or 自动结束 changes, or a press restarts the countdown), ended immediately when the session
/// ends. The app runs in the background during a session (audio mode), so the minute updates
/// keep coming. No push, so no push entitlement.
///
/// The content goes stale two minutes ahead (or at the end of the countdown) and is renewed about
/// once a minute while the session runs: if the app dies mid-session, the island stops claiming
/// a live session within two minutes (the widget then says 「语音已结束」).
@MainActor
final class VoiceLiveActivity {
  private var activity: Activity<VoiceActivityAttributes>?
  private weak var voice: VoiceSessionModel?
  private var ticker: Task<Void, Never>?
  private var lastState: VoiceActivityAttributes.ContentState?
  /// The stale date the activity carries now.
  private var staleAt: Date?
  /// How far ahead the content goes stale while the session runs.
  static let staleWindow: TimeInterval = 120
  /// The request failed (or Live Activities are off): no retry until the app is next in front.
  private var unavailable = false
  private let log = Logger(subsystem: PhoneNames.appLog, category: "live-activity")

  func attach(to voice: VoiceSessionModel) {
    self.voice = voice
    let previous = voice.onSessionChange
    voice.onSessionChange = { [weak self] in
      previous?()
      self?.sync()
    }
    VoiceSessionEnding.handler = { [weak voice, weak self] in
      voice?.end()
      // 「结束」 on an activity no session owns (left by a run iOS suspended before it ended it).
      self?.sync()
    }
    // An activity left by a run the system ended belongs to no session.
    if !voice.isAlive { endStale() }
    sync()
  }

  /// Brings the activity in line with the session.
  func sync() {
    guard let voice else { return }
    if voice.isAlive {
      // The user can switch Live Activities off while one runs.
      if let running = activity,
        !ActivityAuthorizationInfo().areActivitiesEnabled
          || running.activityState == .dismissed || running.activityState == .ended
      {
        end()
        unavailable = true
      }
      let state = currentState(voice)
      if activity == nil {
        start(state)
      } else if state != lastState || staleNeedsRenewal(state) {
        update(state)
      }
      startTicker()
    } else {
      ticker?.cancel()
      ticker = nil
      end()
      // Any activity left behind (an end that never ran because iOS suspended the app first).
      endStale()
    }
  }

  /// The app came to the front: try again if the last request failed.
  func foreground() {
    unavailable = false
    sync()
  }

  private func currentState(_ voice: VoiceSessionModel) -> VoiceActivityAttributes.ContentState {
    let charging = voice.isCharging && voice.settings.stayOnWhileCharging
    return VoiceActivityAttributes.ContentState(
      endsAt: charging ? nil : voice.endsAt, charging: charging)
  }

  private func start(_ state: VoiceActivityAttributes.ContentState) {
    // A build without the widget (a free team's device build) has nothing to draw the activity
    // with: the app shows its own 「结束」 instead.
    guard Self.hasWidget, !unavailable else { return }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      unavailable = true
      return
    }
    do {
      activity = try Activity.request(
        attributes: VoiceActivityAttributes(),
        content: content(state),
        pushType: nil)
      lastState = state
      voice?.indicatorShown = true
    } catch {
      unavailable = true
      log.error("live activity not started: \(String(describing: error), privacy: .public)")
    }
  }

  static var hasWidget: Bool {
    #if MINDLOOM_LIVE_ACTIVITY
      true
    #else
      false
    #endif
  }

  private func update(_ state: VoiceActivityAttributes.ContentState) {
    guard let activity else { return }
    lastState = state
    let next = content(state)
    // `Activity` is not Sendable in this SDK; it is only touched here and by ActivityKit.
    nonisolated(unsafe) let running = activity
    Task {
      await running.update(next)
    }
  }

  /// The content with its stale date: the end of the countdown, or two minutes ahead.
  private func content(_ state: VoiceActivityAttributes.ContentState)
    -> ActivityContent<VoiceActivityAttributes.ContentState>
  {
    let stale = Self.staleDate(endsAt: state.endsAt)
    staleAt = stale
    return ActivityContent(state: state, staleDate: stale)
  }

  static func staleDate(endsAt: Date?, now: Date = Date()) -> Date {
    min(endsAt ?? .distantFuture, now.addingTimeInterval(staleWindow))
  }

  /// The stale date would move on by about a minute: renew it (once a minute while on).
  private func staleNeedsRenewal(_ state: VoiceActivityAttributes.ContentState) -> Bool {
    guard let staleAt else { return true }
    return Self.staleDate(endsAt: state.endsAt).timeIntervalSince(staleAt) >= 55
  }

  private func end() {
    voice?.indicatorShown = false
    guard let activity else { return }
    self.activity = nil
    lastState = nil
    staleAt = nil
    nonisolated(unsafe) let running = activity
    Self.endInBackground { await running.end(nil, dismissalPolicy: .immediate) }
  }

  private func endStale() {
    for stale in Activity<VoiceActivityAttributes>.activities {
      nonisolated(unsafe) let left = stale
      Self.endInBackground { await left.end(nil, dismissalPolicy: .immediate) }
    }
  }

  /// Ends an activity with time asked of iOS: the session has just released the audio, after
  /// which a background app may be suspended before the end reaches ActivityKit.
  private static func endInBackground(_ work: @escaping @Sendable () async -> Void) {
    let application = UIApplication.shared
    let background = BackgroundTime()
    background.id = application.beginBackgroundTask(withName: "live-activity-end") {
      background.finish(application)
    }
    Task { @MainActor in
      await work()
      background.finish(application)
    }
  }

  /// Re-reads the session every few seconds while it is on; the activity changes only when the
  /// words change (a new minute, charging, a restarted countdown).
  private func startTicker() {
    guard ticker == nil else { return }
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(5))
        guard let self, !Task.isCancelled else { return }
        self.sync()
      }
    }
  }
}

/// One background task, ended once (by its expiry or when the work is done).
@MainActor
private final class BackgroundTime {
  var id = UIBackgroundTaskIdentifier.invalid

  func finish(_ application: UIApplication) {
    guard id != .invalid else { return }
    application.endBackgroundTask(id)
    id = .invalid
  }
}
