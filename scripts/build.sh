#!/bin/bash
# Builds build/Glimpse.app for Apple Silicon. Pass --install to replace /Applications/Glimpse.app.
#
# Signs with GLIMPSE_SIGN_IDENTITY if set, else "Glimpse Local Signing" if it's in the keychain
# (see scripts/make-signing-identity.sh), else ad hoc. Ad hoc builds lose the Screen Recording
# permission on every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
APP="build/Glimpse.app"

if [[ ! -f Resources/AppIcon.icns ]]; then
  scripts/make-icon.sh
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Glimpse" "$APP/Contents/MacOS/Glimpse"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
IDENTITY="${GLIMPSE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-certificate -c "Glimpse Local Signing" >/dev/null 2>&1; then
  IDENTITY="Glimpse Local Signing"
fi
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Glimpse || true
  rm -rf /Applications/Glimpse.app
  cp -R "$APP" /Applications/Glimpse.app
  echo "Installed /Applications/Glimpse.app"
fi
