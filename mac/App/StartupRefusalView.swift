import MindloomDesign
import SwiftUI

/// The window when the library did not open (a development build started
/// without naming one, a demo root without the marker, a failed backup
/// before a migration): what happened and what to do, in place of the pages.
struct StartupRefusalView: View {
  let message: String

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("无法打开资料库").mlFont(\.title2).foregroundStyle(MLColor.ink)
        .accessibilityAddTraits(.isHeader)
      Text(message).mlFont(\.body).foregroundStyle(MLColor.ink2)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
    .frame(maxWidth: 520, alignment: .leading)
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(MLColor.paper)
    .accessibilityIdentifier("bestASR.startupFailure")
  }
}
