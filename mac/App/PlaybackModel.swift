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

/// PlaybackModel: the playback state, moved out of DictationAppModel without change.
/// Behaviour still lives on DictationAppModel+*.swift and reaches this
/// state as `playback.<property>`; moving it here concern by concern is the
/// next step. See DICTATION_ARCHITECTURE.md §13.5.
@MainActor
final class PlaybackModel: ObservableObject {
  @Published var playbackTrackIDs: [String] = []

  @Published var playbackTrackRoles: [String: SourceTrackRole] = [:]

  @Published var selectedHistoryPlaybackTrackID = ""

  @Published var playbackPosition = 0.0

  @Published var playbackDuration = 0.0

  @Published var playbackIsPlaying = false

  @Published var playbackOperationInProgress = false

  @Published var playbackStatusMessage = ""

  @Published var waveformSamples: [Float] = []

  /// Where playback of one stretch (a voice to confirm) pauses by itself.
  struct StopPoint: Equatable {
    let sessionID: SessionID
    let position: Double
  }

  /// Set by the memory pages' play-a-stretch; any other seek or play clears it.
  var stopAt: StopPoint?
}
