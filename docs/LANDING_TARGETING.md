# Landing targeting and powered descent

This document explains the current automated landing path as implemented in
the `LAND_DEORBIT`, `LAND_ASSIST`, and `LAND` phases. It focuses on the
vacuum powered-descent stack: choosing a target, deliberately aiming the
ballistic trajectory beyond that target, shaping the coast, deciding when to
brake, and walking the final descent state machine down to touchdown.

On2026-10-21, the operator reported the first successful automated Mun
landing and return to a landing on Kerbin, using the newest RO9 economy
craft. Its reported checkpoints were497+654m/s remaining on the Mun and
430m/s before the final orbital circularization trim. This establishes a
working round-trip baseline. The run included debugging/reboots and a linked
RETURN_SETUP recovery; no final diagnostic archive or exact flown version
has been reviewed. It does not establish a fully unattended repeat, pinpoint
landing accuracy, optimal fuel use or validation of every subsequent fix.
The remaining priorities are powered-footprint targeting, stage-aware ascent
efficiency and repeatable offline/alarm handoffs.

Economy airless flights aim for a coast, one main coupled braking arc and a
gentle touchdown on a reachable, terrain/light-checked footprint. Hover and
large final translations are recovery tools. Geographic precision profiles
retain the longer target-capture sequence described below.

After the8926227 update, the operator reports a substantially better Mun
landing: a smart braking burn, descent onto the flat side of a crater and
excellent refinement. This is qualitative flight evidence for the revised
descent/recovery behavior; no corresponding diagnostic archive has yet been
reviewed. The operator subsequently reports896m/s remaining at touchdown;
target miss, hover duration and touchdown speeds remain unknown. This does
not establish an affordable return: the earlier illustrative877m/s parking
and departure estimate excludes finite-burn losses, and the direct-ascent
command is still a feasibility preview rather than flight guidance.
Because this retry started after deorbit, it does not validate
the new orbital powered-lead solve or establish whole-mission fuel savings.

The operator clarified that this flight was intended to reach the contract
site. Successful local-fallback descent is not a successful targeted mission.
Direct-return testing is deferred to the next craft. The fresh RO9 profile
explicitly sets `LANDING_FLEXIBLE_SITE=0`, retaining the locked contract site
and bounded nearby terrain refinement. `cmd/landfallback` remains a deliberate
recovery concession and now states that it permits replacing the contract
target. Its successful descent must not be used to mark orbital target
accuracy or the mission's landing contract as validated.

A subsequent new-style RO9 **Mun economy** flight has a separate return
propulsion stage. Operator-reported LKO values are3270m/s total, with1371m/s
on transfer3 before an883.1m/s departure,735m/s on lander2 and1165m/s on
return1. Component totals differ by1m/s through rounding. Crossfeed between
lander and return is disabled. Return1 is intended for liftoff; leftover2
fuel can also be used during ascent. Capture/corrections still draw from the
roughly488m/s transfer remainder, so these numbers do not certify landing
or return affordability. Flexible economy targeting remains enabled.

The operator subsequently reports touchdown of the newest Mun economy craft
with497m/s left in the landing stage and654m/s in the return stage:1151m/s
combined staged vacuum dV. The reported descent stopped short of the original
Trajectories target. No corresponding archive, final miss or hover duration
has been reviewed, and the code version has not been confirmed. The earlier
illustrative~877m/s ideal10km-parking/53km-Kerbin-entry route would leave~274m/s
for real ascent losses and corrections; this is a plausible return budget,
not a live solution or guaranteed margin. Surface-return setup retains the
active landing engine for liftoff by default and independent ascent staging
can shed it after exhaustion, so the497m/s need not be discarded before launch.
Return was still pending at this checkpoint; the later successful Kerbin
touchdown is recorded above.

The same craft subsequently reached a reported10673m apoapsis and8103m
periapsis with430m/s left before circularization. It announced a roughly1000s
wait with no maneuver node or KAC alarm. Ascent deliberately circularizes
directly, but the missing owned alarm was a defect. The wait now creates a
T-60 `Ascent circularize` KillWarp alarm, reuses it after replanning, cleans up
only that alarm, retains a clock fallback without KAC and settles warp before
the burn. Ignition UT, estimated duration/acceleration, stage and remaining
dV are included in the saved plan. The user's stage-TWR efficiency concern
is still open: the pitch law is unchanged. Per-stage usable acceleration/TWR
observations are now buffered and saved after verified cutoff for future tuning.

An offline RETURN_SETUP reboot then failed on an undefined handler; obtaining
a link and rebooting recovered the mission. Although the phase manifest
declares the correct provider, LAUNCH's cleanup set previously needn't retain
it. The shared conditional planner now includes return_setup and its config
for LAUNCH sequences with RETURN_SETUP, so a connected ascent boot caches and
keeps those files for the following offline handoff. Other launch sequences
retain their original dependency set. Return bindings use the scalar
`RETURN_SETUP_LOADED`, assigned only when the provider executes. Bare
`DEFINED phaseReturnSetup` is an ordinary-variable check across separately
compiled files and can falsely report unavailable even after a successful
load. A missing/stale provider still reaches the missing-handler hold; a
connected reboot is needed for the updated marker. The dispatcher binds only
the current phase, so this warning must not be dismissed as future-band noise.
No late library import resets return settings. These changes and the new
alarm still need native flight validation.

