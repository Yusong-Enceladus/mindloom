#!/bin/zsh

set -euo pipefail

repository_root="${0:A:h:h}"
source "$repository_root/script/build_storage.sh"

if [[ -n "$(git -C "$repository_root" status --porcelain)" ]]; then
  print -u2 "error: Release builds require a clean worktree so the installed revision is reproducible"
  exit 1
fi

build_revision="$(git -C "$repository_root" rev-parse HEAD)"
app_path="$BESTASR_XCODE_DERIVED_DATA/Build/Products/Release/bestASR.app"
development_identity="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk '/Apple Development:/{if (!found) {value=$2; found=1}} END{print value}')"
[[ -n "$development_identity" ]] || {
  print -u2 "error: stable Apple Development signing identity is unavailable"
  exit 1
}

xcodebuild \
  -workspace "$repository_root/BestASR.xcworkspace" \
  -scheme BestASR \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BESTASR_XCODE_DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$BESTASR_XCODE_SOURCE_PACKAGES" \
  -packageCachePath "$BESTASR_XCODE_PACKAGE_CACHE" \
  -disablePackageRepositoryCache \
  -skipPackageUpdates \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  BESTASR_GIT_REVISION="$build_revision" \
  CODE_SIGN_IDENTITY="$development_identity" \
  CODE_SIGN_STYLE=Manual \
  build

[[ -d "$app_path" ]] || {
  print -u2 "error: Release bundle was not produced: $app_path"
  exit 1
}
codesign --verify --deep --strict "$app_path"
signature_authority="$(codesign -dv --verbose=4 "$app_path" 2>&1 \
  | awk '/^Authority=/{if (!found) {sub(/^Authority=/, ""); value=$0; found=1}} END{print value}')"
team_identifier="$(codesign -dv --verbose=4 "$app_path" 2>&1 \
  | awk '/^TeamIdentifier=/{sub(/^TeamIdentifier=/, ""); value=$0} END{print value}')"
if [[ "$signature_authority" != Apple\ Development:* \
  || -z "$team_identifier" || "$team_identifier" == "not set" ]]; then
  print -u2 "error: Release must use a stable Apple Development identity with a team identifier"
  exit 1
fi

info_plist="$app_path/Contents/Info.plist"
bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - "$info_plist")"
embedded_revision="$(plutil -extract BestASRBuildRevision raw -o - "$info_plist")"
if [[ "$bundle_identifier" != "com.bestasr.app" ]]; then
  print -u2 "error: unexpected Release bundle identifier: $bundle_identifier"
  exit 1
fi
if [[ "$embedded_revision" != "$build_revision" ]]; then
  print -u2 "error: Release revision mismatch: expected $build_revision, got $embedded_revision"
  exit 1
fi

"$repository_root/script/generate_supply_chain.sh" --package "$app_path"
"$repository_root/script/validate_release_package.sh" --package "$app_path"
"$repository_root/script/unregister_build_app.sh" "$app_path"

print "release: $app_path"
print "revision: $build_revision"
print "signing authority: $signature_authority"
