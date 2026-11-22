#!/bin/bash
set -euo pipefail

python="$1"
site="$python/lib/python3.12/site-packages"

# The editor uses these wheels for inference and model graph I/O only.
rm -rf "$site/onnx/backend/test"
find "$site/numpy" -type d -name tests -prune -exec rm -rf {} +

# This wheel's Python extension contains its own linked ONNX Runtime.
rm -f "$site/onnxruntime/capi/libonnxruntime.1.23.2.dylib"

# The bundled interpreter on this build is Apple silicon only.
while IFS= read -r -d '' binary; do
  if [[ "$(xcrun lipo -archs "$binary")" != arm64 ]]; then
    xcrun lipo "$binary" -thin arm64 -output "$binary.arm64"
    mv "$binary.arm64" "$binary"
    codesign --force --sign - "$binary"
  fi
done < <(find "$site/onnx" "$site/google" -type f -name '*.so' -print0)

for binary in "$python/lib/libpython3.12.dylib" "$site/onnxruntime/capi/onnxruntime_pybind11_state.so"; do
  # Retain the symbols needed by the interpreter and extension loader.
  xcrun strip -x "$binary"
  codesign --force --sign - "$binary"
done
