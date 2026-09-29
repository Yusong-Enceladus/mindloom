#!/bin/zsh

set -euo pipefail

repository_root="${0:A:h:h}"
source "$repository_root/script/build_storage.sh"

cache_parent="$HOME/Library/Caches"
cache_link="$cache_parent/com.bestasr.app"
cache_target="$BESTASR_RUNTIME_CACHE_ROOT/com.bestasr.app"

mkdir -p "$cache_parent" "$cache_target"

if [[ -L "$cache_link" ]]; then
  actual_target="$(readlink "$cache_link")"
  if [[ "$actual_target" != "$cache_target" ]]; then
    print -u2 "error: bestASR runtime cache points to an unexpected target: $actual_target"
    exit 74
  fi
elif [[ -e "$cache_link" ]]; then
  print -u2 "error: local bestASR runtime cache must be migrated before installation: $cache_link"
  print -u2 "Refusing to overwrite it or silently keep a large cache on the internal disk."
  exit 75
else
  ln -s "$cache_target" "$cache_link"
fi

[[ -d "$cache_target" ]] || {
  print -u2 "error: external bestASR runtime cache is unavailable: $cache_target"
  exit 76
}

print "runtime cache: $cache_link -> $cache_target"
