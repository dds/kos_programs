# Landing targeting and powered descent

This document explains the current automated landing path as implemented in
the `LAND_DEORBIT`, `LAND_ASSIST`, and `LAND` phases. It focuses on the
vacuum powered-descent stack: choosing a target, deliberately aiming the
ballistic trajectory beyond that target, shaping the coast, deciding when to
brake, and walking the final descent state machine down to touchdown.

## Dependency shape

`lib/dependencies.ks` splits landing into two bands:

- `LAND_DEORBIT` loads `landing_deorbit`, `deorbit_targeting`, and
  `deorbit_burn`.
- `LAND` and `LAND_ASSIST` load `payload_landing` and `landing_main`.
  `landing_main` depends on `landing_config`, `landing_math`,
  `vessel_hardware`, and `landing_terminal`.

The terminal descent files are also loaded dynamically by `landing_main`:

- `landing_coast` owns `COAST` and `COAST_MCC`.
- `landing_brake` owns `BRAKE_ALIGN` and `BRAKING_BURN`.
- `landing_terminal` owns `TARGET_REFINE`, `APPROACH`, `HOVER_REFINE`,
  `VERTICAL_DESCENT`, and touchdown settling.

That dynamic loading matters because the landing band is storage-sensitive.
When the state machine changes tracks, `_landingEnsureStateTrack()` deletes
the previous track from the local volume, syncs the next one from archive, and
`RUNONCEPATH`s it.

`landing_deorbit` loads `landing_site`, refines enabled targets and persists
the coordinates for the powered-descent reboot. Other `deorbit_targeting`
callers only use site refinement if the scanner is already loaded. The
RO8 recovery command's `waypoint` mode uses the visually selected site
without requiring SCANsat coverage.

## Target resolution

`landingResolveTarget()` in `landing_config.ks` is the common target resolver
for deorbit and powered descent. The priority order is:

1. `TARGET_WAYPOINT`, resolved by waypoint name on the current body.
2. Locked configured coordinates, including an explicit 0,0 site.
3. The currently selected Waypoint Manager waypoint.
4. Nonzero `TARGET_LAT` / `TARGET_LNG` coordinates.

If no target is found, `LAND_DEORBIT` refuses blind targeted deorbit. The
powered descent code can still run without a target, but it becomes a safe
vertical landing rather than a point landing.

`LAND_ASSIST` also checks that the predicted impact is useful before taking
over, unless `LANDING_SKIP_TARGET_SEARCH` is set. The assist check accepts the
case where Trajectories predicts impact within `LANDING_ASSIST_IMPACT_LIMIT`
(default 20 km) of the target. If Trajectories has no acceptable impact, it
also accepts a low-periapsis flyover whose projected periapsis pass is within
that same limit.

## LAND_DEORBIT

`phaseLandDeorbit()` is responsible for getting the vessel onto an impact or
near-impact trajectory before the powered landing band takes over.

If the vessel is already suborbital and either `LANDING_SKIP_TARGET_SEARCH` is
set or the impact is acceptable for assist, it skips new targeting and advances
to the next phase. If `LANDING_SKIP_TARGET_SEARCH` is set while still needing a
burn, `_timedLandingDeorbit()` makes a simple retrograde node after
`LANDING_DEORBIT_LEAD_MINUTES`, lowering periapsis to the target terrain
height. That path is mostly for rescue/simulation flows.

Otherwise the phase confirms the landing target, optionally auto-picking the
geoposition `LANDING_AUTO_TARGET_MINUTES` into the future, then calls
`targetedDeorbitAt(targetLat, targetLng)`.

## The phantom landing target

The targeted deorbit solver does not try to make the unpowered impact land on
the real target. It deliberately solves for a Trajectories impact downfield of
the real target:

- nominal downfield distance: 15 km
- accepted downfield band: 10-20 km
- cross-track miss must fit the descent controller's correction allowance

That downfield impact is the "phantom" target. It is a ballistic miss point
beyond the actual landing site, measured along the surface track at predicted
impact. The real landing site remains `TARGET_LAT` / `TARGET_LNG`; the phantom
impact exists to preserve control authority and time. If the craft were aimed
ballistically at the real target, the powered descent would have little room
to kill horizontal velocity, correct crossrange error, and settle vertically.
A downfield miss means the craft naturally approaches the target while still
moving horizontally, then spends that motion during braking and approach.

`targetedDeorbitAt()` first checks that Trajectories is available and that the
target latitude is reachable from the current inclination. If `landing_site`
is loaded and site scanning is enabled, it may replace the requested target
with a nearby SCANsat-selected site before solving.

