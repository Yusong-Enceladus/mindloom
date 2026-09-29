import BestASRMemory
import SwiftUI

/// A person as a circle: their initial on a 15% tint of their voice colour,
/// or a dashed "?" while nobody named them.
struct Avatar: View {
  @Environment(\.zhiji) private var palette
  let name: String
  let isNamed: Bool
  let colorIndex: Int
  var size: CGFloat = 56
  /// A ring in the background colour, for overlapping stacks.
  var ring: Color?

  init(name: String, isNamed: Bool, colorIndex: Int, size: CGFloat = 56, ring: Color? = nil) {
    self.name = name
    self.isNamed = isNamed
    self.colorIndex = colorIndex
    self.size = size
    self.ring = ring
  }

  init(_ person: MemoryPersonRef, size: CGFloat, ring: Color? = nil) {
    self.init(
      name: person.name, isNamed: person.isNamed, colorIndex: person.colorIndex, size: size,
      ring: ring)
  }

  init(_ person: MemoryPersonEntry, size: CGFloat, ring: Color? = nil) {
    self.init(
      name: person.name, isNamed: person.isNamed, colorIndex: person.colorIndex, size: size,
      ring: ring)
  }

  var body: some View {
    ZStack {
      if isNamed {
        Circle().fill(palette.bg)
        Circle().fill(palette.personTint(colorIndex))
        Text(Self.initial(of: name))
          .font(.zhiji(fontSize, .semibold))
          .foregroundStyle(palette.personInk(colorIndex))
      } else {
        Circle().fill(palette.bg)
        Circle()
          .strokeBorder(
            palette.tertiary, style: StrokeStyle(lineWidth: size >= 40 ? 1.5 : 1, dash: [3, 2.5]))
        Text("?")
          .font(.zhiji(fontSize))
          .foregroundStyle(palette.secondary)
      }
    }
    .frame(width: size, height: size)
    .background {
      if let ring { Circle().fill(ring).padding(-2) }
    }
    .accessibilityLabel(isNamed ? name : ZhijiCopy.nameSomeone)
  }

  private var fontSize: CGFloat {
    switch size {
    case 80...: 36
    case 50...: 20
    case 26...: 12
    case 21...: 11
    default: 10
    }
  }

  /// The character people call them by: "小周" → 周, "阿杰" → 杰, "王姐" → 王,
  /// "Ann" → A.
  static func initial(of name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first else { return "?" }
    if ["小", "阿", "老"].contains(String(first)), trimmed.count >= 2 {
      return String(trimmed[trimmed.index(after: trimmed.startIndex)])
    }
    return String(first).uppercased()
  }
}

/// Two or three overlapping 20 pt avatars for a card.
struct MiniAvatars: View {
  @Environment(\.zhiji) private var palette
  let people: [MemoryPersonRef]
  var size: CGFloat = 20
  var limit = 3
  var ring: Color?

  var body: some View {
    HStack(spacing: -5) {
      ForEach(Array(people.prefix(limit).enumerated()), id: \.offset) { _, person in
        Avatar(person, size: size, ring: ring ?? palette.bg)
      }
    }
  }
}
