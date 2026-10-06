"""Execute ONLY original x86 condition functions in an isolated Unicorn VM.
No game process, Wine, OS API, file/network I/O, or persistent game state.
P/O context lookups are callback atoms; B bit lookup and parser code are original.
"""

import json
import re
import struct
import hashlib
import argparse
from pathlib import Path
from unicorn import Uc, UC_ARCH_X86, UC_MODE_32, UC_HOOK_CODE
from unicorn.x86_const import UC_X86_REG_ESP, UC_X86_REG_EAX, UC_X86_REG_EIP

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    "--exe", type=Path, default=Path.cwd() / ".local/reference/EV Nova.exe"
)
parser.add_argument(
    "--mission-scan",
    type=Path,
    default=Path.cwd() / ".local/reports/oracle/mission-ncb-scan.json",
)
parser.add_argument("--output", type=Path, default=Path.cwd() / ".local/reports/oracle")
args = parser.parse_args()
exe = args.exe
output = args.output
output.mkdir(parents=True, exist_ok=True)
b = exe.read_bytes()
expected_sha = "08fa47d24920cf3e5e2cb08a002cab47aa93002dd6c0184d431af5fa32211419"
if hashlib.sha256(b).hexdigest() != expected_sha:
    raise SystemExit(
        "Binary SHA256 mismatch: this oracle is pinned to the inspected CE executable."
    )
pe = struct.unpack_from("<I", b, 0x3C)[0] + 4
ns = struct.unpack_from("<H", b, pe + 2)[0]
opt = pe + 20
hs = struct.unpack_from("<H", b, pe + 16)[0]
szimage = struct.unpack_from("<I", b, opt + 56)[0]
u = Uc(UC_ARCH_X86, UC_MODE_32)
u.mem_map(0x400000, (szimage + 0xFFF) & ~0xFFF)
for i in range(ns):
    o = opt + hs + i * 40
    vsz, rva, sz, raw = struct.unpack_from("<IIII", b, o + 8)
    if sz:
        u.mem_write(0x400000 + rva, b[raw : raw + sz])
u.mem_map(0x1000000, 0x100000)
u.mem_map(0x2000000, 0x100000)
u.mem_map(0x3000000, 0x1000)
u.mem_write(0x5914CC, struct.pack("<I", 0x2000000))
ctx = {}


def token_context(uc, address, size, user):
    esp = uc.reg_read(UC_X86_REG_ESP)
    idxptr = struct.unpack("<I", uc.mem_read(esp + 4, 4))[0]
    idx = struct.unpack("<h", uc.mem_read(idxptr, 2))[0]
    ch = bytes(uc.mem_read(0x7C8A10 + idx, 1)).decode("ascii")
    if ch.lower() not in ("p", "o"):
        return
    i = idx + 1
    while bytes(uc.mem_read(0x7C8A10 + i, 1)) in [bytes([v]) for v in range(48, 58)]:
        i += 1
    uc.mem_write(idxptr, struct.pack("<h", i))
    uc.reg_write(UC_X86_REG_EAX, 0x31 if ctx["atom"] else 0x30)
    ret = struct.unpack("<I", uc.mem_read(esp, 4))[0]
    uc.reg_write(UC_X86_REG_ESP, esp + 4)
    uc.reg_write(UC_X86_REG_EIP, ret)


u.hook_add(UC_HOOK_CODE, token_context, begin=0x448BE0, end=0x448BE0)


def evaluate(text, bits, atom=False):
    bitbuf = bytearray(10000)
    for bit in bits:
        bitbuf[bit] = 1
    u.mem_write(0x2000000, bytes(bitbuf))
    u.mem_write(0x2010000, text.encode("ascii") + b"\0")
    ctx["atom"] = atom
    sp = 0x10FFFF0
    u.mem_write(sp, struct.pack("<II", 0x3000000, 0x2010000))
    u.reg_write(UC_X86_REG_ESP, sp)
    u.emu_start(0x447F20, 0x3000000, count=1_000_000)
    if u.reg_read(UC_X86_REG_EIP) != 0x3000000:
        raise RuntimeError("instruction budget reached")
    return bool(u.reg_read(UC_X86_REG_EAX) & 255)


fixtures = [
    ("([b1 b2 b3] = 2)", [1, 2]),
    ("b1 | b2 & b3", [1]),
    ("b1 & b2 | b3", [2]),
    ("b1 & b2 & b3", [2, 3]),
    ("b1 && b2", [1, 2]),
    ("b1 || b2", [2]),
    ("!!b1", [1]),
    ("!(!b1)", [1]),
    ("!(b511 | b515) & !b350", []),
    ("!(b511 | b515) & !b350", [511]),
]
fixtures = [
    dict(expression=t, bits=v, atom=False, result=evaluate(t, v)) for t, v in fixtures
]
(output / "x86-ncb-fixtures.json").write_text(json.dumps(fixtures, indent=2))
print(json.dumps(fixtures, indent=2), flush=True)
missions = json.load(args.mission_scan.open())["missions"]
cases = []
for m in missions:
    text = m["expression"]
    bits = sorted(set(int(v) for v in re.findall(r"[bB](\d+)", text)))
    atoms = [False, True] if re.search(r"[pPoO]", text) else [False]
    for mask in range(1 << len(bits)):
        active = [bit for i, bit in enumerate(bits) if mask >> i & 1]
        for atom in atoms:
            cases.append(
                dict(
                    mission=m["id"],
                    expression=text,
                    bits=active,
                    atom=atom,
                    result=evaluate(text, active, atom),
                )
            )
(output / "x86-mission-ncb-cases.json").write_text(
    json.dumps(cases, separators=(",", ":"))
)
print(
    "Original x86 evaluated",
    len(cases),
    "cases across",
    len(missions),
    "missions. SHA256",
    hashlib.sha256(b).hexdigest(),
    flush=True,
)
