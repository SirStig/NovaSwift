#!/usr/bin/env python3
"""Compare original Float32 armor captures with native pinned-person spawning."""

import argparse
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source", type=Path, default=Path.cwd(), help="Patched NovaSwift checkout"
    )
    parser.add_argument(
        "--input",
        type=Path,
        default=Path.cwd() / ".local/reports/armor/person-resource-armor.json",
    )
    parser.add_argument(
        "--output", type=Path, default=Path.cwd() / ".local/reports/armor"
    )
    args = parser.parse_args()
    source = args.source.expanduser().resolve()
    report = args.input.expanduser().resolve(strict=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swift", "build"], cwd=source, check=True)
    build = Path(
        subprocess.check_output(
            ["swift", "build", "--show-bin-path"], cwd=source, text=True
        ).strip()
    )
    objects = []
    for name in ("NovaSwiftKit", "NovaSwiftEngine", "Crypto"):
        module_objects = sorted((build / f"{name}.build").glob("*.o"))
        if not module_objects:
            raise ValueError(f"No compiled objects for {name} in {build}")
        objects.extend(str(path) for path in module_objects)
    binary = output / "compare-person-armor"
    comparator = Path(__file__).with_suffix(".swift")
    subprocess.run(
        [
            "swiftc",
            "-parse-as-library",
            "-I",
            str(build / "Modules"),
            str(comparator),
            *objects,
            "-o",
            str(binary),
        ],
        check=True,
    )
    result = subprocess.run([str(binary), str(report)], capture_output=True, text=True)
    log = result.stdout + result.stderr
    (output / "native-person-comparison.log").write_text(log)
    print(log, end="")
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
