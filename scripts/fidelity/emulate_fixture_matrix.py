import runpy
import json
from pathlib import Path

ns = runpy.run_path(str(Path(__file__).with_name("emulate_ncb.py")))
evaluate = ns["evaluate"]
expressions = [
    "( [b1 b2 b3] = 0 )",
    "( [b1 b2 b3] = 1 )",
    "( [b1 b2 b3] = 2 )",
    "( [b1 b2 b3] = 3 )",
    "( [b1 b2 b3] < 2 )",
    "( [b1 b2 b3] > 1 )",
    "!( [b1 b2 b3] > 1 )",
    "([b1 b2 b3] = 2)",
    "( [b1 (b2) b3] = 2 )",
    "b1 | b2 & b3",
    "b1 & b2 | b3",
    "b1 & b2 & b3",
    "b1 | b2 | b3",
    "b1 && b2",
    "b1 || b2",
    "!!b1",
    "!!!b1",
    "!(!b1)",
    "!(b1 | b2) & !b3",
    "!(b1 & (b2 | b3))",
    "((b1 | b2) & b3)",
    "(b1 & b2) & b3",
    "b1 | (b2 | b3)",
]
cases = []
for e in expressions:
    for mask in range(8):
        bits = [n for n in (1, 2, 3) if mask >> (n - 1) & 1]
        cases.append(
            dict(expression=e, bits=bits, atom=False, result=evaluate(e, bits))
        )
(ns["output"] / "x86-ncb-fixture-matrix.json").write_text(json.dumps(cases, indent=2))
print("Synthetic original x86 cases", len(cases), flush=True)
