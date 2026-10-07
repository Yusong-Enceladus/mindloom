#!/bin/zsh
# Xcode build phase of the App (project.yml): builds tmeet from pinned source
# with Mindloom's patches (script/build_tmeet.sh, cached by its inputs),
# copies it to Contents/Helpers/tmeet and signs it with the App's identity
# and the hardened runtime before Xcode seals the App (ENTRY-013).
#
# MINDLOOM_SKIP_TMEET=1 leaves it out (a build machine without Go); the App
# then shows that the Tencent Meeting connection cannot start.

set -euo pipefail

if [[ -n "${MINDLOOM_SKIP_TMEET:-}" ]]; then
  print "warning: tmeet left out of the App (MINDLOOM_SKIP_TMEET)."
  exit 0
fi

built="${DERIVED_FILE_DIR}/tmeet"
"${SRCROOT}/script/build_tmeet.sh" --output "$built"

destination="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
/bin/mkdir -p "$destination"
/usr/bin/ditto "$built/tmeet" "$destination/tmeet"
/bin/chmod 755 "$destination/tmeet"

if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "NO" ]]; then
  exit 0
fi
identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[[ -n "$identity" ]] || identity="-"
timestamp="--timestamp=none"
if [[ "$identity" != "-" && "${CONFIGURATION:-}" == "Release" ]]; then
  timestamp="--timestamp"
fi
/usr/bin/codesign --force --sign "$identity" --options runtime "$timestamp" \
  --identifier "${PRODUCT_BUNDLE_IDENTIFIER}.tmeet" "$destination/tmeet"
