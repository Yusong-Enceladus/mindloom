// swift-tools-version: 6.2

import PackageDescription

// The phone side of the Mindloom link (PHONE-CONTRACT §2, §5):
//
// - `MindloomPhoneKit`: the App Group layout and the durable outbox. Only
//   MindloomLink and Foundation, so the keyboard and share extensions can link
//   it without pulling in networking code.
// - `MindloomInboxSSH`: delivery to the Spark's `zhiji-inbox gate` over SSH,
//   optionally through a relay, with pinned host keys. Linked by the app only.
// - `MindloomPhoneIntake`: what 收进织机 does with shared items (image
//   normalization without metadata, audio/video refusal). System frameworks
//   only (ImageIO, UniformTypeIdentifiers); linked by the share extension
//   and the app.
//
// Every third-party package is pinned exactly and recorded in
// docs/architecture/decisions/ADR-0007-phone-ssh-delivery.md.
let package = Package(
  name: "MindloomPhoneKit",
  platforms: [
    .iOS(.v26),
    // macOS only so `swift test` runs the same tests on the Mac.
    .macOS(.v14),
  ],
  products: [
    .library(name: "MindloomPhoneKit", targets: ["MindloomPhoneKit"]),
    .library(name: "MindloomInboxSSH", targets: ["MindloomInboxSSH"]),
    .library(name: "MindloomPhoneIntake", targets: ["MindloomPhoneIntake"]),
  ],
  dependencies: [
    .package(path: "../MindloomLink"),
    .package(url: "https://github.com/apple/swift-nio-ssh.git", exact: "0.15.0"),
    .package(url: "https://github.com/apple/swift-nio-transport-services.git", exact: "1.28.0"),
    .package(url: "https://github.com/apple/swift-nio.git", exact: "2.103.0"),
    // Used directly for key types; pinned to the newest release swift-nio-ssh accepts.
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
  ],
  targets: [
    .target(
      name: "MindloomPhoneKit",
      dependencies: [.product(name: "MindloomLink", package: "MindloomLink")]
    ),
    .target(
      name: "MindloomInboxSSH",
      dependencies: [
        "MindloomPhoneKit",
        .product(name: "MindloomLink", package: "MindloomLink"),
        .product(name: "NIOSSH", package: "swift-nio-ssh"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .target(
      name: "MindloomPhoneIntake",
      dependencies: [.product(name: "MindloomLink", package: "MindloomLink")]
    ),
    .testTarget(
      name: "MindloomPhoneIntakeTests",
      dependencies: [
        "MindloomPhoneIntake",
        "MindloomPhoneKit",
        .product(name: "MindloomLink", package: "MindloomLink"),
      ]
    ),
    .testTarget(
      name: "MindloomPhoneKitTests",
      dependencies: [
        "MindloomPhoneKit",
        .product(name: "MindloomLink", package: "MindloomLink"),
      ]
    ),
    .testTarget(
      name: "MindloomInboxSSHTests",
      dependencies: [
        "MindloomInboxSSH",
        "MindloomPhoneKit",
        .product(name: "MindloomLink", package: "MindloomLink"),
        .product(name: "NIOSSH", package: "swift-nio-ssh"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
