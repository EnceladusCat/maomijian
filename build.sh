#!/bin/bash
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)"
dest="${1:-$src/../毛咪剪.app}"
cache="${TMPDIR:-/tmp}/framecut-swift-cache"
mkdir -p "$dest/Contents/MacOS" "$dest/Contents/Resources" "$cache"
xcrun swiftc -O -whole-module-optimization -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  -module-cache-path "$cache" -suppress-warnings "$src"/Sources/*.swift -o "$dest/Contents/MacOS/MaoMiJian"
cp "$src/Info.plist" "$dest/Contents/Info.plist"
cp -R "$src/Resources/"* "$dest/Contents/Resources/"
cp "$src/LICENSE" "$dest/Contents/Resources/"
bash "$src/Scripts/bundle-audio8.sh" "$src" "$(cd "$dest/Contents/Resources/Audio8" && pwd)"
codesign --force --sign - "$dest"
