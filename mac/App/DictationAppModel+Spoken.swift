import AppKit
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
import Combine
import CoreGraphics
import CryptoKit
import Foundation
import OSLog
import ServiceManagement
import UniformTypeIdentifiers

// Spoken: moved out of DictationAppModel.swift without change; see
// DICTATION_ARCHITECTURE.md §13.5.
extension DictationAppModel {
  @MainActor static func storedTranslationLanguages() -> [String] {
    let stored =
      LocalPreferenceStore.defaults.stringArray(forKey: translationLanguageKey) ?? []
    let valid = stored.filter(translationLanguageNames.contains)
    return valid.isEmpty ? ["英语"] : Array(valid.prefix(maximumTranslationLanguages))
  }

  /// Adds or removes one target language, keeping the ring within its limit.
  func toggleTranslationLanguage(_ name: String) {
    var chosen = spoken.translationTargetLanguageNames
    if let index = chosen.firstIndex(of: name) {
      guard chosen.count > 1 else { return }
      chosen.remove(at: index)
    } else {
      guard chosen.count < Self.maximumTranslationLanguages else { return }
      chosen.append(name)
    }
    spoken.translationTargetLanguageNames = chosen
    // Adding a language is the moment to get its pack, like adding a
    // keyboard: the system asks once, here, instead of the first dictation
    // aimed at it going in untranslated.
    if spoken.translationEngineStatus[name] == .downloadable {
      installTranslationLanguage(name)
    }
  }

  func refreshTranslationEngineStatus() {
    let targets = spoken.translationTargetLanguageNames
    Task { [weak self] in
      var statuses: [String: AppleTranslation.Availability] = [:]
      for target in targets {
        statuses[target] = await AppleTranslation.availability(
          fromLanguageNamed: Self.translationSource(for: target),
          intoLanguageNamed: target
        )
      }
      self?.spoken.translationEngineStatus = statuses
    }
  }

  /// Whether the system engine is ready for `language`. Unknown counts as
  /// ready: the status is refreshed at launch and on every change, and a
  /// caption that cried "not installed" before the answer came back would be
  /// wrong more often than right.
  func translationEngineReady(for language: String) -> Bool {
    spoken.translationEngineStatus[language].map { $0 == .installed } ?? true
  }

  /// Applies a chord to the dictation it belongs to.
  ///
  /// Fn with another key normally means the user wanted a combination macOS
  /// owns — Fn Delete, Fn arrows — so the dictation Fn just started is thrown
  /// away. Two chords mean something here instead.
  func handleFunctionChord(keyCode: UInt32?) {
    guard let mode = Self.spokenMode(forChord: keyCode) else {
      cancelDictationStartedByFunctionChord()
      return
    }
    beginSpokenMode(mode)
  }

  nonisolated static func spokenMode(forChord keyCode: UInt32?) -> DictationSpokenMode? {
    switch keyCode {
    case CarbonHotkeyBackend.spaceKeyCode: .command
    case CarbonHotkeyBackend.leftShiftKeyCode, CarbonHotkeyBackend.rightShiftKeyCode:
      .translate
    default: nil
    }
  }

  /// Switches the dictation in flight into a mode, at any point before it is
  /// delivered: pressing the chord as you start and pressing it as you finish
  /// both mean the same thing, and the second is how you decide after hearing
  /// yourself say it. Pressing ⇧ again while already translating moves to the
  /// next language you chose in Settings.
  func beginSpokenMode(_ mode: DictationSpokenMode) {
    // A chord only means something while a dictation is actually happening —
    // including one whose start command is still in flight, which is the
    // common case, since the chord follows the key press by milliseconds.
    guard snapshot.phase.isActive || lifecycleCommands.inFlightMode == .dictation
    else { return }
    var plan = spokenModePlan ?? SpokenModePlan(mode: mode)
    if plan.mode == .translate, mode == .translate, spokenModePlan != nil {
      plan.languageIndex += 1
    }
    plan.mode = mode
    if mode == .command, plan.selection == nil {
      // Read it now, while the app the user is working in is still in front
      // and the highlight is still theirs.
      plan.selection = targetReader?.selectedText()
    }
    spokenModePlan = plan
    dictationMode = mode
    spoken.activeTranslationLanguage = Self.translationLanguage(
      at: plan.languageIndex, among: spoken.translationTargetLanguageNames)
    liveTranscriptStatus = spokenModeStatus(mode, hasSelection: plan.selection != nil)
    statusMessage = liveTranscriptStatus
    renderRecordingPanel()
    dictationAppLogger.notice(
      "dictation mode set mode=\(mode.rawValue, privacy: .public) selection=\(plan.selection != nil, privacy: .public)"
    )
  }

