import AppIntents
import BestASREntries
import Foundation

/// Shortcuts (V8 contract A2): 「添加到 Mindloom」 takes text, a file or a link
/// in through the same intake rules as a paste (a link is kept as text and
/// never opened); 「Mindloom：今天到期」 reads today's steps. Both answer that
/// Shortcuts is off unless the owner switched it on in 设置 › 入口: any
/// program on this Mac can run a shortcut, so it is off by default (v12 F10).
struct AddToMindloomIntent: AppIntent {
  static let title: LocalizedStringResource = "添加到 Mindloom"
  static let description = IntentDescription("将文字、文件或链接添加到 Mindloom。链接按文字添加。")
  static let openAppWhenRun = false

  @Parameter(title: "文字")
  var text: String?

  @Parameter(title: "文件")
  var file: IntentFile?

  @Parameter(title: "链接")
  var link: URL?

  static var parameterSummary: some ParameterSummary {
    Summary("把 \(\.$text) 添加到 Mindloom") {
      \.$file
      \.$link
    }
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
    guard let model = await EntryHub.shared.readyModel() else {
      let message = "Mindloom 尚未就绪。请打开 Mindloom 后重试。"
      return .result(value: message, dialog: "\(message)")
    }
    let attachment = file.map { ($0.data, $0.filename, $0.type?.identifier) }
    let message = await model.addFromShortcut(text: text, url: link, file: attachment)
    return .result(value: message, dialog: "\(message)")
  }
}

struct DueTodayIntent: AppIntent {
  static let title: LocalizedStringResource = "Mindloom：今天到期"
  static let description = IntentDescription("列出今天到期和已过期的下一步。")
  static let openAppWhenRun = false

  @Parameter(title: "向后查看的天数", default: 0, inclusiveRange: (0, 30))
  var days: Int

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
    guard let model = await EntryHub.shared.readyModel() else {
      let message = "Mindloom 尚未就绪。请打开 Mindloom 后重试。"
      return .result(value: message, dialog: "\(message)")
    }
    guard model.entries.isOn(.shortcuts) else {
      let message = EntryKind.shortcutsOffMessage
      return .result(value: message, dialog: "\(message)")
    }
    let (heading, lines) = await model.dueText(days: days)
    let text = ([heading] + lines).joined(separator: "\n")
    return .result(value: text, dialog: "\(text)")
  }
}

struct MindloomShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: AddToMindloomIntent(),
      phrases: ["添加到\(.applicationName)", "用\(.applicationName)添加"],
      shortTitle: "添加到 Mindloom", systemImageName: "tray.and.arrow.down")
    AppShortcut(
      intent: DueTodayIntent(),
      phrases: ["\(.applicationName)今天到期", "\(.applicationName)今天有什么到期"],
      shortTitle: "今天到期", systemImageName: "calendar.badge.clock")
  }
}