The distinction is visible in the upstream kOS
[compiler](https://github.com/KSP-KOS/KOS/blob/develop/src/kOS.Safe/Compilation/KS/Compiler.cs)
and [identifier lookup](https://github.com/KSP-KOS/KOS/blob/develop/src/kOS.Safe/Execution/CPU.cs):
user-function delegate lookups use a trailing asterisk, whereas a bare
cross-file identifier existence test need not use that function-pointer name.

The default landing floor0 can select1 after2 exhausts, potentially consuming
the dedicated return stage during descent. `cmd/landingstages.ks, 2` saves a
validated per-flight floor without changing the target, mission, node or
sequence. The operator must run it while idle before deorbit; no global
RO9 stage-number default changes. With the floor applied, landing can stage
3->2 but cannot select/ignite1. It cannot enforce fuel isolation through an
open crossfeed path or guarantee735m/s is enough for descent. Surface-return
setup clears the override and ascent retains its independent staging.

The bounded transfer-credit helper now accepts an extra inactive engine only
when it is explicitly excluded by that floor. Its fuel credit is still capped
by enabled propellant physically on discarded parts and stock stage dV;
reserved return tanks cannot increase it. The return wet mass remains part
of the lander acceleration calculation, and an active parallel engine still
rejects this simple model. Optional fueled-stage disposal remains conservative
about additional future propulsion. Three source cases exercise the reported
3/2/1 handoff and reservation, fuel exclusion and command refusal paths;
the later round trip is operator-confirmed, but its detailed staging trace
and the new role/reservation behavior have not been verified from an archive.

Hardware roles can now be explicit kOS part tags rather than saved stage
numbers. Put `return_decoupler` on the separator between the return craft and
landing engine/tanks/legs; put `lander_decoupler` on the separator between the
whole lander and transfer/carrier. Both are configurable tag names. The return
boundary alone is enough to derive the protected floor; the release tag
identifies hardware and validates relative order while still attached. Spent
carrier separators may remain attached without invalidating return protection.
The helper never fires an event. Future combined surveyor/lander deployments
still need release timing and CPU/mission ownership planned explicitly.

`landing_roles` is a small dependency of vessel_hardware, present in both
orbital landing and powered bands without pulling the FSM into deorbit.
Before a deorbit solve/execution or powered setup, it validates unique tagged
stock separators and, for a return boundary, a stageable unspent separator,
retained CPU, a lander engine on the discarded side and an inactive return
engine on the retained side. Its effective stage floor is the larger of the
manual setting and tagged return stage+1. Staging, activation and finite
transfer-credit filtering all use this same floor. The floor reads the live
part staging number and is reconstructed on reboot; derived stage numbers
are not saved as mission intent. Untagged craft keep legacy/manual behavior.

Bad tags hold an unflown orbital deorbit. During a committed descent, active
engine guidance continues with an urgent conservative future-thrust budget,
while automatic separation/activation is blocked. A metadata error cannot
silently make the stopping gate assume inexhaustible transfer thrust. This
cannot guarantee survival if usable fuel runs out; tag errors require repair.
All attitude, physical cutoff, stage readiness and settle checks remain.
`STATS landing roles valid=... floor=... returnStage=... releaseStage=...`
and readiness reports expose the policy. The3/2/1 example should show floor2,
returnStage1, releaseStage2. Correct tags remove the need for the numeric
`cmd/landingstages` setup; that command remains a per-flight fallback.

This uses the documented [kOS Part TAG/STAGE/DECOUPLEDIN interface](https://ksp-kos.github.io/KOS/structures/vessels/part.html)
and [Separator ISDECOUPLED/STAGED interface](https://ksp-kos.github.io/KOS/structures/vessels/separator.html).
The tests model those interfaces, not native part trees or flight timing.

The next RO9 fixed-site Mun run opts into `LANDING_POWERED_LEAD=1`.
The later measured ignition at control-height6101m/radar7977m,
hs516.1m/s/vs-44.9m/s, active44.68/plan2.72m/s2 and223.9m/s transfer credit
still fired on Hgate42847m with Vgate4775m false. Later, after separation,
BRAKE reported distance39974m, hs286.7m/s, vs-32.3/-32.1 and full throttle.
The engines work; these rows identify a range mismatch, not a zero-throttle
or stationary-hover failure. The remaining transfer fuel/height at the later
row was not supplied. This mission has only post-deorbit saves.

A conservative stopping envelope still owns the vertical collision deadline.
Geographic aiming now uses evolving fuel mass rather than a constant initial
acceleration. `landing_brake_fuel` snapshots one active and at most one eligible
serial landing engine, limiting enabled local propellant by mixture, rocket
equation and stock stage dV. Reserved return tanks cannot add fuel; their wet
mass remains carried. Solids, parallel/multimode engines, massless mixtures,
atmosphere, elective fueled disposal and ambiguous stage roles reject this
precision model. A final single landing stage is supported too.

`lmNominalBrakeRange` uses32 speed intervals with mass loss for supported
snapshots; its old16-bin constant-acceleration estimate is only a live fallback
for unsupported hardware. The snapshot is taken per stage and adjusted by
current mass, without extra per-tick tank scans. The H gate remains capped by
the old reserved bound. The V envelope, gravity/80% net reserve, latency,
terrain/hull clearance, stage floor and actual-facing cutoff are unchanged.

`landing_deorbit_lead` samples the attached node's native conic using numeric
POSITIONAT derivatives. Twelve bisections find ignition using the live fixed-site
H and V policies, including local terrain and H suppression. The deorbit impulse
is charged against both mass and current-stage fuel exactly once.
`landing_prediction` then integrates the shared live descent/thrust law in a
rotating body-fixed frame using midpoint steps, variable mass flow, dry-mass
jettison and the real two-settle staging interval. Cross-product handedness is
measured against native increasing longitude. Gravity, Coriolis and centrifugal
terms are physical; the controller's effective-gravity convention is retained.
Low-speed flare/coast continues until the braking capture conditions are met.
The forecast is bounded1024 steps,900 simulated seconds and20 execution seconds.
It is not an arbitrary-terrain touchdown or attitude-slew simulation.

Ballistic minus powered travel defines the phantom lead. Fresh passes refine
under the original64-trial cap, retro/normal/cross/FPA limits and final native
terrain/light/fuel checks. Model failure, exhausted local landing fuel, no coast,
nonpositive lead or no convergence retain orbit. No probes survive. New,
retained and pre-burn admissions share this policy. RO9's fixed-site Mun and
Minmus profiles opt in; economy missions remain flexible and do not opt in.

Flight and prediction share `landing_brake_math`; only orbital planning loads
the full integrator. A cheap32-bin fuel-aware geographic gate runs in flight,
not the numerical forecast. This separation preserves control cadence and
keeps the landing FSM out of the deorbit band. Independent inertial-frame RK4
fixtures agree within120m with the rotating midpoint forecast in the stated
case, and halving the forecast step changes capture position by less than40m.
These test the numerical model, not native execution or optimality.

The next targeted Mun attempt held on `powered-lead-not-converged` at54/64
trials. The operator read aim63610m, powered range20847m and ballistic
range84457m; these are consistent with the modeled phantom lead, not a request
to land63km from the site. The original loop stopped after three forecasts,
each followed by a possible refinement, leaving its third adjustment unchecked.
This could reject a converged node while native trials remained. The supplied
row alone does not establish whether that particular final node was acceptable.

The outer polish now uses the remaining64-trial budget and stops on fresh
acceptance or no improving node change. Each inner refiner reserves one trial
for the subsequent forecast. Geometry and the lead model are read from the
same newly attached probe; all probes are removed on rejection or acceptance.
`STATS deorbit powered-fit` records pass, downfield/aim/residual, cross-track,
rejection reason and count; the failure summary distinguishes budget exhaustion
from no improvement. Original retro/fuel/normal/cross/FPA, fixed coordinates,
terrain/light and final/pre-burn admission remain. Source regressions reproduce
a third-step success falsely held by the old loop, then freshly validate it at
53/64. A footprint-dependent model with the actual timing/normal Newton refiner
converges in seven forecasts at55/64, and a near-limit case uses trial64 for
validation after trial63 refines. Model failures, drifting/non-convergent goals,
no progress, missing impacts and insufficient validation budget still hold.
These are controlled source fixtures, not a replay of the native failed flight.

With the original nominal timing, the supplied ignition snapshot had a
geographic gate around23km versus43km previously, with identical vertical
safety values. That point-mass comparison was within700m only while forcing
the same three-second ignition and staging pauses assumed by the estimator.
An independent20m/s deorbit conic at15km Mun apoapsis derives about37km lead
rather than15km (exact value varies with terrain/hardware). These limited
checks do not establish native target accuracy, terrain clearance during the
powered arc, total landing fuel or minimum-dV performance. Flight validation
is still needed, including late descent-speed changes and rotation-induced
cross-track drift. No plan promises a high-precision touchdown from this model.

The following targeted run was described as about5km short; its newly supplied
archive `landingdiag_RO9_2157921508_boot_014_core.log` and boot sidecar quantify
4051m guidance miss at braking capture,320s /519.5m/s approach impulse and30s /
48.7m/s hover impulse. Touchdown was2791m from the requested point and2279m from
the refined guidance point (640m target shift). Physical touchdown is not a
successful pinpoint contract landing.

At ignition hs542.3m/s,vs-31.2m/s,ASL9522m,target elevation4113m, transfer credit
293.4m/s and current/weak acceleration40.18/2.45m/s2, the logged H gate was20637m.
It matches the older three-second nominal ignition/staging travel assumption.
The prior timing correction alone gives18396m; adding mass loss gives17494m.
Observed travel is approximately21103-4051=17052m. Do not attribute all the
range error to changing mass: both timing and mass contributed.

A flat-target-height controller replay with explicitly assumed transfer Isp345s
and lander290s predicts16738m and155s to capture, against154s flown. The actual
engine suffixes are absent from this archive, so this is not an exact replay.
It predicts end mass0.7196t versus0.7183t logged. New diagnostic engine rows
record exhaust velocity, thrust, fuel and discarded mass for future validation.
No5km offset, longer hover, weaker terrain policy or relaxed target tolerance
was added. The remaining fast-gate approximation, attitude pauses, actual terrain
and rotation-induced cross-track drift still need native target validation.

`STATS deorbit powered-lead` records aim, powered/ballistic ranges, ignition
state, post-deorbit transfer budget and computation elapsed time. Brake entry
persists `poweredLead` and `stopRangeError`; negative error predicts a short
capture. `brake-complete targetDist` plus the resident archived flight rows
let us compare this prediction against actual capture and terminal fuel.
No additional archive I/O or large scans run in the powered control loop.

The operator has allowed this already-committed craft to land away from its
contract site. `cmd/landfallback` saves flexible-site/descending-control
permission only from an airless suborbital LAND_ASSIST/LAND phase with zero
actual/raw/pilot throttle and Abort clear. It retains the return mission,
sequence and phase. Reboot applies the policy; existing provisional previews
and fresh reachability/clearance/20m-grade/light checks still select the site.
Normal/emergency slope limits are not changed. This is recovery permission,
not a guarantee that a nearby safe site exists or that a search cannot hover.
A rejected site still cannot silently become a landing target.

Automatic site selection now stays in a running orbital solar wait when no
ground-track point meets the light/radio policy (2026-10-21). Previously
`_confirmLandingTarget` yielded to Godspeed after this expected rejection.
The Minmus report, with its sunlit side facing away from Kerbin, should keep
the rejection and defer landing rather than abandon automatic progression.

`landingLitGroundTrack(TRUE)` reuses the normal ephemerides and planning
region/window checks for a coarse forecast beyond the nearby search. It
samples at most 512 epochs over the larger of eight vessel orbits, one
surface rotation or two moon orbital periods, stopping at the first eligible
sample. This can miss opportunities and does not identify the earliest
possible opening. It only schedules a retry; its coordinates are never
persisted as a landing target. Wake places the sample about two vessel
orbits into the normal search range. If the forecast finds no window, the
mission rechecks after roughly one sixteenth of that horizon, with at least
one vessel orbit between checks.

`landing_light_wait` persists mission/launch/phase/body, relevant light
policy, orbit plane/period, wake UT and its named KAC alarm. It installs the
alarm before solar setup, keeps the solar/clock loop running and repeats
the normal local search at wake. No KAC is required for the clock loop to
resume. Reboot keeps the pending deadline; an overdue deadline searches
immediately. Changed context cancels the old intent, and successful manual
`landlight apply` clears it. Preview/status do not enter this wait.

Only an uncommitted bound airless orbit with no maneuver/transition or
predicted Trajectories impact can enter the wait. Physical cutoff is checked
before solar coast. The shared coast wait has an explicit stay-in-body mode,
preserving the original body through slow solar setup and terminating on a
new node, departure, descent or abort. Solar/power health and the existing
auto-warp setting still govern warp. Invalid light configuration or frame
disagreement retains manual review. A real deorbit still needs fresh
terrain, reachability, light/radio, fuel and execution admission.

New `STATS landing-light retry-scheduled` and `wait` rows record the rejection,
estimated opportunity, coarse step, wake time and alarm. Search rows identify
forecast versus normal mode and its sampled interval. The ETA is a retry
estimate, never a guarantee of landing or a continuous surface link.
Eight new source cases cover a modeled native-frame inclined Minmus
opposition through a fresh post-wake search, KAC/no-KAC continuation, reboot,
stale/overdue intent, guards/interruption, fallback cadence, power/warp and
CPU restoration. The full routine suite has 243 cases across 39 scripts;
native kOS execution, KAC UI and actual warp behavior await flight testing.

The first post-update Minmus reboot returned immediately from a 15 km
circular orbit with no search statistics. The operator then confirmed
`PRINT ABORT.` returned TRUE. The selector's `UNTIL ABORT` correctly skipped
search/wait work, but its caller incorrectly presented that cancellation as
a light/Kerbin failure. LAND_DEORBIT now pauses explicitly on Abort at entry;
the operator deliberately clears it with `SET ABORT TO FALSE.` before
rebooting to resume. The software never clears that action group itself.
`STATS landing-light selector revision=2` identifies selector entry;
`wait-rejected` logs a specific node/orbit/impact reason and basic state,
also carried in the failed selection result. The routine suite now has
244 cases, including the reported Abort-on-entry path. No actual search
failure or invalid orbit was established by this particular reboot.

The RO9 Mun flight starting UT1619274.662 landed with733.4m/s remaining and
11.3m miss to its accepted site. Its 351m post-brake correction took76.1s and
25.5kg of propellant;298 rotated rows lost the detailed approach history.
The primary burn took141s after ignition and kept descending, with a weak
2kN lander stage. A long burn here is not itself proof of a hover.

Economy guidance now makes at most one normal-policy footprint check at the
unpowered terminal handoff after horizontal capture. A newly checked nearby
site bypasses the large approach correction and proceeds to vertical descent;
a rejection keeps the accepted target without starting another search or
hold. This uses the existing reachability/clearance/20m terrain/light checks,
and cannot invoke the emergency slope allowance. Precision and
`LANDING_ECONOMY_TERMINAL_RETARGET=0` retain their chosen site.

Brief unpowered flare intervals keep braking attitude inside the existing
alignment lead. The same stopping and attitude gates still control ignition;
large surplus altitude returns to coast. Over a checked nearby airless site,
the economy vertical speed uses a conservative quadratic inversion of the
coupled stopping envelope above the final gentle ramp. It retains full gravity,
reaction time, net-thrust fraction, burn margin, clearance and weaker-stage
authority. Actual facing bounds available vertical acceleration. Low-authority
craft retain the existing schedule unless twice the gentle ramp's maximum
deceleration is available. Atmospheric and precision profiles are unchanged.

A flat-terrain source replay of this terminal entry gives96.3->53.4s and
169.1->100.7m/s scalar impulse with gentle modeled contact. This assumes the
new footprint passes its real checks and uses constant mass/gravity and
instantaneous attitude; it is not flight accuracy or whole-mission savings.
Five eligible vertical models also reach gentle contact with0.2s actuation
lag. The upfront coast survey remains provisional and the orbital deorbit
solver still uses a ballistic phantom impact. A complete staging-aware
finite-burn landing optimization remains outside these changes.

Recorder schema3 retains per-state time/impulse/slow-descent summaries across
detail-buffer rotation, plus initial/native remaining dV. Impulse is sampled
live thrust/mass, with the largest sampling gap reported. The paired
`.log.boot.log` file is the copied boot log from the same recording session.

## Dependency shape

`lib/dependencies.ks` splits landing into two bands:

- `LAND_DEORBIT` loads `landing_deorbit`, `deorbit_targeting`, and
  `deorbit_burn`.
- `LAND` and `LAND_ASSIST` load `payload_landing` and `landing_main`.
  `landing_main` depends on `landing_config`, `landing_math`,
  `vessel_hardware`, `landing_terminal`, `landing_divert`, and `landing_disposal`.

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

### Accepted-node discrepancy under investigation

After the pass-time fix, the operator still reported an accepted Minmus plan
for target18.241,76.9115 whose plotted descent was far off the site. It reached
`Executing deorbit burn at T+7031s`; the game was paused before ignition.
This is not established as a temporary trial-node misunderstanding. A previous
synthetic Kepler solve does not verify the integration with live predictions.

`cmd/deorbitcheck.ks` captures the suspect node before it is removed. It
records the resolved target and loaded mission policy, current and planned
orbital elements, raw state vectors, body spin, and repeated impact samples.
At each impact UT it compares `POSITIONAT` with the TR coordinates, using
both our longitude correction and a separate quaternion transform matching
[Trajectories' native rotation code](https://github.com/neuoy/KSPTrajectories/blob/master/src/Plugin/Predictor/Trajectory.cs).
The command reports sunlight/radio for the target and both predicted contacts;
it does not create, edit, clear or execute a node, nor advance the phase.
Reports are written directly to `0:/logs/archive/_diagnostics/`, with an
archive readback of the completion record. A missing/lost link refuses or
marks the capture incomplete; no local report is left dependent on a boot
sweep. The command also recovers surviving legacy report files from
`0:/logs/` and `1:/run/` without deleting originals. Updating the command
does not require recompiling or installing `boot/boot.ksm`.

The API returns the currently published prediction, not a result tagged with
our trial node. The predictor includes maneuvers but publishes its buffered
calculation asynchronously. Our fixed0.5-second wait does not by itself prove
freshness. See the [prediction API](https://github.com/neuoy/KSPTrajectories/blob/master/src/Plugin/API.cs)
and predictor source above. Stale results and rotation/frame discrepancies
remain hypotheses until the captured native/TR comparisons establish which
contract fails. Do not label another timing/cap adjustment a flight-proven fix.

`Site scan found no safe site` means the optional SCANsat refinement found
no acceptable candidate in its local search. With `LANDING_REQUIRE_SITE=0`,
the planner retains the original target; the message does not certify it as
safe. Powered descent still applies its existing terrain/diversion checks.

## The phantom landing target

The targeted deorbit solver does not try to make the unpowered impact land on
the real target. It deliberately solves for a Trajectories impact downfield of
the real target:

- legacy nominal downfield distance: 15 km
- legacy accepted downfield band: 10-20 km
- opted-in powered lead: ballistic travel minus nominal staged braking travel,
  with target tolerance clamped to250–2500m around that model estimate
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
An automatic ground-track site passes its selected future pass UT through
terrain refinement into the solver. The first search window is the half-orbit
approaching that selected pass; fallback windows start after it. Without this
context, a site beneath a later Minmus orbit was tested against earlier
passes after the body had rotated to a different longitude. A latitude within
the inclination limit did not establish a cheap descent on those passes.
Fixed targets without pass context normally keep the ordinary forward search.
The RO9 fixed-site Mun profile opts into
`TARGET_DEORBIT_PASS_LOOKAHEAD_ROTATIONS=1`: survey one surface rotation,
refine local minima in unburned ground-track range, retain the eight closest
passes, and anchor each burn window to that pass's preceding half-orbit.
This matters when the craft is already over the site: the burn for that pass
is behind it, and eight consecutive later passes need not come close again.
The forecast is restricted to a bound orbit without a next SOI patch and uses
at most 4,096 coarse geometry samples plus local-minimum refinements. It
creates no maneuver nodes. `STATS deorbit pass-survey` reports the bounds and
sample count; `STATS deorbit fixed-pass` reports ranked epochs and unburned
misses. These are provisional seeds; native footprint admission still applies.
Zero disables the survey; positive values are capped at two surface rotations.
Picker-provided automatic pass context bypasses this fixed-site survey.
The search permits up to four windows by default, or
`TARGET_DEORBIT_SCAN_ORBITS` when configured. In `LANDING_SIM_MODE`, this is
capped at two. Subsequent windows span one orbit. The current
coarse step is `period / MAX(128, TARGET_DEORBIT_SCAN_SAMPLES)`.
Candidate order now tries 50 degrees across those windows, then 35, 65, 20
and 80 degrees across them. Previously every alternate angle on an early
pass came before any later pass; a budget stop could therefore exclude a
usable later window. The shared 64-trial ceiling still bounds all work, so
this ordering does not promise exhaustive coverage of every window/angle.
The geometry scan yields every 16 samples and refines burn timing to a
0.25-second bracket, avoiding one physics tick per sample and unnecessary
microsecond refinement.
If `TARGET_DEORBIT_PREFERRED_CROSSTRACK_KM` is set, an otherwise
acceptable pass whose cross-track miss is wider than that threshold will not
stop the scan immediately; the solver keeps looking through the configured
scan orbits and chooses the first pass inside the preferred cross-track band,
or the best acceptable wider pass if none are cleaner.

For each candidate burn time, `_solveGeometricDeorbitDv()` starts at 15 m/s
retrograde inside a 2-120 m/s range. It increases retrograde only until an
impact exists. A far-downfield seed then gets up to six measured
retrograde-only Newton steps at fixed time (at most 40 m/s per step, inside
the original 2-120 m/s bounds, accepting only smaller absolute downfield
error). This prevents a coupled timing/cross-track direction from using its
small timing allowance without fixing a large range error. The subsequent
coupled solve still owns lateral correction and full acceptance. All probes
consume the same 64-trial budget. `STATS deorbit range-seed` logs retained
steps. Temporary nodes let it measure:

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

The coupled refinement first tries burn timing together with retrograde dV,
then normal together with retrograde when enabled. Each Jacobian measures
both downrange and signed lateral response, including their coupling. It
does not assume which normal sign moves north. Timing adjustments are bounded
to 120 seconds around the seed; normal stays inside
`TARGET_DEORBIT_NORMAL_DV_CAP`. A shared trust factor preserves the correction
direction, and rejected full steps backtrack to half or quarter steps. Only
steps that reduce lateral miss plus distance outside the braking band are
retained. Small probe nodes may look worse; they are measurements, not burns.
`STATS deorbit step` records retained improvements.

RO8/RO9 Mun/Minmus economy, Minmus recovery and RO9's fixed-site Mun landing
profile permit up to 10 m/s normal correction; the default elsewhere remains
zero. The fixed-site Mun profile previously inherited zero despite its
rotating target, and reported a 64/64-trial hold after two of eight windows.
It now keeps the target lock and uses the same lateral preference/limit as
economy: preferred 250 m and maximum 500 m. These replace the overly broad
thrust-derived allowance for these profiles. All ordinary braking-lead,
flight-path-angle and terrain limits remain. Fuel and normal-component caps
are checked again on the final prediction. Each correction mode has at most
three iterations; `TARGET_DEORBIT_MAX_EVALUATIONS` caps all trial-node
predictions across the entire search at 64 by default. Exhaustion selects a
previously admissible candidate or holds in orbit, never relaxes the gates.
Search/hold diagnostics report actual windows and candidates tried, evaluation
count and stopping reason. A budget stop does not claim an exhaustive four-orbit
search or prove no solution exists.
Failures now end with `STATS deorbit best-rejected` before the hold line.
It retains the valid footprint minimizing cross-track error squared plus
distance outside the downfield band squared, and reports its window, seed
angle, geometric rejection, light-check status, retro/normal components,
downfield/cross-track error and cap, impact FPA, Pe and burn UT. It is a
diagnostic candidate, never permission to burn. Geometry acceptance with
`light=rejected` still holds. If no valid impact existed, that is reported
explicitly instead. This avoids relying on a scrolled-away candidate row.
A distant accepted node keeps the running executor in solar coast, with a
burn KAC alarm installed before solar aiming. Alarm firing only stops warp;
the clock loop performs continuation. On leaving coast the executor rechecks
light and, for targeted unflown nodes, the native footprint, terrain and fuel
gates before alignment. Abort, body change, node removal or expiry prevents
ignition. Retained interrupted/suborbital burns keep their recovery path.
`scripts/check_deorbit_passes.py` reproduces an overhead polar Mun target for
which the consecutive eight-orbit search fails. Geometry ranking plus range
preconditioning solves its later pass in 22 native-response trials, with
about 3.4 m lateral error and 3.3 m/s normal correction. This is an independent
idealized conic fixture, not the user's measured orbit or KSP validation;
it establishes neither global fuel optimality nor that the next flight solves.

Three new fixtures exercise the actual search prefix/order and failure
summary state, plus independent 15 km polar Mun footprints that require
bounded normal authority with both signs. The 247-case routine suite is
source/model validation; the reported flight needs a new native prediction.
The landing phase temporarily raises planning IPU to the configured landing
floor, capped at 2000, and restores it after either success or failure; boot
already restores that marker after interruption.

The first geometric seed in the legacy10–20km band with cross-track miss within
the controller's allowance is accepted, also respecting `DEORBIT_MIN_FPA`
when enabled. Opted-in powered targeting then refits its lead as described
above. Before execution, the chosen node is recreated and its impact
is rechecked against those same limits. Missing/changed impact predictions
hold without burning. Light/radio checks run only after geometry passes and
use the corrected burn UT. Unflown retained nodes in bound orbit also undergo
the current geometry/terrain/fuel checks, preserving rejected nodes for review. This
does not add an orbital planning hold to interrupted/suborbital recovery.
The node is optionally terrain-validated: if projected terrain contact occurs
before the target pass, planning fails; post-target impact is only warned
about because it is expected for the phantom target.

`STATS landing-light node` labels the real site as `targetLat/targetLng`
and the ballistic contact as `impactLat/impactLng`. The former `lat/lng`
fields meant the target, not the impact. A site at 19 degrees latitude is
reachable from a 20-degree inclined orbit without a plane change; orbital
motion changes latitude naturally. `cross=0.04/7.18km` means 40 m predicted
lateral miss versus a 7.18 km allowance, while `dist=19.23km downfield=19.23km`
describes the intentional ballistic overshoot. These alone do not establish
a latitude error or prove that powered descent will reach the site.

Fresh economy deorbit plans (`LANDING_FLEXIBLE_SITE=1` and
`LANDING_AUTO_TARGET=1`) refresh even a previously locked site from the
current orbit's ground track. Failed sunlight/radio selection holds in orbit
instead of falling back to the old site. This refresh precedes the local
SCANsat terrain refinement; it neither flattens the orbit nor sets latitude
to zero. Set `LANDING_AUTO_TARGET=0` for an intentional fixed site. Retained
or partially flown nodes are preserved by the existing resume checks. From
an unflown bound parking orbit, `cmd/landlight` with `apply` explicitly selects
a fresh ground-track site and removes the old unflown node before reboot.
The pass time is transient context for a fresh plan, cleared before target
confirmation; it cannot leak into a later fixed-target plan. A reboot refreshes
automatic orbit/site geometry. Retained nodes continue to use native checks.

`scripts/check_deorbit_solver.py` reproduces the pass mismatch using an
independent 20-degree circular Minmus model with body rotation: discarding
the selected pass exhausts 64 predictions on earlier passes, while matching
eight unburned ground-track sites to their selected passes converges within
16 predictions and under 1 m/s normal correction. These are instantaneous
Kepler/source fixtures, not Trajectories, finite-burn or flight validation.

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
- performs an initial terrain check for precision targets; flexible economy
  missions validate local sites incrementally during braking
- initializes the crossrange PID used during braking
- sets the initial FSM state to `COAST`
- sets the Trajectories target, when available
- disables SAS, deploys landing gear, locks steering and throttle
- stages automatically if all thrust is gone or an engine flames out

The precision one-shot terrain check samples a grid around the target using
`TERRAIN_CHECK_RADIUS` and `TERRAIN_CHECK_STEP` (defaults 100 m and 20 m). It
first checks the requested center against `LANDING_TERRAIN_MAX_SLOPE` (5°).
If it meets that limit, it keeps the center instead of buying a long diversion
to slightly flatter terrain. Otherwise it scores nearby points by gradient
magnitude and distance, as a best-effort terrain search. This is not a terrain
safety certification. The center is always a candidate, and grid spacing is
clamped to the search radius. `STATS landing-terrain` records any shift.

Flexible-site missions defer validation until horizontal speed is at most
`APPROACH_HSPEED`. They first try a reachable saved target, then search a
square spiral around the predicted horizontal stopping point. Each guidance
tick checks at most one candidate at the final 20 m slope scale; it also checks
altitude clearance, correction time and the saved light/radio policy. A rejected
candidate keeps the search pending and braking active. Pending searches block
APPROACH handoff and chasing the old remote target. Mid-descent reboots skip
the precision grids, and this search does not require Trajectories.

Search radius/spacing/time default to 1000 m/100 m/15 s per pass. The normal
limit remains 5°. Economy profiles explicitly enable the operator-authorized
15° emergency allowance with `LANDING_DIVERT_EMERGENCY_SLOPE=15`; it is disabled
by default and starts only after the normal pass fails. Logs name the active
tier and accepted slope limit. Pending searches request slow descent (5 m/s)
under the existing alignment/velocity controller. Exhaustion of every permitted
tier retains powered arrest and requests intervention, without accepting an
unqualified site. End-of-burn physical cutoff remains in FSM transitions and
cleanup; a bounded terrain sample is not a burn-end handoff.

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

RO9's fixed-site Mun profile opts into `LANDING_STAGE_BRAKE_CREDIT=1`.
The powered-band-only `landing_stage_brake` module computes a two-stage
stop rather than assuming the entire stop uses the weaker lander. For a
single controllable engine on an adjacent serial transfer stage, it bounds
remaining impulse by the lesser of stock current-stage dV and the rocket
equation applied to enabled propellant in the discarded parts. The limiting
mixture component bounds usable fuel; retained lander tanks, disabled tanks,
empty mixtures, massless required resources, parallel/multimode/locked engines,
nonadjacent staging and atmospheric vacuum estimates supply no credit.
The stock dV value alone is insufficient: [kOS documents update lag and
inaccuracies](https://ksp-kos.github.io/KOS/structures/vessels/deltav.html).
Part tank amounts are used rather than `ConsumedResource:AMOUNT`, which is
only valid while the engine is running. This is a conventional serial-stack
model, not a general fuel-routing or arbitrary modded-engine certification.

The available active-stage net impulse is bounded by
`stageDv * activeNetAcc / activeAcc / BURN_MARGIN`. Integrate that portion
with the existing 80% net acceleration reserve, then reserve a separate
separation/ignition coast and give all residual velocity to the weaker stage.
Both components retain full surface gravity, reaction time, burn margin and
clearance. If the extra pause consumes the benefit, retain the old envelope;
zero/unmeasurable credit uses the whole-weaker-stage calculation without
transfer credit (the vector limit in full-vector mode). `PLAN_ACC` still
records the weaker stage. No budget assumes the 44.68 m/s2 transfer engine
can burn throughout a stop after its fuel runs out.

The reported fixed-site entry (504.9 m/s horizontal, -3.8 m/s vertical,
44.68/2.72 m/s2 active/planned acceleration, 9,149 m control height versus
14,869 m radar) reproduces a 152 km horizontal gate with vertical ETA12.7s.
That lets the horizontal trigger ignite within the 20s alignment lead while
the vertical gate is still false. An illustrative313 m/s transfer-stage
budget reduces the horizontal gate to48.3 km and increases vertical ETA38s,
preventing ignition at that snapshot. The actual remaining transfer fuel
was not supplied, so these revised numbers are conditional, not a replay.
`STATS landing setup`, COAST display, the persisted brake decision and resident
diagnostic header/control rows now record the credited budget.
The640m terrain shift is not required to reproduce the mechanism; target
height/radar minimum still preserves the higher terrain guard.

A subsequent measured ignition confirmed the horizontal trigger: hs510m/s,
vs-30.8m/s, active44.68/plan2.72m/s2, stage credit223.9m/s,
height8628m, radar12741m, vGate6286m, vEta8.4s,
hGate74180m and downrange74695m. Subtracting the configured600m lead/bias
put74095m just inside the horizontal gate. The vertical gate was false.
The operator's later11098m radar reading is a current local clearance,
not that earlier ignition's target-relative8628m control height.

That staged model still used the legacy triangle bound `aMax-g`, while the
controller used full thrust-vector authority. The full-vector gate
now solves the physical constraint `|g*up + netAcc*direction| <= aMax`, then
applies the unchanged80% net reserve and burn margin. Gravity consumes a
vector component rather than being subtracted directly from sideways thrust.
For stopping direction with upward fraction `u`, the full net limit is
`-g*u + sqrt(aMax^2-g^2*(1-u^2))`. Full surface gravity still bounds the
entire calculation, including both reaction and staging coasts. This is the
same net-limit helper used by the controller, moved to the resident powered
budget module so coast/ignition can use it before the track executes.

Rounded measured inputs reproduce the old~74km horizontal/~6.3km vertical
bound and yield~40.6km horizontal/~3.46km vertical with the vector budget;
vertical ETA increases to~25.7s. The old ignition snapshot remains in COAST.
No-fuel/unsupported stacks receive no transfer credit and use only weaker-stage
vector capability; legacy control retains the original triangle bound.
Pure-vertical and underpowered gates retain their original values. Independent
physical-norm checks across200 velocity/gravity/thrust cases verify reserved
vectors stay within available thrust for gravity from0 to the surface bound.
Point-mass runs start1m above the new gate with finite223.9m/s transfer fuel
and two3s coast interruptions, retaining the original weaker-stage flare
clearance at horizontal capture. None establishes native target accuracy,
optimal ignition time or a complete landing/return fuel budget.
`vectorGate=true` in setup and saved ignition reports identifies this model.

A later RO9 Mun **economy** flight exposed a configuration gap: only the
fixed-site mission had enabled transfer credit, and the vector gate was
incorrectly conditional on that separate flag. The flight explicitly reported
`stageCredit=0 brakeStageDv=0 vectorGate=false`, height9422m/bottom11058m,
ASL13918m/targetElev4497m, hs513.2m/s, vs-18.2m/s, active39.78m/s2,
plan/reserve2.45m/s2, g1.63 and stage3. The V gate fired at9432m;
H was suppressed as required for a flexible site. Rounded inputs reproduce
V9455m, so the target shift/horizontal trigger is unnecessary to explain it.
The reported downrange17600m disagrees with Hgate207518m and rangeError89903m
(which suggest approximately117600m after the600m bias); do not treat that
transcribed distance as a measured landing miss.

The stopping envelope now follows the controller: above APPROACH_HSPEED,
ECONOMY_BRAKE uses vector geometry regardless of the credit setting. Lower
speeds retain the controller's original flare envelope. Both RO8/RO9 economy
moon profiles explicitly enable physically bounded stage credit. Fuel and
hardware validation remain mandatory; e.g. a3/2/1 stack needs a valid reserved
return boundary to credit transfer fuel without treating the return engine as
an unsupported extra stage. A flag alone cannot supply measured fuel.

At the supplied state, zero transfer credit gives V4503m and ETA13.4s;
illustrative100/200m/s measured credit would give V4234/3111m and ETA17.6/27.2s.
These are instantaneous target-relative bounds, not promised ignition heights.
An unpowered alignment can start within the20s lead, and increasing fall
speed moves the gate upward. The80% net reserve, full surface gravity,
reaction/staging delays and clearance remain. Source tests load all four
economy profiles, reproduce the early V gate, verify credit-disabled/unknown
fuel vector fallback, unpowered alignment, and preserve the low-speed flare.
A point-mass run starting1m above the revised gate with only the2.45m/s2
engine, full surface gravity and3s ignition delay reaches modeled capture
above300m without high hover. A separate finite200m/s transfer-credit run
retains the weaker-stage flare clearance after two3s thrust interruptions.
Neither measures a native landing or proves sufficient fuel/target precision.

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
High-altitude horizontal suppression applies above `TERRAIN_SAFE_ALT` when
more than `LANDING_BRAKE_ALIGN_LEAD` (20s by default) from the vertical gate.
It cannot suppress the vertical trigger. Full-vector descending control alone
does not suppress fixed-site horizontal/overshoot gates; that also requires
`LANDING_FLEXIBLE_SITE>0`.

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

With legacy control (`LANDING_ECONOMY_BRAKE=0`), desired horizontal and
vertical speeds are zero above `APPROACH_HSPEED`. This can sustain a long
high-altitude near-hover. `LANDING_ECONOMY_BRAKE=1` instead uses the existing
full-vector descending controller and budgets its remaining vertical flare
against the weaker stage. RO9's fixed-site Mun profile now enables this mode
while retaining its target and geographic gates. Once lateral speed is low,
the scheduled descent speed resumes. Trajectories
undershoot and crossrange correction no longer reduce braking authority;
position correction follows velocity capture in the terminal track.

Full-vector descending control also has a small upward aim margin. A
reported BRAKE row at d73,988m, TR error21,195m, cross566m, hs418.5m/s,
vs-31/-36.4, alignment0.3deg and throttle0 does not by itself identify the
cutoff: a stage-settle interval or a slightly engine-down actual attitude can
both do it. With an illustrative44.68m/s2 active stage, plan2.72m/s2,
effective gravity0.58m/s2 and9km control height, the actual source reproduces
the rounded commanded speed and nearly horizontal desired attitude. A0.3deg
tracking error puts actual thrust below the horizon and correctly cuts it.
Those illustrative stage/gravity/height inputs were not measured in that row.

`LANDING_BRAKE_MIN_PITCH=1` rotates only shallower thrust requests up to a
1-degree elevation at unchanged magnitude (configuration clamped0-2deg).
It leaves descent targets, fuel credit, all ignition gates, maximum thrust
and the live actual-facing guard intact. `check_landing_alignment.py`
reproduces the dead zone with zero margin, permits useful thrust with the
margin and0.3deg tracking error, and still blocks actual engine-down thrust.
The BRAKE row now includes `cut=` and actual facing `up=` so staging pauses,
alignment/engine-down holds, unavailable thrust and zero requests can be
distinguished on the next flight. This repair does not establish whether the
reported burn began too early or whether that row occurred during staging.

The state exits when the descent is captured and horizontal speed is low:

- if within `VERTICAL_RADIUS`, go directly to `VERTICAL_DESCENT`
- if outside `APPROACH_RADIUS`, go to `APPROACH`
- otherwise go to `TARGET_REFINE`

It can also go to `TARGET_REFINE` once the approach corridor is captured
within `APPROACH_RADIUS`, or to `VERTICAL_DESCENT` on a low vertical gate when
targeting is absent or horizontal speed is already low.

`scripts/check_landing_stage_brake.py` checks physical fuel caps, live cache
refresh, unsupported-stack fallback, the reported gate, fixed-site policy,
and paired finite-fuel point masses with3s ignition and staging gaps. With an
illustrative313 m/s transfer budget and the reported speeds, the revised
model ignites about1.5 km lower in target-relative height, reduces powered
near-zero descent before horizontal capture from159s to0s, and reduces impulse
to capture from594 to502 m/s. These endpoints are not complete landings or a
proof of target accuracy/fuel savings on the actual flight. A separate run
starts only1m above the staged gate under constant full surface gravity and
retains weaker-stage flare clearance after both delays. Terrain geometry,
SteeringManager dynamics, stock resource routing and KSP scheduling still
require flight validation. The ignition altitude is calculated from available
thrust/fuel, not forced to an arbitrary low altitude.

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
route to the next engine. Disposal is ballistic, not actively targeted. By
default fueled stages stay attached. Minmus economy profiles opt into a
handoff at 80 m/s horizontal speed: the adjacent serial stack must retain
the active CPU/lander engines, leave weaker-stage stopping clearance and
braking dV plus a 700 m/s allowance, and have a bound descending coast that
passes below terrain at periapsis with no nodes or atmosphere. A tick-driven
cutoff is verified before the common stage event; a failed check/timeout
retains propulsion. There is no debris separation or destruction guarantee.
`cmd/landingdisposal` saves these settings for the next landing-band boot
without clearing the node, phase, target or return overrides. Numerical fixtures
cover trigger/controller consistency and staged thrust changes; actual
separation clearance and KSP timing remain flight-test requirements.

The orbital aimpoint is not a certified powered stopping point. The recorded
RO9 Minmus node passes within about 65 m of its rotating target at 2.93 km
above target terrain. Replaying the conservative brake envelope over a flat
surface at that elevation opens the gate another 54 seconds/7.4 km later.
The measured-hardware point-mass model ends main braking 8.1 km beyond the
aimpoint with the transfer stage attached, or 9.3 km beyond it after an
80 m/s handoff and a conservative three-second staging gap. These estimates
exclude actual terrain, attitude and kOS timing; they are not flight proof.

For flexible economy sites, orbital selection and new/retained UNFLOWN
node acceptance now reserve `LANDING_LIGHT_SITE_RADIUS` (21 km by default)
around the aimpoint. The minimum Sun/Kerbin elevations gain the angular
radius plus sightline parallax at each of the existing time-window samples.
Ranking compares the resulting conservative margins with preferred light
and radio elevations. This geographic margin does not locate a precise
touchdown or certify the entire region's terrain/eclipses. Powered diversions
still test the actual candidate against their original physical policy.
Precision sites and interrupted/suborbital node recovery keep the point
policy; no new regional planning hold is imposed on committed descent.

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
| deorbit | `TARGET_DEORBIT_NORMAL_DV_CAP` | 0 m/s | Normal correction cap; economy/recovery profiles enable 10 m/s |
| deorbit | `TARGET_DEORBIT_MAX_EVALUATIONS` | 64 | Trial-node prediction limit across the entire search |
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

### Surface sunlight and Kerbin prediction frames

`landing_light` selects only ground-track candidates, then keeps sunlight,
Kerbin visibility and the existing deorbit/terrain acceptance gates separate.
Morning prefers a rising 15-degree Sun. The optional `AFTERNOON` mode prefers
a falling 52.5-degree Sun, approximately 2:30pm at the equator. Neither solar
score can compensate for Kerbin below its configured elevation margin.

The pause between the command's `Economy planning region radius=...` line
and `STATS landing-light search mode=...` is the ground-track light search,
before terrain scanning or deorbit solving. Its default four orbits at 128
samples/orbit require roughly 512 site evaluations, with repeated body
ephemerides, solar trend and eclipse tests, plus regional and time-window
checks. It now borrows the existing capped landing instruction budget during
selection, restoring it on success, failure or ABORT; the existing
`landing_prior_ipu` boot recovery handles interruption. No boot-module change
is needed. Start/progress/completion rows report IPU, samples, eligible sites,
window-check counts and elapsed game seconds. Progress is emitted every 64
samples; the original eight-sample yields and all geometry gates remain.

Do not subtract future `BODY` positions at different hierarchy levels as
though they were fully propagated world positions. The
[kOS body wrapper](https://github.com/KSP-KOS/KOS/blob/develop/src/kOS/Suffixed/BodyTarget.cs#L142)
delegates to the native body predictor. The native local-orbit predictor uses
a current parent center, the behavior also described in the
[vessel wrapper's child-body correction](https://github.com/KSP-KOS/KOS/blob/develop/src/kOS/Suffixed/VesselTarget.cs#L86).
The calculation must remove the current parent center from each local orbit
and accumulate every ancestor orbit to the same root before taking a
body-to-body difference. Surface rotation still uses the inverse of
`lmGroundGeoAt`'s longitude correction. This is separate from the future-vessel
frame correction used by the deorbit solver.

The original light tests incorrectly supplied fully propagated world positions
for every body. They therefore could not detect parent motion leaking into
the Kerbin direction. A nested Sun/Kerbin/Mun fixture now advances the moon
and planet separately: the old formula reported +18.36 degrees at a site
whose actual Kerbin elevation was -15.92 degrees. Corrected forecasts preserve
the tidally locked Mun's constant Kerbin elevation, including reflected RAW
axes and arbitrary origins. Minmus fixtures advance its spin independently
of its orbit. These are source-driven numerical checks, not game proof.

`landingKerbinElevationNow` uses only live positions as an independent check.
On the circular, synchronized Mun, future Kerbin elevation must agree within
0.5 degrees or the site is rejected with `kerbin-frame-mismatch`. The
`landlight status` command displays both and the saved policy without flying
or replacing the node. Direct Kerbin view remains a proxy: neither antenna
range nor ground-station/relay routing is predicted.

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

Precision targeting retains the downfield phantom impact so powered descent
has room to work. Enabled coast MCC tightens that lead; braking removes
horizontal speed, followed by target capture and final refinement. Economy
flights use the checked-footprint and faster descent paths described above
to reduce the correction and powered time before gentle touchdown.
