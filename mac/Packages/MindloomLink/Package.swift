// swift-tools-version: 6.2

import PackageDescription

// The link between the phone, the user's own Spark and the Mac: sealing
// (`mlseal1`), the pairing payload (`mlpair1`), the inbox plaintext and the
// phone outbox entry. Shared by the iOS app and the Mac app.
//
// Pure CryptoKit and Foundation, deliberately without any other dependency
// (PHONE-CONTRACT §1).
//
// `MindloomSpaces` is the member side of shared spaces (SPACES-CONTRACT):
// device keys, signed ops, space-key wraps, per-item data keys, the space
// routes and the member flows. Same rule: CryptoKit and Foundation only.
let package = Package(
  name: "MindloomLink",
  platforms: [
    .macOS(.v14),
    .iOS(.v26),
  ],
  products: [
    .library(name: "MindloomLink", targets: ["MindloomLink"]),
    .library(name: "MindloomSpaces", targets: ["MindloomSpaces"]),
    .library(name: "MindloomSpacesTestSupport", targets: ["MindloomSpacesTestSupport"]),
  ],
  targets: [
    .target(name: "MindloomLink"),
    .target(name: "MindloomSpaces", dependencies: ["MindloomLink"]),
    // Tests only (this package's and the Mac's): an in-memory Spark with the
    // space routes' rules. Never linked into an App.
    .target(
      name: "MindloomSpacesTestSupport", dependencies: ["MindloomSpaces", "MindloomLink"]),
    .testTarget(
      name: "MindloomLinkTests",
      dependencies: ["MindloomLink"],
      resources: [.copy("Resources/seal_vectors.json")]
    ),
    .testTarget(
      name: "MindloomSpacesTests",
      dependencies: ["MindloomSpaces", "MindloomLink", "MindloomSpacesTestSupport"],
      resources: [.copy("Resources/space_vectors.json")]
    ),
  ],
  swiftLanguageModes: [.v6]
)
