#!/usr/bin/env python3
"""Execute pinned EV Nova x86 armor and NPC shield helpers in synthetic memory.

Requires unicorn==2.1.4. No game launch, OS import callbacks, or game-state
callbacks: only original arithmetic instructions and an x87 result adapter run.
Binary/data-derived reports stay in the ignored output directory.
"""

import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import random
import struct
import subprocess

import unicorn
from unicorn import Uc, UC_ARCH_X86, UC_HOOK_CODE, UC_MODE_32
from unicorn.x86_const import UC_X86_REG_EIP, UC_X86_REG_ESI, UC_X86_REG_ESP


EXPECTED_SHA = "08fa47d24920cf3e5e2cb08a002cab47aa93002dd6c0184d431af5fa32211419"
HELPER = 0x4637A0
HELPER_END = 0x4638DD
SHIELD_HELPER = 0x463550
SHIELD_HELPER_END = 0x46367D
PERSON_LOAD_START = 0x4C3595
PERSON_LOAD_END = 0x4C35EA
SHIP = 0x2000000
SHIP_TABLE = 0x2010000
OUTFIT_TABLE = 0x2400000
PERSON_TABLE = 0x2500000
RESULT = 0x2700000
RAW_HANDLE = 0x2700100
RAW_PERSON = 0x2701000
ADAPTER = 0x3000000
PERSON_ADAPTER = ADAPTER + 0x100
SHIELD_ADAPTER = ADAPTER + 0x200
CACHE = 0x735690
SHIP_STRIDE = 0xABC
OUTFIT_STRIDE = 0x37C
PERSON_STRIDE = 0x794
QUANTITIES = 0x5993B4
BRANCHES = {
    "npc_path": 0x4637CF,
    "positive_person_multiplier": 0x463807,
    "subtype_5_multiplier": 0x46381D,
    "player_recompute": 0x46384E,
    "armor_modifier_slot": 0x463878,
    "negative_player_clamp": 0x4638BD,
    "player_cache_write": 0x4638C1,
    "player_cache_reuse": 0x4638D0,
}


def f32(value):
    return struct.unpack("<f", struct.pack("<f", value))[0]


def number(value):
    if math.isnan(value):
        return "NaN"
    if math.isinf(value):
        return "+Infinity" if value > 0 else "-Infinity"
    return value


def float_input(value):
    if isinstance(value, str):
        return {"NaN": math.nan, "+Infinity": math.inf, "-Infinity": -math.inf}[value]
    return value


def float_description(data, fmt):
    return {
        "value": number(struct.unpack(fmt, data)[0]),
        "little_endian_hex": data.hex(),
    }


