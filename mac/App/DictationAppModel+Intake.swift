import AppKit
import BestASRDomain
import BestASRIntake
import BestASRMemory
import BestASRPersistence
import BestASRRemoteOrganizer
import BestASRMemoryUI
import CryptoKit
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
      intake.show("这份剪贴板内容刚才已经收过了")
      return
    }
    switch IntakePasteboardReader(pasteboard: pasteboard).read() {
    case .refused(let message):
      intake.show(message)
    case .candidates(let candidates) where candidates.isEmpty:
      intake.show("剪贴板里没有能收的内容")
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
        intake.show("无法添加此类内容")
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
      intake.show("仅支持这台 Mac 上的文件，链接未添加")
      return true
    }
    let (source, origin) =
      sourceApplicationTracker?.sourceForDrop(containsFiles: true) ?? (nil, .unknown)
    receive(files.map(IntakeCandidate.file), source: source, origin: origin)
    return true
  }

  // MARK: - 文件 › 导入… and 收进会议记录… (v12 1C)

  /// 文件 › 导入… ⌘O (ALIGNMENT 收2-6): recordings and videos, through the
  /// same way in as a drop (one at a time, the same bytes once). An
  /// imported recording is called 「录音」, a video 「视频」.
  func chooseMediaToImport() {
    let panel = NSOpenPanel()
    panel.title = "导入录音或视频"
    panel.prompt = "导入"
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes =
      [.audio, .audiovisualContent, .movie]
      + MediaImportFormats.extensions.sorted().compactMap { UTType(filenameExtension: $0) }
    presentOpenPanel(panel) { [weak self] urls in
      self?.receive(urls.map(IntakeCandidate.file), source: nil, origin: .unknown)
    }
  }

  /// 文件 › 导入会议记录… (ALIGNMENT 收2-5): a transcript a meeting App
  /// exported (txt, md — Tencent Meeting's web download —, docx, srt, vtt).
  func chooseMeetingTranscripts() {
    let panel = NSOpenPanel()
    panel.title = "导入会议记录"
    panel.message = "腾讯会议、飞书妙记、Zoom 导出的会议记录：txt、md、docx、srt、vtt"
    panel.prompt = "导入"
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = IntakeFileClass.meetingTranscriptExtensions.compactMap {
      UTType(filenameExtension: $0)
    }
    presentOpenPanel(panel) { [weak self] urls in self?.takeInMeetingTranscripts(urls) }
  }

  /// Reads each file's turns on this Mac (`MemoryTranscriptText`, the rules
  /// the DGX Spark cuts it by) and takes it in like a drop, its source named
  /// after the App whose export it is (「会议记录 · 腾讯会议」). A file whose
  /// turns cannot be told is still taken in, as a file, and that is said.
  func takeInMeetingTranscripts(_ urls: [URL]) {
    let files = urls.filter(\.isFileURL)
    guard !files.isEmpty else { return }
    Task { [weak self] in
      let read = await Self.meetingTranscriptApps(files)
      guard let self else { return }
      var byApp: [String: [URL]] = [:]
      var unnamed: [URL] = []
      for (url, reading) in zip(files, read) {
        if case .transcript(let app?) = reading {
          byApp[app, default: []].append(url)
        } else {
          unnamed.append(url)
        }
      }
      let notTranscripts = read.filter { $0 == .notTranscript }.count
      let note: String? =
        switch notTranscripts {
        case 0: nil
        case 1 where files.count == 1: "无法识别说话人，已作为文件添加"
        default: "有 \(notTranscripts) 份无法识别说话人，已作为文件添加"
        }
      for app in byApp.keys.sorted() {
        receive(
          byApp[app, default: []].map(IntakeCandidate.file),
          source: ItemSourceApplication(bundleID: nil, name: app), origin: .user)
      }
      if !unnamed.isEmpty {
        receive(unnamed.map(IntakeCandidate.file), source: nil, origin: .unknown, note: note)
      }
    }
  }

  enum MeetingTranscriptReading: Equatable {
    /// Turns were found; the App whose export it is (nil for subtitles).
    case transcript(app: String?)
    case notTranscript
  }

  nonisolated static func meetingTranscriptApps(_ urls: [URL]) async -> [MeetingTranscriptReading] {
    await Task.detached(priority: .userInitiated) {
      urls.map { url in
        guard let text = IntakeTextExtractor.meetingTranscriptText(fileURL: url),
          let transcript = MemoryTranscriptText.parse(text)
        else { return MeetingTranscriptReading.notTranscript }
        return .transcript(app: transcript.format.meetingApp)
      }
    }.value
  }

  /// An open panel as a sheet on the main window when there is one, else
  /// on its own; one at a time.
  func presentOpenPanel(_ panel: NSOpenPanel, chosen: @escaping ([URL]) -> Void) {
    guard importOpenPanel == nil else { return }
    importOpenPanel = panel
    let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
      let urls = response == .OK ? panel?.urls ?? [] : []
      self?.importOpenPanel = nil
      if !urls.isEmpty { chosen(urls) }
    }
    let application = NSApplication.shared
    let parent = Self.importPresentationWindow(
      keyWindow: application.keyWindow, mainWindow: application.mainWindow,
      windows: application.windows)
    application.activate()
    if let parent {
      parent.makeKeyAndOrderFront(nil)
      panel.beginSheetModal(for: parent, completionHandler: finish)
    } else {
      panel.begin(completionHandler: finish)
    }
  }

  func receive(
    _ candidates: [IntakeCandidate], source: ItemSourceApplication?, origin: ItemSourceOrigin,
    note: String? = nil
  ) {
    guard let processor = intakeProcessor, let repository else {
      intake.show("尚未就绪，请稍后再试")
      return
    }
    let base = Date()
    intake.inProgress = true
    let ready = intakeReady
    Task { [weak self] in
      await ready?.value
      var stored = 0
      var storedIDs: [SessionID] = []
      var media: [URL] = []
      var rejected: [String] = []
      // v11: the same bytes taken in twice are recognised by content (SHA-256
      // of the original), never by the file's name.
      var duplicates: [SessionID] = []
      // The same bytes already on their way in (twice in this drop, or a
      // drop still being received or imported): taken in once.
      var onItsWay = 0
      var mediaDigests: [URL: HashedSourceFile] = [:]
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
            let digest = draft.attachments.first(where: { $0.role == .original })?.digest.value
            if let digest, self?.claimIntake(digest) == false {
              await Self.discardIntakeStaging(processor.assetStore, draft.id)
              onItsWay += 1
              continue
            }
            defer { if let digest { self?.intake.receiving.remove(digest) } }
            if let digest,
              let existing = try? await repository.existingCapture(withOriginalDigest: digest)
            {
              await Self.discardIntakeStaging(processor.assetStore, draft.id)
              duplicates.append(existing)
              continue
            }
            do {
              try await repository.createUserItem(draft)
              await Self.commitIntakeStaging(processor.assetStore, draft.id)
              stored += 1
              storedIDs.append(draft.id)
            } catch {
              await Self.discardIntakeStaging(processor.assetStore, draft.id)
              rejected.append("未能存到这台 Mac，没有收")
            }
          case .media(let url):
            let hashed = await Self.fileDigest(url)
            let digest = hashed?.digest
            if let digest, self?.claimIntake(digest) == false {
              onItsWay += 1
              continue
            }
            if let digest,
              let existing = try? await repository.existingCapture(withOriginalDigest: digest)
            {
              self?.intake.receiving.remove(digest)
              duplicates.append(existing)
              continue
            }
            // Stays claimed until it is queued below (then the queue says it
            // is on its way).
            if let hashed { mediaDigests[url] = hashed }
            media.append(url)
          case .rejected(let message):
            rejected.append(message)
          }
        }
      }
      guard let self else { return }
      // A recording or video over 1 GB that is not here yet is asked about
      // once, all of them in one question (STORE-005); a file the item limit
      // refuses or one already in the library is never asked about (review
      // 10-6 S13). Declined ones are left where they are.
      let declined = Self.largeMediaDeclined(media)
      for url in declined {
        if let digest = mediaDigests.removeValue(forKey: url)?.digest {
          intake.receiving.remove(digest)
        }
      }
      media.removeAll { declined.contains($0) }
      intake.inProgress = false
      for url in media {
        intake.pendingMediaImports.append(.init(url: url, source: source, hashed: mediaDigests[url]))
      }
      for hashed in mediaDigests.values { intake.receiving.remove(hashed.digest) }
      let refusal = startNextQueuedMediaImport()
      if !storedIDs.isEmpty {
        CaptureFeedback.shared.taken(storedIDs, kind: .item)
      } else if !media.isEmpty, refusal == nil {
        // A recording or video is taken in once its import finishes; it is
        // already safe on this Mac.
        CaptureFeedback.shared.show(MemoryToast("已添加", icon: .mark))
      } else if let first = duplicates.first {
        CaptureFeedback.shared.duplicate(of: first)
      } else if onItsWay > 0 {
        // Already being taken in: it is safe; nothing is taken twice.
        CaptureFeedback.shared.show(MemoryToast("已添加", icon: .mark))
      }
      if let message = refusal ?? rejected.first {
        intake.show(message)
      } else if let note, stored > 0 {
        intake.show(note)
      }
      if stored > 0 {
        // New items join local fallback events right away, as recordings do.
        await refreshHistoryItems(preserveStatus: true, organizeEvents: true)
      }
    }
  }

  /// 1 GB as the question shows it (`ByteCountFormatter` counts in
  /// thousands).
  static let largeFileBytes: Int64 = 1_000_000_000

  /// The recordings and videos over 1 GB the user chose not to add, asked
  /// in one question.
  static func largeMediaDeclined(_ media: [URL]) -> Set<URL> {
    let large = media.compactMap { url -> (URL, Int64)? in
      guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
        Int64(size) > largeFileBytes
      else { return nil }
      return (url, Int64(size))
    }
    guard !large.isEmpty else { return [] }
    let alert = NSAlert()
    alert.messageText = largeFileQuestion(large.map { ($0.0.lastPathComponent, $0.1) })
    alert.informativeText = "文件会拷贝到 Mindloom，占用相同大小的空间。原文件保持不变。"
    alert.addButton(withTitle: "添加")
    alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
    guard alert.runModal() != .alertFirstButtonReturn else { return [] }
    return Set(large.map(\.0))
  }

  /// 「添加“讲座.mov”（2.3 GB）？」 or 「添加 2 个大于 1 GB 的文件（共 4.1 GB）？」.
  static func largeFileQuestion(_ files: [(name: String, bytes: Int64)]) -> String {
    let total = SettingsStorage.bytes(files.reduce(0) { $0 + $1.bytes })
    if files.count == 1, let file = files.first {
      return "添加“\(file.name)”（\(total)）？"
    }
    return "添加 \(files.count) 个大于 1 GB 的文件（共 \(total)）？"
  }

  /// Claims `digest` for one intake; false when the same bytes are already
  /// on their way in.
  func claimIntake(_ digest: String) -> Bool {
    guard !intake.isOnItsWay(digest, importing: capture.importInProgress) else { return false }
    intake.receiving.insert(digest)
    return true
  }

  /// The SHA-256 of a file's bytes with the file's fingerprint (read in
  /// chunks, off the main actor); nil when it cannot be read. The import
  /// reuses it (`pendingImportHashed`) while the file is unchanged.
  nonisolated static func fileDigest(_ url: URL) async -> HashedSourceFile? {
    await Task.detached(priority: .utility) { HashedSourceFile.hash(url) }.value
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
    intake.importingDigest = next.digest
    pendingImportSourceApplication = next.source
    pendingImportHashed = next.hashed
    importMedia(next.url)
    if !capture.importInProgress {
      // Refused (components not ready, a recording in progress, ...). The
      // queue is dropped rather than started by surprise later; the user's
      // files are untouched and can be dropped again.
      pendingImportSourceApplication = nil
      pendingImportHashed = nil
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
