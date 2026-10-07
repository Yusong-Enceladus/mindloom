import BestASRDomain
import BestASRIntake
import Combine
import Foundation

/// State of pasted/dragged intake (PRD §0.3.2): the transient confirmation
/// and the audio/video files waiting for the one-at-a-time import pipeline.
/// That queue lives only while the App runs (the confirmation says so); the
/// user's files are untouched and can be dropped again. The text is built by
/// `IntakeConfirmation` in the package, where it is tested.
@MainActor
final class IntakeModel: ObservableObject {
  struct PendingMediaImport: Equatable {
    let url: URL
    let source: ItemSourceApplication?
    /// Its SHA-256, when the drop path hashed it (dedupe); the import
    /// reuses it while the file is unchanged instead of hashing it again.
    var hashed: HashedSourceFile? = nil

    var digest: String? { hashed?.digest }
  }

  /// "已收好 · 来自 微信"; cleared after a few seconds.
  @Published var confirmation: String?
  /// The one item the confirmation is about, so its source can be changed
  /// from the toast; nil for several items or a refusal.
  @Published var confirmationItem: SessionID?
  @Published var confirmationSource: String?
  @Published var inProgress = false
  /// The library's asset root, for thumbnails on the memory pages.
  var assetRoot: URL?

  var pendingMediaImports: [PendingMediaImport] = []
  /// Original digests being taken in right now (between the duplicate
  /// check and the commit), so the same bytes dropped twice at once, or
  /// again while the first is still on its way, are taken in once.
  var receiving: Set<String> = []
  /// The digest of the media import running now (nil: none, or unhashed).
  var importingDigest: String?

  /// Whether `digest` is already on its way in (being received, queued for
  /// import, or importing).
  func isOnItsWay(_ digest: String, importing: Bool) -> Bool {
    receiving.contains(digest) || pendingMediaImports.contains { $0.digest == digest }
      || (importing && importingDigest == digest)
  }
  var confirmationTask: Task<Void, Never>?

  func show(
    _ message: String, item: SessionID? = nil, source: String? = nil,
    for duration: Duration = .seconds(4)
  ) {
    confirmation = message
    confirmationItem = item
    confirmationSource = source
    confirmationTask?.cancel()
    // Long enough to reach 改来源 when there is one.
    let shown = item == nil ? duration : .seconds(8)
    confirmationTask = Task { [weak self] in
      try? await Task.sleep(for: shown)
      guard !Task.isCancelled else { return }
      self?.confirmation = nil
      self?.confirmationItem = nil
      self?.confirmationSource = nil
    }
  }
}
