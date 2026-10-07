import AppKit
import BestASRDictation
import BestASRDomain
import BestASRMemory
import BestASRMemoryUI
import Combine
import Foundation
import MindloomDesign

// OWNER: mac-capture. What the capture surfaces say after something was
// taken in (MAC-SPEC §5.9, §7.6): 「已收好」 at once (nothing for dictation),
// then, when the organizer has filed it, 「已归进「…」 · 查看」 with the row lit
// — Home never re-orders or scrolls for it. A file taken in twice:
// 「这个文件已经收过了 · 查看」. Several waiting captures filed together (a
// reconnect): 「{n} 条已归进各自的事」.

/// Small App-wide capture state the Settings window, the menu and the pages
/// read (extensions of `DictationAppModel` cannot hold stored values).
@MainActor
final class CaptureState: ObservableObject {
  static let shared = CaptureState()
  /// The user's own bestASR App holds fn (Mindloom Preview does not arm it).
  @Published var fnHeldByOtherApp = false
  /// The preview's 「使用这台 Mac 上已装的识别模型」 row.
  @Published var modelImportOffer: SettingsModelImport?
  /// Captures waiting on this Mac for the DGX Spark.
  @Published var waitingForSpark = 0
  /// When the iPhone last sent something here (kept across launches).
  @Published var lastPhoneDelivery: Date? =
    LocalPreferenceStore.defaults.object(forKey: CaptureState.phoneDeliveryKey) as? Date

  static let phoneDeliveryKey = "v11.last-phone-delivery"

  func recordPhoneDelivery(at date: Date = Date()) {
    lastPhoneDelivery = date
    LocalPreferenceStore.defaults.set(date, forKey: Self.phoneDeliveryKey)
  }
  /// The fn HUD's hint, while one shows.
  @Published var hudHint: FnHUDHint?
}

extension DictationAppModel {
  var fnHeldByOtherApp: Bool { CaptureState.shared.fnHeldByOtherApp }
  var modelImportOffer: SettingsModelImport? { CaptureState.shared.modelImportOffer }
  var waitingForSpark: Int { CaptureState.shared.waitingForSpark }
  var lastPhoneDelivery: Date? { CaptureState.shared.lastPhoneDelivery }

  /// Counts what waits for the DGX Spark (Home's offline line, Settings).
  func refreshWaitingForSpark() {
    guard let repository else { return }
    Task {
      let count = (try? await repository.undeliveredRemoteItemCount()) ?? 0
      if CaptureState.shared.waitingForSpark != count {
        CaptureState.shared.waitingForSpark = count
      }
    }
  }
}

@MainActor
final class CaptureFeedback {
  static let shared = CaptureFeedback()

  enum Kind {
    /// fn dictation: no 「已收好」 (the words are where the caret was).
    case dictation
    /// A paste, a drop, a share, the menu bar's meeting.
    case item
  }

  private struct Awaiting {
    let ids: Set<String>
    let at: Date
  }

  private weak var screen: MemoryScreenModel?
  private weak var app: DictationAppModel?
  private var awaiting: [Awaiting] = []
  private var observers: Set<AnyCancellable> = []
  private var unlight: Task<Void, Never>?
  /// How long a capture is followed until it is filed.
  static let followFor: TimeInterval = 30 * 60

  private var screenObserver: AnyCancellable?

  /// Whether `screen` is not the one followed (a reopened main window has a
  /// new one).
  func follows(_ screen: MemoryScreenModel) -> Bool { self.screen === screen }

