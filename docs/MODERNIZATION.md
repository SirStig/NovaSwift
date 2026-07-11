# Modernization & Enhancement Layer

Plan for going *beyond* the original engine's constraints — smarter AI, higher-res
art, richer effects, better audio and UI — as **opt-in enhancements layered on top
of a faithful base**. Planned 2026-07-07. Not started.

See also: `ROADMAP.md` (fidelity-first goal), `MOBILE_AND_PLUGINS.md` (override
chain + toggles), `AI.md`, `EDITOR_AND_PLUGINS_SCOPE.md`.

## 0. Principles (the guardrails)

1. **Fidelity-first, enhancement-opt-in.** Every enhancement defaults **OFF**. A
   pure "Classic" run is always reproducible bit-for-bit. This is the project's
   stated contract (`ROADMAP.md`) and it does not change.
2. **One seam per subsystem.** Enhancements swap an implementation behind an
   existing interface; they never fork the engine. The AI seam
   (`AIBrain.think → ControlIntent`) and the presentation seams
   (`SpriteTextures`, `GameAudio`, `GameScene`) already exist.
3. **Determinism is sacred.** The sim is seeded (`RNG.swift`, SplitMix64). Any
   enhancement that touches gameplay (AI, spawns, difficulty) routes *all*
   randomness through `world.rng` so a seeded run never desyncs. Enhanced AI is a
   *different-but-deterministic* strategy, not a nondeterministic one.
4. **Legal posture is unchanged.** Nothing copyrighted is bundled — including
   *derivatives* of copyrighted art. Upscaled/repainted base sprites are
   derivative works and are treated exactly like base data: **bring-your-own or
   generate-on-device**; only cleanly-licensed community packs may be distributed.
5. **Graceful degradation.** Effects auto-scale to a performance tier; everything
   honors existing accessibility settings (`reduceFlashing`, `screenShake`,
   `frameRateCap`).

## 1. The unifying model: Enhancement toggles + Enhancement Packs

Two mechanisms cover everything the modernization umbrella needs.

### 1a. Enhancement toggles (code-side capabilities)

New fields on `GameSettings` (all `Bool`/enum, default off/classic). Because the
decoder is resilient, old saves keep working with zero migration. Surfaced in a new
launcher section **"Enhancements"**, each with a one-line explanation of what it
does — grouped: AI, Graphics, Audio, Interface, plus a **Performance Tier**
(auto / battery / balanced / max) that caps the effect budget per device.

These drive *code paths we already own* — smarter AI, particle systems, post-fx,
spatial audio, a modern HUD skin. No assets required, no legal exposure.

### 1b. Enhancement Packs (content-side, over the existing override chain)

Generalize `PluginBundle` / the override chain. Today a plug-in overrides game
**data** by `(type, id)`. An **Enhancement Pack** overrides **presentation** by
`(type, id)`: a higher-res sprite for `shïp 128`, a remastered clip for `snd 200`,
a normal/emissive map, a particle recipe. Same manifest → same toggle UI
(`PluginsView`) → same deterministic overlay, just a later layer:

```
base data → gameplay patches → (≤1) total conversion → presentation packs (HD art, audio, fx)
```

Presentation packs key to resource ids, so an HD pack works over the base *or* a TC
that reuses ids. Add pack kinds to `PluginKind`: `.hdArt`, `.audioPack`, `.fxPack`.
Same enable/disable/import flow that already ships.

**Why one system:** "add plugins" and "modernize the art/audio" become the same
first-class pipeline — manifest, overlay, toggle — instead of a bolted-on special
case.

## 2. Enhanced AI  (highest ROI, zero assets, zero legal drag → do first)

**Seam:** `NovaSwiftEngine/AIBrain.swift`. Keep today's state machine as the **Classic**
strategy (unchanged, still the default). Add an `AITuning` config and an **Enhanced**
strategy that is a superset.

