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

/// HotkeysModel: the hotkeys state, moved out of DictationAppModel without change.
/// Behaviour still lives on DictationAppModel+*.swift and reaches this
/// state as `hotkeys.<property>`; moving it here concern by concern is the
/// next step. See DICTATION_ARCHITECTURE.md §13.5.
@MainActor
final class HotkeysModel: ObservableObject {
  @Published var startEndHotkeyPresetID = "option-space"

  @Published var startEndHotkeyBinding =
    DictationHotkeyConfiguration.defaultAlpha.startOrEnd

  @Published var hotkeyStatusMessage =
    "口述快捷键"

  @Published var globeKeyConflictsWithStartShortcut = false
}
