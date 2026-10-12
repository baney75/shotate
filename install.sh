#!/bin/bash
# Installs Shotate on macOS or Linux:
#   curl -fsSL https://raw.githubusercontent.com/baney75/shotate/main/install.sh | bash
# macOS: builds from source and puts it in ~/Applications (no Gatekeeper warning, and macOS keeps
#        its Screen Recording permission across updates).
# Linux: installs the nightly preview (stable releases are macOS only for now): the .deb on Debian
#        and Ubuntu, the .rpm on Fedora and openSUSE, otherwise the AppImage in ~/.local/bin.
#        Windows uses install.ps1.
# macOS: Stable by default. For the nightly build of the newest code (docs/updates.md):
#   curl -fsSL https://raw.githubusercontent.com/baney75/shotate/main/install.sh | bash -s -- --nightly
# Running it again updates in place; Shotate can also update itself from its menu.
set -euo pipefail
REPO="baney75/shotate"
REPO_URL="${SHOTATE_REPO:-https://github.com/$REPO.git}"
CHANNEL="${SHOTATE_CHANNEL:-stable}"
for arg in "$@"; do case "$arg" in --nightly) CHANNEL=nightly ;; --stable) CHANNEL=stable ;; esac; done
case "$CHANNEL" in stable|nightly) ;; *) echo "Unknown channel: $CHANNEL (use stable or nightly)" >&2; exit 1 ;; esac
bold=$(tput bold 2>/dev/null || true); dim=$(tput dim 2>/dev/null || true); reset=$(tput sgr0 2>/dev/null || true)
step() { printf '%s==>%s %s\n' "$bold" "$reset" "$*"; }
fail() { printf 'Shotate install failed: %s\n' "$*" >&2; exit 1; }

install_macos() {
  MAJOR=$(sw_vers -productVersion | cut -d. -f1)
  [ "$MAJOR" -ge 13 ] || fail "Shotate needs macOS 13 Ventura or later (this Mac has $(sw_vers -productVersion))."
  if ! xcode-select -p >/dev/null 2>&1; then
    step "Installing Apple's command line tools (a system dialog will open)"
    xcode-select --install >/dev/null 2>&1 || true
    echo "When the install finishes, run this command again."
    exit 1
  fi
  # Stable builds the newest release tag; nightly builds main.
  REF="${SHOTATE_REF:-}"
  if [ -z "$REF" ]; then
    if [ "$CHANNEL" = nightly ]; then REF=main
    else REF=$(curl -fsSI "https://github.com/$REPO/releases/latest" | tr -d '\r' | sed -n 's#^[Ll]ocation: .*/tag/##p'); fi
  fi
  [ -n "$REF" ] || fail "couldn't find the latest release."
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
  step "Downloading Shotate ($CHANNEL, $REF)"
  git clone --quiet --depth 1 --branch "$REF" "$REPO_URL" "$WORK/shotate"
  step "Building (about a minute the first time)"
  SHOTATE_CHANNEL="$CHANNEL" "$WORK/shotate/macos/scripts/bundle.sh" --install 2>&1 | sed "s/^/${dim}    /;s/\$/${reset}/" | tail -4
  echo
  printf '%sShotate is installed.%s It is in your menu bar now.\n' "$bold" "$reset"
  echo "A welcome window will ask for Screen Recording permission. After that, press ⇧⌘S to capture."
}

# The download URL of the channel's newest release asset whose name matches a pattern.
asset_url() {
  local release=latest
  [ "$CHANNEL" = stable ] || release=tags/nightly
  curl -fsSL "https://api.github.com/repos/$REPO/releases/$release" \
    | grep -o '"browser_download_url": *"[^"]*"' | cut -d'"' -f4 | grep -E "$1" | head -1
}

# Shotate was called Snapmark before 0.12. The .deb and .rpm replace the old package themselves and
# keep a `snapmark` command; this handles an old AppImage. Shotate moves Open at login over when it starts.
remove_snapmark() {
  pkill -x snapmark >/dev/null 2>&1 || true
  if [ -f "$HOME/.local/bin/snapmark" ] && [ ! -L "$HOME/.local/bin/snapmark" ]; then
    rm -f "$HOME/.local/bin/snapmark" "$HOME/.local/share/applications/snapmark.desktop"
    [ ! -x "$HOME/.local/bin/shotate" ] || ln -sf shotate "$HOME/.local/bin/snapmark"
  fi
}

