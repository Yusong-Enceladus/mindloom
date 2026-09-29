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

extension DictationAppModel {
  /// A correction typed in a transcript becomes a dictionary draft: history
  /// supplies the two texts, the dictionary takes the draft.
  func addCorrectionToDictionary() {
    let original = history.correctionOriginalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    let replacement = history.correctionReplacementDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !original.isEmpty, !replacement.isEmpty else {
      history.detailStatusMessage = "请输入原识别写法和正确写法"
      return
    }
    dictionary.beginEntry(fromCorrection: original, corrected: replacement)
    history.correctionOriginalDraft = ""
    history.correctionReplacementDraft = ""
    history.detailStatusMessage = "纠错已带入词典草稿；到“词典”确认保存后，可重新识别或整理"
  }
}
