#!/usr/bin/env python3
"""Exercise exact app jump methods with real stock-data worlds, without game UI.

Both variants use one engine build, isolating the application ordering change.
The Swift fixture supplies rendering and persistence shims; transition, world
replacement, nav fuel commits, mission spawning and escort spawning methods are
extracted verbatim from the requested app sources and saved with hashes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

APP_FILES = {
    "scene": "app/NovaSwift/Game/GameScene.swift",
    "container": "app/NovaSwift/Game/GameContainerView.swift",
    "nav": "app/NovaSwift/Game/NavigationModel.swift",
}
SCENE_METHODS = (
    "worldSeed", "currentWorldSeed", "hasMissionShips", "spawnMissionShips",
    "tagEscort", "spawnRosterEscort", "respawnEscorts", "beginJump",
    "beginGateJump", "stepJump", "enterJumpPhase", "showJumpStreaks", "reloadSystem",
)
CONTAINER_METHODS = (
    "syncNav", "syncNavCourseToHUD", "spawnActiveMissionShips", "missionShipName",
    "missionShipSubtitle", "arrivalMode", "missionSystemMatches",
    "performGateJump", "attemptJump", "outboundHeading",
)


def digest(content: str | bytes) -> str:
    return hashlib.sha256(content.encode() if isinstance(content, str) else content).hexdigest()


def extract_method(content: str, name: str) -> str:
    """Balanced Swift function extraction, excluding braces in strings/comments."""
    match = re.search(rf"^[ \t]*(?:(?:private|fileprivate|public|static)\s+)*func {name}\(",
                      content, re.MULTILINE)
    if not match:
        raise ValueError(f"App method not found: {name}")
    start = match.start()
    pos = content.index("{", match.end())
    depth = 0
    while pos < len(content):
        if content.startswith("//", pos):
            end = content.find("\n", pos)
            pos = len(content) if end < 0 else end + 1
            continue
        if content.startswith("/*", pos):
            comment_depth = 1
            pos += 2
            while comment_depth:
                if content.startswith("/*", pos):
                    comment_depth += 1
                    pos += 2
                elif content.startswith("*/", pos):
                    comment_depth -= 1
                    pos += 2
                else:
                    pos += 1
                if pos >= len(content):
                    raise ValueError(f"Unclosed comment in {name}")
            continue
        if content[pos] == '"':
            quote = '"""' if content.startswith('"""', pos) else '"'
            pos += len(quote)
            while pos < len(content):
                if content[pos] == "\\":
                    pos += 2
                elif content.startswith(quote, pos):
                    pos += len(quote)
                    break
                else:
                    pos += 1
            continue
        if content[pos] == "{":
            depth += 1
        elif content[pos] == "}":
            depth -= 1
            if depth == 0:
                return content[start:pos + 1]
        pos += 1
    raise ValueError(f"Unclosed method: {name}")


def command(args: list[str], cwd: Path | None = None) -> str:
    return subprocess.check_output(args, cwd=cwd, text=True)


def stage_variant(source: Path, directory: Path, ref: str | None) -> dict:
    directory.mkdir()
    contents = {}
    for key, relative in APP_FILES.items():
        contents[key] = (command(["git", "show", f"{ref}:{relative}"], source)
                         if ref else (source / relative).read_text())
        (directory / Path(relative).name).write_text(contents[key])
    snippets = {
        "scene": {name: extract_method(contents["scene"], name) for name in SCENE_METHODS},
        "container": {name: extract_method(contents["container"], name) for name in CONTAINER_METHODS},
    }
    fixture = Path(__file__).with_suffix(".swift").read_text()
    for key in ("scene", "container"):
        fixture = fixture.replace(f"// EXTRACTED_{key.upper()}_METHODS",
                                  "\n\n".join(snippets[key].values()))
    (directory / "JumpArrivalFixture.swift").write_text(fixture)
    return {
        "appSourceSHA256": {APP_FILES[key]: digest(value) for key, value in contents.items()},
        "extractedMethodSHA256": {
            key: {name: digest(value) for name, value in methods.items()}
            for key, methods in snippets.items()
        },
        "fixtureSHA256": digest(fixture),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--data", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path, help="Fresh evidence directory")
    parser.add_argument("--baseline-ref", default="63cba42e33ea959cf93973cc418adfc9b6b073c4")
    parser.add_argument("--scratch", type=Path, help="Optional existing Swift build cache")
    parser.add_argument("--build-bin", type=Path,
                        help="Reuse a completed engine build read-only instead of running swift build")
    args = parser.parse_args()
    source = args.source.expanduser().resolve(strict=True)
    data = args.data.expanduser().resolve(strict=True)
    output = args.output.expanduser().resolve()
    if output.exists():
        parser.error("Output exists; choose a new evidence directory")
    output.mkdir(parents=True)
    scratch = args.scratch.expanduser().resolve() if args.scratch else output / "engine-build"
    if args.build_bin:
        build = args.build_bin.expanduser().resolve(strict=True)
    else:
        with (output / "engine-build.log").open("w") as log:
            subprocess.run(["swift", "build", "--scratch-path", str(scratch), "--target", "NovaSwiftStory"],
                           cwd=source, stdout=log, stderr=subprocess.STDOUT, check=True)
        build = Path(command(["swift", "build", "--scratch-path", str(scratch), "--show-bin-path"], source).strip())
    objects = []
    for module in ("NovaSwiftKit", "NovaSwiftEngine", "NovaSwiftStory", "Crypto"):
        files = sorted((build / f"{module}.build").glob("*.o"))
        if not files:
            raise ValueError(f"No compiled objects for {module}")
        objects.extend(map(str, files))
    reports = {}
    for name, ref in (("baseline", args.baseline_ref), ("fixed", None)):
        directory = output / name
        provenance = stage_variant(source, directory, ref)
        binary = directory / "check-jump-arrival"
        with (directory / "compile.log").open("w") as log:
            subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-I", str(build / "Modules"),
                            str(directory / "NavigationModel.swift"),
                            str(directory / "JumpArrivalFixture.swift"), *objects, "-o", str(binary)],
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        result = subprocess.run([str(binary), str(data)], capture_output=True, text=True)
        (directory / "run.log").write_text(result.stdout + result.stderr)
        result.check_returncode()
        report = json.loads(result.stdout)
        report.update(provenance)
        reports[name] = report
        (directory / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    comparison = {
        "source": str(source), "sourceHead": command(["git", "rev-parse", "HEAD"], source).strip(),
        "baselineHead": command(["git", "rev-parse", args.baseline_ref], source).strip(),
        "sameEngineBuildForBothVariants": True,
        "engineBuildBin": str(build),
        "engineObjectSHA256": {str(Path(name).relative_to(build)): digest(Path(name).read_bytes()) for name in objects},
        "engineSourceSHA256": {name: digest((source / name).read_bytes()) for name in (
            "Sources/NovaSwiftEngine/World.swift", "Sources/NovaSwiftEngine/GameSession.swift")},
        "reports": reports,
    }
    (output / "comparison.json").write_text(json.dumps(comparison, indent=2) + "\n")
    print(json.dumps({name: {"allChecksPass": report["allChecksPass"], "scenarios": report["scenarios"]}
                      for name, report in reports.items()}, indent=2))
    if not reports["fixed"]["allChecksPass"]:
        raise SystemExit("Fixed jump-arrival fixture failed")
    if any(case["wraithCountAfterArrival"] != 0 for case in reports["baseline"]["scenarios"]):
        raise SystemExit("Baseline did not reproduce the missing Wraith in both arrival modes")


if __name__ == "__main__":
    main()