install_linux() {
  # Stable releases are macOS only for now; Linux gets the nightly preview.
  if [ "$CHANNEL" = stable ]; then
    echo "${dim}    Stable releases are macOS only for now, so this installs the Linux preview (nightly).${reset}"
    CHANNEL=nightly
  fi
  case "$(uname -m)" in
    # Tauri names packages amd64/arm64 for .deb, x86_64/aarch64 for .rpm, amd64/aarch64 for AppImage.
    x86_64|amd64) deb_arch=amd64; rpm_arch=x86_64; appimage_arch=amd64 ;;
    aarch64|arm64) deb_arch=arm64; rpm_arch=aarch64; appimage_arch=aarch64 ;;
    *) fail "Shotate for Linux is built for x86_64 and arm64 (this machine is $(uname -m))." ;;
  esac
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
  local sudo=""
  [ "$(id -u)" -eq 0 ] || sudo="sudo"
  if command -v apt-get >/dev/null 2>&1; then
    url=$(asset_url "_${deb_arch}\.deb$") || true
    [ -n "${url:-}" ] || fail "no .deb for $deb_arch in the nightly release."
    step "Downloading $(basename "$url")"
    curl -fsSL -o "$WORK/shotate.deb" "$url"
    step "Installing with apt (asks for your password)"
    # Every nightly package carries the same version, so reinstall rather than skip it.
    $sudo apt-get install -y --reinstall --allow-downgrades "$WORK/shotate.deb"
  elif command -v dnf >/dev/null 2>&1 || command -v zypper >/dev/null 2>&1; then
    url=$(asset_url "\.${rpm_arch}\.rpm$") || true
    [ -n "${url:-}" ] || fail "no .rpm for $rpm_arch in the nightly release."
    step "Downloading $(basename "$url")"
    curl -fsSL -o "$WORK/shotate.rpm" "$url"
    step "Installing (asks for your password)"
    # Every nightly package carries the same version: an installed copy is replaced in place
    # (its dependencies are already there); a first install lets dnf or zypper pull them in.
    if rpm -q shotate >/dev/null 2>&1; then $sudo rpm -U --oldpackage --replacepkgs "$WORK/shotate.rpm"
    elif command -v dnf >/dev/null 2>&1; then $sudo dnf install -y "$WORK/shotate.rpm"
    else $sudo zypper --non-interactive install --allow-unsigned-rpm "$WORK/shotate.rpm"; fi
  else
    url=$(asset_url "_${appimage_arch}\.AppImage$") || true
    [ -n "${url:-}" ] || fail "no AppImage for $appimage_arch in the nightly release."
    step "Downloading $(basename "$url")"
    mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
    curl -fsSL -o "$HOME/.local/bin/shotate" "$url"
    chmod +x "$HOME/.local/bin/shotate"
    cat > "$HOME/.local/share/applications/shotate.desktop" <<DESKTOP
[Desktop Entry]
Name=Shotate
Comment=Screenshot and annotate
Exec=$HOME/.local/bin/shotate %f
Icon=camera-photo
Type=Application
Categories=Utility;Graphics;
MimeType=image/png;image/jpeg;
DESKTOP
    echo "${dim}    AppImages need FUSE 2 (libfuse2) on some distributions.${reset}"
  fi
  remove_snapmark
  echo
  printf '%sShotate is installed.%s Starting it now; it lives in your system tray.\n' "$bold" "$reset"
  if [ "${XDG_SESSION_TYPE:-}" = wayland ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    echo "On Wayland, add a keyboard shortcut in your desktop settings that runs:  shotate --capture"
  else
    echo "Press Ctrl+Shift+S to capture an area."
  fi
  (command -v shotate >/dev/null 2>&1 && nohup shotate >/dev/null 2>&1 &) || true
}

case "$(uname -s)" in
  Darwin) install_macos ;;
  Linux) install_linux ;;
  MINGW*|MSYS*|CYGWIN*) fail "on Windows, run this in PowerShell:  irm https://raw.githubusercontent.com/$REPO/main/install.ps1 | iex" ;;
  *) fail "Shotate runs on macOS, Windows and Linux (this is $(uname -s))." ;;
esac
