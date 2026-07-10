# Escorts & Named/Special NPCs — Behavioral Ground Truth

Source: `data/EV Nova/Documentation/Nova Bible.txt` (official Ambrosia/Matt Burch
"Resource Bible"), read in full for the `përs` section (lines 2108–2252) plus
every other section that documents escort *behavior* — the `mïsn` special-ship
goal fields (~1417–1462), the `flët` fleet-escort fields (~896–944), the `gövt`
`VoiceType` field (~944–964), the `shïp` escort/hire/capture fields
(~2531–2735), and the `dësc` reserved-ID table (~723–732). Grep of the raw file
for `escort`/`hire`/`requisition` (case-insensitive) found **every** hit these
sections cover — there is no separate "escort resource"; escorting is a
cross-cutting behavior assembled from `përs`, `düde`/`flët`, `mïsn`, `gövt`, and
`shïp` fields.

This doc does **not** re-derive:
- `përs`/`düde` field-offset tables — see `docs/MISSIONS.md` (`PersRes`,
  `Sources/EVNovaKit/MissionModels.swift:317-351`) for the verified byte layout.
- The 4 base `AIType` dispositions or combat-AI variance sources (odds gating,
  cloak flags, jamming, etc.) — see `docs/AI_GROUND_TRUTH.md`, whose §1 already
  quotes `AIType = 0` = "use the ship's own inherent AI, only meaningful for
  escorts" verbatim. That statement is the hinge for this doc's §2 below.

---

## 1. What a `përs` is, and how it's placed in the world

> "The pers resource defines the characteristics of an AI personality - that
> is, a specific person the player can encounter in the game. These AI-people
> have their names (which are also the names of the associated pers resource)
> displayed on the target-info display in place of the name of their ship
> class."

Key distinction from a plain `düde` fleet ship: a `düde` class produces
anonymous, interchangeable ships of a probabilistic type; a `përs` is a single
named individual with hand-authored stats, loadout, and dialogue, layered
*on top of* the normal ship-spawning system.

**Appearance roll.** "When ships are created, there is a 5% chance that a
specific AI-person will also be created. (obviously, as AI-people are killed
off, they cease to appear in the game.)" — i.e. `përs` creation piggybacks on
ordinary ship spawning (dude/fleet spawns), it isn't scheduled independently,
and a `përs` has exactly one life: once its ship is destroyed, that roll can
never again produce it. (AI_GROUND_TRUTH.md §4.1 already covers this 5% figure
as one of the "where behavior varies" variance sources; repeated here only
because it's the *placement* mechanic, this doc's actual subject.)

**Location gating — `LinkSyst`:**

| Value | Meaning |
|---|---|
| -1 | Any system |
| 128–2175 | ID of a specific system |
| 9999–10255 | Any system belonging to this specific government |
| 15000–15255 | Any system belonging to an ally of this govt |
| 20000–20255 | Any system belonging to any but this govt |
| 25000–25255 | Any system belonging to an enemy of this govt |

**Existence gating — `ActiveOn`:** a standard NCB (control-bit) test
expression; blank = always eligible for the 5% roll. This is on top of, not
instead of, `LinkSyst` — both must pass.

