import AppKit

/// The Services menu item 「收进织机」 for selected text (V8 contract A1). The
/// system hands over the selection on this App's pasteboard argument; it is
/// taken in like a paste, with the App the text came from as its source.
@MainActor
final class MindloomServicesProvider: NSObject {
  static let shared = MindloomServicesProvider()

  /// `NSMessage` `addToMindloom` in Info.plist.
  @objc func addToMindloom(
    _ pasteboard: NSPasteboard, userData: String?,
    error: AutoreleasingUnsafeMutablePointer<NSString?>
  ) {
    let text =
      pasteboard.string(forType: .string)
      ?? pasteboard.readObjects(forClasses: [NSAttributedString.self])?
      .compactMap { ($0 as? NSAttributedString)?.string }.first
    guard let text, !text.isEmpty else {
      error.pointee = "选中的内容里没有文字" as NSString
      return
    }
    if let model = EntryHub.shared.model, model.entries.isReady {
      model.receiveServicesText(text)
      return
    }
    // The system just started 织机 for this: take it once the library is open.
    Task {
      await EntryHub.shared.readyModel()?.receiveServicesText(text)
    }
  }
}
