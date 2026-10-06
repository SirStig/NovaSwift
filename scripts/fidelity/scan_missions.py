#!/usr/bin/env python3
"""Scan local Windows EV Nova BRGR .rez mission conditions; write ignored JSON.
Reads resource data only. Never installs or launches the downloaded executable.
"""

import argparse
import json
import re
import struct
from pathlib import Path


def read_rez(file):
    data = file.read_bytes()
    if data[:4] != b"BRGR" or struct.unpack_from("<I", data, 4)[0] != 1:
        raise ValueError(f"{file}: expected BRGR version 1")
    count = struct.unpack_from("<I", data, 20)[0]
    if not 1 <= count <= (len(data) - 24) // 12:
        raise ValueError("invalid index count")
    entries = [struct.unpack_from("<III", data, 24 + 12 * n) for n in range(count)]
    if any(offset + size > len(data) for offset, size, _ in entries):
        raise ValueError("entry outside file")
    map_offset, map_size, _ = entries[-1]
    num_types = struct.unpack_from(">I", data, map_offset + 4)[0]
    pos = map_offset + 8 + 12 * num_types
    if pos + 266 * (count - 1) > map_offset + map_size:
        raise ValueError("resource records outside map")
    for _ in range(count - 1):
        index = struct.unpack_from(">I", data, pos)[0]
        if not 1 <= index < count:
            raise ValueError("resource entry index invalid")
        kind = data[pos + 4 : pos + 8].decode("mac_roman")
        rid = struct.unpack_from(">H", data, pos + 8)[0]
        name = data[pos + 10 : pos + 266].split(b"\0", 1)[0].decode("mac_roman")
        offset, size, _ = entries[index - 1]
        yield kind, rid, name, data[offset : offset + size]
        pos += 266


def level_ops(s):
    levels = [[]]
    finished = []
    for ch in s:
        if ch in "([":
            levels.append([])
        elif ch in ")]":
            if len(levels) > 1:
                finished.append(levels.pop())
        elif ch in "&|":
            levels[-1].append(ch)
    return finished + levels


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--nova-files", type=Path, default=Path.cwd() / ".local/reference/Nova Files"
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path.cwd() / ".local/reports/oracle/mission-ncb-scan.json",
    )
    args = parser.parse_args()
    files = sorted(args.nova_files.glob("*.rez"))
    if not files:
        raise SystemExit(f"No .rez files in {args.nova_files}")
    resources = {}
    for file in files:
        for kind, rid, name, data in read_rez(file):
            resources[(kind, rid)] = (name, data)
    missions = []
    for (kind, rid), (name, data) in resources.items():
        if kind != "mïsn":
            continue
        if len(data) < 347:
            raise ValueError(f"mission {rid}: incomplete condition field")
        text = data[92:347].split(b"\0", 1)[0].decode("mac_roman")
        ops = level_ops(re.sub(r"([&|])\1+", r"\1", text))
        flags = dict(
            counted_set="[" in text,
            repeated_operators=bool(re.search(r"&&|\|\|", text)),
            double_negation=bool(re.search(r"!\s*!", text)),
            mixed_same_level=any("&" in v and "|" in v for v in ops),
            multiple_same_level=any(len(v) > 1 for v in ops),
        )
        missions.append(dict(id=rid, name=name, expression=text, **flags))
    missions.sort(key=lambda m: m["id"])
    summary = dict(
        total=len(missions),
        nonempty=sum(bool(m["expression"]) for m in missions),
        feature_counts={
            f: sum(m[f] for m in missions)
            for f in [
                "counted_set",
                "repeated_operators",
                "double_negation",
                "mixed_same_level",
                "multiple_same_level",
            ]
        },
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(dict(summary=summary, missions=missions), indent=2) + "\n"
    )
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