**Character/ship fields relevant to placement, beyond what MISSIONS.md
already tables:** `Govt` (-1 = independent, else a specific government ID —
this is the government whose diplomatic stance the person's ship uses, and
per the `gövt` resource it also selects which of the 8 `VoiceType` comm-sound
sets plays for it); `ShipType` (the person's hull); custom `WeapType`/`WeapCount`/
`AmmoLoad` (×8 each) that can *add or remove* weapons relative to the hull's
stock loadout — "Standard weapons can be 'removed' by entering their ID
numbers in the WeapType fields and entering the negative of their standard
load ... in the WeapCount field"; `Credits` (±25% variance); `ShieldMod`
(percent multiplier on stock shield capacity — "a value less than zero makes
this person invincible"); `Color` (paint override, 00RRGGBB, 0 = no tint);
`Flags2 0x0001` ("This person starts with zero fuel").

---

## 2. `përs` as escort: recruitment, `AIType 0`, and the Bible's actual hire/requisition system

**The Bible's own escort economy does not run through `përs` at all — it runs
through the `shïp` resource's hire/capture fields, `flët`'s NPC-fleet-formation
fields, and `mïsn`'s special-ship-goal fields. `përs` only enters escort
territory indirectly, via mission linkage (§2.3 below).** This is the single
most important structural finding in this doc — do not build a "recruit this
`përs` as a permanent wingman" feature expecting it to be Bible-documented;
it isn't the design that shipped.

### 2.1 `AIType 0` and `shïp.InherentAI`

`düde.AIType`: "If you set this to 0, each ship will use its own inherent AI
type." `shïp.InherentAI` is introduced with: "The next field tells Nova what
kind of AI the ship will have if it's not created in connection with a dude
resource. **The only place this field is useful is when a ship is created as
an escort ship; otherwise, it's ignored:**"

> `InherentAI` — "What AI the ship uses when it's escorting the player. 1-4:
> Use this kind of AI... Note that only ships with inherent AI of 1 or 2 can
> be used to carry cargo when they are the player's escorts."

So: an escort ship (of any origin — hired, captured, or mission-granted) that
isn't itself governed by a `düde` uses its *hull's* `InherentAI` (1–4, the
same Wimpy/Brave/Warship/Interceptor scale as everywhere else) to decide how
it flies while tagging along — and only Wimpy/Brave-trader-classed escort
hulls (`InherentAI` 1 or 2) are eligible to actually haul cargo for the
player. This is a hull-level property (`shïp` resource), not a `përs`-level
one — a `përs`'s own `AI Type` field (1-4, same section, lines 2131-2138)
governs how that *named individual* fights/flees while independent/hostile,
before and separately from any escort relationship.

### 2.2 The real hire/requisition/capture system (`shïp` + `dësc` resources)

The Bible documents a full escort acquisition economy, entirely on ordinary
(non-`përs`) ship-class fields:

| Field (on `shïp`) | Meaning |
|---|---|
| `HireRandom` | "The percent chance that a ship of this type will be available for hire in the bar on a given day. A HireRandom of 0 means this ship will never be made available for hire." |
| `EscortType` | "Tells Nova which of the four categories of escorts to put this ship type into when organizing the escort control menu." -1 = auto-detect, 0 Fighter, 1 Medium Ship, 2 Warship, 3 Freighter |
| `UpgradeTo` | "If an escort ship of this type can be upgraded, this field holds the ID of the ship type that it can be upgraded to." 0/-1 = not upgradeable |
| `EscUpgrdCost` | "The cost to upgrade an escort ship of this type to the next more advanced version" |
| `EscSellValue` | "The amount of cash the player gets for selling off a captured escort of this type." ≤0 defaults to 10% of the ship's original `Cost` |
| `Crew` | "Ships with 0 crew can't be boarded, nor can they capture any other ships." — gates whether a hull can ever become a *captured* escort |
| `OnCapture` | NCB control-bit-set expression evaluated when the player captures a ship of this type |
| `OnRetire` | NCB control-bit-set expression evaluated when the player sells/replaces a ship of this type (applies to escorts sold off too) |

**Byte offsets now confirmed** (superseding the "unknown layout" framing this
section previously had). Method: `third_party/ResForge/Plugins/Sources/NovaTools/Templates.rsrc`
TMPL #518 (`shïp`), decoded field-by-field via `swift run evnova-extract tmpl
"third_party/ResForge/Plugins/Sources/NovaTools/Templates.rsrc" 518`, gives a
1860-byte total record. Cross-checked against real `shïp` records with
`swift run evnova-extract raw "data/EV Nova" shïp <id>` for **12 ships**
spanning fighters, medium ships, warships, carriers, and freighters (#128
Shuttle, #129 Heavy Shuttle, #130 Cargo Drone, #135 Lightning, #137 Valkyrie,
#141 Fed Destroyer, #142 Fed Patrol Boat, #143 Fed Carrier, #144 Fed Viper,
#161 Manta, #164 Raven, #167 Viper), plus a scripted sweep of the offsets
below over **284 of the ~288 base-game `shïp` records** (ids 128–415) to
check for outliers — every one of the 284 is exactly 1860 bytes:

| Bible field | Confirmed offset | Real type/size | Evidence |
|---|---|---|---|
| `HireRandom` | `@906` | `DWRD`, 2B | Sane 0–100 percentages across all 284 swept ships (208 are 0 = never hireable, e.g. Cargo Drone #130, Wraith variants #168-170 — matches non-combat/plot-only hulls; nonzero values cluster on fighters/mediums/warships, e.g. Viper #167 = 95, Valkyrie #137 = 50, Fed Viper #144 = 35) |
| `EscortType` (doc's name; field is unlabeled `DWRD` in the TMPL — naming it `EscortCategory` here to match this doc's evidence-based convention) | `@1842` | `DWRD`, 2B | Distribution across the 284-ship sweep: 0=Fighter ×25, 1=Medium Ship ×105, 2=Warship ×106, 3=Freighter ×48 — and the assignments are sane per-hull: Viper #167/Manta #161/Fed Viper #144 → 0 (Fighter); Valkyrie #137/Fed Patrol Boat #142 → 1 (Medium); Shuttle #128/Heavy Shuttle #129/Cargo Drone #130 → 3 (Freighter). No ship in the sweep used -1 (Automatic) |
| `UpgradeTo` | `@1832` | `RSID`, 2B | Every non-`(-1)` value in the sweep resolves to a **real `shïp` id with the same class name and equal-or-better stats** — e.g. Shuttle #128→#188 "Shuttle" (shield 30→35, armor 30→40), Fed Viper #144→#223 "Fed Viper" (shield 60→80), Valkyrie #137→#280 "Valkyrie" (armor 120→130), Fed Patrol Boat #142→#217 "Fed Patrol Boat" (shield 350→400), Viper #167→#335 "Viper" (shield 45→50), Manta #161→#315 "Manta" (shield 100→180) — confirmed with `swift run evnova-extract ship "data/EV Nova" <id>` on both ends of each chain. 133/284 swept ships are `-1` (not upgradeable), e.g. Cargo Drone #130, all three Wraith age-variants #168-170 |
| `EscUpgrdCost` | `@1834` | `DLNG`, 4B | Sane, tier-scaled credit values across the sweep: Shuttle #128 = 5,000cr, Fed Viper #144 = 50,000cr, Fed Patrol Boat #142 = 70,000cr, up to Leviathan #131 = 1,000,000cr (a superfreighter — plausible top-end price). Zero negative/overflow values anywhere in the 284-ship sweep |
| `EscSellValue` | `@1838` | `DLNG`, 4B | **Confirmed 0 on literally all 284 swept ships, with no exceptions.** Per the Bible's own text ("≤0 defaults to 10% of the ship's original `Cost`"), this means the retail game never overrides this field — every escort sale falls through to the automatic 10%-of-`Cost` default. (An earlier working note from this session misread ship #128's field at this offset as "3" — that was actually reading 4 bytes too far forward, into `EscortCategory@1842`'s value for that ship, which is legitimately 3 = Freighter. Re-verified byte-by-byte against the raw dump: `@1838`'s two 16-bit words are `0,0` for Shuttle, and `0,0` for every other ship checked.) |
| `Crew` | already decoded | — | `crew` at `Sources/EVNovaKit/NovaModels.swift:189` (`@68`, per the TMPL field list) — unrelated to this session's new offsets, listed here for completeness since the Bible groups it with the hire/capture fields |
| `OnCapture` | `@976` | `n0FF`, 255B (NCB Set) | Not spot-checked against real data this session (would require parsing/decoding an NCB control-bit-set expression, out of scope here) — offset is TMPL-derived only |
| `OnRetire` | `@1231` | `n0FF`, 255B (NCB Set) | Same caveat as `OnCapture` |

**Layout-confidence note: the `shïp` record's two weapon/outfit tables are
real, not a template-parser artifact.** The TMPL dump shows what looks like a
duplicate weapon table (4×`(RSID weapon, DWRD count, DWRD ammo)` at both
`@18` and `@1742`) and a duplicate outfit table (4×`(RSID outfit, DWRD count)`
at both `@78` and `@880`) — raising the question of whether this tool's
lack of `KEYB`/union support was silently printing the same physical bytes
twice under two labels (which would put every offset *after* the first
occurrence, including all of §2.2's escort fields, in doubt). This was
checked directly against real data across the same 12-ship sample:
- **The second outfit table (`@880`) is empty (`-1,-1,-1,-1`, counts `0,0,0,0`)
  on every one of the 12 ships checked**, including ships whose first table
  (`@78`) *is* populated (e.g. Fed Patrol Boat #142: `@78` = `[197, 240, -1,
  -1]` counts `[1, 1, 0, 0]` — a real afterburner-class outfit — vs. `@880` =
  all empty). A pure duplicate-read bug would mirror `@78`'s content into
  `@880`; it doesn't. This table appears to be a genuinely distinct,
  currently-unused-in-retail-data field, not a misread.
- **The second weapon table (`@1742`) is not a duplicate of `@18` either, and
  is not always empty** — it holds real, *different* weapon ids on ships
  whose primary 4-slot table (`@18`) is completely full: Fed Carrier #143's
  `@18` = `[132, 135, 149, 150]` (4/4 slots used) and `@1742` = `[133, -1,
  -1, -1]` (weapon 133, count 2) — a fifth weapon type absent from the
  primary table. Same pattern on Fed Destroyer #141 (`@18` full with
  `[131, 134, 128, 133]`, `@1742` = `[129, ...]`), Aurora Carrier #153
  (`@18` full, `@1742` = `[144, ...]`), and Aurora Cruiser #154 (`@18` full,
  `@1742` = `[162, ...]`). This is not a universal rule — Pirate Carrier #147
  also has a full `@18` table but an empty `@1742` — and every ship checked
  with a non-full primary table (Shuttle, Valkyrie, Manta, Viper, Raven,
  Manticore, Arachnid, Fed Viper, Fed Patrol Boat) has an empty `@1742`
  regardless of fill level. The evidence best supports **`@1742` being a real,
  optional fifth weapon slot** used by a minority of heavily-armed hulls that
  need more than four distinct weapon types, not a parser double-read.

Practical upshot for this doc: since both "second table" regions sit
*between* `EscUpgrdCost`/`EscSellValue`/`EscortCategory` (all `@1832+`) and
have no bearing on whether the bytes *before* them (`@0`–`@904`, where
`HireRandom` and `BuyRandom` live) are correctly located, and since the total
record size (1860B) was independently confirmed exact across all 284 swept
ships, this ambiguity does not undermine confidence in any offset cited in
the table above — it was worth resolving on its own merits (per the shared
open question from this reverse-engineering pass), and the answer is "two
genuinely separate, TMPL-declared fields," not "one field misread as two."

Capture odds themselves are computed from `Crew` plus the `oütf` ModType 25
("marines") outfit: "Adds the value in ModVal to your ship's effective crew
complement when calculating capture odds ... -1 to -100: Increase the
player's capture odds by this amount" — i.e. marines are a purchasable,
stackable capture-odds booster, separate from any escort mechanic per se, but
this is how a *captured enemy ship* becomes an escort in the first place
(hire in the bar and capture in combat are the two acquisition paths; there is
no third "recruit a `përs`" path in the resource fields).

**UI surfaces named explicitly** (`dësc` reserved-ID table): "13000-13767 Ship
class descriptions, shown in the shipyard and **requisition-escort dialog**."
/ "14000-14767 Ship pilot descriptions, shown in the **hire-escort dialog**."
— two distinct dialogs: a "requisition" flow (likely the free/mission-granted
path) and a paid "hire" flow (the bar, gated by `HireRandom`), each with its
own description-text resources. There's also a standing **"escort control
menu"** referenced in passing by the `FloatingMap` field: "Floating hyperspace
map / escort menu border color" — i.e. escorts get a persistent management
UI, grouped into the four `EscortType` categories, not just a hail-dialog
button.

**Pricing gap:** the Bible documents `HireRandom` (availability chance) and
`EscUpgrdCost`/`EscSellValue` (upgrade/resale) but never states a distinct
"hire price" field — `Cost` is introduced once, for outright purchase ("tells
Nova how much to charge you when you buy this ship"), and no second price
field exists near `HireRandom`. The likely reading is that hiring charges the
same `Cost` the shipyard would, but this is an inference, not a quoted rule —
flagging it as unresolved from the Bible text alone.

**`gövt.VoiceType`:** "Sets this government's voice type, used for when you
have a ship of this government as your escort (i.e. an escort with an
inherent attributes govt field that points to this govt). There can be up to
eight different voice types" (0-7), each with 10 acknowledgement + 10
targeting + 10 victory `snd ` clips (1000-1029 for type 0, +100 per type). So
an escort's *comm voice* is selected by its ship's `InherentGovt`, not by
anything `përs`-specific either.

### 2.3 Where `përs` actually connects to escorting: mission linkage + flag 0x0040

A `përs` becomes an escort only by being folded into a *mission's* special
ships, via its `LinkMission` field and this flag:

> `Flags 0x0040`: "When LinkMission is accepted with a single SpecialShip,
> replace it with this ship while removing this one from play. **This is
> generally only useful for escort and refuel-a-ship missions.** Note: if the
> mission's SpecialShip dude type contains the pers ship's ship type in it,
> the SpecialShip that's created will be of the same type as the pers ship...
> to prevent a pers ship from accidentally morphing into another ship type
> before the player's eyes."

And the companion note on `mïsn.ShipStart`: "a ShipStart value of 0 (appear
randomly in the system) is the proper value to use in conjunction with pers
resource flag 0x0040." So the intended flow is: the player hails/boards a
named `përs` captain in open space → accepts their `LinkMission` → the game
despawns the standalone `përs` ship and spawns the mission's `ShipCount`/
`ShipDude`/`ShipGoal` special ship(s) in its place (same hull type, guaranteed
by the sub-rule above) → the mission's `ShipGoal = 3` ("Escort them - keep
them from getting killed") makes that former-`përs` ship the player's
protection charge for the mission's duration. This is a **per-mission,
temporary** escort relationship scoped to one mission's lifetime, not the
persistent hire/requisition roster from §2.2 — the Bible gives no field
anywhere that promotes a mission's special ship into the *permanent* escort
list after the mission ends.

Related `mïsn` fields (full section starts ~line 1417):

| Field | Values |
|---|---|
| `ShipCount` | -1 none, 0-31 special ships |
| `ShipSyst` | where they appear (-1 initial system … -6 "whatever system the player is in (i.e. follow him around)" … or a specific/relative-government system) |
| `ShipDude` | which `düde` class supplies their hull/AI/govt |
| `ShipGoal` | -1 none, **0 destroy all, 1 disable-only, 2 board, 3 escort them (keep them from getting killed), 4 observe, 5 rescue (start disabled, stay so until boarded — unless the govt has the "always disabled" flag), 6 chase them off (kill or scare into jumping out)** |
| `ShipBehav` | -1 standard AI, 0 always attack the player, 1 protect the player, 2 attempt to destroy enemy stellars |
| `ShipStart` | on-top-of-nav-default -4..-1, 0 random (pair with `përs` 0x0040), 1 jump in after delay, 2 random+cloaked |

`ShipBehav = 1` ("protect the player") is the actual command-verb analog of
"defend me" for mission special ships — this, not anything on `përs` itself,
is the field that makes a special ship behave like a bodyguard. AI_GROUND_TRUTH.md
§4.8 already flags `ShipBehav` as a deferred item (needs mission-driven ship
spawning wired through `EVNovaStory` — not done).

### 2.4 `flët` (fleet) escorts — a third, unrelated meaning of "escort"

The `flët` resource's `EscortType`(×4)/`Min`(×4)/`Max`(×4) fields describe
**NPC formation escorts around an NPC flagship** (e.g. a warship convoy with
2-4 fighter screens) — nothing to do with the player's own escort roster.
This is the one escort concept that's fully implemented today (§5).

---

## 3. Escort combat/command behavior — comm verbs and what's actually implemented

**The Bible documents no comm-dialog order verbs for player-held escorts at
all** — no "Hold Position," "Attack My Target," "Dock," "Form Up," etc. appear
anywhere in the text (grepped case-insensitively; zero hits for any of those
phrases). The only escort-adjacent *behavioral* toggle the Bible gives the
player is `ShipBehav` on the mission side (§2.3) — an author-time mission
field, not a runtime player command. Real EV Nova's escort command menu (the
one implied by the "escort control menu"/`FloatingMap` border-color field in
§2.2) is understood from general EV Nova knowledge to offer simple stance
toggles per escort (aggressive/defensive/hold-fire and similar), but **the
Bible prose itself stops at the resource-field level and never spells out
those verbs** — this is a real gap in the source document, not something this
doc is choosing to omit.

**What the codebase actually has today is a different, unrelated feature:**
the "assistance mechanics" commit (`bdf82d2`, "Implement assistance
mechanics for NPCs and enhance communication features") added a **one-shot,
paid "tow truck" hail service**, not escort recruitment or command:

- `AIBrain.assist` (`Sources/EVNovaEngine/AIBrain.swift:481-502`) — a hailed
  NPC flies to the player, docks within 90 units, and calls
  `World.deliverAssistance` exactly once (`assistDelivered` latch), which
  refuels the player to full and floors armor at 40% max
  (`Sources/EVNovaEngine/World.swift:892-897`). After delivery, if the player
  currently has a hostile ship targeted and the assisting NPC is armed, it
  will pitch in against that one target (reusing `attack()` wholesale) before
  departing on a 4-second timer (`AIBrain.swift:492-501`).
- `HailDialogView.swift` (`app/EVNova/Game/HailDialogView.swift:17-115`) — the
  comm dialog exposes exactly **three** buttons: `Greetings`, `Request
  Assistance`, `Close Channel` (lines 84-88). No per-escort order verbs exist
  because there is no persistent escort object to command — assistance is
  requested from, and delivered by, *any* nearby non-hostile ship, ally or
  stranger, and the relationship ends the moment it flies off.
- Pricing is by diplomatic tier, not `përs`/hire economics: `assistanceTier`
  (`GameScene`) maps to free (ally), 300cr (neutral), or 900cr with only a 50%
  acceptance chance (wary/dislikes-you-but-not-hostile) —
  `app/EVNova/Game/GameContainerView.swift:190-193, 580-615`. This pricing
  model is an invented scope cut with no Bible citation (the Bible's own
  hire/capture pricing is `Cost`/`EscUpgrdCost`/`EscSellValue`, none of which
  this code path reads).

So: **the recent commit is not an implementation of the Bible's `përs`/
hire-escort system at all** — it's a same-verb-different-mechanic feature
(paid battlefield support call) layered on top of the diplomacy system. It
does not create a `Ship.brain.leaderID` relationship, does not add anything to
a persistent escort roster, and does not touch `PersRes` in any way.

---

## 4. Escort persistence, death, and capacity — what the Bible specifies (and doesn't)

- **Death is permanent for a `përs`.** Directly stated: "as AI-people are
  killed off, they cease to appear in the game." No respawn, no re-recruitment
  of the same named individual once destroyed — the 5%-roll population pool
  for that `LinkSyst` simply shrinks by one entry forever.
- **Grudge flag (`Flags 0x0001`) survives death of the relationship, not the
  ship:** "The special ship will hold a grudge if attacked, and will
  subsequently attack the player wherever the twain shall meet" — this is
  about a *hostile* `përs` remembering the player, unrelated to escort
  persistence, but worth noting since it's the only cross-encounter memory
  the resource defines.
- **Escort ships acquired via hire/capture (§2.2) are NOT documented as
  permanent or loss-free either** — `EscSellValue` exists specifically
  because the player can choose to sell a captured escort off, and nothing in
  the text states escorts are shielded from being destroyed in combat; there
  is no "escort invulnerability" flag on `shïp` (contrast with `përs.ShieldMod
  < 0` = invincible, which is a per-`përs` override, not an escort-general
  rule). The closest thing to escort damage immunity is a *different*
  mechanic entirely: `düde.Booty` note "0x0100 Ships of this dude type can't
  be hit by the player and their shots can't hit the player (useful for
  things like AuxShip mission escorts, etc.)" — a dude-class flag for
  *player-proof* NPCs used in some escort-flavored missions, not a property
  of the player's own hired/captured roster.
- **Capacity/hire limits are not specified in the Bible text at all** — no
  field caps the number of simultaneous hired/captured escorts, no bay-space
  or hangar-slot mechanic is mentioned anywhere in the `shïp`/`gövt`/`mïsn`
  sections searched for this doc. (EV Nova is widely known, outside the Bible,
  to cap the escort roster in practice, but that's not something the
  developer-facing resource documentation states — flagging as an unresolved
  gap rather than asserting a number.)
- **Cargo-carrying escorts** are capacity-relevant in one specific way: only
  `InherentAI` 1/2 (trader-classed) escorts "can be used to carry cargo when
  they are the player's escorts" (§2.1) — implying escorts have their own
  cargo holds usable for mission cargo overflow, gated by hull disposition,
  not a universal escort-cargo rule.

---

## 5. What's implemented vs. what's missing

| Bible concept | Status | Where |
|---|---|---|
| `PersRes` field decoder (LinkSyst, Govt, AIType, Aggress, Coward, ShipType, LinkMission, flags, activeOn, subtitle) | ✅ Decoded | `Sources/EVNovaKit/MissionModels.swift:317-351`; exposed via `game.pers(id)`/`game.persons()`, `Sources/EVNovaKit/NovaModels.swift:454-455` |
| `përs` 5%-chance spawn-time creation, tied to ordinary ship spawns | ❌ Not wired | No caller of `PersRes`/`game.pers`/`game.persons()` exists anywhere outside the decoder file and its accessor (verified by repo-wide grep). `docs/MISSIONS.md`'s own "Not yet wired" section already flags this: "`përs` captains offering their linked missions in space (needs AI to place them; the decoder + `activeOn`/`linkMission` fields are ready)." |
| `AIType 0` → `shïp.InherentAI` fallback for escorts | Partially decoded, not escort-specific | `inherentAI` decoded at `Sources/EVNovaKit/NovaModels.swift:193,265` (`@66`); `AIType(raw:)` fallback exists generically (see AI_GROUND_TRUTH.md §1) but nothing in the engine currently creates a "hired/captured escort using its hull's InherentAI" — the only consumer of `InherentAI` today is `Spawner.spawnFleet` picking a flagship/escort's *own* disposition for NPC-fleet ships (`Sources/EVNovaEngine/Spawner.swift:132-133,158-165`), not a player-owned escort |
| `shïp.HireRandom` (bar hire availability) | ❌ Not decoded, offset now confirmed | No `hireRandom` field on `ShipRes` (`Sources/EVNovaKit/NovaModels.swift:151-311` — compare `buyRandom` at line 240, which *is* decoded per commit `ff8fc20`, at the adjacent offset `@904`). Confirmed at `@906` (`DWRD`, 2B) via TMPL #518 + a 284-ship raw-data sweep — see §2.2's table |
| `shïp.EscortType`/`UpgradeTo`/`EscUpgrdCost`/`EscSellValue` (escort-menu categorization, upgrades, resale) | ❌ Not decoded, offsets now confirmed | Same struct; none of these four fields exist on `ShipRes`. Confirmed offsets (§2.2): `UpgradeTo`(doc's name for `EscortUpgradesTo`)`@1832`(`RSID`,2B), `EscUpgrdCost@1834`(`DLNG`,4B), `EscSellValue@1838`(`DLNG`,4B, empirically always `0` in retail data — falls through to the Bible's documented 10%-of-`Cost` default), `EscortType@1842`(`DWRD`,2B, this doc's `EscortCategory`) — all byte-verified against 12 individually-inspected ships plus a 284-ship automated sweep, not just the single Shuttle (#128) spot-check from the earlier working pass |
| "Requisition-escort" / "hire-escort" dialogs, escort control menu | ❌ Not built | No matching view in `app/EVNova/` (only `HailDialogView.swift`'s 3-button in-flight comm dialog exists, and it's unrelated — see §3) |
| Persistent player escort roster (hired, captured, or mission-granted) | ❌ Not built | `PilotInfoView`'s "Escorts" section is a static placeholder: `app/EVNova/Story/StoryGuideView.swift:119-120` — `section("Escorts") { Text("No escorts hired.") ... }`, no backing data model, never populated |
| `gövt.VoiceType` (per-government escort comm voice, 8 types × ack/target/victory `snd`) | ✅ Decoded, unused for escorts | `Sources/EVNovaKit/NovaAIModels.swift:220,264` decodes `voiceType`; not consumed anywhere for playing escort ack/targeting/victory audio (no escort feature exists to consume it) |
| Capture mechanics (`Crew`, marines `ModType 25`, `OnCapture`) | Partially decoded | `crew` decoded (`NovaModels.swift:189`); marines outfit ModVal handling and `OnCapture` control-bit-set evaluation not found in `Sources/EVNovaEngine` (no boarding/capture system exists in this engine yet per AI_GROUND_TRUTH.md's boarding caveat, §1 item 3) |
| `mïsn.ShipGoal`/`ShipBehav`/`ShipStart` (mission special-ship goals incl. `ShipGoal=3` escort-the-NPC, `ShipBehav=1` protect-the-player) | ❌ Deferred | AI_GROUND_TRUTH.md §6 item 12: "blocked on [EVNovaStory-to-game-loop wiring], not on anything AI-specific" — same root cause as the `përs` placement gap above |
| `flët.EscortType`/`Min`/`Max` — NPC fleet escort formations | ✅ Implemented | `Sources/EVNovaEngine/Spawner.swift:126-163` (`spawnFleet`) builds a flagship + numbered escort slots; `Sources/EVNovaEngine/AIBrain.swift:17,42-45,240-252,450-473` (`AIState.escorting`, `leaderID`, `formationSlot`, `escort()` V-wing station-keeping) drives their flight. This is the one escort concept fully built — but it's the *NPC convoy screen* meaning of "escort," not the player's own roster. |
| `përs.ShieldMod < 0` invincibility, custom weapon add/remove, grudge flag, escape-pod flag | Field-decoded only | `flags1`/related bits exist on `PersRes` (`MissionModels.swift:328-334`, only 3 of the ~16 documented flag bits have named accessors: `deactivateAfterAccept`, `offerOnBoard`, `leavesAfterAccept`); no runtime behavior consumes any of them since `PersRes` is never instantiated (see row 2) |
| "Assist" paid support call (recent commit `bdf82d2`) | ✅ Implemented, but **not** a Bible `përs`/escort feature | See §3 — `AIBrain.assist`, `World.deliverAssistance`, `HailDialogView`'s "Request Assistance" button, `GameContainerView`'s tier-based pricing. A legitimate, self-consistent invented mechanic, but should not be mistaken for progress on `përs` recruitment, hire/requisition dialogs, or a command-verb system — it shares no code path with any of those. |

**Bottom line:** the escort *AI-formation* half of EV Nova (flët-driven NPC
convoys) is built; the entire *player-facing* half — hiring in the bar,
requisitioning via mission, capturing, upgrading, a persistent roster with a
management menu, and command verbs in the hail dialog — is undocumented in
code beyond decoding a few unused struct fields and one static UI placeholder
string. `PersRes` decodes cleanly but has zero runtime consumers.
