import Foundation

extension DictationAppModel {
  /// Opens the library's lookup folder and the Keychain search keys
  /// (「从网络补充信息」 stays off until the owner turns it on).
  func configureWebLookup(dataRoot: URL) {
    guard !BestASRProcessEnvironment.isXCTestHost else { return }
    webLookup.timeZone = productTimeZone
    webLookup.configure(dataRoot: dataRoot)
  }
}
