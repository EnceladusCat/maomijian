"""Run the pinned Audio8 INT8 export with either its default or a saved voice."""

from collections import deque
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack, closing
from itertools import islice
import json
import os
import re
from pathlib import Path
import sys
import textwrap
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


def instant_chunks(text, normalize):
    chunks = []
    pending = ""
    for sentence in re.split(r"(?<=[。！？!?；;\n])|(?<=\.)(?=\s|$)", text):
        sentence = normalize(sentence)
        # Spoken Chinese uses more codec frames per written character.
        limit = 90 if re.search(r"[㐀-鿿]", sentence) else 260
        for line in textwrap.wrap(sentence, width=limit, break_on_hyphens=False):
            if pending and len(pending) + len(line) + 1 > limit:
                chunks.append(pending)
                pending = ""
            pending = pending + " " + line if pending else line
    if pending:
        chunks.append(pending)
    return chunks


def render_in_order(entries, render, workers, stop):
    indexed = enumerate(entries)
    if workers == 1:
        for index, entry in indexed:
            yield render(index, entry)
        return

    pool = ThreadPoolExecutor(max_workers=workers)
    try:
        # Limit buffered audio while keeping each worker busy across long batches.
        pending = deque(pool.submit(render, *item) for item in islice(indexed, workers * 2))
        while pending:
            pcm = pending.popleft().result()
            next_entry = next(indexed, None)
            if next_entry is not None:
                pending.append(pool.submit(render, *next_entry))
            yield pcm
    finally:
        stop.set()
        pool.shutdown(wait=True, cancel_futures=True)


def synthesize(model, request, progress, voice_folder, fallback="zh", decoder_graph="",
               decoder_weights="", *, instant=False):
    import numpy as np
    from arktts_runtime import ArkTtsRuntime
    from arktts_runtime.prompt import clean_text
    from spoken_numbers import spoken_financial_text

    def normalize(value):
        return spoken_financial_text(clean_text(value), fallback)

    payload = json.loads(request.read_text(encoding="utf-8"))
    if instant:
        entries = [{"text": line, "path": payload["path"]} for line in instant_chunks(payload["text"], normalize)]
        if not entries:
            raise ValueError("Enter text to read aloud")
        progress.write_text(f"0/{len(entries)}", encoding="ascii")
    else:
        entries = payload
    from accelerated_decoder import DeferredDecoder, LIBRARY, prepare_decoder

    accelerated = bool(decoder_graph and decoder_weights and LIBRARY.is_file())
    cores = os.cpu_count() or 4
    if accelerated and len(entries) >= 8 and cores >= 10:
        workers, threads = 6, 1
    elif len(entries) >= 4 and cores >= 8:
        workers, threads = 4, 1
    else:
        workers = 2 if len(entries) >= 2 and cores >= 6 else 1
        threads = 2
    with ExitStack() as files:
        decoder_factory = None
        if accelerated:
            preparation = files.enter_context(ThreadPoolExecutor(max_workers=1))

            def decoder_factory(path, _threads):
                future = preparation.submit(prepare_decoder, path, 2 if cores >= 8 and workers <= 4 else 1,
                                            Path(decoder_graph), Path(decoder_weights))
                return DeferredDecoder(future)

        runtime = ArkTtsRuntime(model, voice_folder.parent if voice_folder else model,
                                precision="int8", threads=threads, decoder_factory=decoder_factory)
        if voice_folder:
            voice = voice_folder.name
        else:
            voice = "default"
            runtime.voices = PackagedVoice(model, runtime.manifest, np)

        reference, metadata = runtime.voices.load(voice)
        transcript = metadata["reference_text"]
        prefilled = prefill_voice(runtime, reference, transcript, np) if len(entries) > 1 else None
        sample_rate = runtime.manifest["sample_rate"]
        params = (1, 2, sample_rate, 0, "NONE", "not compressed")
        stop = threading.Event()
        decoder_pool = files.enter_context(ThreadPoolExecutor(max_workers=min(workers, 2))) if accelerated else None

        def decode(index, codes):
            if stop.is_set():
                raise RuntimeError("Voiceover batch stopped")
            samples = runtime.decode_codes(codes)
            if not np.isfinite(samples).all() or not np.any(samples):
                raise ValueError(f"Entry {index + 1} produced invalid audio")
            return np.rint(np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes()

        def render(index, entry):
            text = entry["text"] if instant else normalize(entry["text"])
            if not text:
                raise ValueError(f"Entry {index + 1} has no speakable text")
            prompt = runtime.prompt_builder.build(text, transcript, reference)
            limit = min(1024, runtime.manifest["max_seq_len"] - prompt.shape[2])
            if limit <= 0:
                raise ValueError(f"Entry {index + 1} exceeds the model context")
            codes = list(runtime.iter_codes(text=text, voice=voice, max_new_tokens=limit,
                                            prompt=prompt, prefilled=prefilled, stop_event=stop))
            if stop.is_set():
                raise RuntimeError("Voiceover batch stopped")
            if not codes or len(codes) == limit:
                raise ValueError(f"Entry {index + 1} did not generate a complete utterance")
            codes = np.stack(codes, axis=1)
            return decoder_pool.submit(decode, index, codes) if decoder_pool else decode(index, codes)

        joined = files.enter_context(wave.open(payload["path"], "wb")) if instant else None
        if joined:
            joined.setparams(params)
        audio = files.enter_context(closing(render_in_order(entries, render, workers, stop)))
        for index, (entry, result) in enumerate(zip(entries, audio)):
            pcm = result.result() if decoder_pool else result
            if joined:
                if index > 0:
                    joined.writeframesraw(bytes((sample_rate // 8) * 2))
                joined.writeframesraw(pcm)
            else:
                with wave.open(entry["path"], "wb") as audio:
                    audio.setparams(params)
                    audio.writeframes(pcm)
            done = f"{index + 1}/{len(entries)}" if instant else str(index + 1)
            progress.write_text(done, encoding="ascii")


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
    if operation in ("synthesize", "instant"):
        model, request, progress, voice, *fallback = args
        synthesize(Path(model), Path(request), Path(progress), Path(voice) if voice else None,
                   *fallback, instant=operation == "instant")
    elif operation == "register":
        register(*map(Path, args))
    else:
        raise ValueError("Unknown Audio8 operation")


if __name__ == "__main__":
    main()
