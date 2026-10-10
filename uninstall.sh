#!/bin/bash
# Removes Snapmark, its settings and its local signing keychain. Screenshots are left alone.
#   curl -fsSL https://raw.githubusercontent.com/baney75/snapmark/main/uninstall.sh | bash
set -euo pipefail
APP="$HOME/Applications/Snapmark.app"
osascript -e 'tell application id "com.baney.snapmark" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 25); do pgrep -f "$APP/Contents/MacOS/Snapmark" >/dev/null || break; sleep 0.2; done
rm -rf "$APP"
defaults delete com.baney.snapmark >/dev/null 2>&1 || true
rm -rf "$HOME/Library/Application Support/Snapmark"
# The Screen Recording entry clears itself once the app is gone; this removes it right away.
tccutil reset ScreenCapture com.baney.snapmark >/dev/null 2>&1 || true
echo "Snapmark is uninstalled. Your screenshots are still in ~/Pictures/Screenshots."
