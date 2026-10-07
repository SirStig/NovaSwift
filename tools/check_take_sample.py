#!/usr/bin/env python3
"""Check stock Take Sample boarding, cargo and return without opening the game."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def run_variant(source, data, output, scratch):
    output.mkdir(parents=True, exist_ok=False)
    args = ["swift", "build", "--scratch-path", str(scratch), "--target", "NovaSwiftStory"]
    with (output / "build.log").open("w") as log:
        subprocess.run(args, cwd=source, stdout=log, stderr=subprocess.STDOUT, check=True)
    build = Path(subprocess.check_output(
        ["swift", "build", "--scratch-path", str(scratch), "--show-bin-path"],
        cwd=source, text=True).strip())
    objects = []
    for module in ("NovaSwiftKit", "NovaSwiftEngine", "NovaSwiftStory", "Crypto"):
        files = sorted((build / f"{module}.build").glob("*.o"))
        if not files:
            raise ValueError(f"No compiled objects for {module}")
        objects.extend(map(str, files))
    harness = Path(__file__).with_suffix(".swift")
    binary = output / "check-take-sample"
    with (output / "compile.log").open("w") as log:
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-I", str(build / "Modules"),
                        str(harness), *objects, "-o", str(binary)],
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    result = subprocess.run([str(binary), str(data)], capture_output=True, text=True, check=True)
    (output / "run.log").write_text(result.stdout + result.stderr)
    report = json.loads(result.stdout)
    report["source"] = str(source)
    report["sourceSHA256"] = {name: hashlib.sha256((source / name).read_bytes()).hexdigest()
        for name in ["Sources/NovaSwiftEngine/World.swift", "Sources/NovaSwiftStory/StoryEngine.swift"]}
    (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--data", type=Path, required=True, help="Your local stock Nova data directory")
    parser.add_argument("--output", type=Path, required=True, help="Fresh directory for evidence")
    parser.add_argument("--scratch", type=Path, help="Optional existing Swift build cache for fixed source")
    parser.add_argument("--baseline-source", type=Path)
    parser.add_argument("--baseline-scratch", type=Path)
    args = parser.parse_args()
    output = args.output.expanduser().resolve()
    if output.exists():
        parser.error("Output exists; choose a new directory")
    data = args.data.expanduser().resolve(strict=True)
    output.mkdir(parents=True)
    reports = {}
    if args.baseline_source:
        baseline = args.baseline_source.expanduser().resolve(strict=True)
        scratch = args.baseline_scratch.expanduser().resolve() if args.baseline_scratch else output / "baseline-build"
        reports["baseline"] = run_variant(baseline, data, output / "baseline", scratch)
    source = args.source.expanduser().resolve(strict=True)
    scratch = args.scratch.expanduser().resolve() if args.scratch else output / "fixed-build"
    reports["fixed"] = run_variant(source, data, output / "fixed", scratch)
    (output / "comparison.json").write_text(json.dumps(reports, indent=2) + "\n")
    print(json.dumps({name: {"allChecksPass": report["allChecksPass"], "checks": report["checks"]}
                      for name, report in reports.items()}, indent=2))
    if not reports["fixed"]["allChecksPass"]:
        raise SystemExit("Fixed stock mission check failed; inspect result.json and logs")
    if "baseline" in reports and reports["baseline"]["allChecksPass"]:
        raise SystemExit("Expected stock mission baseline to reproduce the regression")


if __name__ == "__main__":
    main()
