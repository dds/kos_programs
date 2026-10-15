# Maneuver execution and B-plane review — 2026-09-16

The code defects below are fixed in this revision. The changes have numerical
and structural checks, but have **not been flight-tested**. There are no saved
flight logs in this checkout establishing which defect caused a particular
reported overburn.

## Burn execution

- The overshoot checks compared `nd:BURNVECTOR` with `nd:DELTAV`. These are
  [aliases](https://ksp-kos.github.io/KOS/structures/vessels/node.html), so
  their normalized dot product could not become negative. The checks now
  compare the remaining vector with the saved ignition vector.
- `_gacc()` used `SHIP:POSITION` as the radius vector. kOS positions use a
  [ship-centered origin](https://ksp-kos.github.io/KOS/math/ref_frame.html).
  Gravity now uses `SHIP:POSITION - SHIP:BODY:POSITION`, averaged over each
  integration interval. Without this subtraction, gravity opposing a burn
  could make the fallback dV integral undercount thrust and keep burning.
- The old throttle law commanded full thrust whenever more than 10 m/s
  remained and imposed a 2% minimum during trim. The new law also accounts
  for acceleration and the measured loop interval, with no minimum throttle.
  For example, 11 m/s remaining at 100 m/s² with a 0.2 s loop previously
  commanded a 20 m/s impulse; the new command delivers 2.2 m/s in that model.
- Completion decisions cut throttle before logging. Cleanup clears
  `PILOTMAINTHROTTLE` and lets the zero lock reach a physics update before
  restoring engine thrust limits. A zero lock alone does not clear the
  [pilot setting restored when control is released](https://ksp-kos.github.io/KOS/commands/flight/pilot.html).
- The start-time estimate now follows the small-burn thrust-limit changes.
  Previously the fallback estimate centered the burn using the old thrust.

## B-plane planning

- Check the current arrival patch's Pe, inclination, and requested LAN
  before creating a correction node or reusing an old correction. This
  check uses patch elements directly: `POSITIONAT(SHIP, t)` includes
  [pending maneuver nodes](https://ksp-kos.github.io/KOS/commands/prediction.html)
  and is unsuitable as the geometry for a no-burn decision.
- Unspecified LAN is unconstrained. With both inclination and LAN specified,
  use the angle between their orbital planes; equatorial LAN cannot create
  a spurious correction. Preserve the existing closest-achievable-plane
  policy when the desired plane is tilted away from the incoming asymptote.
- Score only error **outside** `BPLANE_PE_TOL` and `BPLANE_ANG_TOL`. A solution
  inside both tolerances now wins over one with exact Pe but unacceptable
  plane error. Stop fallback probing when a candidate enters the corridor.
- Choose the plane-normal mirror closest to the measured reference. The old
  90-degree test chose the wrong mirror for some low-inclination orbits:
  at 30 degrees inclination the wrong candidate is only 60 degrees away.
- Keep an acquisition node if its burn creates an acceptable encounter.
  Previously that branch could remove the necessary burn as though the
  unburned trajectory already had the newly acquired encounter.

Tolerance defaults remain 2 km in Pe and 0.2 degrees in plane angle.

## Validation and next flight

Local checks covered balanced delimiters, whitespace, 150 throttle impulse
bounds across acceleration/loop-time/residual combinations, five synthetic
burns through cutoff, plane-angle edge cases (including LAN wrapping and
equatorial targets), and admissible-versus-inadmissible corridor scoring.
These check equations and source structure, not KSP physics or kOS execution.

Flight checks still needed:

1. A short correction and a high-thrust burn: confirm cutoff without chasing
   a reversed residual. Save `BURN tick` and `STATS burn result` lines.
2. A fixed-vector radial correction on an eccentric orbit: compare `applied`
   with the requested dV and inspect the resulting actual trajectory.
3. Start with nonzero pilot throttle; complete/abort a burn and release kOS
   control. Confirm thrust stays off after engine limits are restored.
4. Enter BPLANE and REFINE_BPLANE with an already acceptable arrival,
   including a stale correction node. Expect the current-trajectory skip
   message and zero additional burns.
5. Use an inclination-only target with a different LAN, then a constrained
   LAN target: only the latter should need a LAN correction.
6. Acquire a missing encounter into the corridor. Confirm the acquisition
   node remains for execution, then remeasure after the burn.

## RO6 Minmus flight follow-up

The next flight reported a transfer cutoff with about 5 m/s left, a
mid-latitude arrival instead of polar, and impact during **Minmus CAPTURE**.
The earlier changes had left these separate problems in place:

- `applied-node-trim` declared success at 98% integrated dV with up to
  5 m/s of node residual. Both running and paused versions are removed.
  Ordinary node burns now trim to an absolute 0.05 m/s, including the
  throttle tail. Percentage-based completion, the sub-1 m/s angle shortcut,
  and multi-m/s rebound acceptance no longer report success. A stop outside
  tolerance returns failure for replanning. The existing fixed-vector
  fallback still uses integrated dV when node data cannot be trusted.
- `phaseCapture` overwrote its 35 km fallback with unset `TARGET_AP = -1`.
  `planCapture` then treated -1 metre as the opposite apsis of the desired
  ellipse. Starting at 50 km Pe, that retrograde burn makes the burn point
  the new Ap and puts the new Pe **one metre below the surface**. Preserve
  the fallback when Ap is unset, reject negative targets in the planner,
  and clamp targets below arrival Pe to a circle at arrival Pe. Verify the
  node predicts a bound orbit above the surface and check the actual orbit
  after execution. The other planner caller, Duna capture assist, now handles
  a rejected node too.
- Inclination-only B-plane targeting was still constructing its target
  normal at the measured LAN, although LAN was unspecified. For a polar
  target this could invent an infeasibility and switch to Pe-only correction.
  With free LAN, intersect the requested inclination cone with the plane
  perpendicular to the incoming asymptote, choosing the closer valid normal.
  Keep explicit-LAN targeting separate. Every incoming asymptote can lie in
  a polar plane; it need not lie in the polar plane at the old LAN.
- `RO6/minmus_polar_orbit_return` now specifies `TARGET_AP = 50000` and a
  `SHAPE` phase targeting 50 x 50 km at 90 degrees before science operations.
  Capture alone preserves whichever arrival inclination BPLANE achieved.

Follow-up numerical checks reproduced the -1 metre capture Pe, checked
unset/below-Pe/circular/elliptical target handling, ran four burn tails from
5 m/s to <=0.05 m/s without overshoot, and checked 152 free-LAN normal
candidates for unit length, requested inclination, and perpendicularity to
the incoming asymptote. Structural checks also pass. These follow-up fixes
still need an in-game RO6 Minmus flight; they are not yet flight-proven.

## Transfer overshoot after tighter trimming

The following flight reported about 1 m/s of transfer overshoot. Without
the final burn trace, its exact cause is not established. Inspection found
a timing hazard the earlier constant-loop-time numerical checks missed:
`mLog` calls `archiveLog()` for every message while connected, and
`archiveLog` reads and copies the entire flight log. The executor logged
`BURN tick` between measuring residual dV and updating `throttleCmd`.
Its throttle lock simply repeated that command during the intervening work.
Using the preceding loop's duration could not protect against a new stall.

Ordinary node burns now use `_burnNodeThrottle` from `LOCK THROTTLE`.
[kOS evaluates cooked control locks every physics tick](https://ksp-kos.github.io/KOS/commands/flight/cooked.html).
The helper reads the live node vector and available acceleration, limits
throttle using a physics-tick horizon, and latches zero when the residual
reaches tolerance or reverses. No waiting, logging, state-file writes, or
staging runs inside that helper. The existing fixed-vector/integrated-dV
fallback retains its separate throttle path because its node is unreliable.

Running burn traces now print to the terminal and keep only the latest
20 samples in memory. They are written to the flight log after throttle is
zero and a physics update has elapsed. Samples include their original UT,
requested and live throttle, loop interval, and throttle-lock interval.
`STATS burn cutoff` records the latched cutoff time/residual and subsequent
residual sample. Staging also cuts throttle before its status logging.

`python3 scripts/check_burn_timing.py` reproduces a -1 m/s overshoot from a
stale command held for one additional second. It evaluates the new source
throttle expressions in 72 synthetic cases with different accelerations,
physics steps, main-loop stalls of up to five seconds, and zero or one
physics tick of actuator delay. All stop with a positive residual no larger
than 0.05 m/s and remain off if the residual later grows. The script also
checks reversal, invalid telemetry, pause/resume, no-thrust behavior, and
the lock/logging integration points. It is a numerical scheduling model,
not a kOS runtime test; engine response and actual flight behavior still
need confirmation.

## Launch timing and stage continuity

PRELAUNCH now persists a compact `launch_window`; the shared
`launch_window.ks` handles the final wait after the ascent band has loaded.
Missed plane windows select the next reachable crossing and its signed
inclination; other timed windows return to PRELAUNCH. The immediate option
explicitly selects due east and clears the timed-plane intent. Geometric
lead defaults to zero instead of absorbing an assumed 145 seconds of
startup/ascent latency; profiles can override it for measured ascent bias.
PARK logs the true mutual plane angle, and liftoff logs planned/actual UT.

The reported partial Minmus departure is consistent with the old executor
staging once, waiting 0.7 seconds, then aborting on no thrust. Without the
flight log that cause is not confirmed. Stage recovery now advances only
as far as a surviving, unignited next engine, allowing separate decoupler
and ignition slots with a bounded wait. Active non-flamed-out engines must
be exhausted first. After staging, steering is reacquired and live node
residual/acceleration are refreshed; the original node and applied dV stay
intact. Traces record stage events and residuals without archive I/O during
the burn. Stage/attitude recovery failure preserves the node. A persistent
ignition marker prevents XING from deleting an interrupted departure and
replanning it as an unflown parking-orbit maneuver, including after reboot.

Follow-up flight feedback reported the specific `no-thrust` abort. The
executor sampled acceleration twice: a positive sample skipped recovery,
then a zero sample after fuel exhaustion aborted directly. The burn now
uses one acceleration sample to select recovery/throttle, with any later
loss returning through recovery on the next pass. The physics-tick throttle
governor still observes live acceleration. Recovery also accepts an inactive
engine in the current staging slot and explicitly activates it once, stops
automatic staging at that engine, and logs engine eligibility/stage events.
After automatic recovery stops, a 120-second live wait detects manual
staging/activation without discarding the executor's node or integrated dV.
The remaining hold after timeout/abort/reboot is intentional; the new
`cmd/resumeburn.ks` gives the operator an explicit XING continuation path
using the retained live residual, without missed-window deletion. It checks
node time/body and alignment; it cannot undo trajectory error accumulated
during a long interruption. Older saved burns lack the new body marker.

The local transfer scan no longer exits after six encounters. Safe direct
encounters inside the correction corridor rank by departure dV, and a
better coarse candidate survives a worse refinement. This remains a
bounded departure search, not a total ascent/transfer/capture optimizer.

Validation: `python3 scripts/check_burn_timing.py` covers the live throttle
tail, and `PYTHONDONTWRITEBYTECODE=1 python3 scripts/check_launch_and_staging.py`
checks 450 plane crossings against an independent plane equation, true
plane-angle cases, engine/stage predicates, and nine synthetic 950 m/s
burns using 100 m/s from the insertion stage before upper-stage ignition
delays of 0.5, 2, or 6 seconds. These checks evaluate source expressions and
integration guards; they do not execute a kOS VM or simulate KSP separation,
engine modules, or MechJeb ascent. Required flight checks: both Minmus plane
crossings, a reboot/warp-missed window, immediate-east launch, combined and
separate separation/ignition stages, final-stage exhaustion, and small-core
compiled storage. No new behavior here is flight-proven yet.
Recovery fixtures additionally cover a missed activation, delayed staging
readiness/ignition, manual activation after 15 seconds, event limits,
final-engine exhaustion, abort, and guards against the second-sample abort.
Flight-check manual recovery during BURN WAIT and explicit continuation
after TRANSFER HOLD with the updated library loaded.

## Low-thrust departure follow-up

Flight feedback confirms transfer staging worked, but the lander engine
took a long time to finish and appeared to overburn slightly. There is no
cutoff telemetry from that flight yet, so whether this was throttle latency,
node drift during a finite burn, or an attitude issue is not established.
The reported KSP-wide input freeze is also unconfirmed. The code did retain
control locks after an abort while follow-up phase logic ran; it now releases
both locks after the zero-throttle physics update, before archive logging.
This addresses script-held flight axes, not arbitrary KSP UI bugs.

The physics-tick governor now tapers along the current thrust-axis component
inside the existing near-cutoff guard, and latches a rebound measured from
the best powered residual. Coasting/staging resets the rebound baseline.
This prevents chasing transverse error through a useful-axis overshoot,
but does not make an impulsive node an exact finite-duration trajectory.
Residuals outside tolerance still use actual-encounter handoff or a hold.
Stage diagnostics now include approximate remaining burn seconds and time
past the node, to distinguish long burns from slow shutdown.

The separate `burn_departure_*` checkpoint closes the save gap between burn
cleanup and phase advancement. XING examines actual arrival geometry before
reusing a node from a flown departure and will not plan a second departure
if the encounter is absent. The existing BPLANE phase can attempt bounded
arrival correction after explicit `cmd/setphase.ks` selection, preserving
the mission's capture/science/landing goals. Older saves have no new marker;
their retained `burn_pending`/`burn_started` state and trajectory remain the
available evidence.

Checks now include 120 scalar tails down to 0.05 m/s², nine tails with a
4 m/s transverse residual, cumulative powered rebound, staging/coast
baseline resets, control-release ordering, and departure-marker save/phase
guards. These are source-expression/structural checks with synthetic physics,
not a KSP flight or an input-freeze reproduction. Still needed: a flight
with the new cutoff/control-release safeguards, its cutoff log, the new
departure checkpoint across reload, and compiled storage checks.

## RO8 flight result — 2026-10-12

The operator identifies this flight as `missions/RO8/minmus_landing_return.ks`.
Transfer staging succeeded, but the low-thrust landing stage's long burn
left a near Minmus approach without an encounter. After reloading into
XING and holding, switching to BPLANE successfully recovered the encounter.
The mission reached COAST_1HALF, with about four game days until midpoint
refinement. The hoped-for correction of at most 3 m/s is not yet measured;
capture, science, landing and return have not been confirmed.

This validates encounter reacquisition on the reported RO8 trajectory, not
the subsequent cutoff/input-lock changes or a complete mission. The planned
same-craft comparison is `missions/RO8/mun_landing_return.ks`; neither of
these flight reports refers to the Falcon mission profiles.

## RO9 reported continued thrust — diagnosis corrected, 2026-10-15

The operator initially reported the engine stayed on too long during Mun departure.
The resulting encounter had a 1,780 km periapsis; increasing the recovery
allowance to 300 m/s ran into the correction-plus-capture reserve. No cutoff
trace is available. The operator subsequently corrected the diagnosis: the
planned maneuver itself predicted about 2,200 km Mun Pe and went far beyond
the Mun's orbit. This is evidence of a bad departure plan, not proof of an
executor overrun. The following safeguards remain useful independent defenses.

`executeManeuver` now applies an independent live guard to both normal-node
and fixed-vector burns. It integrates actual `SHIP:THRUST / SHIP:MASS`, caps
delivered dV at the ignition request plus max(1%, 0.05 m/s), and retains that
budget through staging. Positive commands older than one second and ABORT
also latch zero. This is independent of node residual and main-loop progress,
but not independent of the kOS scheduler or KSP physics. A legitimate finite
burn that needs more impulse may stop early rather than automatically exceed
the cap.

Cutoff holds zero through physics updates, checks actual thrust, and attempts
shutdown of active throttleable engines that still thrust after 0.25 seconds.
The verification is bounded and reports failure if thrust persists. Engine
shutdown uses the documented [kOS engine controls](https://ksp-kos.github.io/KOS/structures/vessels/engine.html).
No automatic restart follows this emergency shutdown inside the verifier.
Controls are released before state/log I/O. `last_burn_report` is saved before
trace flushing and survives phase reboot; `cmd/burnreport.ks` loads its own
preamble to display it. The measured impulse ends at the live guard's last
sample, so it does not include any subsequent shutdown tail. `cmd/logs.ks`
now loads its preamble too, allowing current-boot log export from the prompt.

`python3 -B scripts/check_burn_watchdog.py` runs the actual helper bodies
against frozen-residual, stalled-main-loop, ABORT, staging/mass-change,
same-timestamp and stubborn-thrust fixtures. The existing burn-timing and
launch/staging suites also pass. These checks do not reproduce the actual
game failure. Still required: compiled storage verification and an observed
flight with its saved report, particularly a stage transition near cutoff.

## Local departure periapsis contract

The economy path called `newtonTarget(..., "PE", 0)` instead of targeting
the requested capture altitude. It ignored convergence and returned any
remaining encounter. The plane-requested path could likewise accept a Pe
almost as large as the entire target SOI. This let a cheap grazing encounter
become a departure burn even when downstream corrections were unaffordable.

Local departures now refine the requested Pe using finite differences on all
three node axes, with a minimum-norm update and backtracking that requires an
improving direct encounter. The 100 m/s default cap applies to the vector
change from the raw departure seed, not to total injection dV or a late MCC.
Probe values are read before restoring the node, including when the game's
patch object updates in place. Failed trials restore the best node.

The independent final gate requires a direct, positive target Pe within 2 km
of CAPTURE_PE; it aims within 500 m while solving. Unconverged/absent/impact
encounters cannot be returned as executable plans. Saved unburned XING nodes
pass the same gate; flown or explicitly resumed interrupted burns continue
to use their recovery rules. No new forced plane or arbitrary apoapsis limit
is imposed. A high post-flyby apoapsis alone does not diagnose a bad approach.

`python3 -B scripts/check_departure_pe.py` executes solver and plan-gate
bodies against synthetic responses, including a live patch object and an
analytic 2,200 km hyperbolic Pe with zero prograde sensitivity. It checks
convergence, bounded vector changes, lost probes and rejection despite a
refiner returning a node. These are not flight tests or a reproduction of
the deleted maneuver. The scan still optimizes a raw seed, so global mission
fuel optimality is not guaranteed.

## Ignition follow-up — 2026-10-15

The operator reports the revised local departure planned a good encounter,
but ignition entered `BURN WAIT`. That message specifically comes from the
no-usable-thrust recovery path; engine/stage telemetry is still needed to
explain why. `cmd/burnreport.ks` now distinguishes the latest completed
cutoff from the saved current attempt and displays current engine activation,
flameout, limiter, available/possible thrust and staging fields without
changing the craft.

Inspection also found a separate watchdog publication race: positive throttle
was assigned before its timestamp was refreshed. A cooked-control evaluation
between those statements could latch `live-command-stale` after a long
zero-throttle setup/recovery. The loop now computes the next command, refreshes
its timestamp, then exposes positive throttle. This does not explain entry
into `BURN WAIT`, but could prevent a recovered engine from starting afterward.
The source-driven watchdog fixture interrupts each publication operation in
both burn modes and confirms ignition succeeds while a real stale command
still latches zero. KSP validation remains outstanding.
