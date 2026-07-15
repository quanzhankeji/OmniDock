#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ID="com.quanzhankeji.OmniDock"

echo "Resetting OmniDock privacy records for $BUNDLE_ID"
/usr/bin/tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
/usr/bin/tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
/usr/bin/tccutil reset ListenEvent "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "Done. Relaunch OmniDock, then grant permissions again in System Settings."
