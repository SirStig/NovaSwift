# Background events — the `crön` resource ("Nova control bits" time system)

> **Scope note.** [MISSIONS.md](../MISSIONS.md) already documents the `crön`
> field-decoding layer (verified byte offsets, 125 real crons, the shared NCB
> engine) and the `StoryEngine`/`GameServices` wiring status. This doc does not
> restate those offset tables — it goes one level deeper: what a cron is *for*
> in the real game, the exact behavioral contract of its fields, and how that
> contract compares to what `StoryEngine.swift` actually does today. Per
> [STATUS.md](../STATUS.md) / MISSIONS.md's banner, the story module is
> **BUILT, NOT WIRED** — everything below that says "the engine does X" means
> "X happens in `EVNovaStory` unit tests and the `evnova-extract story` CLI
> path," not "the player has ever seen it," since no live `GameServices`
> conformer exists and the app never instantiates `StoryEngine` for play.

Primary source: `data/EV Nova/Documentation/Nova Bible.txt` — the official
Ambrosia/Matt Burch "Resource Bible." The `crön` resource is documented at
lines 598–715 (`* The crön resource` through the end of its "Some notes"
section); the shared control-bit ("NCB") grammar both TEST and SET strings use
is documented at lines 97–193 (`A quick word about control bits and scripting
in EV Nova`). All quotes below are verbatim from that file unless marked as
paraphrase.

## 1. What a cron is for

The Bible's own framing (line 600):

> "Cron resources are used to define time-dependent events that occur in a
> manner that is **invisible to the player** but can cause interesting things
> to happen in the universe, via the manipulation of control bits."

It then lists the three canonical use patterns (lines 602–611), verbatim:

- "an event that occurs periodically during the course of the game"
- "an event that occurs at some fixed date during the game, as part of the
  story's set script"
- "an event, triggered by the actions of the player, that occurs after some
  fixed or random interval"

In plain terms: a cron is Nova's general-purpose **cause resources don't
otherwise have a home for** — anything that should happen on a clock or in
response to prior state, without a player-facing mission offer, dialog, or
button press to hang it on. Concretely, scenario authors used this for:

- **Story beats that must land on a specific date** regardless of what the
  player is doing (`FirstYear`/`FirstMonth`/`FirstYear` pinned to one value,
  `Random` = 100) — e.g. an invasion that starts on turn N of the campaign
  clock, gated by an `EnableOn` test on the story's control bits so it only
  fires for pilots who reached that point in the plot.
- **Recurring ambient events** with no fixed date — a wide date range plus a
  `Random` percent-per-day roll (e.g. a government's supply convoy running
  periodically, a smuggling crackdown that flares up now and then).
- **Player-triggered delayed consequences** — a cron whose `EnableOn` tests a
  bit the player's own actions set (e.g. via a mission's `OnSuccess`), so the
  *cron itself* fires "some fixed or random interval" later, decoupled from the
  mission's own `DatePostIncrement`.
- **Background news**, which is the one concrete, fully-specified mechanism
  the Bible gives for what a cron's *effect* looks like to the player even
  though the cron's own activation is "invisible": while a cron is active, it
  can drive up to **four independent per-government "local news" feeds** plus
  one catch-all "independent news" feed (see §2, `NewsGovt`/`GovtNewsStr` and
  `IndNewsStr`). This is how Nova makes the galaxy feel like it's reacting to
  the story without any dialog box or mission text — the news screen at a
  station is effectively cron output.
- Note 4 (line ~710) documents a specific authored trick this enables: *"You
  can use this to make everyone in the universe except a particular government
  or set of governments report on something"* — i.e. crons are the mechanism
  behind faction-specific spin on the same galaxy-wide event (one side's news
  outlet reports a battle as a victory, everyone else's is silent or reports
  something else via the independent-news fallback).

## 2. Field-level trigger semantics

Reference (not restated in full — see [MISSIONS.md](../MISSIONS.md) for
verified byte offsets): `firstDay/Month/Year`, `lastDay/Month/Year`, `random`,
`duration`, `preHoldoff`, `postHoldoff`, `independentNewsStrID`, `flags`,
`enableOn`/`onStart`/`onEnd`.

