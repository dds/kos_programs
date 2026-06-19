# Plan: FalconHeavy Duna Aerocapture + Ike Flyby

## Mission Intent

Fly the FalconHeavy Duna SCISat lander to Duna, use Duna's upper atmosphere
plus a small retroburn to get barely captured, reshape into a safe Duna orbit,
set up a cheap Ike flyby from that orbit, collect Ike science, then return to
Duna atmospheric entry and land the probe.

The key design choice is to keep the mission as a chain of small, reboot-safe
legs. Each leg rewrites the active `SEQUENCE` and target state before handing
back to the existing phase machine. This avoids duplicate phase names in one
long list and keeps each boot in the smallest useful library band.

## Existing Tools We Should Reuse

- `XING` plans the departure burn for one SOI transition.
- `BPLANE` and `REFINE_BPLANE` target arrival periapsis and plane.
- `COAST_1HALF` and `COAST_2HALF` provide guarded long-coast behavior.
- `FLYBY` waits through periapsis and can remain inside the flyby body's SOI.
- `SCIENCE_OPS` and `SCIENCE_OPS_LOW` can be used as two distinct phase names
  for pre- and post-periapsis science runs.
- `SHAPE` can clean up a captured Duna orbit using `SHAPE_PE/AP/INC/LAN/AOP`.
- `planCapture`, `planRaisePeNow`, and `planLowerPe` already provide the small
  maneuver primitives needed by the new setup phases.
- `AEROBRAKE` and `DESCENT` already prepare and fly the final Duna atmospheric
  entry, though `AEROBRAKE` should get a targeting guard before we rely on it
  for non-Kerbin entries.

## New Thin Library

Add one mission orchestration library, tentatively:

```text
lib/duna_ike_setup.ks
```

It should own four phase handlers:

- `DUNA_AEROCAPTURE`
- `IKE_SETUP`
- `DUNA_ENTRY_SETUP`
- `DUNA_ENTRY_LOWER_PE`

Wire those phases in `lib/dependencies.ks`. The dependency roots should stay
small:

- `DUNA_AEROCAPTURE`: `maneuver`, `orbit`, `solar`
- `IKE_SETUP`: no heavy math, but needs state/config helpers from core
- `DUNA_ENTRY_SETUP`: `orbit`, `solar`
- `DUNA_ENTRY_LOWER_PE`: `maneuver`, `orbit`

This is deliberately not a new universal grand-tour planner. It is the minimum
mission-specific glue required to compose the libraries already in flight.

## Top-Level Profile

The initial FalconHeavy profile should target Duna, but no longer target a
direct 18 km landing entry. Instead it targets an upper-atmosphere aerocapture
corridor:

```ks
SET MISSION_ID TO "duna_ike_scisat_lander".
SET MISSION_NAME TO "FalconHeavy Duna/Ike SCISat Lander".
SET TARGET_ TO "DUNA".
SET PAYLOADS TO LIST("SCISAT").

SET SEQUENCE TO LIST(
    "PRELAUNCH", "LAUNCH", "FAIR", "ANTS", "PARK",
    "XING", "BPLANE", "COAST_1HALF", "REFINE_BPLANE", "COAST_2HALF",
    "DUNA_AEROCAPTURE", "SHAPE", "IKE_SETUP"
).
```

Suggested first-pass Duna arrival config:

```ks
SET CAPTURE_PE TO 20000.          // deep Duna aerocapture corridor
SET CAPTURE_INC TO 0.
SET CAPTURE_DIR TO "PROGRADE".

SET DUNA_AEROCAPTURE_PE TO 20000.
SET DUNA_AEROCAPTURE_TARGET_AP TO 5000000.
SET DUNA_SAFE_PE TO 85000.

SET SHAPE_PE TO 85000.
SET SHAPE_AP TO 2880000.          // near Ike's orbital altitude over Duna
SET SHAPE_INC TO 0.2.             // close to Ike/Duna equatorial plane
SET SHAPE_ALT_TOL TO 10000.
```

The nominal aerocapture Pe should be about 20 km. The current direct lander's
18 km Pe was already intended to survive Duna entry and commit to landing, and
this bus can tolerate Kerbin entry loads, so 20 km is a reasonable aggressive
starting point for useful Duna braking. Still, treat it as a sim-tuned corridor:
the same Pe that is "good braking" on one arrival can become "too much braking"
if the interplanetary approach is steeper or faster than expected.

## Duna Arrival and Aerocapture

### Before Duna SOI

The existing transfer leg remains unchanged except for the target Pe:

```text
XING -> BPLANE -> COAST_1HALF -> REFINE_BPLANE -> COAST_2HALF
```

`BPLANE` should target `CAPTURE_PE = DUNA_AEROCAPTURE_PE`, and the refinement
phase should hold if the arrival is not inside the configured Pe corridor.
This matters more than usual because a few kilometers of Duna Pe is the
difference between "free capture energy" and "probe becomes terrain data."

### `DUNA_AEROCAPTURE`

This is a new phase, not a reuse of current `AEROBRAKE`.

Current `AEROBRAKE` is an entry-prep phase that waits for atmosphere and then
hands to `DESCENT`. For this mission we need a phase that dips through the
atmosphere, survives the outbound leg, confirms capture, then raises periapsis
out of the atmosphere.

Proposed behavior:

1. Verify `SHIP:BODY:NAME = "Duna"`.
2. Verify `SHIP:PERIAPSIS` is in the configured aerocapture corridor.
3. Retract risky deployables using the same part-walking pattern as
   `aerobrake.ks`.
4. Point retrograde before atmospheric interface.
5. At or just before periapsis, run a small capture-assist retroburn only if
   needed and inside the configured dV cap.
6. Coast through atmosphere.
7. After exiting atmosphere, require `SHIP:STATUS = "ORBITING"`.
8. If Pe is still inside the atmosphere, raise Pe to `DUNA_SAFE_PE`.
9. Advance to `SHAPE`.

The retroburn should use existing maneuver math:

```ks
planCapture(BODY("Duna"), DUNA_AEROCAPTURE_TARGET_AP).
executeManeuver().
```

The important trick is choosing `DUNA_AEROCAPTURE_TARGET_AP` high enough that
the burn only barely captures. The 20 km atmosphere pass then does most of the
braking for free. First-pass target: several million meters, near or above Ike
altitude. If the planned burn is too large, the phase should skip/hold rather
than spend the lander's reserve blindly; a deep Duna pass may capture without
any burn at all.

Guardrails:

- Add `DUNA_AEROCAPTURE_MAX_RETRO_DV`, probably 75-150 m/s at first.
- Add `DUNA_AEROCAPTURE_MIN_PE` and `MAX_PE`, e.g. 17000-25000 m.
- If post-pass orbit is still escaping, hold for manual control. Do not try to
  salvage a hyperbolic post-aerobrake state with the generic Duna-entry code.
- If the pass is so deep that the ship never exits the atmosphere, treat it as
  an off-nominal direct-entry case and hand to `DESCENT` only by explicit
  recovery logic, not by pretending the Ike mission is still alive.
- If post-pass Pe is below atmosphere and the ship is orbiting, raise Pe at the
  first apoapsis with `planRaisePeNow(DUNA_SAFE_PE)`.

## Safe Duna Orbit

After aerocapture, `SHAPE` should produce a Duna orbit that is:

- safely above atmosphere at periapsis,
- not so low that Ike transfer requires a large raise,
- near Ike's plane,
- and preferably with apoapsis near Ike altitude.

The intended first orbit is not a circular parking orbit. A useful shape is:

```text
Pe: 85-100 km
Ap: around Ike altitude, or somewhat above it
Inc: near Ike's Duna orbit inclination
```

Why this shape:

- Low Pe keeps the aerocapture recovery burn cheap.
- High Ap makes the Ike encounter setup cheap.
- Matching Ike's plane early prevents an expensive plane change at Duna.

`SHAPE` is the right tool here because it can trim Pe, Ap, and plane after the
messy aerocapture pass. It should not try to target a precise LAN unless we
learn from sim logs that doing so helps the Ike transfer.

## `IKE_SETUP`

`IKE_SETUP` is a setup phase reached after the Duna orbit is safe. It rewrites
the active mission into an Ike flyby leg and reboots into the next band.

It should:

1. Archive the Duna-arrival log if there is a connection.
2. Set `target = "IKE"`.
3. Set `mission_type = "duna_ike_flyby"`.
4. Set `mission_cfg_SEQUENCE` for the Ike leg.
5. Set the Ike flyby periapsis and B-plane settings.
6. Copy any Ike-specific scan/tolerance keys into the generic transfer keys
   consumed by `XING`, `BPLANE`, and `REFINE_BPLANE`.
7. Clear stale Duna shaping and aerocapture keys.
8. Set `phase = "XING"` and clear cached band state.
9. Reboot.

Suggested Ike leg:

```ks
SET IKE_FLYBY_SEQUENCE TO LIST(
    "XING", "BPLANE", "COAST_1HALF", "REFINE_BPLANE", "COAST_2HALF",
    "SCIENCE_OPS", "FLYBY", "SCIENCE_OPS_LOW", "DUNA_ENTRY_SETUP"
).

SET IKE_FLYBY_PE TO 25000.
SET IKE_FLYBY_INC TO -1.           // Pe-only unless sim says plane helps
SET IKE_FLYBY_POST_PE_HOLD TO 600.
SET IKE_FLYBY_EXIT_SOI TO 0.
SET IKE_TRANSFER_SCAN_LOOKAHEAD_HOURS TO 24.
```

Concrete state handoff:

```ks
stateSet("target", "IKE").
stateSet("mission_type", "duna_ike_flyby").
stateSet("mission_id", "duna_ike_flyby").
stateSet("mission_name", "Duna/Ike Flyby").

stateSet("mission_cfg_SEQUENCE", IKE_FLYBY_SEQUENCE).
stateSet("mission_cfg_CAPTURE_PE", IKE_FLYBY_PE).
stateSet("mission_cfg_BPLANE_TARGET", "IKE").
stateSet("mission_cfg_FLYBY_POST_PE_HOLD", IKE_FLYBY_POST_PE_HOLD).
stateSet("mission_cfg_FLYBY_EXIT_SOI", IKE_FLYBY_EXIT_SOI).
stateSet("mission_cfg_TRANSFER_SCAN_LOOKAHEAD_HOURS",
    IKE_TRANSFER_SCAN_LOOKAHEAD_HOURS).
stateSet("mission_cfg_TRANSFER_SCAN_SAMPLES_PER_ORBIT", 32).
stateSet("mission_cfg_BPLANE_DV_CAP", 40).
stateSet("mission_cfg_REFINE_BPLANE_DV_CAP", 5).
stateSet("mission_cfg_REFINE_BPLANE_MAX_BURNS", 8).

stateSet("phase", "XING").
```

If `IKE_FLYBY_INC >= 0`, `IKE_SETUP` may also persist
`mission_cfg_CAPTURE_INC`; otherwise it should remove any stale
`mission_cfg_CAPTURE_INC`, `mission_cfg_CAPTURE_LAN`, `mission_cfg_CAPTURE_AOP`,
and `mission_cfg_CAPTURE_DIR` so the Ike flyby is Pe-targeted rather than
plane-constrained.

The important piece is `FLYBY_EXIT_SOI = 0`. We want `FLYBY` to wait through
Ike periapsis but not coast all the way back out to Duna before science can
run. Using both `SCIENCE_OPS` and `SCIENCE_OPS_LOW` gives us two science
passes without duplicate phase-name problems:

- `SCIENCE_OPS`: shortly after entering Ike SOI, before periapsis.
- `FLYBY`: wait through periapsis and hold briefly after.
- `SCIENCE_OPS_LOW`: after periapsis, still in Ike SOI if the hold is short.

If the actual flyby time in Ike SOI is too short, replace the two generic
science phases with a small `IKE_FLYBY_SCIENCE` phase that runs experiments
before and after Pe inside one handler.

`IKE_TRANSFER_SCAN_LOOKAHEAD_HOURS` is a setup-phase convenience key. `IKE_SETUP`
should persist it as the existing `TRANSFER_SCAN_LOOKAHEAD_HOURS` before the
Ike `XING` boot.

## Cheap Ike Encounter Refinement

The cheapness mostly comes from orbital setup before `IKE_SETUP`:

- Duna Ap near Ike altitude.
- Duna orbit near Ike's plane.
- Local `XING` starts from that high ellipse instead of low Duna orbit.

Then the existing precision pipeline does the rest:

1. `XING` scans local transfer opportunities and creates an Ike encounter.
2. `BPLANE` targets a safe Ike Pe.
3. `COAST_1HALF` waits to a guarded midpoint.
4. `REFINE_BPLANE` performs low-dV cleanup near arrival.
5. `COAST_2HALF` enters Ike SOI.
6. `FLYBY` waits through Pe without capture.

Config knobs likely worth widening for Duna-to-Ike:

```ks
SET TRANSFER_SCAN_LOOKAHEAD_HOURS TO 24.
SET TRANSFER_SCAN_SAMPLES_PER_ORBIT TO 32.
SET BPLANE_DV_CAP TO 40.
SET REFINE_BPLANE_DV_CAP TO 5.
SET REFINE_BPLANE_MAX_BURNS TO 8.
```

