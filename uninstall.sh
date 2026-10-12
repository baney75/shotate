#!/bin/bash
# Removes Shotate and its settings. Screenshots are left alone. Also removes Snapmark, the name
# Shotate had before 0.12.
#   curl -fsSL https://raw.githubusercontent.com/baney75/shotate/main/uninstall.sh | bash
# Windows: run "Uninstall Shotate" from Settings › Apps, or uninstall.ps1.
set -euo pipefail

uninstall_macos() {
  osascript -e 'tell application id "com.baney.snapmark" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 25); do
    pgrep -f "/(Shotate|Snapmark).app/Contents/MacOS/" >/dev/null || break; sleep 0.2
  done
  rm -rf "$HOME/Applications/Shotate.app" "$HOME/Applications/Snapmark.app"
  rm -rf "/Applications/Shotate.app" "/Applications/Snapmark.app" 2>/dev/null || true
  defaults delete com.baney.snapmark >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Application Support/Shotate" "$HOME/Library/Application Support/Snapmark" \
         "$HOME/.config/shotate" "$HOME/.config/snapmark"
  # The Screen Recording entry clears itself once the app is gone; this removes it right away.
  tccutil reset ScreenCapture com.baney.snapmark >/dev/null 2>&1 || true
}

uninstall_linux() {
  local sudo=""
  [ "$(id -u)" -eq 0 ] || sudo="sudo"
  for name in shotate snapmark; do
    pkill -x "$name" >/dev/null 2>&1 || true
    if command -v dpkg >/dev/null 2>&1 && dpkg -s "$name" >/dev/null 2>&1; then
      $sudo apt-get remove -y "$name"
    elif command -v rpm >/dev/null 2>&1 && rpm -q "$name" >/dev/null 2>&1; then
      if command -v dnf >/dev/null 2>&1; then $sudo dnf remove -y "$name"; else $sudo zypper --non-interactive remove "$name"; fi
    fi
  done
  rm -f "$HOME/.local/bin/shotate" "$HOME/.local/share/applications/shotate.desktop" \
        "$HOME/.config/autostart/Shotate.desktop" "$HOME/.config/autostart/shotate.desktop" \
        "$HOME/.local/bin/snapmark" "$HOME/.local/share/applications/snapmark.desktop" \
        "$HOME/.config/autostart/Snapmark.desktop" "$HOME/.config/autostart/snapmark.desktop"
  rm -rf "$HOME/.config/shotate" "$HOME/.config/snapmark"
}

case "$(uname -s)" in
  Darwin) uninstall_macos ;;
  Linux) uninstall_linux ;;
  *) echo "On Windows, uninstall Shotate from Settings › Apps." >&2; exit 1 ;;
esac
echo "Shotate is uninstalled. Your screenshots are still in your Pictures/Screenshots folder."
