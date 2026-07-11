## Summary

<!-- What does this change do, and why? -->

## Type of change

- [ ] Bug fix
- [ ] Fidelity fix (brings behavior closer to the original EV Nova)
- [ ] New feature / enhancement (opt-in, see docs/CHARTER.md)
- [ ] Wiring (connects already-built code into the running app — update docs/STATUS.md)
- [ ] Refactor / cleanup, no behavior change
- [ ] Docs only

## Fidelity check

<!-- Per docs/CHARTER.md, fidelity to the original always comes first. -->

- [ ] A pure **Classic** run (all enhancements off) is unaffected, or unchanged in behavior
- [ ] Any new enhancement defaults to **OFF** and is additive, not a replacement
- [ ] No copyrighted game data was added to the repo (BYO-data — see docs/CHARTER.md)

## Testing

<!-- How did you verify this? -->

- [ ] `swift build && swift test` passes
- [ ] Manually exercised the affected flow (describe below)
- [ ] Verified against real game data / the original game's behavior (if a fidelity-relevant change)

<!-- Describe manual testing, or paste relevant test output. -->

## Docs

- [ ] Updated `docs/STATUS.md` if this changes what's wired vs. built vs. missing
- [ ] Updated other relevant docs (ROADMAP, ARCHITECTURE, subsystem deep-dives)
- [ ] N/A

## Related issues

<!-- Closes #, relates to # -->
