// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "BestASRSecurityStorageProbe",
  platforms: [.macOS(.v14)],
  products: [
    .executable(
      name: "SecurityStorageProbeCLI",
      targets: ["SecurityStorageProbeCLI"]
    )
  ],
  dependencies: [
    .package(path: "../../../Packages/BestASRCore")
  ],
  targets: [
    .binaryTarget(
      name: "SQLCipher",
      path: "Artifacts/SQLCipher.xcframework"
    ),
    .executableTarget(
      name: "SecurityStorageProbeCLI",
      dependencies: [
        "SQLCipher",
        .product(
          name: "BestASRSecurityEnvelopeProbe",
          package: "BestASRCore"
        ),
      ],
      cSettings: [.define("SQLITE_HAS_CODEC")],
      swiftSettings: [.define("SQLITE_HAS_CODEC")],
      linkerSettings: [.linkedFramework("Security")]
    ),
  ],
  swiftLanguageModes: [.v6]
)
