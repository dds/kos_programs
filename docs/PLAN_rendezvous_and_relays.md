# Plan: Orbital Rendezvous Campaign + Minmus Relay Constellation

Handoff document. An implementer AI executes §A and §B; the reviewer (and the
implementer) follow §C to validate. Conventions and constraints are in
`CLAUDE.md` — read it first. Nothing here is flight-proven yet; the whole
PRELAUNCH/MATCH/CREW_XFER chain and the relay deploy are marked unproven in
`CLAUDE.md`.

## 0. State of the code (exists vs. missing)

**Rendezvous pipeline — built, NOT flight-proven:**
- `lib/prelaunch.ks` `phasePrelaunch` — launch window from the target vessel's
  plane + along-track lead, hands to LAUNCH at the window.
- `lib/maneuver_rendezvous.ks` `planRendezvous` — Hohmann + golden-section
  refine on burn time and Δv to minimize closest approach.
- `phaseMatch` — brake at CA, then direct-thrust close-in to `MATCH_FINAL_DIST`
  (150 m, EVA range).
- `phaseCrewXfer` — holds until crew count rises; reboot-safe via
  `crew_xfer_start` state.
- Falcon profiles: `falcon_lko_target` (park empty pod), `launch_to_rendezvous`
  (PRELAUNCH→…→RDV→MATCH→DONE), `rendezvous_around_parent`.

**Minmus relays — built, NOT flight-proven:**
- `lib/relay_constellation.ks` `constellationDeploy` — resonant deploy: release
  a relay, drop carrier to a `(n-1)/n`-period phasing orbit, coast one orbit,
  re-circularize, repeat. Orbital mechanics are sound.
- `missions/FR3C/minmus_relay_tripack.cfg` — full sequence to 500 km
  equatorial, 3 relays.

**Gaps this plan closes:**
1. Vessel name collision — parked pod and Jeb's ship both default to "Falcon";
   `VESSEL("Falcon")` / MATCH target lookup are ambiguous with two same-named
   vessels.
2. No Falcon rescue profile for the Ellory leg (only `rescue_lko.cfg` on
   FR3/FR3b exists).
3. Relay deploy never activates antennas/solar (critical) and isn't resumable
   mid-deploy (violates hard-constraint #3).

Pre-staged in this handoff (already committed):
- `missions/Falcon/launch_to_rendezvous.cfg` → `RENDEZVOUS_TARGET = Grumpy Bear`.
- `missions/Falcon/rescue_ellory.cfg` — descent tags wired for the real
  three-stage craft (`descent_decoupler` / `descent_chutes`, decouple at 45 km).

## Resolved craft facts (operator-confirmed)
- **Naming:** every launch vehicle flies as "Falcon" and is renamed once it
  reaches parking orbit. Campaign ships: parked target → **"Grumpy Bear"**,
  Jeb's rescuer → **"Tenderheart Bear"**. (They meet in orbit and reenter
  together — story names.)
- **Three-stage Falcon:**
  - *Booster:* drogue + radial chutes, auto-triggered when staging to the
    intermediate stage (handled by KSP staging, not kOS).
  - *Intermediate:* nudges to orbit and does the rest of the work; carries an
    MJ2 core, battery, reaction wheels, maybe fuel, and two chutes. Stays mated
    to the pod through deorbit/braking, separates just before reentry, then
    descends on its own armed chutes.
  - *Pod:* heat shield + chute.
  - Tags: both the intermediate-stage chutes and the pod chute are
    `descent_chutes` (armed together before decouple); pod decoupler is
    `descent_decoupler`. (`_descentArmChutes` arms all `descent_chutes` parts at
    descent.ks:151, before the decouple at :164 — so both vessels get armed
    chutes.)
- **Relays are deployable** — there is a deployable antenna, and the relays
  carry deployable antennas. So **B1 is a required code change** (extend before
  decouple), not just a VAB confirm.
- **New requirement:** on the descent-to-Kerbin phase, reopen `extend_bay` at
  the same time antennas are re-extended → see §D.

---

## A. Kerbin orbital-rendezvous campaign

Four sequential flights, run in order by the operator.

### A1 — Park the empty target pod (`falcon_lko_target`, exists)
- Launch a Falcon, pick `falcon_lko_target` → `LAUNCH,ANTS,PARK,DONE`
  (74 km / 28°).
- **Rename the parked vessel to `Grumpy Bear`** in-game once parked, so it is
  not ambiguous with the rescuer (both launch as "Falcon").
- Done when: stable ~74 km orbit; vessel renamed `Grumpy Bear`.

### A2 — Jeb rendezvous with the empty pod (`launch_to_rendezvous`, edited)
- `RENDEZVOUS_TARGET = Grumpy Bear` (done). Rename Jeb's ship to
  `Tenderheart Bear` once parked.
- Sequence: `PRELAUNCH,LAUNCH,ANTS,PARK,RDV,MATCH,DONE`. Jeb launches into the
  target plane, catches up, closes to 150 m.
