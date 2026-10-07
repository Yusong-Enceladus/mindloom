// swift-tools-version: 6.2

import PackageDescription

// Apple Watch → iPhone: what the watch records and how it hands each recording to the iPhone
// (PRD WATCH-001–008, TECHNICAL_DESIGN "Apple Watch").
//
// - `WatchRecording`: the description both sides agree on (id, start, length, size, SHA-256),
//   carried as the WatchConnectivity file-transfer metadata.
// - `WatchRecordingQueue`: the watch's durable queue. A recording stays on the watch until the
//   iPhone says it has stored the original.
// - `WatchRecordingInbox`: the iPhone's store of the originals it received, and their
//   transcription state.
// - `WatchHandoffMessage`: the small messages in between ("stored", "holding").
//
// Foundation and CryptoKit only, so the watch app links it without anything else. WatchConnectivity
// itself stays in the apps; everything here is plain files and values, tested with `swift test`
// on the Mac.
let package = Package(
  name: "MindloomWatchHandoff",
  platforms: [
    .iOS(.v26),
    .watchOS(.v26),
    // macOS only so `swift test` runs the same tests on the Mac.
    .macOS(.v14),
  ],
  products: [
    .library(name: "MindloomWatchHandoff", targets: ["MindloomWatchHandoff"])
  ],
  targets: [
    .target(name: "MindloomWatchHandoff"),
    .testTarget(name: "MindloomWatchHandoffTests", dependencies: ["MindloomWatchHandoff"]),
  ],
  swiftLanguageModes: [.v6]
)
