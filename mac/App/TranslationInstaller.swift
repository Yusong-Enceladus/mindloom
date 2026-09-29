import AppKit
import OSLog
import SwiftUI
import Translation

private let translationInstallerLogger = Logger(
  subsystem: "com.bestasr.app",
  category: "translation"
)

/// Gets a language pair installed, through the system's own download prompt.
///
/// The prompt only exists on a view. A session made without one — the
/// headless `TranslationSession(installedSource:target:)` — throws
/// `notInstalled` from `prepareTranslation()` and shows nothing; that is what
/// the earlier "下载语言" button did, which is why no language was ever
/// installed. So this puts up one small window whose only content carries the
/// `translationTask` modifier, and the system drops its sheet from there.
///
/// It is asked for in three places, all of them after the fact: when a
/// dictation aimed at a language that is not installed has already been
/// written in as spoken, when a language is added in Settings, and from the
/// status line in Settings. Never during a dictation: the sheet would take the
/// keyboard from the field the user is dictating into.
@MainActor
final class TranslationInstaller: ObservableObject {
  @Published private(set) var request: Request?

  struct Request: Identifiable, Equatable {
    let id = UUID()
    let sourceName: String
    let targetName: String
    let source: Locale.Language
    let target: Locale.Language
  }

  private var window: NSWindow?
  private var completion: ((Bool) -> Void)?

  /// Asks the system to install `source → target`. Returns once the user has
  /// answered the prompt and the download finished, or declined.
  func install(fromLanguageNamed source: String, intoLanguageNamed target: String) async -> Bool {
    guard #available(macOS 15.0, *),
      request == nil,
      let sourceLocale = AppleTranslation.locale(for: source),
      let targetLocale = AppleTranslation.locale(for: target)
    else { return false }
    return await withCheckedContinuation { continuation in
      completion = { continuation.resume(returning: $0) }
      request = Request(
        sourceName: source, targetName: target,
        source: sourceLocale, target: targetLocale)
      present()
    }
  }

  private func present() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 140),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "翻译"
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: TranslationInstallHost(installer: self))
    window.center()
    window.setAccessibilityIdentifier("bestASR.translationInstall")
    self.window = window
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  fileprivate func finish(_ installed: Bool) {
    translationInstallerLogger.notice(
      "language install \(installed ? "completed" : "declined", privacy: .public)")
    window?.close()
    window = nil
    request = nil
    completion?(installed)
    completion = nil
  }
}

private struct TranslationInstallHost: View {
  @ObservedObject var installer: TranslationInstaller

  var body: some View {
    VStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      Text(
        installer.request.map { "正在准备 \($0.sourceName) → \($0.targetName) 翻译" }
          ?? "正在准备翻译"
      )
      .font(.body)
      Text("语言包由 macOS 下载并保管，只下载这一次。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(24)
    .frame(width: 360, height: 140)
    .modifier(TranslationInstallTask(installer: installer))
  }
}

/// The part that needs macOS 15: the modifier that owns the system prompt.
private struct TranslationInstallTask: ViewModifier {
  @ObservedObject var installer: TranslationInstaller

  func body(content: Content) -> some View {
    if #available(macOS 15.0, *) {
      // The session is not Sendable and the installer lives on the main
      // actor; the closure captures only a Sendable callback so the session
      // never has to cross an isolation boundary.
      let installer = installer
      let finish: @Sendable (Bool) -> Void = { installed in
        Task { @MainActor in installer.finish(installed) }
      }
      content.translationTask(configuration) { @Sendable session in
        do {
          try await session.prepareTranslation()
          finish(true)
        } catch {
          finish(false)
        }
      }
    } else {
      content
    }
  }

  @available(macOS 15.0, *)
  private var configuration: TranslationSession.Configuration? {
    installer.request.map {
      TranslationSession.Configuration(source: $0.source, target: $0.target)
    }
  }
}
