#!/bin/bash
# Builds Snapmark.app (universal: Apple silicon and Intel) into ./build.
#   scripts/bundle.sh            release build
#   scripts/bundle.sh --install  also copy to ~/Applications and register it
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat ../VERSION)  # one version for every platform
APP=build/Snapmark.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

ARCHS=(--arch arm64)
if xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1 && [ "${SNAPMARK_ARM64_ONLY:-}" != 1 ]; then ARCHS+=(--arch x86_64); fi
swift build -c release "${ARCHS[@]}"
BIN=$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Snapmark
cp "$BIN" "$APP/Contents/MacOS/Snapmark"

swift scripts/make-icon.swift build/Snapmark.iconset >/dev/null
iconutil -c icns build/Snapmark.iconset -o "$APP/Contents/Resources/Snapmark.icns"

sed "s/@VERSION@/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
# A stable local identity keeps the Screen Recording permission across rebuilds; ad-hoc is the fallback.
if [ "${SNAPMARK_ADHOC:-}" != 1 ] && IDENT=$(scripts/signing-identity.sh 2>/dev/null); then
  codesign --force --sign "${IDENT%%$'\t'*}" --keychain "${IDENT#*$'\t'}" --identifier com.baney.snapmark "$APP"
else
  ADHOC_NOTE="note: signed ad-hoc, so macOS will ask for Screen Recording again after each update"
  echo "$ADHOC_NOTE" >&2
  codesign --force --sign - --identifier com.baney.snapmark "$APP"
fi
codesign --verify "$APP"
echo "built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/Snapmark"))"

if [ "${1:-}" = "--install" ]; then
  DEST="$HOME/Applications/Snapmark.app"
  # Quit by bundle ID (lets open editors save) instead of killing anything with a matching name.
  osascript -e 'tell application id "com.baney.snapmark" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do pgrep -f "$DEST/Contents/MacOS/Snapmark" >/dev/null || break; sleep 0.2; done
  if pgrep -f "$DEST/Contents/MacOS/Snapmark" >/dev/null; then
    echo "Snapmark is still running; quit it from the menu bar and run this again." >&2
    exit 1
  fi
  rm -rf "$DEST"
  mkdir -p "$HOME/Applications"
  cp -R "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$APP" 2>/dev/null || true
  open "$DEST"
  echo "installed $DEST"
fi
[ -z "${ADHOC_NOTE:-}" ] || echo "$ADHOC_NOTE"
