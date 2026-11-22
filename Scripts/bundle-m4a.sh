#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ "$(uname -m)" != arm64 ]]; then
  exit 0
fi
mkdir -p "$1"
destination="$(cd "$1" && pwd)"

work="$(mktemp -d "${TMPDIR:-/tmp}/maomijian-ffmpeg.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT
version=9.1
archive="ffmpeg-$version.tar.xz"
curl --http1.1 --connect-timeout 15 --retry 3 --retry-all-errors -fsSL \
  "https://ffmpeg.org/releases/$archive" -o "$work/$archive"
printf '%s  %s\n' 1a4d394ae63d190a526cd052eb4415c156b5c5e2df37efab41a7de0b8fde2433 \
  "$work/$archive" | shasum -a 256 -c -
tar -xf "$work/$archive" -C "$work"
cd "$work/ffmpeg-$version"

# Build a local WAV-to-AAC helper with the LGPL configuration.
export MACOSX_DEPLOYMENT_TARGET=14.0
./configure --disable-everything --disable-autodetect --disable-network \
  --disable-asm --disable-doc --disable-debug --disable-ffplay --disable-ffprobe \
  --extra-cflags=-mmacosx-version-min=14.0 --extra-ldflags=-mmacosx-version-min=14.0 \
  --enable-protocol=file --enable-demuxer=wav --enable-decoder=pcm_s16le \
  --enable-encoder=aac --enable-muxer=ipod --enable-filter=aresample
make -j 6 ffmpeg

notices="$destination/Resources/AudioExport"
mkdir -p "$destination/Helpers" "$notices"
install -m 755 ffmpeg "$destination/Helpers/ffmpeg"
codesign --force --sign - "$destination/Helpers/ffmpeg"
cp COPYING.LGPLv2.1 "$notices/"
cp "$work/$archive" "$notices/"
cp "$source_dir/bundle-m4a.sh" "$notices/"
