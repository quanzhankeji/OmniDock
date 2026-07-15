#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="OmniDock"
BUNDLE_ID="com.quanzhankeji.OmniDock"
MIN_SYSTEM_VERSION="12.3"
MARKETING_VERSION="1.0"
BUILD_NUMBER="3"

usage() {
  echo "usage: $0 [run|--stage|--debug|--logs|--telemetry|--verify|--install]" >&2
}

if [[ $# -gt 1 ]]; then
  usage
  exit 2
fi

case "$MODE" in
  run|--stage|stage|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--install|install)
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac

BUILD_CONFIGURATION="${OMNIDOCK_BUILD_CONFIGURATION:-release}"
if [[ "$MODE" == "--debug" || "$MODE" == "debug" ]]; then
  BUILD_CONFIGURATION="debug"
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_APP_DIR="${TMPDIR:-/tmp}/omnidock-app"
DIST_DIR="${OMNIDOCK_APP_DIR:-$DEFAULT_APP_DIR}"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
INSTALL_DIR="${OMNIDOCK_INSTALL_DIR:-/Applications}"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"

cd "$ROOT_DIR"

swift build \
  -c "$BUILD_CONFIGURATION" \
  -Xswiftc -DOMNIDOCK_APP_BUNDLE_BUILD
BUILD_BINARY="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
mkdir -p "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
if [[ "$BUILD_CONFIGURATION" == "release" && "${OMNIDOCK_STRIP_BINARY:-1}" != "0" ]]; then
  /usr/bin/strip "$APP_BINARY"
fi

if [[ -d "$ROOT_DIR/Resources/AppIcon.iconset" ]]; then
  /usr/bin/iconutil -c icns "$ROOT_DIR/Resources/AppIcon.iconset" -o "$APP_RESOURCES/AppIcon.icns"
fi
if [[ -f "$ROOT_DIR/Resources/PrivacyInfo.xcprivacy" ]]; then
  cp "$ROOT_DIR/Resources/PrivacyInfo.xcprivacy" "$APP_RESOURCES/PrivacyInfo.xcprivacy"
fi
if [[ -f "$ROOT_DIR/LICENSE" ]]; then
  cp "$ROOT_DIR/LICENSE" "$APP_RESOURCES/COPYING.txt"
fi
for LOCALIZATION_DIR in "$ROOT_DIR"/Sources/OmniDockCore/Resources/*.lproj; do
  [[ -d "$LOCALIZATION_DIR" ]] || continue
  LOCALIZATION_NAME="$(basename "$LOCALIZATION_DIR")"
  rm -rf "$APP_RESOURCES/$LOCALIZATION_NAME"
  /usr/bin/ditto "$LOCALIZATION_DIR" "$APP_RESOURCES/$LOCALIZATION_NAME"
done

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>CFBundleShortVersionString</key>
  <string>$MARKETING_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright (c) 2026 Chengdu Quanzhan Technology Co., Ltd</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>ITSAppUsesNonExemptEncryption</key>
  <false/>
  <key>NSScreenCaptureUsageDescription</key>
  <string>OmniDock uses Screen Recording permission to create window thumbnails, including live images and one-time static snapshots, above Dock icons.</string>
  <key>NSInputMonitoringUsageDescription</key>
  <string>OmniDock uses input monitoring permission to detect repeated Dock icon clicks.</string>
</dict>
</plist>
PLIST

verify_bundle_resources() {
  local bundle="$1"
  local contents="$bundle/Contents"
  local resources="$contents/Resources"
  local required_files=(
    "$contents/Info.plist"
    "$resources/AppIcon.icns"
    "$resources/COPYING.txt"
    "$resources/PrivacyInfo.xcprivacy"
    "$resources/en.lproj/AppStrings.strings"
    "$resources/en.lproj/InfoPlist.strings"
    "$resources/zh-Hans.lproj/AppStrings.strings"
    "$resources/zh-Hans.lproj/InfoPlist.strings"
  )

  for required_file in "${required_files[@]}"; do
    if [[ ! -f "$required_file" ]]; then
      echo "Missing required app resource: $required_file" >&2
      return 1
    fi
  done

  /usr/bin/plutil -lint "$contents/Info.plist" >/dev/null
  /usr/bin/plutil -lint "$resources/PrivacyInfo.xcprivacy" >/dev/null
  /usr/bin/plutil -lint "$resources/en.lproj/AppStrings.strings" >/dev/null
  /usr/bin/plutil -lint "$resources/en.lproj/InfoPlist.strings" >/dev/null
  /usr/bin/plutil -lint "$resources/zh-Hans.lproj/AppStrings.strings" >/dev/null
  /usr/bin/plutil -lint "$resources/zh-Hans.lproj/InfoPlist.strings" >/dev/null

  local key
  local expected
  local actual
  while IFS='|' read -r key expected; do
    actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$contents/Info.plist")"
    if [[ "$actual" != "$expected" ]]; then
      echo "Unexpected $key: $actual" >&2
      return 1
    fi
  done <<VALUES
CFBundleIdentifier|$BUNDLE_ID
CFBundleShortVersionString|$MARKETING_VERSION
CFBundleVersion|$BUILD_NUMBER
LSMinimumSystemVersion|$MIN_SYSTEM_VERSION
VALUES
}

verify_bundle_resources "$APP_BUNDLE"

SIGN_IDENTITY="${OMNIDOCK_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGNING_IDENTITIES=()
  while IFS= read -r identity; do
    [[ -n "$identity" ]] && SIGNING_IDENTITIES+=("$identity")
  done < <(
    security find-identity -p codesigning -v 2>/dev/null \
      | awk -F '"' '/Apple Development:/ { print $2 }'
  )
  case "${#SIGNING_IDENTITIES[@]}" in
    0)
      SIGN_IDENTITY="-"
      echo "No Apple Development identity found; using ad-hoc signing. TCC grants may reset after rebuilding." >&2
      ;;
    1)
      SIGN_IDENTITY="${SIGNING_IDENTITIES[0]}"
      ;;
    *)
      echo "Multiple Apple Development identities found. Set OMNIDOCK_SIGN_IDENTITY explicitly." >&2
      exit 1
      ;;
  esac
fi

/usr/bin/xattr -cr "$APP_BUNDLE" >/dev/null 2>&1 || true
/usr/bin/codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE" >/dev/null
/usr/bin/xattr -cr "$APP_BUNDLE" >/dev/null 2>&1 || true
/usr/bin/codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE" >/dev/null

open_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  /usr/bin/open -n "$APP_BUNDLE"
}

install_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  rm -rf "$INSTALLED_APP"
  /usr/bin/ditto "$APP_BUNDLE" "$INSTALLED_APP"
  /usr/bin/xattr -cr "$INSTALLED_APP" >/dev/null 2>&1 || true
  verify_bundle_resources "$INSTALLED_APP"
  /usr/bin/codesign --verify --deep --strict --verbose=4 "$INSTALLED_APP" >/dev/null
  /usr/bin/open -n "$INSTALLED_APP"
}

case "$MODE" in
  run)
    install_app
    ;;
  --stage|stage)
    open_app
    ;;
  --debug|debug)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    install_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    install_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    verify_bundle_resources "$APP_BUNDLE"
    /usr/bin/codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE" >/dev/null
    echo "Verified staged app: $APP_BUNDLE"
    ;;
  --install|install)
    install_app
    ;;
  *)
    usage
    exit 2
    ;;
esac
