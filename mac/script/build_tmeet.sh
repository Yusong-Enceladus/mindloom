#!/bin/zsh
# Builds the tmeet Mindloom bundles (Contents/Helpers/tmeet) from the pinned
# upstream source in third_party/tencentmeeting-cli/upstream plus the patches
# in third_party/tencentmeeting-cli/patches, after running the patches'
# regression tests. Reproducible: CGO off, -trimpath, no VCS stamp, the Go
# module downloads checked against upstream's go.sum.
#
#   script/build_tmeet.sh --output <dir> [--work <dir>] [--skip-tests]
#   script/build_tmeet.sh --check-only
#
# Prints the binary's path and SHA-256. Rebuilds only when the source, the
# patches, this script or the Go version changed (a stamp next to the binary).
# The vendored tree must be exactly the manifest: every listed file with its
# hash and nothing else (Go would compile a file added there); --check-only
# checks that and stops.
# Never touches the system Keychain: the Keychain integration tests upstream
# ships are not run (they would write the real login Keychain).

set -euo pipefail
umask 022

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
vendor="$repository_root/third_party/tencentmeeting-cli"
output=""
work=""
skip_tests=0
check_only=0
while (( $# > 0 )); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --work) work="$2"; shift 2 ;;
    --skip-tests) skip_tests=1; shift ;;
    --check-only) check_only=1; shift ;;
    *) print -u2 "error: unknown argument $1"; exit 64 ;;
  esac
done
if [[ -z "$output" ]] && (( ! check_only )); then
  print -u2 "usage: $0 --output <dir> [--work <dir>] [--skip-tests] | --check-only"
  exit 64
fi

expected_commit="$(<"$vendor/UPSTREAM_COMMIT")"

# The pristine tree must be exactly its manifest before anything is
# patched: the same paths (any file, link or other entry that is not a
# folder; Finder's .DS_Store aside, which Go never reads) and each file's
# hash.
manifest_paths="$(/usr/bin/sed -E 's/^[0-9a-f]{64} [ *]//' "$vendor/upstream.sha256" | LC_ALL=C /usr/bin/sort)"
tree_paths="$(cd "$vendor/upstream" && /usr/bin/find . ! -type d ! -name .DS_Store | LC_ALL=C /usr/bin/sort)"
if [[ "$manifest_paths" != "$tree_paths" ]]; then
  print -u2 "error: third_party/tencentmeeting-cli/upstream does not have exactly the files upstream.sha256 lists (commit $expected_commit):"
  /usr/bin/diff <(print -r -- "$manifest_paths") <(print -r -- "$tree_paths") \
    | /usr/bin/sed -n -e 's/^> /  not listed: /p' -e 's/^< /  missing: /p' >&2 || true
  exit 65
fi
(cd "$vendor/upstream" && /usr/bin/shasum -a 256 -c --quiet ../upstream.sha256) || {
  print -u2 "error: third_party/tencentmeeting-cli/upstream differs from upstream.sha256 (commit $expected_commit)."
  exit 65
}
if (( check_only )); then
  print "tmeet: third_party/tencentmeeting-cli/upstream matches upstream.sha256"
  exit 0
fi

go_binary=""
for candidate in "${GO:-}" "$(command -v go 2>/dev/null || true)" /opt/homebrew/bin/go /usr/local/go/bin/go /usr/local/bin/go; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then go_binary="$candidate"; break; fi
done
if [[ -z "$go_binary" ]]; then
  print -u2 "error: Go 1.22 or later is needed to build tmeet (third_party/tencentmeeting-cli/README.md)."
  exit 69
fi

version="$(<"$vendor/VERSION")"

go_version="$("$go_binary" env GOVERSION)"
inputs_hash="$(
  {
    /bin/cat "$vendor/upstream.sha256"
    print -r -- "$tree_paths"
    for patch in "$vendor"/patches/*.patch; do /usr/bin/shasum -a 256 "$patch" | /usr/bin/cut -d' ' -f1; done
    /usr/bin/shasum -a 256 "$0" | /usr/bin/cut -d' ' -f1
    print "$go_version $version"
  } | /usr/bin/shasum -a 256 | /usr/bin/cut -d' ' -f1
)"
binary="$output/tmeet"
stamp="$output/tmeet.inputs"
if [[ -x "$binary" && -f "$stamp" && "$(<"$stamp")" == "$inputs_hash" ]]; then
  print "tmeet: up to date ($binary)"
  print "sha256: $(/usr/bin/shasum -a 256 "$binary" | /usr/bin/cut -d' ' -f1)"
  exit 0
fi

work="${work:-$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/mindloom-tmeet.XXXXXX")}"
cleanup_work=1
[[ -n "${MINDLOOM_TMEET_KEEP_WORK:-}" ]] && cleanup_work=0
trap '(( cleanup_work )) && /bin/rm -r "$work" 2>/dev/null || true' EXIT
/bin/mkdir -p "$work/src"
/usr/bin/ditto "$vendor/upstream" "$work/src"
for patch in "$vendor"/patches/*.patch; do
  /usr/bin/patch -d "$work/src" -p1 --forward --quiet --no-backup-if-mismatch < "$patch"
done

export CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 GOFLAGS=-mod=readonly GOTOOLCHAIN=local
export GOFLAGS="$GOFLAGS -buildvcs=false"
unset TMEET_AGENT TMEET_MODEL TMEET_MASTER_KEY_FD
if (( ! skip_tests )); then
  # The patches' own regression tests: crash reporting off (0001), the login
  # kept on network failures (0002), the key from Mindloom's descriptor and
  # never the system Keychain (0003).
  (cd "$work/src" && TMEET_CLI_DATA_DIR="$work/test-data" TMEET_CLI_CONFIG_DIR="$work/test-config" \
    "$go_binary" test -count=1 \
      -run '^(TestRefresh|TestMasterKeyFD|TestEncrypt|TestDecrypt|TestFallback|TestReport)' \
      ./internal/auth/ ./internal/core/keychain/ ./internal/crash/)
fi
/bin/mkdir -p "$output"
(cd "$work/src" && "$go_binary" build -trimpath \
  -ldflags "-s -w -X tmeet/cmd.Version=$version" -o "$binary.new" .)
/bin/mv -f "$binary.new" "$binary"
print -n "$inputs_hash" > "$stamp"
print "tmeet: built $version from $expected_commit with $go_version ($binary)"
print "sha256: $(/usr/bin/shasum -a 256 "$binary" | /usr/bin/cut -d' ' -f1)"
