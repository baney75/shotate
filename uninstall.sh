#!/bin/bash
# Removes Snapmark and its settings. Screenshots are left alone.
#   curl -fsSL https://raw.githubusercontent.com/baney75/snapmark/main/uninstall.sh | bash
# Windows: run "Uninstall Snapmark" from Settings › Apps, or uninstall.ps1.
set -euo pipefail

uninstall_macos() {
  APP="$HOME/Applications/Snapmark.app"
  osascript -e 'tell application id "com.baney.snapmark" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 25); do pgrep -f "$APP/Contents/MacOS/Snapmark" >/dev/null || break; sleep 0.2; done
  rm -rf "$APP"
  defaults delete com.baney.snapmark >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Application Support/Snapmark" "$HOME/.config/snapmark"
  # The Screen Recording entry clears itself once the app is gone; this removes it right away.
  tccutil reset ScreenCapture com.baney.snapmark >/dev/null 2>&1 || true
}

uninstall_linux() {
  pkill -x snapmark >/dev/null 2>&1 || true
  local sudo=""
  [ "$(id -u)" -eq 0 ] || sudo="sudo"
  if command -v dpkg >/dev/null 2>&1 && dpkg -s snapmark >/dev/null 2>&1; then
    $sudo apt-get remove -y snapmark
  elif command -v rpm >/dev/null 2>&1 && rpm -q snapmark >/dev/null 2>&1; then
    if command -v dnf >/dev/null 2>&1; then $sudo dnf remove -y snapmark; else $sudo zypper --non-interactive remove snapmark; fi
  fi
  rm -f "$HOME/.local/bin/snapmark" "$HOME/.local/share/applications/snapmark.desktop" \
        "$HOME/.config/autostart/Snapmark.desktop" "$HOME/.config/autostart/snapmark.desktop"
  rm -rf "$HOME/.config/snapmark"
}

case "$(uname -s)" in
  Darwin) uninstall_macos ;;
  Linux) uninstall_linux ;;
  *) echo "On Windows, uninstall Snapmark from Settings › Apps." >&2; exit 1 ;;
esac
echo "Snapmark is uninstalled. Your screenshots are still in your Pictures/Screenshots folder."
