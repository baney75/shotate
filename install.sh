#!/bin/bash
# One-line install: builds Snap from source and puts it in ~/Applications.
#   curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/install.sh | bash
# Building locally means no Gatekeeper download warning and no paid signing certificate.
set -euo pipefail
REPO_URL="${SNAP_REPO:-https://github.com/OWNER/REPO.git}"
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Snap builds with Apple's command line tools. Installing them opens a system dialog;"
  echo "run this again when it finishes."
  xcode-select --install || true
  exit 1
fi
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
git clone --depth 1 "$REPO_URL" "$WORK/snap"
"$WORK/snap/scripts/bundle.sh" --install
echo
echo "Snap is in ~/Applications and running in your menu bar."
echo "Press ⇧⌘S to capture. macOS asks once for Screen Recording permission."