- Done when: `STATS match result sep<150 relV<~1 target=Grumpy Bear`.

### A3 — Deorbit both at KSC
Two independent vessels, each with its own kOS core. Recover one at a time (do
NOT burn both simultaneously). Pass the Falcon descent tags so landat wires the
pod decoupler + chutes (the parked ships' `falcon_lko_target` profile has no
descent keys, so defaults must be supplied here):
1. On `Grumpy Bear`:
   `RUNPATH("0:/cmd/landatksc.ks", LEX("descent_decoupler","descent_decoupler","descent_chutes","descent_chutes")).`
2. Then on `Tenderheart Bear`: same call.

`landat.ks` forwards `descent_decoupler` / `descent_chutes` into
`mission_cfg_DESCENT_*`. Reuses the flight-proven landatksc / KSC_DEORBIT
recipe.
- Done when: both splash within tolerance of KSC (lat −0.10, lng −74.25); crew
  recovered.

### A4 — Rescue Ellory from "Ellory's Wreckage" (`rescue_ellory.cfg`, new)
- Profile mirrors `missions/FR3b/rescue_lko.cfg`, Falcon-flavored:
  - `SEQUENCE = PRELAUNCH,LAUNCH,ANTS,PARK,RDV,MATCH,CREW_XFER,KSC_DEORBIT,DESCENT,DONE`
  - `PAYLOADS = CREW` (Falcon Mk1 launches EMPTY → one free seat for Ellory)
  - `LIBS_EXTRA = launch@PARK, descent`
  - `RENDEZVOUS_TARGET` left commented — the wreck name has an apostrophe/space;
    **target "Ellory's Wreckage" in map view before launch** (PRELAUNCH grabs
    and persists the game target).
  - Landing keys block copied from `rescue_lko.cfg`.
  - Descent (three-stage Falcon): `DESCENT_DECOUPLER_TAG = descent_decoupler`,
    `DESCENT_DECOUPLE_ALT = 45000` (separate just before reentry),
    `DESCENT_CHUTES_TAG = descent_chutes` (done).
- Flow: launch empty → rendezvous with wreck → CREW_XFER waits while operator
  EVAs Ellory into the Falcon → auto deorbit + descent to KSC.
- Done when: `STATS crew_xfer result count=2 roster=…Ellory…`, then KSC
  splashdown with Ellory recovered.

**Cross-cutting (A2/A4):** RDV/MATCH use `VESSEL(name)` / name-equality target
lookup. Distinct vessel names are mandatory — if the A1 rename is skipped,
RDV/MATCH may lock onto the wrong (own) vessel.

---

## B. Minmus relay constellation (`FR3C/minmus_relay_tripack`)

Mechanics are right; two must-fix issues plus several checks before flying.
Flies on **FR3C** (already Minmus-capable), not Falcon.

### B1 — MUST FIX: relays released but never activated (critical) — CODE REQUIRED
Confirmed: the relays carry **deployable** antennas (and a deployable antenna
exists on the craft), so this is a required code change, not a VAB confirm.
`_deployOneRelay` (relay_constellation.ks:62) only decouples. After decouple the
carrier can no longer command the relay, so a stowed antenna/panel → dead relay.
- Fix: **before** the decouple call in `_deployOneRelay`, walk that relay's
  parts (the decoupler `dc` and its children, or parts tagged
  `relay_<idx>_ant` / `relay_<idx>_sol`) and extend deployables. Mirror the
  proven pattern in `descent.ks`: `ModuleDeployableAntenna` →
  `DOEVENT("extend antenna")` (see `_descentExtendAntennas`, descent.ks:510);
  `ModuleDeployableSolarPanel` → its extend event (see solar.ks:16). Be
  tolerant — count + log, skip if none found, then `WAIT` briefly so the
  animation starts before decouple.
- Then decouple as today, and record the activation in the relay's release log.

### B2 — MUST FIX: deploy not resumable mid-constellation (hard-constraint #3)
`constellationDeploy` always restarts at `idx=1`. After a reboot following
relay 1's release it tries to decouple `relay_1` again — part is gone →
`_deployOneRelay` returns FALSE → holds. Cannot resume.
- Fix: persist a deployed counter (`stateSet("relay_deployed_count", k)`); on
  entry skip already-released slots (it already records `relay_<idx>_released` —
  read it). Resume from the first not-yet-released relay; detect whether the
  carrier is mid-phasing-orbit so it doesn't double-burn.

### B3 — CHECK: SHAPE must leave a near-circular orbit before deploy
`_burnToPhasingOrbit` assumes radius ≈ `targetR` everywhere (valid only if
circular). Add a guard at the top of `constellationDeploy`: if eccentricity >
~0.01, re-circularize first.

### B4 — CONFIRM craft design (VAB; not checkable from code)
- Three decouplers tagged `relay_1/2/3` (carrier = debris after), or two
  decouplers with the carrier itself as relay #3? Cfg says three and
  `RELAY_COUNT=3`. Confirm the FR3C build matches; else fix count/tags.
