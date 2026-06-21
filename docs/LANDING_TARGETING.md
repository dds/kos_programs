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

`landing_site` is optional. `deorbit_targeting` only calls
`selectScanSatLandingSite()` if `landing_site` is already loaded in the boot
library set. When present and enabled, it can shift the requested deorbit
target to a nearby SCANsat-safe site before planning the deorbit node.

## Target resolution

`landingResolveTarget()` in `landing_config.ks` is the common target resolver
for deorbit and powered descent. The priority order is:

1. `TARGET_WAYPOINT`, resolved by waypoint name on the current body.
2. Locked configured coordinates, if `TARGET_LOCK` is true and either
   `TARGET_LAT` or `TARGET_LNG` is nonzero.
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
- accepted straight-line target distance: 10-20 km

That downfield impact is the "phantom" target. It is a ballistic miss point
beyond the actual landing site, measured along the ground track at the burn
time. The real landing site remains `TARGET_LAT` / `TARGET_LNG`; the phantom
impact exists to preserve control authority and time. If the craft were aimed
ballistically at the real target, the powered descent would have little room
to kill horizontal velocity, correct crossrange error, and settle vertically.
A downfield miss means the craft naturally approaches the target while still
moving horizontally, then spends that motion during braking and approach.

`targetedDeorbitAt()` first checks that Trajectories is available and that the
target latitude is reachable from the current inclination. If `landing_site`
is loaded and site scanning is enabled, it may replace the requested target
with a nearby SCANsat-selected site before solving.

The solver then scans candidate burn times looking for a geometric node where
the vessel subpoint is about 50 degrees of central angle before the target.
It scans up to four orbits by default, or `TARGET_DEORBIT_SCAN_ORBITS` when
configured. In `LANDING_SIM_MODE`, this is capped at two orbits. The current
implementation uses a fixed coarse step of `period / 128`; the
`TARGET_DEORBIT_SCAN_SAMPLES` global exists, but is not currently used by this
solver. If `TARGET_DEORBIT_PREFERRED_CROSSTRACK_KM` is set, an otherwise
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
- signed downfield distance relative to the real target and burn ground track
- periapsis and impact flight-path angle
- error from the desired 15 km downfield point

The first solution that lands in the 10-20 km downfield band and the 10-20 km
distance band is accepted. Before execution, the chosen node is recreated for
real and optionally terrain-validated: if projected terrain contact occurs
before the target pass, planning fails; post-target impact is only warned
about because it is expected for the phantom target.

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
scores each point by local north/south and east/west slope plus distance from
the requested center. If the best point is more than 5 m from the current
target, it shifts `TARGET_LAT` / `TARGET_LNG` and updates Trajectories.

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

Horizontal braking uses:

- horizontal acceleration reserve calculated from the thrust vector budget
- brake distance: `hspeed^2 / (2 * horizontalAcc)`
- gate distance: brake distance plus `BRAKE_MARGIN`
- target downrange distance projected along current horizontal velocity
- extra lead: `LANDING_BRAKE_GATE_LEAD_DIST` when moving horizontally

The horizontal acceleration is not a static fraction of thrust. The gate
reserves vertical acceleration first: local gravity plus
`LANDING_HORIZONTAL_ACCEL_VERTICAL_BUFFER`. It then treats `MAX_ACC` as the
hypotenuse of the thrust vector and computes the horizontal leg:

```text
verticalAcc = gravAcc * (1 + LANDING_HORIZONTAL_ACCEL_VERTICAL_BUFFER)
horizontalAcc = sqrt(maxAcc^2 - verticalAcc^2)
```

If available thrust cannot cover that vertical requirement, the gate falls
back to `LANDING_HORIZONTAL_ACCEL_FALLBACK_FRACTION * MAX_ACC`, so low-TWR
vehicles get a longer, earlier horizontal brake gate instead of an optimistic
one.

Vertical braking uses:

- vertical burn distance from `lmVerticalBurnDistance()`
- vertical gate: burn distance times `BURN_MARGIN`, plus `BRAKE_MARGIN`
- burn height: target-relative height, except during `VERTICAL_DESCENT` where
  bottom radar altitude is used

The gate returns both immediate flags and ETAs. `H_NOW` means downrange is
inside the horizontal brake gate. `V_NOW` means the vertical burn gate has
arrived. `H_OVERSHOT` means the target has passed behind the craft while the
craft is descending below `TERRAIN_SAFE_ALT`.

There is a high-altitude suppression rule for horizontal braking: if the craft
is still above `TERRAIN_SAFE_ALT`, the burn height is more than twice the
horizontal gate, and the vertical burn is more than 60 seconds away, the
horizontal gate is deferred so the vehicle does not waste energy braking too
early in a long descent.

## State machine overview

The state machine starts in `COAST`. Touchdown is detected outside the normal
guidance states by observing `SHIP:STATUS`; once landed or splashed, the loop
runs surface settling until the vehicle is slow and stable.