  /// Starts following the pages' state with the main window's models. A
  /// main window opened again re-attaches its own screen model, so 已收好 /
  /// 已归进 and the lit row reach the window on screen.
  func attach(screen: MemoryScreenModel, app: DictationAppModel) {
    guard self.screen !== screen else { return }
    self.screen = screen
    screenObserver = screen.$base
      .sink { [weak self] state in self?.check(state) }
    guard self.app == nil else { return }
    self.app = app
    // Captures that finish without going through intake (dictation, the
    // menu bar's meeting). What had finished before this launch is not news.
    for snapshot in [app.snapshot, app.capture.roomSnapshot, app.capture.systemAudioSnapshot] {
      if let id = snapshot.sessionID { completedIDs.insert(id) }
    }
    app.$snapshot
      .sink { [weak self] (snapshot: DictationSessionSnapshot) in
        self?.completed(snapshot, kind: .dictation)
      }
      .store(in: &observers)
    app.capture.$roomSnapshot
      .sink { [weak self] (snapshot: DictationSessionSnapshot) in
        self?.completed(snapshot, kind: .item)
      }
      .store(in: &observers)
    app.capture.$systemAudioSnapshot
      .sink { [weak self] (snapshot: DictationSessionSnapshot) in
        self?.completed(snapshot, kind: .item)
      }
      .store(in: &observers)
  }

  private var completedIDs = Set<SessionID>()

  private func completed(_ snapshot: DictationSessionSnapshot, kind: Kind) {
    guard snapshot.phase == .completed, let id = snapshot.sessionID,
      completedIDs.insert(id).inserted
    else { return }
    taken([id], kind: kind)
  }

  func show(_ toast: MemoryToast) { screen?.show(toast) }

  /// Something was taken in. Follows it until the organizer files it.
  func taken(_ ids: [SessionID], kind: Kind) {
    let keys = Set(ids.map { $0.rawValue.uuidString.uppercased() })
    guard !keys.isEmpty, !awaiting.contains(where: { $0.ids == keys }) else { return }
    if kind == .item {
      let down = screen.map { _ in app.map { MemoryScreenModel.link($0).showsNotConnected } ?? false }
      show(MemoryToast("已添加", icon: .mark, detail: down == true ? "暂存在这台 Mac 上" : nil))
    }
    awaiting.append(Awaiting(ids: keys, at: Date()))
    app?.refreshWaitingForSpark()
    if let state = screen?.base { check(state) }
  }

  /// The same bytes were taken in before: 「这个文件已经收过了」 (+ 查看 when
  /// the earlier one is filed).
  func duplicate(of id: SessionID) {
    let key = id.rawValue.uuidString.uppercased()
    let matter = screen?.base.digest?.matters.first { $0.itemIDs.contains { $0.uppercased() == key } }
    show(
      MemoryToast(
        "此文件已添加过", icon: .symbol("checkmark"),
        action: matter.map { .view(eventID: $0.eventID, stepID: nil) }))
  }

  /// Filed captures (the organizer put them into a matter).
  private func check(_ state: MemoryScreenState) {
    guard !awaiting.isEmpty, let digest = state.digest else { return }
    let now = Date()
    awaiting.removeAll { now.timeIntervalSince($0.at) > Self.followFor }
    var filed: [(MatterDigest, Awaiting)] = []
    for entry in awaiting {
      if let matter = digest.matters.first(where: { matter in
        matter.itemIDs.contains { entry.ids.contains($0.uppercased()) }
      }) {
        filed.append((matter, entry))
      }
    }
    guard !filed.isEmpty else { return }
    awaiting.removeAll { entry in filed.contains { $0.1.ids == entry.ids } }
    app?.refreshWaitingForSpark()
    if filed.count == 1, let (matter, _) = filed.first {
      show(
        MemoryToast(
          "已归入“\(MLAutospace.apply(matter.title))”", icon: .none,
          action: .view(eventID: matter.eventID, stepID: nil)))
      light(matter.eventID)
    } else {
      show(MemoryToast("\(filed.count) 条已归入各自的事", icon: .symbol("checkmark")))
      if let last = filed.last { light(last.0.eventID) }
    }
  }

  /// The row is tinted, then fades (M9); nothing moves.
  private func light(_ eventID: String) {
    screen?.highlightedEventID = eventID
    unlight?.cancel()
    unlight = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      if self?.screen?.highlightedEventID == eventID { self?.screen?.highlightedEventID = nil }
    }
  }
}

