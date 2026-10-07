#!/usr/bin/env python3
"""Compare original/fixed quantity-sheet sizing without launching the game.

Builds a UI-only executable from the exact prompt/font source and visual control
shims. It uses offscreen NSHostingView objects and prohibited app activation;
there is no game bootstrap, save access, preferences access, or network use.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path


SOURCE_FILES = (
    "app/NovaSwift/Spaceport/TradeQuantityPrompt.swift",
    "app/NovaSwift/UI/NovaFont.swift",
)


def command(args: list[str]) -> str:
    result = subprocess.run(args, check=True, capture_output=True, text=True)
    return result.stdout


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path, help="NovaSwift source checkout")
    parser.add_argument("--baseline-ref", default="63cba42e33ea959cf93973cc418adfc9b6b073c4",
                        help="Git revision containing the original dialog (defaults to the known buggy revision)")
    parser.add_argument("--output", required=True, type=Path, help="New directory for JSON and offscreen PNG evidence")
    args = parser.parse_args()
    source = args.source.expanduser().resolve()
    output = args.output.expanduser().resolve()
    if output.exists():
        parser.error(f"Output already exists; choose a new directory: {output}")
    output.mkdir(parents=True)
    harness = Path(__file__).with_name("trade_dialog_harness.swift").resolve()
    summary: dict = {
        "source": str(source),
        "sourceHead": command(["git", "-C", str(source), "rev-parse", "HEAD"]).strip(),
        "baselineRef": args.baseline_ref,
        "baselineHead": command(["git", "-C", str(source), "rev-parse", args.baseline_ref]).strip(),
        "harnessSHA256": hashlib.sha256(harness.read_bytes()).hexdigest(),
        "variants": {},
    }
    fonts = sorted((source / "app/NovaSwift/Resources/Fonts").glob("*.ttf"))
    summary["fontSHA256"] = {
        str(font.relative_to(source)): hashlib.sha256(font.read_bytes()).hexdigest()
        for font in fonts
    }
    for variant in ("baseline", "fixed"):
        directory = output / variant
        directory.mkdir()
        staged = []
        source_hashes = {}
        for relative in SOURCE_FILES:
            content = (
                command(["git", "-C", str(source), "show", f"{args.baseline_ref}:{relative}"]).encode()
                if variant == "baseline" else (source / relative).read_bytes()
            )
            destination = directory / Path(relative).name
            destination.write_bytes(content)
            staged.append(destination)
            source_hashes[relative] = hashlib.sha256(content).hexdigest()
        binary = directory / "trade-dialog-harness"
        compile_result = subprocess.run(
            ["xcrun", "swiftc", "-parse-as-library", "-target", "arm64-apple-macosx14.0",
             *map(str, staged), str(harness), "-o", str(binary)],
            capture_output=True, text=True,
        )
        (directory / "compile.log").write_text(compile_result.stdout + compile_result.stderr)
        compile_result.check_returncode()
        run_result = subprocess.run([str(binary), str(directory), *map(str, fonts)],
                                    capture_output=True, text=True)
        (directory / "run.log").write_text(run_result.stdout + run_result.stderr)
        run_result.check_returncode()
        report = json.loads((directory / "layout.json").read_text())
        summary["variants"][variant] = {
            "sourceSHA256": source_hashes,
            "layout": report,
            "footerFitCount": sum(case["footerFits"] for case in report["scenarios"]),
        }
    baseline = summary["variants"]["baseline"]
    fixed = summary["variants"]["fixed"]
    total = len(fixed["layout"]["scenarios"])
    summary["regressionReproduced"] = baseline["footerFitCount"] < total
    summary["fixedAllCasesFit"] = fixed["footerFitCount"] == total
    (output / "comparison.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"Baseline footers fit: {baseline['footerFitCount']}/{total}")
    print(f"Fixed footers fit: {fixed['footerFitCount']}/{total}")
    print(f"Evidence: {output / 'comparison.json'}")
    if not summary["regressionReproduced"] or not summary["fixedAllCasesFit"]:
        raise SystemExit("Layout regression comparison failed; inspect evidence.")


if __name__ == "__main__":
    main()
