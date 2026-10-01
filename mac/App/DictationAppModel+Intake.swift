import AppKit
import BestASRDomain
import BestASRIntake
import BestASRPersistence
import BestASRRemoteOrganizer
import Foundation
import UniformTypeIdentifiers

/// Paste, the "收进来" command, and drops (PRD §0.3.2). Everything received is
/// kept as data with its source App; nothing in it is ever interpreted as an
/// instruction. Text, images, and documents become `userItem` sessions;
/// audio and video go to the existing import pipeline, one at a time.
extension DictationAppModel {
  func configureIntake(repository: GRDBDictationStore, assetRoot: URL) {
    let store = IntakeAssetStore(assetRoot: assetRoot)
    // Files inside the owner's real library or this data root are never
    // taken in: a copy would get a fresh digest and pass the data-root
    // provenance guard (a synthetic dev root could then send real content).
    // Without a resolvable owner library, every file is refused.
    let realLibrary = BestASRDataRootSelection.ownerRealLibraryRoot()
    let dataRoot = assetRoot.deletingLastPathComponent()
    let policy = IntakePathPolicy { url in
      guard let realLibrary else { return true }
      return [realLibrary, dataRoot].contains {
        BestASRDataRootSelection.path(url, isWithinOrEqualTo: $0)
      }
    }
    intake.assetRoot = assetRoot
    intakeProcessor = IntakeProcessor(
      assetStore: store, pathPolicy: policy, imageReader: VisionImageTextReader())
    sourceApplicationTracker = WorkspaceSourceApplicationTracker()
    // Staging directories whose rows never committed (a crash between the
    // file copy and the commit) are removed; committed ones lose the marker.
    // Intake waits for this sweep, so it can never remove the files of an
    // item that is being committed right now.
    intakeReady = Task {
      // Bytes of items deleted before a crash leave the content index.
      await Self.pruneContentIndex(assetRoot)
      let marked = await Self.markedIntakeSessions(store)
      guard !marked.isEmpty,
        let existing = try? await repository.existingSessionIDs(among: marked)
      else { return }
      await Self.sweepIntakeStaging(store, existing: existing, marked: marked)
    }
  }

  /// ⌘V with no text field focused, or the "收进来" command. Reads the
  /// pasteboard only because the user asked for it.
  func receivePasteboard(_ pasteboard: NSPasteboard = .general) {
    // One clipboard content is taken in once: a second ⌘V (or an
    // auto-repeat that slipped through) does not make a duplicate item.
    guard pasteboard.changeCount != lastReceivedPasteChangeCount else {
      intake.show("这份剪贴板内容刚才已收进来")
      return
    }
    switch IntakePasteboardReader(pasteboard: pasteboard).read() {
    case .refused(let message):
      intake.show(message)
    case .candidates(let candidates) where candidates.isEmpty:
      intake.show("剪贴板里没有可收进来的内容")
    case .candidates(let candidates):
      lastReceivedPasteChangeCount = pasteboard.changeCount
      let (source, origin) = sourceApplicationTracker?.sourceForPaste() ?? (nil, .unknown)
      receive(candidates, source: source, origin: origin)
    }
  }

