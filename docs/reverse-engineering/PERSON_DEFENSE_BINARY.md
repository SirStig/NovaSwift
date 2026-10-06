# Named-person defense multiplier

The positive `përs.ShieldMod` percentage scales both armor and shields in the
original Windows engine. NovaSwift previously applied it only to shields, leaving
named-person armor at the base hull value. The NPC customization path now scales
both maximum defenses and fills current defenses from those maxima as before.

For a synthetic hull with armor 80, a modifier of 50 gives armor 40; 300 gives
240. This changes named-person survivability according to the original modifier.
The local corpus has 253 positive modifiers other than 100 across 516 person
resources. That is resource coverage, not a claim that every person spawns in a
particular campaign or that its complete loadout has been verified.

## Original-routine evidence

Reference executable SHA-256:
`08fa47d24920cf3e5e2cb08a002cab47aa93002dd6c0184d431af5fa32211419`.
The CE [symbol annotations](https://github.com/andrews05/EV-Nova-CE/blob/7c3fb177ba6e8cfc9cb90f61f0f0625bf54f63f3/sym.cpp)
anchor the armor-capacity helper at `0x004637A0`. A resource-loader slice at
`0x004C3595` through `0x004C35E9` reads the signed 16-bit personality percentage
from raw resource offset 40, divides by 100, and stores it as Float32.

The NPC armor helper multiplies base template armor by that strictly positive
Float32 factor. Its ordinary return remains in x87, without rounding the product
to Float32. For modifier 130, the parsed factor is `1.2999999523162842`, so base
armor 80 returns `103.99999618530273` when captured as Double. Capturing that
return as Float gives 104. Ten isolated checks of the maximum-shield helper at
`0x00463550` confirm the same ordinary NPC multiplication and return precision.
NovaSwift keeps Double defense fields and reproduces
the original factor conversion before multiplying them.

The helper was executed in isolated Unicorn memory with synthetic ship, person,
outfit, and quantity tables. There are no arithmetic or context callbacks. The
oracle ran 246 controlled armor cases, 15 original percentage conversions, and
all 516 local raw person modifiers applied to a synthetic armor base; all checks
passed. Its instruction hook covered all eight recorded helper branches.
These are oracle checks of the recovered contract; the native spawn regressions
check the named-person subset through public `Spawner.populate`. A separate
native comparator spawns a controlled hull for every local person modifier;
all 516 Float32 armor captures match the original helper.

## Scope and remaining differences

- Zero and negative personality modifiers keep the existing native behavior.
  Negative-modifier invincibility is not established by the armor helper alone.
- The original helper's player branch clamps negative capacity to zero, while
  NovaSwift floors capacity at one. Changing that floor alone would break the
  native `armor > 0` life-state invariant and kill shield-only vessels. That
  difference needs a separate life-state correction and remains outside this fix.
- Original numeric subtype 5 adds another multiplier. It is assigned during
  fighter launch and saved-escort restoration, and starting HP can differ from
  capacity. Native leader/escort relationships have not been mapped to that
  lifecycle, so this change does not apply that multiplier speculatively.
- Native current HP stays at its full Double maximum on spawn. This is not a
  claim of matching every original Float32 HP store or later damage operation.
- The oracle initializes x87 to control word `0x037F`. The full game's runtime
  FPU control word, actual spawn composition, and combat trajectories were not
  recovered by this experiment.

## Reproduce locally

Supply your own matching executable and BRGR data under
`.local/reference/EV Nova.exe` and `.local/reference/Nova Files/`, or pass
`--exe`, `--nova-files`, and `--output` explicitly. No game binary, raw resource
data, person names, or generated resource fixtures are committed.

```sh
python3 -m venv .local/oracle-venv
.local/oracle-venv/bin/python -m pip install unicorn==2.1.4
.local/oracle-venv/bin/python scripts/fidelity/emulate_armor.py
python3 scripts/fidelity/compare_person_armor.py
swift test --filter PersSpawnTests
```

Reports and local disassembly go into ignored `.local/reports/armor/`. The tool
pins the executable hash and never launches the full game or Wine.
