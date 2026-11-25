#!/bin/bash
# Removes Yapshot and its settings. Screenshots are left alone. Also removes Shotate and Snapmark,
# the names Yapshot had before.
#   curl -fsSL https://raw.githubusercontent.com/baney75/yapshot/main/uninstall.sh | bash
# Windows: run "Uninstall Yapshot" from Settings › Apps, or uninstall.ps1.
set -euo pipefail

uninstall_macos() {
  osascript -e 'tell application id "com.baney.snapmark" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 25); do
    pgrep -f "/(Yapshot|Shotate|Snapmark).app/Contents/MacOS/" >/dev/null || break; sleep 0.2
  done
  for name in Yapshot Shotate Snapmark; do
    rm -rf "$HOME/Applications/$name.app"
    rm -rf "/Applications/$name.app" 2>/dev/null || true
    rm -rf "$HOME/Library/Application Support/$name" "$HOME/Library/Logs/$name"
  done
  for cmd in yapshot shotate; do
    case "$(readlink "$HOME/.local/bin/$cmd" 2>/dev/null)" in */Yapshot.app/*|*/Shotate.app/*) rm -f "$HOME/.local/bin/$cmd" ;; esac
  done
  defaults delete com.baney.snapmark >/dev/null 2>&1 || true
  rm -rf "$HOME/.config/yapshot" "$HOME/.config/shotate" "$HOME/.config/snapmark"
  # The Screen Recording entry clears itself once the app is gone; this removes it right away.
  tccutil reset ScreenCapture com.baney.snapmark >/dev/null 2>&1 || true
}

uninstall_linux() {
  local sudo=""
  [ "$(id -u)" -eq 0 ] || sudo="sudo"
  for name in yapshot shotate snapmark; do
    pkill -x "$name" >/dev/null 2>&1 || true
    if command -v dpkg >/dev/null 2>&1 && dpkg -s "$name" >/dev/null 2>&1; then
      $sudo apt-get remove -y "$name"
    elif command -v rpm >/dev/null 2>&1 && rpm -q "$name" >/dev/null 2>&1; then
      if command -v dnf >/dev/null 2>&1; then $sudo dnf remove -y "$name"; else $sudo zypper --non-interactive remove "$name"; fi
    fi
  done
  for name in yapshot shotate snapmark; do
    title="$(printf '%s' "${name:0:1}" | tr a-z A-Z)${name:1}"
    rm -f "$HOME/.local/bin/$name" "$HOME/.local/share/applications/$name.desktop" \
          "$HOME/.config/autostart/$title.desktop" "$HOME/.config/autostart/$name.desktop"
    rm -rf "$HOME/.config/$name"
  done
}

case "$(uname -s)" in
  Darwin) uninstall_macos ;;
  Linux) uninstall_linux ;;
  *) echo "On Windows, uninstall Yapshot from Settings › Apps." >&2; exit 1 ;;
esac
echo "Yapshot is uninstalled. Your screenshots are still in your Pictures/Screenshots folder."
