#!/usr/bin/env bash
set -euo pipefail

APP_NAME="OmniDock"
BUNDLE_ID="com.quanzhankeji.OmniDock"
MIN_SYSTEM_VERSION="12.3"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VERSION=""
BUILD_NUMBER=""
LICENSE_MODE=""
NOTARY_PROFILE="${OMNIDOCK_NOTARY_PROFILE:-}"
NOTARY_SUBMISSION_ID="${OMNIDOCK_NOTARY_SUBMISSION_ID:-}"
NOTARY_TIMEOUT="${OMNIDOCK_NOTARY_TIMEOUT:-2h}"
SIGN_IDENTITY="${OMNIDOCK_SIGN_IDENTITY:-}"
BINARY_LICENSE_PATH="${OMNIDOCK_BINARY_LICENSE:-}"
BINARY_LICENSE_SHA256=""
BUNDLED_LICENSE_NAME=""
OUTPUT_ROOT="${OMNIDOCK_RELEASE_DIR:-$ROOT_DIR/dist/release}"
WORK_DIR=""
BUILT_BINARY=""
LAST_SUBMISSION_ID=""

usage() {
  cat <<'USAGE'
Usage:
  ./script/release.sh --version <marketing-version> --build <build-number> \
    --license-mode <gpl|eula> --notary-profile <keychain-profile> [options]

Required:
  --version <version>             CFBundleShortVersionString, for example 1.0
  --build <number>               Positive integer CFBundleVersion
  --license-mode <gpl|eula>      Binary distribution license
  --notary-profile <profile>     notarytool Keychain profile name

Options:
  --binary-license <path>        Approved EULA; required only for eula mode
  --signing-identity <identity>  Developer ID Application identity
  --notary-submission-id <uuid> Resume an existing submission; do not upload again
  --notary-timeout <duration>    Maximum wait time (default: 2h)
  --output-dir <directory>       Release output root (default: dist/release)
  -h, --help                     Show this help

Environment equivalents:
  OMNIDOCK_NOTARY_PROFILE
  OMNIDOCK_NOTARY_SUBMISSION_ID
  OMNIDOCK_NOTARY_TIMEOUT
  OMNIDOCK_SIGN_IDENTITY
  OMNIDOCK_BINARY_LICENSE
  OMNIDOCK_RELEASE_DIR

The script signs and notarizes locally produced artifacts. It does not create
Git commits, push source, upload to GitHub, or publish a release.
USAGE
}

die() {
  echo "release: $*" >&2
  exit 1
}

log() {
  echo "==> $*"
}

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}

