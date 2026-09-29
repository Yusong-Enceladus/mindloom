#!/bin/zsh

set -euo pipefail

repository_root="${0:A:h:h:h}"
source "$repository_root/script/build_storage.sh"

fake_app="$BESTASR_XCODE_DERIVED_DATA/Build/Products/UnregisterTest/bestASR.app"
mkdir -p "$fake_app"

BESTASR_LSREGISTER_PATH=/usr/bin/true \
  "$repository_root/script/unregister_build_app.sh" "$fake_app" >/dev/null

BESTASR_LSREGISTER_PATH=/usr/bin/true \
  "$repository_root/script/unregister_build_app.sh" --hide-product \
  "$fake_app" >/dev/null
hidden_app="${fake_app%.app}.build-product"
[[ ! -e "$fake_app" && -d "$hidden_app" ]] || {
  print -u2 "error: build App quarantine did not remove the registerable suffix"
  exit 1
}
mv "$hidden_app" "$fake_app"

BESTASR_LSREGISTER_PATH=/usr/bin/false \
  "$repository_root/script/unregister_build_app.sh" --hide-product \
  "$fake_app" >/dev/null 2>&1
[[ ! -e "$fake_app" && -d "$hidden_app" ]] || {
  print -u2 "error: cache failure prevented physical build App quarantine"
  exit 1
}
mv "$hidden_app" "$fake_app"

if BESTASR_LSREGISTER_PATH=/usr/bin/true \
  "$repository_root/script/unregister_build_app.sh" \
  "$HOME/Applications/bestASR.app" >/dev/null 2>&1
then
  print -u2 "error: build App unregistration accepted the installed product path"
  exit 1
fi

missing_app="$BESTASR_XCODE_DERIVED_DATA/Build/Products/Release-missing/bestASR.app"
if BESTASR_LSREGISTER_PATH=/usr/bin/true \
  "$repository_root/script/unregister_build_app.sh" "$missing_app" >/dev/null 2>&1
then
  print -u2 "error: build App unregistration accepted a missing bundle"
  exit 1
fi

find "$fake_app:h" -depth -delete
print "unregister build app tests passed"
