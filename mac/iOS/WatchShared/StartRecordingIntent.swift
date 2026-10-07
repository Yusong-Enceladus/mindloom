import AppIntents
import Foundation

/// 「录音」: opens Mindloom on Apple Watch and starts recording at once (WATCH-006). Used by the
/// control (Control Center, the Smart Stack, the Action button on Apple Watch Ultra), Siri and
/// Shortcuts. It runs in the app, in the foreground: watchOS only lets recording start there.
struct StartRecordingIntent: AppIntent {
  static let title: LocalizedStringResource = "录音"
  static let description: IntentDescription? = IntentDescription("在 Apple Watch 上用 Mindloom 开始录音。")
  static let supportedModes: IntentModes = .foreground(.immediate)

  @MainActor
  func perform() async throws -> some IntentResult {
    RecordRequest.post()
    return .result()
  }
}

/// Hands a start request to the app's recorder. The app sets `handler` at launch; a request that
/// comes before is kept in `pending` and taken when the screen appears.
@MainActor
enum RecordRequest {
  static var handler: (() -> Void)?
  static var pending = false

  static func post() {
    if let handler {
      handler()
    } else {
      pending = true
    }
  }

  /// The complication's link (`widgetURL`).
  static let url = URL(string: "mindloom://record")!

  static func isRecordURL(_ url: URL) -> Bool {
    url.scheme == "mindloom" && url.host() == "record"
  }
}
