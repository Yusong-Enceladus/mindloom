import SwiftUI

/// The three glass variants of SYSTEM.md §6.  Glass is only for the control layer that floats over content (bars,
/// toolbars, floating buttons, toasts, menus, partial sheets, the HUD).  Never for content.
public enum MLGlassVariant: Sendable, Hashable {
  /// Toolbars, toasts, the speak bar, round buttons.
  case regular
  /// Menus, partial sheets, popovers, the HUD (more opaque).
  case thick
  /// Only over photos or video, and always with `MLColor.dim` under it.
  case clear
}

/// How glass is drawn.
public enum MLGlassRendering: Sendable, Hashable {
  /// The system's Liquid Glass on macOS 26 / iOS 26 and later; the approximation (with a material blur) before.
  case automatic
  /// The v10 CSS approximation only (tint, top sheen, inner edge, layered shadow; no blur).  Snapshot renders use
  /// it, because an offscreen render has no backdrop for real glass to refract.
  case approximation
}

extension EnvironmentValues {
  /// Glass rendering for the kit's glass surfaces.
  @Entry public var mlGlassRendering: MLGlassRendering = .automatic
}

/// Liquid Glass with the v10 approximation as its fallback.
public struct MLGlassModifier<S: Shape>: ViewModifier {
  @Environment(\.mlGlassRendering) private var rendering
  @Environment(\.colorScheme) private var scheme
  let variant: MLGlassVariant
  let shape: S

  public func body(content: Content) -> some View {
    if rendering == .automatic, #available(macOS 26.0, iOS 26.0, *) {
      #if os(macOS)
        if variant == .thick {
          // Thick (toasts, menus, the HUD; tint .82 / .76, blur 36): Liquid Glass over a thick material and the
          // paper tint, so text behind it never shows through (fix-mac: rows read through toasts).
          content
            .background {
              ZStack {
                shape.fill(Material.thickMaterial)
                shape.fill(MLColor.glassTint2.color(for: scheme).opacity(0.6))
              }
            }
            .glassEffect(.regular, in: shape)
        } else {
          content.glassEffect(systemGlass, in: shape)
        }
      #else
        content.glassEffect(systemGlass, in: shape)
      #endif
    } else {
      content
        .background {
          ZStack {
            if rendering == .automatic {
              shape.fill(variant == .thick ? Material.regularMaterial : Material.ultraThinMaterial)
            }
            shape.fill(tint.color(for: scheme))
            // the sheen is a background layer, so it never washes over the content
            shape.fill(
              LinearGradient(
                stops: [
                  .init(color: MLColor.glassSheen.color(for: scheme), location: 0),
                  .init(color: MLColor.glassSheen.color(for: scheme).opacity(0), location: 0.45),
                ], startPoint: .top, endPoint: .bottom))
          }
          .mlShadow(.glass)
        }
        .overlay {
          ZStack {
            // inner 0.5 pt edge (a 1 pt stroke clipped to the inside) and the 1 pt top highlight
            shape.stroke(MLColor.glassEdge.color(for: scheme), lineWidth: 1).clipShape(shape)
            shape.stroke(
              LinearGradient(
                stops: [
                  .init(color: MLColor.glassHighlight.color(for: scheme), location: 0),
                  .init(
                    color: MLColor.glassHighlight.color(for: scheme).opacity(0), location: 0.12),
                ], startPoint: .top, endPoint: .bottom), lineWidth: 2
            )
            .clipShape(shape)
          }
          .allowsHitTesting(false)
        }
    }
  }

  private var tint: MLColor {
    switch variant {
    case .regular: .glassTint
    case .thick: .glassTint2
    case .clear: .glassClear
    }
  }

  @available(macOS 26.0, iOS 26.0, *)
  private var systemGlass: Glass {
    switch variant {
    case .regular: .regular
    // thick: the regular material carrying the warm paper tint, so menus and the HUD read more opaque
    case .thick: .regular.tint(MLColor.glassTint2.color(for: scheme).opacity(0.5))
    case .clear: .clear
    }
  }
}

extension View {
  /// Puts the view on glass in `shape` (Liquid Glass where available, the v10 approximation otherwise).
  public func mlGlass<S: Shape>(_ variant: MLGlassVariant = .regular, in shape: S) -> some View {
    modifier(MLGlassModifier(variant: variant, shape: shape))
  }

  /// Glass in a capsule, the kit's usual shape.
  public func mlGlass(_ variant: MLGlassVariant = .regular) -> some View {
    modifier(MLGlassModifier(variant: variant, shape: Capsule()))
  }
}
