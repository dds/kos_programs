# Plan: Vacuum Surface Ascent Efficiency

## Problem

The Mun surface-return test reached low Mun orbit and successfully rebooted into
`ESCAPE`, but the return burn budget is tight:

```text
Kerbin return escape burn needed: 324.9 m/s
Remaining vessel dV:              344.0 m/s
Margin:                            19.1 m/s
Margin percent:                     5.9%
```

That may be acceptable for an uncrewed probe if MCC and reentry corrections are
small, but it is not a comfortable Kerbaled-mission margin. The original craft
should have had more dV margin for a Mun landing, relaunch, and Kerbin return,
so the surface-to-orbit leg is a prime suspect.

The observed behavior during surface return was also suspicious:

- the relaunch appeared close to straight vertical;
- the countdown issue was fixed separately by delaying MJ enable until after
  countdown;
- the surface-return config persisted a launch inclination/azimuth, but our
  launch code does not actually apply azimuth to MechJeb.

For an airless body, a mostly vertical ascent is expensive. Without atmosphere,
there is no aerodynamic reason to climb steeply. The efficient shape is:

1. clear terrain and local obstacles;
2. pitch over early;
3. build horizontal velocity as soon as practical;
4. cut off at target apoapsis;
5. circularize near apoapsis.

Every second spent hovering or climbing steeply burns against gravity without
building much orbital energy.

## Current Code Path

Surface return is configured by `lib/return_setup.ks`:

```ks
GLOBAL SURFACE_RETURN_SEQUENCE IS LIST("PRELAUNCH", "LAUNCH", "PARK", "RETURN_SETUP").
GLOBAL SURFACE_RETURN_PARKING_ALT IS 20000.
GLOBAL SURFACE_RETURN_INCLINATION IS 0.
GLOBAL SURFACE_RETURN_AZIMUTH IS 0.
```

`phaseSurfaceReturnSetup` persists:

```ks
mission_cfg_SEQUENCE = PRELAUNCH, LAUNCH, PARK, RETURN_SETUP
mission_cfg_PARKING_ALT = SURFACE_RETURN_PARKING_ALT
mission_cfg_LAUNCH_INCLINATION = SURFACE_RETURN_INCLINATION
mission_cfg_LAUNCH_AZIMUTH = SURFACE_RETURN_AZIMUTH
```

Then `lib/launch.ks` runs `phaseLaunch` and configures MechJeb ascent:

```ks
LOCAL asc IS ADDONS:MJ:ASCENT.
SET asc:ENABLED               TO FALSE.
SET asc:DESIREDALTITUDE       TO PARKING_ALT.
SET asc:DESIREDINCLINATION    TO LAUNCH_INCLINATION.
SET asc:AUTOSTAGE             TO FALSE.
SET asc:AUTOSTAGELIMIT        TO 0.
SET asc:AUTODEPLOYANTENNAS    TO FALSE.
SET asc:AUTODEPLOYSOLARPANELS TO FALSE.
SET asc:AUTOWARP              TO FALSE.
SET asc:SKIPCIRCULARIZATION   TO FALSE.
```

It logs azimuth:

```ks
mLog("MechJeb ascent armed. Alt=" + ROUND(PARKING_ALT/1000,0)
    + "km  inc=" + LAUNCH_INCLINATION
    + " deg  az=" + LAUNCH_AZIMUTH + " deg").
```

But there is no current line equivalent to:

```ks
SET asc:<some azimuth suffix> TO LAUNCH_AZIMUTH.
```

So the answer to "did we push improvements to MJ setup for azimuth?" is:

```text
Partly, but not enough.
```

We added a surface-return azimuth config and preserve it into mission state.
We did not confirm or wire a MechJeb kOS API suffix that forces launch azimuth.
At the moment, `LAUNCH_AZIMUTH` is a stored/logged value, not an active guidance
input.

## Are Current MJ Settings Sufficient?

They are sufficient to ask MechJeb for an orbit:

- target altitude;
- target inclination;
- no autostage;
- no antenna/solar deploy;
- no autowarp;
- circularization enabled.

They are probably not sufficient to guarantee an efficient airless ascent,
because they do not specify:

- launch heading/azimuth;
- turn start altitude or velocity;
- turn end altitude;
- turn shape;
- pitch program;
- minimum vertical clearance before pitchover;
- whether circularization should be handled by MJ or by our own maneuver node;
- a vacuum-specific "pitch over immediately" policy.

On Kerbin this omission is tolerable because MechJeb's default atmosphere ascent
profile is often good enough and atmospheric drag punishes early horizontal
flight. On Mun and Minmus the default profile may be too conservative, too
vertical, or simply not tuned for the vessel's TWR and local terrain.

## Why Vacuum Ascent Is Different

A Kerbin launch balances:

- gravity losses;
- drag losses;
- max Q;
- aerodynamic stability;
- heating;
- steering losses;
- terminal velocity-ish constraints.

An airless-body launch has almost none of that. The dominant losses are:

- gravity losses from burning while vertical;
- steering losses from pointing away from the desired velocity vector;
- cosine losses from using thrust for height instead of orbital speed;
- late circularization losses if the ascent arc is badly shaped.

For a 20 km Mun parking orbit, the useful orbital speed is only on the order of
hundreds of m/s. A vertical ascent that spends tens of seconds climbing before
turning can consume a large fraction of the whole ascent budget.

## Evidence To Collect Next Flight

Before changing guidance deeply, add or inspect logs for:

```text
surface_return ascent start:
  body
  target parking altitude
  target inclination
  configured azimuth
  vessel mass
  available thrust
  TWR
  starting lat/lng

ascent telemetry every 5-10 seconds:
  mission elapsed time since launch
  altitude
  radar altitude
  vertical speed
  surface speed
  orbital speed
  apoapsis
  periapsis
  pitch
  heading/yaw
  angle to surface prograde
  throttle
  MJ ascent enabled

parking result:
  final Pe/Ap
  final inclination
  dV remaining
  time to orbit
```

We already have some launch telemetry, but it is oriented toward Kerbin anomaly
detection. For vacuum efficiency, the key question is how quickly the vehicle
starts building horizontal velocity after terrain clearance.

## Options

### Option A: Tune MechJeb Ascent For Vacuum Bodies

Keep `phaseLaunch` as a MechJeb launch phase, but set more MJ ascent parameters
when `SHIP:BODY:ATM:EXISTS` is false.

Potential settings to investigate:

```text
launch azimuth / desired launch azimuth
turn start altitude
turn start velocity
turn end altitude
turn shape
limit acceleration
corrective steering
skip circularization
```

Current repo-confirmed suffixes are only:

```text
ENABLED
DESIREDALTITUDE
DESIREDINCLINATION
AUTOSTAGE
AUTOSTAGELIMIT
AUTODEPLOYANTENNAS
AUTODEPLOYSOLARPANELS
AUTOWARP
SKIPCIRCULARIZATION
```

Before coding this option, we need a live suffix dump or in-game probe of
`ADDONS:MJ:ASCENT` to confirm what the installed kOS/MechJeb exposes. Guessing
suffix names here is risky because a bad suffix can crash the program.

Pros:

- smallest behavioral change if the API exposes the right knobs;
- keeps MJ responsible for steering and circularization;
- likely works for all bodies with one launch phase.

Cons:

- depends on unknown/installation-specific MJ kOS suffixes;
- still delegates a vacuum-specific optimization to a generic ascent autopilot;
- may remain inefficient if MJ's guidance assumptions are Kerbin-like.

### Option B: Add A Dedicated Vacuum Ascent Phase

Create a new airless-body ascent path, either:

```text
VACUUM_LAUNCH
```

or an internal branch in `phaseLaunch`:

```ks
IF NOT SHIP:BODY:ATM:EXISTS {
    phaseVacuumLaunch().
    RETURN.
}
```

Basic first version:

1. Lock throttle to 0.
2. Countdown and stage.
3. Lift vertically only until radar altitude/vertical speed clears a threshold.
4. Pitch to a computed horizontal direction.
5. Burn mostly prograde/horizontal until apoapsis reaches `PARKING_ALT`.
6. Cut throttle.
7. Create a circularization node at apoapsis or directly burn prograde near
   apoapsis.
8. Enter `PARK`.

This mirrors the logic we already trust in pieces:

- `lib/suborbit.ks` has custom non-atmospheric-ish arc handling concepts;
- `lib/maneuver.ks` can execute circularization nodes;
- `lib/launch.ks` already owns staging and parking checks.

Pros:

- directly optimizes the airless ascent problem;
- does not depend on hidden MJ suffixes;
- can use explicit terrain clearance and TWR-aware pitch timing;
- likely yields the biggest dV recovery.

Cons:

- new flight guidance code is higher risk than MJ tuning;
- needs careful handling of steering frames and launch azimuth;
- needs flight-test iteration;
- staging and engine restarts must remain robust.

### Option C: Hybrid Vacuum Launch

Use custom guidance for the expensive early part, then hand off to MJ or a
maneuver node for circularization.

Flow:

1. Our code stages and pitches over early.
2. Our code burns until apoapsis reaches target.
3. Either:
   - create and execute a circularization node with `executeManeuver`, or
   - enable MJ ascent only for circularization.

Pros:

- fixes the most expensive likely loss: vertical climb;
- keeps circularization less hand-rolled if MJ is used;
- easier to test than a full ascent autopilot.

Cons:

- handoff between custom steering and MJ can be awkward;
- MJ might fight or undo state if enabled late;
- still needs good launch-direction math.

### Option D: Manual/Operator Procedure For Current Mission Class

For near-term crewed missions, do not trust the automated surface relaunch yet.
Use a manual ascent profile:

```text
launch
clear terrain
pitch toward desired horizon heading
hold near surface prograde
cut at target Ap
circularize at Ap
then run return setup / escape
```

Pros:

- immediate;
- avoids risking a Kerbaled mission on unproven automation.

Cons:

- not reusable;
- not reboot-safe;
- does not improve the codebase.

## Launch Direction And Azimuth

For vacuum ascent, we need an explicit target horizontal direction.

Possible inputs:

```text
LAUNCH_INCLINATION
LAUNCH_AZIMUTH
SURFACE_RETURN_INCLINATION
SURFACE_RETURN_AZIMUTH
CAPTURE_INC / CAPTURE_LAN, if trying to target a specific plane
```

For simple return missions, we may not need an exact LAN. A low Mun orbit that
allows a cheap Kerbin escape is enough, and MCC can clean up. But we still need
to avoid a vertical launch.

Near-term recommendation:

- Use `LAUNCH_AZIMUTH` as the primary heading for airless surface ascent.
- Keep `LAUNCH_INCLINATION` as the orbit-plane reporting/target value.
- Default `SURFACE_RETURN_AZIMUTH` should probably be eastward unless the
  mission profile asks for polar.

Open question:

```text
What heading convention should LAUNCH_AZIMUTH use on non-Kerbin bodies?
```

The repo generally treats headings as compass-like degrees. We should confirm
with a small in-game test before using it for precise polar launches.

## Minimal Vacuum Ascent Algorithm Sketch

This is intentionally conservative rather than mathematically optimal:

```ks
GLOBAL FUNCTION phaseVacuumLaunch {
    LOCAL targetAp IS PARKING_ALT.
    LOCAL clearAlt IS MAX(50, SHIP:BOUNDS:EXTENTS:MAG * 2).
    LOCAL pitchStartAlt IS clearAlt.
    LOCAL cutoffAp IS targetAp.

    // 1. Liftoff.
    LOCK THROTTLE TO 0.
    countdown(3).
    STAGE.
    LOCK THROTTLE TO 1.

    // 2. Clear terrain vertically.
    LOCK STEERING TO SHIP:UP:VECTOR.
    WAIT UNTIL ALT:RADAR > clearAlt OR ABORT.

    // 3. Pitch toward horizon direction.
    LOCAL launchDir IS computedHorizontalLaunchVector(LAUNCH_AZIMUTH).
    LOCK STEERING TO LOOKDIRUP(launchDir, SHIP:UP:VECTOR).

    // 4. Build horizontal speed until target Ap.
    WAIT UNTIL SHIP:APOAPSIS >= cutoffAp OR ABORT.
    LOCK THROTTLE TO 0.

    // 5. Circularize near Ap.
    planCircularize().
    executeManeuver().
    nextPhase(launchSeq).
}
```

Needed refinements:

- throttle shaping to avoid overshooting apoapsis;
- TWR-aware clear-altitude and pitch schedule;
- terrain slope and obstacle margin;
- automatic staging using existing `armAscentStaging`;
- use `VXCL(SHIP:UP:VECTOR, SHIP:VELOCITY:ORBIT)` or another measured
  horizontal reference when it is safer than a heading vector;
- fallback if the craft cannot reach orbit.

## Recommended Plan

### Phase 1: Documentation And Instrumentation

1. Document the issue and current MJ settings. This file is that artifact.
2. Add a `cmd/mjascdump.ks` or launch debug command to print available
   `ADDONS:MJ:ASCENT` suffixes if kOS supports suffix introspection.
3. Add vacuum-ascent telemetry around the current MJ path:
   - time since launch;
   - altitude/radar altitude;
   - vertical speed;
   - surface/orbital speed;
   - pitch/heading;
   - apoapsis/periapsis;
   - dV remaining if available.

### Phase 2: Try MJ Tuning If Suffixes Exist

If the installed MJ exposes ascent-path controls, add explicit vacuum defaults:

```text
turn start: immediately after terrain clearance
turn end altitude: low fraction of PARKING_ALT
turn shape: aggressive
launch azimuth: LAUNCH_AZIMUTH
```

Acceptance criterion:

```text
Mun 20 km parking orbit uses materially less dV than current surface return.
```

### Phase 3: Add Custom Vacuum Ascent If MJ Is Still Wasteful

If MJ tuning cannot be confirmed or remains inefficient, add a dedicated
vacuum-ascent path.

Recommended first target:

```text
Mun/Minmus only
single active vessel
no atmosphere
target circular orbit at PARKING_ALT
simple azimuth heading
existing staging trigger reused
```

Do not try to solve precise LAN targeting in the first version. First recover
dV by avoiding vertical ascent. Plane precision can come later.

## Acceptance Criteria

A successful improvement should show:

1. Countdown and staging still occur in the correct order.
2. The vehicle pitches over shortly after terrain clearance on Mun/Minmus.
3. `PARK` reaches a stable orbit near `SURFACE_RETURN_PARKING_ALT`.
4. dV remaining before `ESCAPE` is materially higher than the current report.
5. The solution is reboot-safe or fails to manual control before burning.
6. The same code path does not affect Kerbin atmospheric launches unless
   explicitly enabled.

## Open Questions

1. What `ADDONS:MJ:ASCENT` suffixes are available in the installed version?
2. Does MJ have a reliable launch azimuth/heading setting exposed to kOS?
3. How much dV did the Mun surface-to-20km-orbit leg actually consume?
4. What was the vessel TWR on the Mun at liftoff?
5. Did the ascent circularize at 20 km efficiently, or did it waste dV fixing
   a high/odd apoapsis?
6. Should surface return default to equatorial, polar, or eastward local
   prograde for Kerbin return?

## Near-Term Operational Guidance

For probes, the current 19 m/s margin after a 324.9 m/s escape burn may be
acceptable if MCC is tiny and aerobrake targeting is forgiving.

For Kerbaled missions, treat this as not yet operationally safe. Either carry
more ascent/return dV or use a manual surface ascent until the airless ascent
path is proven.