The solver scans candidate burn times at approaching ground angles of
50, 35, 65, 20 and 80 degrees, accepting the first usable candidate. The
additional seeds avoid assuming one burn location works for every eccentric
orbit; this is not a global minimum-dV search.
It scans up to four orbits by default, or `TARGET_DEORBIT_SCAN_ORBITS` when
configured. In `LANDING_SIM_MODE`, this is capped at two orbits. The current
coarse step is `period / MAX(128, TARGET_DEORBIT_SCAN_SAMPLES)`.
The geometry scan yields every 16 samples and refines burn timing to a
0.25-second bracket, avoiding one physics tick per sample and unnecessary
microsecond refinement.
If `TARGET_DEORBIT_PREFERRED_CROSSTRACK_KM` is set, an otherwise
acceptable pass whose cross-track miss is wider than that threshold will not
stop the scan immediately; the solver keeps looking through the configured
scan orbits and chooses the first pass inside the preferred cross-track band,
or the best acceptable wider pass if none are cleaner.

For each candidate burn time, `_solveGeometricDeorbitDv()` searches retrograde
dV from a 15 m/s seed inside a 2-120 m/s range. It places temporary nodes,
waits for Trajectories, and evaluates:

- whether Trajectories predicts an impact
- the predicted impact latitude/longitude
- distance from the real target
- signed downfield distance and lateral miss in the predicted impact track
- periapsis and impact flight-path angle
- error from the desired 15 km downfield point

`downErr` is the error from the phantom aim point, not total landing miss.
For example, the reported `downfield=15km downErr=0.02km cross=2.94/0.61km`
candidate missed laterally by 2.94 km despite only 20 m of downrange error.
Its lateral miss exceeded the estimated 610 m descent correction allowance.

The Minmus recovery profile enables `TARGET_DEORBIT_NORMAL_DV_CAP=10` m/s
(default zero elsewhere). When downrange is acceptable but cross-track is
not, the planner tries normal components of +1 and -1 m/s in the same node,
measures which direction reduces lateral miss, then tests one bounded
linear correction. These are predictions, not separate burns. It stops at
the first complete acceptable solution; at most three extra predictions
are made per burn location. If the normal correction shifts downrange out
of the braking band, the retrograde solve continues with that normal
component retained. The final node preserves both components and undergoes
the usual impact and terrain checks. The cap limits the normal component,
not the total burn; actual savings depend on the measured trajectory.

If downrange has converged within 250 m but another limit still rejects the
approach, the solver moves to another burn location instead of polishing
the same downrange root. Persistent `STATS deorbit` records name the failing
gate (`cross-track`, braking lead, impact angle, or missing prediction).

The first solution in the 10-20 km downfield band with cross-track miss within
the controller's allowance is accepted, also respecting `DEORBIT_MIN_FPA`
when enabled. Before execution, the chosen node is recreated and its impact
is rechecked against those same limits. Missing/changed impact predictions
hold without burning. The node is optionally terrain-validated: if projected terrain contact occurs
before the target pass, planning fails; post-target impact is only warned
about because it is expected for the phantom target.

### Geometry regression: eccentric polar Minmus landing

The old cross-track calculation subtracted the squared projected downfield
distance from the squared three-dimensional target/impact chord. That counts
the planet's curvature as lateral error: a perfectly aligned 15 km downrange
point on a 60 km-radius Minmus produced about **1,865 m false cross-track**.
It could never satisfy a 610 m lateral limit. The new calculation resolves
along-track and cross-track angles on the sphere using the impact tangent;
altitude and radial chord sag are excluded.

