import AppKit
import BestASRMemoryUI
import BestASRAudioJournal
import BestASRDictation
import BestASRDomain
import BestASRFluidRuntime
import BestASRInference
import BestASRIntake
import BestASRDelivery
import BestASRMLXRuntime
import BestASRMacAudio
import BestASRMacPermissions
import BestASRMacUI
import BestASRModelManager
import BestASRPersistence
import BestASRPortableArchiveProbe
import BestASRProcessing
import BestASRQwenRuntime
import BestASRRemoteOrganizer
import Combine
import CoreGraphics
import CryptoKit
import Foundation
import MindloomLibrary
import OSLog
import ServiceManagement
import UniformTypeIdentifiers
import MindloomIdentity

let dictationAppLogger = Logger(
  subsystem: MindloomIdentity.logSubsystem,
  category: "dictation-app"
)

enum BestASRAppStorageError: LocalizedError {
  case externalCacheUnavailable

  var errorDescription: String? {
    switch self {
    case .externalCacheUnavailable:
      "Mindloom 的外置缓存盘未装载。请重新装载该卷后再打开 Mindloom。历史、录音、词典、人物和已安装的模型保存在这台 Mac 上。"
    }
  }
}

/// Transcript `inputRevision` is an inference-input revision, not a reliable
/// presentation timestamp. A completed final recognition can therefore be
/// created after higher-numbered live drafts. Select the current user-facing
/// revision from terminal revisions by creation time, and only fall back to a
/// live draft while no final or user edit exists.
enum TranscriptSelection {
  static func current(
    in transcripts: [DictationPersistedTranscriptRecord]
  ) -> DictationPersistedTranscriptRecord? {
    let terminal = transcripts.filter {
      $0.kind == .final || $0.kind == .userEdit
    }
    return mostRecent(in: terminal.isEmpty ? transcripts : terminal)
  }

  static func timestamped(
    in transcripts: [DictationPersistedTranscriptRecord]
  ) -> DictationPersistedTranscriptRecord? {
    if let current = current(in: transcripts), !current.segments.isEmpty {
      return current
    }
    let terminal = transcripts.filter {
      !$0.segments.isEmpty && ($0.kind == .final || $0.kind == .userEdit)
    }
    if let transcript = mostRecent(in: terminal) { return transcript }
    return mostRecent(in: transcripts.filter { !$0.segments.isEmpty })
  }

  static func recognitionSource(
    for transcript: DictationPersistedTranscriptRecord,
    in transcripts: [DictationPersistedTranscriptRecord]
  ) -> DictationPersistedTranscriptRecord? {
    var source = transcript
    var visited = Set<TranscriptRevisionID>()
    while source.kind == .userEdit {
      guard visited.insert(source.id).inserted,
        let parentID = source.parentID,
        let parent = transcripts.first(where: {
          $0.id == parentID && $0.sessionID == transcript.sessionID
        })
      else { return nil }
      source = parent
    }
    return source
  }

  static func mostRecent(
    in transcripts: [DictationPersistedTranscriptRecord],
    where predicate: (DictationPersistedTranscriptRecord) -> Bool = { _ in true }
  ) -> DictationPersistedTranscriptRecord? {
    transcripts.filter(predicate).max { lhs, rhs in
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
      if lhs.inputRevision != rhs.inputRevision {
        return lhs.inputRevision < rhs.inputRevision
      }
      let lhsRank = kindRank(lhs.kind)
      let rhsRank = kindRank(rhs.kind)
      if lhsRank != rhsRank { return lhsRank < rhsRank }
      return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
    }
  }

  private static func kindRank(_ kind: TranscriptRevisionKind) -> Int {
    switch kind {
    case .streaming: 0
    case .sentence: 1
    case .final: 2
    case .userEdit: 3
    }
  }
}

enum TranscriptSpeakerSelection {
  static func occurrence(
    for segment: DictationTranscriptSegment,
    in occurrences: [SpeakerOccurrenceSummary]
  ) -> SpeakerOccurrenceSummary? {
    let overlapping = occurrences.filter { overlap(segment, $0) > 0 }
    let groups = Dictionary(grouping: overlapping, by: \.sessionSpeakerID)
    let coverage = groups.map { speakerID, values in
      (speakerID: speakerID, duration: coveredDuration(segment, values))
    }
    guard let winner = coverage.max(by: { $0.duration < $1.duration }) else {
      return nil
    }
    let otherCoverage = coverage.filter { $0.speakerID != winner.speakerID }
      .reduce(0.0) { $0 + Double($1.duration) }
    // Silence between one speaker's turns is not an unknown speaker. Count
    // retained speech coverage, not just a sentence's midpoint or longest turn.
    // Ties and mixed segments without a majority stay unassigned.
    guard Double(winner.duration) > otherCoverage else { return nil }
    return groups[winner.speakerID]?.max { lhs, rhs in
      let left = overlap(segment, lhs)
      let right = overlap(segment, rhs)
      if left != right { return left < right }
      return lhs.id.rawValue.uuidString > rhs.id.rawValue.uuidString
    }
  }

  static func displayTitle(
    displayName: String?,
    personID: PersonID?,
    associationStatus: PersonAssociationStatus,
    stableOrdinal: UInt32
  ) -> String {
    let anonymous = "说话人 \(speakerLabel(ordinal: stableOrdinal))"
    switch associationStatus {
    case .candidate:
      return displayName.map { "可能是 \($0)" }
        ?? "\(anonymous) · 待确认"
    case .rejected:
      return "\(anonymous) · 未关联"
    case .unknown:
      return anonymous
    case .anonymousIdentity, .automaticMatch, .userConfirmed:
      return displayName ?? anonymous
    }
  }

  static func speakerLabel(ordinal: UInt32) -> String {
    var value = max(1, ordinal)
    var label = ""
    repeat {
      value -= 1
      label = String(UnicodeScalar(65 + value % 26)!) + label
      value /= 26
    } while value > 0
    return label
  }

  private static func overlap(
    _ segment: DictationTranscriptSegment,
    _ occurrence: SpeakerOccurrenceSummary
  ) -> UInt64 {
    let start = max(segment.monotonicStartNanoseconds, occurrence.monotonicStartNanoseconds)
    let end = min(segment.monotonicEndNanoseconds, occurrence.monotonicEndNanoseconds)
    return end > start ? end - start : 0
  }

  private static func coveredDuration(
    _ segment: DictationTranscriptSegment,
    _ occurrences: [SpeakerOccurrenceSummary]
  ) -> UInt64 {
    let intervals = occurrences.map {
      (
        start: max(segment.monotonicStartNanoseconds, $0.monotonicStartNanoseconds),
        end: min(segment.monotonicEndNanoseconds, $0.monotonicEndNanoseconds)
      )
    }.sorted { $0.start < $1.start }
    var covered: UInt64 = 0
    var coveredUntil = segment.monotonicStartNanoseconds
    for interval in intervals {
      let start = max(interval.start, coveredUntil)
      if interval.end > start { covered += interval.end - start }
      coveredUntil = max(coveredUntil, interval.end)
    }
    return covered
  }
}

struct HistoryNavigationOrigin: Equatable, Sendable {
  enum Kind: String, Sendable {
    case person = "people"
    case event = "events"

    var title: String {
      switch self {
      case .person: "人物"
      case .event: "事情"
      }
    }
  }

  let kind: Kind
  let title: String

  var returnTitle: String {
    "返回\(kind.title)：\(title)"
  }
}

struct CaptureWorkspaceHandoff: Equatable, Sendable {
  enum State: Equatable, Sendable {
    case processing
    case completed
    case needsAttention
  }

  let sessionID: SessionID
  let inputMode: SessionInputMode
  let state: State
  let title: String
  let detail: String
  let sourceDisplayName: String?
  let sourceAudioRetained: Bool
}

struct CaptureLifecycleCommandState {
  enum Mode: Equatable {
    case dictation
    case roomRecording
    case systemAudio
  }

  enum Action: Equatable {
    case start
    case end
    case pauseOrResume
    case cancel
  }

  private(set) var inFlightMode: Mode?
  /// What the in-flight command is doing, so a key press arriving during it
  /// can be interpreted against that and not only against the phase.
  private(set) var inFlightAction: Action?
  private var deferredAction: Action?

  mutating func begin(_ mode: Mode, action: Action) -> Bool {
    guard inFlightMode == nil else { return false }
    inFlightMode = mode
    inFlightAction = action
    deferredAction = nil
    return true
  }

  mutating func queueIfInFlight(
    _ action: Action,
    for mode: Mode
  ) -> Bool {
    guard inFlightMode == mode else { return false }
    deferredAction = action
    return true
  }

  mutating func finish(_ mode: Mode) -> Action? {
    guard inFlightMode == mode else { return nil }
    let action = deferredAction
    inFlightMode = nil
    inFlightAction = nil
    deferredAction = nil
    return action
  }
}

@MainActor
enum LocalModelLicenseReceipts {
  private static let defaults = UserDefaults.standard

  static func accepted(key: String, receipt: String) -> Bool {
    defaults.string(forKey: key) == receipt
  }