class ArmorOracle:
    def __init__(self, exe):
        self.data = exe.read_bytes()
        self.sha = hashlib.sha256(self.data).hexdigest()
        if self.sha != EXPECTED_SHA:
            raise ValueError(
                "Binary SHA256 mismatch: oracle addresses require the pinned inspected executable"
            )
        pe = struct.unpack_from("<I", self.data, 0x3C)[0]
        if self.data[pe : pe + 4] != b"PE\0\0":
            raise ValueError("Expected PE executable")
        section_count = struct.unpack_from("<H", self.data, pe + 6)[0]
        optional = pe + 24
        optional_size = struct.unpack_from("<H", self.data, pe + 20)[0]
        base = struct.unpack_from("<I", self.data, optional + 28)[0]
        image_size = struct.unpack_from("<I", self.data, optional + 56)[0]
        if (
            base != 0x400000
            or struct.unpack_from("<H", self.data, optional)[0] != 0x10B
        ):
            raise ValueError("Expected PE32 image at 0x400000")
        self.uc = Uc(UC_ARCH_X86, UC_MODE_32)
        self.uc.mem_map(base, (image_size + 0xFFF) & ~0xFFF)
        for index in range(section_count):
            header = optional + optional_size + 40 * index
            _, rva, size, raw = struct.unpack_from("<IIII", self.data, header + 8)
            if size:
                self.uc.mem_write(base + rva, self.data[raw : raw + size])
        self.uc.mem_map(0x1000000, 0x100000)
        self.uc.mem_map(0x2000000, 0x800000)
        self.uc.mem_map(ADAPTER, 0x1000)
        self.write_u32(0x5912A4, SHIP_TABLE)
        self.write_u32(0x5912C8, OUTFIT_TABLE)
        self.write_u32(0x5912D4, PERSON_TABLE)
        self.write_u32(0x8610D0, RAW_HANDLE)
        self.write_u32(RAW_HANDLE, RAW_PERSON)
        # FNINIT; PUSH ship; CALL original; ADD ESP,4; FST m32; FST m64;
        # FSTP m80. The adapter preserves the returned x87 value for all stores.
        adapter = b"\xdb\xe3\x68" + struct.pack("<I", SHIP)
        adapter += b"\xe8" + struct.pack("<i", HELPER - (ADAPTER + len(adapter) + 5))
        adapter += b"\x83\xc4\x04\xd9\x15" + struct.pack("<I", RESULT)
        adapter += b"\xdd\x15" + struct.pack("<I", RESULT + 8)
        adapter += b"\xdb\x3d" + struct.pack("<I", RESULT + 16)
        self.adapter_end = ADAPTER + len(adapter)
        self.uc.mem_write(ADAPTER, adapter)
        # Separate immutable adapters avoid stale translated call instructions
        # when switching routines in a reused Unicorn VM.
        shield_adapter = bytearray(adapter)
        shield_adapter[8:12] = struct.pack("<i", SHIELD_HELPER - (SHIELD_ADAPTER + 12))
        self.uc.mem_write(SHIELD_ADAPTER, bytes(shield_adapter))
        self.shield_adapter_end = SHIELD_ADAPTER + len(shield_adapter)
        # A second adapter initializes x87 and jumps into a straight-line
        # original resource loader slice; emulation stops before its next field.
        self.uc.mem_write(
            PERSON_ADAPTER,
            b"\xdb\xe3\xe9"
            + struct.pack("<i", PERSON_LOAD_START - (PERSON_ADAPTER + 7)),
        )
        self.visited = set()
        self.all_visited = set()
        self.uc.hook_add(UC_HOOK_CODE, self.observe, begin=HELPER, end=HELPER_END - 1)
        self.factor = struct.unpack("<d", self.uc.mem_read(0x575760, 8))[0]
        self.percent_divisor = struct.unpack("<d", self.uc.mem_read(0x575E48, 8))[0]

    def observe(self, _uc, address, _size, _user):
        self.visited.add(address)
        self.all_visited.add(address)

    def write_u32(self, address, value):
        self.uc.mem_write(address, struct.pack("<I", value))

    def write_i16(self, address, value):
        self.uc.mem_write(address, struct.pack("<h", value))

    def execute(self, case, *, npc_shield=False):
        uc = self.uc
        if npc_shield and case.get("mode", 0) == 0:
            raise ValueError(
                "Shield confidence check is limited to the NPC person path"
            )
        adapter = SHIELD_ADAPTER if npc_shield else ADAPTER
        adapter_end = self.shield_adapter_end if npc_shield else self.adapter_end
        cache_address = 0x735688 if npc_shield else CACHE
        template_offset = 0x5C if npc_shield else 0x60
        self.visited = set()
        uc.mem_write(SHIP, bytes(0xC948))
        uc.mem_write(SHIP_TABLE, bytes(SHIP_STRIDE * 768))
        uc.mem_write(OUTFIT_TABLE, bytes(OUTFIT_STRIDE * 512))
        uc.mem_write(PERSON_TABLE, bytes(PERSON_STRIDE * 1024))
        uc.mem_write(QUANTITIES, bytes(512 * 2))
        ship_class = case.get("ship_class", 0)
        if not 0 <= ship_class < 768:
            raise ValueError("Synthetic ship_class outside the allocated table")
        self.write_i16(SHIP + 0x76, ship_class)
        self.write_i16(SHIP + 0x86, case.get("mode", 0))
        self.write_i16(SHIP + 0x88, case.get("subtype", 0))
        self.write_i16(SHIP + 0xC8D0, case.get("person_index", -1))
        uc.mem_write(
            SHIP_TABLE + ship_class * SHIP_STRIDE + template_offset,
            struct.pack("<i", case["base_armor"]),
        )
        uc.mem_write(
            cache_address, struct.pack("<f", float_input(case.get("cache", -1.0)))
        )
        person = case.get("person_index", -1)
        if 0 <= person < 1024:
            uc.mem_write(
                PERSON_TABLE + person * PERSON_STRIDE + 0x61C,
                struct.pack("<f", float_input(case.get("person_factor", 1.0))),
            )
        for outfit in case.get("outfits", []):
            index = outfit["index"]
            if not 0 <= index < 512 or len(outfit["slots"]) > 4:
                raise ValueError(
                    "Outfit index/slot count outside original table bounds"
                )
            self.write_i16(QUANTITIES + 2 * index, outfit["count"])
            for slot, (kind, value) in enumerate(outfit["slots"]):
                self.write_i16(
                    OUTFIT_TABLE + index * OUTFIT_STRIDE + 4 + 2 * slot, kind
                )
                self.write_i16(
                    OUTFIT_TABLE + index * OUTFIT_STRIDE + 12 + 2 * slot, value
                )
        uc.mem_write(RESULT, bytes(32))
        uc.reg_write(UC_X86_REG_ESP, 0x1080000)
        uc.emu_start(adapter, adapter_end, count=200000)
        if uc.reg_read(UC_X86_REG_EIP) != adapter_end:
            raise RuntimeError(
                "Armor routine did not finish within the instruction budget"
            )
        return {
            "float32_result": float_description(bytes(uc.mem_read(RESULT, 4)), "<f"),
            "float64_result": float_description(
                bytes(uc.mem_read(RESULT + 8, 8)), "<d"
            ),
            "float80_result_hex": bytes(uc.mem_read(RESULT + 16, 10)).hex(),
            "cache_after": float_description(
                bytes(uc.mem_read(cache_address, 4)), "<f"
            ),
            "branches": [
                name for name, address in BRANCHES.items() if address in self.visited
            ],
            "visited_instructions": [
                f"0x{address:08X}" for address in sorted(self.visited)
            ],
        }

    def decode_person_percent(self, raw_percent):
        self.write_i16(RAW_PERSON + 40, raw_percent)
        self.uc.reg_write(UC_X86_REG_ESI, 0)
        self.uc.reg_write(UC_X86_REG_ESP, 0x1080000)
        self.uc.emu_start(PERSON_ADAPTER, PERSON_LOAD_END, count=100)
        if self.uc.reg_read(UC_X86_REG_EIP) != PERSON_LOAD_END:
            raise RuntimeError("Original person resource loader slice did not finish")
        return float_description(bytes(self.uc.mem_read(PERSON_TABLE + 0x61C, 4)), "<f")


