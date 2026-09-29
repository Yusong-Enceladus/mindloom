import AppKit
import BestASRAudioJournal
import BestASRDictation
import BestASRDomain
import BestASRFluidRuntime
import BestASRInference
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
import Combine
import CoreGraphics
import CryptoKit
import Foundation
import OSLog
import ServiceManagement
import UniformTypeIdentifiers

/// PeopleModel: the people state, moved out of DictationAppModel without change.
/// Behaviour still lives on DictationAppModel+*.swift and reaches this
/// state as `people.<property>`; moving it here concern by concern is the
/// next step. See DICTATION_ARCHITECTURE.md §13.5.
@MainActor
final class PeopleModel: ObservableObject {
  @Published var speakerRuntimeReady = false

  @Published var speakerReadinessMessage =
    "尚未安装本地多人识别组件"

  @Published var selectedSessionSpeakers: [SessionSpeakerSummary] = []

  @Published var personSummaries: [PersonSummary] = []

  @Published var personReviewCandidates: [PersonReviewCandidateSummary] = []

  @Published var selectedPersonID: PersonID?

  @Published var selectedPersonOccurrences: [SpeakerOccurrenceSummary] = []

  @Published var personNameDraft = ""

  @Published var personAliasesDraft = ""

  @Published var mergeTargetPersonID: PersonID?

  @Published var peopleStatusMessage = "人物资料只保存在这台 Mac 上"

  @Published var splitPersonNameDraft = ""

  @Published var speakerNameDrafts: [SessionSpeakerID: String] = [:]

  @Published var speakerIdentityStatusMessage = ""

  /// The personal cleanup model is this user's own and is faithful by
  /// construction, so it is on when installed; this switch turns it off.
  @Published var personalCleanupEnabled = LocalPreferenceStore.bool(
    "preferences.personal-cleanup-enabled",
    default: true
  )

  @Published var speakerMemoryEnabled = LocalPreferenceStore.bool(
    "preferences.speaker-memory-enabled",
    default: true
  )
}