  /// Where "翻译一下" goes when no language is named: into the first chosen
  /// target, unless the highlight is already in that language, in which case
  /// back into Chinese — the language the user dictates in.
  nonisolated static func defaultTranslationTarget(
    forSelection selection: String,
    chosen: [String]
  ) -> String {
    let target = chosen.first ?? translationLanguageNames[0]
    guard let detected = AppleTranslation.detectedLanguage(of: selection),
      let targetLocale = AppleTranslation.locale(for: target),
      detected.minimalIdentifier == targetLocale.minimalIdentifier
    else { return target }
    return "简体中文"
  }

  nonisolated static func translationLanguage(
    at index: Int,
    among chosen: [String]
  ) -> String {
    guard !chosen.isEmpty else { return translationLanguageNames[0] }
    return chosen[((index % chosen.count) + chosen.count) % chosen.count]
  }

  nonisolated static func spokenModeStatus(
    _ mode: DictationSpokenMode,
    hasSelection: Bool,
    language: String
  ) -> String {
    switch mode {
    case .dictate: "音频会先安全保存，再进行本地识别"
    case .translate: "说完写入\(language)"
    case .command: hasSelection ? "说出要对选中文字做的事" : "说出要它做的事"
    }
  }

  func spokenModeStatus(
    _ mode: DictationSpokenMode, hasSelection: Bool
  ) -> String {
    Self.spokenModeStatus(
      mode, hasSelection: hasSelection, language: spoken.activeTranslationLanguage)
  }

  /// Shows an answer that had nowhere to be written.
  ///
  /// A 指令 is delivered into the field the caret is in, exactly like a
  /// dictation. Only when that field will not take it — read-only text, a
  /// PDF, nothing focused at all — is the answer shown instead, which is the
  /// rule Typeless states: rewrite editable text, answer questions about
  /// read-only text.
  func presentSpokenAnswer(_ answer: String, question: String, sessionID: SessionID) {
    answeredSessionIDs.insert(sessionID)
    IntakePasteboardMarks.writeOwnText(answer, to: .general)
    copiedRetainedSessionID = sessionID
    copiedRetainedTextWasDraft = false
    spokenAnswerPanel.present(answer: answer, question: question)
  }

  func cancelDictationStartedByFunctionChord() {
    guard let started = functionHoldStartedAt else { return }
    functionHoldStartedAt = nil
    guard ContinuousClock.now - started < Self.functionChordWindow,
      [.preparing, .recording].contains(snapshot.phase)
    else { return }
    dictationAppLogger.info("fn chord cancelled the dictation it started")
    cancel()
  }

  func performLifecycleCommand(
    mode: CaptureLifecycleCommandState.Mode,
    intent: CaptureLifecycleCommandState.Action,
    preparation: (@MainActor () -> Void)? = nil,
    operation: @escaping @MainActor () async -> Void
  ) {
    guard lifecycleCommands.begin(mode, action: intent) else {
      dictationAppLogger.info("overlapping lifecycle command suppressed")
      return
    }
    preparation?()
    Task { [weak self] in
      guard let self else { return }
      await operation()
      let deferred = lifecycleCommands.finish(mode)
      applyDeferredLifecycleAction(deferred, for: mode)
    }
  }
}