### Date-window wildcarding

> "Setting any of the above date fields to **0 or -1** effectively makes that
> field a wildcard field, which will match to anything." (note 1, line 698)

Each of `FirstDay`/`FirstMonth`/`FirstYear` and `LastDay`/`LastMonth`/`LastYear`
is independently wildcardable. Per-field prose (lines 615–637): e.g. "If you
set [FirstDay] to 0 or -1, this field will be ignored and only FirstMonth and
FirstYear will be considered" — so wildcarding is field-granular, not
all-or-nothing: you can pin the year but leave month/day open, or vice versa.

### The activation roll and the start/hold/end lifecycle

| Field | Behavioral contract (Bible, paraphrased where noted) |
|---|---|
| `Random` | "The percent chance that the cron event will be activated **during the date range** defined above. Set to 100 for the event to be activated as soon as it can be." — i.e. this is a *per-eligible-day* roll while the cron sits inside its date window, not a one-time roll at window entry. |
| `Duration` | "The duration during which the event is active, in days. If this is set to zero, the event will start and end **on the same day**, i.e. its OnStart and OnEnd scripts will be run at the same time." |
| `PreHoldoff` | "The number of days to 'hold' the event in a waiting state **after it is activated and before it starts**." So there are two distinct moments: *activated* (the random roll succeeded) and *started* (OnStart actually runs) — `PreHoldoff` is the gap between them. Set to 0 to start immediately on activation. |
| `PostHoldoff` | "The number of days to hold the event in a waiting state after it **ends** and before it is **deactivated**. This is used to keep a repeating event from being activated immediately after it has just happened." I.e. this is the anti-thrash cooldown for a repeatable cron — without it, a wide-date-range/high-`Random` cron could re-fire the very next day. |
| `EnableOn` | A **TEST** string (same grammar as `mïsn.AvailBits`) — must evaluate true for the cron to be eligible to activate. "Leave this blank if you are creating an event whose activation doesn't depend on the state of any control bits" (blank ⇒ always true, per the general NCB rule at line 141). |
| `OnStart` | A **SET** string, run once the `PreHoldoff` wait elapses. |
| `OnEnd` | A **SET** string, run when `Duration` elapses (or immediately, if `Duration` is 0). |

**Repeatability** is not a single flag — it falls out of the combination of a
wide date range, a nonzero `Random`, and whatever `OnStart`/`OnEnd` themselves
do to control bits. The Bible is explicit that authors must engineer
"never again" by hand (note 2, line 700, paraphrased): *if you want an event
with a wide possible date range to be guaranteed to never run more than once,
make its `OnEnd` script set a control bit that its own `EnableOn` then tests
against* (i.e. the cron has no built-in "fire once" bit — that's just an
`EnableOn`/`OnEnd` pair referencing the same bit, exactly like a mission
gating itself off after completion).

**Flags** add a second repeat mode on top of that — continuous re-evaluation
*within* a single activation, not across activations:

> `0x0001` "Continuous, iterative cron entry - keep evaluating the cron's
> **OnStart** field until the `EnableOn` expression is no longer true or the
> constraints of the `Require` fields are no longer met. This can create
> infinite loops, so be careful!"
>
> `0x0002` "Continuous, iterative cron exit - keep evaluating the cron's
> **OnEnd** field until the `EnableOn` expression is no longer true or the
> constraints of the `Require` fields are no longer met."

Read literally, these flags turn `OnStart`/`OnEnd` from "run once" into "run
every day the event is active/ending, until something in the SET string itself
flips `EnableOn` false" — the Bible's own warning that this "can create
infinite loops" implies these fields are evaluated **synchronously and
repeatedly within a single day's tick**, not just once per day, when the flag
is set. This is a materially different execution model from the plain case
and is not implemented at all (see §5).

### `Contribute` / `Require` — cross-resource gating