```
struct AITuning {           // Classic preset = reproduces current behavior exactly
    var reactionTime: Double        // perception latency (fairness knob)
    var aimError: Double            // aim jitter; scales with difficulty
    var aggression: Double
    var useAfterburner: Bool
    var evade: Bool                 // juke under fire, break off head-ons
    var coordinate: Bool            // focus-fire, formations, roles
    var conserveAmmo: Bool          // missiles at optimal range, not spam
    var dynamicDifficulty: Bool     // scale skill/spawns to player ship strength
}
```

Enhanced behaviors, each a discrete, testable increment:

- **Threat-weighted targeting.** Replace naive `nearestHostile` with a scored pick
  (distance, incoming fire, target strength, kill-ability). Stop suiciding into the
  toughest thing nearby.
- **Maneuvering.** Use the **afterburner** the AI currently ignores; evasive jukes
  when shields drop; strafing runs; respect turret vs gun arcs; don't fly straight
  into missiles.
- **Coordination.** Escorts already adopt a leader's target — extend to fleet-wide
  focus-fire, flanker/tank roles, holding formation, and **distress →
  reinforcements** (already flagged ⏭ in `ROADMAP.md` §4).
- **Self-preservation.** Retreat toward friendly assets/planets, regroup, disengage
  cleanly, "land" to repair/refuel, conserve missile ammo.
- **Personality.** Drive style from `gövt` flags and (later) `përs` named captains.
- **Fairness / dynamic difficulty.** `reactionTime` + `aimError` scale with
  `GameSettings.difficulty` so Enhanced-normal is *smart, not unfair*; optional
  director scales spawn skill/size to the player's current ship.

**Determinism & tests.** All randomness through `world.rng`. New headless scenario
in `novaswift-extract ai` (Classic vs Enhanced), plus `AIBehaviorTests`: same seed →
same outcome; Enhanced wins 1v1 vs Classic at ≥ target rate; afterburner/evade
actually fire. Gameplay-affecting → record active AI mode in the pilot save so a
purist run is distinguishable.

## 3. Higher-res art & smoother animation

**Seam:** `Data/SpriteTextures.swift` (currently `SpriteSheet → SKTexture`, `.nearest`).

- **Filtering/scaling.** Wire the existing `smoothSprites` properly: linear +
  mipmaps; optional pixel-art upscaler (xBRZ/hqx-class) at load for crisp scaling
  without blur.
- **HD sprite packs (Enhancement Pack).** `SpriteTextures` gains an HD lookup: if an
  enabled pack supplies a texture for `(type, id)`, use it; else fall back to base.
  Packs may include **normal + emissive maps** for dynamic lighting (§4).
- **On-device ML upscale (legal-safe, universal).** A Core ML super-resolution model
  runs once over the user's *own* imported sprites at import, cached to their
  container. Output never leaves the device → same posture as BYO base data. Off by
  default (compute/quality trade-off).
- **Smoother animation.** EV Nova ships are 36 discrete rotation frames — add
  optional **frame interpolation / continuous rotation** and smoother banking; more
  engine-glow frames; modern explosion/particle art replacing `bööm` frames.
- **Per-sprite shaders.** Shields as a ripple shader, cloak as dissolve, battle
  damage as accumulating scorch, per-pixel lighting from weapons/suns via the
  pack's normal maps.

**Legal:** upscaled/HD *base* art is derivative → never bundled. Distributed HD
packs must be cleanly licensed community work; otherwise on-device generation only.

## 4. Effects & rendering  (engine-side → pure upside, no legal issue → do early)

**Seam:** `Game/GameScene.swift`. All behind an **Enhanced Effects** toggle with
sub-toggles, scaled by Performance Tier, honoring `reduceFlashing`/`screenShake`.

- **Post-processing:** bloom, subtle HDR tone, chromatic aberration on hits, motion
  blur.
- **Dynamic 2D lighting:** weapons, engines, explosions and stars cast additive
  light (full per-pixel with pack normal maps; additive glows without).
- **Particles:** engine trails, impact sparks, debris, asteroid dust, nebula
  volumetrics.
- **Parallax backgrounds:** multi-layer starfield + nebulae (extends
  `starfieldDensity`).
- **Screen-space set pieces:** hyperjump warp, explosion shockwaves.

None of this touches copyrighted assets — it's the safest, most visible "wow" win.

## 5. Audio modernization