```text
COAST
  -> COAST_MCC        impact lead/cross error is large and braking is not soon
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
  -> APPROACH         lateral drift and Trajectories impact are acceptable
  -> VERTICAL_DESCENT timeout or climb guard

APPROACH
  -> HOVER_REFINE     over target, hover-refine lead time, or terminal altitude

HOVER_REFINE
  -> VERTICAL_DESCENT final target position is settled

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

`COAST_MCC` is a small pulsed midcourse correction during the unpowered coast.
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

The steering comes from `_landingBrakeSteeringInfo()`:

- default is retro steering from `lmRetroSteering()`
- if horizontal speed is above `APPROACH_HSPEED` and there is plenty of height,
  hard braking points mostly opposite horizontal velocity with a small upward
  bias from `LANDING_HARD_BRAKE_UP_BIAS`
- if Trajectories says the impact is already behind the target, the brake
  guard suppresses horizontal retro steering and resets the cross PID
- if crossrange error exceeds `GUIDANCE_CORRECTION_THRESHOLD`, the cross PID
  biases steering toward the cross axis, capped by `TR_BRAKE_BIAS`

If either brake gate arrives, the state changes to `BRAKING_BURN`. If the gate
is no longer close and was not merely suppressed, it returns to `COAST`.

## BRAKING_BURN

`BRAKING_BURN` arrests vertical speed and kills most horizontal velocity. It
uses the scheduled descent speed for the current height and computes a
vertical throttle with `lmVerticalThrottle()`. If the craft is falling much
faster than the schedule, it commands full throttle.

When horizontal speed is still above `APPROACH_HSPEED` and there is enough
height, it adds a horizontal-kill throttle between
`LANDING_HKILL_THROTTLE_MIN` and `LANDING_HKILL_THROTTLE_MAX`, scaled by how
far above the approach speed it is. The commanded throttle is the larger of
vertical throttle and horizontal-kill throttle.

The state exits when the descent is captured and horizontal speed is low:

- if within `VERTICAL_RADIUS`, go directly to `VERTICAL_DESCENT`
- if outside `APPROACH_RADIUS`, go to `APPROACH`
- otherwise go to `TARGET_REFINE`

It can also go to `TARGET_REFINE` once the approach corridor is captured
within `APPROACH_RADIUS`, or to `VERTICAL_DESCENT` on a low vertical gate when
targeting is absent or horizontal speed is already low.

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

It advances to `APPROACH` when the flat position error is under 5 m and
horizontal speed is below `LANDING_TARGET_REFINE_HSPEED`. It gives up and
drops to `VERTICAL_DESCENT` if it times out
at `LANDING_TARGET_REFINE_MAX_TIME` or if a climb guard trips.

## APPROACH

`APPROACH` translates toward the final target while continuing a controlled
descent. Desired horizontal speed is the minimum of several caps:

- `MAX_APPROACH_SPEED`
- a stopping-speed limit based on remaining distance outside
  `VERTICAL_RADIUS`
- a time-to-hover limit so the craft can arrive before reaching `HOVER_ALT`
- an altitude cap that fades approach speed out as height approaches
  `HOVER_ALT`

Steering is `lmApproachSteering()` toward the target at that desired speed,
while throttle follows the vertical descent schedule.

It enters `HOVER_REFINE` in three cases:

- it is inside `VERTICAL_RADIUS` with horizontal speed below `VERTICAL_HSPEED`
- hover refinement has not yet happened and terminal altitude is within
  `LANDING_HOVER_REFINE_LEAD_TIME`
- bottom radar altitude is at or below `TERMINAL_ALT`

## HOVER_REFINE

`HOVER_REFINE` is the last target-selection and settling state. On first entry
it performs another terrain check, temporarily reducing `TERRAIN_CHECK_RADIUS`
to 20 m. This allows a small final shift to a flatter nearby patch after the
craft is close enough that the initial grid may no longer be ideal.

It then translates gently to the refined target. Desired horizontal speed is
limited by:

- `LANDING_HOVER_REFINE_MAX_SPEED`
- distance times `LANDING_HOVER_REFINE_SPEED_GAIN`
- a stopping-speed estimate using 35 percent of max acceleration

The approach steering target weight is increased by
`LANDING_HOVER_REFINE_TARGET_WEIGHT`, making the hover correction more eager
to remove residual position error. Vertically, the state remembers the bottom
radar altitude at entry and tries to hold it, with vertical speed limited by
`LANDING_HOVER_REFINE_ALT_VSPEED` and gain
`LANDING_HOVER_REFINE_ALT_GAIN`.

The default exit condition is intentionally tight because it uses the minimum
of the accept and settle values: distance within 5 m and horizontal speed
below 0.3 m/s. When that is achieved, `HOVER_REFINED` is set and the state
moves to `VERTICAL_DESCENT`.

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
| braking | `LANDING_HORIZONTAL_ACCEL_VERTICAL_BUFFER` | 0.1 | Extra vertical acceleration reserved over gravity |
| braking | `LANDING_HORIZONTAL_ACCEL_FALLBACK_FRACTION` | 0.1 | Low-TWR horizontal acceleration fallback |
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
| hover | `LANDING_HOVER_REFINE_LEAD_TIME` | 30 s | Start hover refine before terminal |
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

The important design idea is that early targeting is intentionally not
pinpoint. The deorbit aims at a downfield phantom impact so powered descent
has room to work. Coast MCC tightens that phantom lead. Braking spends the
horizontal energy. Target refine and approach convert the remaining miss into
a controlled hover. Hover refine picks the final local patch, and vertical
descent finishes the landing.