  static func setAccepted(_ accepted: Bool, key: String, receipt: String) {
    if accepted {
      defaults.set(receipt, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }
}

/// NSPasteboard is an AppKit object and must stay on the main actor. The old
/// isolated actor could execute pasteboard calls on a cooperative background
/// thread, which made the floating panel appear to freeze after Copy.
@MainActor
final class LocalPasteboardWriter {
  private let pasteboard: NSPasteboard

  /// The general pasteboard in the app, written only by explicit user copy
  /// actions; tests pass a private named pasteboard.
  init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
  }

  /// Writes the text with bestASR's origin mark, so ⌘V in bestASR does not
  /// take bestASR's own copy in again as an item from another App.
  func write(_ text: String) -> Bool {
    IntakePasteboardMarks.writeOwnText(text, to: pasteboard)
  }
}

actor LocalImportedMediaFileStore {
  private let assetRoot: URL

  init(assetRoot: URL) {
    self.assetRoot = assetRoot
  }

  /// Copies `source` into the session's folder and records its digest.
  /// `hashed` (the drop path's digest of the same file) is reused when the
  /// file is unchanged before and after the copy; otherwise the copy is
  /// hashed here, as before.
  func stage(source: URL, sessionID: SessionID, hashed: HashedSourceFile? = nil) throws
    -> RetainedSourceAssetRecord
  {
    let values = try source.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    )
    guard
      values.isRegularFile == true,
      values.isSymbolicLink != true,
      let size = values.fileSize,
      size > 0
    else { throw CocoaError(.fileReadInvalidFileName) }
    let extensionValue = source.pathExtension.lowercased()
    guard MediaImportFormats.extensions.contains(extensionValue) else {
      throw CocoaError(.fileReadUnsupportedScheme)
    }
    let relative =
      "sessions/\(sessionID.rawValue.uuidString.lowercased())/source/original.\(extensionValue)"
    let destination = assetRoot.appendingPathComponent(relative)
    let directory = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let temporary = directory.appendingPathComponent(
      ".original.\(UUID().uuidString).importing"
    )
    defer { try? FileManager.default.removeItem(at: temporary) }
    let unchangedBefore = hashed?.stillDescribes(source) ?? false
    try FileManager.default.copyItem(at: source, to: temporary)
    let handle = try FileHandle(forUpdating: temporary)
    try handle.synchronize()
    try handle.close()
    let copiedSize =
      (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
    let digest: String
    if let hashed, unchangedBefore, hashed.stillDescribes(source),
      copiedSize == hashed.fingerprint.size
    {
      digest = hashed.digest
    } else {
      digest = try Self.digest(file: temporary)
    }
    try FileManager.default.moveItem(at: temporary, to: destination)
    return RetainedSourceAssetRecord(
      id: UUID(),
      sessionID: sessionID,
      revision: try Revision(1),
      kind: .importedOriginal,
      originalFilename: source.lastPathComponent,
      mediaType: Self.mediaType(for: extensionValue),
      assetReference: try PortableAssetReference(relativePath: relative),
      digest: try BestASRDomain.SHA256Digest(digest),
      sizeBytes: UInt64(size),
      createdAt: Date()
    )
  }

  func verifiedURL(for asset: RetainedSourceAssetRecord) throws -> URL {
    guard asset.kind == .importedOriginal,
      case .relativePath(let relativePath) = asset.assetReference,
      relativePath.hasPrefix(
        "sessions/\(asset.sessionID.rawValue.uuidString.lowercased())/source/"
      ),
      !relativePath.contains(".."),
      !relativePath.hasPrefix("/")
    else { throw CocoaError(.fileReadCorruptFile) }
    let url = assetRoot.appendingPathComponent(relativePath).standardizedFileURL
    let values = try url.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values.isRegularFile == true,
      values.isSymbolicLink != true,
      UInt64(values.fileSize ?? 0) == asset.sizeBytes,
      try Self.digest(file: url) == asset.digest.value.lowercased()
    else { throw CocoaError(.fileReadCorruptFile) }
    return url
  }

  private static func digest(file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    // Each chunk released as soon as it is hashed (see LocalModelManager.sha256).
    while try autoreleasepool(invoking: {
      let data = try handle.read(upToCount: 1_048_576) ?? Data()
      if data.isEmpty { return false }
      hasher.update(data: data)
      return true
    }) {}
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func mediaType(for extensionValue: String) -> String {
    switch extensionValue {
    case "wav": "audio/wav"
    case "m4a": "audio/mp4"
    case "mp3": "audio/mpeg"
    case "aac": "audio/aac"
    case "mp4": "video/mp4"
    case "mov": "video/quicktime"
    default: "application/octet-stream"
    }
  }
}

actor LocalImportPauseGate {
  private var paused = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func setPaused(_ value: Bool) {
    paused = value
    guard !value else { return }
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }

  func waitIfPaused() async {
    guard paused else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}

enum ImportPauseAction: Equatable, Sendable {
  case waitForPreparation
  case pause
  case resume
  case none
  case unavailable
}

struct ImportPauseIntent: Equatable, Sendable {
  private(set) var wantsPaused = false

  @discardableResult
  mutating func toggle() -> Bool {
    wantsPaused.toggle()
    return wantsPaused
  }

  mutating func setPaused(_ value: Bool) {
    wantsPaused = value
  }

  mutating func reset() {
    wantsPaused = false
  }

  func action(for phase: DictationPhase) -> ImportPauseAction {
    switch (wantsPaused, phase) {
    case (true, .idle), (true, .preparing): .waitForPreparation
    case (true, .recording): .pause
    case (false, .paused): .resume
    case (true, .paused), (false, .idle), (false, .preparing),
      (false, .recording):
      .none
    default: .unavailable
    }
  }
}

enum AppTextFormattingStyle: String, Codable, CaseIterable, Identifiable,
  Sendable
{
  case automatic
  case plainText
  case markdown
  case codeComment

  var id: String { rawValue }

  var title: String {
    switch self {
    case .automatic: "自动"
    case .plainText: "纯文本"
    case .markdown: "Markdown"
    case .codeComment: "代码注释"
    }
  }
}

struct AppTextPolicy: Codable, Equatable, Identifiable, Sendable {
  var id: String { bundleIdentifier }
  var bundleIdentifier: String
  var displayName: String
  var polishEnabled: Bool
  var formattingStyle: AppTextFormattingStyle
}

struct AppTextPolicyChoice: Equatable, Identifiable, Sendable {
  var id: String { bundleIdentifier }
  let bundleIdentifier: String
  let displayName: String
}

struct LocalModelComponentPresentation: Identifiable, Equatable, Sendable {
  let component: LocalModelComponent
  let revision: String
  let sizeBytes: UInt64
  let ready: Bool

  var id: LocalModelComponent { component }
}

@MainActor
enum LocalPreferenceStore {
  static let defaults = UserDefaults.standard

  static func bool(_ key: String, default fallback: Bool) -> Bool {
    defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
  }

  static func string(_ key: String, default fallback: String) -> String {
    defaults.string(forKey: key) ?? fallback
  }

  static func strings(_ key: String) -> [String] {
    defaults.stringArray(forKey: key) ?? []
  }

  static func boolMap(_ key: String) -> [String: Bool] {
    guard let values = defaults.dictionary(forKey: key) else { return [:] }
    return values.reduce(into: [:]) { result, pair in
      if let value = pair.value as? NSNumber {
        result[pair.key] = value.boolValue
      }
    }
  }

  static func uuid(_ key: String) -> UUID {
    if let value = defaults.string(forKey: key),
      let existing = UUID(uuidString: value)
    {
      return existing
    }
    let created = UUID()
    defaults.set(created.uuidString, forKey: key)
    return created
  }

  static func policies() -> [AppTextPolicy] {
    guard let data = defaults.data(forKey: "preferences.app-text-policies.v1")
    else { return [] }
    return (try? JSONDecoder().decode([AppTextPolicy].self, from: data)) ?? []
  }
}

struct HistoryRefreshGenerationGate {
  private(set) var current: UInt64 = 0

  mutating func begin() -> UInt64 {
    current &+= 1
    return current
  }

  func accepts(_ generation: UInt64) -> Bool {
    generation == current
  }
}

struct HistoryPlaybackUIFixture {
  let sessionID: SessionID
  let assetRootURL: URL
  let descriptor: CaptureTrackDescriptor
  let ranges: [AudioRangeInput]
  var transcript: DictationPersistedTranscriptRecord
  var speakers: [SessionSpeakerSummary]
  var occurrences: [SpeakerOccurrenceSummary]
  var people: [PersonSummary]
}

struct EventReviewUIFixture {
  let candidate: EventCandidate
  let initialSummary: EventSummary
  let acceptedSummary: EventSummary
}

struct EventReviewUIFixtureState {
  let summaries: [EventSummary]
  let candidates: [EventCandidate]
  let selectedEventID: EventID?
}

@MainActor
final class DictationAppModel: ObservableObject {

  // Each concern's state is its own object; the app model owns them and
  // forwards their changes so every existing view keeps updating.
  var dictionary = DictionaryModel()
  var usage = UsageModel()
  var export = ExportModel()
  var memorySearch = MemorySearchModel()
  /// v12 search: the meaning half of 历史's and other Apps' search.
  let meaningSearch = MeaningSearch()
  var playback = PlaybackModel()
  var history = HistoryModel()
  var capture = CaptureModel()
  var models = ModelsModel()
  var people = PeopleModel()
  var events = EventsModel()
  /// Mirrors the per-library link state held by `remoteOrganizer`; the
  /// enable watermark lives in the library, not in app preferences.
  @Published var remoteOrganizerEnabled = false
  /// "让 Spark 忘掉" is offered (the link is on and the organizing device
  /// answers), and whether its store belongs to another key.
  @Published var remoteOrganizerCanForget = false
  @Published var remoteOrganizerHoldsOtherKey = false
  @Published var remoteOrganizerForgetting = false
  /// v11: the link's status as the pages word it (已连接 / 没连上 / 连接中),
  /// and when the DGX Spark's state last arrived (「上次整理 22:40」).
  @Published var remoteOrganizerLinkStatus: RemoteOrganizerLinkController.Status = .off
  @Published var remoteOrganizerLastPull: Date?
  var remoteOrganizer: RemoteOrganizerLinkController?
  /// The paired iPhone (PHONE-CONTRACT §4).
  var phoneLink = PhoneLinkModel()
  /// Other Apps reading Mindloom (AGENT-CONTRACT; v12 1D): grants, every call,
  /// the changes they made (each undoable).
  var agentAccess = AgentAccessModel()
  var agentRequestPanel: AgentRequestPanelController?
  var spoken = SpokenModel()
  var hotkeys = HotkeysModel()
  var onboarding = OnboardingModel()
  /// The undo window (v11), owned for the App's lifetime: closing the main
  /// window never drops a held correction, and a crash leaves it in the
  /// library's journal for the next launch (`DictationAppModel+Memory`).
  lazy var memoryCorrections: MemoryCorrectionQueue = makeMemoryCorrections()
  private var childObservers: [AnyCancellable] = []

  private func observeChildren() {
    dictionary.captureIsActive = { [weak self] in self?.hasActiveCapture ?? false }
    spoken.languagesChanged = { [weak self] in
      guard let self else { return }
      spoken.activeTranslationLanguage = Self.translationLanguage(
        at: spokenModePlan?.languageIndex ?? 0, among: spoken.translationTargetLanguageNames)
    }
    childObservers = [
      dictionary.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
      usage.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
      export.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
      memorySearch.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
      playback.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
      history.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
      capture.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
      models.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
      people.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
      events.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
      spoken.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
      hotkeys.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
      onboarding.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
      intake.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
      phoneLink.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
      agentAccess.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
    ]
  }
  static let speechLicenseReceiptKey =
    "model-license-receipt.automatic-speech-pack-v2"
  static let polishLicenseReceiptKey =
    "model-license-receipt.qwen3-1.7b-mlx-4bit"
  static let meaningLicenseReceiptKey =
    "model-license-receipt.qwen3-embedding-0.6b-mlx-4bit"
  static let speakerLicenseReceiptKey =
    "model-license-receipt.fluid-speaker-diarization-coreml"
  static let speechLicenseReceipt =
    "LicenseRef-FunASR-Model-1.1|0e0bf30bfc6836f182ccd1d89984df919c949e26|5dd557bd06342a3cd07ceccb909d8a45e48b053a|7dba975a2069691db4992b0592d70828b330d2f8a30a71450f4e152a554e84f8|CC-BY-4.0|4252711f6f060f9a2f91e5f081a806d7f45eebd8|ba3860fa07d324df252296b64388d46bedb9c37f3e9c463154a0703e57cc0d67"
  static let polishLicenseReceipt =
    "Apache-2.0|21457c6f51ed54a7c16e988c0844db973815c137|b83d568eb276ef9705b46d55f6b85393b444e1c2a20b5fce45c4ee5f0102f80a"
  /// Apache-2.0 | the model's revision | the license text's SHA-256
  /// (`Legal/Qwen3-LICENSE-Apache-2.0.txt`).
  static let meaningLicenseReceipt =
    "Apache-2.0|6c3ae70858513f1a78e9cdca3cae330d9075cd2a|b83d568eb276ef9705b46d55f6b85393b444e1c2a20b5fce45c4ee5f0102f80a"
  static let speakerLicenseReceipt =
    "CC-BY-4.0|1ed7a662fdc7109e36d822db793ee6eebdaf8594|638b2185c4e3885a54d79d1ea6765a7778519b902389be632e37389c80e41a63"

  @Published var snapshot = DictationSessionSnapshot()
  @Published var statusMessage = "正在启动本地服务…"
  @Published var startupFailureMessage = ""
  @Published var recoveryItemCount = 0
  @Published var startupRecoverySessionIDs: Set<SessionID> = []
  @Published var enhancedFinalASRReady = false
  @Published var polishRuntimeReady = false
  /// v12 search: the meaning model is installed and verified.
  @Published var meaningSearchReady = false
  @Published var polishReadinessMessage =
    "本地文字整理尚未准备；口述仍可使用基础标点"
  /// Every application dictation has been written into, for the source filter.
  /// The mode of the dictation now running, for the floating capsule.
  @Published var dictationMode: DictationSpokenMode = .dictate
  nonisolated static let translationLanguageKey = "preferences.translation-languages"



  /// Puts up the system's download prompt for a language pair.
  let translationInstaller = TranslationInstaller()
  /// A language a finished dictation needed and did not have. The prompt is
  /// shown once the dictation has been delivered, never during it.
  var translationInstallNeeded: String?
  /// The last dictation whose translation went in as said because its
  /// language was not installed: the HUD says so when it ends (收1-9).
  var untranslatedDictation: (session: SessionID, language: String)?
  /// What the last dictation wrote in place of what was said (a translation,
  /// an answer): the HUD's caption ends with it. Held in memory only, for
  /// one dictation; never written to the database or logged.
  var deliveredDictationText: (session: SessionID, text: String)?





  var spokenModePlan: SpokenModePlan?
  /// Answers produced by a 指令, kept only until that dictation is delivered
  /// or shown. Never written to the database.
  var commandAnswers: [SessionID: String] = [:]
  /// The same Accessibility port the insertion service uses, kept so 指令 mode
  /// can read what the user highlighted.
  var targetReader: TargetReader?
  /// Sessions whose result was shown as an answer and already copied.
  var answeredSessionIDs = Set<SessionID>()
  lazy var spokenAnswerPanel = SpokenAnswerPanelController()

  /// True while the running dictation was started from this window — the
  /// "试一句" button — rather than by the hotkey from another app. Only then
  /// does the main window show a live panel for it.
  @Published var dictationStartedInApp = false
  @Published var selectedSessionOccurrences: [SpeakerOccurrenceSummary] = []
  @Published var splitOccurrenceIDs = Set<SpeakerOccurrenceID>()
  /// Set once 事件 has been opened in this run. Until then, no dictation and
  /// no launch organizes events: that work is sentence embeddings over the
  /// whole library, and it belongs to the page that shows the result.
  var eventMemoryWanted = false
  @Published var liveTranscriptText = ""
  @Published var liveTranscriptStatus =
    "音频会先保存，再进行本地识别"
  @Published var menuBarEnabled = LocalPreferenceStore.bool(
    "preferences.menu-bar-enabled",
    default: true
  ) {
    didSet {
      LocalPreferenceStore.defaults.set(
        menuBarEnabled,
        forKey: "preferences.menu-bar-enabled"
      )
    }
  }
  @Published var launchAtLoginEnabled = false
  @Published var defaultPolishEnabled = DictationAppModel.initialDefaultPolishEnabled()
  /// 设置 › 通用 › 口述时显示文字 (on by default; ALIGNMENT 收1-17). The old
  /// 「只在鼠标悬停时显示实时字幕」 key is no longer read: v11 ignored it.
  @Published var dictationCaptionsEnabled = LocalPreferenceStore.bool(
    DictationAppModel.dictationCaptionsKey,
    default: true
  )
  @Published var appTextPolicies = LocalPreferenceStore.policies()
  @Published var appPolicyBundleIDDraft = ""
  @Published var appPolicyDisplayNameDraft = ""
  @Published var appPolicyPolishEnabled = true
  @Published var appPolicyFormattingStyle: AppTextFormattingStyle = .automatic
  @Published var preferencesStatusMessage = ""
  @Published var storageSnapshot = LocalStorageSnapshot()
  /// Settings › 通用 › 储存空间 (收3-5): by kind, by month, and the disk.
  @Published var libraryStorage: LibraryStorageReport?
  /// Dictionary words learning made (自动添加), by word.
  @Published var automaticDictionaryEntries: [DictionaryEntryID: AutomaticDictionaryEntry] = [:]
  /// Reads the last dictation's field again a while after it was typed in
  /// (改了就校准, `scheduleCorrectionSettle`).
  var correctionSettleTask: Task<Void, Never>?
  /// What the watched field has shown of the last dictation, read every
  /// second or two while the watch lasts (`followFieldCorrections`).
  var fieldCorrections: FieldCorrectionTracker?
  @Published var storageStatusMessage = "正在统计本机储存空间…"
  @Published var storageRefreshInProgress = false
  @Published var diagnosticsPreview = ""
  @Published var requestedNavigationSectionID: String?
  /// The zone the library counts days in (ALIGNMENT 根-13): Home's 今天 and
  /// 已过期, due dates and time words in search. Set at launch from the
  /// library (`MindloomLaunch.applyProductTimeZone`), changed in 通用.
  @Published var productTimeZone: TimeZone =
    MindloomLaunch.launch.map { MindloomLaunch.productTimeZone(root: $0.root) } ?? .current
  /// A record 历史 should show and light when it opens next (menu bar
  /// 最近记录 › 在历史里查看).
  var pendingHistoryReveal: String?


  let fixtureMode: Bool
  /// The owner's 「我」, or the demo root's own in demo mode.
  let localSelfPersonID = PersonID(LibraryIdentity.localSelfPersonID)
  var repository: GRDBDictationStore?
  var journal: ProductionAudioJournal?
  var coordinator: DictationCaptureCoordinator?
  /// Dictations whose audio is sealed and that are still being recognized,
  /// cleaned up and inserted in the background.
  var finalizingSessionIDs: Set<SessionID> = []
  var finalizationChain: Task<Void, Never>?
  var bookkeepingChain: Task<Void, Never>?
  /// A finished dictation changed history while nobody was looking at it.
  var historyNeedsRefresh = false
  var dictationLifecycleTask: Task<Void, Never>?
  var activeDictationMicrophoneUID = ""
  var roomCoordinator: DictationCaptureCoordinator?
  var roomLevelMonitor: AVAudioEngineMicrophoneLevelMonitor?
  var roomLevelTask: Task<Void, Never>?
  var roomLifecycleTask: Task<Void, Never>?
  var activeRoomMicrophoneUID = ""
  var systemAudioCoordinator: DictationCaptureCoordinator?
  var systemAudioLifecycleTask: Task<Void, Never>?
  var activeSystemMicrophoneUID = ""
  /// 开始记录会议 asked for the computer's sound: the next system-audio
  /// start records this pick (the meeting App playing sound, the whole
  /// computer, or what the menu chose) plus the microphone when allowed,
  /// whatever the 电脑内录 page's own source choice is (v12 1C).
  var meetingComputerSound: MeetingAudioPick?
  /// What the running system-audio recording captures (scope and whether a
  /// microphone track goes with it); a paused one resumes the same way.
  var activeSystemScope: SystemAudioCaptureScope?
  var activeSystemIncludesMicrophone = false
  var activeSystemOutputDeviceID: UInt32?
  let sourceContextAdapterRegistry = LocalSourceContextAdapterRegistry()
  var lastSystemSourceContextFingerprint = ""
  var lastSystemSourceContextPollNanoseconds: UInt64 = 0
  var lastSystemSourceContextPersistedNanoseconds: UInt64 = 0
  var recentSystemAudioSourceIDs = LocalPreferenceStore.strings(
    "preferences.recent-system-audio-sources"
  )
  var systemAudioMicrophoneOverrides = LocalPreferenceStore.boolMap(
    "preferences.system-audio-microphone-overrides.v1"
  )
  var systemAudioMicrophoneSelectionIsAutomatic = true
  var systemAudioPreviewCapture: (any MicrophoneCapturePort)?
  var systemAudioPreviewTask: Task<Void, Never>?
  var systemAudioPreviewID: UUID?
  var importedMediaDecoder: AVFoundationImportedMediaDecoder?
  var importedMediaFileStore: LocalImportedMediaFileStore?
  var importTask: Task<Void, Never>?
  var importOpenPanel: NSOpenPanel?
  var importSessionActor: DictationSessionActor?
  var importSessionID: SessionID?
  let importPauseGate = LocalImportPauseGate()
  var importPauseIntent = ImportPauseIntent()
  var importPauseControlTask: Task<Void, Never>?
  var importCancellationShouldDiscard = true
  /// Pasted/dragged intake (PRD §0.3.2); set once the library is open.
  let intake = IntakeModel()
  /// Every other entry (Settings → 入口, V8 contract §A).
  let entries = EntriesModel()
  /// 设置 › 设备与隐私 › 从网络补充信息 (PRD LOOKUP-001–003).
  let webLookup = WebLookupModel()
  var intakeProcessor: IntakeProcessor?
  /// The startup staging sweep; every intake waits for it.
  var intakeReady: Task<Void, Never>?
  /// `NSPasteboard.changeCount` of the last clipboard taken in.
  var lastReceivedPasteChangeCount: Int?
  var sourceApplicationTracker: (any SourceApplicationProviding)?
  /// The App an intake-routed audio/video file came from, consumed by the
  /// next `startImport`.
  var pendingImportSourceApplication: ItemSourceApplication?
  /// The drop path's digest of that file, reused by the import's copy while
  /// the file is unchanged (the recording is not read twice to hash it).
  var pendingImportHashed: HashedSourceFile?
  var permissionService: MacDictationPermissionService?
  var permissionRefreshTask: Task<Void, Never>?
  var insertionService: DeliveryInsertionPort?
  var localRuntime: LocalDictationRuntime?
  var hotkeyProvider: NativeGlobalHotkeyProvider?
  var hotkeyController: GlobalHotkeyConfigurationController?
  var hotkeyTask: Task<Void, Never>?
  var hotkeyRegistrationAvailable = false
  var preflightHotkeyInsertionTarget: DictationTargetSnapshot?
  var preflightHotkeyTargetUptimeNanoseconds: UInt64 = 0
  var copiedRetainedSessionID: SessionID?
  var copiedRetainedTextWasDraft = false
  var functionHoldStartedAt: ContinuousClock.Instant?
  /// The fn press's own time (seconds since the Mac started), when known.
  var functionHoldKeyTime: TimeInterval?
  var firstAudioPendingSince: ContinuousClock.Instant?
  /// Key down to recording started (the capture coordinator running) for
  /// the dictation being recorded: the definition 收1-19 is judged by.
  var pressToRecording: Duration?
  /// The key events that will start and end the dictation, from the events'
  /// own times: the timing table counts from the key itself, not from when
  /// the main actor got round to it (review 2026-10-06).
  var dictationStartKeyAt: ContinuousClock.Instant?
  var dictationEndKeyAt: ContinuousClock.Instant?
  /// This Mac's dictation timings (numbers only, 90 days; 收1-2, 收1-5).
  var dictationMetricsStore: DictationMetricsStore?
  /// 设置 › 口述 › 速度与占用.
  @Published var dictationMetrics = SettingsDictationMetrics()
  var keyPressMicrophone: (early: EarlyMicrophoneStart, at: ContinuousClock.Instant)?
  var diskSpaceDecisionCache:
    (decision: CaptureDiskSpaceDecision, checkedAt: ContinuousClock.Instant)?
  var onboardingPracticeTargetArmed = false
  var pushToTalkFinishTask: Task<Void, Never>?
  var functionReleaseWatchdog: Task<Void, Never>?
  var liveTranscriptTask: Task<Void, Never>?
  var recommendedModelInstallTask: Task<Void, Never>?
  var lifecycleCommands = CaptureLifecycleCommandState()
  var fixtureActor: DictationSessionActor?
  let pasteboardWriter = LocalPasteboardWriter()
  var historyListCopyRequestID = UUID()
  var historyDetailCopyRequestID = UUID()
  var memorySearchTask: Task<Void, Never>?
  var memorySearchRequestID = UUID()
  let historyAudioPlayer = LocalSessionAudioPlayer()
  let historyWaveformSampler = LocalWaveformSampler()
  let historyExporter = LocalHistoryExporter()
  let portableArchiveStore = ProductionPortableArchiveStore()
  let appUpdateChecker = AppUpdateChecker()
  let storageInspector = LocalStorageInspector()
  let localEventOrganizer = LocalEventOrganizer()
  var historyWaveformTask: Task<Void, Never>?
  var historyPlaybackTask: Task<Void, Never>?
  var historyPlaybackControlTask: Task<Void, Never>?
  var historyPlaybackGeneration = UUID()
  var historyPlaybackSeekRequestID = UUID()
  var loadedPlaybackSessionID: SessionID? {
    didSet {
      // The idle rewrite (16 kHz, Opus) leaves a recording being played
      // alone; the player reads its chunk files as it goes.
      guard loadedPlaybackSessionID != oldValue else { return }
      publishAudioInUse()
    }
  }

  /// The recordings a rewrite must leave alone: the one loaded in the player
  /// and the one open in a record (its ranges are already in hand).
  func publishAudioInUse() {
    let inUse = Set([loadedPlaybackSessionID, history.selectedHistorySessionID].compactMap { $0 })
    let runtime = localRuntime
    Task { await runtime?.setAudioInUse(inUse) }
  }
  var loadedPlaybackTrackID = ""
  var historyPlaybackAssetRootURL: URL?
  var historyPlaybackTrackDescriptors: [String: CaptureTrackDescriptor] = [:]
  var historyPlaybackRangesByTrack: [String: [AudioRangeInput]] = [:]
  var historyPlaybackUIFixture: HistoryPlaybackUIFixture?
  var historyPlaybackFixturePersonUndoStack:
    [([SessionSpeakerSummary], [SpeakerOccurrenceSummary], [PersonSummary])] = []
  var eventReviewUIFixture: EventReviewUIFixture?
  var eventReviewUIFixtureUndoStack: [EventReviewUIFixtureState] = []
  var historyTranscriptEditSessionID: SessionID?
  var historyRefreshGenerationGate = HistoryRefreshGenerationGate()
  var attemptedLegacySourceAudioIndex: Set<SessionID> = []
  var legacySourceAudioIndexTask: Task<Void, Never>?
  var systemLifecycleObservers: [NSObjectProtocol] = []
  var systemInterruptionEvents:
    [SessionID: (id: TimelineEventID, startedAt: UInt64, revision: Revision)] = [:]

  lazy var recordingPanel = RecordingStatusPanelController(
    onOpenRecord: { [weak self] in self?.openFinishedDictationRecord() }
  )

  init(
    preview: Bool = false,
    modelSetupFixture: Bool = false,
    memoryRepository: GRDBDictationStore? = nil
  ) {
    fixtureMode =
      preview || modelSetupFixture
      || ProcessInfo.processInfo.arguments.contains("--ui-testing")
      || BestASRProcessEnvironment.isXCTestHost
    // Exercise memory actions against real temporary SQLite storage without
    // bootstrapping capture, permissions or inference in hosted tests.
    precondition(memoryRepository == nil || fixtureMode)
    repository = memoryRepository
    dictionary.repository = memoryRepository
    history.repository = memoryRepository
    // Every stored property has its value by now; the children can be
    // observed before any mode-specific path returns early.
    observeChildren()
    // V1 is intentionally Simplified-Chinese only.  Older development builds
    // exposed an English choice without shipping localized UI; normalize that
    // misleading preference instead of presenting a partially translated app.
    self.spoken.interfaceLanguageID = "zh-Hans"
    LocalPreferenceStore.defaults.set(
      "zh-Hans",
      forKey: "preferences.interface-language"
    )
    if !fixtureMode {
      // 登录时打开 follows the App when it moved (bestASR.app → Mindloom.app):
      // registered again from this bundle, once (switch preparation 10-6).
      launchAtLoginEnabled =
        LoginItemRepair.repair(
          service: MainAppLoginItem(), defaults: LocalPreferenceStore.defaults,
          currentPath: Bundle.main.bundleURL.path) == .enabled
      models.modelLicenseAccepted = LocalModelLicenseReceipts.accepted(
        key: Self.speechLicenseReceiptKey,
        receipt: Self.speechLicenseReceipt
      )
      models.polishModelLicenseAccepted = LocalModelLicenseReceipts.accepted(
        key: Self.polishLicenseReceiptKey,
        receipt: Self.polishLicenseReceipt
      )
      models.speakerModelLicenseAccepted = LocalModelLicenseReceipts.accepted(
        key: Self.speakerLicenseReceiptKey,
        receipt: Self.speakerLicenseReceipt
      )
      models.meaningModelLicenseAccepted = LocalModelLicenseReceipts.accepted(
        key: Self.meaningLicenseReceiptKey,
        receipt: Self.meaningLicenseReceipt
      )
      if systemAudioMicrophoneOverrides.isEmpty,
        LocalPreferenceStore.defaults.object(
          forKey: "preferences.system-audio-include-microphone"
        ) != nil
      {
        systemAudioMicrophoneOverrides[capture.selectedSystemAudioSourceID] =
          history.includeMicrophoneInSystemRecording
        persistSystemAudioMicrophoneOverrides()
      }
    }
    if fixtureMode {
      let onboardingFixture = ProcessInfo.processInfo.arguments.contains(
        "--onboarding-ui-testing"
      )
      let onboardingExistingHistoryFixture =
        ProcessInfo.processInfo.arguments.contains(
          "--onboarding-existing-history-ui-testing"
        )
      fixtureActor = DictationSessionActor()
      statusMessage = "本机口述测试环境已就绪"
      capture.microphonePermission = .granted
      onboarding.accessibilityPermission = .granted
      capture.systemAudioPermission = .granted
      models.modelRuntimeReady = true
      enhancedFinalASRReady = true
      models.modelDiscoveryComplete = true
      models.modelReadinessMessage = "本机语音识别测试模型已就绪"
      polishRuntimeReady = true
      polishReadinessMessage = "本机文字整理测试模型已就绪"
      people.speakerRuntimeReady = true
      people.speakerReadinessMessage = "本机多人识别测试模型已就绪"
      history.historyItems = Self.fixtureHistoryItems()
      history.homeRecentHistoryItems = Array(history.historyItems.prefix(3))
      usage.usage = DictationUsageSummary.make(
        history.historyItems.filter { $0.inputMode == .dictation }.map {
          DictationActivityRecord(
            createdAt: $0.createdAt, speechNanoseconds: $0.durationNanoseconds ?? 0,
            text: $0.preferredText ?? "")
        })
      usage.usageStatistics = LocalHistoryUsageStatistics(
        sessionCount: history.historyItems.count,
        recordedDurationNanoseconds: 5_450_000_000_000,
        currentTextCharacterCount: 12_480,
        activeDayCount: 3
      )
      history.historyStatusMessage = "4 条本机测试记录"
      if ProcessInfo.processInfo.arguments.contains(
        "--history-playback-ui-testing"
      ) {
        do {
          let fixture = try Self.makeHistoryPlaybackUIFixture()
          historyPlaybackUIFixture = fixture
          people.personSummaries = Self.browsablePersonSummaries(fixture.people)
          people.personReviewCandidates = Self.personReviewCandidates(from: fixture)
        } catch {
          history.historyStatusMessage = "无法创建本地播放测试原音"
        }
      }
      if ProcessInfo.processInfo.arguments.contains(
        "--event-review-ui-testing"
      ) {
        do {
          if historyPlaybackUIFixture == nil {
            historyPlaybackUIFixture = try Self.makeHistoryPlaybackUIFixture()
          }
          guard let playbackFixture = historyPlaybackUIFixture else {
            throw BestASRAppStorageError.externalCacheUnavailable
          }
          let fixture = try Self.makeEventReviewUIFixture(
            playbackFixture: playbackFixture,
            historyItems: history.historyItems
          )
          eventReviewUIFixture = fixture
          events.summaries = [fixture.initialSummary]
          events.candidates = [fixture.candidate]
          history.eventAvailableHistoryItems = history.historyItems
          events.eventStatusMessage = "1 件事 · 1 条待确认；先听原音再决定"
        } catch {
          events.eventStatusMessage = "无法创建本地测试数据"
        }
      }
      if ProcessInfo.processInfo.arguments.contains(
        "--history-origin-ui-testing"
      ) {
        history.navigationOrigin = HistoryNavigationOrigin(
          kind: .person,
          title: "测试人物"
        )
        history.selectedHistorySessionID = history.historyItems.first?.sessionID
        history.detailPresented = true
        requestedNavigationSectionID = "history"
      }
      // Shows the 指令 answer panel over an empty window, so its layout can
      // be seen and tested without speaking into a microphone.
      if ProcessInfo.processInfo.arguments.contains("--answer-panel-ui-testing") {
        spokenAnswerPanel.present(
          answer: """
            We'll go over this plan together next week.

            The wording reads oddly in places — the model is small, and it \
            tends to carry the original sentence order straight across \
            instead of saying it the way an English speaker would.
            """,
          question: "翻译成英语"
        )
      }
      if ProcessInfo.processInfo.arguments.contains("--dictionary-ui-testing") {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        dictionary.entries = [
          ("bestASR", ["百思特"], true), ("Claude Code", [], true), ("Typeless", [], true),
          ("张明", ["章明"], true), ("SwiftUI", [], true), ("MLX", [], false),
        ].compactMap { term, spoken, enabled in
          try? DictionaryEntry(
            revision: try Revision(1), canonicalForm: term, spokenForms: spoken, enabled: enabled,
            createdAt: now, updatedAt: now)
        }
        dictionary.dictionaryStatusMessage = "\(dictionary.entries.count) 个本地词典条目"
        requestedNavigationSectionID = "dictionary"
      }
      if onboardingFixture {
        capture.microphonePermission = .notDetermined
        onboarding.accessibilityPermission = .notDetermined
        capture.systemAudioPermission = .notDetermined
        models.modelRuntimeReady = false
        models.modelDiscoveryComplete = true
        polishRuntimeReady = false
        people.speakerRuntimeReady = false
        models.modelReadinessMessage = "需要准备本机语音识别"
        polishReadinessMessage = "需要准备本机文字整理"
        people.speakerReadinessMessage = "需要准备本机多人识别"
        if !onboardingExistingHistoryFixture {
          history.historyItems = []
          history.homeRecentHistoryItems = []
          usage.usageStatistics = LocalHistoryUsageStatistics()
          usage.usage = DictationUsageSummary()
          history.historyStatusMessage = "尚无记录"
        }
      } else if modelSetupFixture
        || ProcessInfo.processInfo.arguments.contains("--model-setup-ui-testing")
      {
        models.modelRuntimeReady = false
        models.modelDiscoveryComplete = true
        polishRuntimeReady = false
        people.speakerRuntimeReady = false
        models.modelReadinessMessage = "需要准备推荐的本机模型"
        polishReadinessMessage = "需要准备推荐的本机模型"
        people.speakerReadinessMessage = "需要准备推荐的本机模型"
      }
      if ProcessInfo.processInfo.arguments.contains(
        "--capture-processing-ui-testing"
      ),
        let processingItem = history.historyItems.first(where: {
          $0.status == .processing
        })
      {
        snapshot = DictationSessionSnapshot(
          sessionID: processingItem.sessionID,
          revision: processingItem.revision,
          phase: .recognizing
        )
        liveTranscriptText = "已保存的实时草稿"
        liveTranscriptStatus = "采集已经结束；正在运行本地识别"
        statusMessage = "原音已保存，正在本机识别…"
      } else if ProcessInfo.processInfo.arguments.contains(
        "--capture-handoff-ui-testing"
      ),
        let completedItem = history.historyItems.first(where: {
          $0.status == .completed
        })
      {
        capture.captureWorkspaceHandoff = CaptureWorkspaceHandoff(
          sessionID: completedItem.sessionID,
          inputMode: completedItem.inputMode,
          state: .completed,
          title: "口述已完成",
          detail: "最终文字与原音均已保存在本机",
          sourceDisplayName: completedItem.sourceDisplayName,
          sourceAudioRetained: completedItem.sourceAudioRetained
        )
      }
      return
    }
    do {
      let root = try Self.applicationDataRoot()
      let cacheRoot = try Self.applicationCacheRoot()
      // Waits while another program has the database busy instead of failing
      // the startup (REHEARSAL.md §8), and is closed cleanly on quit.
      let durableRepository = try GRDBDictationStore.openWaitingWhileBusy(
        databaseURL: root.appendingPathComponent("history.sqlite")
      )
      LibraryQuit.store = durableRepository
      // Measuring is never a reason not to start: without the table the
      // dictation still runs, its numbers are just not kept.
      dictationMetricsStore = try? DictationMetricsStore(
        databaseURL: DictationMetricsStore.databaseURL(dataRoot: root))
      let durableJournal = try ProductionAudioJournal(
        assetRootURL: root.appendingPathComponent("assets", isDirectory: true),
        sourceIndex: durableRepository
      )
      repository = durableRepository
      configureRemoteOrganizer(repository: durableRepository, dataRoot: root)
      configureIntake(repository: durableRepository, assetRoot: durableJournal.assetRootURL)
      configureAgentAccess(repository: durableRepository, dataRoot: root)
      configureEntries(dataRoot: root)
      configureWebLookup(dataRoot: root)
      dictionary.repository = durableRepository
      history.repository = durableRepository
      journal = durableJournal
      refreshDiskSpaceDecisionInBackground()
      // Once the main window can show the notice.
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(10))
        self?.checkLowDisk()
      }
      importedMediaDecoder = AVFoundationImportedMediaDecoder()
      importedMediaFileStore = LocalImportedMediaFileStore(
        assetRoot: durableJournal.assetRootURL
      )
      let permissions = MacDictationPermissionService()
      permissionService = permissions
      let targetReader = TargetReader()
      self.targetReader = targetReader
      let deliveryPort = DeliveryInsertionPort(
        reader: targetReader,
        deliverer: TextDeliverer(),
        ownApplicationAllowed: { [weak self] in
          MainActor.assumeIsolated { self?.onboardingPracticeTargetArmed ?? false }
        },
        // A dictation that ends in one of Mindloom's own fields (the search
        // field, a name) is written into it directly (收1-11).
        ownTextInput: { AppKitOwnTextInput.focused() }
      )
      insertionService = deliveryPort
      let runtime = try LocalDictationRuntime(
        applicationRoot: root,
        cacheRoot: cacheRoot,
        journal: durableJournal,
        repository: durableRepository,
        insertion: deliveryPort,
        localSelfPersonID: localSelfPersonID
      )
      localRuntime = runtime
      // The runtime asks, once per dictation, what to deliver; the mode and
      // the highlighted text it acts on are owned here.
      Task { [weak self] in
        await runtime.setDeliveryTransform { [weak self] sessionID, text in
          guard let model = self else { return .asIs }
          return await model.deliveryForDictation(sessionID: sessionID, text: text)
        }
      }
      let nativeBackend = CarbonHotkeyBackend()
      nativeBackend.setPreflightHandler { [weak self] identifier in
        self?.preflightHotkeyTarget(identifier: identifier)
      }
      let nativeProvider = NativeGlobalHotkeyProvider(backend: nativeBackend)
      hotkeyProvider = nativeProvider
      hotkeyController = GlobalHotkeyConfigurationController(
        provider: nativeProvider,
        store: UserDefaultsHotkeyConfigurationStore()
      )
      inspectSetupCompatibility(dataRoot: root)
      beginSystemLifecycleMonitoring()
      FnGuard.shared.attach(self, applyNow: false)
      Task { [weak self] in await self?.bootstrap() }
    } catch {
      let failure = Self.startupFailureDescription(error)
      startupFailureMessage = failure
      statusMessage = failure
      let nsError = error as NSError
      dictationAppLogger.error(
        "local startup failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
      )
    }
  }

  nonisolated static func startupFailureDescription(_ error: Error) -> String {
    if let storageError = error as? BestASRAppStorageError {
      return storageError.localizedDescription
    }
    if let launchError = error as? LibraryLaunchError {
      return MindloomLaunch.refusalMessage(launchError)
    }
    if error is LibraryMigrationBackupError {
      return
        "资料库需要升级到新版本，但升级前的备份未能完成，因此未升级。请释放磁盘空间后重新打开 Mindloom。"
    }
    let nsError = error as NSError
    return
      "本机服务启动失败（\(nsError.domain)#\(nsError.code)）；历史记录和原始音频没有被删除或覆盖。请重新打开 App；仍失败时可在设置中导出不含私人内容的诊断。"
  }

  func beginSystemLifecycleMonitoring() {
    guard systemLifecycleObservers.isEmpty else { return }
    // Dictations finished while another application was in front leave the
    // history on screen stale; it is read back when the user comes here.
    systemLifecycleObservers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.refreshHistoryIfStale() }
      }
    )
    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.willSleepNotification,
      NSWorkspace.sessionDidResignActiveNotification,
    ] {
      systemLifecycleObservers.append(
        center.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in
          Task { @MainActor [weak self] in
            await self?.pauseActiveWorkForSystemTransition()
          }
        }
      )
    }
    for name in [
      NSWorkspace.didWakeNotification,
      NSWorkspace.sessionDidBecomeActiveNotification,
    ] {
      systemLifecycleObservers.append(
        center.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in
          Task { @MainActor [weak self] in
            await self?.handleSystemResume()
          }
        }
      )
    }
  }

  func pauseActiveWorkForSystemTransition() async {
    // The organizing device locks its store while this Mac sleeps (privacy
    // review F1); the link reconnects and unlocks again on wake.
    await remoteOrganizer?.suspendForSleep()
    if snapshot.phase == .recording, let coordinator {
      stopDictationLifecycleMonitoring()
      snapshot = (try? await coordinator.pause()) ?? snapshot
      await recordSystemInterruption(for: snapshot)
      statusMessage =
        "Mac 即将睡眠或锁定；口述已自动暂停，已提交音频完整保留。解锁后由你决定继续或结束"
      liveTranscriptStatus = "系统暂停前的实时文字已保留"
      renderRecordingPanel()
    }
    if capture.roomSnapshot.phase == .recording, let roomCoordinator {
      stopRoomLifecycleMonitoring()
      capture.roomSnapshot = (try? await roomCoordinator.pause()) ?? capture.roomSnapshot
      await recordSystemInterruption(for: capture.roomSnapshot)
      capture.roomStatusMessage =
        "Mac 即将睡眠或锁定；线下录音已自动暂停，原音和逐字稿均已保留"
    }
    if capture.systemAudioSnapshot.phase == .recording,
      let systemAudioCoordinator
    {
      stopSystemAudioLifecycleMonitoring()
      capture.systemAudioSnapshot =
        (try? await systemAudioCoordinator.pause()) ?? capture.systemAudioSnapshot
      await recordSystemInterruption(for: capture.systemAudioSnapshot)
      capture.systemAudioStatusMessage =
        "Mac 即将睡眠或锁定；电脑内录已自动暂停，所有独立音轨均已保留"
    }
    if capture.importInProgress, capture.importPauseControlAvailable, !capture.importPaused {
      importPauseIntent.setPaused(true)
      capture.importPaused = true
      if let paused = await synchronizeImportPauseIntent(),
        paused.phase == .paused
      {
        await recordSystemInterruption(for: paused)
        capture.importStatusMessage = "Mac 已锁定或睡眠；导入进度和原始文件均已保留"
      }
    }
  }

  func handleSystemResume() async {
    remoteOrganizer?.resumeAfterSleep()
    await readPermissionStates()
    await closeSystemInterruptionEvents()
    if snapshot.phase == .paused {
      statusMessage =
        capture.microphonePermission == .granted
        ? "Mac 已唤醒；口述保持暂停，可继续或结束"
        : "Mac 已唤醒，但麦克风权限当前不可用；音频仍已保留"
    }
    if capture.roomSnapshot.phase == .paused {
      capture.roomStatusMessage =
        capture.microphonePermission == .granted
        ? "Mac 已唤醒；线下录音保持暂停，可继续或结束"
        : "Mac 已唤醒，但麦克风权限当前不可用；原音仍已保留"
    }
    if capture.systemAudioSnapshot.phase == .paused {
      capture.systemAudioStatusMessage =
        "Mac 已唤醒；电脑内录保持暂停，请确认来源和权限后继续或结束"
    }
    if capture.importInProgress, capture.importPaused {
      capture.importStatusMessage = "Mac 已唤醒；文件导入保持暂停，可继续或取消"
    }
  }



  var menuBarSymbol: String {
    if capture.importInProgress { return capture.importPaused ? "pause.circle.fill" : "arrow.down.circle.fill" }
    if !hasActiveCapture, let handoff = capture.captureWorkspaceHandoff {
      return switch handoff.state {
      case .processing: "ellipsis.circle"
      case .completed: "checkmark.circle.fill"
      case .needsAttention: "exclamationmark.circle.fill"
      }
    }
    return switch primaryActivePhase {
    case .recording: "waveform.circle.fill"
    case .paused: "pause.circle.fill"
    case .finalizing, .recognizing, .polishing, .inserting: "ellipsis.circle"
    case .failedRecoverable: "exclamationmark.circle"
    default: "waveform.circle"
    }
  }

  var menuBarStatusMessage: String {
    if capture.roomSnapshot.phase.isActive { return capture.roomStatusMessage }
    if capture.systemAudioSnapshot.phase.isActive { return capture.systemAudioStatusMessage }
    if capture.importInProgress { return capture.importStatusMessage }
    if let handoff = capture.captureWorkspaceHandoff { return handoff.title }
    return statusMessage
  }

  var primaryActivePhase: DictationPhase {
    if capture.roomSnapshot.phase.isActive { return capture.roomSnapshot.phase }
    if capture.systemAudioSnapshot.phase.isActive { return capture.systemAudioSnapshot.phase }
    return snapshot.phase
  }

  func requestNavigation(to sectionID: String) {
    if sectionID == "history" { history.detailPresented = false }
    requestedNavigationSectionID = sectionID
  }

  func dismissCaptureWorkspaceHandoff() {
    capture.captureWorkspaceHandoff = nil
  }

  func clearCaptureWorkspaceHandoff(afterDeleting sessionID: SessionID) {
    guard capture.captureWorkspaceHandoff?.sessionID == sessionID else { return }
    capture.captureWorkspaceHandoff = nil
  }


  func refreshDiskSpaceDecisionInBackground() {
    guard let journal else { return }
    Task { [weak self] in
      guard let decision = try? await journal.diskSpaceDecision() else { return }
      self?.diskSpaceDecisionCache = (decision, ContinuousClock.now)
    }
  }

  struct EarlyMicrophoneStart {
    let sessionID: SessionID
    let deviceUID: String
    let capture: AVAudioEngineMicrophoneCapture
    let start: Task<Void, Error>
  }







  /// macOS "Press 🌐 key to" (com.apple.HIToolbox AppleFnUsageType): 0 is
  /// "Do Nothing". Unset or any other value makes every Fn press also switch
  /// input source, show emoji, or start system dictation.
  nonisolated static func globeKeyTriggersSystemAction(usageType: Int?) -> Bool {
    usageType != 0
  }

  func refreshGlobeKeyConflict() {
    let domain = "com.apple.HIToolbox" as CFString
    CFPreferencesAppSynchronize(domain)
    let usage = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) as? Int
    hotkeys.globeKeyConflictsWithStartShortcut =
      hotkeys.startEndHotkeyBinding.isFunctionAlone
      && Self.globeKeyTriggersSystemAction(usageType: usage)
  }



  func openCaptureWorkspaceHandoff() {
    guard let handoff = capture.captureWorkspaceHandoff else { return }
    let availableItems = history.historyItems + history.homeRecentHistoryItems
    if let item = availableItems.first(where: {
      $0.sessionID == handoff.sessionID
    }) {
      revealLinkedHistoryItem(item)
      capture.captureWorkspaceHandoff = nil
      openHistoryItem(item)
      return
    }
    guard !fixtureMode, let repository else { return }
    Task { [weak self] in
      guard let self else { return }
      do {
        let recentItems = try await repository.loadHistory(limit: 100)
        guard capture.captureWorkspaceHandoff?.sessionID == handoff.sessionID else {
          return
        }
        guard
          let item = recentItems.first(where: {
            $0.sessionID == handoff.sessionID
          })
        else {
          capture.captureWorkspaceHandoff = nil
          statusMessage = "这条记录已不存在；可以开始新的记录"
          history.historyStatusMessage = "这条记录已被删除或移出资料库"
          return
        }
        revealLinkedHistoryItem(item)
        capture.captureWorkspaceHandoff = nil
        openHistoryItem(item)
      } catch {
        guard capture.captureWorkspaceHandoff?.sessionID == handoff.sessionID else {
          return
        }
        capture.captureWorkspaceHandoff = CaptureWorkspaceHandoff(
          sessionID: handoff.sessionID,
          inputMode: handoff.inputMode,
          state: .needsAttention,
          title: handoff.title,
          detail: "这条记录仍保存在本机，但资料库暂时无法打开；请稍后重试",
          sourceDisplayName: handoff.sourceDisplayName,
          sourceAudioRetained: handoff.sourceAudioRetained
        )
      }
    }
  }

  var startEndTitle: String {
    if [.preparing, .recording, .paused].contains(snapshot.phase) {
      return "结束口述"
    }
    return models.modelRuntimeReady ? "开始口述" : "开始录音（待转写）"
  }


  /// A new dictation may start now: either nothing is running, or the one on
  /// screen has already released the microphone and sealed its audio and is
  /// only being recognized and inserted in the background.
  var canStartDictationNow: Bool {
    Self.canStartDictation(
      phase: snapshot.phase,
      sessionID: snapshot.sessionID,
      finalizingInBackground: finalizingSessionIDs
    )
  }



  nonisolated static func presentationSnapshot(
    from snapshot: DictationSessionSnapshot,
    phase: DictationPhase,
    marker: DictationTimelineMarkerKind? = nil,
    now: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) -> DictationSessionSnapshot {
    var timeline = snapshot.timeline
    if let marker,
      timeline.last?.kind != marker
    {
      timeline.append(
        DictationTimelineMarker(
          kind: marker,
          monotonicNanoseconds: now
        )
      )
    }
    return DictationSessionSnapshot(
      sessionID: snapshot.sessionID,
      revision: max(1, snapshot.revision),
      phase: phase,
      target: snapshot.target,
      timeline: timeline,
      transcript: snapshot.transcript,
      polish: snapshot.polish,
      insertion: phase == .completed ? snapshot.insertion : nil,
      failure: phase == .failedRecoverable ? snapshot.failure : nil
    )
  }

  nonisolated static func preparingCaptureSnapshot(
    sessionID: SessionID,
    now: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) -> DictationSessionSnapshot {
    DictationSessionSnapshot(
      sessionID: sessionID,
      revision: 1,
      phase: .preparing,
      timeline: [
        DictationTimelineMarker(
          kind: .started,
          monotonicNanoseconds: now
        )
      ]
    )
  }

  var pauseResumeTitle: String { snapshot.phase == .paused ? "继续" : "暂停" }
  var canPauseOrResume: Bool {
    [.preparing, .recording, .paused].contains(snapshot.phase)
  }
  var canCancel: Bool {
    [.preparing, .recording, .paused].contains(snapshot.phase)
  }

  var startEndShortcutTitle: String {
    BestASRHotkeyFormatter.title(hotkeys.startEndHotkeyBinding)
  }

  var permissionApplicationIdentity: String {
    let bundleName =
      Bundle.main.object(
        forInfoDictionaryKey: "CFBundleDisplayName"
      ) as? String
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
      ?? MindloomIdentity.displayName
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? MindloomIdentity.bundleID
    let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
      .replacingOccurrences(
        of: FileManager.default.homeDirectoryForCurrentUser.path,
        with: "~",
        options: [.anchored]
      )
    return "当前权限对象：\(bundleName)（\(bundleIdentifier)）· \(path)"
  }

  var hotkeySelectionIsSafe: Bool {
    !hotkeys.startEndHotkeyBinding.modifiers.isEmpty
  }




  var isReadyForDictation: Bool {
    Self.canRecord(microphonePermission: capture.microphonePermission)
      && models.modelRuntimeReady
  }

  /// Capture remains available before inference is ready so source audio is
  /// never sacrificed to model installation or recovery. The UI distinguishes
  /// this durable recording path from a ready-to-insert dictation path.
  var canStartDictationCapture: Bool {
    Self.canRecord(microphonePermission: capture.microphonePermission)
  }

  var needsModelSetup: Bool {
    models.modelDiscoveryComplete
      && (!models.modelRuntimeReady || !enhancedFinalASRReady || !polishRuntimeReady
        || !people.speakerRuntimeReady)
  }

  var recommendedComponentLicensesAccepted: Bool {
    models.modelLicenseAccepted
      && models.polishModelLicenseAccepted
      && models.speakerModelLicenseAccepted
  }


  var canInstallRecommendedModels: Bool {
    recommendedComponentLicensesAccepted && onboarding.setupHardwareSupported
  }





  var modelReadinessHeadline: String {
    if models.modelRuntimeReady && !enhancedFinalASRReady { return "基础识别可用，可更新" }
    return Self.modelReadinessHeadline(
      ready: models.modelRuntimeReady,
      message: models.modelReadinessMessage
    )
  }

  var localModelComponents: [LocalModelComponentPresentation] {
    [
      LocalModelComponentPresentation(
        component: .speech,
        revision: "automatic-speech-pack-v3-aligned",
        sizeBytes: Self.recommendedSpeechBytes,
        ready: models.modelRuntimeReady && enhancedFinalASRReady
      ),
      LocalModelComponentPresentation(
        component: .speaker,
        revision: FluidSpeakerPinnedArtifact.sourceRevision,
        sizeBytes: 21_602_781,
        ready: people.speakerRuntimeReady
      ),
      LocalModelComponentPresentation(
        component: .localText,
        revision: MLXLocalTextArtifact.qwen3Selected.sourceRevision,
        sizeBytes: MLXLocalTextArtifact.qwen3Selected.totalSizeBytes,
        ready: polishRuntimeReady
      ),
      LocalModelComponentPresentation(
        component: .meaning,
        revision: MLXMeaningArtifact.selected.sourceRevision,
        sizeBytes: MLXMeaningArtifact.selected.totalSizeBytes,
        ready: meaningSearchReady
      ),
    ]
  }

  /// SenseVoice (live captions) 239,918,735 bytes, the recognizer and the
  /// aligner; Paraformer and Parakeet left the download on 2026-10-06
  /// (`LocalDictationRuntime.requiredSpeechArtifactIDs`).
  nonisolated static let recommendedSpeechBytes: UInt64 =
    239_918_735 + QwenASRPinnedArtifact.totalSizeBytes
    + QwenAlignmentPinnedArtifact.totalSizeBytes
  nonisolated static let recommendedTotalBytes: UInt64 =
    recommendedSpeechBytes + 21_602_781 + 930_271_884

  var localDataLocation: String {
    (try? Self.applicationDataRoot().path(percentEncoded: false))
      ?? "本机应用支持目录暂不可用"
  }

  var appTextPolicyChoices: [AppTextPolicyChoice] {
    var choices: [String: AppTextPolicyChoice] = [:]
    for source in capture.systemAudioSources {
      guard let bundleIdentifier = source.bundleID, !bundleIdentifier.isEmpty
      else { continue }
      choices[bundleIdentifier] = AppTextPolicyChoice(
        bundleIdentifier: bundleIdentifier,
        displayName: source.displayName
      )
    }
    for application in NSWorkspace.shared.runningApplications {
      guard application.activationPolicy == .regular,
        let bundleIdentifier = application.bundleIdentifier,
        !bundleIdentifier.isEmpty,
        bundleIdentifier != Bundle.main.bundleIdentifier
      else { continue }
      let displayName = application.localizedName?.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      let resolvedDisplayName =
        displayName.flatMap { value in
          value.isEmpty ? nil : value
        } ?? bundleIdentifier
      choices[bundleIdentifier] = AppTextPolicyChoice(
        bundleIdentifier: bundleIdentifier,
        displayName: resolvedDisplayName
      )
    }
    return choices.values.sorted {
      $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
    }
  }

  func selectAppTextPolicyChoice(_ bundleIdentifier: String) {
    guard !bundleIdentifier.isEmpty,
      let choice = appTextPolicyChoices.first(where: {
        $0.bundleIdentifier == bundleIdentifier
      })
    else { return }
    appPolicyBundleIDDraft = choice.bundleIdentifier
    appPolicyDisplayNameDraft = choice.displayName
  }

  func revealLocalDataFolder() {
    guard let root = try? Self.applicationDataRoot() else {
      storageStatusMessage = "本机数据目录暂不可用"
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([root])
  }







  func setLaunchAtLoginEnabled(_ enabled: Bool) {
    guard !fixtureMode else {
      launchAtLoginEnabled = enabled
      return
    }
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
      LoginItemRepair.recordChoice(
        on: enabled, status: MainAppLoginItem().status, defaults: LocalPreferenceStore.defaults,
        currentPath: Bundle.main.bundleURL.path)
      preferencesStatusMessage =
        launchAtLoginEnabled
        ? "已设置为登录后自动启动"
        : "已关闭登录后自动启动"
    } catch {
      launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
      preferencesStatusMessage =
        "未能更改登录时启动设置。请确认 Mindloom 已安装在“应用程序”文件夹中。"
    }
  }

  /// Model polish is off by default since 2026-09-19: on the user's verified
  /// transcripts it made text worse (4.1% → 4.7% character errors) while
  /// keeping a general text model resident. Earlier installs are switched off
  /// once; the Settings toggle still turns it back on.
  nonisolated static func initialDefaultPolishEnabled(
    defaults: UserDefaults = .standard
  ) -> Bool {
    let migration = "preferences.default-polish-off-migration-v1"
    if !defaults.bool(forKey: migration) {
      defaults.set(false, forKey: "preferences.default-polish-enabled")
      defaults.set(true, forKey: migration)
    }
    return defaults.object(forKey: "preferences.default-polish-enabled") as? Bool ?? false
  }

  func setDefaultPolishEnabled(_ enabled: Bool) {
    defaultPolishEnabled = enabled
    LocalPreferenceStore.defaults.set(
      enabled,
      forKey: "preferences.default-polish-enabled"
    )
    applyRuntimePreferences()
  }










  func saveAppTextPolicy() {
    let bundleID =
      appPolicyBundleIDDraft
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !bundleID.isEmpty, bundleID.count <= 255,
      bundleID.range(
        of: "^[A-Za-z0-9.-]+$",
        options: .regularExpression
      ) != nil
    else {
      preferencesStatusMessage = "请输入有效的 App Bundle ID，例如 com.apple.TextEdit"
      return
    }
    let displayName =
      appPolicyDisplayNameDraft
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let policy = AppTextPolicy(
      bundleIdentifier: bundleID,
      displayName: displayName.isEmpty ? bundleID : displayName,
      polishEnabled: appPolicyPolishEnabled,
      formattingStyle: appPolicyFormattingStyle
    )
    appTextPolicies.removeAll { $0.bundleIdentifier == bundleID }
    appTextPolicies.append(policy)
    appTextPolicies.sort {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
        == .orderedAscending
    }
    persistAppTextPolicies()
    appPolicyBundleIDDraft = ""
    appPolicyDisplayNameDraft = ""
    appPolicyPolishEnabled = true
    appPolicyFormattingStyle = .automatic
    preferencesStatusMessage = "App 专属文字策略已保存"
  }

  func deleteAppTextPolicy(_ policy: AppTextPolicy) {
    appTextPolicies.removeAll { $0.bundleIdentifier == policy.bundleIdentifier }
    persistAppTextPolicies()
    preferencesStatusMessage = "App 专属文字策略已删除"
  }


  func clearRebuildableCaches() {
    guard !hasActiveCapture, !models.recommendedModelInstallInProgress,
      !export.archiveOperationInProgress
    else {
      storageStatusMessage = "请先结束录音、导入、模型下载或归档操作"
      return
    }
    storageStatusMessage = "正在清理可重新下载的缓存…"
    Task { [weak self] in
      guard let self else { return }
      do {
        let cacheRoot = try Self.applicationCacheRoot()
        let freedBytes = try await storageInspector.clearRebuildableCache(
          cacheRoot: cacheRoot
        )
        storageStatusMessage =
          "已释放 \(Self.byteCountTitle(freedBytes))；资料库、原音、词典、人物和已安装模型未受影响"
        refreshStorageUsage()
      } catch {
        storageStatusMessage = "缓存清理失败；没有删除用户数据"
      }
    }
  }


  static func storageModeTitle(_ mode: SessionInputMode) -> String {
    switch mode {
    case .dictation: "口述"
    case .roomMicrophone: "线下录音"
    case .systemAudio: "电脑内录"
    case .importedMedia: "文件导入"
    case .userItem: "添加的内容"
    }
  }

  func refreshDiagnosticsPreview() {
    let appVersion =
      Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
      ) as? String ?? "development"
    diagnosticsPreview = [
      "\(MindloomIdentity.displayName) \(appVersion)",
      "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
      "本机服务：\(startupFailureMessage.isEmpty ? "已启动" : startupFailureMessage)",
      "麦克风权限：\(Self.diagnosticPermissionTitle(capture.microphonePermission))",
      "设备控制和数据访问权限：\(Self.diagnosticPermissionTitle(onboarding.accessibilityPermission))",
      "系统音频权限：\(Self.diagnosticPermissionTitle(capture.systemAudioPermission))",
      "语音识别模型：\(models.modelRuntimeReady ? "已就绪" : "未就绪")",
      "多人识别模型：\(people.speakerRuntimeReady ? "已就绪" : "未就绪")",
      "本地文字模型：\(polishRuntimeReady ? "已就绪" : "未就绪")",
      "本机历史记录：\(usage.usageStatistics.sessionCount) 条",
      "可恢复记录：\(recoveryItemCount) 条",
      "受管理的储存空间：\(Self.byteCountTitle(storageSnapshot.totalManagedBytes))",
      "可用空间：\(Self.byteCountTitle(UInt64(max(0, storageSnapshot.availableBytes))))",
      "产品遥测：关闭",
      "远程崩溃上报：关闭",
      "包含私人内容：否",
    ].joined(separator: "\n")
  }


  func persistAppTextPolicies() {
    if let data = try? JSONEncoder().encode(appTextPolicies) {
      LocalPreferenceStore.defaults.set(
        data,
        forKey: "preferences.app-text-policies.v1"
      )
    }
    applyRuntimePreferences()
  }


  static func byteCountTitle(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(
      fromByteCount: Int64(clamping: bytes),
      countStyle: .file
    )
  }


  var isEditingDictionaryEntry: Bool { dictionary.editingDictionaryEntryID != nil }


  func startOrEnd() {
    startOrEnd(
      preCapturedTarget: nil,
      captureExternalTargetWhenMissing: false
    )
  }


  func startOrEnd(
    preCapturedTarget: DictationTargetSnapshot?,
    captureExternalTargetWhenMissing: Bool
  ) {
    if lifecycleCommands.inFlightMode == .dictation {
      let queued = Self.inFlightDictationAction(inFlight: lifecycleCommands.inFlightAction)
      _ = lifecycleCommands.queueIfInFlight(queued, for: .dictation)
      liveTranscriptStatus =
        queued == .end ? "当前操作完成后立即结束这次口述" : "上一段正在收尾，马上开始新的一段"
      statusMessage = liveTranscriptStatus
      renderRecordingPanel()
      return
    }
    guard [.recording, .paused].contains(snapshot.phase) || canStartDictationNow
    else { return }
    let ending = [.recording, .paused].contains(snapshot.phase)
    if ending {
      scheduleCorrectionSettle()
      checkLowDisk()
    }
    if !ending {
      // Cleared here, before the command is queued, rather than inside it.
      // The chord that chooses 翻译 or 指令 arrives milliseconds after the
      // key press and the queued start runs later still, so clearing it in
      // there threw away the mode the user had just chosen.
      spokenModePlan = nil
      dictationMode = .dictate
      spoken.activeTranslationLanguage =
        spoken.translationTargetLanguageNames.first ?? Self.translationLanguageNames[0]
      spokenAnswerPanel.dismiss()
      // The last take's HUD facts are not this one's.
      deliveredDictationText = nil
      untranslatedDictation = nil
      // Starting the next dictation ends the watch on the last one: what the
      // user changed in it by now is what they meant (收1-8).
      settleFieldCorrections()
    }
    performLifecycleCommand(
      mode: .dictation,
      intent: ending ? .end : .start
    ) { [weak self] in
      guard let self else { return }
      if [.recording, .paused].contains(snapshot.phase) {
        await end()
      } else if canStartDictationNow {
        // Only a dictation begun from this window is watched in this window.
        // `captureExternalTargetWhenMissing` is exactly that distinction: it
        // is true for the hotkey and the menu bar, which aim at another app.
        dictationStartedInApp = !captureExternalTargetWhenMissing
        await start(
          preCapturedTarget: preCapturedTarget,
          captureExternalTargetWhenMissing: captureExternalTargetWhenMissing
        )
      }
    }
  }

  var roomCanPauseOrResume: Bool {
    [.preparing, .recording, .paused].contains(capture.roomSnapshot.phase)
  }

  var roomCanCancel: Bool {
    [.preparing, .recording, .paused].contains(capture.roomSnapshot.phase)
  }







  var systemAudioCanPauseOrResume: Bool {
    [.preparing, .recording, .paused].contains(capture.systemAudioSnapshot.phase)
  }

  var systemAudioCanCancel: Bool {
    [.preparing, .recording, .paused].contains(capture.systemAudioSnapshot.phase)
  }


  var runningSystemAudioSources: [SystemAudioSource] {
    selectableSystemAudioSources.filter(\.isRunningOutput)
  }

  var recentSystemAudioSources: [SystemAudioSource] {
    recentSystemAudioSourceIDs.compactMap { identifier in
      selectableSystemAudioSources.first(where: {
        $0.id == identifier && !$0.isRunningOutput
      })
    }
  }

  var otherSystemAudioSources: [SystemAudioSource] {
    let recent = Set(recentSystemAudioSources.map(\.id))
    return selectableSystemAudioSources.filter {
      !$0.isRunningOutput && !recent.contains($0.id)
    }
  }

  var selectableSystemAudioSources: [SystemAudioSource] {
    Self.selectableAudioSources(capture.systemAudioSources)
  }

  /// The sources a person would pick: running Apps (and bundle-less players
  /// while they play), not background services.
  static func selectableAudioSources(_ sources: [SystemAudioSource]) -> [SystemAudioSource] {
    sources.filter { source in
      let isUserFacingApplication =
        source.bundleID.map { bundleID in
          let resolvesToApplication =
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            != nil
          return NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID
          ).contains { application in
            Self.applicationAudioSourceIsUserFacing(
              bundleID: bundleID,
              activationPolicy: application.activationPolicy,
              resolvesToApplication: resolvesToApplication
            )
          }
        } ?? false
      return Self.shouldShowSystemAudioSource(
        source,
        isUserFacingApplication: isUserFacingApplication
      )
    }
  }



  var selectedSystemAudioSourceGuidance: String? {
    guard capture.selectedSystemAudioSourceID != "entire-system",
      let source = capture.systemAudioSources.first(where: {
        $0.id == capture.selectedSystemAudioSourceID
      })
    else { return nil }
    let identity = "\(source.bundleID ?? "") \(source.displayName)".lowercased()
    if identity.contains("chrome") || identity.contains("chromium") {
      return "Chrome 会作为一个应用整体录制，无法单独录制某个标签页。如需避免录入其他标签页的声音，请关闭其他正在发声的标签页。"
    }
    if ["quicktime", "vlc", "iina"].contains(where: {
      identity.contains($0)
    }) {
      return "这是本地播放器。若有原始媒体文件，直接拖到“文件导入”通常更快，也能保留准确时长和原始文件证据。"
    }
    return nil
  }

  var systemAudioMicrophoneGuidance: String {
    if !systemAudioMicrophoneSelectionIsAutomatic {
      return "这是你为当前来源保存的选择；切换回来时会保持。"
    }
    return history.includeMicrophoneInSystemRecording
      ? "已识别为会议应用，默认开启独立麦克风音轨；你可以覆盖。"
      : "当前来源默认录制电脑输出；需要录制讲解或网页会议时，可以手动开启麦克风。"
  }







  static func isLikelyMeetingWindowTitle(_ title: String) -> Bool {
    [
      "google meet", "meet.google", "zoom meeting", "zoom webinar",
      "腾讯会议", "voov meeting", "microsoft teams", "teams meeting",
      "webex", "飞书会议", "lark meeting", "钉钉会议",
    ].contains(where: title.contains)
  }















  func pauseOrResume() {
    if lifecycleCommands.queueIfInFlight(.pauseOrResume, for: .dictation) {
      liveTranscriptStatus = "当前操作完成后切换暂停状态"
      statusMessage = liveTranscriptStatus
      renderRecordingPanel()
      return
    }
    performLifecycleCommand(mode: .dictation, intent: .pauseOrResume) { [weak self] in
      guard let self else { return }
      do {
        if fixtureMode {
          guard let fixtureActor else { return }
          snapshot = try await fixtureActor.handle(
            snapshot.phase == .paused ? .resume : .pause
          )
        } else if snapshot.phase == .paused, let coordinator {
          let devices = (try? MicrophoneDeviceCatalog.devices()) ?? []
          if devices.contains(where: { $0.uid == activeDictationMicrophoneUID }) {
            snapshot = try await coordinator.resume()
          } else {
            let replacement = try MicrophoneDeviceCatalog.defaultDevice()
            snapshot = try await coordinator.replacePausedCapture(
              with: AVAudioEngineMicrophoneCapture(
                selectedDeviceUID: replacement.uid
              )
            )
            activeDictationMicrophoneUID = replacement.uid
            statusMessage = "已切换到 \(replacement.name)，并在同一条口述中继续"
          }
          beginDictationLifecycleMonitoring(coordinator: coordinator)
        } else if snapshot.phase == .recording {
          snapshot = try await coordinator?.pause() ?? snapshot
          stopDictationLifecycleMonitoring()
        }
        publishSnapshotStatus()
      } catch {
        statusMessage = "暂停或继续未完成；已提交音频仍保留"
      }
    }
  }

  func cancel() {
    if lifecycleCommands.queueIfInFlight(.cancel, for: .dictation) {
      liveTranscriptStatus = "当前操作完成后立即取消，取消后不输入文字"
      statusMessage = liveTranscriptStatus
      renderRecordingPanel()
      return
    }
    performLifecycleCommand(mode: .dictation, intent: .cancel) { [weak self] in
      guard let self, canCancel else { return }
      do {
        if fixtureMode {
          guard let fixtureActor else { return }
          _ = try await fixtureActor.handle(.cancel)
          snapshot = try await fixtureActor.handle(.cancellationCompleted)
        } else if let coordinator {
          stopDictationLifecycleMonitoring()
          let sessionID = snapshot.sessionID
          statusMessage = "正在取消这次未提交的口述…"
          snapshot = Self.presentationSnapshot(
            from: snapshot,
            phase: .cancelling,
            marker: .cancelRequested
          )
          publishSnapshotStatus()
          snapshot = try await coordinator.cancel()
          if let sessionID {
            await localRuntime?.clearLiveSession(sessionID: sessionID)
            // Esc and the fn chord end the take here, never in `process`:
            // give the speculation slot back and re-arm the idle release.
            await localRuntime?.endUnprocessedDictation(sessionID: sessionID)
          }
          self.coordinator = nil
          activeDictationMicrophoneUID = ""
          if !keepsDictations { await forgetDemoDictation(sessionID) }
        }
        await hotkeyProvider?.setCancellationEnabled(false)
        publishSnapshotStatus()
      } catch {
        statusMessage = "取消尚未收口；下次启动会从本机记录恢复"
      }
    }
  }


































  static func startupRecoverySessionIDs(
    from candidates: [DictationRecoveryCandidate]
  ) -> Set<SessionID> {
    Set(
      candidates.compactMap { candidate in
        guard candidate.disposition != .cleanupCompleted,
          candidate.snapshot.failure?.retryable != false,
          !isSilentDictationFailure(code: candidate.snapshot.failure?.code)
        else {
          return nil
        }
        return candidate.snapshot.sessionID
      }
    )
  }


















  var selectedHistoryRawText: String? {
    guard let selectedHistorySessionID = history.selectedHistorySessionID else { return nil }
    return history.historyItems.first(where: {
      $0.sessionID == selectedHistorySessionID
    })?.rawText
  }

  var selectedHistoryFinalText: String? {
    guard let selectedHistorySessionID = history.selectedHistorySessionID else { return nil }
    return history.historyItems.first(where: {
      $0.sessionID == selectedHistorySessionID
    })?.polishedText
  }

  var selectedHistoryRecognitionText: String? {
    guard let current = selectedHistoryCurrentTranscript else {
      return selectedHistoryRawText
    }
    return TranscriptSelection.recognitionSource(
      for: current,
      in: history.selectedHistoryTranscripts
    )?.content
  }

  var selectedHistoryCurrentTranscript: DictationPersistedTranscriptRecord? {
    TranscriptSelection.current(in: history.selectedHistoryTranscripts)
  }

  var selectedHistoryTimestampedTranscript: DictationPersistedTranscriptRecord? {
    TranscriptSelection.timestamped(in: history.selectedHistoryTranscripts)
  }








































  var selectedHistorySourceAudioExportTitle: String {
    let hasImportedOriginal = history.selectedHistorySourceAssets.contains {
      $0.kind == .importedOriginal
    }
    if hasImportedOriginal, historySelectedExportMonotonicRange() == nil {
      return "导出导入原文件（未转码）"
    }
    let trackTitle = historyPlaybackTrackTitle(playback.selectedHistoryPlaybackTrackID)
    return "导出\(trackTitle)所选范围"
  }

  var archiveSecretIsValid: Bool {
    export.archiveSecretDraft.count >= 12
      && export.archiveSecretDraft.utf8.count >= 16
      && export.archiveSecretDraft == export.archiveSecretConfirmationDraft
  }






  var filteredEventSummaries: [EventSummary] {
    let query = history.eventSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return events.summaries }
    if let eventSearchResultIDs = history.eventSearchResultIDs {
      return events.summaries.filter { eventSearchResultIDs.contains($0.id) }
    }
    return events.summaries.filter { summary in
      summary.event.title.localizedCaseInsensitiveContains(query)
        || summary.event.notes.localizedCaseInsensitiveContains(query)
        || summary.personDisplayNames.contains(where: {
          $0.localizedCaseInsensitiveContains(query)
        })
        || summary.sessionIDs.contains(where: { sessionID in
          history.eventAvailableHistoryItems.first(where: { $0.sessionID == sessionID })
            .map {
              $0.title.localizedCaseInsensitiveContains(query)
                || ($0.preferredText ?? "").localizedCaseInsensitiveContains(query)
            } ?? false
        })
    }
  }

  var selectedEventSummary: EventSummary? {
    guard let selectedEventID = events.selectedEventID else { return nil }
    return events.summaries.first { $0.id == selectedEventID }
  }

  var activeEventReviewCandidate: EventCandidate? {
    guard let activeEventReviewCandidateID = events.activeEventReviewCandidateID else { return nil }
    return events.candidates.first { $0.id == activeEventReviewCandidateID }
  }

  var unassignedEventHistoryItems: [DictationHistoryItem] {
    let assigned = Set(events.summaries.flatMap(\.sessionIDs))
    return history.eventAvailableHistoryItems.filter { !assigned.contains($0.sessionID) }
  }

  var linkableHistoryItemsForSelectedEvent: [DictationHistoryItem] {
    guard let selectedEventSummary else { return [] }
    let linked = Set(selectedEventSummary.sessionIDs)
    return history.eventAvailableHistoryItems.filter { !linked.contains($0.sessionID) }
  }
























  nonisolated static func eventEvidenceTokens(
    _ text: String
  ) -> Set<String> {
    let characters = Array(
      text.lowercased().filter { $0.isLetter || $0.isNumber }
    )
    guard !characters.isEmpty else { return [] }
    guard characters.count > 1 else { return Set([String(characters)]) }
    return Set(
      (0..<(characters.count - 1)).map {
        String(characters[$0...($0 + 1)])
      }
    )
  }
















  nonisolated static func eventStatus(
    eventCount: Int,
    candidateCount: Int
  ) -> String {
    if eventCount == 0, candidateCount == 0 {
      return "尚无事。请确认归类，或从相关记录新建一件事"
    }
    let review =
      candidateCount == 0
      ? "没有待确认的内容" : "\(candidateCount) 条待确认"
    return "\(eventCount) 件事 · \(review)；全部处理均在本机完成"
  }

  var filteredPersonSummaries: [PersonSummary] {
    let query = history.peopleSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let browsable = Self.browsablePersonSummaries(people.personSummaries)
    guard !query.isEmpty else { return browsable }
    return browsable.filter { Self.personSummary($0, matches: query) }
  }






  var selectedPersonSummary: PersonSummary? {
    guard let selectedPersonID = people.selectedPersonID else { return nil }
    return people.personSummaries.first { $0.person.id == selectedPersonID }
  }

  var selectedPersonRelatedHistory: [DictationHistoryItem] {
    history.selectedPersonHistoryItems
  }






  func toggleOccurrenceForSplit(_ occurrence: SpeakerOccurrenceSummary) {
    if splitOccurrenceIDs.contains(occurrence.id) {
      splitOccurrenceIDs.remove(occurrence.id)
    } else {
      splitOccurrenceIDs.insert(occurrence.id)
    }
  }

  func splitSelectedOccurrences() {
    let selected = selectedSessionOccurrences.filter {
      splitOccurrenceIDs.contains($0.id)
    }
    guard let sourcePersonID = selected.first?.personID,
      selected.allSatisfy({ $0.personID == sourcePersonID }),
      let repository,
      let sessionID = history.selectedHistorySessionID
    else {
      people.speakerIdentityStatusMessage = "请选择同一个已确认人物的一段或多段出现记录"
      return
    }
    let name = people.splitPersonNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      people.speakerIdentityStatusMessage = "请为拆分后的人物输入名称"
      return
    }
    people.speakerIdentityStatusMessage = "正在拆分所选出现记录…"
    Task { [weak self] in
      guard let self else { return }
      do {
        _ = try await repository.splitPersonOccurrences(
          sourcePersonID: sourcePersonID,
          occurrenceIDs: selected.map(\.id),
          newDisplayName: name,
          originDeviceID: Self.localOriginDeviceID()
        )
        splitOccurrenceIDs = []
        people.splitPersonNameDraft = ""
        people.speakerIdentityStatusMessage = "所选片段已拆分为新人物；可以在人物页撤销"
        await refreshSelectedSpeakerDetails(sessionID: sessionID)
      } catch {
        people.speakerIdentityStatusMessage = "拆分失败；现有说话人证据没有被改变"
      }
    }
  }
















  func bootstrap() async {
    await readPermissionStates()
    // Not at launch (live-mac): listing devices brings CoreAudio up in this
    // process (its voice-processing listeners log at once), and an idle App
    // has no use for the list. The pages and Settings that show devices
    // read them when they appear, and a capture reads its device itself.
    // Known before the first Fn ⇧, so the capsule can say when a language
    // pack is missing rather than discovering it after the words went in.
    refreshTranslationEngineStatus()
    // Register and observe the system-wide shortcut before loading history,
    // semantic organization, or model runtimes. A large local library must
    // never make the most basic interaction look dead during launch.
    // Not while fn is held by the user's bestASR App, switched off, or a
    // preview verification run says so (FnGuard arms it later when it may).
    // FnGuard is attached before this (init), so a launch or quit of
    // bestASR meanwhile is applied after this arming, never before it.
    await FnGuard.shared.arm(atLaunch: self)
    if let hotkeyProvider {
      await beginHotkeyObservation(using: hotkeyProvider)
    }

    if let localRuntime {
      await localRuntime.configureUserPreferences(
        defaultPolishEnabled: defaultPolishEnabled,
        personalCleanupEnabled: people.personalCleanupEnabled,
        appPolicies: appTextPolicies,
        speakerMemoryEnabled: people.speakerMemoryEnabled
      )
      let events = await localRuntime.liveTranscriptEvents()
      liveTranscriptTask = Task { [weak self] in
        for await event in events {
          guard let self else { return }
          self.applyLiveTranscriptEvent(event)
        }
      }
    }

    async let modelDiscovery: Void = discoverInstalledModels()
    // Demo mode: dictations an earlier run left behind go before history
    // and recovery see them.
    await forgetLeftoverDemoDictations()
    await dictionary.refreshEntries()
    await refreshHistoryItems(refreshOverview: false)
    scheduleHistoryMaintenance()
    await refreshPeopleNow()
    if let repository, let journal {
      let recovery = DictationStartupRecovery(repository: repository, journal: journal)
      let candidates = (try? await recovery.scan()) ?? []
      // Only successful, positively verified empty-take cleanup removes a
      // recovery entry. Failed checks and unknown source bytes remain reachable.
      let remaining = await cleanUpVerifiedEmptyRecoveryCandidates(candidates)
      startupRecoverySessionIDs = Self.startupRecoverySessionIDs(
        from: remaining
      )
      recoveryItemCount = startupRecoverySessionIDs.count
    }

    // Model construction starts only after the global shortcut/capture path,
    // but runs alongside local-library loading so neither delays the other.
    // Ending early still seals source audio and leaves recoverable local work.
    await modelDiscovery
    if models.automaticModelUpdates, models.allowModelDownloads,
      recommendedComponentLicensesAccepted, needsModelSetup,
      !models.recommendedModelInstallInProgress
    {
      models.recommendedModelProgressMessage =
        "自动更新已启用：正在安装此版本固定并校验过的缺失模型"
      downloadRecommendedModels()
    }
    if models.automaticAppUpdateChecks {
      performAppUpdateCheck(silentWhenCurrent: true)
    }
    refreshStorageUsage()
    // Event organization — sentence embeddings over the whole library — used
    // to run here on every launch: two cores and 4 GB of small allocations
    // for a page the user has not opened, on a feature that is explicitly
    // future work. It runs when 事件 is opened (`refreshEvents`), not before.
  }


  func handle(_ transition: NativeHotkeyTransition) async {
    // Mindloom Preview beside the user's own bestASR App: that App has fn, so
    // the preview does not dictate (one press would dictate twice). A press
    // that started here before the other App launched still gets its release.
    if transition.isPressed, snapshot.phase == .idle, MindloomBuild.otherAppHoldsFn {
      hotkeys.hotkeyStatusMessage = "bestASR 正在使用 fn 键。请先退出 bestASR，或在设置中为 Mindloom 更换快捷键。"
      return
    }
    // Only a press is refused because other work is running. A release always
    // reaches the branch its press took: a recording that starts elsewhere
    // while the key is held must not strand the dictation it was holding.
    let hasNonDictationWork =
      transition.isPressed
      && (capture.roomSnapshot.phase.isActive
        || capture.systemAudioSnapshot.phase.isActive || capture.importInProgress)
    if transition.isFunctionChord {
      handleFunctionChord(keyCode: transition.chordKeyCode)
      return
    }
    // Hold to talk, tap to toggle — for every shortcut, not only for Fn.
    // There used to be a switch for this, whose own description explained
    // that with it off the key already behaved this way; the rule reads the
    // press itself, so there is nothing left to configure.
    if transition.action == .startOrEnd, !hasNonDictationWork {
      await handleFunctionKey(isPressed: transition.isPressed, keyTime: transition.keyTime)
      return
    }
    guard transition.isPressed else { return }
    await handle(transition.action)
  }

  /// Holding Fn longer than this is push-to-talk; a shorter tap keeps the
  /// dictation running hands-free until Fn is tapped again (Esc cancels).
  nonisolated static let functionHoldThreshold: Duration = DictationKeyRelease.holdThreshold

  /// Another key typed within this window after Fn started a dictation means
  /// the user meant an Fn chord (Fn+Delete, Fn+arrow…), not dictation.
  nonisolated static let functionChordWindow: Duration = .milliseconds(700)

  func handleFunctionKey(isPressed: Bool, keyTime: TimeInterval? = nil) async {
    if isPressed {
      pushToTalkFinishTask?.cancel()
      // v11 (mac-capture): microphone not allowed → 「麦克风没有打开 · 去设置」.
      guard fnPressAllowed() else { return }
      // Time every press, including one made while the runtime is still busy.
      // Reading the clock only when a dictation could start immediately meant
      // a hold that began a moment too early recorded no start time, so its
      // release was discarded and the dictation it did start kept recording.
      functionHoldStartedAt = ContinuousClock.now
      functionHoldKeyTime = keyTime
      // A press starts a dictation, or ends one that is listening hands-free.
      let keyAt = Self.keyEventInstant(keyTime)
      if [.recording, .paused].contains(snapshot.phase) {
        dictationEndKeyAt = keyAt
      } else {
        dictationStartKeyAt = keyAt
      }
      armFunctionReleaseWatchdog()
      await handle(.startOrEnd)
      return
    }
    functionReleaseWatchdog?.cancel()
    functionReleaseWatchdog = nil
    guard let started = functionHoldStartedAt else { return }
    functionHoldStartedAt = nil
    let pressedAt = functionHoldKeyTime
    functionHoldKeyTime = nil
    // A short tap leaves the take listening hands-free: the next press ends
    // it, Esc cancels it, and a take with no speech ends with 「没有听到」
    // (d54; ALIGNMENT 收1-21, decided 10/5). v11 dropped it instead. The
    // key events' own times decide, not when they were handled (review
    // v12-B #11): starting the microphone between the two is not holding fn.
    let held = DictationKeyRelease.heldDuration(
      pressedAt: pressedAt, releasedAt: keyTime, handledApart: ContinuousClock.now - started)
    if Self.functionReleaseEndsDictation(heldFor: held) {
      dictationEndKeyAt = Self.keyEventInstant(keyTime)
      finishDictationAfterStartSettles()
    }
  }

  /// Ends a held dictation even when its release event never arrives.
  ///
  /// Fn has no key-up of its own: it is seen only as a modifier flag change,
  /// which is lost if the event tap is disabled, if Accessibility is revoked,
  /// or if another app swallows the transition. That left the microphone
  /// recording with no way to stop it from the keyboard. Once the press has
  /// lasted past the hold threshold and the key is confirmed still down, the
  /// hardware modifier state is polled directly, and the moment Fn is no
  /// longer held the release runs as if the event had come through.
  func armFunctionReleaseWatchdog() {
    functionReleaseWatchdog?.cancel()
    // Only Fn is invisible as a key-up; every other shortcut has one.
    guard hotkeys.startEndHotkeyBinding.isFunctionAlone else { return }
    functionReleaseWatchdog = Task { [weak self] in
      try? await Task.sleep(for: Self.functionHoldThreshold + .milliseconds(50))
      guard !Task.isCancelled else { return }
      // Let go before this first look: a tap (or a hold just past the
      // threshold), and the release event, queued behind the main thread,
      // says which with the key's own times. Ending it here would turn a
      // delayed tap into a hold (review v12-B #11); if that event never
      // comes, the take keeps listening and the next tap ends it.
      guard Self.functionKeyPhysicallyHeld() else { return }
      // Still held: the hardware state is the truth from here; the release
      // event may never come.
      while !Task.isCancelled, Self.functionKeyPhysicallyHeld() {
        try? await Task.sleep(for: .milliseconds(150))
      }
      guard !Task.isCancelled, let self, self.functionHoldStartedAt != nil else { return }
      dictationAppLogger.notice("fn release recovered from hardware state")
      await self.handleFunctionKey(isPressed: false)
    }
  }

  nonisolated static func functionKeyPhysicallyHeld() -> Bool {
    NSEvent.modifierFlags.contains(.function)
  }


  /// What a dictation is for. Chosen by chording the dictation key while it
  /// runs, the way Typeless does it: the key already under the finger decides,
  /// so a second shortcut never has to be found, remembered or registered —
  /// and a bare-Fn dictation key would win the race against any separate Fn
  /// combination anyway, because it fires on its own down edge.
  typealias DictationSpokenMode = SpokenMode

  /// The mode of the dictation now in flight, and the text it acts on.
  ///
  /// It deliberately carries no session identifier. It used to, taken from
  /// `snapshot.sessionID` at the moment the chord arrived — but a chord
  /// arrives milliseconds after the dictation key goes down, and the session
  /// is created asynchronously, so what it read was the *previous*
  /// dictation's identifier. The start that followed then cleared the plan
  /// outright. Between them, pressing Fn+⇧ at the start of a dictation set
  /// the capsule to 翻译 and delivered Chinese; only pressing it a second
  /// time, once recording was really under way, worked. Only one dictation
  /// runs at a time, so the plan belongs to whichever one is in flight, and
  /// the start clears it before the chord can arrive rather than after.
  ///
  /// The selection is the user's own words, read out of another app. It is
  /// held only until this dictation is delivered, never written to the
  /// database, and never logged — not its content and not its length.
  struct SpokenModePlan: Sendable {
    var mode: DictationSpokenMode
    var selection: String?
    /// Which of the configured target languages 翻译 is aimed at. Pressing ⇧
    /// again advances it.
    var languageIndex = 0
  }




  /// Every language 翻译 can aim at. Their names go to the model as written,
  /// so they are language names rather than codes.
  nonisolated static let translationLanguageNames = [
    "英语", "简体中文", "繁体中文", "日语", "韩语", "法语", "德语", "西班牙语",
    "俄语", "葡萄牙语", "意大利语", "阿拉伯语",
  ]

  /// At most this many may be chosen, because ⇧ cycles through them one press
  /// at a time and a longer ring is a worse control than a menu.
  nonisolated static let maximumTranslationLanguages = 3












  func handle(_ action: GlobalHotkeyAction) async {
    dictationAppLogger.info(
      "app handling hotkey action \(action.rawValue, privacy: .public)"
    )
    switch action {
    case .startOrEnd:
      if capture.roomSnapshot.phase.isActive {
        startOrEndRoomRecording()
      } else if capture.systemAudioSnapshot.phase.isActive {
        startOrEndSystemAudioRecording()
      } else if canStartDictationNow {
        startOrEnd(
          preCapturedTarget: captureHotkeyInsertionTarget(),
          captureExternalTargetWhenMissing: true
        )
      } else {
        startOrEnd()
      }
    case .pauseOrResume:
      if capture.roomSnapshot.phase.isActive {
        pauseOrResumeRoomRecording()
      } else if capture.systemAudioSnapshot.phase.isActive {
        pauseOrResumeSystemAudioRecording()
      } else if capture.importInProgress {
        toggleImportPause()
      } else {
        pauseOrResume()
      }
    case .cancel:
      if capture.roomSnapshot.phase.isActive {
        cancelRoomRecording()
      } else if capture.systemAudioSnapshot.phase.isActive {
        cancelSystemAudioRecording()
      } else if capture.importInProgress {
        cancelImport()
      } else {
        cancel()
      }
    }
  }


  func applyDeferredLifecycleAction(
    _ action: CaptureLifecycleCommandState.Action?,
    for mode: CaptureLifecycleCommandState.Mode
  ) {
    guard let action else { return }
    switch mode {
    case .dictation:
      if action == .start {
        guard canStartDictationNow else { return }
        startOrEnd()
        return
      }
      guard [.recording, .paused].contains(snapshot.phase) else { return }
      switch action {
      case .start: return
      case .end: startOrEnd()
      case .pauseOrResume: pauseOrResume()
      case .cancel: cancel()
      }
    case .roomRecording:
      guard [.recording, .paused].contains(capture.roomSnapshot.phase) else { return }
      switch action {
      case .start: return
      case .end: startOrEndRoomRecording()
      case .pauseOrResume: pauseOrResumeRoomRecording()
      case .cancel: cancelRoomRecording()
      }
    case .systemAudio:
      guard [.recording, .paused].contains(capture.systemAudioSnapshot.phase) else {
        return
      }
      switch action {
      case .start: return
      case .end: startOrEndSystemAudioRecording()
      case .pauseOrResume: pauseOrResumeSystemAudioRecording()
      case .cancel: cancelSystemAudioRecording()
      }
    }
  }




  func start(
    preCapturedTarget: DictationTargetSnapshot?,
    captureExternalTargetWhenMissing: Bool
  ) async {
    let startRequested = ContinuousClock.now
    // Counted from the key's own event when a key started it, else from the
    // microphone started at the key press, else from now (menu bar, window).
    let pressedAt = Self.dictationAnchor(
      dictationStartKeyAt ?? keyPressMicrophone?.at, now: startRequested)
    dictationStartKeyAt = nil
    // An end key seen before this take started belongs to an earlier one.
    dictationEndKeyAt = nil
    pressToRecording = nil
    dictationAppLogger.info("dictation start requested")
    do {
      guard !self.capture.roomSnapshot.phase.isActive,
        !self.capture.systemAudioSnapshot.phase.isActive,
        !self.capture.importInProgress
      else {
        statusMessage = "请先结束正在进行的录音或文件导入"
        return
      }
      let startedAt = DispatchTime.now().uptimeNanoseconds
      // Start the microphone before any check, panel, or focus work so the
      // first syllable is recorded. Every path below that does not hand it to
      // the capture coordinator discards it without saving anything.
      let earlyMicrophone =
        takeKeyPressMicrophone(startRequested: startRequested)
        ?? (fixtureMode || self.capture.microphonePermission != .granted
          ? nil : startMicrophoneEarly(since: startRequested))
      var earlyMicrophoneAdopted = false
      defer {
        if let earlyMicrophone, !earlyMicrophoneAdopted {
          discardEarlyMicrophone(earlyMicrophone)
        }
      }
      if let journal,
        let disk = await dictationStartDiskSpaceDecision(journal),
        disk.state == .hardStop
      {
        statusMessage = "这台 Mac 的可用空间不足 1 GB，无法开始录音。请先在设置中管理储存空间"
        return
      }
      liveTranscriptText = ""
      liveTranscriptStatus = "正在准备麦克风"
      if fixtureMode {
        self.capture.captureWorkspaceHandoff = nil
        let fixtureActor = DictationSessionActor()
        self.fixtureActor = fixtureActor
        let target =
          ProcessInfo.processInfo.arguments.contains(
            "--no-target-ui-testing"
          ) || !captureExternalTargetWhenMissing
          ? nil : Self.fixtureTarget()
        let preparing = try await fixtureActor.handle(
          .start(sessionID: SessionID(), target: target)
        )
        snapshot = preparing
        renderRecordingPanel(snapshot: preparing)
        await hotkeyProvider?.setCancellationEnabled(true)
        snapshot = try await fixtureActor.handle(.preparationSucceeded)
      } else {
        guard let permissions = permissionService, let journal,
          let repository, let localRuntime
        else { return }
        self.capture.microphonePermission = await permissions.state(for: .microphone)
        onboarding.accessibilityPermission = await permissions.state(for: .accessibility)
        guard self.capture.microphonePermission == .granted else {
          if self.capture.microphonePermission == .notDetermined {
            self.capture.microphonePermission = await permissions.request(.microphone)
          }
          if self.capture.microphonePermission != .granted {
            await permissions.openRecoverySettings(for: .microphone)
          }
          statusMessage = "请允许麦克风权限，然后重新开始"
          return
        }
        logDictationStage("start-prechecks", since: startRequested)
        // Wake an idle recognizer while the user is still speaking.
        Task { await localRuntime.warmFinalASRIfIdle() }
        let sessionID = earlyMicrophone?.sessionID ?? SessionID()
        // Demo mode: written down before the session exists, so it is
        // removed even if the App stops in the middle (根-10).
        if !keepsDictations { noteDemoDictation(sessionID) }
        var target = externalInsertionTarget(preCapturedTarget)
        snapshot = DictationSessionSnapshot(
          sessionID: sessionID,
          revision: 1,
          phase: .preparing,
          target: target,
          timeline: [
            DictationTimelineMarker(
              kind: .started,
              monotonicNanoseconds: startedAt
            )
          ]
        )
        self.capture.captureWorkspaceHandoff = nil
        statusMessage = "正在准备麦克风"
        renderRecordingPanel()
        // Esc must become active as soon as the visible preparation state
        // exists. Waiting until microphone startup finishes would drop the
        // user's explicit cancel command during the slowest part of startup.
        await hotkeyProvider?.setCancellationEnabled(true)

        // The panel is already visible before any potentially stabilizing AX
        // read. Only global-shortcut/menu-bar starts may acquire an external
        // insertion target; a main-window start always saves to Library and
        // can never write into bestASR's own search or editing controls.
        if target == nil, captureExternalTargetWhenMissing,
          onboarding.accessibilityPermission == .granted,
          insertionService != nil
        {
          let targetCaptureStarted = ContinuousClock.now
          target = externalInsertionTarget(try? captureHotkeyTarget())
          logDictationStage("target-capture", since: targetCaptureStarted)
          snapshot = DictationSessionSnapshot(
            sessionID: sessionID,
            revision: 1,
            phase: .preparing,
            target: target,
            timeline: snapshot.timeline
          )
          renderRecordingPanel()
        }
        let capture: AVAudioEngineMicrophoneCapture
        if let earlyMicrophone {
          // Let the early start settle before the coordinator adopts it; a
          // failed early start simply leaves the coordinator a normal start.
          _ = try? await earlyMicrophone.start.value
          activeDictationMicrophoneUID = earlyMicrophone.deviceUID
          capture = earlyMicrophone.capture
          earlyMicrophoneAdopted = true
        } else {
          firstAudioPendingSince = startRequested
          pressToRecording = nil
          let dictationDevice = try MicrophoneDeviceCatalog.defaultDevice()
          activeDictationMicrophoneUID = dictationDevice.uid
          capture = makeDictationCapture(deviceUID: dictationDevice.uid, sessionID: sessionID)
        }
        await localRuntime.beginFinalSpeculation(sessionID: sessionID)
        let coordinator = DictationCaptureCoordinator(
          sessionActor: DictationSessionActor(),
          capture: capture,
          journal: journal,
          repository: repository,
          committedChunkObserver: localRuntime,
          // A demo dictation never reaches a DGX Spark.
          grantsRemoteEligibility: keepsDictations
        )
        self.coordinator = coordinator
        snapshot = try await coordinator.start(
          sessionID: sessionID,
          target: target
        )
        logDictationStage("start-to-capture", since: startRequested)
        pressToRecording = ContinuousClock.now - pressedAt
        if let sessionID = snapshot.sessionID {
          await localRuntime.registerLiveSession(
            sessionID: sessionID,
            inputMode: .dictation
          )
        }
        beginDictationLifecycleMonitoring(coordinator: coordinator)
      }
      liveTranscriptStatus =
        models.modelRuntimeReady
        ? "正在本地聆听——草稿文字还会继续更新"
        : "正在保存音频；本地识别准备完成后可转写"
      await hotkeyProvider?.setCancellationEnabled(true)
      publishSnapshotStatus()
      dictationAppLogger.info("dictation start succeeded")
    } catch {
      let diagnostic = error as NSError
      dictationAppLogger.error(
        "dictation start failed: domain=\(diagnostic.domain, privacy: .public) code=\(diagnostic.code)"
      )
      stopDictationLifecycleMonitoring()
      coordinator = nil
      activeDictationMicrophoneUID = ""
      await hotkeyProvider?.setCancellationEnabled(false)
      // A start that failed after the runtime took its speculation slot (or
      // cancelled the idle release to warm the recognizer) ends here.
      if let sessionID = snapshot.sessionID, snapshot.phase == .preparing {
        await localRuntime?.endUnprocessedDictation(sessionID: sessionID)
      }
      if let sessionID = snapshot.sessionID,
        let durable = try? await repository?.load(sessionID: sessionID)
      {
        // Demo mode too: what was captured stays (review v12-B #1).
        if !keepsDictations { keepDemoDictation(sessionID) }
        snapshot = durable
        statusMessage = "口述未能开始；已建立的本机记录可恢复，没有插入不完整文字"
        renderRecordingPanel()
      } else {
        // Nothing was made: a demo take only leaves the ledger.
        if !keepsDictations { await forgetDemoDictation(snapshot.sessionID) }
        snapshot = DictationSessionSnapshot()
        recordingPanel.dismiss()
        statusMessage = "口述未能开始；没有插入任何不完整文字"
      }
    }
  }

  func end() async {
    let endRequested = ContinuousClock.now
    // Release to text counts from the key's own event (the release, or the
    // press that ends a hands-free take) when a key ended it.
    let releasedAt = Self.dictationAnchor(dictationEndKeyAt, now: endRequested)
    dictationEndKeyAt = nil
    defer { refreshDiskSpaceDecisionInBackground() }
    stopDictationLifecycleMonitoring()
    do {
      if fixtureMode {
        guard let fixtureActor else { return }
        snapshot = try await fixtureActor.handle(.end)
        renderRecordingPanel()
        snapshot = try await fixtureActor.handle(.journalSealed)
        guard models.modelRuntimeReady else {
          await hotkeyProvider?.setCancellationEnabled(false)
          publishSnapshotStatus()
          upsertFixtureDictationHistory(state: .processing)
          await presentCaptureWorkspaceHandoff(
            sessionID: snapshot.sessionID,
            inputMode: .dictation,
            state: .processing,
            detail: "原音已保存；完成本地语音识别模型准备后即可继续转写",
            organizeEvents: false
          )
          return
        }
        let transcript = DictationTranscriptResult(
          revisionID: TranscriptRevisionID(),
          segmentIDs: [],
          text: "fixture raw dictation",
          modelArtifactID: "fixture-asr"
        )
        snapshot = try await fixtureActor.handle(.recognitionSucceeded(transcript))
        let polish = DictationPolishResult(
          sourceRevisionID: transcript.revisionID,
          text: "Fixture raw dictation.",
          disposition: .model,
          modelArtifactID: "fixture-text"
        )
        snapshot = try await fixtureActor.handle(.polishSucceeded(polish))
        let insertion = DictationInsertionResult(
          idempotencyKey: try DictationIdempotencyKey("fixture-insert:1"),
          method: snapshot.target == nil ? .retainedForCopy : .clipboardPaste,
          inserted: snapshot.target != nil,
          failureReason: snapshot.target == nil ? .nowhere : nil
        )
        snapshot = try await fixtureActor.handle(.insertionCompleted(insertion))
        upsertFixtureDictationHistory(state: .completed)
      } else if let coordinator {
        snapshot = Self.presentationSnapshot(
          from: snapshot,
          phase: .finalizing,
          marker: .endRequested
        )
        statusMessage = "正在结束录音并保存原音…"
        publishSnapshotStatus()
        let finalization = try await coordinator.end()
        logDictationStage("seal-audio", since: endRequested)
        let sealed = ContinuousClock.now - endRequested
        let measured = DictationTimingInputs(
          releasedAt: releasedAt, seal: sealed, pressToRecording: pressToRecording,
          mode: spokenModePlan?.mode ?? .dictate)
        pressToRecording = nil
        if models.modelRuntimeReady, let localRuntime {
          // The audio is sealed, so nothing about this dictation needs the
          // microphone or the lifecycle lock any more: recognition, cleanup
          // and insertion continue in the background and the user can start
          // the next dictation immediately. Recognition starts before any
          // screen work; the status and the capsule follow while the
          // recognizer already runs (收1-2).
          self.coordinator = nil
          activeDictationMicrophoneUID = ""
          snapshot = finalization.snapshot
          finalizeInBackground(
            finalization,
            coordinator: coordinator,
            runtime: localRuntime,
            endRequested: endRequested,
            measured: measured
          )
          statusMessage = "正在本地转写并插入文字…"
          await hotkeyProvider?.setCancellationEnabled(false)
          publishSnapshotStatus()
          return
        }
        // No recognizer yet: the audio stays to be transcribed once the
        // models are ready.
        if let sessionID = finalization.snapshot.sessionID {
          await localRuntime?.endUnprocessedDictation(sessionID: sessionID)
        }
        snapshot = finalization.snapshot
        publishSnapshotStatus()
        await hotkeyProvider?.setCancellationEnabled(false)
        self.coordinator = nil
        activeDictationMicrophoneUID = ""
        // Demo mode too: the audio stays to be transcribed once the
        // models are ready (review v12-B #1).
        if !keepsDictations, let sessionID = snapshot.sessionID {
          keepDemoDictation(sessionID)
        }
        statusMessage =
          "音频已保存在本机；完成本地语音识别模型准备后即可转写"
        await presentCaptureWorkspaceHandoff(
          sessionID: snapshot.sessionID,
          inputMode: .dictation,
          state: .processing,
          detail: statusMessage,
          organizeEvents: false
        )
        return
      }
      await hotkeyProvider?.setCancellationEnabled(false)
      publishSnapshotStatus()
      await presentCaptureWorkspaceHandoff(
        sessionID: snapshot.sessionID,
        inputMode: .dictation,
        state: snapshot.phase == .completed ? .completed : .needsAttention,
        detail: statusMessage,
        organizeEvents: true
      )
    } catch {
      // Sealing failed, so `process` never saw this take.
      if !fixtureMode, let sessionID = snapshot.sessionID {
        await localRuntime?.endUnprocessedDictation(sessionID: sessionID)
      }
      if let sessionID = snapshot.sessionID,
        let durable = try? await repository?.load(sessionID: sessionID)
      {
        snapshot = durable
        try? await coordinator?.synchronizeProcessingSnapshot(durable)
      }
      copyUninsertedDictationIfNeeded(snapshot, draft: liveTranscriptText)
      await hotkeyProvider?.setCancellationEnabled(false)
      publishSnapshotStatus()
      // Demo mode: a take that failed stays in the demo library with its
      // audio (review v12-B #1).
      if !keepsDictations, await settleDemoDictation(snapshot, sessionID: snapshot.sessionID) {
        return
      }
      statusMessage = "音频已保留；可以重试完成处理"
      await presentCaptureWorkspaceHandoff(
        sessionID: snapshot.sessionID,
        inputMode: .dictation,
        state: .needsAttention,
        detail: statusMessage,
        organizeEvents: false
      )
    }
  }









  nonisolated static func applicationDisplayName(_ bundleIdentifier: String) -> String {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
      .flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleName"] as? String }
      ?? (bundleIdentifier.split(separator: ".").last.map(String.init) ?? bundleIdentifier)
  }



















  var retainedTextWasCopied: Bool {
    snapshot.sessionID != nil && snapshot.sessionID == copiedRetainedSessionID
  }








  nonisolated static let onboardingPracticeElementIdentifier =
    "bestASR.onboarding.practiceEditor"




  func publishASRReadiness(_ ready: Bool) {
    models.modelDiscoveryComplete = true
    // Mindloom Preview: Welcome and Settings may have offered the import
    // before the models in the root were found (finish-ship).
    defer { refreshModelImportOffer() }
    if ready {
      models.modelRuntimeReady = true
      models.modelReadinessMessage =
        enhancedFinalASRReady
        ? "本地语音识别与时间对齐已就绪（自动中文、英文与混输）"
        : "基础识别可用；可在设置中更新增强终稿与时间对齐"
    } else {
      models.modelRuntimeReady = false
      models.modelReadinessMessage =
        "本地语音识别尚未准备；请在设置中完成推荐安装"
    }
    publishIdleReadinessStatus()
  }

  func publishEnhancedASRReadiness(_ ready: Bool) {
    enhancedFinalASRReady = ready
  }

  func publishPolishReadiness(_ ready: Bool) {
    if ready {
      polishRuntimeReady = true
      polishReadinessMessage =
        "本地文字整理已就绪，并启用事实保护"
    } else {
      polishRuntimeReady = false
      polishReadinessMessage =
        "本地文字整理尚未准备；口述仍可使用基础标点"
    }
  }


  func applyDistributionState(
    _ state: ModelDistributionState,
    component: String,
    offset: Double,
    weight: Double
  ) {
    models.recommendedModelProgress = min(
      1,
      offset + state.fractionCompleted * weight
    )
    switch state.phase {
    case .downloading:
      models.recommendedModelProgressMessage =
        "\(component)：正在下载已固定版本 \(Int(state.fractionCompleted * 100))%"
    case .verifying:
      models.recommendedModelProgressMessage = "\(component)：正在校验大小和摘要…"
    case .warming:
      models.recommendedModelProgressMessage = "\(component)：正在准备本地运行时…"
    case .ready:
      models.recommendedModelProgressMessage = "\(component)已就绪，可在本机使用"
    case .retryableFailure:
      models.recommendedModelProgressMessage =
        "\(component)已暂停；重试会继续已校验进度"
    case .incompatible:
      models.recommendedModelProgressMessage =
        "\(component)与当前目录不兼容。请更新 Mindloom。"
    case .consentRequired:
      models.recommendedModelProgressMessage =
        "请接受当前所选模型的许可后再下载"
    }
  }


  /// Whether anyone can actually see history right now: the App is in front
  /// and has a window open. The dictation capsule is a non-activating panel,
  /// so it does not count — during dictation the user is in another App.
  nonisolated static var mainWindowIsVisible: Bool {
    MainActor.assumeIsolated {
      NSApp.isActive && NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
    }
  }



  func presentCaptureWorkspaceHandoff(
    sessionID: SessionID?,
    inputMode: SessionInputMode,
    state: CaptureWorkspaceHandoff.State,
    detail: String,
    organizeEvents: Bool,
    refreshHistory: Bool = true
  ) async {
    guard let sessionID else { return }
    if state == .completed { await enqueueRemoteSessionIfEnabled(sessionID) }
    // A keyboard dictation was reported by the capsule; the window keeps
    // quiet. History still refreshes so the record is there when looked for.
    if inputMode == .dictation, !dictationStartedInApp {
      if refreshHistory { await refreshHistoryItems(organizeEvents: organizeEvents) }
      return
    }
    let provisional = CaptureWorkspaceHandoff(
      sessionID: sessionID,
      inputMode: inputMode,
      state: state,
      title: Self.captureHandoffTitle(inputMode: inputMode, state: state),
      detail: detail,
      sourceDisplayName: inputMode == .importedMedia ? capture.importedFilename : nil,
      sourceAudioRetained: true
    )
    capture.captureWorkspaceHandoff = provisional
    guard refreshHistory else { return }
    await refreshHistoryItems(organizeEvents: organizeEvents)
    guard capture.captureWorkspaceHandoff?.sessionID == sessionID else { return }
    let item = (history.historyItems + history.homeRecentHistoryItems).first(where: {
      $0.sessionID == sessionID
    })
    capture.captureWorkspaceHandoff = CaptureWorkspaceHandoff(
      sessionID: sessionID,
      inputMode: inputMode,
      state: state,
      title: provisional.title,
      detail: detail,
      sourceDisplayName: item?.sourceDisplayName
        ?? provisional.sourceDisplayName,
      sourceAudioRetained: item?.sourceAudioRetained ?? true
    )
  }

  nonisolated static func captureHandoffTitle(
    inputMode: SessionInputMode,
    state: CaptureWorkspaceHandoff.State
  ) -> String {
    let modeTitle: String =
      switch inputMode {
      case .dictation: "口述"
      case .roomMicrophone: "线下录音"
      case .systemAudio: "电脑内录"
      case .importedMedia: "文件导入"
      case .userItem: "添加的内容"
      }
    return switch state {
    case .processing: "\(modeTitle)已保存，等待完成处理"
    case .completed: "\(modeTitle)已完成"
    case .needsAttention: "\(modeTitle)已保留，需要继续处理"
    }
  }

  /// How many records one page of history holds. The list used to be handed
  /// every matching row at once — five thousand of them, each carrying its
  /// text — which made opening the page cost seconds and scrolling it stutter.
  nonisolated static let historyPageSize = 60







  /// This Mac's device identity, or the demo root's own in demo mode.
  nonisolated static func localOriginDeviceID() -> UUID {
    LibraryIdentity.originDeviceID
  }



  var hasActiveCapture: Bool {
    snapshot.phase.isActive
      || capture.roomSnapshot.phase.isActive
      || capture.systemAudioSnapshot.phase.isActive
      || capture.importInProgress
  }





  static func localTextTaskTitle(_ taskID: LocalTextTaskID) -> String {
    switch taskID {
    case .structuredSummary: "摘要"
    case .actionItems: "待办"
    case .chapters: "章节"
    case .decisions: "结论与决定"
    default: taskID.rawValue
    }
  }

  /// The library this launch opens (`MindloomLaunch`): the owner's library
  /// in the product, a separate root named with `-BestASRDataRoot <path>`, a
  /// demo root named with `-MindloomDemoRoot <path>`. A separate or demo root
  /// may not be, contain, or sit inside the owner's library (compared by
  /// file identity); any misspelled, empty, or invalid request, and a
  /// development build started without naming a library, fails the launch
  /// instead of falling back to the owner's library.
  static func applicationDataRoot() throws -> URL {
    let root = try MindloomLaunch.current.get().root
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  static func float32RMS(_ data: Data) -> Double {
    guard data.count >= 4, data.count.isMultiple(of: 4) else { return 0 }
    return data.withUnsafeBytes { raw in
      let count = data.count / 4
      var sum = 0.0
      for index in 0..<count {
        let bits = raw.loadUnaligned(
          fromByteOffset: index * 4,
          as: UInt32.self
        ).littleEndian
        let sample = Double(Float(bitPattern: bits))
        if sample.isFinite { sum += sample * sample }
      }
      return sqrt(sum / Double(max(1, count)))
    }
  }

  static func applicationCacheRoot() throws -> URL {
    try resolveApplicationCacheRoot(
      base: FileManager.default.url(
        for: .cachesDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
    )
  }

  nonisolated static func resolveApplicationCacheRoot(base: URL) throws -> URL {
    let fileManager = FileManager.default
    let root = base.appendingPathComponent(MindloomBuild.cacheFolderName, isDirectory: true)
    let attributes = try? fileManager.attributesOfItem(atPath: root.path)
    if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
      let destination = try fileManager.destinationOfSymbolicLink(atPath: root.path)
      let target = URL(
        fileURLWithPath: destination,
        relativeTo: root.deletingLastPathComponent()
      ).standardizedFileURL
      if externalCacheLinkIsUsable(target, localBase: base) {
        return root
      }
      // A developer-redirected cache on an unmounted volume must never stop
      // capture or dictation. Caches are rebuildable, so use a local sibling
      // and leave the user's link untouched for when the volume returns.
      dictationAppLogger.notice("cache link target unavailable; using local cache")
      let fallback = base.appendingPathComponent(
        MindloomBuild.cacheFolderName + ".local", isDirectory: true)
      try fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)
      return fallback
    }
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  nonisolated static func externalCacheLinkIsUsable(
    _ target: URL,
    localBase: URL
  ) -> Bool {
    guard FileManager.default.fileExists(atPath: target.path) else { return false }
    guard target.path.hasPrefix("/Volumes/") else { return true }
    return externalCacheTargetIsAvailable(target, localBase: localBase)
  }

  nonisolated static func externalCacheTargetIsAvailable(
    _ target: URL,
    localBase: URL
  ) -> Bool {
    guard FileManager.default.fileExists(atPath: target.path) else { return false }
    let targetVolume = try? target.resourceValues(
      forKeys: [.volumeUUIDStringKey]
    ).volumeUUIDString
    let localVolume = try? localBase.resourceValues(
      forKeys: [.volumeUUIDStringKey]
    ).volumeUUIDString
    guard let targetVolume, let localVolume else { return false }
    return targetVolume != localVolume
  }






}

/// `SMAppService.mainApp` for `LoginItemRepair` (MindloomLibrary).
struct MainAppLoginItem: LoginItemService {
  var status: LoginItemRepair.Status {
    switch SMAppService.mainApp.status {
    case .enabled: .enabled
    case .requiresApproval: .requiresApproval
    case .notRegistered: .notRegistered
    case .notFound: .notFound
    @unknown default: .notFound
    }
  }

  func register() throws { try SMAppService.mainApp.register() }
  func unregister() throws { try SMAppService.mainApp.unregister() }
}