> "When the cron event is active, these two `Contribute` fields together form
> a 64-bit flag that is subsequently combined with the `Contribute` fields
> from the player's ship and the other outfit items in the player's
> possession, to be used with the `Require` fields in the `outf` and `misn`
> resources."
>
> "These two `Require` fields together form a 64-bit flag that is logically
> and'ed with the `Contribute` fields from the player's current ship and
> outfit items. Unless for each 1 bit in the `Require` fields there is a
> matching 1 bit in one or more of the `Contribute` fields, the cron will not
> be activated."

So a cron is both a **consumer** and a **producer** in this 64-bit-flag
system: its own `Require` fields can gate its activation on the player's ship
class / owned outfits (a completely separate axis from `EnableOn`'s
control-bit test — this is capability-gating, not story-state-gating), and
while it's active its `Contribute` bits flow into the same pool that gates
whether outfits (`oütf.Require`) or missions (`mïsn.Require`) are available.
Concretely, this is how a scenario could make "an outfit is only purchasable
while a particular background event is in progress" without spending a
control bit on it at all.

### `NewsGovt1-4` / `GovtNewsStr1-4` / `IndNewsStr` — the background-news mechanism

> "On planets or stations that are allied with the government whose ID is
> given by one of the `NewsGovt` fields, a string will be randomly selected
> from the `STR#` resource whose ID is given by the corresponding
> `GovtNewsStr` field, and will be displayed as news while the cron event is
> active. This allows you to let up to four different governments (and their
> allies) have their own 'local news' for a given cron event."
>
> "`IndNewsStr`: The ID of a `STR#` resource from which to randomly select a
> string to be displayed in the news dialog while this cron event is in
> progress, **if it doesn't have any applicable local news**."
>
> "Local news always takes precedence over independent news, even if there is
> no corresponding news string to display (the `STR#` ID must still be
> greater than zero to not be ignored)."

