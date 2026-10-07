#!/bin/zsh

set -euo pipefail

repository_root="${0:A:h:h}"
source "$repository_root/script/build_storage.sh"
source "$repository_root/script/identity.sh"

if [[ -n "$(git -C "$repository_root" status --porcelain)" ]]; then
  print -u2 "error: Release builds require a clean worktree so the installed revision is reproducible"
  exit 1
fi

build_revision="$(git -C "$repository_root" rev-parse HEAD)"
app_path="$BESTASR_XCODE_DERIVED_DATA/Build/Products/Release/$MINDLOOM_APP_NAME"
# The installed product is Mindloom.app, bundle id app.mindloom (2026-10-06); the build is
# copied here as it will be installed.
release_app="$BESTASR_RELEASE_ARTIFACT_ROOT/$MINDLOOM_APP_NAME"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
# The team is passed at build time and never committed (script/signing_team.sh).
signing_team="$("$repository_root/script/signing_team.sh")"
development_identity="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk '/Apple Development:/{if (!found) {value=$2; found=1}} END{print value}')"
[[ -n "$development_identity" ]] || {
  print -u2 "error: stable Apple Development signing identity is unavailable"
  exit 1
}

# 「从网络补充信息」 keeps search keys in the data-protection keychain (synced by
# iCloud Keychain) only where the App carries keychain-access-groups, which macOS
# honours only with a provisioning profile that names the group. Without a profile
# the entitlement makes the system refuse to launch the App (measured: exit 137), so
# it is opt-in: MINDLOOM_PROFILE_SPECIFIER names a Mac provisioning profile for the
# App ID, and the variant file adds the group. Otherwise the keys stay in the login
# keychain on this Mac (Settings says so). Both settings are read by the App target
# only (project.yml); passing CODE_SIGN_ENTITLEMENTS or PROVISIONING_PROFILE_SPECIFIER
# directly would override the share extension, the worker and the MCP helper too.
keychain_group_arguments=()
if [[ -n "${MINDLOOM_PROFILE_SPECIFIER:-}" ]]; then
  keychain_group_arguments=(
    MINDLOOM_ENTITLEMENTS_VARIANT=-KeychainGroup
    MINDLOOM_APP_PROFILE_SPECIFIER="$MINDLOOM_PROFILE_SPECIFIER"
  )
fi

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
  DEVELOPMENT_TEAM="$signing_team" \
  "${keychain_group_arguments[@]}" \
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
if [[ "$team_identifier" != "$signing_team" ]]; then
  print -u2 "error: Release is signed by another team than the one passed at build time"
  exit 1
fi

info_plist="$app_path/Contents/Info.plist"
bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - "$info_plist")"
embedded_revision="$(plutil -extract BestASRBuildRevision raw -o - "$info_plist")"
if [[ "$bundle_identifier" != "$MINDLOOM_BUNDLE_ID" ]]; then
  print -u2 "error: unexpected Release bundle identifier: $bundle_identifier"
  exit 1
fi
if [[ "$embedded_revision" != "$build_revision" ]]; then
  print -u2 "error: Release revision mismatch: expected $build_revision, got $embedded_revision"
  exit 1
fi

"$repository_root/script/generate_supply_chain.sh" --package "$app_path"
"$repository_root/script/validate_release_package.sh" --package "$app_path"

# The release copy, as it will be installed (Mindloom.app). Neither it nor the build product
# stays registered with LaunchServices, so nothing finds the product by its bundle id in a
# build folder.
mkdir -p "$BESTASR_RELEASE_ARTIFACT_ROOT"
if [[ -e "$release_app" ]]; then
  "$lsregister" -u "$release_app" >/dev/null 2>&1 || true
  find "$release_app" -depth -delete
fi
ditto "$app_path" "$release_app"
codesign --verify --deep --strict "$release_app"
designated_requirement="$(codesign -d -r- "$app_path" 2>&1 | awk '/^designated =>/{value=$0} END{print value}')"
release_requirement="$(codesign -d -r- "$release_app" 2>&1 | awk '/^designated =>/{value=$0} END{print value}')"
if [[ -z "$designated_requirement" || "$designated_requirement" != "$release_requirement" ]]; then
  print -u2 "error: the release copy's designated requirement differs from the build's"
  exit 1
fi
if [[ "$designated_requirement" != "designated => identifier \"$MINDLOOM_BUNDLE_ID\" and "* ]]; then
  print -u2 "error: the designated requirement does not name $MINDLOOM_BUNDLE_ID"
  exit 1
fi
if [[ "$(plutil -extract CFBundleExecutable raw -o - "$info_plist")" != "$MINDLOOM_EXECUTABLE" ]]; then
  print -u2 "error: the executable is not named $MINDLOOM_EXECUTABLE"
  exit 1
fi
"$lsregister" -u "$release_app" >/dev/null 2>&1 || true
"$repository_root/script/unregister_build_app.sh" "$app_path"

print "release: $release_app"
print "build product: $app_path"
print "revision: $build_revision"
print "version: $(plutil -extract CFBundleShortVersionString raw -o - "$info_plist") ($(plutil -extract CFBundleVersion raw -o - "$info_plist"))"
print "signing authority: $signature_authority"
print "$designated_requirement"