The target is not "capture into Ike orbit." It is a low-risk flyby Pe with a
post-flyby Duna trajectory we can still use. We should not spend large normal
or radial corrections trying to force a pretty Ike plane unless logs show the
flyby return geometry needs it.

## `DUNA_ENTRY_SETUP`

`DUNA_ENTRY_SETUP` runs after post-Ike science. It prepares the final Duna
entry sequence.

It should:

1. If still inside Ike SOI, wait until `SHIP:BODY:NAME = "Duna"`.
2. Archive the Ike flyby log if possible.
3. Inspect the Duna orbit.
4. If current Duna Pe is already inside the entry corridor, start final entry.
5. If current Duna Pe is too high and the ship is in a stable Duna orbit, run
   `DUNA_ENTRY_LOWER_PE` first.
6. If the post-Ike trajectory is escaping Duna, hold for manual attention.

Suggested final entry sequence:

```ks
SET DUNA_ENTRY_SEQUENCE TO LIST(
    "DUNA_ENTRY_LOWER_PE", "AEROBRAKE", "DESCENT", "DONE"
).

SET DUNA_ENTRY_PE TO 18000.
SET AEROBRAKE_REENTRY_DIR TO "RETROGRADE".
SET AEROBRAKE_ARM_CHUTES TO 1.
```

`DUNA_ENTRY_SETUP` can skip `DUNA_ENTRY_LOWER_PE` by setting phase directly to
`AEROBRAKE` when the current Pe is already good.

## `DUNA_ENTRY_LOWER_PE`

This is a very thin wrapper around existing maneuver code:

```ks
planLowerPe(DUNA_ENTRY_PE).
executeManeuver().
```

Use it only when:

- current body is Duna,
- ship is orbiting,
- current Pe is above Duna atmosphere,
- apoapsis burn occurs before any impact or atmosphere entry,
- and the node dV is below a configured cap.

Suggested cap: `DUNA_ENTRY_LOWER_PE_MAX_DV = 150`.

After the burn, advance to `AEROBRAKE`.

## Final `AEROBRAKE` and `DESCENT`

For the last Duna entry, the existing `AEROBRAKE -> DESCENT` path from
`missions/FalconHeavy/duna_scisat_lander.ks` is the right base:

```ks
SET AEROBRAKE_REENTRY_DIR TO "RETROGRADE".
SET AEROBRAKE_ARM_CHUTES TO 1.

SET DESCENT_CHUTES_TAG TO "descent_chutes".
SET DESCENT_RELEASE_ALT TO 12000.
SET DESCENT_DROGUE_CUT_ALT TO 3500.
SET DESCENT_FAIRING_TAG TO "descent_fairing".
SET DESCENT_FAIRING_DEPLOY_SPEED TO 60.
SET DESCENT_DECOUPLER_TAG TO "descent_decoupler".
SET DESCENT_DECOUPLE_ALT TO 8000.
SET DESCENT_HEAT_SHIELD_DROP_ALT TO -1.
SET DESCENT_BAY_REOPEN_ALT TO 6000.
SET DESCENT_ENGINE_ASSIST TO 1.
SET DESCENT_ENGINE_ASSIST_ALT TO 1200.
```

Before using it for this mission, make one small safety improvement:

```ks
SET AEROBRAKE_TARGETING TO 0.
```

Then update `lib/aerobrake.ks` so Trajectories impact targeting only runs when
`AEROBRAKE_TARGETING > 0`. The current targeting coordinates are KSC-flavored
and are useful for Kerbin returns, but they are not a Duna landing strategy.

## Config Sketch

One possible mission profile after the setup phases exist:

```ks
// KerboScript mission profile.
SET MISSION_ID TO "duna_ike_scisat_lander".
SET MISSION_NAME TO "FalconHeavy Duna/Ike SCISat Lander".
SET TARGET_ TO "DUNA".
SET PAYLOADS TO LIST("SCISAT").
SET SEQUENCE TO LIST(
    "PRELAUNCH", "LAUNCH", "FAIR", "ANTS", "PARK",
    "XING", "BPLANE", "COAST_1HALF", "REFINE_BPLANE", "COAST_2HALF",
    "DUNA_AEROCAPTURE", "SHAPE", "IKE_SETUP"
).

SET PARKING_ALT TO 85000.
SET LAUNCH_INCLINATION TO 0.
SET LAUNCH_PLANE_MODE TO "INTERPLANETARY".
SET TRANSFER_SCAN_SAMPLES_PER_ORBIT TO 16.
SET COAST_AUTO_WARP TO 1.
SET COAST_HIBERNATE TO 1.
SET KEEP_WARP TO 1.

SET CAPTURE_PE TO 20000.
SET CAPTURE_INC TO 0.
SET CAPTURE_DIR TO "PROGRADE".

SET DUNA_AEROCAPTURE_PE TO 20000.
SET DUNA_AEROCAPTURE_MIN_PE TO 17000.
SET DUNA_AEROCAPTURE_MAX_PE TO 25000.
SET DUNA_AEROCAPTURE_TARGET_AP TO 5000000.
SET DUNA_AEROCAPTURE_MAX_RETRO_DV TO 125.
SET DUNA_SAFE_PE TO 85000.

SET SHAPE_PE TO 85000.
SET SHAPE_AP TO 2880000.
SET SHAPE_INC TO 0.2.
SET SHAPE_ALT_TOL TO 10000.

SET IKE_FLYBY_PE TO 25000.
SET IKE_FLYBY_POST_PE_HOLD TO 600.
SET IKE_FLYBY_EXIT_SOI TO 0.
SET IKE_TRANSFER_SCAN_LOOKAHEAD_HOURS TO 24.

SET DUNA_ENTRY_PE TO 18000.
SET DUNA_ENTRY_LOWER_PE_MAX_DV TO 150.
SET AEROBRAKE_TARGETING TO 0.
SET AEROBRAKE_REENTRY_DIR TO "RETROGRADE".
SET AEROBRAKE_ARM_CHUTES TO 1.

SET DESCENT_CHUTES_TAG TO "descent_chutes".
SET DESCENT_RELEASE_ALT TO 12000.
SET DESCENT_DROGUE_CUT_ALT TO 3500.
SET DESCENT_FAIRING_TAG TO "descent_fairing".
SET DESCENT_FAIRING_DEPLOY_SPEED TO 60.
SET DESCENT_DECOUPLER_TAG TO "descent_decoupler".
SET DESCENT_DECOUPLE_ALT TO 8000.
SET DESCENT_HEAT_SHIELD_DROP_ALT TO -1.
SET DESCENT_BAY_REOPEN_ALT TO 6000.
SET DESCENT_ENGINE_ASSIST TO 1.
SET DESCENT_ENGINE_ASSIST_ALT TO 1200.
SET DESCENT_ENGINE_ASSIST_TOUCHDOWN_VS TO 2.5.
SET DESCENT_ENGINE_ASSIST_HIGH_VS TO 12.
SET DESCENT_ENGINE_ASSIST_MAX_THROTTLE TO 0.85.
```

## Implementation Checklist

1. Add `lib/duna_ike_setup.ks` with the four new phase handlers.
2. Add new config defaults in that library.
3. Wire new phases and bands in `lib/dependencies.ks`.
4. Add `AEROBRAKE_TARGETING` guard to `lib/aerobrake.ks`.
5. Add a selectable FalconHeavy profile for the Duna/Ike variant.
6. Sim Duna arrival and tune `DUNA_AEROCAPTURE_PE`.
7. Sim post-aerocapture Duna `SHAPE` to verify the orbit is safe and useful.
8. Sim `IKE_SETUP` from that shaped Duna orbit.
9. Sim the Ike flyby and inspect post-Ike Duna Pe.
10. Tune `DUNA_ENTRY_SETUP` thresholds and final entry Pe.

## Flight Test Order

1. **Duna aerocapture only**
   Stop after `SHAPE`. Verify the probe survives, Pe is safe, and enough dV
   remains.

2. **Duna orbit to Ike flyby**
   Start from a saved Duna orbit and test `IKE_SETUP` through
   `SCIENCE_OPS_LOW`. Do not continue to Duna entry until the flyby geometry is
   understood.

3. **Ike flyby to Duna entry**
   Start from just after `SCIENCE_OPS_LOW` and test `DUNA_ENTRY_SETUP` through
   `DESCENT`.

4. **End-to-end**
   Only after the three legs above work independently.

## Open Questions

1. What Duna aerocapture Pe is survivable for this exact payload mass and heat
   shield geometry?
2. How much capture-assist dV should we allow before declaring the arrival too
   expensive?
3. Is a roughly 2.9 Mm Duna apoapsis altitude best for Ike, or should we
   target slightly above Ike so local `XING` gets better timing?
4. Does the post-Ike flyby naturally return with a useful Duna Pe, or do we
   need `DUNA_ENTRY_LOWER_PE` on most attempts?
5. Do the installed science experiments benefit from two Ike science phases, or
   should we make a dedicated flyby science phase that runs around periapsis?
