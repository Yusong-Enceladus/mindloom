#!/bin/zsh

# Shared, fail-closed build storage configuration for every bestASR build entry point.
# Source this file before invoking SwiftPM or xcodebuild.

if [[ -z "${ZSH_VERSION:-}" ]]; then
  print -u2 "error: bestASR build storage requires zsh"
  return 64 2>/dev/null || exit 64
fi

bestasr_build_volume="${BESTASR_BUILD_VOLUME:-/Volumes/BestASRBuild}"
bestasr_expected_mount=" on ${bestasr_build_volume} ("

if [[ ! -d "$bestasr_build_volume" ]] || \
   ! /sbin/mount | /usr/bin/grep -Fq "$bestasr_expected_mount"; then
  print -u2 "error: bestASR external build volume is not mounted at $bestasr_build_volume"
  print -u2 "Mount the build volume (or set BESTASR_BUILD_VOLUME) and retry. Build stopped to prevent a large local fallback."
  return 72 2>/dev/null || exit 72
fi

if [[ ! -w "$bestasr_build_volume" ]]; then
  print -u2 "error: bestASR external build volume is not writable: $bestasr_build_volume"
  return 73 2>/dev/null || exit 73
fi

export BESTASR_BUILD_ROOT="${BESTASR_BUILD_ROOT:-$bestasr_build_volume/bestASR}"
case "$BESTASR_BUILD_ROOT" in
  "$bestasr_build_volume"/*) ;;
  *)
    print -u2 "error: BESTASR_BUILD_ROOT must remain under $bestasr_build_volume"
    return 64 2>/dev/null || exit 64
    ;;
esac

export BESTASR_XCODE_DERIVED_DATA="$BESTASR_BUILD_ROOT/xcode/DerivedData"
export BESTASR_XCODE_SOURCE_PACKAGES="$BESTASR_XCODE_DERIVED_DATA/SourcePackages"
export BESTASR_XCODE_PACKAGE_CACHE="$BESTASR_BUILD_ROOT/shared/PackageCache"
export BESTASR_SWIFTPM_SCRATCH="$BESTASR_BUILD_ROOT/swiftpm/Scratch"
export BESTASR_SWIFTPM_CACHE="$BESTASR_BUILD_ROOT/shared/SwiftPMCache"
export BESTASR_SWIFTPM_MODULE_CACHE="$BESTASR_BUILD_ROOT/shared/ModuleCache"
export BESTASR_CLANG_MODULE_CACHE="$BESTASR_BUILD_ROOT/shared/ClangModuleCache"
export BESTASR_BUILD_LOG_ROOT="$BESTASR_BUILD_ROOT/logs"
export BESTASR_RELEASE_ARTIFACT_ROOT="$BESTASR_BUILD_ROOT/release"
export BESTASR_WORK_ROOT="$BESTASR_BUILD_ROOT/work"
export BESTASR_MODEL_DOWNLOAD_CACHE="$BESTASR_BUILD_ROOT/model-downloads"
export BESTASR_RUNTIME_CACHE_ROOT="$BESTASR_BUILD_ROOT/runtime-cache"
export BESTASR_CORPUS_CACHE="$BESTASR_BUILD_ROOT/corpora"
export BESTASR_BUILD_TMP="$BESTASR_BUILD_ROOT/tmp"
export SWIFTPM_MODULECACHE_OVERRIDE="$BESTASR_SWIFTPM_MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$BESTASR_CLANG_MODULE_CACHE"
export TMPDIR="$BESTASR_BUILD_TMP"

/bin/mkdir -p \
  "$BESTASR_XCODE_DERIVED_DATA" \
  "$BESTASR_XCODE_SOURCE_PACKAGES" \
  "$BESTASR_XCODE_PACKAGE_CACHE" \
  "$BESTASR_SWIFTPM_SCRATCH" \
  "$BESTASR_SWIFTPM_CACHE" \
  "$BESTASR_SWIFTPM_MODULE_CACHE" \
  "$BESTASR_CLANG_MODULE_CACHE" \
  "$BESTASR_BUILD_LOG_ROOT" \
  "$BESTASR_RELEASE_ARTIFACT_ROOT" \
  "$BESTASR_WORK_ROOT" \
  "$BESTASR_MODEL_DOWNLOAD_CACHE" \
  "$BESTASR_RUNTIME_CACHE_ROOT" \
  "$BESTASR_CORPUS_CACHE" \
  "$BESTASR_BUILD_TMP"

if [[ "$ZSH_EVAL_CONTEXT" == "toplevel" ]]; then
  print "BESTASR_BUILD_ROOT=$BESTASR_BUILD_ROOT"
  print "BESTASR_XCODE_DERIVED_DATA=$BESTASR_XCODE_DERIVED_DATA"
  print "BESTASR_XCODE_SOURCE_PACKAGES=$BESTASR_XCODE_SOURCE_PACKAGES"
  print "BESTASR_XCODE_PACKAGE_CACHE=$BESTASR_XCODE_PACKAGE_CACHE"
  print "BESTASR_SWIFTPM_SCRATCH=$BESTASR_SWIFTPM_SCRATCH"
  print "BESTASR_SWIFTPM_CACHE=$BESTASR_SWIFTPM_CACHE"
  print "BESTASR_MODEL_DOWNLOAD_CACHE=$BESTASR_MODEL_DOWNLOAD_CACHE"
  print "BESTASR_RUNTIME_CACHE_ROOT=$BESTASR_RUNTIME_CACHE_ROOT"
  print "BESTASR_CORPUS_CACHE=$BESTASR_CORPUS_CACHE"
fi
