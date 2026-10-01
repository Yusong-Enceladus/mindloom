#!/bin/zsh
# Run `swift build` / `swift test` for one of the phone packages with every
# build product, cache and temporary file on the external build volume.
#
#   iOS/script/swift_package.sh MindloomLink test
#   iOS/script/swift_package.sh MindloomPhoneKit test --filter InboxSender
#
# PHONE_BUILD_ROOT overrides the default /Volumes/<build-volume>/ios-build/phone.

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
package="${1:?package name (MindloomLink or MindloomPhoneKit)}"
shift
command="${1:?swift command (build or test)}"
shift

build_root="${PHONE_BUILD_ROOT:-/Volumes/<build-volume>/ios-build/phone}"
volume="/Volumes/$(print -r -- "$build_root" | /usr/bin/cut -d/ -f3)"
if [[ ! -d "$volume" ]] || ! /sbin/mount | /usr/bin/grep -Fq " on $volume ("; then
  print -u2 "error: build volume $volume is not mounted; refusing to fall back to the system disk"
  exit 72
fi

scratch="$build_root/swiftpm/$package"
cache="$build_root/swiftpm-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_root/module-cache"
export CLANG_MODULE_CACHE_PATH="$build_root/clang-module-cache"
export TMPDIR="$build_root/tmp"
/bin/mkdir -p "$scratch" "$cache" "$SWIFTPM_MODULECACHE_OVERRIDE" "$CLANG_MODULE_CACHE_PATH" "$TMPDIR"

exec /usr/bin/swift "$command" \
  --package-path "$repository_root/Packages/$package" \
  --scratch-path "$scratch" \
  --cache-path "$cache" \
  --jobs 6 \
  "$@"