  /// A drop anywhere on the main window.
  func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
    guard !providers.isEmpty else { return false }
    let containsFiles = providers.contains {
      $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }
    let (source, origin) =
      sourceApplicationTracker?.sourceForDrop(containsFiles: containsFiles) ?? (nil, .unknown)
    Task { [weak self] in
      var candidates: [IntakeCandidate] = []
      for provider in providers {
        if let candidate = await Self.candidate(from: provider) {
          candidates.append(candidate)
        }
      }
      guard let self else { return }
      guard !candidates.isEmpty else {
        intake.show("不支持这种内容，未收进来")
        return
      }
      receive(candidates, source: source, origin: origin)
    }
    return true
  }

  /// Files dropped on the import page's drop zone. `URL` drops also carry web
  /// links; only local files are taken (a link would be fetched online).
  func receiveDroppedFiles(_ urls: [URL]) -> Bool {
    guard !urls.isEmpty else { return false }
    let files = urls.filter(\.isFileURL)
    guard !files.isEmpty else {
      intake.show("只收本机文件，链接未收进来")
      return true
    }
    let (source, origin) =
      sourceApplicationTracker?.sourceForDrop(containsFiles: true) ?? (nil, .unknown)
    receive(files.map(IntakeCandidate.file), source: source, origin: origin)
    return true
  }

  func receive(
    _ candidates: [IntakeCandidate], source: ItemSourceApplication?, origin: ItemSourceOrigin
  ) {
    guard let processor = intakeProcessor, let repository else {
      intake.show("资料库尚未打开；未收进来")
      return
    }
    let base = Date()
    intake.inProgress = true
    let ready = intakeReady
    Task { [weak self] in
      await ready?.value
      var stored = 0
      var lastStored: SessionID?
      var media: [URL] = []
      var rejected: [String] = []
      for (index, candidate) in candidates.enumerated() {
        // Input order is capture order.
        let capturedAt = base.addingTimeInterval(Double(index) * 0.001)
        // A zip gives the archive (kept on this Mac) and each file in it.
        let outcomes = await Self.prepare(
          processor, candidate, capturedAt: capturedAt, source: source, origin: origin
        )
        for outcome in outcomes {
          switch outcome {
          case .item(let draft):
            do {
              try await repository.createUserItem(draft)
              await Self.commitIntakeStaging(processor.assetStore, draft.id)
              stored += 1
              lastStored = draft.id
            } catch {
              await Self.discardIntakeStaging(processor.assetStore, draft.id)
              rejected.append("未能保存到资料库，未收进来")
            }
          case .media(let url):
            media.append(url)
          case .rejected(let message):
            rejected.append(message)
          }
        }
      }
      guard let self else { return }
      intake.inProgress = false
      for url in media {
        intake.pendingMediaImports.append(.init(url: url, source: source))
      }
      let wasImporting = capture.importInProgress
      let refusal = startNextQueuedMediaImport()
      let summary = IntakeConfirmation.text(
        stored: stored, mediaStarted: !media.isEmpty && !wasImporting && capture.importInProgress,
        mediaWaiting: media.isEmpty ? 0 : intake.pendingMediaImports.count,
        rejected: rejected, source: source)
      intake.show(
        refusal.map { stored > 0 ? "\(summary)；\($0)" : $0 } ?? summary,
        item: stored == 1 && refusal == nil && rejected.isEmpty ? lastStored : nil,
        source: source?.name)
      if stored > 0 {
        // New items join local fallback events right away, as recordings do.
        await refreshHistoryItems(preserveStatus: true, organizeEvents: true)
      }
    }
  }

  /// The user corrects where an item came from; stored as a new revision.
  func changeItemSource(_ item: DictationHistoryItem, to name: String) {
    guard item.inputMode == .userItem, let repository else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let source = ItemSourceApplication(bundleID: nil, name: trimmed)
    Task { [weak self] in
      do {
        try await repository.setItemSourceApplication(sessionID: item.sessionID, source: source)
        self?.intake.show(trimmed.isEmpty ? "已清除来源" : "来源已改为 \(trimmed)")
        // The local organizer groups by source too.
        await self?.refreshHistoryItems(preserveStatus: true, organizeEvents: true)
      } catch {
        self?.intake.show("未能修改来源；原记录没有改变")
      }
    }
  }

  /// Starts the next intake-routed audio/video import when none is running.
  /// Returns why it was refused, if it was.
  @discardableResult
  func startNextQueuedMediaImport() -> String? {
    guard !capture.importInProgress, !intake.pendingMediaImports.isEmpty else { return nil }
    let next = intake.pendingMediaImports.removeFirst()
    pendingImportSourceApplication = next.source
    importMedia(next.url)
    if !capture.importInProgress {
      // Refused (components not ready, a recording in progress, ...). The
      // queue is dropped rather than started by surprise later; the user's
      // files are untouched and can be dropped again.
      pendingImportSourceApplication = nil
      let skipped = intake.pendingMediaImports.count
      intake.pendingMediaImports.removeAll()
      return "音视频未导入：\(capture.importStatusMessage)"
        + (skipped > 0 ? "（另有 \(skipped) 个文件未导入）" : "")
    }
    return nil
  }

  /// A video's keyframes as image items under its recording. Best effort:
  /// a frame that cannot be taken or stored is skipped, and the recording's
  /// import goes on either way. The video is the copy already in the
  /// library, so nothing outside it is opened.
  func takeVideoKeyframes(
    _ video: URL, parent: SessionID, videoName: String, capturedAt: Date,
    source: ItemSourceApplication?
  ) async {
    guard let processor = intakeProcessor, let repository else { return }
    await intakeReady?.value
    let drafts = await Self.keyframeDrafts(
      processor, video: video, parent: parent, videoName: videoName, capturedAt: capturedAt,
      source: source)
    for draft in drafts {
      do {
        try await repository.createUserItem(draft)
        await Self.commitIntakeStaging(processor.assetStore, draft.id)
      } catch {
        await Self.discardIntakeStaging(processor.assetStore, draft.id)
      }
    }
  }

  // MARK: - Off the main actor

  private nonisolated static func keyframeDrafts(
    _ processor: IntakeProcessor, video: URL, parent: SessionID, videoName: String,
    capturedAt: Date, source: ItemSourceApplication?
  ) async -> [UserItemDraft] {
    let frames = (try? await VideoKeyframeExtractor().keyframes(fileURL: video)) ?? []
    return processor.keyframeDrafts(
      frames, parent: parent, videoName: videoName, capturedAt: capturedAt, source: source)
  }

  private nonisolated static func prepare(
    _ processor: IntakeProcessor, _ candidate: IntakeCandidate, capturedAt: Date,
    source: ItemSourceApplication?, origin: ItemSourceOrigin
  ) async -> [IntakeOutcome] {
    processor.prepareAll(candidate, capturedAt: capturedAt, source: source, origin: origin)
  }

  private nonisolated static func pruneContentIndex(_ assetRoot: URL) async {
    ContentAddressedAssets.prune(assetRoot: assetRoot)
  }

  private nonisolated static func commitIntakeStaging(_ store: IntakeAssetStore, _ id: SessionID)
    async
  {
    store.commit(sessionID: id)
  }

  private nonisolated static func discardIntakeStaging(
    _ store: IntakeAssetStore, _ id: SessionID
  ) async {
    store.discard(sessionID: id)
  }

  private nonisolated static func markedIntakeSessions(_ store: IntakeAssetStore) async
    -> [SessionID]
  {
    store.markedSessionIDs()
  }

  private nonisolated static func sweepIntakeStaging(
    _ store: IntakeAssetStore, existing: Set<SessionID>, marked: [SessionID]
  ) async {
    store.sweep(existing: existing, marked: marked)
  }

  /// One dropped thing: a local file, else the same representation rule as a
  /// paste (`IntakeRepresentations`).
  private static func candidate(from provider: NSItemProvider) async -> IntakeCandidate? {
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
      let url = await loadFileURL(provider)
    {
      return .file(url)
    }
    var representations = IntakeRepresentations()
    if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
      let data = await loadData(provider, UTType.plainText.identifier)
    {
      representations.plainText =
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
    }
    if let imageType = IntakeRepresentations.imageTypeIdentifiers.first(where: {
      provider.hasItemConformingToTypeIdentifier($0)
    }), let data = await loadData(provider, imageType) {
      representations.image = (data, imageType)
    }
    for (type, keyPath) in [
      (UTType.pdf, \IntakeRepresentations.pdf), (UTType.rtf, \IntakeRepresentations.rtf),
      (UTType.html, \IntakeRepresentations.html),
    ] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
      representations[keyPath: keyPath] = await loadData(provider, type.identifier)
    }
    if let text = representations.plainText, IntakeProcessor.exceedsTextLimit(text) {
      return .text(text, extractor: "drop-text-v1")  // refused with a size message
    }
    return representations.candidate(origin: "drop")
  }

  private static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
    await withCheckedContinuation { continuation in
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        continuation.resume(returning: url?.isFileURL == true ? url : nil)
      }
    }
  }

  private static func loadData(_ provider: NSItemProvider, _ type: String) async -> Data? {
    await withCheckedContinuation { continuation in
      _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
        continuation.resume(returning: data)
      }
    }
  }
}
