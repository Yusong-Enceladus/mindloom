import Foundation
import MindloomDesign
import MindloomTaglines
import SwiftUI

// The brand's taglines on the Mac (docs/TAGLINES.md): the welcome window's
// first screen (the line large, a quotation's source small below) and the
// foot of the main window's sidebar (quiet, above 设置). Which line shows is
// `MindloomTaglines.TaglineRotation`'s; the App asks `MindloomTaglineBoard`
// when a surface comes on screen and passes the line in.

/// One line of the curated sets.
public typealias MindloomTagline = Tagline

/// The App's door to the taglines.
public struct MindloomTaglineBoard {
  private let store: TaglineStore

  /// `defaults`: the App's own preferences (the install's place in the
  /// rotation is kept there).
  public init(defaults: UserDefaults) {
    store = TaglineStore(defaults: defaults)
  }

  /// The line for a surface coming on screen now, in the set of the App's
  /// interface language, counted in the product time zone; records the
  /// showing (the first one starts the install with the line marked first).
  public func line(now: Date = Date(), zone: TimeZone, interfaceLanguage: String)
    -> MindloomTagline?
  {
    store.show(TaglineLanguage(interfaceLanguage: interfaceLanguage), now: now, zone: zone)
  }

  /// The line a new install shows first (still images; nothing recorded).
  public static func first(interfaceLanguage: String) -> MindloomTagline? {
    TaglineCatalog.bundled.first(TaglineLanguage(interfaceLanguage: interfaceLanguage))
  }

  /// A bundled line by id (still images).
  public static func line(id: String) -> MindloomTagline? {
    TaglineCatalog.bundled.line(id: id)
  }
}

enum TaglineAttribution {
  /// A quotation's source as shown: the Chinese dash run straight into the
  /// name, the English one with a space.
  static func text(_ line: MindloomTagline) -> String? {
    guard let source = line.shownSource else { return nil }
    switch line.language {
    case .zh: return "\u{2014}\u{2014}\(source)"
    case .en: return "\u{2014} \(source)"
    }
  }

  static func accessibilityLabel(_ line: MindloomTagline) -> String {
    [line.text, line.shownSource].compactMap { $0 }.joined(separator: " ")
  }
}

/// Welcome's line: 17/26 `ink`, balanced and centred in the 552 pt column
/// (a Chinese line stays on one line, an English one takes at most two); a
/// quotation's source in `foot` `ink2`, 8 below.
struct WelcomeTagline: View {
  let line: MindloomTagline

  var body: some View {
    VStack(spacing: 8) {
      BalancedText(line.text, size: 17, maxWidth: 552, alignment: .center)
        .mlFont(style: MLTextStyle(size: 17, weight: .regular, lineHeight: 26), lineBox: true)
        .foregroundStyle(MLColor.ink)
        .multilineTextAlignment(.center)
      if let source = TaglineAttribution.text(line) {
        Text(source).mlFont(\.foot).foregroundStyle(MLColor.ink2)
          .multilineTextAlignment(.center)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(TaglineAttribution.accessibilityLabel(line))
  }
}

/// The sidebar's quiet line above 设置: `foot` in `ink3`, balanced in 192 pt
/// from the rows' text edge; a quotation's source in `caption` `ink3` below.
/// It scrolls nothing and moves no row: the sidebar's free space takes it.
struct SidebarTagline: View {
  let line: MindloomTagline

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      BalancedText(line.text, size: 12, maxWidth: 192, alignment: .leading)
        .mlFont(\.foot)
        .foregroundStyle(MLColor.ink3)
      if let source = TaglineAttribution.text(line) {
        BalancedText(source, size: 11, maxWidth: 192, alignment: .leading)
          .mlFont(\.caption)
          .foregroundStyle(MLColor.ink3)
      }
    }
    .padding(.leading, 10)
    .padding(.trailing, 8)
    .padding(.bottom, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(TaglineAttribution.accessibilityLabel(line))
    .accessibilityIdentifier("mindloom.sidebar.tagline")
  }
}