def expected_contract(case, subtype_factor):
    """Independent arithmetic check of the recovered contract, not the oracle."""
    cache = f32(float_input(case.get("cache", -1.0)))
    value = case["base_armor"]
    if case.get("mode", 0) == 0:
        if math.isnan(cache) or cache < 0:
            for outfit in case.get("outfits", []):
                if outfit["count"] > 0:
                    value += sum(
                        modifier * outfit["count"]
                        for kind, modifier in outfit["slots"]
                        if kind == 6
                    )
            value = max(0, value)
            cache = f32(value)
        else:
            value = cache
    else:
        if 0 <= case.get("person_index", -1) < 1024:
            factor = f32(float_input(case.get("person_factor", 1.0)))
            if factor > 0:
                value *= factor
        if case.get("subtype", 0) == 5:
            value = f32(value * subtype_factor)
    return struct.pack("<f", value).hex(), struct.pack("<f", cache).hex()


def outfit(index, count, *slots):
    return {"index": index, "count": count, "slots": list(slots)}


def fixtures(seed, random_count):
    cases = []

    def add(name, base=30, **kwargs):
        cases.append({"name": name, "base_armor": base, **kwargs})

    add("player_base")
    add("player_zero_base", 0)
    add("player_negative_base", -30)
    add("player_type6_positive", outfits=[outfit(0, 2, (6, 12))])
    add("player_net_zero", outfits=[outfit(0, 3, (6, -10))])
    add("player_net_negative", outfits=[outfit(0, 4, (6, -10))])
    add(
        "player_all_four_slots",
        outfits=[outfit(7, 2, (6, 12), (6, -3), (4, 500), (6, 7))],
    )
    add(
        "player_nonarmor_slots",
        outfits=[outfit(0, 7, (4, 999), (0, -10), (5, 200), (7, 10))],
    )
    add(
        "player_nonpositive_counts",
        outfits=[
            outfit(0, 0, (6, 99)),
            outfit(1, -1, (6, 99)),
            outfit(2, -32768, (6, 99)),
        ],
    )
    add(
        "player_outfit_upper_boundary",
        ship_class=767,
        outfits=[outfit(511, 3, (6, 10))],
    )
    add(
        "player_signed_slot_extremes",
        outfits=[outfit(0, 32767, (6, 32767)), outfit(511, 32767, (6, -32768))],
    )
    add("player_return_retains_precision", 16777216, outfits=[outfit(0, 1, (6, 1))])
    add(
        "player_player_ignores_person_and_subtype",
        person_index=0,
        person_factor=2.5,
        subtype=5,
    )
    for name, value in [
        ("zero", 0.0),
        ("positive", 8.0),
        ("negative_zero", -0.0),
        ("negative", -0.5),
        ("nan", "NaN"),
        ("positive_infinity", "+Infinity"),
        ("negative_infinity", "-Infinity"),
    ]:
        add("player_cache_" + name, cache=value, outfits=[outfit(0, 2, (6, 4))])
    add("npc_base", mode=1)
    add("npc_zero_base", 0, mode=1)
    add("npc_negative_base", -30, mode=1)
    add(
        "npc_ignores_player_outfits_and_cache",
        mode=1,
        cache=999.0,
        outfits=[outfit(0, 2, (6, 99))],
    )
    for index in [-32768, -1, 0, 1023, 1024, 32767]:
        add(f"npc_person_index_{index}", mode=1, person_index=index, person_factor=2.0)
    for name, factor in [
        ("half", 0.5),
        ("one_and_half", 1.5),
        ("zero", 0.0),
        ("negative", -1.0),
        ("nan", "NaN"),
        ("infinity", "+Infinity"),
    ]:
        add("npc_person_" + name, mode=-1, person_index=0, person_factor=factor)
    add("npc_subtype5", mode=1, subtype=5)
    add(
        "npc_person_percent130_unrounded_return",
        80,
        mode=1,
        person_index=0,
        person_factor=f32(1.3),
    )
    add("npc_subtype5_person", mode=1, subtype=5, person_index=0, person_factor=1.25)
    add(
        "npc_subtype5_explicit_float32_rounding",
        32767,
        mode=1,
        subtype=5,
        person_index=0,
        person_factor=f32(1.1),
    )
    add("npc_subtype5_negative", -30, mode=1, subtype=5)
    for subtype in [0, 1, 4, 6, -1]:
        add(f"npc_other_subtype_{subtype}", mode=1, subtype=subtype)
    rng = random.Random(seed)
    for index in range(random_count):
        base = rng.randint(-32768, 32767)
        if index % 2 == 0:
            entries = []
            for item in rng.sample(range(512), rng.randrange(1, 8)):
                entries.append(
                    outfit(
                        item,
                        rng.randint(-4, 100),
                        *[
                            (rng.choice([0, 4, 6, 6, 7]), rng.randint(-1000, 1000))
                            for _ in range(4)
                        ],
                    )
                )
            add(
                f"random_player_{index}",
                base,
                outfits=entries,
                ship_class=rng.randrange(768),
            )
        else:
            add(
                f"random_npc_{index}",
                base,
                mode=rng.choice([-1, 1, 2]),
                subtype=rng.choice([0, 1, 5, 6]),
                person_index=rng.choice([-1, 0, 1023, 1024]),
                person_factor=rng.choice([-1.0, 0.0, 0.01, 1.0, 1.05, 1.3, 2.5, 20.0]),
            )
    return cases


