import SwiftUI

extension MLColor {
  /// Fully transparent, for a style that switches between a token and
  /// nothing (`hovering ? .fill2 : .transparent`).
  public static let transparent = MLColor(fixed: MLRGBA(0, 0, 0, 0))
}