**Seam:** `Audio/GameAudio.swift` / `NovaSoundLibrary.swift`.

- **HD audio packs (Enhancement Pack):** remastered / higher-sample-rate clips keyed
  by `snd` id — same overlay + toggle as art.
- **Spatial audio:** positional pan/attenuation from entity position
  (AVAudioEnvironmentNode / PHASE).
- **Dynamic music:** layered adaptive score (combat ↔ calm) with crossfades vs the
  original's static tracks.
- **Ambience:** per-system reverb/occlusion.

## 6. Modern UI / HUD

**Seam:** you already have `useAuthenticMenu` (authentic PICT HUD ↔ modern launcher)
and `AuthenticHUDView` + `GameHUD` + `GalaxyMapView`.

- **Modern HUD skin** option: crisp vector, fully scalable, animated — target info
  cards, lead reticle (ties to `autoTargetAfterFiring`), damage direction
  indicators, richer radar/minimap. Authentic PICT HUD stays the default.
- Themeable colors (from `ïntf` or custom); reuse existing `uiScale`, `largerHUD`,
  `highContrastHUD`, `colorblindMode`.

## 7. Settings scaffolding (concrete)

Add to `GameSettings` (all default off/classic; resilient decoder needs one line
each; bump nothing):

```
// Enhancements — Modernization
var enhancedAI = false
var aiCoordination = false
var aiDynamicDifficulty = false
var enhancedEffects = false          // master for §4
var dynamicLighting = false
var smoothRotation = false
var performanceTier: PerformanceTier = .auto
var spatialAudio = false
var dynamicMusic = false
var modernHUD = false
// HD-pack-dependent toggles are shown/enabled only when a matching pack is active.
```

New `Launcher/EnhancementsView.swift` (mirrors `SettingsView`/`PluginsView`), one
section per group, each row a toggle + explanatory caption. HD/audio-pack toggles
appear only when a corresponding Enhancement Pack is enabled.

## 8. Phasing

| Phase | Scope | Why here |
|------|-------|----------|
| **E1 — Scaffolding** | `GameSettings` fields, `EnhancementsView`, Performance Tier | cheap; unlocks everything; no risk |
| **E2 — Enhanced AI** | `AITuning` + Enhanced strategy, afterburner/evade/focus-fire, dynamic difficulty, tests | biggest "more fun" win; no assets, no legal drag |
| **E3 — Effects/rendering** | particles, glow, post-fx, parallax, smooth rotation | engine-side, pure upside, most visible |
| **E4 — Enhancement Pack system** | manifest + presentation overlay, `SpriteTextures`/`GameAudio` lookups | reuses existing override chain; enables E5 |
| **E5 — HD art & audio** | on-device upscale + pack format; spatial/dynamic audio | needs E4 + legal clearing for distributed packs |
| **E6 — Modern UI/HUD** | modern HUD skin, map/minimap polish, theming | polish; independent of the rest |

Order rationale: AI + effects first — they deliver the "smarter, better, more fun"
the request is really about, with **no asset dependency and no legal exposure**. The
pack pipeline and HD content come once the presentation seams and permissions are
settled.

## 9. Risks & open questions

- **Gameplay-affecting enhancements & save integrity.** Enhanced AI / dynamic
  difficulty change outcomes. Record the active enhancement set per-pilot so a
  purist run is identifiable; consider locking gameplay-affecting toggles at
  new-pilot time rather than mid-run.
- **Legal (distributed HD/audio packs).** Same unresolved gate as bundling
  community plug-ins (`MOBILE_AND_PLUGINS.md` §3): need per-author permission, else
  import-only / on-device-generate. Base derivatives never ship.
- **Performance.** Effects must degrade gracefully on 30fps / older iPhones — the
  Performance Tier must actually gate the particle/lighting/post-fx budget, not just
  label it.
- **On-device upscale quality/cost.** Model choice, one-time import compute, cache
  size, and whether results are good enough to be worth it — needs a spike.
- **Determinism regression tests.** A CI check that a seeded run produces identical
  state with enhancements off (and Enhanced AI produces identical state across runs
  of the same seed).
