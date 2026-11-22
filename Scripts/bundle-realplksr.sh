#!/bin/bash
set -euo pipefail
destination="$1"
if [[ "$(uname -m)" != arm64 ]]; then exit 0; fi

model="$destination/model_x4.onnx"
sha=012c34d6223af4cc65f30f3aae26b63e1eea101652471cbbaff83066651ccbe5
valid() { printf '%s  %s\n' "$sha" "$1" | shasum -a 256 -c -; }
if [[ -f "$model" ]] && valid "$model"; then
  chmod 644 "$model"
  exit 0
fi

staged="$(mktemp "$destination/model_x4.XXXXXXXX")"
trap 'rm -f "$staged"' EXIT
curl --http1.1 --connect-timeout 15 --retry 3 --retry-all-errors -fsSL \
  'https://huggingface.co/notaneimu/onnx-image-models/resolve/4cd6fa6bf614d37d00350c6cac174897582ed4bc/4xNomosWebPhoto_RealPLKSR.onnx' \
  -o "$staged"
valid "$staged"
chmod 644 "$staged"
mv "$staged" "$model"
