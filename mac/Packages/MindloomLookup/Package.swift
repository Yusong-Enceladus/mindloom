// swift-tools-version: 6.2

import PackageDescription

// Web lookup, 「从网络补充信息」 (PRD LOOKUP-001–003; v12/arch/WEBSEARCH.md,
// ARCH-V3 §4.5 and its review, MATTER-MINIMUM §5, §7, §8).
//
// The organizer's "what is missing" step hands this package a gap of one
// matter (a public name, a year, the kind of fact). The package decides which
// public source can answer, builds the outgoing words on the device, refuses
// anything that carries private data, sends through one network exit that
// records every request without content, reads the pages on the device, and
// returns new web source items attached under the original item. The
// original is never changed.
//
// Foundation, CryptoKit, Security and PDFKit only (and MindloomIdentity for the
// names); no third-party package
// (the reader is this package's own HTML tokenizer and readability scoring,
// so no web-page script ever runs). Builds for macOS and iOS.
let package = Package(
  name: "MindloomLookup",
  platforms: [
    .macOS(.v14),
    .iOS(.v26),
  ],
  products: [
    .library(name: "MindloomLookup", targets: ["MindloomLookup"])
  ],
  dependencies: [
    // The identity (bundle id, keychain service names) in one place; a leaf
    // package with no dependencies of its own.
    .package(path: "../MindloomLink")
  ],
  targets: [
    .target(
      name: "MindloomLookup",
      dependencies: [.product(name: "MindloomIdentity", package: "MindloomLink")]),
    .testTarget(
      name: "MindloomLookupTests",
      dependencies: ["MindloomLookup"],
      resources: [.copy("Fixtures")]
    ),
  ],
  swiftLanguageModes: [.v6]
)