def scan_person_resources(directory, oracle):
    # Reuse the existing data reader without changing it; its main is guarded.
    from scan_missions import read_rez

    resources = {}
    files = sorted(directory.glob("*.rez"))
    for file in files:
        for kind, resource_id, name, data in read_rez(file):
            if kind == "përs":
                resources[resource_id] = (name, data)
    records = []
    failures = []
    for resource_id, (name, data) in sorted(resources.items()):
        raw = struct.unpack_from(">h", data, 40)[0]
        decoded = oracle.decode_person_percent(raw)
        expected = struct.pack("<f", raw / 100.0).hex()
        case = {
            "name": f"resource_person_{resource_id}",
            "base_armor": 30,
            "mode": 1,
            "person_index": 0,
            "person_factor": decoded["value"],
        }
        output = oracle.execute(case)
        value = 30 * f32(raw / 100.0) if raw > 0 else 30
        passed = (
            decoded["little_endian_hex"] == expected
            and output["float32_result"]["little_endian_hex"]
            == struct.pack("<f", value).hex()
        )
        records.append(
            {
                "id": resource_id,
                "name": name,
                "raw_shield_mod": raw,
                "parsed_factor": decoded,
                "synthetic_armor_base": 30,
                "oracle_armor": output["float32_result"],
                "passed": passed,
            }
        )
        if not passed:
            failures.append(resource_id)
    return {
        "files": [str(file) for file in files],
        "count": len(records),
        "positive_non100": sum(
            item["raw_shield_mod"] > 0 and item["raw_shield_mod"] != 100
            for item in records
        ),
        "negative": sum(item["raw_shield_mod"] < 0 for item in records),
        "raw_value_counts": dict(
            sorted(Counter(item["raw_shield_mod"] for item in records).items())
        ),
        "failures": failures,
        "persons": records,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--exe", type=Path, default=Path.cwd() / ".local/reference/EV Nova.exe"
    )
    parser.add_argument(
        "--output", type=Path, default=Path.cwd() / ".local/reports/armor"
    )
    parser.add_argument(
        "--nova-files", type=Path, default=Path.cwd() / ".local/reference/Nova Files"
    )
    parser.add_argument("--seed", type=int, default=4637)
    parser.add_argument("--random-cases", type=int, default=200)
    args = parser.parse_args()
    oracle = ArmorOracle(args.exe)
    args.output.mkdir(parents=True, exist_ok=True)
    cases = []
    failures = []
    for case in fixtures(args.seed, args.random_cases):
        result = oracle.execute(case)
        expected_result, expected_cache = expected_contract(case, oracle.factor)
        passed = (
            result["float32_result"]["little_endian_hex"] == expected_result
            and result["cache_after"]["little_endian_hex"] == expected_cache
        )
        cases.append(
            {
                "input": case,
                "original": result,
                "contract_check": {
                    "float32_result_hex": expected_result,
                    "cache_hex": expected_cache,
                    "passed": passed,
                },
            }
        )
        if not passed:
            failures.append(case["name"])
    percent_cases = []
    for raw in [
        -32768,
        -1,
        0,
        1,
        20,
        100,
        105,
        110,
        125,
        130,
        150,
        200,
        250,
        2000,
        32767,
    ]:
        output = oracle.decode_person_percent(raw)
        passed = output["little_endian_hex"] == struct.pack("<f", raw / 100.0).hex()
        percent_cases.append(
            {"raw_signed16": raw, "original_float32": output, "passed": passed}
        )
        if not passed:
            failures.append(f"person_percent_{raw}")
    shield_cases = []
    for raw in [-1, 0, 1, 100, 105, 125, 130, 200, 250, 2000]:
        factor = oracle.decode_person_percent(raw)["value"]
        case = {
            "name": f"npc_shield_percent_{raw}",
            "base_armor": 80,
            "mode": 1,
            "person_index": 0,
            "person_factor": factor,
            "cache": 999.0,
        }
        result = oracle.execute(case, npc_shield=True)
        value = 80 * factor if raw > 0 else 80
        passed = (
            result["float64_result"]["little_endian_hex"]
            == struct.pack("<d", value).hex()
            and result["cache_after"]["value"] == 999.0
        )
        shield_cases.append(
            {
                "raw_signed16_percent": raw,
                "base_shield": 80,
                "parsed_factor": factor,
                "original": result,
                "passed": passed,
            }
        )
        if not passed:
            failures.append(f"shield_percent_{raw}")
    persons = (
        scan_person_resources(args.nova_files, oracle)
        if args.nova_files.is_dir()
        else {"count": 0, "failures": [], "skipped": "Resource directory absent"}
    )
    branches = {
        name: address in oracle.all_visited for name, address in BRANCHES.items()
    }
    limitations = [
        "Only armor helper 0x4637A0, the NPC person path of shield helper 0x463550, and the straight-line person resource conversion slice 0x4C3595..0x4C35E9 execute; no game process or OS calls.",
        "No arithmetic or game-state callbacks are mocked. A code hook observes helper instruction coverage only.",
        "Ship/person/outfit table pointers, player outfit quantities, cache and instance fields are controlled synthetic memory, not live game state.",
        "FNINIT chooses x87 control word 0x037F (round nearest, extended precision); the game's runtime FPU control word was not recovered.",
        "Float32 return capture mirrors common callers; x87 extended return and float32 cache can differ for large synthetic values.",
        "Person resource scan reads big-endian BRGR fields, supplies signed16 values in the Windows loader's byte-order-normalized working buffer, and applies each result to synthetic base armor 30; actual spawn/loadout composition and campaigns are not validated.",
        "Negative NPC template armor and nonfinite factors/cache are synthetic edge cases, not asserted normal resource states.",
        "Subtype 5 is assigned by original fighter launch at 0x41E7C4 and saved-escort restore at 0x4CCD60, but broader native leader/escort relationships have not been mapped to it.",
    ]
    report = {
        "schema_version": 1,
        "executable": str(args.exe),
        "executable_sha256": oracle.sha,
        "tool_version": {"unicorn": unicorn.__version__},
        "helper_start": "0x004637A0",
        "helper_end_exclusive": "0x004638DD",
        "seed": args.seed,
        "synthetic_cases": len(cases),
        "person_conversion_cases": len(percent_cases),
        "resource_person_cases": persons["count"],
        "failures": failures + persons["failures"],
        "shield_person_cases": len(shield_cases),
        "shield_helper_start": "0x00463550",
        "shield_helper_end_exclusive": "0x0046367D",
        "branches": branches,
        "visited_instruction_count": len(oracle.all_visited),
        "subtype5_double": oracle.factor,
        "percent_divisor_double": oracle.percent_divisor,
        "limitations": limitations,
        "cases": cases,
        "person_conversion": percent_cases,
        "shield_person": shield_cases,
    }
    (args.output / "armor-oracle.json").write_text(
        json.dumps(report, indent=2, allow_nan=False) + "\n"
    )
    (args.output / "person-resource-armor.json").write_text(
        json.dumps(persons, indent=2, allow_nan=False) + "\n"
    )
    # Disassembly is a local evidence artifact, never embedded into tracked code.
    for name, start, end in [
        ("armor", HELPER, HELPER_END),
        ("shield", SHIELD_HELPER, SHIELD_HELPER_END),
        ("person-percent", PERSON_LOAD_START, PERSON_LOAD_END),
    ]:
        output = subprocess.run(
            [
                "objdump",
                "-d",
                f"--start-address={hex(start)}",
                f"--stop-address={hex(end)}",
                "--x86-asm-syntax=intel",
                str(args.exe),
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        (args.output / f"{name}-disassembly.txt").write_text(output.stdout)
    lines = [
        "# Original armor oracle",
        "",
        f"Pinned executable SHA256 `{oracle.sha}`; Unicorn {unicorn.__version__}.",
        "",
        f"Executed {len(cases)} controlled armor cases, {len(percent_cases)} raw person conversions, {persons['count']} local person resource conversions/armor applications, and {len(shield_cases)} narrow NPC shield checks. Failures: {len(report['failures'])}.",
        "",
        "Player mode (+0x86 == 0) reuses nonnegative float32 cache, including zero. Negative or NaN cache recomputes signed32 template armor plus every type 6 signed16 modifier times positive signed16 installed count across 512 outfits and four slots each, then clamps negative totals to zero. A negative-zero cache is reused unchanged.",
        "",
        "NPC mode (+0x86 != 0) uses template armor without player-owned outfit additions or player clamp. Valid person index 0..<1024 selects a strictly positive float32 factor. Raw person ShieldMod signed16 at resource offset 40 is divided by 100 and rounded to float32 by the original loader. Numeric subtype 5 then multiplies by the stored double 1.333 and explicitly rounds to float32.",
        "",
        "Ordinary person multiplication returns the x87 product without an explicit float32 round. Base 80 with raw percent 130 returns 103.99999618530273 as float64, while callers storing float32 see 104. The script captures both representations; fidelity corrections must choose according to the native field/callsite being modeled.",
        "",
        "Shield helper 0x463550 loads signed32 base at template +0x5C, reads the same parsed person float32 at +0x61C (0x46359B), and multiplies with FMUL ST,ST(1) at 0x4635B1. Its ordinary NPC return has no intervening float32 store. Ten original executions confirm the same unrounded product, including base 80 / percent 130, and confirm the shield cache is unchanged. This narrow check uses valid person index 0 and subtype 0; it does not broaden armor's table-bound claims to shield.",
        "",
        "Original subtype 5 stores occur in fighter launch at 0x41E7C4 and saved-pilot escort restoration at 0x4CCD60. Fighter launch initializes current armor directly from template armor at 0x41E8CD, so boosted capacity does not prove boosted starting HP. No assumption equates all native leader/escort relationships to subtype 5.",
        "",
        "The original returns x87 ST0. When recomputing player armor it also stores float32 cache without truncating the returned accumulator: synthetic base 16777216 plus 1 returns 16777217 as float64 while cache/float32 return are 16777216.",
        "",
        f"Local person resources: {persons.get('positive_non100', 0)} positive modifiers other than 100; {persons.get('negative', 0)} negative modifiers. Resource names/values exist only in ignored reports.",
        "",
        "## Limitations",
        "",
        *[f"- {item}" for item in limitations],
        "",
        "## Reproduce",
        "",
        "```sh",
        ".local/oracle-venv/bin/python tools/emulate_armor.py",
        "```",
        "",
    ]
    (args.output / "armor-report.md").write_text("\n".join(lines))
    summary = {
        key: report[key]
        for key in [
            "executable_sha256",
            "tool_version",
            "synthetic_cases",
            "person_conversion_cases",
            "resource_person_cases",
            "shield_person_cases",
            "failures",
            "branches",
            "visited_instruction_count",
        ]
    }
    print(json.dumps(summary, indent=2))
    return 1 if report["failures"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
