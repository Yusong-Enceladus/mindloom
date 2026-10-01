import AppIntents
import BestASREntries
import Foundation

/// Shortcuts (V8 contract A2): 「添加到织机」 takes text, a file or a link in
/// through the same intake rules as a paste (a link is kept as text and never
/// opened); 「织机：今天到期」 reads today's steps from this Mac, read-only.
/// Both answer "关闭" when the owner switched Shortcuts off in 设置 → 入口.
struct AddToMindloomIntent: AppIntent {
  static let title: LocalizedStringResource = "添加到织机"
  static let description = IntentDescription("把文字、文件或链接收进织机。链接只记下，不会打开。")
  static let openAppWhenRun = false

  @Parameter(title: "文字")
  var text: String?

  @Parameter(title: "文件")
  var file: IntentFile?

  @Parameter(title: "链接")
  var link: URL?

  static var parameterSummary: some ParameterSummary {
    Summary("把 \(\.$text) 添加到织机") {
      \.$file
      \.$link
    }
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
    guard let model = await EntryHub.shared.readyModel() else {
      let message = "织机还没有准备好，请打开织机后再试"
      return .result(value: message, dialog: "\(message)")
    }
    let attachment = file.map { ($0.data, $0.filename, $0.type?.identifier) }
    let message = await model.addFromShortcut(text: text, url: link, file: attachment)
    return .result(value: message, dialog: "\(message)")
  }
}

struct DueTodayIntent: AppIntent {
  static let title: LocalizedStringResource = "织机：今天到期"
  static let description = IntentDescription("列出今天到期和已经过期的下一步。只读，只在这台 Mac 上。")
  static let openAppWhenRun = false

  @Parameter(title: "往后看几天", default: 0, inclusiveRange: (0, 30))
  var days: Int

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
    guard let model = await EntryHub.shared.readyModel() else {
      let message = "织机还没有准备好，请打开织机后再试"
      return .result(value: message, dialog: "\(message)")
    }
    guard model.entries.isOn(.shortcuts) else {
      let message = "快捷指令入口已在织机的 设置 → 入口 里关闭"
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
      phrases: ["添加到\(.applicationName)", "用\(.applicationName)收进来"],
      shortTitle: "添加到织机", systemImageName: "tray.and.arrow.down")
    AppShortcut(
      intent: DueTodayIntent(),
      phrases: ["\(.applicationName)今天到期", "\(.applicationName)今天有什么到期"],
      shortTitle: "今天到期", systemImageName: "calendar.badge.clock")
  }
}
