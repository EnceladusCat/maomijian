#!/bin/bash
set -euo pipefail

source_dir="$1"
destination="$2"
arch="$(uname -m)"
case "$arch" in
  arm64)
    triple=aarch64-apple-darwin
    python_sha=130e8e279f7ac2c98511af79c8215bb8a4705c23706a76fafce2f4eaa64560be
    ;;
  *)
    # ONNX Runtime's tested macOS wheel for this model is arm64.
    exit 0
    ;;
esac

work="$(mktemp -d "${TMPDIR:-/tmp}/maomijian-audio8.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT
release=20260310
archive="cpython-3.12.13+${release}-${triple}-install_only_stripped.tar.gz"
download() {
  curl --http1.1 --connect-timeout 15 --retry 3 --retry-all-errors -fsSL "$1" -o "$2"
  printf '%s  %s\n' "$3" "$2" | shasum -a 256 -c -
}
download "https://github.com/astral-sh/python-build-standalone/releases/download/$release/$archive" \
  "$work/python.tar.gz" "$python_sha"
tar -xzf "$work/python.tar.gz" -C "$work"
python="$work/python/bin/python3"
site="$work/python/lib/python3.12/site-packages"
"$python" -m pip --isolated install --disable-pip-version-check --no-cache-dir --no-compile \
  --no-deps --only-binary=:all: -r "$source_dir/Scripts/audio8-requirements.txt"

cd "$work"
mkdir -p runtime/arktts_runtime
revision=aef426db7229b93c8cb9a00c7c054b2b234e2979
github="https://raw.githubusercontent.com/Edge0-AI/Audio8_TTS/$revision"
download "$github/LICENSE" runtime/LICENSE-Audio8-runtime.txt c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4
download "$github/NOTICE" runtime/NOTICE-Audio8-runtime.txt 819129644b28fb066221d782dd27a6fe1d35f33f46718d4e61570614fb38854e
github="$github/onnx_runtime_0_1b_int8/arktts_runtime"
download "$github/__init__.py" runtime/arktts_runtime/__init__.py 17fd2c63cab68d135708d8b0f930225983252227817bf94d0dbac1b7de04105c
download "$github/runtime.py" runtime/arktts_runtime/runtime.py 85e069c97566e3610b2c86f1455f7d66dcc5a69c55b3d89f35987179230b3717
patch -s runtime/arktts_runtime/runtime.py < "$source_dir/Scripts/audio8-prefill.patch"
download "$github/prompt.py" runtime/arktts_runtime/prompt.py 0d80aa9cb5553083aa52f6d973108881f6e320c369ffb661bdf4b9d5baa81ba2
download "$github/voices.py" runtime/arktts_runtime/voices.py cba523c59f354ed48013f91fa8aec9b950cc067197336e649a1381075937b921

headers="https://cdn.jsdelivr.net/gh/microsoft/onnxruntime@v1.23.1/include/onnxruntime/core/session"
download "$headers/onnxruntime_c_api.h" onnxruntime_c_api.h 71125e66180a991d65c9bdbad4aa20daaa1f7a48c7a5c0fa5f18f250ac839a02
download "$headers/onnxruntime_ep_c_api.h" onnxruntime_ep_c_api.h b92778f50c36ecdf53d0344e0129a78b306afed653f81bba8a9597e3e6e9546f
xcrun clang -O3 -dynamiclib -target arm64-apple-macos14.0 -I "$work" -framework Accelerate \
  "$source_dir/Scripts/audio8-conv.c" -o runtime/audio8_conv.dylib
codesign --force --sign - runtime/audio8_conv.dylib

# The runtime is sealed into the app. The package manager is only needed here.
rm -rf "$site"/pip "$site"/pip-*.dist-info "$work/python/lib/python3.12/ensurepip"
find "$work/python" -type d -name __pycache__ -prune -exec rm -rf {} +
bash "$source_dir/Scripts/prune-inference-runtime.sh" "$work/python"
"$python" -IB -c 'import numpy, onnx, onnxruntime; from tokenizers import Tokenizer; from PIL import Image; assert "CPUExecutionProvider" in onnxruntime.get_available_providers()'
mkdir -p "$destination"
# Remove the previous runtime so reusing a destination also drops pruned files.
rm -rf "$destination/python"
ditto "$work/python" "$destination/python"
ditto "$work/runtime" "$destination"
