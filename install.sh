#!/bin/bash
# Installs Snapmark on macOS or Linux:
#   curl -fsSL https://raw.githubusercontent.com/baney75/snapmark/main/install.sh | bash
# macOS: builds from source and puts it in ~/Applications (no Gatekeeper warning, and macOS keeps
#        its Screen Recording permission across updates).
# Linux: installs the latest release: the .deb on Debian and Ubuntu, the .rpm on Fedora and
#        openSUSE, otherwise the AppImage in ~/.local/bin. Windows uses install.ps1.
set -euo pipefail
REPO="baney75/snapmark"
REPO_URL="${SNAPMARK_REPO:-https://github.com/$REPO.git}"
REF="${SNAPMARK_REF:-main}"
bold=$(tput bold 2>/dev/null || true); dim=$(tput dim 2>/dev/null || true); reset=$(tput sgr0 2>/dev/null || true)
step() { printf '%s==>%s %s\n' "$bold" "$reset" "$*"; }
fail() { printf 'Snapmark install failed: %s\n' "$*" >&2; exit 1; }

install_macos() {
  MAJOR=$(sw_vers -productVersion | cut -d. -f1)
  [ "$MAJOR" -ge 13 ] || fail "Snapmark needs macOS 13 Ventura or later (this Mac has $(sw_vers -productVersion))."
  if ! xcode-select -p >/dev/null 2>&1; then
    step "Installing Apple's command line tools (a system dialog will open)"
    xcode-select --install >/dev/null 2>&1 || true
    echo "When the install finishes, run this command again."
    exit 1
  fi
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
  step "Downloading Snapmark"
  git clone --quiet --depth 1 --branch "$REF" "$REPO_URL" "$WORK/snapmark"
  step "Building (about a minute the first time)"
  "$WORK/snapmark/macos/scripts/bundle.sh" --install 2>&1 | sed "s/^/${dim}    /;s/\$/${reset}/" | tail -4
  echo
  printf '%sSnapmark is installed.%s It is in your menu bar now.\n' "$bold" "$reset"
  echo "A welcome window will ask for Screen Recording permission. After that, press ⇧⌘S to capture."
}

# The download URL of the latest release asset whose name matches a pattern.
asset_url() {
  curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*"' | cut -d'"' -f4 | grep -E "$1" | head -1
}

install_linux() {
  case "$(uname -m)" in
    # Tauri names packages amd64/arm64 for .deb, x86_64/aarch64 for .rpm, amd64/aarch64 for AppImage.
    x86_64|amd64) deb_arch=amd64; rpm_arch=x86_64; appimage_arch=amd64 ;;
    aarch64|arm64) deb_arch=arm64; rpm_arch=aarch64; appimage_arch=aarch64 ;;
    *) fail "Snapmark for Linux is built for x86_64 and arm64 (this machine is $(uname -m))." ;;
  esac
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
  local sudo=""
  [ "$(id -u)" -eq 0 ] || sudo="sudo"
  if command -v apt-get >/dev/null 2>&1; then
    url=$(asset_url "_${deb_arch}\.deb$") || true
    [ -n "${url:-}" ] || fail "no .deb for $deb_arch in the latest release."
    step "Downloading $(basename "$url")"
    curl -fsSL -o "$WORK/snapmark.deb" "$url"
    step "Installing with apt (asks for your password)"
    $sudo apt-get install -y "$WORK/snapmark.deb"
  elif command -v dnf >/dev/null 2>&1 || command -v zypper >/dev/null 2>&1; then
    url=$(asset_url "\.${rpm_arch}\.rpm$") || true
    [ -n "${url:-}" ] || fail "no .rpm for $rpm_arch in the latest release."
    step "Downloading $(basename "$url")"
    curl -fsSL -o "$WORK/snapmark.rpm" "$url"
    step "Installing (asks for your password)"
    if command -v dnf >/dev/null 2>&1; then $sudo dnf install -y "$WORK/snapmark.rpm"
    else $sudo zypper --non-interactive install --allow-unsigned-rpm "$WORK/snapmark.rpm"; fi
  else
    url=$(asset_url "_${appimage_arch}\.AppImage$") || true
    [ -n "${url:-}" ] || fail "no AppImage for $appimage_arch in the latest release."
    step "Downloading $(basename "$url")"
    mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
    curl -fsSL -o "$HOME/.local/bin/snapmark" "$url"
    chmod +x "$HOME/.local/bin/snapmark"
    cat > "$HOME/.local/share/applications/snapmark.desktop" <<DESKTOP
[Desktop Entry]
Name=Snapmark
Comment=Screenshot and annotate
Exec=$HOME/.local/bin/snapmark %f
Icon=camera-photo
Type=Application
Categories=Utility;Graphics;
MimeType=image/png;image/jpeg;
DESKTOP
    echo "${dim}    AppImages need FUSE 2 (libfuse2) on some distributions.${reset}"
  fi
  echo
  printf '%sSnapmark is installed.%s Starting it now; it lives in your system tray.\n' "$bold" "$reset"
  if [ "${XDG_SESSION_TYPE:-}" = wayland ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    echo "On Wayland, add a keyboard shortcut in your desktop settings that runs:  snapmark --capture"
  else
    echo "Press Ctrl+Shift+S to capture an area."
  fi
  (command -v snapmark >/dev/null 2>&1 && nohup snapmark >/dev/null 2>&1 &) || true
}

case "$(uname -s)" in
  Darwin) install_macos ;;
  Linux) install_linux ;;
  MINGW*|MSYS*|CYGWIN*) fail "on Windows, run this in PowerShell:  irm https://raw.githubusercontent.com/$REPO/main/install.ps1 | iex" ;;
  *) fail "Snapmark runs on macOS, Windows and Linux (this is $(uname -s))." ;;
esac
