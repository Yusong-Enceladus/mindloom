// swift-tools-version: 6.2

import PackageDescription

// The link between the phone, the user's own Spark and the Mac: sealing
// (`mlseal1`), the pairing payload (`mlpair1`), the inbox plaintext and the
// phone outbox entry. Shared by the iOS app and the Mac app.
//
// Pure CryptoKit and Foundation, deliberately without any other dependency
// (PHONE-CONTRACT §1).
let package = Package(
  name: "MindloomLink",
  platforms: [
    .macOS(.v14),
    .iOS(.v26),
  ],
  products: [
    .library(name: "MindloomLink", targets: ["MindloomLink"])
  ],
  targets: [
    .target(name: "MindloomLink"),
    .testTarget(
      name: "MindloomLinkTests",
      dependencies: ["MindloomLink"],
      resources: [.copy("Resources/seal_vectors.json")]
    ),
  ],
  swiftLanguageModes: [.v6]
)
