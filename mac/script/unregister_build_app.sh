#!/bin/zsh

set -euo pipefail

repository_root="${0:A:h:h}"
source "$repository_root/script/build_storage.sh"

hide_product=false
if [[ "${1:-}" == "--hide-product" ]]; then
  hide_product=true
  shift
fi
app_path="${1:-$BESTASR_XCODE_DERIVED_DATA/Build/Products/Release/bestASR.app}"
lsregister_path="${BESTASR_LSREGISTER_PATH:-/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister}"

case "$app_path" in
  "$BESTASR_XCODE_DERIVED_DATA"/Build/Products/*/bestASR.app) ;;
  *)
    print -u2 "error: refusing to unregister a non-build bestASR path: $app_path"
    exit 64
    ;;
esac

[[ -d "$app_path" ]] || {
  print -u2 "error: build App is unavailable: $app_path"
  exit 66
}
[[ -x "$lsregister_path" ]] || {
  print -u2 "error: LaunchServices registration tool is unavailable: $lsregister_path"
  exit 69
}

if ! "$lsregister_path" -u "$app_path"; then
  print -u2 "warning: LaunchServices did not remove the cached build registration"
fi
if [[ "$hide_product" == true ]]; then
  hidden_path="${app_path%.app}.build-product"
  case "$hidden_path" in
    "$BESTASR_XCODE_DERIVED_DATA"/Build/Products/*/bestASR.build-product) ;;
    *)
      print -u2 "error: refusing unexpected hidden build product path: $hidden_path"
      exit 64
      ;;
  esac
  if [[ -e "$hidden_path" ]]; then
    /usr/bin/trash "$hidden_path"
  fi
  mv "$app_path" "$hidden_path"
  if ! "$lsregister_path" -gc; then
    print -u2 "warning: LaunchServices cache cleanup was deferred by macOS"
  fi
  print "quarantined build app: $hidden_path"
else
  print "unregistered build app: $app_path"
fi