trap cleanup EXIT INT TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || die "--version requires a value"
      VERSION="$2"
      shift 2
      ;;
    --build)
      [[ $# -ge 2 ]] || die "--build requires a value"
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --license-mode)
      [[ $# -ge 2 ]] || die "--license-mode requires a value"
      LICENSE_MODE="$2"
      shift 2
      ;;
    --notary-profile)
      [[ $# -ge 2 ]] || die "--notary-profile requires a value"
      NOTARY_PROFILE="$2"
      shift 2
      ;;
    --signing-identity)
      [[ $# -ge 2 ]] || die "--signing-identity requires a value"
      SIGN_IDENTITY="$2"
      shift 2
      ;;
    --notary-submission-id)
      [[ $# -ge 2 ]] || die "--notary-submission-id requires a value"
      NOTARY_SUBMISSION_ID="$2"
      shift 2
      ;;
    --notary-timeout)
      [[ $# -ge 2 ]] || die "--notary-timeout requires a value"
      NOTARY_TIMEOUT="$2"
      shift 2
      ;;
    --binary-license)
      [[ $# -ge 2 ]] || die "--binary-license requires a value"
      BINARY_LICENSE_PATH="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || die "--output-dir requires a value"
      OUTPUT_ROOT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$VERSION" ]] || die "--version is required"
[[ -n "$BUILD_NUMBER" ]] || die "--build is required"
[[ -n "$LICENSE_MODE" ]] || die "--license-mode is required"
[[ -n "$NOTARY_PROFILE" ]] || die "--notary-profile or OMNIDOCK_NOTARY_PROFILE is required"
[[ "$VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] \
  || die "version must contain two or three dot-separated integers"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] \
  || die "build number must be a positive integer"
[[ "$NOTARY_TIMEOUT" =~ ^[1-9][0-9]*([smh])?$ ]] \
  || die "notary timeout must be a positive duration such as 30m or 2h"
if [[ -n "$NOTARY_SUBMISSION_ID" ]]; then
  [[ "$NOTARY_SUBMISSION_ID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
    || die "notary submission ID must be a UUID"
fi

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

for command_name in \
  awk codesign date ditto dsymutil dwarfdump git iconutil lipo plutil \
  security shasum spctl stat strip swift xattr xcodebuild xcrun; do
  require_command "$command_name"
done

git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "release must run from a Git worktree"
[[ -z "$(git -C "$ROOT_DIR" status --porcelain=v1 --untracked-files=all)" ]] \
  || die "worktree is dirty; commit or stash all changes before releasing"
SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"

[[ -x /usr/libexec/PlistBuddy ]] || die "required command not found: /usr/libexec/PlistBuddy"
/usr/bin/xcrun --find notarytool >/dev/null 2>&1 || die "notarytool is unavailable in the active Xcode toolchain"
/usr/bin/xcrun --find stapler >/dev/null 2>&1 || die "stapler is unavailable in the active Xcode toolchain"

for required_file in \
  "$ROOT_DIR/Package.swift" \
  "$ROOT_DIR/LICENSE" \
  "$ROOT_DIR/LICENSING.md" \
  "$ROOT_DIR/NOTICE" \
  "$ROOT_DIR/script/generate_xcode_project.py" \
  "$ROOT_DIR/Resources/PrivacyInfo.xcprivacy" \
  "$ROOT_DIR/Sources/OmniDockCore/Resources/en.lproj/AppStrings.strings" \
  "$ROOT_DIR/Sources/OmniDockCore/Resources/en.lproj/InfoPlist.strings" \
  "$ROOT_DIR/Sources/OmniDockCore/Resources/zh-Hans.lproj/AppStrings.strings" \
  "$ROOT_DIR/Sources/OmniDockCore/Resources/zh-Hans.lproj/InfoPlist.strings"; do
  [[ -f "$required_file" ]] || die "required release input is missing: $required_file"
done
SOURCE_LICENSE_SHA256="$(/usr/bin/shasum -a 256 "$ROOT_DIR/LICENSE" | /usr/bin/awk '{ print $1 }')"
case "$LICENSE_MODE" in
  gpl)
    [[ -z "$BINARY_LICENSE_PATH" ]] \
      || die "--binary-license is not used with GPL distribution"
    BINARY_LICENSE_PATH="$ROOT_DIR/LICENSE"
    BINARY_LICENSE_SHA256="$SOURCE_LICENSE_SHA256"
    BUNDLED_LICENSE_NAME="COPYING.txt"
    ;;
  eula)
    [[ -n "$BINARY_LICENSE_PATH" ]] \
      || die "--binary-license or OMNIDOCK_BINARY_LICENSE is required for eula mode"
    [[ -f "$BINARY_LICENSE_PATH" && -s "$BINARY_LICENSE_PATH" ]] \
      || die "binary license must be a nonempty file: $BINARY_LICENSE_PATH"
    BINARY_LICENSE_PATH="$(cd "$(dirname "$BINARY_LICENSE_PATH")" && pwd -P)/$(basename "$BINARY_LICENSE_PATH")"
    case "$BINARY_LICENSE_PATH" in
      "$ROOT_DIR"/*)
        die "binary license must be stored outside the source repository"
        ;;
    esac
    BINARY_LICENSE_SHA256="$(/usr/bin/shasum -a 256 "$BINARY_LICENSE_PATH" | /usr/bin/awk '{ print $1 }')"
    [[ "$BINARY_LICENSE_SHA256" != "$SOURCE_LICENSE_SHA256" ]] \
      || die "binary EULA must not be the GPL source license"
    BUNDLED_LICENSE_NAME="EULA.txt"
    ;;
  *)
    die "license mode must be 'gpl' or 'eula'"
    ;;
esac
[[ -d "$ROOT_DIR/Resources/AppIcon.iconset" ]] \
  || die "required release input is missing: $ROOT_DIR/Resources/AppIcon.iconset"

resolve_signing_identity() {
  local identity
  local matched=0
  local identities=()

  while IFS= read -r identity; do
    [[ -n "$identity" ]] && identities+=("$identity")
  done < <(
    /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
      | /usr/bin/awk -F '"' '/Developer ID Application:/ { print $2 }'
  )

  if [[ -n "$SIGN_IDENTITY" ]]; then
    [[ "$SIGN_IDENTITY" == Developer\ ID\ Application:* ]] \
      || die "signing identity must be a Developer ID Application identity"
    for identity in "${identities[@]}"; do
      if [[ "$identity" == "$SIGN_IDENTITY" ]]; then
        matched=1
        break
      fi
    done
    [[ "$matched" -eq 1 ]] \
      || die "the requested Developer ID Application identity is not available with a private key"
    return
  fi

  case "${#identities[@]}" in
    0)
      die "no Developer ID Application signing identity with a private key was found"
      ;;
    1)
      SIGN_IDENTITY="${identities[0]}"
      ;;
    *)
      die "multiple Developer ID Application identities found; pass --signing-identity"
      ;;
  esac
}

resolve_signing_identity

log "Checking notarytool Keychain profile"
if ! /usr/bin/xcrun notarytool history \
  --keychain-profile "$NOTARY_PROFILE" \
  --output-format json >/dev/null; then
  die "notarytool could not authenticate with Keychain profile '$NOTARY_PROFILE'"
fi

ARTIFACT_BASE="$APP_NAME-$VERSION-build-$BUILD_NUMBER"
RELEASE_DIR="$OUTPUT_ROOT/$VERSION-$BUILD_NUMBER"
[[ ! -e "$RELEASE_DIR" ]] \
  || die "release output already exists: $RELEASE_DIR"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/omnidock-release.XXXXXX")"
APP_BUNDLE="$WORK_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
DSYM_BUNDLE="$WORK_DIR/$APP_NAME.app.dSYM"
DSYM_ZIP="$WORK_DIR/$ARTIFACT_BASE.dSYM.zip"
APP_NOTARY_ZIP="$WORK_DIR/$ARTIFACT_BASE-notary.zip"
APP_ZIP="$WORK_DIR/$ARTIFACT_BASE.zip"
MANIFEST_PATH="$WORK_DIR/$ARTIFACT_BASE-manifest.json"
CHECKSUM_PATH="$WORK_DIR/$ARTIFACT_BASE-SHA256SUMS"

log "Running release source checks"
"$ROOT_DIR/script/generate_xcode_project.py" --check
git -C "$ROOT_DIR" diff --check
/usr/bin/swift test \
  --package-path "$ROOT_DIR" \
  --scratch-path "$WORK_DIR/tests" \
  -Xswiftc -warnings-as-errors

build_architecture() {
  local architecture="$1"
  local scratch_path="$WORK_DIR/build-$architecture"
  local target_triple="$architecture-apple-macosx$MIN_SYSTEM_VERSION"
  local binary_directory

  log "Building SwiftPM release for $architecture"
  /usr/bin/swift build \
    --package-path "$ROOT_DIR" \
    --scratch-path "$scratch_path" \
    --configuration release \
    --triple "$target_triple" \
    --disable-index-store \
    --product "$APP_NAME" \
    -Xswiftc -g \
    -Xswiftc -warnings-as-errors \
    -Xswiftc -DOMNIDOCK_APP_BUNDLE_BUILD

  binary_directory="$(
    /usr/bin/swift build \
      --package-path "$ROOT_DIR" \
      --scratch-path "$scratch_path" \
      --configuration release \
      --triple "$target_triple" \
      --disable-index-store \
      --show-bin-path
  )"
  BUILT_BINARY="$binary_directory/$APP_NAME"
  [[ -x "$BUILT_BINARY" ]] || die "$architecture build did not produce $APP_NAME"
  /usr/bin/lipo "$BUILT_BINARY" -verify_arch "$architecture" \
    || die "$architecture build has an unexpected architecture"
}

verify_architectures() {
  local binary="$1"
  local architectures

  /usr/bin/lipo "$binary" -verify_arch arm64 x86_64 \
    || die "binary is not Universal 2: $binary"
  architectures="$(/usr/bin/lipo "$binary" -archs)"
  [[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]] \
    || die "binary architectures are incomplete: $architectures"
  [[ "$(echo "$architectures" | /usr/bin/awk '{ print NF }')" -eq 2 ]] \
    || die "binary contains unexpected architectures: $architectures"
}

verify_dsym() {
  local architecture
  local binary_uuid
  local dsym_uuid

  for architecture in arm64 x86_64; do
    binary_uuid="$(
      /usr/bin/dwarfdump --uuid "$APP_BINARY" \
        | /usr/bin/awk -v arch="($architecture)" '$3 == arch { print $2; exit }'
    )"
    dsym_uuid="$(
      /usr/bin/dwarfdump --uuid "$DSYM_BUNDLE" \
        | /usr/bin/awk -v arch="($architecture)" '$3 == arch { print $2; exit }'
    )"
    [[ -n "$binary_uuid" && "$binary_uuid" == "$dsym_uuid" ]] \
      || die "dSYM UUID does not match the $architecture executable"
  done
}

build_architecture arm64
ARM64_BINARY="$BUILT_BINARY"
build_architecture x86_64
X86_64_BINARY="$BUILT_BINARY"

log "Creating Universal 2 executable and dSYM"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
/usr/bin/lipo -create "$ARM64_BINARY" "$X86_64_BINARY" -output "$APP_BINARY"
chmod 755 "$APP_BINARY"
verify_architectures "$APP_BINARY"
/usr/bin/dsymutil "$APP_BINARY" -o "$DSYM_BUNDLE"
/usr/bin/strip -S "$APP_BINARY"
verify_dsym

log "Assembling app resources"
/usr/bin/iconutil \
  -c icns \
  "$ROOT_DIR/Resources/AppIcon.iconset" \
  -o "$APP_RESOURCES/AppIcon.icns"
/usr/bin/ditto "$ROOT_DIR/Resources/PrivacyInfo.xcprivacy" "$APP_RESOURCES/PrivacyInfo.xcprivacy"
/usr/bin/ditto "$BINARY_LICENSE_PATH" "$APP_RESOURCES/$BUNDLED_LICENSE_NAME"
for localization_dir in "$ROOT_DIR"/Sources/OmniDockCore/Resources/*.lproj; do
  [[ -d "$localization_dir" ]] || continue
  /usr/bin/ditto "$localization_dir" "$APP_RESOURCES/$(basename "$localization_dir")"
done

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>zh-Hans</string>
  </array>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>ITSAppUsesNonExemptEncryption</key>
  <false/>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright (c) 2026 Chengdu Quanzhan Technology Co., Ltd</string>
  <key>NSInputMonitoringUsageDescription</key>
  <string>OmniDock uses Input Monitoring permission to detect repeated Dock icon clicks.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>OmniDock uses Screen Recording permission to create window thumbnails, including live images and one-time static snapshots, above Dock icons.</string>
</dict>
</plist>
PLIST

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

assert_plist_value() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local actual

  actual="$(plist_value "$plist" "$key")"
  [[ "$actual" == "$expected" ]] \
    || die "$plist has $key='$actual'; expected '$expected'"
}

verify_privacy_reason() {
  local manifest="$1"
  local expected_category="$2"
  local expected_reason="$3"
  local api_count
  local reason_count
  local api_index
  local reason_index
  local category
  local reason

  api_count="$(/usr/bin/plutil -extract NSPrivacyAccessedAPITypes raw "$manifest")"
  api_index=0
  while [[ "$api_index" -lt "$api_count" ]]; do
    category="$(
      /usr/bin/plutil \
        -extract "NSPrivacyAccessedAPITypes.$api_index.NSPrivacyAccessedAPIType" raw \
        "$manifest"
    )"
    if [[ "$category" == "$expected_category" ]]; then
      reason_count="$(
        /usr/bin/plutil \
          -extract "NSPrivacyAccessedAPITypes.$api_index.NSPrivacyAccessedAPITypeReasons" raw \
          "$manifest"
      )"
      reason_index=0
      while [[ "$reason_index" -lt "$reason_count" ]]; do
        reason="$(
          /usr/bin/plutil \
            -extract "NSPrivacyAccessedAPITypes.$api_index.NSPrivacyAccessedAPITypeReasons.$reason_index" raw \
            "$manifest"
        )"
        [[ "$reason" == "$expected_reason" ]] && return 0
        reason_index=$((reason_index + 1))
      done
    fi
    api_index=$((api_index + 1))
  done

  die "privacy manifest is missing $expected_category reason $expected_reason"
}

verify_bundle_resources() {
  local bundle="$1"
  local contents="$bundle/Contents"
  local resources="$contents/Resources"
  local required_file

  for required_file in \
    "$contents/Info.plist" \
    "$contents/MacOS/$APP_NAME" \
    "$resources/AppIcon.icns" \
    "$resources/$BUNDLED_LICENSE_NAME" \
    "$resources/PrivacyInfo.xcprivacy" \
    "$resources/en.lproj/AppStrings.strings" \
    "$resources/en.lproj/InfoPlist.strings" \
    "$resources/zh-Hans.lproj/AppStrings.strings" \
    "$resources/zh-Hans.lproj/InfoPlist.strings"; do
    [[ -f "$required_file" ]] || die "app bundle is missing required resource: $required_file"
  done

  [[ -x "$contents/MacOS/$APP_NAME" ]] || die "app executable is not executable"
  /usr/bin/plutil -lint "$contents/Info.plist" >/dev/null
  /usr/bin/plutil -lint "$resources/PrivacyInfo.xcprivacy" >/dev/null
  /usr/bin/plutil -lint "$resources/en.lproj/AppStrings.strings" >/dev/null
  /usr/bin/plutil -lint "$resources/en.lproj/InfoPlist.strings" >/dev/null
  /usr/bin/plutil -lint "$resources/zh-Hans.lproj/AppStrings.strings" >/dev/null
  /usr/bin/plutil -lint "$resources/zh-Hans.lproj/InfoPlist.strings" >/dev/null

  assert_plist_value "$contents/Info.plist" CFBundleExecutable "$APP_NAME"
  assert_plist_value "$contents/Info.plist" CFBundleIdentifier "$BUNDLE_ID"
  assert_plist_value "$contents/Info.plist" CFBundleShortVersionString "$VERSION"
  assert_plist_value "$contents/Info.plist" CFBundleVersion "$BUILD_NUMBER"
  assert_plist_value "$contents/Info.plist" LSMinimumSystemVersion "$MIN_SYSTEM_VERSION"
  verify_privacy_reason \
    "$resources/PrivacyInfo.xcprivacy" \
    NSPrivacyAccessedAPICategoryUserDefaults \
    CA92.1
  verify_privacy_reason \
    "$resources/PrivacyInfo.xcprivacy" \
    NSPrivacyAccessedAPICategorySystemBootTime \
    35F9.1
  verify_architectures "$contents/MacOS/$APP_NAME"
}

verify_signed_app() {
  local bundle="$1"
  local details

  /usr/bin/codesign --verify --deep --strict --verbose=4 "$bundle"
  details="$(/usr/bin/codesign --display --verbose=4 "$bundle" 2>&1)"
  [[ "$details" == *"Authority=Developer ID Application:"* ]] \
    || die "app is not signed with Developer ID Application"
  [[ "$details" == *"runtime"* ]] || die "hardened runtime is not enabled"
  [[ "$details" == *"Timestamp="* ]] || die "app signature has no secure timestamp"
}

notarize() {
  local artifact="$1"
  local label="$2"
  local result_path="$WORK_DIR/$label-notary-result.json"
  local info_path="$WORK_DIR/$label-notary-info.json"
  local log_path="$WORK_DIR/$label-notary-log.json"
  local expected_name
  local submission_name
  local status

  expected_name="$(basename "$artifact")"
  if [[ -n "$NOTARY_SUBMISSION_ID" ]]; then
    LAST_SUBMISSION_ID="$NOTARY_SUBMISSION_ID"
    log "Resuming notarization submission $LAST_SUBMISSION_ID"
  else
    log "Submitting $label for notarization"
    if ! /usr/bin/xcrun notarytool submit "$artifact" \
      --keychain-profile "$NOTARY_PROFILE" \
      --no-wait \
      --output-format json >"$result_path"; then
      die "notarytool failed while submitting $label"
    fi
    LAST_SUBMISSION_ID="$(/usr/bin/plutil -extract id raw "$result_path")"
    log "Notarization submission ID: $LAST_SUBMISSION_ID"
  fi

  if ! /usr/bin/xcrun notarytool info \
    "$LAST_SUBMISSION_ID" \
    --keychain-profile "$NOTARY_PROFILE" \
    --output-format json >"$info_path"; then
    die "could not read notarization submission $LAST_SUBMISSION_ID"
  fi
  submission_name="$(/usr/bin/plutil -extract name raw "$info_path")"
  [[ "$submission_name" == "$expected_name" ]] \
    || die "submission $LAST_SUBMISSION_ID is for '$submission_name', not '$expected_name'"
  status="$(/usr/bin/plutil -extract status raw "$info_path")"

  if [[ "$status" == "In Progress" ]]; then
    log "Waiting up to $NOTARY_TIMEOUT for notarization"
    if /usr/bin/xcrun notarytool wait \
      "$LAST_SUBMISSION_ID" \
      --keychain-profile "$NOTARY_PROFILE" \
      --timeout "$NOTARY_TIMEOUT" \
      --output-format json >"$result_path"; then
      status="$(/usr/bin/plutil -extract status raw "$result_path")"
    else
      /usr/bin/xcrun notarytool info \
        "$LAST_SUBMISSION_ID" \
        --keychain-profile "$NOTARY_PROFILE" \
        --output-format json >"$info_path" || true
      status="$(/usr/bin/plutil -extract status raw "$info_path" 2>/dev/null || true)"
      if [[ "$status" == "In Progress" ]]; then
        die "notarization is still in progress; rerun with --notary-submission-id $LAST_SUBMISSION_ID"
      fi
    fi
  fi

  if [[ "$status" != "Accepted" ]]; then
    /usr/bin/xcrun notarytool log \
      "$LAST_SUBMISSION_ID" \
      "$log_path" \
      --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || true
    [[ ! -f "$log_path" ]] || cat "$log_path" >&2
    die "notarization of $label finished with status '${status:-unknown}'"
  fi
}

verify_bundle_resources "$APP_BUNDLE"

log "Clearing extended attributes and signing app"
/usr/bin/xattr -cr "$APP_BUNDLE"
/usr/bin/xattr -cr "$DSYM_BUNDLE"
/usr/bin/codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "$SIGN_IDENTITY" \
  "$APP_BUNDLE"
verify_signed_app "$APP_BUNDLE"

/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$APP_NOTARY_ZIP"
notarize "$APP_NOTARY_ZIP" app
APP_SUBMISSION_ID="$LAST_SUBMISSION_ID"
/usr/bin/xcrun stapler staple -v "$APP_BUNDLE"
/usr/bin/xcrun stapler validate -v "$APP_BUNDLE"
verify_signed_app "$APP_BUNDLE"
/usr/sbin/spctl --assess --type execute --verbose=4 "$APP_BUNDLE"

log "Creating app and dSYM archives, manifest, and checksums"
[[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" == "$SOURCE_COMMIT" ]] \
  || die "source commit changed while the release was being built"
[[ -z "$(git -C "$ROOT_DIR" status --porcelain=v1 --untracked-files=all)" ]] \
  || die "worktree changed while the release was being built"
/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"
/usr/bin/ditto -c -k --keepParent "$DSYM_BUNDLE" "$DSYM_ZIP"
APP_SHA256="$(/usr/bin/shasum -a 256 "$APP_ZIP" | /usr/bin/awk '{ print $1 }')"
DSYM_SHA256="$(/usr/bin/shasum -a 256 "$DSYM_ZIP" | /usr/bin/awk '{ print $1 }')"
BUILT_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
SWIFT_TOOLCHAIN="$(/usr/bin/swift --version | /usr/bin/awk 'NR == 1 { print; exit }')"
XCODE_TOOLCHAIN="$(/usr/bin/xcodebuild -version | /usr/bin/awk 'NR == 1 { first = $0 } NR == 2 { print first " " $0 }')"
SDK_VERSION="$(/usr/bin/xcrun --sdk macosx --show-sdk-version)"

/usr/bin/plutil -create json "$MANIFEST_PATH"
/usr/bin/plutil -insert schemaVersion -integer 1 "$MANIFEST_PATH"
/usr/bin/plutil -insert appName -string "$APP_NAME" "$MANIFEST_PATH"
/usr/bin/plutil -insert bundleIdentifier -string "$BUNDLE_ID" "$MANIFEST_PATH"
/usr/bin/plutil -insert version -string "$VERSION" "$MANIFEST_PATH"
/usr/bin/plutil -insert build -string "$BUILD_NUMBER" "$MANIFEST_PATH"
/usr/bin/plutil -insert minimumSystemVersion -string "$MIN_SYSTEM_VERSION" "$MANIFEST_PATH"
/usr/bin/plutil -insert builtAt -string "$BUILT_AT" "$MANIFEST_PATH"
/usr/bin/plutil -insert sourceCommit -string "$SOURCE_COMMIT" "$MANIFEST_PATH"
/usr/bin/plutil -insert sourceTreeDirty -bool false "$MANIFEST_PATH"
/usr/bin/plutil -insert swiftToolchain -string "$SWIFT_TOOLCHAIN" "$MANIFEST_PATH"
/usr/bin/plutil -insert xcodeToolchain -string "$XCODE_TOOLCHAIN" "$MANIFEST_PATH"
/usr/bin/plutil -insert macOSSDK -string "$SDK_VERSION" "$MANIFEST_PATH"
/usr/bin/plutil -insert distribution -string developer-id "$MANIFEST_PATH"
/usr/bin/plutil -insert licensing -dictionary "$MANIFEST_PATH"
/usr/bin/plutil -insert licensing.source -string GPL-3.0-only "$MANIFEST_PATH"
/usr/bin/plutil -insert licensing.mode -string "$LICENSE_MODE" "$MANIFEST_PATH"
/usr/bin/plutil -insert licensing.bundledFile -string "$BUNDLED_LICENSE_NAME" "$MANIFEST_PATH"
if [[ "$LICENSE_MODE" == "gpl" ]]; then
  /usr/bin/plutil -insert licensing.binary -string GPL-3.0-only "$MANIFEST_PATH"
else
  /usr/bin/plutil -insert licensing.binary -string separate-eula "$MANIFEST_PATH"
  /usr/bin/plutil -insert licensing.binaryEULASHA256 -string "$BINARY_LICENSE_SHA256" "$MANIFEST_PATH"
fi
/usr/bin/plutil -insert hardenedRuntime -bool true "$MANIFEST_PATH"
/usr/bin/plutil -insert architectures -array "$MANIFEST_PATH"
/usr/bin/plutil -insert architectures.0 -string arm64 "$MANIFEST_PATH"
/usr/bin/plutil -insert architectures.1 -string x86_64 "$MANIFEST_PATH"
/usr/bin/plutil -insert notarization -dictionary "$MANIFEST_PATH"
/usr/bin/plutil -insert notarization.appSubmissionId -string "$APP_SUBMISSION_ID" "$MANIFEST_PATH"
/usr/bin/plutil -insert artifacts -array "$MANIFEST_PATH"
/usr/bin/plutil -insert artifacts.0 -dictionary "$MANIFEST_PATH"
/usr/bin/plutil -insert artifacts.0.name -string "$(basename "$APP_ZIP")" "$MANIFEST_PATH"
/usr/bin/plutil -insert artifacts.0.kind -string app-zip "$MANIFEST_PATH"
/usr/bin/plutil -insert artifacts.0.sha256 -string "$APP_SHA256" "$MANIFEST_PATH"
/usr/bin/plutil -insert artifacts.0.bytes -integer "$(/usr/bin/stat -f '%z' "$APP_ZIP")" "$MANIFEST_PATH"
/usr/bin/plutil -insert artifacts.1 -dictionary "$MANIFEST_PATH"
/usr/bin/plutil -insert artifacts.1.name -string "$(basename "$DSYM_ZIP")" "$MANIFEST_PATH"
/usr/bin/plutil -insert artifacts.1.kind -string dsym "$MANIFEST_PATH"
/usr/bin/plutil -insert artifacts.1.sha256 -string "$DSYM_SHA256" "$MANIFEST_PATH"
/usr/bin/plutil -insert artifacts.1.bytes -integer "$(/usr/bin/stat -f '%z' "$DSYM_ZIP")" "$MANIFEST_PATH"
/usr/bin/plutil -convert json -r "$MANIFEST_PATH"
/usr/bin/plutil -lint "$MANIFEST_PATH" >/dev/null

(
  cd "$WORK_DIR"
  /usr/bin/shasum -a 256 \
    "$(basename "$APP_ZIP")" \
    "$(basename "$DSYM_ZIP")" \
    "$(basename "$MANIFEST_PATH")" >"$(basename "$CHECKSUM_PATH")"
)

mkdir -p "$RELEASE_DIR"
/usr/bin/ditto "$APP_ZIP" "$RELEASE_DIR/$(basename "$APP_ZIP")"
/usr/bin/ditto "$DSYM_ZIP" "$RELEASE_DIR/$(basename "$DSYM_ZIP")"
/usr/bin/ditto "$MANIFEST_PATH" "$RELEASE_DIR/$(basename "$MANIFEST_PATH")"
/usr/bin/ditto "$CHECKSUM_PATH" "$RELEASE_DIR/$(basename "$CHECKSUM_PATH")"

log "Release artifacts are ready in $RELEASE_DIR"
for artifact in "$RELEASE_DIR"/*; do
  echo "  $(basename "$artifact")"
done
