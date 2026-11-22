"""Apply the bundled 4x RealPLKSR checkpoint to an oriented sRGB PNG."""

import argparse
import os
from pathlib import Path

import numpy as np
import onnxruntime as ort
from PIL import Image


TILE = 256
OVERLAP = 64
SCALE = 4


def starts(length):
    stride = TILE - OVERLAP
    margin = OVERLAP // 2
    # Keep some reflected context at the far edge without adding a mostly empty tile.
    extra = max(0, length - (TILE - margin - margin // 2))
    count = 1 + (extra + stride - 1) // stride
    return range(-margin, count * stride - margin, stride)


def blend(previous, following, axis):
    weights = np.linspace(0, 1, following.shape[axis] + 2, dtype=np.float32)[1:-1]
    weights = weights.reshape((-1, 1, 1) if axis == 0 else (1, -1, 1))
    following[:] = np.rint(previous * (1 - weights) + following * weights).astype(np.uint8)


def predict_image(model, rgb, progress):
    height, width = rgb.shape[:2]
    padding = OVERLAP // 2
    padded = np.pad(rgb, ((padding, padding), (padding, padding), (0, 0)), mode="reflect")
    options = ort.SessionOptions()
    # This worker runs at utility priority. Leave cores available for the editor
    # instead of letting ONNX Runtime use all available CPUs.
    options.intra_op_num_threads = max(1, min(8, (os.cpu_count() or 4) - 2))
    options.add_session_config_entry("session.intra_op.allow_spinning", "0")
    session = ort.InferenceSession(str(model), options, providers=["CPUExecutionProvider"])
    input_name = session.get_inputs()[0].name
    xs, ys = starts(width), starts(height)
    total = len(xs) * len(ys)
    done = 0
    output = np.empty((height * SCALE, width * SCALE, 3), dtype=np.uint8)
    previous_bottom = 0
    for y in ys:
        tile_bottom = min(y + TILE, height + padding)
        top, bottom = max(0, y) * SCALE, min(height, y + TILE) * SCALE
        crop_y = top - y * SCALE
        strip = np.empty((bottom - top, width * SCALE, 3), dtype=np.uint8)
        previous_right = 0
        for x in xs:
            left, right = max(0, x) * SCALE, min(width, x + TILE) * SCALE
            crop_x = left - x * SCALE
            tile_right = min(x + TILE, width + padding)
            tile = padded[y + padding:tile_bottom + padding, x + padding:tile_right + padding]
            data = np.ascontiguousarray(tile.transpose(2, 0, 1)[None], dtype=np.float32) / 255
            prediction = session.run(None, {input_name: data})[0][0]
            pixels = prediction[:, crop_y:crop_y + bottom - top, crop_x:crop_x + right - left]
            pixels = np.rint(np.clip(pixels, 0, 1) * 255).astype(np.uint8).transpose(1, 2, 0)
            shared = previous_right - left
            if shared > 0:
                blend(strip[:, left:previous_right], pixels[:, :shared], axis=1)
            strip[:, left:right] = pixels
            previous_right = right
            done += 1
            progress.write_text(str(done / total), encoding="ascii")
        shared = previous_bottom - top
        if shared > 0:
            blend(output[top:previous_bottom], strip[:shared], axis=0)
        output[top:bottom] = strip
        previous_bottom = bottom
    return output


def upscale(model, source, target, progress, size):
    with Image.open(source) as image:
        profile = image.info.get("icc_profile")
        alpha = image.getchannel("A") if "A" in image.getbands() else None
        if alpha is not None and alpha.getextrema() == (255, 255):
            alpha = None
        rgb = np.asarray(image.convert("RGB"), dtype=np.uint8)

    # Release the inference session and its tile workspace before encoding.
    output = predict_image(model, rgb, progress)
    result = Image.fromarray(output)
    del output
    if result.size != size:
        result = result.resize(size, Image.Resampling.LANCZOS)
    reference = Image.fromarray(rgb).resize(size, Image.Resampling.LANCZOS)
    # Blend by rows to avoid allocating a third full-size RGB image.
    for top in range(0, result.height, 128):
        box = (0, top, result.width, min(top + 128, result.height))
        result.paste(Image.blend(reference.crop(box), result.crop(box), 0.8), (0, top))
    del reference
    if alpha is not None:
        result.putalpha(alpha.resize(size, Image.Resampling.LANCZOS))
    result.save(target, format="PNG", icc_profile=profile)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ("model", "source", "target", "progress"):
        parser.add_argument(name, type=Path)
    parser.add_argument("width", type=int)
    parser.add_argument("height", type=int)
    args = parser.parse_args()
    upscale(args.model, args.source, args.target, args.progress, (args.width, args.height))
