# Deorbit, landing, ascent and rendezvous validation

Improve the complete sequence against repeatable flights, starting with
airless bodies. A plausible maneuver node or a successful touchdown alone
does not establish fuel efficiency or a viable return.

## RO9 evidence, 2026-10-16

The operator reports a successful Mun transfer after increasing the burn
instruction budget. During LAND_DEORBIT, the burn appeared to finish with
about 10% throttle remaining; the operator intervened. After the band reboot,
BRAKE began almost immediately, arrested velocity above 14 km and handed to
APPROACH. At about 13 km, APPROACH maintained roughly 35% throttle,
54.96 m/s horizontal speed and -5.89 m/s vertical speed. At that descent
rate, 13 km would take about 37 minutes. About 960 m/s remained after BRAKE.

The final outcome, initial gate reason, thrust/acceleration and post-deorbit
impact coordinates were not captured. The proposed connection between the
deorbit overburn and the target miss remains a hypothesis. Source inspection
did establish two gaps:

- The compact deorbit executor waited one tick and released throttle without
  checking physical thrust. It also tapered against a fixed 0.4-second horizon.
- Horizontal range could start braking for a passed target or high above the
  vertical stopping gate. BRAKE and TARGET_REFINE could enter APPROACH at any
  altitude, where descent was slowed to buy lateral travel time.

The shared cutoff and high-altitude handoff changes have offline regression
coverage. They are not yet validated in this RO9 flight. A low-TWR craft
arresting substantial horizontal speed can legitimately need a high ignition
altitude; height alone is not an ignition criterion.

## RO9 approach evidence, 2026-10-17

After a completed deorbit, the operator reported `Must attach node first`
at the compact executor's steering-lock line. kOS evaluates system locks
as callbacks; the node wrapper throws that error when BURNVECTOR or DELTAV
is read after REMOVE. The locks now use cached values, and the executor
releases its own steering trigger before removing the node. Physical cutoff
checks remain active. Cached throttle commands expire after 0.5 seconds
without a fresh publication; the compact burn also uses the scoped CPU
floor and restores it at cutoff/reboot. A fixture evaluates deferred callbacks after node
removal, including callbacks queued before cleanup. Radio loss can delay
archive-dependent band loading; it does not explain this node exception.

