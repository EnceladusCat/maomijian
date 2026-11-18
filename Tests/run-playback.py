#!/usr/bin/env python3
"""Build and launch an isolated editor to measure a long project's default 1080p preview."""
import argparse
import json
import pathlib
import platform
import plistlib
import shutil
import subprocess
import tempfile
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("project", type=pathlib.Path, help="Existing long .framecut project")
parser.add_argument("result", type=pathlib.Path, help="New JSON results file")
parser.add_argument("--seconds", type=int, default=60)
parser.add_argument("--interaction", action="store_true", help="Measure panel switching, annotation and undo latency")
args = parser.parse_args()
if not args.project.is_file() or args.result.exists() or args.seconds < 1:
    parser.error("Supply an existing project, a new result path, and positive playback seconds.")
if not args.result.parent.is_dir():
    parser.error("The result directory must exist.")
src = pathlib.Path(__file__).resolve().parents[1]
root = pathlib.Path(tempfile.mkdtemp(prefix="framecut-playback-"))
bundle = root / "MaoMiJian Playback Test.app"
contents = bundle / "Contents"
binary = contents / "MacOS" / "MaoMiJian"
binary.parent.mkdir(parents=True)
resources = contents / "Resources"
shutil.copytree(src / "Resources", resources)
info = plistlib.loads((src / "Info.plist").read_bytes())
info.update(CFBundleName="MaoMiJian Playback Test", CFBundleDisplayName="MaoMiJian Playback Test",
            CFBundleIdentifier="local.framecut.perf.run" + uuid.uuid4().hex)
info.pop("CFBundleDocumentTypes", None)
info.pop("UTExportedTypeDeclarations", None)
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
(resources / ("InteractionProbe.json" if args.interaction else "Probe.json")).write_text(json.dumps({
    "project": str(args.project.resolve()), "result": str(args.result.resolve()),
    **({} if args.interaction else {"runSeconds": args.seconds})
}))
test_files = ["InteractionProbe.swift", "EditingChecks.swift"] if args.interaction else ["PlaybackProbe.swift"]
subprocess.run(["xcrun", "swiftc", "-D", "INTERACTION_BENCH" if args.interaction else "FRAME_BENCH", "-O", "-whole-module-optimization",
                "-suppress-warnings", "-swift-version", "5", "-target",
                platform.machine()+"-apple-macos14.0", *sorted((src / "Sources").glob("*.swift")),
                *[src / "Tests" / name for name in test_files], "-o", binary], check=True)
subprocess.run(["codesign", "--force", "--sign", "-", bundle], check=True)
subprocess.run(["open", "-n", bundle], check=True)
print(f"Results: {args.result.resolve()}\nTest application: {bundle}")
