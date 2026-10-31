#!/bin/bash
# Builds Shotate.app (universal: Apple silicon and Intel) into ./build.
#   scripts/bundle.sh            release build
#   scripts/bundle.sh --install  also copy to ~/Applications and register it
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat ../VERSION)  # one version for every platform
APP=build/Shotate.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

ARCHS=(--arch arm64)
if xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1 && [ "${SHOTATE_ARM64_ONLY:-}" != 1 ]; then ARCHS+=(--arch x86_64); fi
swift build -c release "${ARCHS[@]}"
BIN=$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Shotate
cp "$BIN" "$APP/Contents/MacOS/Shotate"

swift scripts/make-icon.swift build/Shotate.iconset >/dev/null
iconutil -c icns build/Shotate.iconset -o "$APP/Contents/Resources/Shotate.icns"

sed "s/@VERSION@/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
# The `shotate` command and the agent skill ship inside the app, so they update with it.
mkdir -p "$APP/Contents/Resources/bin" "$APP/Contents/Resources/skills"
cp Resources/shotate "$APP/Contents/Resources/bin/shotate"
chmod +x "$APP/Contents/Resources/bin/shotate"
cp -R ../skills/shotate "$APP/Contents/Resources/skills/shotate"
# What this build is, for the update check (docs/updates.md): the commit, the channel (stable when
# built from the release tag, otherwise nightly) and when it was built.
COMMIT=$(git rev-parse HEAD 2>/dev/null || echo unknown)
if [ -n "${SHOTATE_CHANNEL:-}" ]; then CHANNEL=$SHOTATE_CHANNEL
elif ! git rev-parse --git-dir >/dev/null 2>&1; then CHANNEL=stable
# (Not `git describe`: the rolling `nightly` tag can sit on the same commit as a release.)
elif git tag --points-at HEAD 2>/dev/null | grep -qx "v$VERSION"; then CHANNEL=stable
else CHANNEL=nightly; fi
for kv in "ShotateCommit:$COMMIT" "ShotateChannel:$CHANNEL" "ShotateBuildDate:$(date -u +%Y-%m-%dT%H:%M:%SZ)"; do
  /usr/libexec/PlistBuddy -c "Add :${kv%%:*} string ${kv#*:}" "$APP/Contents/Info.plist"
done
# A stable local identity keeps the Screen Recording permission across rebuilds; ad-hoc is the fallback.
if [ "${SHOTATE_ADHOC:-}" != 1 ] && IDENT=$(scripts/signing-identity.sh 2>/dev/null); then
  codesign --force --sign "${IDENT%%$'\t'*}" --keychain "${IDENT#*$'\t'}" --identifier com.baney.snapmark "$APP"
else
  ADHOC_NOTE="note: signed ad-hoc, so macOS will ask for Screen Recording again after each update"
  echo "$ADHOC_NOTE" >&2
  codesign --force --sign - --identifier com.baney.snapmark "$APP"
fi
codesign --verify "$APP"
echo "built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/Shotate"))"

if [ "${1:-}" = "--install" ]; then
  DEST="$HOME/Applications/Shotate.app"
  # Shotate was called Snapmark and keeps its bundle ID, so its permission and settings carry over.
  running() { pgrep -f "$DEST/Contents/MacOS/Shotate" >/dev/null || pgrep -f "/Snapmark.app/Contents/MacOS/Snapmark" >/dev/null; }
  # Quit by bundle ID (lets open editors save) instead of killing anything with a matching name.
  osascript -e 'tell application id "com.baney.snapmark" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do running || break; sleep 0.2; done
  if running; then
    echo "Shotate is still running; quit it from the menu bar and run this again." >&2
    exit 1
  fi
  rm -rf "$DEST"
  for LEGACY in "$HOME/Applications/Snapmark.app" "/Applications/Snapmark.app"; do
    [ -d "$LEGACY" ] || continue
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$LEGACY" 2>/dev/null || true
    if rm -rf "$LEGACY" 2>/dev/null; then echo "removed the old $LEGACY"; else echo "remove the old $LEGACY yourself (it needs an administrator)" >&2; fi
  done
  mkdir -p "$HOME/Applications"
  cp -R "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$APP" 2>/dev/null || true
  open "$DEST"
  echo "installed $DEST"
  # `shotate` on the PATH, and the skill where coding agents look, as links into the app. Anything
  # already there that isn't one of these links is left alone.
  link() {
    if [ ! -e "$2" ] && [ ! -L "$2" ]; then ln -s "$1" "$2" && echo "linked $2"
    else case "$(readlink "$2" 2>/dev/null)" in
      */Shotate.app/Contents/*) ln -sfn "$1" "$2" && echo "linked $2" ;;
      *) echo "left $2 as it is (not Shotate's link)" ;;
    esac; fi
  }
  mkdir -p "$HOME/.local/bin"
  link "$DEST/Contents/Resources/bin/shotate" "$HOME/.local/bin/shotate"
  for SKILLS in "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.agents/skills"; do
    [ -d "$SKILLS" ] && link "$DEST/Contents/Resources/skills/shotate" "$SKILLS/shotate"
  done
fi
[ -z "${ADHOC_NOTE:-}" ] || echo "$ADHOC_NOTE"