- Decide carrier disposal: debris is fine for now (note it); if the carrier is
  a relay, set `RELAY_COUNT=2` + tags.

### B5 — ACCEPT (note, don't fix): spacing tolerance
~60 s gap between release and the phasing burn, plus release-TA ≠ burn-point,
yields a few degrees of spacing error. Fine for relay coverage.

### B6 — minor: STATS pair
Add a `STATS constellation setup …` / `… result …` pair at phase entry/exit per
house convention.

---

## D. Falcon descent: reopen `extend_bay` when antennas re-extend — CODE REQUIRED
Requirement: in the descent-to-Kerbin phase, reopen `extend_bay` at the same
time antennas are re-extended (the bay houses the deployable antenna; it is
closed for entry at descent.ks:148 by `_descentCloseExtendBays`).
- Fix in `lib/descent.ks`: add `_descentReopenExtendBays()` — the inverse of
  `_descentCloseExtendBays` (descent.ks:433). For each `SHIP:PARTSTAGGED("extend_bay")`
  with `ModuleAnimateGeneric`, fire the open event: `Open` / `Open Doors` /
  `Extend` (mirror `_openExtendBays` in launch.ks:284). Tolerant + logged.
- Call it **immediately before** `_descentExtendAntennas()` at descent.ks:185,
  so the bay is open before the antenna deploys out of it. Add a short `WAIT`
  for the door animation.
- Note for the implementer: line 185 runs **after** the pod decouples
  (descent.ks:164), so `SHIP:PARTS` here is the pod only. Confirm the
  `extend_bay` part (and the deployable antenna it holds) is on the **pod** side
  of `descent_decoupler` — otherwise the reopen is a harmless no-op and the
  antenna won't be present to extend.

---

## C. Shared verification protocol (implementer AND reviewer follow this)

### C1 — Static checks (before any flight; every edited file)
1. Brace balance: strip `//` comments and strings, count `{` vs `}` over each
   edited `.ks`. Must balance.
2. Statement terminators: every new/edited statement ends in `.`.
3. Reserved names: no bare `r`/`v`/`q`; no shadowing `up`/`north`/`body`/
   `target`/`alt`/`eta`.
4. After editing `lib/dependencies.txt`: run `make dependencies`; confirm
   `lib/dependencies.ks` regenerated and committed.
5. Phase wiring: every `SEQUENCE` phase exists in the `dependencies.ks` phase
   list AND belongs to a band; every new cfg key is read by some lib (grep it).
6. New cfg sanity: `rescue_ellory.cfg` keys match keys consumed by
   prelaunch / maneuver_rendezvous / descent libs.
7. No archive-dependence in offline flight paths (descent libs preloaded via
   `LIBS_EXTRA`, hard-constraint #2).

### C2 — Flight acceptance criteria (watch the STATS lines)
| Mission | Pass condition |
|---|---|
| A1 park | stable ~74 km orbit; target renamed `Falcon-Target` |
| A2 rendezvous | `STATS match result sep<150 relV<~1 target=Grumpy Bear` |
| A3 deorbit ×2 | both splash within tolerance of KSC; intermediate stage lands on its own armed chutes; crew recovered |
| A4 rescue | `STATS crew_xfer result count=2 roster=…Ellory…`; KSC splashdown |
| D extend_bay | on descent, bay reopens and the deployable antenna extends; comms/link restored before landing |
| B relays | each relay released (`relay_N_released` in state); after release each relay's antenna confirmed **deployed** and link live; `STATS relay-phase result` Pe>floor; 3 relays ≈120° apart at 500 km |

### C3 — Reviewer checklist after implementer finishes
- Diff vs. this plan: A2 cfg points at renamed target; `rescue_ellory.cfg`
  mirrors `rescue_lko.cfg` with Falcon-correct decoupler/landing keys.
- B1 fix present and tolerant of missing tags; B2 resume logic skips released
  slots and is reboot-safe; B3 circular guard present.
- Re-run C1 independently.
- Confirm `make dependencies` ran if `dependencies.txt` changed; work committed
  AND pushed (archive sync needs the push).

---

## Open questions — RESOLVED
1. Naming → all LVs are "Falcon", renamed on parking orbit; target =
   `Grumpy Bear`, Jeb = `Tenderheart Bear`.
2. Descent staging → three-stage; pod decouples from the intermediate stage just
   before reentry (`descent_decoupler` @ 45 km), chutes `descent_chutes`.
3. Relays → deployable antennas → B1 is a code change.

## Remaining VAB confirm for the implementer (not blocking)
- FR3C relay carrier: three decouplers tagged `relay_1/2/3` (matching
  `RELAY_COUNT=3`), or two with the carrier as relay #3? Confirm and reconcile
  count/tags + carrier disposal (B4).
- `extend_bay` and its deployable antenna sit on the **pod** side of
  `descent_decoupler` (§D note).
