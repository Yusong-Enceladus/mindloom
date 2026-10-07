import BestASRMemory
import MindloomDesign
import SwiftUI

/// Who builds a surface (FOUNDATION.md's ownership map).
public enum MindloomOwner: String, Sendable {
  case foundation = "mac-foundation"
  case home = "mac-home"
  case matter = "mac-matter"
  case capture = "mac-capture"
}

/// A surface not built yet: its ID, name and owner, drawn quietly where the
/// surface goes, so a snapshot shows what is missing. Each agent replaces
/// the placeholder in its own file with the real view; the file and the
/// view's name and input type stay.
public struct MindloomPlaceholder: View {
  let surface: String
  let title: String
  let owner: MindloomOwner
  let detail: String

  public init(_ surface: String, _ title: String, owner: MindloomOwner, detail: String = "") {
    self.surface = surface
    self.title = title
    self.owner = owner
    self.detail = detail
  }

  public var body: some View {
    VStack(spacing: 6) {
      Text("\(surface) · \(title)").mlFont(\.headline).foregroundStyle(MLColor.ink2)
      Text(owner.rawValue).mlFont(\.foot).foregroundStyle(MLColor.ink3)
      if !detail.isEmpty {
        Text(detail).mlFont(\.foot).foregroundStyle(MLColor.ink3).multilineTextAlignment(.center)
          .frame(maxWidth: 420)
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, minHeight: 120)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(MLColor.rule2, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    )
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("mindloom.placeholder.\(surface)")
  }
}

/// A plain, working row for placeholders: the title and its second line;
/// clicking opens the matter. Pages replace it with their own rows.
public struct PlaceholderMatterRow: View {
  let context: MindloomPageContext
  let matter: MatterDigest

  public init(context: MindloomPageContext, matter: MatterDigest) {
    self.context = context
    self.matter = matter
  }

  public var body: some View {
    Button {
      context.navigator.openMatter(matter.eventID)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        FadingLine(MLAutospace.apply(matter.title)).mlFont(\.headline)
        FadingLine(MLAutospace.apply(matter.status)).mlFont(\.sub).foregroundStyle(MLColor.ink2)
      }
      .padding(.vertical, 8)
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
      .contentShape(RoundedRectangle(cornerRadius: 10))
    }
    .buttonStyle(.plain)
  }
}
