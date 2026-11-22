"""Run the pinned Audio8 INT8 export with either its default or a saved voice."""

import json
import os
from pathlib import Path
import sys
import threading
import time
import wave


class PackagedVoice:
    def __init__(self, model, manifest, numpy):
        self.codes = numpy.load(model / manifest["reference_codes"], allow_pickle=False)
        self.meta = {"reference_text": manifest["reference_text"]}

    def load(self, name):
        if name != "default":
            raise ValueError("Unknown voice")
        return self.codes, self.meta


def prefill_voice(runtime, reference, transcript, numpy):
    # These prompts differ at the first target token. Compare the full columns
    # to identify exactly how much of the shared voice prompt can be reused.
    first = runtime.prompt_builder.build("A", transcript, reference)
    second = runtime.prompt_builder.build("B", transcript, reference)
    count = min(first.shape[2], second.shape[2])
    different = numpy.flatnonzero(numpy.any(first[:, :, :count] != second[:, :, :count], axis=(0, 1)))
    if not different.size:
        return None
    end = int(different[0])
    if not 0 < end < runtime.manifest["max_seq_len"]:
        return None
    columns = first[:, :, :end].copy()
    state = runtime._empty_slow_state()
    for position in range(end):
        runtime._slow_step(columns[:, :, position : position + 1], position, state)
    return columns, state


def synthesize(model, request, progress, voice_folder, fallback="zh"):
    import numpy as np
    from arktts_runtime import ArkTtsRuntime
    from arktts_runtime.prompt import clean_text
    from spoken_numbers import spoken_financial_text

    entries = json.loads(request.read_text(encoding="utf-8"))
    runtime = ArkTtsRuntime(model, voice_folder.parent if voice_folder else model,
                            precision="int8", threads=2)
    if voice_folder:
        voice = voice_folder.name
    else:
        voice = "default"
        runtime.voices = PackagedVoice(model, runtime.manifest, np)

    reference, metadata = runtime.voices.load(voice)
    transcript = metadata["reference_text"]
    prefilled = prefill_voice(runtime, reference, transcript, np) if len(entries) > 1 else None
    for index, entry in enumerate(entries):
        text = spoken_financial_text(clean_text(entry["text"]), fallback)
        if not text:
            raise ValueError(f"Caption {index + 1} has no speakable text")
        prompt = runtime.prompt_builder.build(text, transcript, reference)
        limit = min(1024, runtime.manifest["max_seq_len"] - prompt.shape[2])
        if limit <= 0:
            raise ValueError(f"Caption {index + 1} exceeds the model context")
        codes = list(runtime.iter_codes(text=text, voice=voice, max_new_tokens=limit,
                                        prompt=prompt, prefilled=prefilled))
        if not codes or len(codes) == limit:
            raise ValueError(f"Caption {index + 1} did not generate a complete utterance")
        samples = runtime.decode_codes(np.stack(codes, axis=1))
        if not np.isfinite(samples).all() or not np.any(samples):
            raise ValueError(f"Caption {index + 1} produced invalid audio")
        pcm = np.rint(np.clip(samples, -1, 1) * 32767).astype("<i2")
        with wave.open(entry["path"], "wb") as audio:
            audio.setparams((1, 2, runtime.manifest["sample_rate"], 0, "NONE", "not compressed"))
            audio.writeframes(pcm.tobytes())
        progress.write_text(str(index + 1), encoding="ascii")


def register(model, recording, output):
    # Use the same PCM layout and encoder contract as the upstream registration
    # runtime. macOS converts the input to mono 16-bit PCM before this step.
    import numpy as np
    import onnxruntime as ort

    root = model / "registration"
    manifest = json.loads((root / "registration_manifest.json").read_text(encoding="utf-8"))
    rate = manifest["sample_rate"]
    with wave.open(str(recording), "rb") as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, rate):
            raise ValueError("Invalid reference PCM format")
        length = source.getnframes()
        if not rate // 2 <= length <= rate * 30:
            raise ValueError("Reference audio must be between 0.5 and 30 seconds")
        audio = np.frombuffer(source.readframes(length), dtype="<i2").astype(np.float32) / 32768
    if not np.any(audio):
        raise ValueError("Reference audio is silent")
    audio = np.pad(audio, (0, (-audio.size) % 2048)).reshape(1, 1, -1)
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    options.inter_op_num_threads = 1
    options.log_severity_level = 3
    session = ort.InferenceSession(str(root / "codec_encoder_fp16.onnx"), sess_options=options,
                                   providers=["CPUExecutionProvider"])
    input_info = session.get_inputs()[0]
    dtype = np.float16 if input_info.type == "tensor(float16)" else np.float32
    codes = np.asarray(session.run(None, {input_info.name: audio.astype(dtype)})[0])
    if codes.ndim == 3:
        codes = codes[0]
    if (codes.ndim != 2 or codes.shape[0] != manifest["num_codebooks"] or codes.shape[1] == 0
            or codes.min() < 0 or codes.max() >= manifest.get("codebook_size", 4096)):
        raise ValueError("Voice encoder returned invalid codes")
    np.save(output, codes.astype(np.uint16), allow_pickle=False)


def main():
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    try:
        os.nice(8)
    except OSError:
        pass

    parent = os.getppid()
    if parent == 1:
        sys.exit(1)

    def watch_parent():
        while os.getppid() == parent:
            time.sleep(1)
        os._exit(1)

    threading.Thread(target=watch_parent, daemon=True).start()
    operation, *args = sys.argv[1:]
    if operation == "synthesize":
        model, request, progress, voice, *fallback = args
        synthesize(Path(model), Path(request), Path(progress), Path(voice) if voice else None, *fallback)
    elif operation == "register":
        register(*map(Path, args))
    else:
        raise ValueError("Unknown Audio8 operation")


if __name__ == "__main__":
    main()