On the resumed descent, braking reportedly started around 12 km, captured
horizontal speed near 20 m/s, and handed to APPROACH. The reported display
was `bottom=2504`, `d=79622`, `hs=7.2/7.1`, `vs=-0.3/-0.3`: an approximately
80 km target chase. The initial brake-gate values remain unavailable. A
400 m local terrain adjustment cannot account for this distance; the search
is bounded to its configured grid (up to the square's diagonal).

Terminal admission used the smaller of hull clearance and height above the
target's terrain elevation. A distant high site could therefore admit
APPROACH while local clearance was still 2.5 km. Admission now uses hull
clearance. The conservative smaller height remains in the stopping envelope,
preserving elevated-terrain protection. COAST hands to BRAKE_ALIGN, which
remeasures the gate before thrust. Geographic ignition requires alignment
within 15 degrees; an already urgent vertical envelope can still start
emergency arrest without an artificial wait. The cause of the 12 km ignition
has not been established, and its conservative stage/terrain gates remain.

RO8/RO9 Mun/Minmus economy profiles now enable `LANDING_FLEXIBLE_SITE=1`.
An actual ballistic miss beyond the existing 20 km assist corridor triggers
a nearby-site review before descent or after horizontal capture. Inside the terminal corridor, an
estimated lateral translation/arrest time beyond
`LANDING_APPROACH_MAX_TIME` (120 s) triggers the same review. This estimate
is not a guaranteed touchdown deadline or a fuel budget. Replacements start
at the actual timed Trajectories impact, receive coarse and fine terrain
checks, and must pass slope and sunlight requirements. Kerbin view is optional
for post-deorbit diversions by operator request; loss of a radio link alone
must not abort an otherwise acceptable autonomous landing. Terminal replacements
must also fit the time estimate. Failure requests manual review with checked
cutoff, rather than silently accepting an unsuitable site. Precision
profiles retain their target and existing correction policy.

Accepted diversions preserve unrelated mission overrides and the return leg.
Original requested coordinates remain in the active descent context for the
touchdown miss report. Fine surveying now finishes before powered guidance,
instead of blocking with a stale positive command in APPROACH. A scoped
2000-IPU landing budget reduces scheduling delays; normal cleanup or the next
boot restores the previous value. No KSP loop-latency bound is claimed.
Powered descent loads shared light geometry, without orbital site search or
deorbit-node checks (`landing_light_math` is split from `landing_light`).

`last_landing_brake` saves reason, hull/target-relative heights, target
elevation, speed, gate flags, current/next-stage acceleration, stage and IPU.
`cmd/landingcheck.ks` prints this record and engine limits. Source-driven
regressions cover the reported geometry, deferred node callbacks, diversion
rejection gates, preserved return overrides and CPU recovery. These changes
still need KSP validation from a named pre-deorbit quicksave.

## Radio margin and partial-throttle braking, 2026-10-17

The subsequent economy flight rejected a flat fallback (grade 0.006) because
Kerbin was at -1.11 degrees. The operator explicitly accepted that elevation
and prioritized autonomous landing after deorbit over radio availability.
`LANDING_DIVERT_REQUIRE_KERBIN=0` is now the default. Original site selection
still requires Kerbin view: economy profiles now require 15 degrees and favor
30 degrees or more. Sunlit hours are eligible above a 5-degree Sun minimum;
15-degree morning light is a soft preference, subordinate to radio margin.
Similar radio sites favor rising over setting light. A source-geometry/ranking
fixture chooses a 47-degree-Kerbin afternoon site over a 19-degree-Kerbin ideal
morning site. The orbital search remains bounded to four orbits. Direct view
does not establish antenna range, terrain clearance to Kerbin, or network routing.

The operator also reported BRAKE at about 68% throttle. This matches the
current controller: net velocity-arrest acceleration is 0.8 * (maxAcc - g),
then the vector receives gravity support before conversion to throttle.
High horizontal speed requests zero vertical speed. This is conservative
velocity arrest, not an optimized full-thrust suicide-burn trajectory.
In a source-driven flat, constant-g example (Mun g=1.63, TWR=4, horizontal
speed 400 m/s and descent 60 m/s), it commands 68.34% throttle and a net
3.912 m/s^2 arrest budget. An ideal full-thrust vector could provide
6.076 m/s^2 in that direction, reducing the ideal velocity-stop duration from
103.4 to 66.6 seconds. Those are illustrative model values, not measured RO9
thrust or predicted flight savings.

A full-thrust redesign must solve the vector thrust/gravity budget and use
the same model for ignition height, steering and taper. It must retain
reaction/staging time, terrain clearance, changing mass/thrust and cutoff
checks. Merely forcing the existing command to 100%, or dropping the 20%
reserve without validating its purpose, is not that redesign. No braking
physics or safety margins changed in the radio-priority work.

### Economy descent instead of a hovering brake

The operator subsequently rejected the sustained altitude-supporting brake.
Economy profiles now enable `LANDING_ECONOMY_BRAKE=1`. Their geographic
horizontal/overshoot triggers are suppressed: the unchanged vertical stopping
envelope already includes full horizontal speed, terrain, weak-stage thrust
and latency. These geographic triggers protected precision targeting; they
are not needed to enforce that combined collision-stopping envelope for a
flexible-site landing. Other profiles retain their original triggers.

The high-horizontal-speed controller now solves the exact vector thrust bound
`|g*up + aNet*direction| = aMax` instead of using the triangle-inequality
`aMax-g` bound for actuation. A bounded search chooses a downward flare-entry
speed that fits the remaining altitude, rather than unconditionally requesting
zero vertical speed. It reserves a conservative final flare with the existing
80%-net acceleration envelope, residual lateral velocity, burn margin,
reaction/staging time and clearance. The same 80% ignition envelope remains.
The main burn can therefore use full thrust without silently removing those
margins. Tail taper and the prohibition on engine-down steering remain.

The altitude predictor uses the weaker planned stage. Its net-acceleration
bound is the smaller of the exact limits at zero and maximum effective
gravity: the limit is concave in gravity, so this bounds centrifugal support
disappearing during braking. A pure-horizontal-thrust bound prevents the
selected downward target from demanding an engine-down acceleration.
An already urgent or underpowered state can still request full velocity
arrest; continuing descent is not allowed to override terrain safety.

In a paired flat, constant-g fixture (Mun g=1.63, TWR=4, initial hs=400,
vs=-5, height=5000 m, target downrange=4000 m), high-altitude near-hover fell
from 45.4 to 0 seconds. Braking-to-approach commanded impulse fell from
534.1 to 440.6 m/s. This is not whole-landing fuel use or measured RO9 savings.
Source-driven cases include three seconds of delayed ignition, a transfer-to-
weaker-stage interruption, Minmus gravity and changing centrifugal support.
Vector/flare property checks retain thrust bounds, no engine-down command,
the weaker-stage flare budget and the unchanged ignition gate. The model
omits terrain meshes, attitude dynamics, engine spool and the kOS scheduler;
KSP quicksave testing remains required.

## End-of-burn contract

`lib/thrust_cutoff.ks` owns `thrustCutoff()` and `thrustCutoffOk()`.
The burn owner must first stop publishing positive throttle. The checker:

1. Locks cooked throttle to zero and clears raw and pilot throttle settings.
2. Waits for physics and checks actual thrust, rather than available thrust.
3. Attempts shutdown of active, throttleable, shutdown-capable engines if
   thrust persists beyond 0.25 seconds by default; the verification window
   is bounded. Solids and reserved inactive engines are not shut down.
4. On release, clears throttle again and checks another physics step.
5. Saves `last_thrust_cutoff`. Forced shutdown or a failed stop requests a
   mission hold; neither is a successful burn. `nextPhase` respects the hold.

`thrustCutoff(FALSE)` keeps the zero lock for a caller retaining control.
Landing guidance rebinds its command-variable lock only after successful
verification. The maneuver executor retains its configurable cutoff delay,
independent impulse cap, stale-command guard and failed-node retention.
`cmd/burnreport.ks` prints the shared cutoff evidence as well as maneuver data.

This is a checked handoff, not a continuous interlock after release. It
requires kOS/KSP to keep running. Another controller can later issue a new
command; enforce one active throttle owner per vessel. Aircraft/drone manual
assist disengagement is a separate control handoff, not an end-of-burn event.
An abort action group must still execute even if a solid cannot be stopped.
The atmospheric descent watchdog also retains its emergency descent/reboot
fallback after a failed cutoff; this is not a successful planned handoff.

## Airless sequence: acceptance before optimization

| Segment | Required handoff | Measurements and next improvement |
|---|---|---|
| Deorbit planning | Feasible landing corridor, terrain clearance, sufficient fuel for landing and the intended next leg | Predicted impact, stopping footprint, stage-dependent thrust/mass, total descent/ascent/reserve budget. Current targeting validates a ballistic impact; a powered landing footprint is still needed. |
| Deorbit execution | Residual within tolerance and physical cutoff verified | Requested versus delivered dV, loop interval, final throttle/thrust, actual impact shift after cutoff. Revalidate against the actual orbit; never substitute the planned trajectory. |
| Coast and brake | Coast without thrust until the combined velocity/terrain envelope requires ignition | Gate reason, radar/hull clearance, horizontal/vertical speed, current and reserved acceleration, ignition height, burn duration and dV. Preserve terrain, staging and latency margins. |
| Terminal landing | Enter approach/refinement within the terminal altitude corridor, then settle on terrain | Target miss, approach duration/dV, final drift, slope and touchdown speed. Reachable-site selection and an explicit approach fuel/time budget remain work; the altitude guard alone cannot guarantee a cheap landing. |
| Surface ascent | Confirm a usable orbit before advancing | Fuel before/after, gravity and steering losses, stage events, target/actual Ap and Pe, circularization overshoot, verified cutoff. Optimize against a measured baseline, not just a lower parking altitude. |
| Rendezvous | Accept both separation and relative velocity | Predicted/actual closest approach, closure rate, correction spending, cutoff and remaining docking reserve. MATCH currently requires separation within its configured radius and relative speed below 0.2 m/s; it is not a docking controller. |

Distinguish a required site from an economy landing region. A precision
mission must retain its requested target and report failure if unreachable.
A flexible-site mission should select a reachable, terrain-checked site
inside the powered landing footprint, rather than spend the return reserve
backtracking to an arbitrary old point. That selection policy is not supplied
by the current high-altitude guard and should be implemented before claiming
end-to-end economy performance.

## Repeatable flight campaign

Use a named quicksave before deorbit, with the same craft, mass, stage layout,
orbit, target and code revision. Preserve each flight's logs and cutoff report.
Record UT, phase/state, radar/hull altitude, surface velocity components,
command/raw/pilot throttle, actual/available thrust, mass, stage, remaining dV,
target distance and the gate reason at transitions. Measure maximum loop delay
as well as its typical value; offline fixtures do not model the kOS scheduler.

Run nominal cases first, then perturb one input at a time: short high-TWR
burns; one or several delayed control updates; residual/reversal errors;
deorbit undershoot and overshoot; low-TWR next stages; separated ignition
slots; lost thrust; a reboot in each coast/burn; terrain above the target;
and rendezvous with a small range but excessive relative speed. Include a
cutoff fault and confirm no automatic success or phase advance follows it.

Compare total fuel/dV for the entire leg, minimum clearance, touchdown and
orbit accuracy, maximum loop delay and completion of the return/reserve
contract. Accept the safety and restart cases before tuning margins. For
efficiency changes, compare paired runs from the same save and alter one
policy at a time. Keep raw observations separate from inferred causes.

## Atmospheric extension

Reuse the cutoff, fuel ledger, state-transition evidence and orbital
rendezvous contracts. Do not reuse the vacuum braking model as an entry
predictor. Add measured drag/lift behavior, dynamic pressure, heating,
attitude authority, engine performance versus pressure, chute deployment
limits and staged entry configurations. Validate ballistic entries first,
then aerodynamic guidance, powered corrections and terminal landing, before
coupling them to launch and rendezvous.

The atmospheric `KSC_DEORBIT` handler remains missing and guarded. Restore
and validate that path before promising a complete precision atmospheric
return. A deorbit node and the existing shallow-entry corridor are not proof
of thermal survival or a safe landing.
