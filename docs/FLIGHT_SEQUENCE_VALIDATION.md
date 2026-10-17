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
