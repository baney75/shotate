#!/bin/bash
# Writes manifest.json for a release from its uploaded installers and uploads it (docs/updates.md).
#   manifest.sh <tag> <stable|nightly> <version> <commit>
set -euo pipefail
tag=$1 channel=$2 version=$3 commit=$4
repo=${GITHUB_REPOSITORY:-baney75/shotate}
dir=$(mktemp -d)
gh release download "$tag" --repo "$repo" --dir "$dir" \
  --pattern '*-setup.exe' --pattern '*.deb' --pattern '*.rpm' --pattern '*.AppImage'
python3 - "$dir" "$repo" "$tag" "$channel" "$version" "$commit" > "$dir/manifest.json" <<'PY'
import hashlib, json, os, re, sys, urllib.parse
from datetime import datetime, timezone
d, repo, tag, channel, version, commit = sys.argv[1:]
kinds = [(r'_x64-setup\.exe$', 'windows-x64'),
         (r'_amd64\.deb$', 'linux-x64-deb'), (r'_arm64\.deb$', 'linux-arm64-deb'),
         (r'\.x86_64\.rpm$', 'linux-x64-rpm'), (r'\.aarch64\.rpm$', 'linux-arm64-rpm'),
         (r'_amd64\.AppImage$', 'linux-x64-appimage'), (r'_aarch64\.AppImage$', 'linux-arm64-appimage')]
assets = {}
for name in sorted(os.listdir(d)):
    key = next((k for pattern, k in kinds if re.search(pattern, name)), None)
    if not key:
        continue
    sha = hashlib.sha256(open(os.path.join(d, name), 'rb').read()).hexdigest()
    url = f'https://github.com/{repo}/releases/download/{tag}/{urllib.parse.quote(name)}'
    assets[key] = {'name': name, 'url': url, 'sha256': sha}
missing = {k for _, k in kinds} - assets.keys()
if missing:
    sys.exit(f'missing installers: {sorted(missing)}')
print(json.dumps({
    'channel': channel, 'version': version, 'commit': commit,
    'date': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'notes': f'https://github.com/{repo}/releases/tag/{tag}', 'assets': assets,
}, indent=2))
PY
gh release upload "$tag" --repo "$repo" "$dir/manifest.json" --clobber
echo "uploaded manifest.json for $tag ($channel $version)"
