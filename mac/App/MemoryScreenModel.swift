import AppKit
import BestASRDomain
import BestASRMemory
import BestASRMemoryUI
import BestASRPersistence
import Combine
import Foundation

/// Adapts the App's models to the memory pages' value state. It reloads the
/// read model when events, the organizer projection, people or history
/// change, and keeps nothing the models do not already hold.
@MainActor
final class MemoryScreenModel: ObservableObject {
  /// Derived once per load; the view only patches the live parts in.
  @Published private(set) var base = MemoryScreenState()
  private var reload: Task<Void, Never>?
  private var observers: Set<AnyCancellable> = []
  private let thumbnails = ThumbnailCache()

  /// Starts following the App's models; call once.
  func attach(to app: DictationAppModel) {
    guard observers.isEmpty else { return }
    let changes: [AnyPublisher<Void, Never>] = [
      app.events.$summaries.map { _ in () }.eraseToAnyPublisher(),
      app.events.$candidates.map { _ in () }.eraseToAnyPublisher(),
      app.events.$remoteProjection.map { _ in () }.eraseToAnyPublisher(),
      app.people.$personSummaries.map { _ in () }.eraseToAnyPublisher(),
      app.people.$personReviewCandidates.map { _ in () }.eraseToAnyPublisher(),
      app.history.$historyItems.map { _ in () }.eraseToAnyPublisher(),
      app.history.$eventAvailableHistoryItems.map { _ in () }.eraseToAnyPublisher(),
      app.$remoteOrganizerEnabled.map { _ in () }.eraseToAnyPublisher(),
    ]
    Publishers.MergeMany(changes)
      .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
      .sink { [weak self, weak app] in
        guard let self, let app else { return }
        self.refresh(app)
      }
      .store(in: &observers)
    refresh(app)
  }

  func refresh(_ app: DictationAppModel) {
    reload?.cancel()
    reload = Task { [weak self, weak app] in
      guard let app else { return }
      // The records are read off the main thread by the store; building the
      // projection and deriving Home, people and Unfiled from thousands of
      // records happens off it too, so the window never waits for it.
      guard let inputs = await app.memoryProjectionInputs() else {
        guard !Task.isCancelled, let self else { return }
        base = MemoryScreenState(mode: app.memoryUsesRemote ? .spark : .local, projection: nil)
        return
      }
      let model = await Task.detached(priority: .userInitiated) {
        MemoryReadModel(inputs.projection())
      }.value
      guard !Task.isCancelled, let self else { return }
      let root = app.intake.assetRoot
      let cache = thumbnails
      base = MemoryScreenState(
        mode: app.memoryUsesRemote ? .spark : .local, readModel: model,
        personReviews: Self.reviews(app: app, projection: model.projection),
        thumbnail: { path in cache.image(path, root: root) })
    }
  }

  var projection: MemoryProjection? { base.projection }

  private var lastPageRefresh: Date?

  /// True at most once a minute: a page visit asks the models to reload.
  func claimPageRefresh(now: Date = Date()) -> Bool {
    if let last = lastPageRefresh, now.timeIntervalSince(last) < 60 { return false }
    lastPageRefresh = now
    return true
  }

  func state(
    app: DictationAppModel, capture: MemoryCaptureIndicator?, now: Date = Date()
  ) -> MemoryScreenState {
    var state = base
    state.toast = app.intake.confirmation.map {
      MemoryToast(
        message: $0, itemID: app.intake.confirmationItem?.rawValue.uuidString,
        sourceName: app.intake.confirmationSource)
    }
    state.capture = capture
    state.issues = Self.issues(app.events.remoteProjection)
    state.playingItemID =
      app.playback.playbackIsPlaying
      ? app.history.selectedHistorySessionID?.rawValue.uuidString : nil
    state.now = now
    return state
  }

  /// Corrections the organizing device did not take, worded as Settings
  /// words them; the local overlay keeps showing them applied until the user
  /// retries or drops them.
  static func issues(_ projection: RemoteOrganizerProjection?) -> [MemoryIssue] {
    (projection?.unacceptedDecisions ?? []).map { issue in
      MemoryIssue(
        id: issue.decisionID.uuidString,
        title: DictationAppModel.remoteDecisionIssueTitle(issue),
        deliveryUnknown: issue.state == .deliveryUnknown)
    }
  }

  /// Review rows per person: the organizing device's same-person questions,
  /// and voice matches waiting on this Mac.
  private static func reviews(
    app: DictationAppModel, projection: MemoryProjection?
  ) -> [String: [MemoryPersonReview]] {
    var result: [String: [MemoryPersonReview]] = [:]
    for question in projection?.memoryQuestions() ?? [] where question.kind == .samePerson {
      for personID in question.personIDs {
        result[personID.uppercased(), default: []].append(
          MemoryPersonReview(
            id: question.questionID, prompt: question.prompt, meta: "", itemID: nil,
            origin: .question(question)))
      }
    }
    var calendar = Calendar.current
    calendar.timeZone = .current
    for candidate in app.people.personReviewCandidates {
      let name = candidate.candidateDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
      let prompt = (name?.isEmpty == false) ? "这段声音是\(name!)吗？" : "这段声音是这个人吗？"
      let item = app.memoryHistoryItem(candidate.sessionID)
      var meta: [String] = []
      if let item {
        meta.append(
          "\(MemoryDateText.day(item.createdAt, calendar: calendar, now: Date())) "
            + MemoryDateText.time(item.createdAt, calendar: calendar))
        meta.append(item.inputMode == .roomMicrophone ? "当面" : item.sourceLabel)
      }
      if let event = app.events.summaries.first(where: {
        $0.sessionIDs.contains(candidate.sessionID)
      }) {
        meta.append("「\(event.event.title)」")
      }
      result[candidate.candidatePersonID.rawValue.uuidString.uppercased(), default: []].append(
        MemoryPersonReview(
          id: candidate.speakerID.rawValue.uuidString, prompt: prompt,
          meta: meta.joined(separator: " · "),
          itemID: item?.sourceAudioRetained == true
            ? candidate.sessionID.rawValue.uuidString : nil,
          origin: .voiceMatch(candidate.speakerID.rawValue.uuidString),
          // The candidate's own stretch, not the start of the recording.
          startNanoseconds: candidate.monotonicStartNanoseconds,
          endNanoseconds: candidate.monotonicEndNanoseconds))
    }
    return result
  }
}

/// Normalized images read once from the asset root, by relative path. A path
/// that leaves the root is refused. NSCache is thread-safe.
private final class ThumbnailCache: @unchecked Sendable {
  private let cache = NSCache<NSString, NSImage>()

  func image(_ path: String, root: URL?) -> NSImage? {
    guard let root, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
      return nil
    }
    if let hit = cache.object(forKey: path as NSString) { return hit }
    guard let image = NSImage(contentsOf: root.appendingPathComponent(path)) else { return nil }
    cache.setObject(image, forKey: path as NSString)
    return image
  }
}
