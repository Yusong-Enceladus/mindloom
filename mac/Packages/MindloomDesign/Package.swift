// swift-tools-version: 6.2

import PackageDescription

// Mindloom's native design kit: the v10 design system (tokens, motion, components) and brand (mark, wordmark,
// title, listening animation) for the Mac app and the iPhone app.  SwiftUI only, no other dependency.
// Source of truth: /Users/Shared/mindloom-demo/v10/system (tokens.css, kit.js, SYSTEM.md) and v10/brand.
//
// `MindloomTaglines` is the brand's taglines (docs/TAGLINES.md): the curated Chinese and English sets as a bundled
// data file, and which line each six-hour period shows. Foundation only; a product of its own, so a target that
// does not show taglines (the iPhone keyboard and share extensions) carries no data file.
let package = Package(
  name: "MindloomDesign",
  platforms: [
    .macOS(.v14),
    .iOS(.v26),
  ],
  products: [
    .library(name: "MindloomDesign", targets: ["MindloomDesign"]),
    .library(name: "MindloomTaglines", targets: ["MindloomTaglines"]),
  ],
  targets: [
    .target(name: "MindloomDesign"),
    .target(name: "MindloomTaglines", resources: [.copy("Resources/taglines.json")]),
    .testTarget(name: "MindloomDesignTests", dependencies: ["MindloomDesign"]),
    .testTarget(name: "MindloomTaglinesTests", dependencies: ["MindloomTaglines"]),
  ],
  swiftLanguageModes: [.v6]
)
