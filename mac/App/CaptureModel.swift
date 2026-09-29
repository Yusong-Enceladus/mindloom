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

/// CaptureModel: the capture state, moved out of DictationAppModel without change.
/// Behaviour still lives on DictationAppModel+*.swift and reaches this
/// state as `capture.<property>`; moving it here concern by concern is the
/// next step. See DICTATION_ARCHITECTURE.md §13.5.
@MainActor
final class CaptureModel: ObservableObject {
  @Published var microphonePermission: DictationPermissionState =
    .notDetermined

  @Published var systemAudioPermission: DictationPermissionState =
    .notDetermined

  @Published var roomSnapshot = DictationSessionSnapshot()

  @Published var roomStatusMessage = "选择麦克风后开始线下录音"

  @Published var roomLiveTranscriptText = ""

  @Published var roomLiveTranscriptStatus =
    "录音开始后会显示本机实时逐字稿"

  @Published var roomMicrophoneDevices: [MicrophoneDeviceInfo] = []

  @Published var selectedRoomMicrophoneUID = LocalPreferenceStore.string(
    "preferences.room-microphone-uid",
    default: ""
  ) {
    didSet {
      LocalPreferenceStore.defaults.set(
        selectedRoomMicrophoneUID,
        forKey: "preferences.room-microphone-uid"
      )
    }
  }

  @Published var roomInputLevel = 0.0

  @Published var roomLevelPreviewActive = false

  @Published var systemAudioSnapshot = DictationSessionSnapshot()

  @Published var systemAudioSources: [SystemAudioSource] = []

  @Published var selectedSystemAudioSourceID = LocalPreferenceStore.string(
    "preferences.system-audio-source",
    default: "entire-system"
  ) {
    didSet {
      LocalPreferenceStore.defaults.set(
        selectedSystemAudioSourceID,
        forKey: "preferences.system-audio-source"
      )
    }
  }

  @Published var selectedSystemMicrophoneUID = LocalPreferenceStore.string(
    "preferences.system-audio-microphone-uid",
    default: ""
  ) {
    didSet {
      LocalPreferenceStore.defaults.set(
        selectedSystemMicrophoneUID,
        forKey: "preferences.system-audio-microphone-uid"
      )
    }
  }

  @Published var systemAudioStatusMessage =
    "选择一个正在发声的应用，或录制整个 Mac 的输出"

  @Published var systemAudioLiveTranscriptText = ""

  @Published var systemAudioLiveTranscriptStatus =
    "录制开始后会显示本机实时逐字稿"

  @Published var systemAudioSourceContextMessage = ""

  @Published var systemAudioPreviewLevel = 0.0

  @Published var systemAudioPreviewActive = false

  @Published var captureWorkspaceHandoff: CaptureWorkspaceHandoff?

  @Published var importInProgress = false

  @Published var importPaused = false

  @Published var importPauseControlAvailable = false

  @Published var importCanDiscard = false

  @Published var importProgress = 0.0

  @Published var importStatusMessage =
    "支持 WAV、M4A、MP3、AAC、MP4、MOV 和 FLAC；原始文件会保留在本机"

  @Published var importedFilename: String?

  @Published var storageSourceAudioBytes: [SessionInputMode: UInt64] = [:]
}
