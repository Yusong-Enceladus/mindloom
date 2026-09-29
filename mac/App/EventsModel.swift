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

/// EventsModel: the events state, moved out of DictationAppModel without change.
/// Behaviour still lives on DictationAppModel+*.swift and reaches this
/// state as `events.<property>`; moving it here concern by concern is the
/// next step. See DICTATION_ARCHITECTURE.md §13.5.
@MainActor
final class EventsModel: ObservableObject {
  @Published var summaries: [EventSummary] = []

  @Published var candidates: [EventCandidate] = []

  @Published var selectedEventID: EventID?

  @Published var titleDraft = ""

  @Published var notesDraft = ""

  @Published var newEventTitleDraft = ""

  @Published var sessionSelection = Set<SessionID>()

  @Published var mergeTargetEventID: EventID?

  @Published var moveTargetEventID: EventID?

  @Published var addSessionID: SessionID?

  @Published var textDocuments: [EventTextDocumentRecord] = []

  @Published var documentTextDrafts: [UUID: String] = [:]

  @Published var generatingEventDocumentTaskID: LocalTextTaskID?

  @Published var eventStatusMessage =
    "事件会在本机按语义、人物、时间和来源整理"

  @Published var organizationInProgress = false

  @Published var remoteProjection: RemoteOrganizerProjection?

  @Published var remoteStatusMessage = "整理设备链路已关闭；使用这台 Mac 整理"

  /// The organizer's clock mode from its health check (`wall` in production).
  @Published var remoteServiceClock: String?

  @Published var activeEventReviewCandidateID: EventCandidateID?
}