This is the payload most players actually perceive from a cron: the news
dialog at a spaceport reads differently depending on which government's
space you're in, for as long as the cron is active, then reverts. Up to 4
governments (plus everyone they're allied with) get bespoke local spin; every
other government's territory falls back to the one shared `IndNewsStr` pool
(or silence, if `IndNewsStr` is -1).

## 3. Interaction with the galaxy clock / date system

Crons are evaluated against Nova's day/month/year galaxy clock, the same
clock missions use for deadlines (`mïsn.TimeLimit`) and `DatePostIncrement`.
The Bible's date-window semantics (§2 above) imply a **daily-tick evaluation
model**: `Random` is described as a chance "during the date range," which only
makes sense if the game re-checks/re-rolls once per elapsed day while the
cron sits inside its window and isn't already active — a single one-shot roll
at first eligibility wouldn't need a percent-*per-day* framing at all. The
Bible doesn't give an exact-tick-vs-real-time distinction because EV Nova has
no finer time unit than a day for story purposes — hyperspace travel and
landing both advance the clock in whole-day increments, so "daily tick" and
"exact-date trigger" are the same mechanism at different `Random` values (100
= exact-date/as-soon-as-eligible; <100 = probabilistic daily creep across the
window).

`StoryEngine.advanceDays(_:)` (`Sources/EVNovaStory/StoryEngine.swift:387-395`)
matches this model exactly: it loops one day at a time (`for _ in 0..<n`),
advancing `player.date`, then calling `evaluateCrons()` once per simulated
day — so nothing is skipped over even if the caller advances the clock by
several days in one call (e.g. a hyperspace jump with travel time, or a
mission's `DatePostIncrement`). `evaluateCrons()`
(`StoryEngine.swift:416-449`) implements, per cron per day: end-if-elapsed →
skip-if-already-active → holdoff gate (`rt.earliestStart`) → date-window gate
(`dateInWindow`, `StoryEngine.swift:451-466`) → `EnableOn` test → `Random`
roll → `OnStart`. This is a faithful one-to-one mapping of the Bible's
activate→(PreHoldoff)→start→(Duration)→end→(PostHoldoff)→reactivate state
machine, persisted per-cron in `player.cronRuntime: [Int: CronRuntime]`
(`PlayerState.swift:32-46`, fields `startedDate`/`endDate`/`earliestStart`).

## 4. Relation to `öops` ("disaster") events

`öops` (Bible, lines 1795–1816) is a narrower, single-purpose sibling of
`crön` — a timed event whose *only* effect is an economic price shift, not a
general control-bit script:

> "Oops resources contain info on planetary disasters. Actually, the term
> 'disasters' is a misnomer, as these occurrences simply affect the price of a
> single commodity at a planet or station, for good or bad. Nova uses the
> name of the resource in the commodity exchange dialog box to indicate that a
> disaster is currently going on at a planet."

Its fields (`Stellar`, `Commodity`, `PriceDelta`, `Duration`, `Freq` = percent
chance per day, `ActivateOn` = an NCB test string) are a strict subset of a
cron's vocabulary — no `OnStart`/`OnEnd` script, no news, no
`Contribute`/`Require`, no per-government branching; it exists purely to jitter
one commodity's price at one stellar (or "any planet or station," `Stellar =
-1`) for `Duration` days at `Freq`% per eligible day, gated by one TEST
expression. Where a cron can do anything a control-bit SET expression can do,
an `öops` can only ever move a price. Full economic-model detail (trade
pricing, commodity list, how `öops` composes with base supply/demand) belongs
in the economy doc, not here — see
[ECONOMY.md](ECONOMY.md) once it exists; this doc only notes the boundary
between the two timed-event resources so cron work doesn't accidentally
reinvent disaster pricing.

No `öops` decoder exists anywhere in `EVNovaKit` today (confirmed by search —
no `OopsRes` type, no references to the `öops` four-char code); it is wholly
unimplemented, tracked separately from the cron work in this doc.

## 5. What's implemented vs. what's missing

`StoryEngine.swift` implements the core cron state machine faithfully for the
common case, but several Bible-documented fields/behaviors are either
unparsed, parsed-but-unused, or diverge subtly from spec. Verified against the
real game data (`evnova-extract raw "data/EV Nova" "crön" <id>`, swept across
all 125 real crons, IDs matching MISSIONS.md's count):

| Bible behavior | Status | Evidence |
|---|---|---|
| Date-window activation, `PreHoldoff`/`PostHoldoff`, `Duration` (incl. same-day start/end at 0), `EnableOn` test, `Random` per-day roll, `OnStart`/`OnEnd` | ✅ Implemented | `StoryEngine.evaluateCrons` / `dateInWindow`, `StoryEngine.swift:416-466` |
| `0` **and** `-1` both wildcard a date field | ⚠️ Partial | `dateInWindow` (`StoryEngine.swift:453,459`) only special-cases `c.firstYear != 0` / `c.lastYear != 0`, and `firstDay/lastDay/firstMonth/lastMonth == 0` for their own defaults — a field set to `-1` is taken as a literal date component instead of a wildcard. Empirically **inert against the base game**: a sweep of all 125 real crons' header fields found zero uses of `-1` (only `0` is used as the wildcard sentinel in practice) — but a plugin author following the Bible's documented "0 or -1" convention literally (e.g. `LastYear = -1` for "never expires") would have that cron permanently fail its window check once the campaign clock passes year ~-1's Julian Day equivalent, i.e. from the very first day — the opposite of the intended "no upper bound." |
| Flags `0x0001`/`0x0002` (continuous iterative OnStart/OnEnd re-evaluation while `EnableOn`/`Require` hold) | ❌ Not implemented | `CronRes.flags`/`loopStartUntilFalse`/`loopEndUntilFalse` are decoded (`MissionModels.swift:276,282-283`) but never read in `StoryEngine` — `evaluateCrons` always treats `OnStart`/`OnEnd` as a one-shot call regardless of these bits. |
| `Contribute`/`Require` cross-resource gating (cron feeds `oütf.Require`/`mïsn.Require` while active; cron's own `Require` can gate its activation on ship/outfit `Contribute`) | ❌ Not implemented at all, and not even fully decoded | `CronRes` has no `contribute`/`require` fields; `MissionRes.Require` (@1622, per `MissionModels.swift:239-247` comment) is explicitly skipped ("`// 1622: Require (8 bytes)`" — read past but never assigned to a field). The producer side (`shïp.contribute` @ `NovaModels.swift:232,276`; `oütf.contribute`/`require` @ `NovaAIModels.swift:146-147,177`) *is* decoded, but nothing in the engine (`StoryEngine.isEligible`, or anywhere else searched) ever reads those 64-bit fields to gate anything — the whole mechanism is inert on both ends. |
| `NewsGovt1-4`/`GovtNewsStr1-4` (per-government local news) | ❌ Not decoded, and real data uses it | `CronRes` (`MissionModels.swift:264-305`) only reads bytes `0`–`788` (24-byte head + 3×255-byte NCB strings). **Verified against real data: every real `crön` resource is 822 bytes, not 789** — a fixed 33-byte tail is silently dropped by the decoder. That tail is not always zero: cron #128 ("Wraith Change") has nonzero 16-bit values at absolute offsets 806 (=130) and 814 (=15000) — a plausible govt-ID/`STR#`-ID pair, i.e. real, in-use `NewsGovt`/`GovtNewsStr` data — while cron #129 ("Terraforming Start") has an all-zero tail. Exact per-field byte offsets within that 33-byte tail are **not yet verified** (open follow-up; the Bible's prose order there is `Contribute(8)+Require(8)+NewsGovt1-4(8)+GovtNewsStr1-4(8)` = 32 bytes, one short of the observed 33 — likely a 1-byte pad, but this needs a dedicated offset pass like the rest of `MissionModels.swift`, not a guess). |
| `IndNewsStr` (independent/fallback news) | ⚠️ Decoded, never consumed | `CronRes.independentNewsStrID` (@20, `MissionModels.swift:275,299`) is parsed correctly, but nothing calls `game.stringList`/`descText` on it anywhere in `StoryEngine`. `StoryNotification` (`GameServices.swift:78-79`) only has `.cronStarted`/`.cronEnded` (a bare cron ID) — there is no notification or `GameServices` method carrying news text at all. Even fully fixing the `NewsGovt` decoding gap above would have nowhere to plug in yet: this needs a new `GameServices` method (e.g. `showNews(_:govt:)`) and a caller in `evaluateCrons()` that resolves local-vs-independent news per the precedence rule in note 4. |
| Player ever seeing any cron effect | ❌ Not wired | Per MISSIONS.md's "BUILT, NOT WIRED" status: no app type conforms to `GameServices`, and the app never instantiates a live `StoryEngine`/calls `advanceOneDay()` during play. So even the cron behavior that *is* correctly implemented — bit flips via `OnStart`/`OnEnd`, mission-availability changes those bits cause, salary/deadline processing on the same daily tick — only happens inside `EVNovaStoryTests` (e.g. `testCronStartsAndEnds`, `testCronBlockedByEnableTest`, `Tests/EVNovaStoryTests/StoryEngineTests.swift:149-172`) and the `evnova-extract story` CLI replay. A player running the live game today experiences **no background events whatsoever** — no news changes, no ambient bit flips, no scenario-timed unlocks — regardless of how faithful the underlying engine is, because nothing calls it. |

### Open questions not resolvable from the Bible text alone

- The exact byte layout of the 33-byte tail past the currently-decoded 789
  bytes (which sub-fields are `Contribute` vs `Require` vs `NewsGovt`/
  `GovtNewsStr`, and where the apparent 1-byte pad sits) — needs the same
  empirical offset-verification pass MISSIONS.md already did for the rest of
  `crön`, ideally cross-checked against ResForge's `Templates.rsrc` TMPL for
  `crön` (not attempted here; out of scope for a prose behavior doc).
  Command used to observe the raw tail: `evnova-extract raw "data/EV Nova"
  "crön" <id>` (built from this repo's `Sources/evnova-extract`).
- Whether flags `0x0001`/`0x0002`'s "keep evaluating... until no longer true"
  really means *within one day's tick* (synchronous loop, per the Bible's own
  "can create infinite loops" warning) or *once per subsequent day* (an
  implicit repeat-without-holdoff) — the Bible text doesn't disambiguate
  timing precisely enough to be certain which the original engine did; the
  "infinite loop" warning reads more consistently with same-tick looping, but
  this is inference, not a direct quote.
