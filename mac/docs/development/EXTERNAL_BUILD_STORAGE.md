# External build storage

All bestASR build entry points use one fail-closed root:
`/Volumes/BestASRBuild/bestASR`.

- Xcode DerivedData and its single SourcePackages checkout live under
  `xcode/DerivedData`.
- Xcode package cache and SwiftPM cache/module caches live under `shared`.
- SwiftPM products and checkouts live under `swiftpm/Scratch`.
- Re-downloadable model transfer receipts/staging cache live under
  `model-downloads`; installed model versions remain in local Application
  Support.
- Logs, release artifacts, and disposable probe workspaces live under their
  corresponding external subdirectories. Compiler temporary files use the
  external `tmp` directory as well.

Repository scripts source `script/build_storage.sh`, which verifies that
`/Volumes/BestASRBuild` is a mounted, writable volume before creating any build
directory. If it is absent, the command exits with a clear error instead of
falling back to a repository-local `.build` directory. The shared workspace
settings apply the same DerivedData location when building from the Xcode UI.
To build on a different mounted volume, set
`BESTASR_BUILD_VOLUME=/Volumes/<name>`; every path above then moves under
`/Volumes/<name>/bestASR`.

Run `script/build_storage.sh` to inspect the resolved paths. Do not invoke raw
`swift build`, `swift test`, or `xcodebuild` for this repository; use the
repository scripts so the external scratch, cache, and package paths are
always supplied explicitly.
