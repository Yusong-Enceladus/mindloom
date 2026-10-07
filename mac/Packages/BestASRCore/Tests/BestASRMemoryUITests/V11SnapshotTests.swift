import AppKit
import BestASRDomain
import BestASRMemory
import MindloomDesign
import SwiftUI
import XCTest

@testable import BestASRMemoryUI

/// One renderable prototype state: a MAC-SPEC §1.2 state ID and how to draw
/// it from the v10 fixture. Each owner keeps its scenes in its own file
/// (`V11Scenes+Home.swift`, `+Matter`, `+Capture`, `+Shell`).
struct V11Scene {
  let id: String
  /// The window (1188 × 848, the prototype's main window) or the surface's
  /// own size (sheets, popovers, Settings, Welcome, HUD, menus).
  var size = V11Scene.window
  let build: @MainActor (V11Fixture.Loaded) -> AnyView

  static let window = CGSize(width: 1188, height: 848)
}

enum V11Scenes {
  @MainActor static var all: [V11Scene] { shell + home + matter + capture }
}

/// Renders any MAC-SPEC state, light and dark, to PNG (MAC-SPEC §1.2):
///
///     BESTASR_UI_SNAPSHOT_DIR=<dir> BESTASR_UI_STATES=home,matter \
///       /Volumes/<build-volume>/mac-build/v11-test.sh --filter V11SnapshotTests
///
/// `BESTASR_UI_STATES`: comma-separated state IDs, or `all` (the default).
/// `BESTASR_UI_SCALE`: pixels per point (default 2, as the prototype's
/// shots). `BESTASR_UI_SCHEMES`: `light`, `dark` or both (default). Writes
/// `<id>-light.png` / `<id>-dark.png`. Off (skipped) unless
/// `BESTASR_UI_SNAPSHOT_DIR` is set; needs the synthetic fixture files.
@MainActor
final class V11SnapshotTests: XCTestCase {
  func testRenderStates() throws {
    let env = ProcessInfo.processInfo.environment
    guard let directory = env["BESTASR_UI_SNAPSHOT_DIR"], !directory.isEmpty else {
      throw XCTSkip("Set BESTASR_UI_SNAPSHOT_DIR to render the v11 states.")
    }
    guard V11Fixture.isAvailable else { throw XCTSkip("The v10 fixture files are not on this Mac.") }
    let loaded = try V11Fixture.load()
    let output = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let wanted = (env["BESTASR_UI_STATES"] ?? "all").split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    let scenes = V11Scenes.all.filter { wanted.contains("all") || wanted.contains($0.id) }
    XCTAssertFalse(scenes.isEmpty, "no scene for \(wanted)")
    let scale = CGFloat(Double(env["BESTASR_UI_SCALE"] ?? "") ?? 2)
    let schemes = (env["BESTASR_UI_SCHEMES"] ?? "light,dark").split(separator: ",").map(String.init)
    for scene in scenes {
      for scheme in schemes {
        let dark = scheme == "dark"
        let png = try Self.render(scene, loaded: loaded, dark: dark, scale: scale)
        try png.write(
          to: output.appendingPathComponent("\(scene.id)-\(dark ? "dark" : "light").png"),
          options: .atomic)
      }
    }
  }

  /// Every prototype state has a scene (a placeholder until its owner draws
  /// it), and no scene names an unknown state.
  func testEveryStateHasAScene() {
    let ids = Set(V11Scenes.all.map(\.id))
    let known = Set(MindloomStateID.all.map(\.id))
    XCTAssertEqual(MindloomStateID.all.count, 76)
    XCTAssertEqual(known.subtracting(ids), [], "states without a scene")
    XCTAssertEqual(ids.subtracting(known).filter { !$0.hasPrefix("x-") }, [], "unknown states")
  }

  /// The shell and the default pages draw from the fixture without the
  /// snapshot directory (a smoke check every run).
  func testHomeAndMatterDraw() throws {
    guard V11Fixture.isAvailable else { throw XCTSkip("The v10 fixture files are not on this Mac.") }
    let loaded = try V11Fixture.load()
    for id in ["home", "matter", "empty"] {
      let scene = try XCTUnwrap(V11Scenes.all.first { $0.id == id })
      let png = try Self.render(scene, loaded: loaded, dark: false, scale: 1)
      XCTAssertGreaterThan(png.count, 10_000, id)
    }
  }

  static func render(_ scene: V11Scene, loaded: V11Fixture.Loaded, dark: Bool, scale: CGFloat)
    throws -> Data
  {
    let view = scene.build(loaded)
      .frame(width: scene.size.width, height: scene.size.height)
      .environment(\.colorScheme, dark ? .dark : .light)
      .environment(\.zhijiSnapshot, true)
      .environment(\.mlGlassRendering, .approximation)
      .environment(\.mlPlatform, .mac)
      .environment(\.locale, Locale(identifier: "zh-Hans"))
      .environment(\.timeZone, V11Fixture.calendar.timeZone)
      .environment(\.calendar, V11Fixture.calendar)
      // As every App window: no system Chinese–Latin gap (macOS 27).
      .mlNoAutospace()
    let renderer = ImageRenderer(content: view)
    renderer.proposedSize = ProposedViewSize(scene.size)
    renderer.scale = scale
    guard let image = renderer.cgImage,
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    return png
  }
}
