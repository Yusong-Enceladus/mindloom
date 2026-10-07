#!/bin/zsh

# Creates a separate, explicitly synthetic Mindloom data root for demos and
# own-device organizer tests, then prints how to launch the app on it.
#
# The app starts the Spark organizer link only from a data root that holds the
# SYNTHETIC_DATA_ROOT marker (PRD §0.3.8). This script never creates, reads, or
# modifies the owner's real library (Mindloom's folder, and bestASR's where it was
# before 2026-10-06) and refuses any path that is, contains, or sits inside either.
# Put only fabricated data in the new root.

set -euo pipefail

if (( $# != 1 )); then
  print -u2 "usage: $0 <absolute path of a new synthetic data root>"
  exit 64
fi

target="$1"
if [[ "$target" != /* ]]; then
  print -u2 "error: the data root must be an absolute path"
  exit 64
fi

support_parent="$HOME/Library/Application Support"
if [[ -d "$support_parent" ]]; then
  support_parent="$(cd "$support_parent" && pwd -P)"
fi
real_libraries=("${support_parent}/Mindloom" "${support_parent}/bestASR")

refuse_if_overlapping() {
  local candidate="${1:l}" real
  candidate="${candidate%/}"
  for real in "${(@L)real_libraries}"; do
    if [[ "$candidate/" == "$real/"* || "$real/" == "$candidate/"* ]]; then
      print -u2 "error: refusing a path that overlaps the owner's library"
      exit 65
    fi
  done
}

# Magic prefixes (/.nofollow, /.resolve, /.vol) reach any directory under
# another spelling; the app refuses them, so this script does too.
first_component="${${target#/}%%/*}"
if [[ "$first_component" == .* ]]; then
  print -u2 "error: refusing a path under /$first_component"
  exit 64
fi

# Lexical check before anything is created, then the resolved path (symlinks).
refuse_if_overlapping "$target"
parent="${target:h}"
if [[ -d "$parent" ]]; then
  refuse_if_overlapping "$(cd "$parent" && pwd -P)/${target:t}"
fi
# The marker says "everything here is fabricated", so it is only ever put on
# a directory this script creates. An existing directory (for example a
# restored or copied library) is never blessed.
if [[ -e "$target" || -L "$target" ]]; then
  print -u2 "error: $target already exists; choose a new path (only a new, empty root is marked)"
  exit 66
fi
/bin/mkdir -p "${target:h}"
/bin/mkdir -m 0700 "$target"
resolved="$(cd "$target" && pwd -P)"
refuse_if_overlapping "$resolved"

marker="$resolved/SYNTHETIC_DATA_ROOT"
print -r -- "Synthetic Mindloom data root. Only fabricated data belongs here." > "$marker"
/bin/chmod 0644 "$marker"

print "Synthetic data root ready: $resolved"
print "Launch Mindloom on it with:"
print "  open -n <path to Mindloom.app> --args -BestASRDataRoot \"$resolved\""
