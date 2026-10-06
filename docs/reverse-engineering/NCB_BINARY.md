# NCB TEST binary behavior

The TEST evaluator now reproduces the inspected Windows engine's cursor and
accumulator behavior rather than applying conventional `! > & > |` precedence.
For example, with only bit 1 set, `b1 | b2 & b3` returns false. With bits 2 and
3 set, `b1 & b2 & b3` returns true: the second `&` resets the accumulator to the
latest operand. These are observed compatibility quirks, not recommended syntax
for new plug-ins. Parenthesize each binary operation to make intent explicit.

## Reference

This analysis uses the EV Nova CE executable included in the inspected WineNova
image, SHA-256
`08fa47d24920cf3e5e2cb08a002cab47aa93002dd6c0184d431af5fa32211419`.
It is PE32 x86 at image base `0x00400000`. No executable or original resource
data is included here.

[CE's symbol annotations](https://github.com/andrews05/EV-Nova-CE/blob/7c3fb177ba6e8cfc9cb90f61f0f0625bf54f63f3/sym.cpp)
identify the wrapper at `0x00447F20`. Ghidra and direct execution locate its
tokenizer at `0x00448BE0` and recursive evaluator at `0x00449020`, with shared
expression memory at `0x007C8A10`. The inspected original `.text` differs from
CE's preserved reference at only 910 of 1,479,168 raw bytes; `.rdata` is identical.
The oracle rejects other executable hashes rather than assuming those addresses
remain valid.

## Verified rules

- Every `&` or `|` starts from the latest operand, including repeated operators
  in a flat chain. Adjacent copies such as `&&` are consumed as one token.
- Repeated `!` sets one pending negation flag. `!!b1` consequently behaves like
  `!b1`; `!(!b1)` behaves like `b1`.
- Square brackets count true operands, with comparisons using `=`, `<`, or `>`.
  With bits 1 and 2 set, `( [b1 b2 b3] = 2 )` is true.
- The recursive scanner's cursor boundary matters. The immediately adjacent
  `([b1 b2 b3] = 2)` returns false for the same state. The documented spaced
  form above avoids that quirk.
- The wrapper accepts only a final result of exactly one. Identifiers consume
  adjacent ASCII digits through the original signed 16-bit arithmetic.

The documented syntax is described in the
[EV Nova resource reference](https://andrews05.github.io/evstuff/guides/evnbible.html).
The quirks above are observations from the pinned binary, not claims from that
reference.

## Differential coverage

The local data contains 791 mission availability expressions, 606 nonempty.
Exhaustive subsets of each expression's referenced control bits (at most seven)
and both callback truth values where applicable produce 5,507 cases. A further
184 synthetic cases cover flat chains, grouping, counted sets, repeated
operators, and negation. The upstream evaluator disagrees on 40 synthetic cases;
all 5,691 match the corrected Swift evaluator. The upstream and corrected
evaluators both match all 5,507 stock cases in this corpus.

The oracle executes only the original wrapper and reachable expression helpers
in a Unicorn x86 memory image. It does not launch the game, Wine, or Windows
APIs. Original B lookups and parser instructions run directly. P/O context
lookups are replaced with truth callbacks; their account, outfit, and other
game-state semantics are not validated. Stock mission expressions contain no
E/G atoms. The Swift context API and outer-whitespace normalization are preserved.
SET expressions and complete mission lifecycle behavior are outside this check.

The stock availability corpus does not contain counted sets, adjacent repeated
operators, double negation, or multiple flat operators at one level. This change
therefore establishes compatibility on those edges through synthetic cases,
rather than claiming to repair a demonstrated stock-campaign failure.

## Reproduce locally

Requirements: Swift, Python 3.11+, Unicorn 2.1.4, and your own matching reference
executable and BRGR `.rez` data. From the repository root, place them in
`.local/reference/EV Nova.exe` and `.local/reference/Nova Files/` or pass explicit
paths to the tools. Everything generated below stays in ignored `.local/`.

```sh
python3 -m venv .local/oracle-venv
.local/oracle-venv/bin/python -m pip install unicorn==2.1.4
python3 scripts/fidelity/scan_missions.py
.local/oracle-venv/bin/python scripts/fidelity/emulate_fixture_matrix.py
swiftc -parse-as-library Sources/NovaSwiftStory/NCBExpression.swift \
  scripts/fidelity/compare_ncb_oracle.swift -o .local/reports/oracle/compare-ncb
.local/reports/oracle/compare-ncb \
  .local/reports/oracle/x86-mission-ncb-cases.json \
  .local/reports/oracle/x86-ncb-fixture-matrix.json
swift test --filter NCBTests
```

The inspected corpus reports `Compared 5691 cases: 0 mismatches.` Both the mission
scan and generated cases contain the user's own resource strings and must remain
local. The committed regression cases are synthetic.
