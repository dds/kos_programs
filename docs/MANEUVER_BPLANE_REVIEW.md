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