`lmGroundGeoAt` accounts for body rotation at the future sample time. For a
same-SOI local landing, kOS/KSP `POSITIONAT(SHIP, ut)` uses the current body
center; the radius is measured from `BODY:POSITION`, not
`POSITIONAT(BODY, ut)`. Mixing those centers injected the moon's motion
around its parent into the old impact-angle and terrain predictions. See
[kOS vessel prediction implementation](https://github.com/KSP-KOS/KOS/blob/develop/src/kOS/Suffixed/VesselTarget.cs)
and [body coordinate conversion](https://ksp-kos.github.io/KOS/structures/celestial_bodies/body.html#body-geopositionof).
The helpers here are local-SOI geometry, not encounter/SOI-transition tools.

Ground-relative velocity is a finite difference of the corrected positions,
and the same geometry is used for impact FPA and terrain validation. Lateral
correction time excludes the wait before the deorbit burn. Candidate failures,
the selected plan and final validation now emit persistent `STATS deorbit`
records. `scripts/check_deorbit_geometry.py` evaluates the actual source
expressions against spherical/polar/rotating-body fixtures and acceptance
boundaries. It does not simulate Trajectories updates, finite burns, terrain
meshes or kOS execution; flight validation is still needed.

`executeDeorbitNode()` centers the burn around the node time, starts alignment
90 seconds early, creates a maneuver alarm, points along `nd:BURNVECTOR`, and
refuses the burn if alignment is worse than 15 degrees at start. Throttle is
full for most of the burn, then tapers at low remaining dV. Afterward it
removes nodes, restores SAS, and the next landing phase takes over.

## Powered-descent setup

`phaseLandAssist()` and `phaseLand()` are thin wrappers in
`payload_landing.ks`. Both redirect back to `LAND_DEORBIT` if the vessel is
still in orbit with periapsis more than 500 m above the target flyover terrain.
`LAND_ASSIST` additionally refuses to start unless the predicted impact is
acceptable, unless target search has explicitly been skipped.

`landExecute()` in `landing_main.ks` owns the powered descent:

- resolves and stores the landing target, if any
- performs an initial terrain check near the target
- initializes the crossrange PID used during braking
- sets the initial FSM state to `COAST`
- sets the Trajectories target, when available
- disables SAS, deploys landing gear, locks steering and throttle
- stages automatically if all thrust is gone or an engine flames out

The one-shot terrain check samples a grid around the target using
`TERRAIN_CHECK_RADIUS` and `TERRAIN_CHECK_STEP` (defaults 100 m and 20 m). It
first checks the requested center against `LANDING_TERRAIN_MAX_SLOPE` (5°).
If it meets that limit, it keeps the center instead of buying a long diversion
to slightly flatter terrain. Otherwise it scores nearby points by gradient
magnitude and distance, as a best-effort terrain search. This is not a terrain
safety certification. The center is always a candidate, and grid spacing is
clamped to the search radius. `STATS landing-terrain` records any shift.

If no target exists, the same state machine runs, but target-aware horizontal
guidance is skipped and it becomes a vertical powered descent.

## Shared landing math

`landing_math.ks` supplies the physics helpers:

- `lmGravity()` computes local gravity and subtracts centripetal acceleration
  from horizontal ground speed.
- `lmMaxAcc()` is available thrust divided by mass.
- `lmHorizontalBrakeDistance(v, a)` returns `v^2 / (2a)`.
- `lmVerticalBurnDistance(v, aMax, g)` returns the suicide-burn height for
  current downward speed and net upward acceleration.
- `lmDescentSpeed()` schedules the target vertical speed: high-altitude
  descent uses `HIGH_DESCENT_SPEED`, blends to 20 m/s near 1000-1500 m, to
  8 m/s near 100 m, and finally to `TOUCHDOWN_SPEED` near `UPRIGHT_ALT`.
- steering helpers produce retrograde, hover, and approach steering vectors
  capped by `MAX_TILT`.

The descent loop refreshes a context cache each tick: surface velocity, up
vector, horizontal velocity and speed, max acceleration, local gravity,
vertical speed, and positive downspeed.

## Brake gates

`_landingBrakeGateInfo()` decides when braking should begin.

The trigger and braking controller share a coupled velocity-arrest budget:

```text
netAcc = 0.8 * max(0, availableAcceleration - gravity)
futureDown = downSpeed + gravity * reactionTime
stopTime = sqrt(horizontalSpeed^2 + futureDown^2) / netAcc * BURN_MARGIN
horizontalGate = horizontalSpeed * (reactionTime + stopTime / 2)
verticalGate = downSpeed * reactionTime + gravity * reactionTime^2 / 2
               + futureDown * stopTime / 2 + clearance
```

Defaults are three seconds of reaction time and 100 m clearance. The planning
acceleration is the weaker of current propulsion and the next eligible
stage's estimated acceleration after separation at its current wet mass.
Planning uses full surface gravity, without credit for centripetal support
that disappears as horizontal speed falls. An insufficient acceleration
budget triggers braking immediately; it cannot make an underpowered craft
capable of landing.

The horizontal trigger compares the gate with target downrange **minus**
`LANDING_BRAKE_GATE_LEAD_DIST` and `LANDING_BRAKE_UNDERSHOOT_BIAS`. These
positive allowances now advance ignition; the former addition delayed it.
The vertical trigger uses the smaller of height above target elevation and
bottom-of-vessel radar clearance. It remains active regardless of target
miss or the Trajectories impact prediction.

The vertical ETA searches the next 120 seconds of conservative coast,
including the growth of stopping distance as downward speed increases.
The horizontal ETA estimates closing time to the horizontal gate.
`H_NOW`/`V_NOW` mean the corresponding gate has arrived. `H_OVERSHOT` means
the target is behind the descending craft below `TERRAIN_SAFE_ALT`.
The existing high-altitude horizontal suppression still applies when above
`TERRAIN_SAFE_ALT`, above twice the horizontal gate, and over 60 seconds from
the vertical trigger. It cannot suppress the vertical trigger.

These are conservative point-mass bounds, not terrain-path or attitude
simulation. Rising terrain ahead, unusually slow rotation, engine spool-up,
or nonstandard staging can require additional allowance. The next-stage
mass estimate assumes a conventional serial stack with the root/core on the
retained lander. `landingcheck.ks` prints its estimated surface TWR.
It uses [kOS engine POSSIBLETHRUST](https://ksp-kos.github.io/KOS/structures/vessels/engine.html#engine-possiblethrust),
which reports thrust even before ignition, and current retained part mass.
Any unaccounted vessel mass is conservatively retained on the lander.

## State machine overview

The state machine starts in `COAST`. Touchdown is detected outside the normal
guidance states by observing `SHIP:STATUS`; once landed or splashed, the loop
runs surface settling until the vehicle is slow and stable.

```text
COAST
  -> COAST_MCC        enabled, impact error is large and braking is not soon
  -> BRAKE_ALIGN      target landing, brake gate is within alignment lead
  -> BRAKING_BURN     horizontal/vertical gate is due, overshot, or blind suicide burn
  -> VERTICAL_DESCENT untargeted vertical gate

COAST_MCC
  -> COAST            corrected, unsafe to keep correcting, or brake gate is near

BRAKE_ALIGN
  -> BRAKING_BURN     horizontal/vertical gate is due or target has been passed
  -> COAST            gate was deferred again

BRAKING_BURN
  -> VERTICAL_DESCENT over target and slow, low vertical gate, or blind h-speed killed
  -> TARGET_REFINE    close enough after braking but not ready for final drop
  -> APPROACH         post-brake miss remains outside approach radius

TARGET_REFINE
  -> APPROACH         velocity stabilized, timeout, or climb guard above final-hover height
  -> VERTICAL_DESCENT too low for a translation handoff

APPROACH
  -> VERTICAL_DESCENT position and speed meet landing tolerances
  -> HOVER_REFINE     final-hover altitude reached with residual miss

HOVER_REFINE
  -> VERTICAL_DESCENT acceptable position/speed, or bounded hover time exhausted

VERTICAL_DESCENT
  -> HOVER_REFINE     final hover refinement needed near the ground
  -> surface settle   when KSP reports landed/splashed
```

## COAST

`_landingCoastTick()` keeps throttle at zero and steers roughly retrograde
using `lmRetroSteering()`. If a target exists and the initial terrain check
has not yet happened, it performs that check when radar altitude falls below
`GUIDANCE_ALT`.

During coast it logs the brake-gate solution and, for target landings, starts
a maneuver-correction state if Trajectories predicts a miss before the brake
gate. This correction is only attempted when the next brake event is more than
`LANDING_COAST_MCC_MIN_BRAKE_ETA` away.

If no correction is needed, the state moves into braking based on the vertical
gate, horizontal gate, overshoot detection, or the `LANDING_BRAKE_ALIGN_LEAD`
window. Without a target, it uses a blind suicide-burn estimate based on time
to impact and burn time.

## COAST_MCC

`COAST_MCC` is an optional small pulsed midcourse correction during the
unpowered coast. A nonpositive `LANDING_COAST_MCC_THROTTLE_MAX` disables it
(default zero). The minimum throttle cannot override that maximum. Previously
the default 2% minimum accidentally enabled burns even with the maximum zero.
It does not try to move the Trajectories impact onto the real target. Instead
it tries to put the predicted impact `LANDING_COAST_MCC_LEAD_DIST` ahead of
the target, with crossrange error near zero. The default lead is 3 km. This is
a second, smaller phantom lead used right before braking: enough lead to still
brake and approach, but much tighter than the original 15 km deorbit miss.

The correction vector is built from:

- along-track error from the desired 3 km lead
- signed crossrange error
- current horizontal travel direction and cross axis

The craft points horizontally along that correction vector using
`LOOKDIRUP()`. It burns only when alignment is within
`LANDING_COAST_MCC_ALIGN_DEG` and the nose is not too close to vertical
(`LANDING_COAST_MCC_MAX_UP_DOT`). Burns are tiny pulses:
between `LANDING_COAST_MCC_THROTTLE_MIN` and
`LANDING_COAST_MCC_THROTTLE_MAX` for `LANDING_COAST_MCC_PULSE_TIME`,
followed by `LANDING_COAST_MCC_SETTLE_TIME`. The throttle approaches the max
when braking is still far away and rolls down toward the min near the brake
gate for gentler refinement.

It exits back to `COAST` if braking is near, if it starts climbing too fast,
if Trajectories is lost, if the miss drops below
`LANDING_COAST_MCC_ACCEPT_DIST`, or if there is no useful horizontal
correction vector.

## BRAKE_ALIGN

`BRAKE_ALIGN` throttles to zero and points the ship for the braking burn before
the gate arrives. The lead time defaults to 20 seconds.

Alignment uses the same gravity-compensated velocity-arrest vector as the
burn. The brake track is loaded during landing setup, its disk file reclaimed,
and its resident functions reused at ignition; state changes no longer fetch
or compile that track near the ground.

If either brake gate arrives, the state changes to `BRAKING_BURN`. If the gate
is no longer close and was not merely suppressed, it returns to `COAST`.

## BRAKING_BURN

One acceleration vector owns both throttle and direction:
`gravity * up + netAcceleration * normalized(desiredVelocity - velocity)`.
The net acceleration uses the same fractional budget as the trigger, with a
one-second response taper near the desired velocity. The magnitude sets
throttle and its normalized direction sets steering. This replaces a nearly
horizontal fixed upward bias and an independently computed vertical throttle.

Above `APPROACH_HSPEED`, desired horizontal and vertical speeds are zero.
Maintaining the ordinary 30 m/s descent target throughout a long sideways
burn would spend height absent from the stopping-distance calculation. Once
lateral speed is low, the scheduled descent speed resumes. Trajectories
undershoot and crossrange correction no longer reduce braking authority;
position correction follows velocity capture in the terminal track.

The state exits when the descent is captured and horizontal speed is low:

- if within `VERTICAL_RADIUS`, go directly to `VERTICAL_DESCENT`
- if outside `APPROACH_RADIUS`, go to `APPROACH`
- otherwise go to `TARGET_REFINE`

It can also go to `TARGET_REFINE` once the approach corridor is captured
within `APPROACH_RADIUS`, or to `VERTICAL_DESCENT` on a low vertical gate when
targeting is absent or horizontal speed is already low.

## Staging during powered descent

The transfer engine remains in use while any active, non-flamed-out engine
provides available thrust. On exhaustion, tick-driven staging advances only
to the next inactive throttleable engine, respecting `LANDING_STAGE_LIMIT`
and `LANDING_STAGE_MAX_EVENTS`. Separation and ignition may use separate
slots. An engine still inactive at its selected slot gets one explicit
activation attempt. The controller never advances past that slot merely
because thrust has not appeared, and a manual engine activation is detected.

Steering and guidance continue between events; throttle is held at zero for
`LANDING_STAGE_SETTLE` (0.25 seconds). Acceleration and mass are refreshed
before guidance after each event. No next engine means no further staging,
so exhaustion cannot blindly progress into a chute or payload release.
`STATS landing-stage` records events and restored thrust; `STATS landing-brake
begin` records clearance, gates, thrust assumptions and alignment error.

No tag is required. `landing_assist_decoupler` is an unused legacy label.
The staging stack must contain only intended separation/ignition events en
route to the next engine. Disposal is ballistic, not actively targeted, and
still-fueled stages are not automatically discarded. Numerical fixtures
cover trigger/controller consistency and staged thrust changes; actual
separation clearance and KSP timing remain flight-test requirements.

## TARGET_REFINE

`TARGET_REFINE` is the post-brake stabilization state. Its job is to remove
lateral drift and pull the vessel toward the landing target before the
approach leg.

The steering is a kinematic position controller:

- compute the flat position error from the vessel to the target
- turn that into a desired horizontal velocity, capped by
  `LANDING_TARGET_REFINE_HSPEED`
- lean proportionally to the velocity error, capped by `MAX_TILT`

Throttle tracks the scheduled descent speed and adds correction throttle from
the requested lateral acceleration. The correction bounds are scaled around
hover throttle so high-TWR landers do not use a fixed, overpowering throttle
limit.

It hands off to `APPROACH` once horizontal speed is stabilized: immediately
below `LANDING_TARGET_REFINE_HSPEED`, or after `LANDING_TARGET_REFINE_ACCEPT_TIME`
below `LANDING_TARGET_REFINE_ACCEPT_HSPEED`. A timeout or climb guard also
hands off to approach when above `LANDING_FINAL_HOVER_ALT`. Below that height,
it finishes vertically instead of attempting a new translation. It no longer
tries to cover hundreds of meters at 1 m/s inside a 20-second timeout and then
silently abandons the position target.

## APPROACH

`APPROACH` performs the final 20 m terrain check once, while continuing the
approach. It translates toward the target while descending, using lateral
acceleration available while supporting weight: the lesser of the thrust
reserve and `g * tan(MAX_TILT)`, with a 20% response margin. This is much less
than the full-thrust sideways brake acceleration on a high-TWR Minmus lander.
The stopping-speed cap uses this upright acceleration and the remaining
distance outside the small settle radius.

Steering converts velocity error into acceleration using
`LANDING_APPROACH_RESPONSE_TIME` (5 seconds), then into a tilt demand using
local gravity. `targetWeight` changes the response, not the commanded speed;
it no longer multiplies the speed beyond the stopping cap. The tilt limit is
respected using `tan(MAX_TILT)` in the up-plus-horizontal steering vector.

Descent speed is capped by the estimated time needed to translate and arrest
horizontal motion. This allows continued descent rather than first holding
altitude to complete the entire lateral correction. The old routine hover
trigger at about 1 km plus lead time has been removed. A low-altitude speed
cap retains the hover translation speed instead of fading all translation to
zero before reaching the target.

Once distance and horizontal speed meet `LANDING_HOVER_REFINE_ACCEPT_RADIUS`
and `LANDING_HOVER_REFINE_ACCEPT_HSPEED` (30 m and 1.75 m/s), approach goes to
vertical descent. If it reaches `LANDING_FINAL_HOVER_ALT` (15 m) with a larger
miss, it enters final hover refinement.

## HOVER_REFINE

This is a final low-altitude correction, not an unconditional terrain-check
pause high above the surface. If the fine terrain check has already run in
approach, it is reused. Otherwise its grid spacing is limited to the 20 m
search radius, so a mission with 100 m coarse spacing cannot force a spurious
move to the southwest corner without sampling the center.

Translation uses the same upright acceleration/stopping limits. If entered
above final-hover height through another path, the craft continues descending
while translating. At final-hover height it briefly supports altitude to
settle. A result within the configured acceptable radius/speed can descend
without waiting for the tighter 5 m / 0.3 m/s condition.

`LANDING_HOVER_REFINE_MAX_TIME` (30 seconds) bounds this position-correction
pause. Expiration proceeds to vertical landing and logs the residual miss;
it does not claim precise capture. The separate near-ground horizontal-speed
safety check remains active, so this limit does not force a fast sideways
touchdown or bound all time spent supporting the craft.

## VERTICAL_DESCENT

`VERTICAL_DESCENT` performs the final drop. If a target exists, hover
refinement has not happened, and bottom altitude is already below
`LANDING_FINAL_HOVER_ALT`, it detours back into `HOVER_REFINE`.

Otherwise steering depends on height and residual horizontal speed:

- near the ground with too much horizontal speed, use hover steering against
  horizontal velocity
- below `UPRIGHT_ALT`, point straight up
- with a target, lean toward zero target-relative horizontal speed
- without a target, use hover steering

When appropriate, `_landingSolarRollSteering()` rolls the craft so the sun is
in the steering frame. This keeps the vehicle upright while preserving a
useful roll orientation for panels.

Descent speed uses the normal schedule, except during the final hover case
where it is reduced to `LANDING_FINAL_HOVER_VSPEED`. There is no explicit
"touchdown burn complete" transition; the main loop waits for KSP to report
`LANDED` or `SPLASHED`.

## Touchdown and final site

Once the vessel is on the surface, `_landingSurfaceSettleTick()` holds
throttle at zero, keeps gear deployed, and points upright with solar roll when
near the ground. The landing is considered settled only after all of these are
true for `LANDING_TOUCHDOWN_SETTLE_TICKS` ticks:

- status is `LANDED` or `SPLASHED`
- bottom radar altitude is at or below `LANDING_TOUCHDOWN_ALT`
- absolute vertical speed is at or below `LANDING_TOUCHDOWN_VSPEED`
- horizontal speed is at or below `LANDING_TOUCHDOWN_HSPEED`

Then `_landingFinish()` sets the state to `TOUCHDOWN`, cleans up throttle and
steering locks, restores reaction wheel authority, records `landing_lat`,
`landing_lng`, and `landing_time`, and deploys antennas and solar panels.

The final place to land is therefore chosen in layers:

1. User/mission target resolution picks the requested site.
2. Optional SCANsat site selection can shift it to a safe nearby site before
   deorbit planning.
3. Initial terrain sampling can shift it to the flattest nearby point before
   powered descent.
4. Hover refinement can shift it again within a much smaller radius.
5. The actual recorded landing point is wherever the craft physically settles
   after the final vertical descent.

## Operational entry points

Mission profiles normally set the landing globals directly and include
`LAND_DEORBIT`, then `LAND_ASSIST` or `LAND`, in `SEQUENCE`.

`cmd/setlanding.ks` is the manual phase/config override. In `deorbit` mode it
sets a `LAND_DEORBIT -> LAND_ASSIST -> DONE` sequence by default, or can route
to `LAND` instead. In `assist` mode it forces the current phase to
`LAND_ASSIST`, marks the current lib band as `LANDING`, and disables reloads
after landing.

`cmd/landingrescue.ks` is the storage-pruning rescue path. In automatic mode it
chooses one of these plans based on current trajectory and atmosphere:

- `LAND_ASSIST -> DONE` when already on an impact trajectory
- `LAND_DEORBIT -> LAND_ASSIST -> DONE` when a cheap deorbit is needed
- atmospheric variants that run `AEROBRAKE` before powered assist

For rescue, it locks a target to the current Trajectories impact if available,
or to a future body-fixed position along the orbit, sets
`LANDING_SKIP_TARGET_SEARCH`, and keeps only the libraries needed for the
chosen sequence.

`cmd/landat.ks` is related but is not the vacuum powered-descent path described
above. It sets up `KSC_DEORBIT, DESCENT, DONE` for Kerbin point landings using
the shared targeted-deorbit machinery plus the atmospheric `descent` library.

## Important defaults

These values come from `landing_config.ks`, `landing_main.ks`, and
`landing_site.ks`. Mission profiles often override them.

| Area | Setting | Default | Meaning |
|---|---:|---:|---|
| target | `TARGET_TOLERANCE` | 5000 m | Generic deorbit/impact tolerance |
| target | `LANDING_ASSIST_IMPACT_LIMIT` | 20000 m | Maximum miss accepted before assist |
| deorbit | phantom downfield | 15000 m | Nominal ballistic miss beyond real target |
| deorbit | phantom band | 10000-20000 m | Accepted downfield and distance band |
| deorbit | node ground angle | 50 deg | Desired central angle before target |
| deorbit | retro dV search | 2-120 m/s | Range searched for the deorbit node |
| deorbit | seed retro dV | 15 m/s | Initial dV trial |
| deorbit | `TARGET_DEORBIT_PREFERRED_CROSSTRACK_KM` | 0 km | Preferred max cross-track before waiting for a later orbit; 0 disables |
| terrain | `TERRAIN_CHECK_RADIUS` | 100 m | Initial flat-spot search radius |
| terrain | `TERRAIN_CHECK_STEP` | 20 m | Initial flat-spot grid step |
| terrain | hover radius override | 20 m | Final hover flat-spot search radius |
| SCANsat | `LANDING_SITE_SCAN_ENABLE` | 0 | Optional pre-deorbit site scan |
| SCANsat | `LANDING_SITE_SCAN_RADIUS` | 1500 m | Optional SCANsat scan radius |
| SCANsat | `LANDING_SITE_SCAN_STEP` | 250 m | Optional SCANsat scan step |
| SCANsat | `LANDING_SITE_MAX_SLOPE` | 12 deg | Optional SCANsat slope cutoff |

| Area | Setting | Default | Meaning |
|---|---:|---:|---|
| braking | `BURN_MARGIN` | 1.1 | Multiplier on vertical burn distance |
| braking | `BRAKE_MARGIN` | 100 m | Extra gate distance/height |
| braking | `LANDING_BRAKE_ACCEL_FRACTION` | 0.8 | Shared fraction of net thrust acceleration for trigger/controller |
| braking | `LANDING_BRAKE_REACTION_TIME` | 3 s | Coast allowance for ignition/rotation/staging |
| braking | `LANDING_BRAKE_CLEARANCE` | 100 m | Height reserved after the predicted velocity stop |
| braking | `LANDING_BRAKE_RESPONSE_TIME` | 1 s | Velocity-error taper near capture |
| braking | `LANDING_BRAKE_GATE_LEAD_DIST` | 1500 m | Extra downrange lead in h-gate |
| braking | `LANDING_BRAKE_ALIGN_LEAD` | 20 s | Alignment lead before burn |
| braking | `APPROACH_HSPEED` | 18 m/s | Desired post-brake approach speed |
| braking | `TERMINAL_HSPEED` | 1 m/s | Slow enough for terminal decisions |
| braking | `LANDING_LOW_ALT_HSPEED` | 2 m/s | Low-alt horizontal speed threshold |
| steering | `MAX_TILT` | 15 deg | Lean cap for guidance steering |
| crossrange | `GUIDANCE_CORRECTION_THRESHOLD` | 500 m | Cross error before PID bias |
| crossrange | `TR_BRAKE_BIAS` | 0.35 | Max crossrange steering bias |
| MCC | `LANDING_COAST_MCC_LEAD_DIST` | 3000 m | Desired pre-brake impact lead |
| MCC | `LANDING_COAST_MCC_TRIGGER_DIST` | 30 m | Error needed to enter MCC |
| MCC | `LANDING_COAST_MCC_ACCEPT_DIST` | 10 m | Error small enough to exit MCC |
| MCC | `LANDING_COAST_MCC_MIN_BRAKE_ETA` | 60 s | Do not MCC too close to braking |
| MCC | `LANDING_COAST_MCC_THROTTLE_MIN` | 0.02 | Late/refinement pulse throttle |
| MCC | `LANDING_COAST_MCC_THROTTLE_MAX` | 0.07 | Early/large-error pulse throttle |
| MCC | `LANDING_COAST_MCC_PULSE_TIME` | 10 s | Pulse duration |
| MCC | `LANDING_COAST_MCC_SETTLE_TIME` | 3 s | Wait after each pulse |

| Area | Setting | Default | Meaning |
|---|---:|---:|---|
| descent | `HIGH_DESCENT_SPEED` | 30 m/s | High-altitude scheduled descent |
| descent | `TOUCHDOWN_SPEED` | 2 m/s | Final scheduled descent speed |
| descent | `HOVER_ALT` | 100 m | Hover/low-altitude reference |
| descent | `UPRIGHT_ALT` | 10 m | Height for straight-up final attitude |
| target refine | `LANDING_TARGET_REFINE_HSPEED` | 1 m/s | Immediate refine acceptance speed |
| target refine | `LANDING_TARGET_REFINE_ACCEPT_TIME` | 10 s | Time before looser acceptance |
| target refine | `LANDING_TARGET_REFINE_ACCEPT_HSPEED` | 5.5 m/s | Looser h-speed after accept time |
| target refine | `LANDING_TARGET_REFINE_MAX_TIME` | 20 s | Timeout to avoid lingering |
| approach | `APPROACH_RADIUS` | 750 m | Radius where target refine is preferred |
| approach | `VERTICAL_RADIUS` | 60 m | Close enough for final vertical descent |
| approach | `MAX_APPROACH_SPEED` | 55 m/s | Upper bound on approach translation |
| approach | `TERMINAL_ALT` | 1000 m | Force hover/refine at low altitude |
| hover | `LANDING_HOVER_REFINE_MAX_TIME` | 30 s | Maximum final position-correction pause |
| hover | `LANDING_HOVER_REFINE_MAX_SPEED` | 4 m/s | Hover translation cap |
| hover | `LANDING_HOVER_REFINE_ACCEPT_RADIUS` | 30 m | Loose hover radius |
| hover | `LANDING_HOVER_REFINE_SETTLE_RADIUS` | 5 m | Tight hover radius |
| hover | `LANDING_HOVER_REFINE_ACCEPT_HSPEED` | 1.75 m/s | Loose hover h-speed |
| hover | `LANDING_HOVER_REFINE_SETTLE_HSPEED` | 0.3 m/s | Tight hover h-speed |
| final | `LANDING_FINAL_HOVER_ALT` | 15 m | Final hover threshold |
| final | `LANDING_FINAL_HOVER_VSPEED` | 0.2 m/s | Final hover descent speed |
| touchdown | `LANDING_TOUCHDOWN_ALT` | 3 m | Bottom radar settled altitude |
| touchdown | `LANDING_TOUCHDOWN_VSPEED` | 1 m/s | Settled vertical speed |
| touchdown | `LANDING_TOUCHDOWN_HSPEED` | 0.3 m/s | Settled horizontal speed |
| touchdown | `LANDING_TOUCHDOWN_SETTLE_TICKS` | 120 | Stable ticks before finish |

### Minmus landing efficiency regression

The operator reported the first successful RO8 landing 305 m from the requested
waypoint with about 380 m/s remaining, prolonged corrections and a wasteful
hover (2026-10-14). No detailed state log was available, so a terrain-driven
site shift cannot be distinguished from a guidance miss on that flight.
State transitions, terrain shifts, and touchdown now persist `STATS` records.
During powered guidance, records stay local; archive copies wait until landing
cleanup has cleared throttle and allowed a physics update before unlocking.
`STATS landing-result` separates requested-waypoint miss, final-guidance miss,
and target relocation distance.

`scripts/check_landing_guidance.py` runs selected source functions through a
small fixture interpreter. Checks cover disabled MCC, centered terrain grids,
stabilization handoffs, hover limits, and an idealized 305 m Minmus approach.
That fixture assumes flat terrain, instantaneous steering and constant mass;
it is not a kOS/KSP simulation or a prediction of flight accuracy/fuel savings.

The important design idea is that early targeting is intentionally not
pinpoint. The deorbit aims at a downfield phantom impact so powered descent
has room to work. Coast MCC tightens that phantom lead. Braking spends the
horizontal energy. Target refine and approach convert the remaining miss into
a controlled hover. Hover refine picks the final local patch, and vertical
descent finishes the landing.
