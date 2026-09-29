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

/// SpokenModel: the spoken state, moved out of DictationAppModel without change.
/// Behaviour still lives on DictationAppModel+*.swift and reaches this
/// state as `spoken.<property>`; moving it here concern by concern is the
/// next step. See DICTATION_ARCHITECTURE.md §13.5.
@MainActor
final class SpokenModel: ObservableObject {
  /// The languages 翻译 can aim at, in the order ⇧ cycles through them. Their
  /// names are what the model is told, so they are names rather than codes.
  @Published var translationTargetLanguageNames =
    DictationAppModel.storedTranslationLanguages()
  {
    didSet {
      LocalPreferenceStore.defaults.set(
        translationTargetLanguageNames, forKey: DictationAppModel.translationLanguageKey)
      languagesChanged?()
    }
  }

  /// The app model recomputes the active language here, because which one
  /// is active depends on the dictation in flight, which it owns.
  var languagesChanged: (() -> Void)?

  /// The one the running dictation is aimed at, for the capsule to name.
  @Published var activeTranslationLanguage =
    DictationAppModel.storedTranslationLanguages().first ?? "英语"

  /// Whether the system's translation engine is ready for each target the
  /// user chose, so Settings can say so and offer the one-time install.
  @Published var translationEngineStatus: [String: AppleTranslation.Availability] = [:]

  @Published var interfaceLanguageID = "zh-Hans" {
    didSet {
      LocalPreferenceStore.defaults.set(
        interfaceLanguageID,
        forKey: "preferences.interface-language"
      )
    }
  }
}
