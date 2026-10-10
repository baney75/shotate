#!/bin/bash
# Installs Snapmark: builds it from source and puts it in ~/Applications.
#   curl -fsSL https://raw.githubusercontent.com/baney75/snapmark/main/install.sh | bash
# Building on your Mac means no Gatekeeper warning and no paid signing certificate.
set -euo pipefail
REPO_URL="${SNAPMARK_REPO:-https://github.com/baney75/snapmark.git}"
REF="${SNAPMARK_REF:-main}"
bold=$(tput bold 2>/dev/null || true); dim=$(tput dim 2>/dev/null || true); reset=$(tput sgr0 2>/dev/null || true)
step() { printf '%s==>%s %s\n' "$bold" "$reset" "$*"; }
fail() { printf 'Snapmark install failed: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "Snapmark runs on macOS only."
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
"$WORK/snapmark/scripts/bundle.sh" --install 2>&1 | sed "s/^/${dim}    /;s/\$/${reset}/" | tail -4

echo
printf '%sSnapmark is installed.%s It is in your menu bar now.\n' "$bold" "$reset"
echo "A welcome window will ask for Screen Recording permission. After that, press ⇧⌘S to capture."
