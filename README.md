# Komptroller

Open-source Kerbal mission governance for career mode: purposeful planes,
useful rovers, efficient rockets, tidy relays, and shiny things with jobs. Do
you like swarms of stuff? Built for fans of functional government, low part
counts, wheels, reusable infrastructure, a pristine homeworld, and the *ahem*
best technology available to a small green civilization with a fully
open-source hive mind updated for the second quarter of the 21st century.

Technically, Komptroller is KerbalScript (kOS) mission automation for Kerbal
Space Program: autonomous, reboot-safe flight computers for rockets,
airplanes, spaceplanes, hover drones, rovers, and EVA kerbals, driven by
executable mission config profiles with progressive code loading to fit tiny
in-game processors.

- **Operating a flight?** Start at [Quick start](#quick-start) and
  [Operations](#operations).
- **Building a mission?** See [Mission profiles](#mission-profiles) and the
  vehicle sections.
- **Writing code?** See [Architecture](#architecture),
  [Extending](#extending-the-system), and `CLAUDE.md` for conventions.
- **Following current work?** See [TASKS.md](TASKS.md) for active changes,
  queued improvements and outstanding flight validation.

## Quick start

1. In the VAB/SPH, set the kOS processor's boot file to `boot/boot.ks`.
2. Name the vessel either `VEHICLE-TARGET-PAYLOADS...` (legacy hints, e.g.
   `FR3-MUN-SCANSAT-01`) or a friendly name whose first word is the vehicle
   id (`FR3 Mun Mapper 1`).
3. Launch to the pad/runway. Boot opens the console just before the startup
   chime, syncs code from the archive, shows the mission profile picker (when
   profiles exist under `missions/<vehicle>/`), and runs the vehicle script.
4. Press any key after boot starts, during the manual-mode window, for
   **manual mode**; otherwise the mission auto-resumes from saved state.

## Operations

### Breaking into a running mission

Action group **0** toggles power on the kOS processor and its terminal.
Pressing `0` a few times power-cycles the CPU, forcing a reboot — then the
manual-mode window gives you a console. On multi-CPU ships the
dormant **zombie** core can reboot every other CPU remotely
(`RUNPATH("0:/cmd/zombie.ks").` from its terminal while linked).

### Operator commands

Run from a manual-mode terminal while linked. Commands are archive tools:
use `0:/cmd/...`; boot does not install phase commands onto the local volume.

| Command | What it does |
|---|---|
| `RUNPATH("0:/cmd/goto.ks", "Minmus").` | Route to any body/vessel (see [goto](#universal-routing-goto)) |
| `RUNPATH("0:/cmd/restartflightplan.ks").` | Rewind the phase machine for the next sortie/leg |
| `RUNPATH("0:/cmd/returntokerbin.ks").` | Full automated moon→Kerbin return (escape/MCC/aerobrake/descent) |
| `RUNPATH("0:/cmd/returnshallow.ks").` | 53 km moon→Kerbin return; keep engine/tank through aerobraking, then separate for parachute descent |
| `RUNPATH("0:/cmd/returncheck.ks").` | Plan a 53 km Mun/Minmus→Kerbin departure for review, with KSC targeting off; prints cost, remaining fuel and predicted Pe without burning or changing phase |
| `RUNPATH("0:/cmd/aeroassist.ks",1).` | Enable fuel-assisted aerobraking at the next boot; `0` disables (RO9 defaults enabled) |
| `RUNPATH("0:/cmd/reentrype.ks",53000).` | Restore Kerbin entry Pe at the upcoming apoapsis from an outbound orbit outside atmosphere; validates the native node, executes, preserves the mission |
| `RUNPATH("0:/cmd/directreturn.ks").` | From a landed Mun/Minmus craft, model a single-stage direct ascent to Kerbin Pe 53 km with a 20 m/s reserve; preview only, no launch or mission change |
| `RUNPATH("0:/cmd/returnrescue.ks").` | Repair an in-flight Kerbin return and resume at MCC |
| `RUNPATH("0:/cmd/kerbinrecover.ks").` | Inspect the live current/predicted Kerbin orbit and stage fuel; archive a report without changing the mission. Pass `"apply"` to configure shallow recovery with optional KSC targeting and reboot into MCC |
| `RUNPATH("0:/cmd/resumeburn.ks").` | After inspection, continue an interrupted XING burn now using its retained node |
| `RUNPATH("0:/cmd/shaperetry.ks").` | Clear an interrupted SHAPE attempt in stable orbit, retaining mission/targets/budget; then reboot to replan from the achieved orbit. Preserves unrelated nodes |
| `RUNPATH("0:/cmd/shapebudget.ks",1500).` | Allow1500 m/s further SHAPE corrections; preserves recorded spending, per-burn cap and fuel reserve. Reboot to replan |
| `RUNPATH("0:/cmd/arrival.ks", "review").` | Inspect a retained partial arrival; actions `accept` / `replan`, optional capture Ap in km |
| `RUNPATH("0:/cmd/arrival.ks", "budget", 100).` | Allow up to 100 m/s of further arrival corrections; preserves capture/return reserves and does not burn |
| `RUNPATH("0:/cmd/arrival.ks", "plan").` | Preview an arrival correction and hold for review; does not burn or advance the mission |
| `RUNPATH("0:/cmd/arrival.ks", "status").` | Show actual arrival Pe, capture fuel estimate, correction spending and interrupted-burn reason without flying |
| `RUNPATH("0:/cmd/airtest.ks").` | Airplane assist shakeout card (see [Aircraft](#aircraft)) |
| `RUNPATH("0:/cmd/setphase.ks", "PHASE").` | Force a phase, keep the mission |
| `RUNPATH("0:/cmd/hoproute.ks", LIST(LIST(lat1,lng1),LIST(lat2,lng2)),700).` | Save local airless rocket hops while landed; replace coordinates, review, then reboot. Stops after every landing for science; N continues, R restores return/DONE. Last argument reserves return dV |
| `RUNPATH("0:/cmd/hopnext.ks",3).` | Select site 3 of a saved hop route without igniting; reboot when ready. Omit the number for a site menu; 0 selects the configured return |
| `RUNPATH("0:/cmd/minmusrecover.ks").` | Select RO8 landing recovery; use argument `"waypoint"` for a visually chosen selected site without SCANsat coverage; then reboot |
| `RUNPATH("0:/cmd/resetmission.ks").` | Clear the profile; next boot shows the picker |
| `RUNPATH("0:/cmd/dump.ks").` | Print persistent state |
| `RUNONCEPATH("0:/cmd/trimstate.ks").` | Remove bulky stale state keys after a tight-storage boot |
| `RUNPATH("0:/cmd/convertstatejson.ks").` | Convert legacy SimpleJSON state to native kOS JSON |
| `RUNPATH("0:/cmd/logs.ks").` | Archive the current boot's flight log to KSC |
| `RUNPATH("0:/cmd/burnreport.ks").` | Print the latest maneuver cutoff report, retained across reboots |
| `RUNPATH("0:/cmd/burncheck.ks").` | Read-only ignition check: engine availability, autopilot suppression, CPU roles/IPU, and timed throttle-governor probes against the retained node; never fires engines |
| `RUNPATH("0:/cmd/deorbitcheck.ks").` | Read-only deorbit snapshot: keep the suspect node attached and run in manual mode with an archive link; saves and verifies the report under `0:/logs/archive/_diagnostics/` |
| `RUNPATH("0:/cmd/deorbitretry.ks").` | Discard the next unflown moon landing node while preserving the configured target, mission and overrides; then reboot to replan. Refuses committed/interrupted burns or unsafe controls/orbits |
| `RUNPATH("0:/cmd/landingcheck.ks").` | Print and archive landing hardware, current-stage dV, next-stage acceleration and the last brake decision; requires an archive link |
| `RUNPATH("0:/cmd/divertcheck.ks").` | Archive nearby raw terrain heights/slopes, correction-time estimates, policy/hardware and a copy of the flight log; no flight control; sample limit/spacing optional |
| `RUNPATH("0:/cmd/landfallback.ks").` | Permit a checked local fallback during a committed airless LAND_ASSIST/LAND descent; requires zero throttle, then reboot; preserves the return mission and phase |
| `RUNPATH("0:/cmd/landingstages.ks", 2).` | Save a verified per-flight landing stage floor: stage 2 and above may be used; stage 1 is reserved for ascent/return; requires automation stopped and zero throttle |
| `RUNPATH("0:/cmd/landingdisposal.ks").` | Save an optional transfer-stage handoff at 80 m/s horizontal speed with a 700 m/s lander reserve; preserves node, phase and other overrides; pass `0` to restore fuel-first staging |
| `RUNPATH("0:/cmd/transferretry.ks").` | Clear a no-thrust XING attempt after deleting its node; then reboot to replan from low Kerbin orbit |
| `RUNPATH("0:/cmd/scan.ks", "status").` | SCANsat/science: `start` / `status` / `transmit` |
| `RUNPATH("0:/cmd/setlanding.ks", "assist").` | Landing overrides from archive: `deorbit` / `assist` |
| `RUNPATH("0:/cmd/landlight.ks").` | Preview a lit ground-track site from Mun/Minmus parking orbit; `"status"` checks the saved target with live positions; `"apply", "AFTERNOON", 1` selects afternoon while preserving the return mission; final argument `0` waives direct Kerbin view |
| `RUNPATH("0:/cmd/setorbit.ks", ...).` | Set orbit targets for the next phases |
| `RUNPATH("0:/cmd/geodistance.ks", lat1, lng1, lat2, lng2).` | Surface distance between two lat/lng points on the current body |
| `RUNPATH("0:/cmd/kscsplash.ks").` | Target water splashdown offshore of KSC |
| `RUNPATH("0:/cmd/zombie.ks").` | Power-cycle every *other* CPU on the vessel |
| `RUNPATH("0:/cmd/updateboot.ks").` | Compile/install the current bootstrap while linked and thrust/throttle are zero; select it for the next reboot |

Emergency landing rescue is archive-only: run `0:/cmd/landassist.ks`,
`0:/cmd/landmin.ks`, or `0:/cmd/landingrescue.ks` while linked.

Commands require archive access. If you need one, get a link and run the
archive copy directly.

**Current limitation:** `KSC_DEORBIT` has no atmospheric phase handler after
the vacuum deorbit refactor. Profiles using it and `landat`/`landatksc` hold
for manual review. The [codebase audit](docs/CODEBASE_AUDIT.md) records this
gap, offline-loading limits, repairs, and validation still needed.

If a linked reboot says `RETURN_SETUP library unavailable`, the loaded-file
check previously used `DEFINED` on a function name and could reject a provider
that had loaded. It now tests the provider's explicit scalar readiness marker.
Sync and reboot with a link to update both `dependencies` and `return_setup`;
no installed bootstrap replacement is needed. If the active return phase still
holds, retain the boot log—the warning is not evidence of harmless future-band
loading, and a genuinely missing provider remains a hold.

### Programmed surface hops

`cmd/hoproute` saves 1–16 explicit latitude/longitude pairs on the current
body, checking normal terrain slope and limiting each leg to a quarter of the
body radius. Run it while landed, idle and linked; it does not launch until
you reboot. `cmd/hop` is the one-site form. These are rocket ballistic hops,
separate from FDR1's RCS drone missions. This new route path needs flight testing.

Every touchdown settles for two seconds with brakes set and throttle off,
then returns to the Godspeed prompt and prints these commands:

- `RUNPATH("1:/run/hop").` — next route site; after the last site, resume the original return/DONE.
- `RUNPATH("1:/run/hop","waypoint").` — replace the next hop with the currently selected navigation waypoint.
- `RUNPATH("1:/run/hop","return").` — end hops and begin economy Kerbin return, targeting 53 km Pe without KSC targeting.

The small script is saved locally before yielding, so these commands need no
archive or radio link. They reload the cached libraries and mission settings,
then recheck surface contact, Abort and applicable terrain/fuel limits before
rebooting into the selected action. The selected mission/profile and unrelated
return settings are retained. A reboot during a flown hop resumes landing rather
than repeating liftoff. Launch/landing/review libraries stay cached together
for route reboots; later return bands may still need their normal link/cache.

Use the printed script commands: kOS disallows calling a program's user
functions directly from the terminal. See the
[kOS interpreter limitation](https://ksp-kos.github.io/KOS/language/user_functions.html#functions-and-the-terminal-interpreter).

Surface review yields at 1× with no automatic departure timer or solar
pointing. Scheduled orbital waits instead set an
owned KAC alarm before solar setup and stay running until their wake time.
KAC stops warp; the running script resumes the mission. Without a usable
owned alarm, these waits poll the clock at 1×. Abort and trajectory/body
changes interrupt the wait; alarm cleanup preserves independent SOI alarms.

The default return allowance is700m/s, configurable in the command; it is not
a solved return trajectory. Each leg also needs an independent landing
allowance and a conservative launch/braking estimate, both on the currently
permitted engine stage as well as in total vessel dV. The executor never
stages into the return engine, clears Abort or ignites after a failed
alignment. It lifts vertically before pitching toward the site, and preserves
thrust limits across an interrupted boot. Keep reserved-tank crossfeed disabled.
The route is local and experimental; it does not guarantee contract precision,
resource/biome science completion, or an optimized multi-biome tour.

### Launch windows and staging

Minmus profiles use `LAUNCH_PLANE_MODE = "BODY_ORBIT"`. PRELAUNCH offers
**SPACE: wait for the target plane**, **N: launch east now**, or **H: hold**;
the default after 30 seconds is to wait. Launching east uses the minimum
direct-ascent inclination at the launch latitude, leaving encounter
corrections to the transfer planner. A negative timed-launch inclination
selects the southbound crossing, not a retrograde orbit.

PRELAUNCH saves the window and immediately loads the LAUNCH band. LAUNCH
waits against the absolute liftoff time after setup, with a KAC alarm when
available. Missed plane windows are recalculated; missed rendezvous or
interplanetary windows return to PRELAUNCH for a fresh plan. It never
silently launches late. Both atmospheric and airless ascents use this gate.
While waiting, there are no countdown updates more than an hour before
liftoff. During the final hour, console notices appear at most once every
15 game minutes; the HUD countdown runs only during the last 10 seconds.
The KAC alarm stops warp 30 seconds before liftoff when available.

`LAUNCH_PLANE_LEAD` is a vehicle/profile calibration in seconds before the
geometric plane crossing. Its default `-1` inherits
`PRELAUNCH_PLANE_LEAD`, whose default is now **0**, replacing the old
145-second allowance. Explicit `LAUNCH_PLANE_LEAD = 0` is supported.
Keep reboot/loading delay out of this calibration. Compare `STATS launch
liftoff` with `STATS launch-plane result`; `planeErr` is the actual angle
between the parking and target planes, including both inclination and LAN.
The new default still needs flight calibration for each ascent profile.

Tag the stock procedural fairing base **`main_fairing`** and include `FAIR`
in the mission sequence. Deployment waits for `FAIRING_ALT` (default 72 km)
or a stable orbit above the atmosphere. Untagged fairings are skipped.

Maneuver burns use the active stage's remaining fuel before advancing to
the next engine. Separation and engine ignition may occupy separate stage
slots; the same maneuver node and remaining dV are retained throughout.
`BURN_STAGE_TIMEOUT` (10 s), `BURN_STAGE_SETTLE` (0.5 s), and
`BURN_STAGE_MAX_EVENTS` (4) bound automatic staging. An engine whose staging
slot has fired but remains inactive gets an explicit activation attempt.
If automatic recovery stalls, **BURN WAIT** keeps the executor running with
zero throttle for `BURN_STAGE_MANUAL_WAIT` (120 s). Manual staging/engine
activation during this wait is detected automatically; after realignment,
the same burn continues. ABORT stops this recovery wait.
`BURN_STAGE_LIMIT` (0)
is the lowest stage number allowed for the next engine; raise it in the
mission profile to reserve lower-numbered stages. Arrange the staging stack
so advancing to that engine only triggers intended separation/ignition events.
An unrelated flamed-out engine does not force staging while usable engines
are still active.

Use kOS part name tags to declare reusable hardware roles:

| Tag on the actual decoupler | Role |
|---|---|
| `return_decoupler` | Separates the ascent/return craft from landing tanks, engine and legs. Landing reserves this boundary and the return engines. |
| `lander_decoupler` | Releases the complete lander from its transfer section or surveyor/carrier. Identifies the release hardware; finding it does not fire it. |

One part per tag. A unique valid `return_decoupler` is enough to reserve the
return stage: a3/2/1 stack derives floor2 from the tagged stage1 separator.
No numeric configuration command is needed for correctly tagged hardware.
Names can be changed with `LANDING_RETURN_DECOUPLER_TAG` and
`LANDING_RELEASE_DECOUPLER_TAG`; blank/`none` disables that role lookup.
The resolver checks actual separator modules, staging order, lander/return
engines and retention of the controlling CPU. Duplicates and invalid roles
hold deorbit while still in orbit. A committed descent retains active-engine
guidance, blocks further staging and uses a conservative brake budget when
roles are invalid. Tags never fire separators or ignite engines by themselves.
A combined surveyor/lander still needs its release timing and separate CPU/
mission handoff configured; these tags do not install a dual-vessel mission.

After syncing this code at a connected boot, landing entry points read the
tags from the vessel, including after a reboot. `STATS landing roles` shows
`valid`, `floor`, `returnStage` and `releaseStage`; the example should report
`valid=True floor=2 returnStage=1 releaseStage=2`. No derived stage numbers
are persisted. `cmd/landingcheck` includes the current role reason/floor.
Untagged craft retain their existing manual/default policy. The numerical
fallback remains `RUNPATH("0:/cmd/landingstages.ks", 2).` at a throttle-off
manual point before deorbit, followed by reboot; it changes only that flight's
landing stage limit. A manual floor can tighten a tagged boundary, not weaken it.

Keep crossfeed from reserved return tanks disabled: this policy controls
staging, not fuel flow, and cannot prove descent fuel is sufficient. Surface
ascent uses its own staging and can use leftover lander fuel before shedding
the lander. No bootstrap update is required. Hardware tags follow kOS's
[Part name-tag and staging interfaces](https://ksp-kos.github.io/KOS/structures/vessels/part.html).

Vacuum landing also uses the active transfer stage's fuel before staging.
No landing-specific tags are required: put transfer-stage separation and
lander ignition in the same staging slot or consecutive slots, with only
intended events between them. Keep the controlling kOS core on the lander.
The controller advances only to the next inactive, throttleable engine,
continues guidance between staging events, and remeasures thrust/mass after
ignition. `LANDING_STAGE_LIMIT` (0) reserves lower-numbered slots;
`LANDING_STAGE_MAX_EVENTS` (4) and `LANDING_STAGE_SETTLE` (0.25 s) bound the
automatic sequence. A usable engine prevents staging even if another engine
has flamed out. Exhausting the final engine does not stage payloads or chutes.

`RUNPATH("0:/cmd/landingcheck.ks").` reports the next engine slot and estimated
post-separation surface TWR, engine limits/Isp, current-stage and total vacuum
dV, and the saved last brake decision. It also saves every output row to
`0:/logs/archive/_diagnostics/landingcheck_<vessel>_<UT>.log` and verifies the
completion record. Copy that file for review; an archive link is required.
There is no boot-sweep dependency or boot-module update.
Braking accounts for the weaker of current and
next-stage acceleration, combined horizontal/vertical motion, terrain
clearance, and a three-second reaction allowance. It can therefore start
earlier than a vertical-only suicide-burn estimate. The spent stage is
discarded ballistically; this is not a separate disposal-targeting program.
By default, a fueled transfer stage stays attached; the controller does not
burn fuel merely to empty it. RO8/RO9 Minmus economy profiles instead enable
`LANDING_STAGE_DISCARD_HSPEED=80`: after initial braking on the transfer engine,
attempt separation while horizontal speed is between 30 and 80 m/s. This
requires an adjacent serial separation/ignition slot, retention of the active
CPU and lander engines, adequate weaker-stage stopping clearance, and enough
lander dV for braking plus `LANDING_STAGE_DISCARD_RESERVE_DV` (700 m/s). The
reserve is an allowance, not a complete surface-return budget.

The handoff also requires a bound descending trajectory, no remaining nodes,
no atmosphere, and predicted passage below measured terrain at periapsis.
Guidance holds all throttle commands at zero across a physics step and
verifies physical cutoff before staging. Failed checks keep existing
propulsion; a cutoff/staging timeout cancels the elective handoff. Existing
ignition recovery, stage limits and live alignment guards remain active.
ABORT cancels elective staging and sends landing guidance through its existing
verified throttle cleanup.
This predicts debris contact, not component destruction or safe debris
clearance. Mun profiles retain fuel-first staging pending a measured budget.
For an in-flight mission, `RUNPATH("0:/cmd/landingdisposal.ks").` saves only
these two overrides. It preserves the target, return sequence, phase and
retained node. Passing `0` disables elective disposal.

RO9's fixed-site `mun_landing_return` and `minmus_landing_return` enable
`LANDING_POWERED_LEAD=1`, retaining their locked contract coordinates. Change
those coordinates for a new contract before launch. The planner samples the
native post-deorbit conic, finds ignition using both live H/V gate policies,
and simulates the descending braking/flare controller with evolving mass,
local engine propellant, dry-stage separation, vacuum Isp and body rotation.
It aims the ballistic footprint beyond the site by the difference between
ballistic travel and predicted powered travel. Unsupported/fuel-exhausted or
nonconvergent precision models hold in orbit; they do not authorize a burn.
New, retained and pre-burn nodes share the admission checks.

Powered refinement takes one accepted geometric step before re-running the
full braking forecast. Polishing a frozen lead wastes trials when each node
change also moves the required powered lead. Successive checked residuals
may supply a bounded secant proposal; noisy/reversed slopes or a proposal
that cannot improve the geometry fall back to the measured model goal.
Each changed node still needs fresh powered validation, with one trial
reserved for it. The64-trial cap, landing tolerance and admission limits
remain unchanged. `STATS deorbit powered-step` records the proposal mode,
goal and slope; its goal is not an accepted landing forecast.

For powered landings, the preferred ballistic cross-track goal (typically
250m) does not consume the trials needed for finite-burn validation. A seed
inside the unchanged hard cross-track limit (typically500m), downfield, fuel
and normal-burn limits proceeds directly to powered fitting. Inner geometric
polishing follows the same rule. Radio checks still precede that handoff;
fresh powered forecasts and final terrain checks still authorize the burn.
`STATS deorbit seed` reports the hard/preferred cross-track values and remaining trials; search stops with`powered-seed`.
The64-trial cap is unchanged. If no model check could run, the hold now says
`powered-validation-budget-exhausted` rather than implying model nonconvergence.

If a coupled retrograde/normal step stalls while downfield is already inside
its allowed band, the solver can reuse its measured normal response for a
normal-only correction. It keeps burn time and retrograde dV fixed, bounds
each normal step to 5 m/s within the existing total cap, and backtracks through
the same full/half/quarter fractions. Every probe consumes the original trial
budget; the powered-validation reserve still applies. Invalid/flat/nonfinite
responses cannot produce a correction, and no hard landing limit changes.
Accepted steps record `method=normal-only`; failed responses include the
measured downfield/cross deltas in `STATS deorbit refine-stop`. This improves
recovery from a bad local Newton response; it does not prove why a particular
native TR response changed or guarantee convergence for an unreachable site.

The live H gate uses a cheaper 32-bin mass-aware range quadrature from a
per-stage hardware snapshot. The full forward simulation stays in orbital
planning; it is not run in a throttle lock or powered guidance tick. Both
read the same stage fuel/thrust data, while flight and forward prediction use
one shared descent/thrust law. Vertical safety reserves, terrain clearance,
actual-facing checks and throttle cutoff remain unchanged. Economy profiles
retain their flexible-site policy rather than becoming pinpoint missions.

A reported fixed-site Mun run exposed a separate ignition delay: at18.97km
downrange the modeled H gate was already due, but its old V-ETA arming guard
kept it suppressed until13.19km. Validated powered fixed-site ranges now arm
independently of V-ETA through a predicate shared with orbital prediction.
Legacy/unknown models retain the high-altitude suppression; flexible economy
sites still use their vertical stopping gate. `hModel` and `hSupp` show which
policy is active. The vertical envelope and alignment requirements are unchanged.

Powered fixed-site braking also steers sideways toward the actual landing
site, rather than leaving all cross-track correction to APPROACH. Flight and
the forward predictor share geometric lateral guidance: the horizontal thrust
direction can turn at most15deg while preserving vertical thrust and total
command magnitude. The descent schedule reserves the corresponding loss of
horizontal arrest; lateral steering fades before the terminal handoff.
Flexible economy sites, blind landing, terrain-search recovery and legacy
braking retain their existing policy. `lateral`, `latYaw` and `latMiss` show
the live command. Staged3D simulations reduce a1.2km cross-track miss to101m
for about4m/s additional braking impulse; this awaits native flight validation.

Powered fixed-site APPROACH also uses a response-aware horizontal stopping
limit and coupled stopping-height reserve instead of the old3km altitude ramp.
It estimates acceleration/cruise/braking time from signed closing velocity,
cross velocity and the speed actually commanded, then descends only through
height above that reserve. Tilt compensation preserves vertical thrust while
translating. Safe terminal handoff can retain lateral motion up to18m/s once
vertical capture is secure, rather than first nulling it below1m/s. Legacy
and flexible approaches and the slow final settling corridor retain their
existing limits. `tLat`/`stopH` expose recovery time and reserved height.
In a flat, constant-thrust replay of the reported5km/594m recovery, target/speed
capture improves from1167s/1924m/s integrated thrust to149s/284m/s. This is
not native flight proof, a fuel budget, or a guarantee of pinpoint landing.

The reviewed `landingdiag_RO9_2157921508_boot_014_core` run ended main braking
4051m from the guidance site, spent320s /519.5m/s thrust-integrated impulse in
APPROACH and another48.7m/s in final hover, and logged touchdown2791m from the
requested site. Its20.6km H gate matches the older nominal timing; the prior
timing fix reduces this snapshot to18.4km, and fuel accounting reduces it to
17.5km, versus roughly17.1km flown. A replay assuming345s transfer /290s lander
Isp predicts16.7km /155s versus154s flown. These are partial model checks,
not proof of native pinpoint accuracy or whole-flight fuel savings.

`STATS deorbit powered-lead` records capture location error, height/velocity,
time, impulse, mass and iteration count. Landing archives now include engine
thrust, exhaust velocity, local fuel mass and jettison mass, so later replays
need not assume Isp. The forecast stops at braking/flare capture, uses ideal
attitude and target-height terrain, and does not certify powered-path terrain
clearance or touchdown. Existing native terrain and live safety checks remain.
No installed bootstrap update is needed; use a connected boot to cache the
new shared libraries before flight.

Powered refinement uses the existing 64-trial budget, reserves a trial to
validate each changed node, and stops when accepted or unable to improve.
It no longer stops after three model passes without checking the final
adjustment. `STATS deorbit powered-fit` reports actual downfield distance,
the fresh lead aim, residual, cross-track and trial count. A hold includes
`stop=trial-budget` or `stop=no-improving-step` and the remaining error.

For an already-deorbited craft that may land off-target, interrupt automation,
cut throttle fully, then run `RUNPATH("0:/cmd/landfallback.ks").` and reboot
while linked. This permits the existing checked local-site diversion and
preserves the mission/return sequence, phase and other overrides. It does
not select a site, waive terrain/light/radio checks or start a burn. An old
fixed-site deorbit cannot be repaired retroactively by changing the planner.
No installed bootstrap update is needed for this change.

RO8/RO9 Mun/Minmus economy profiles allow `LANDING_FLEXIBLE_SITE=1`.
During coast/braking, economy guidance samples a provisional stopping footprint
at most once every two seconds. These approximate forecasts cache terrain/light
only: they never change the target or trigger ignition. At horizontal capture,
the controller repeats actual reachability, clearance, fine terrain and light
checks before accepting cached coordinates, or searches near the stopping point.
A remote site outside the `LANDING_APPROACH_MAX_TIME` correction estimate
(120 seconds) is rejected.
The search checks one candidate per guidance tick at the final 20 m terrain
scale while guidance continues. Normal searches retain the 5° slope
limit, sunlight policy and optional Kerbin requirement. Precision profiles
keep their original target and survey policy. The time setting estimates
correction feasibility; it does not guarantee touchdown timing or fuel.

Economy airless descent aims for an unpowered coast, a coupled braking arc,
and a gentle touchdown at a checked reachable footprint. Brief unpowered
intervals close to the flare gate keep braking attitude instead of cycling
through COAST and BRAKE_ALIGN; the ignition envelope and live alignment
guard still decide when thrust is allowed. Larger surplus height still
returns to COAST.

After velocity capture, a flexible economy landing can make one normal-policy
check of its nearby stopping footprint before committing to a large approach
correction. This runs at zero thrust/commands, while falling; it does not
start another grid search or request a hover. A passing point goes straight
to vertical descent. Failure keeps the accepted site and its normal recovery
path. `LANDING_ECONOMY_TERMINAL_RETARGET=0` opts out of this final retarget;
precision profiles retain their coordinates. The check retains reachability,
100 m clearance, 20 m terrain samples, the normal slope limit, and the existing
Sun/radio policy. It cannot invoke the emergency slope allowance.

Once over a checked site with captured horizontal speed, airless economy
vertical descent can fall faster above the gentle touchdown segment. The
speed comes from a conservative inversion of the existing coupled stopping
envelope, preserving the 80% net-thrust budget, full gravity, reaction time,
burn margin and clearance. Actual vertical thrust projection and the weaker
planned stage bound the calculation. Low-authority craft keep their existing
schedule; the faster profile requires twice the net acceleration demanded by
the gentle final ramp. Atmosphere, precision, unchecked/distant targets and
final lateral settling keep their existing profiles. Coast terrain forecasts
remain provisional; the deorbit solver still does not optimize a complete
staged finite-burn landing. These changes have source-driven/model checks,
not a flight-proven single-burn or globally minimum-dV solution.

By operator request, economy profiles set `LANDING_DIVERT_EMERGENCY_SLOPE=15`.
Only after the normal search fails may an emergency search accept terrain up
to 15°. Its accepted-site log records `emergency=true` and `slopeLimit=15`.
The default allowance is 0 (disabled). `LANDING_DIVERT_SEARCH_RADIUS` (1000 m),
`LANDING_DIVERT_SEARCH_STEP` (100 m maximum), and `LANDING_DIVERT_SEARCH_TIME` (15 s per
pass) bound the search. The actual radius also fits the upright controller's
120-second range; spacing tightens with the radius to a 20 m minimum.
On Minmus this resolves small flat patches instead of spending most
samples on unreachable outer points. Each pass logs its best measured slope.
In economy mode an active or exhausted search cannot itself start braking or
keep a captured craft burning above the stopping envelope. Search continues
while falling; ignition still uses the existing terrain/velocity/staging gate.
After horizontal capture, a pending economy diversion can use current hull
clearance and the highest measured local terrain when the old target is beyond
the low-speed coast corridor and at least 1 km away. Nearby targets, moving
craft and enabled coast corrections retain the original height guard.
When powered arrest is physically needed and no site has passed, low-speed
search requests up to `LANDING_DIVERT_SEARCH_DESCENT` (5 m/s). If both permitted
searches fail after reachability rejections, a material reduction in horizontal
speed or shift of the stopping point permits one fresh normal/emergency cycle.
This revisits nearby sites that were rejected while braking but are reachable
after velocity capture. It keeps the same slope, light, clearance and correction
time gates, and still evaluates at most one candidate per tick. If that retry
also fails, or the stopping conditions have not changed, it retains powered
arrest and signals manual intervention;
it does not certify a rejected site or return to the prompt in free fall.
Failure logs include rejection totals by reachability, terrain, clearance and
light, plus the last candidate's distance and correction-time estimate.
`grade=-1` with `reason=reachability` means that candidate's terrain was not
sampled. BRAKE `d=` is surface distance to the saved target, excluding altitude.

Landing guidance now records diagnostics automatically, including its actual
terrain samples (raw north/south/east/west elevations at 20 m), rejection
reasons, search passes, limits and flight state. It captures the controller's
current/commanded speeds, distance and throttle every two seconds, including
approach/hover holds. There is no extra scan and no
separate diagnostic command or reboot to collect them. With an archive link,
it appends checkpoints to
`0:/logs/archive/_diagnostics/landingdiag_*.log` during zero-thrust coast with
at least 60 seconds until both braking gates, at most every 15 seconds.
During burns and terminal descent it buffers up to 64 rows / 16,000 characters,
reserving half for terrain/events so a long hold cannot erase that evidence;
the report counts any older rows dropped. A separate12-row/3,000-character
braking history samples lateral steering every15s and on stage changes, so
late terminal samples cannot erase it. This buffer adds no powered archive
I/O. It also exports after landing or
normal abort cleanup, verifies that final checkpoint, and copies a `.boot.log`
sidecar. Transfer the report and sidecar when available. Without a safe coast
window or a link, it keeps buffering during descent; it never holds altitude
to write a report. Rows still unexported at phase exit or reboot are lost.
Installing the updated landing
libraries uses the usual connected boot; no replacement `boot/boot.ks` is needed.
Schema 2 also records unrounded speed commands, state age, pending/exhausted
search flags, local clearance versus target/control heights, actual thrust,
mass, gravity, facing-up fraction, and raw/pilot throttle at that cadence.
Schema 3 adds the initial mass, available/stage dV and velocity/thrust snapshot,
plus a bounded numerical ledger for each of the nine guidance states. Time,
powered time, estimated scalar thrust impulse (`integral(thrust/mass dt)`),
powered slow descent above 50 m, entry counts and the largest sample gap survive
rotation of detailed rows. Unpowered stage separation does not count as fuel
impulse. Summary rows are cumulative at each safe checkpoint; the sample gap
exposes integration uncertainty. Native remaining dV and mass are recorded
again at each checkpoint. The `.log.boot.log` file is the companion boot log,
copied at final verification; it shares the report's filename/timestamp by design.
These distinguish an intentional search hold, a target-elevation hold, and
failure to follow a descent command; HUD rounding alone cannot do that.

For an additional repeatable terrain snapshot, use `RUNPATH("0:/cmd/divertcheck.ks").` with
an archive link from a saved test state or with flight control maintained
separately. This command does not hover, land, stage or change the mission.
It probes the center first, then up to 80 surrounding points at 50 m spacing.
Optional arguments set sample count (1–81) and spacing (20–100 m). Sampling
checks a six-game-second deadline between points; loading and archive export
take additional time. It restores its temporary instruction budget and writes
the report directly under `0:/logs/archive/_diagnostics/divertcheck_*.log`, with
a `.boot.log` sidecar copied from the current flight log. The report includes
raw four-neighbor elevations, production/independent grades, slope degrees,
clearance and correction-time estimates. Transfer both files for analysis;
no boot sweep or boot-module update is required.
After deorbit, diversions default to `LANDING_DIVERT_REQUIRE_KERBIN=0`: a lost
Kerbin view does not abort an otherwise acceptable autonomous landing. The
orbital site search retains its configured requirement (15 degrees in the economy profiles).
Sunlight and terrain checks remain active. To require radio view for diversions,
set `LANDING_DIVERT_REQUIRE_KERBIN=1`; its configurable
`LANDING_DIVERT_KERBIN_TOLERANCE` subtracts 7 degrees from the planned requirement,
with a lower bound of -2 degrees. Neither setting guarantees a live link.

Targeted deorbit coasts now wake five minutes before the burn for a fresh
powered forecast. If only the braking lead changed, a bounded local pass can
adjust the same node's retrograde component while keeping its time, normal,
radial component and landing target fixed. It measures the powered residual
response rather than treating the ballistic footprint as the landing point.
At most seven forecasts are allowed, with 5 m/s steps, a 10 m/s total change
limit and the original 2–120 m/s retrograde range. Each candidate must still
meet the original geometry, fuel and terrain limits; radio is rechecked before
acceptance. A failed pass restores the original node. The original final
check 90 seconds before the burn remains; another forecast change cancels
ignition. KAC is installed before the solar coast, and the wait stays resident.

Powered forecasts measure hull clearance from a single snapshot of the
vessel's physical bounding box, using its half-diagonal plus its centre's
offset from the centre of mass. This encloses every corner for any attitude.
They do not infer vessel size by subtracting radar altitudes: `ALT:RADAR` can
fall back to sea-level altitude, while `BOTTOMALTRADAR` samples terrain under
the bounding box. Their difference falsely reported a 2.2–2.4 km RO9 hull.
Future terrain and target-elevation clearance checks remain in place. Live
landing guidance still uses its original bottom-radar guard.

If a coupled solve stalls at a timing/normal bound but cross-track is already
acceptable, a powered mission can try a measured retrograde-only step. It
keeps time/normal fixed, backtracks within the existing retrograde limits,
retains the hard cross-track cap and reserves a fresh powered-model check.
The shared 64-trial limit and all final admission checks remain unchanged.

The `STATS deorbit powered-lead` row includes ignition latitude/longitude,
ASL, target elevation, local terrain, geometric hull clearance and the vertical
gate. `hullMode=geometric-radius`, `legacyRadarHull`, `originAsl` and
`originRadar` distinguish the corrected measurement from the old terrain
contamination. These diagnostics remain in the normal archived flight log.
If revalidation fails while still in orbit, use
`RUNPATH("0:/cmd/deorbitretry.ks").` then `REBOOT.` to replan the saved target.

Before deorbit, the shared policy in [landing_radio.ks](lib/landing_radio.ks)
uses `LANDING_RADIO_MODE="AUTO"`. Mun and Minmus are in
`LANDING_DIRECT_KERBIN_BODIES`; `LANDING_RELAY_BODIES` starts empty. Thus a
profile's older `LANDING_REQUIRE_KERBIN=0` no longer silently permits a
far-side landing on those bodies. Once a relay network is ready, add its body
to `LANDING_RELAY_BODIES` in that one file and sync at a connected boot.
AUTO then waives the direct Kerbin requirement for that body across profiles.
Per-flight `DIRECT`, `RELAY` or `OFFLINE` modes explicitly override AUTO.
This is operator-declared relay coverage, not discovery or verification of a
live CommNet route. Existing sunlight, terrain and elevation margins remain.
`cmd/landlight` inherits this policy when its final argument is omitted;
explicit1 selects DIRECT and explicit0 selects OFFLINE for that flight.

At the operator's explicit request, deorbit no longer requires the complete
future landing code to be cached before burning. The normal post-burn band
reboot loads landing libraries through the usual sync/cache path. A lost
link with missing libraries can prevent descent from running; this risk is
accepted rather than blocked by a storage check. Existing guidance tracks
remain cached for later state changes and offline reboots. Site radio policy
and the trajectory, terrain, fuel, staging and throttle safeguards still apply.
No installed bootstrap update is required; pull and reboot while linked.

Native Minmus3 boot026 showed that the full planner and descent code cannot
fit together on its current core. Reducing storage use remains a resilience
improvement, not a prerequisite for deorbit authorization.

APPROACH admission uses hull radar clearance, so a distant mountain's elevation
cannot start terminal guidance kilometres above the local ground. Economy
reboots skip blocking grids around the saved target; precision surveys finish
before powered guidance. Landing temporarily raises IPU to
at least `LANDING_MIN_IPU` (2000, capped at 2000 for the automatic raise), then
restores the previous value on cleanup or the next boot.

The economy profiles enable `LANDING_ECONOMY_BRAKE=1`. Geographic target range
alone cannot start braking: coast continues until the combined horizontal/
vertical stopping envelope requires it. The main horizontal arrest uses the
full available thrust vector while targeting a continuing descent, reserving
enough height for the final vertical flare on the weaker planned stage.
It tapers near velocity capture and keeps the existing reaction, clearance,
staging and physical-cutoff checks. The conservative 80% acceleration budget
remains in the ignition and flare envelopes; it does not cap the economy
main-burn throttle. The RO9 fixed-site Mun profile now enables the same
descending controller while keeping its geographic stopping gates and target
lock; only flexible-site missions suppress the geographic gate.
The RO8/RO9 Mun and Minmus economy profiles and RO9 fixed-site Mun profile
also enable `LANDING_STAGE_BRAKE_CREDIT=1`. On a supported single-engine
serial transfer stage, the ignition calculation credits that stage's remaining
impulse, capped by its own enabled propellant mixture and current-stage dV.
The weaker lander still covers every residual velocity component, with the
80% acceleration reserve, full gravity, clearance and separate reaction and
staging pauses. Unknown fuel, unsupported stacks and atmosphere retain the
whole-stop-on-the-weaker-stage calculation without transfer credit. Full-vector
mode still uses that weaker engine's vector limit. Other profiles default off
for transfer credit. The vector calculation follows `LANDING_ECONOMY_BRAKE`
independently of that credit flag; disabling credit cannot restore the older
triangle calculation while the main burn uses full vector authority.
Above `APPROACH_HSPEED`, the stopping budget uses the engine's vector
thrust limit before applying the existing 80% net-acceleration reserve.
Subtracting gravity directly from horizontal braking had inflated the
reported stopping distance to74 km. The supplied510m/s, -30.8m/s,
223.9m/s-transfer-credit case instead has a calculated gate of about41 km;
this is a stopping bound, not a promised ignition distance or altitude.
At lower horizontal speeds the controller and gate retain the original flare
calculation. In the later RO9 economy report, `stageCredit=0 vectorGate=false`
identified a missed profile setting. The rounded513.2/-18.2m/s,
39.78/2.45m/s2 snapshot reproduces a9.45km vertical gate with the older math;
the matching vector bound is4.50km at that same state even with zero credit.
Those heights use target elevation, not local radar. The gate grows as fall
speed increases, so this is not a prediction of the eventual ignition height.
`STATS landing setup` prints `vectorGate=true`, effective flags and `brakeStageDv`; COAST
shows `vGate`, `height` and `stageDv`, and the saved brake decision includes
the credit. A connected reboot loads the new powered-landing library; no
installed bootstrap update is needed.
Braking waits for the actual facing direction to be within 15 degrees of
the commanded thrust vector and at or above the horizon. The same throttle
guard runs throughout braking and after staging; an urgent stopping gate
does not bypass it. `STATS landing-brake alignment hold/ready` records
alignment changes, and the saved brake decision includes commanded throttle.
During landing COAST, the alignment countdown also owns a vessel-specific
`Landing braking alignment` KAC alarm (`Landing braking burn` without a
target). Its estimate refreshes every five seconds and the alarm is removed
when coast ends or landing finishes/aborts. Guidance remains resident at 1x;
this alarm does not start a burn or replace the live safety gates. Stay with
the craft during descent. Without KAC, the same guidance loop continues.
Descending braking aims at least `LANDING_BRAKE_MIN_PITCH` (1 degree by
default, bounded to 0-2) above the horizon at unchanged thrust magnitude.
An exactly horizontal aim could otherwise let a 0.3-degree tracking error
repeatedly trip the actual engine-below-horizon cutoff. That cutoff remains.
BRAKE now reports `cut=` (`none`, `below-horizon`, `alignment`, `stage-settle`,
`separating`, `no-thrust`, or `zero-command`) and actual facing `up=` beside
throttle, so a zero command can be distinguished from a staging pause.
On2026-10-21, the operator reported the first successful automated **RO9 Mun
economy landing and return to a landing on Kerbin**. The craft retained
497m/s in the lander stage plus654m/s in the return stage on the Mun, then
430m/s before the final circularization trim. This is a working round-trip
baseline; the run included debugging/reboots and a linked return-setup
recovery. Fixed-site accuracy, stage-aware ascent efficiency and an unattended
repeat remain to be established.

These are source-driven model improvements, not a flight-proven optimum.
An RO9 Mun economy retry landed successfully after the alignment and terrain
recovery fixes (operator report, 2026-10-17). Landing fuel cost and the
ascent/return outcome remain unconfirmed. Its flight log records a 12.6 m
guidance miss, a normal-tier site and 830.5 m/s remaining. Broader craft/terrain
coverage is still needed.

If the recovery wait expires or attitude recovery fails after ignition, XING preserves the
unfinished node and holds for the operator, unless the actual trajectory
already supports arrival handoff. It also preserves an interrupted burn
across reboot. It does **not** discard a partial departure and automatically
plan another parking-orbit transfer. **TRANSFER HOLD** has returned to the
terminal, so manual staging alone cannot restart it. After inspecting the
remaining node and trajectory, `RUNPATH("0:/cmd/resumeburn.ks").` explicitly
continues that node **now**, bypassing its already-passed ignition time. It
checks the saved node time and body (when recorded), realigns, and burns the
live residual. This requires the updated maneuver library to be loaded;
ordinary mission resume/reboot still keeps the hold, and the command does
not clear ABORT. A long interruption can make the original trajectory
inaccurate, so this command is an operator decision, not an automatic retry.

If ignition never produced thrust and the node has been deleted, use
`RUNPATH("0:/cmd/transferretry.ks").` then `REBOOT.` to clear the saved
departure-attempt markers and plan a new window. This explicit reset requires
XING, no node, throttle off, ABORT cleared, and a bound Kerbin orbit with Pe
above the atmosphere, Ap at most 500 km, and no SOI transition. Use it only
for a known unflown attempt; these orbit checks cannot prove no fuel was
burned. It preserves the mission, overrides and latest cutoff report. It
does not fix engine activation/fuel problems responsible for `BURN WAIT`.

Long, low-thrust burns can leave transverse node error because a maneuver
node models an instantaneous impulse. The live throttle guard tapers the
remaining component along the craft's thrust direction near cutoff, and
latches off if the powered residual rebounds from its best value. A stopped
burn with residual error is checked against the actual arrival trajectory;
it is not declared precise just because the engines stopped. Controls are
unlocked after cutoff, including failed burns. This is cutoff protection,
not a finite-duration transfer optimizer.

Both maneuver burn modes also integrate actual thrust divided by mass,
independently of the node residual. The delivered-dV cap is the requested
burn plus the larger of 1% or 0.05 m/s; it survives staging within the burn.
The live throttle lock latches off if that cap is reached, ABORT is pressed,
or a positive throttle command goes more than one second without a main-loop
update. After commanding zero, the executor checks actual thrust and attempts
engine shutdown if thrust persists for 0.25 seconds. A forced shutdown is a
failed burn, not a successful completion; inspect the engine before resuming.
These guards require kOS and KSP to keep executing and can stop a long finite
burn early. They have numerical coverage, but still need flight validation.

End-of-burn cutoff is shared through `lib/thrust_cutoff.ks`: maneuver,
compact deorbit, ascent, rendezvous, landing, hop, disposal and atmospheric
correction burns clear cooked, raw and pilot throttle, verify actual thrust,
and check again after releasing control. Persistent thrust triggers a bounded
engine-shutdown attempt; a forced shutdown or failed stop holds the mission.
`cmd/burnreport.ks` prints the latest shared cutoff record. Burn owners must
stop issuing positive commands before calling the checker.

Vacuum APPROACH and TARGET_REFINE are limited to `TERMINAL_ALT` (1000 m by
default). A completed early brake above that corridor returns to coast when
the stopping envelope allows it. A passed target cannot masquerade as a
horizontal stopping point ahead of the craft; urgent vertical/terrain braking
remains active. These guards do not implement a fuel-optimal landing footprint
or an approach fuel budget. See the [flight validation plan](docs/FLIGHT_SEQUENCE_VALIDATION.md)
for the airless sequence and atmospheric follow-up.

The executor temporarily raises `CONFIG:IPU` to `BURN_MIN_IPU` (2000 by
default, capped at kOS's maximum) before installing the live governor, so
its high-priority calculations leave time for the main loop. It restores
the previous setting after cutoff or at the next boot after interruption.
The one-second stale-command cutoff remains active.

Maneuver engine limiting uses measured available acceleration and
`BURN_MIN_FULL_THRUST_SECONDS` (2 seconds by default). It scales existing
engine limits only when the full-throttle impulse would be shorter than that;
longer burns use available power. Remaining-dV/control-latency tapering still
reduces throttle near cutoff. There is no separate half-throttle ceiling
below 10 m/s. `STATS burn setup` records `thrustScale` and the resulting
`maxAcc`; the duration floor describes the full-power impulse, not the final
elapsed time including precision tapering or alignment pauses.

After the next maneuver, run `RUNPATH("0:/cmd/burnreport.ks").` to see planned
and measured thrust dV, the independent cap, residual, cutoff reason, and
whether thrust stopped. This compact record survives phase reboots even if
the log fills; the next maneuver replaces it. It cannot reconstruct an older
burn flown before this update. `RUNPATH("0:/cmd/logs.ks").` archives the current
boot's log when connected to KSC.
The report also prints the saved attempt status and **current** engine
activation, flameout, thrust limiter and staging information. `BURN WAIT`
means the executor is waiting for usable thrust; the previous cutoff report
alone may describe an earlier maneuver. The throttle watchdog refreshes its
timestamp before publishing positive throttle, preventing an intentional
zero-throttle setup or staging wait from being mistaken for a stale command.

After reloading a save following departure, XING checks the actual encounter
before considering the retained node. A departure marker survives burn
cleanup until the next phase is saved, preventing a second departure plan
in that save window. A valid encounter can proceed to arrival correction;
otherwise the mission holds. Older saves can only use the markers they
already contain.

For a Minmus mission whose sequence includes **BPLANE**, if the departure is
already flown but XING holds, inspect the actual orbit and remaining fuel.
To keep the mission and request an arrival correction instead of replaying
the departure, use `RUNPATH("0:/cmd/setphase.ks", "BPLANE").` then `REBOOT.`
from the manual terminal while linked. BPLANE can attempt to reacquire a
near miss within its correction budget; a Minmus encounter/landing is not
guaranteed. Do not use `resumeburn.ks` to replay an overshot departure.

### Multi-leg flights

Airline-style missions (land, swap passengers, fly on) and drone sorties end
each leg normally, then `RUNPATH("0:/cmd/restartflightplan.ks").` archives the
leg's log, rewinds `phase` to the start of the sequence, stamps a fresh
`launch_time`, and reboots. Mission config is untouched.

## Architecture

### Boot chain

`boot/boot.ks` (initially installed in the VAB) syncs only
`lib/boot_lib.ks` + `lib/dependencies.ks`, then delegates: preamble/core
libs load, EVA kerbals are auto-detected (root part `kerbalEVA`), `CORE:TAG`
routes tagged CPUs to `roles/`, untagged CPUs load `craft/<vehicle>.ks`.
The selected mission id is persisted in state. The profile itself is copied
to `1:/missions/<vehicle>/` and run on every boot; profiles are executable
config scripts made of `SET NAME TO value.` lines. Runtime config overrides
live in `1:/run/mission_overrides.ks` as the same kind of `SET` lines;
that file is overwritten by the command/phase that owns the current override
set, never synthesized from state.
Boot plans the library band from the selected mission/phase every boot,
compiles it to KSM (comments cost nothing), prunes stale files, runs the
vehicle defaults, then re-runs the mission profile so mission/body overrides
win before resume. The planned library list is deliberately not cached in
state; if storage runs out mid-boot, the next connected boot can recover the
selected mission from `mission_id` or the cached profile copy.

Craft, role and archive mission scripts use the same compile/copy installer as
libraries. Local execution selects an explicit `.ksm` filename first, then
`.ks`, then a legacy extensionless file. This fixes deployed probes whose
old bootstrap copied `craft/RO9` without an extension while offline discovery
looked only for `.ks` or `.ksm`. Cached compiled profiles retain their exact
mission ID. Profiles generated during flight remain source; rewriting one
invalidates any older bytecode with the same name. Missing craft/profile code
holds the mission instead of continuing with empty defaults.

Existing probes need the revised **installed bootstrap** to compile craft code
on connected boots. While linked, with thrust and both throttle controls zero,
run `RUNPATH("0:/cmd/updateboot.ks").` and reboot when ready. The command compiles
the current archive source in kOS, copies it to an alternate local boot file,
then selects that file using `CORE:BOOTFILENAME`. It preserves the previously
selected boot file and does not change the mission or phase. The following
connected boot installs the craft and selected archive profile as `.ksm` files
for later offline boots. The updated `boot_lib` also recognizes legacy bare
craft files with an older bootstrap, but that bootstrap still needs updating
to use the uniform installer.

### Phase machine and sequences

Mission profiles own `SEQUENCE` — the ordered phase names. Craft scripts map
phase names to handlers and call `runPhases(phaseMap)`; each handler calls
`nextPhase(seq)` when done. The current phase persists to state, so any
reboot resumes exactly where it left off. Shared phases follow the naming
convention `PHASE_NAME -> phasePhaseName`; explicit bindings map the current
phase string to the matching handler after the phase's band is loaded.

### Progressive loading (bands)

Storage is the scarce resource (OCTO = 10 KB, big cores ≈ 100 KB), so code
loads in **bands**: groups of phases whose libraries load together. When the
sequence reaches a phase outside the loaded band, the machine saves
`reload_*` state and asks for a reboot; the next boot loads only the new
band. **A band loads the libraries of every phase in it**, regardless of the
mission — so per-mission code (e.g. ScanSat disposal) lives in its own
phase/band rather than inside a shared band.

### dependencies.ks

`lib/dependencies.ks` is the boot dependency source of truth:

```
dependencyLibs()["core"]         roots loaded always
dependencyLibs()                 library dependency edges
dependencyPhases()               libraries a phase needs
dependencyBands()                phases that load together
```

### State, logs, telemetry

- **State**: native kOS JSON at `1:/run/state.json` via
  `stateGet`/`stateSet` — never raw file I/O for mission state. Survives
  reboots, quickloads, power loss. Legacy SimpleJSON state can be converted
  once with `RUNPATH("0:/cmd/convertstatejson.ks").`.
- **Flight log**: `mLog`/`mLogWarn`/`mLogError`; `STATS ...` summaries and
  non-INFO events are persisted by default. Ordinary INFO chatter stays on
  the console; `LOG_INFO_TO_FILE = 1` enables it in files too.
  Each boot writes a numbered per-core log under `1:/run/logs/<flight>/`;
  archive copies land in `0:/logs/archive/<flight>/` after persisted lines
  when linked and at phase transitions. `LOG_FILE_RESERVE_BYTES` leaves
  1,024 bytes free by default; a console warning reports when further file
  logging is suppressed to preserve room for mission state. Logs cannot
  reconstruct console-only diagnostics from older flights.
- **Observation telemetry** (`lib/observe.ks`): periodic one-line samples
  streamed straight to `0:/logs/obs/` when linked (offline lines buffer
  locally and flush on reconnect). `cmd/airtest.ks` drops the interval to 1 s
  for PID tuning.

### Storage model

`0:/` is the archive (unlimited, KSC link required); `1:/` is the local
volume. Source compiles to KSM before upload, so comment liberally in `.ks`
files. Once out of link range nothing new can be fetched; everything a
mission might need must be loaded while connected. On storage-constrained
cores, keep per-mission behavior in its own phase/band, avoid persistent
derived state, and use `RUNONCEPATH("0:/cmd/trimstate.ks").` to clear the old
`lib_band_libs` key if an upgraded vessel is stuck on a full local volume.

## Vehicles

| Craft | Type | Notes |
|---|---|---|
| `FR2` | Multi-payload launcher | Legacy name-driven flights + profiles |
| `FR3` | Multi-payload launcher | Banded loading, profile-first, rover/mapper missions |
| `Falcon` | Crew/science launcher | Banded profile flights for crew, tourists, and science returns |
| `FalconHeavy` | Heavy Falcon variant | Falcon plumbing for heavier moon/interplanetary payloads |
| `FJ1A` | Juno trainer jet | `airplaneMain()` configuration |
| `FJ4B` | Supersonic jet | No landing assist — pilot owns the rollout |
| `FBIJ` | Business jet | GAP airline missions, multi-leg, touch-and-go aware |
| `FSP1` | Seaplane | SPLASHDOWN/SURFACE_OPS water phases |
| `FSS1` | SSTO spaceplane | Template for the Whiplash/RAPIER era |
| `FDR1` | Hover drone | Kerbin (lift engines) and Mun/Minmus (RCS) |
| `ROVER` | Surface rover | Waypoint driving + science |
| `X_SHOT` | Sounding rocket | SHRIMP thermometer/barometer drops |

### Rockets (FR2 / FR3 / Falcon / FalconHeavy)

Modern profile sequence: `PRELAUNCH, LAUNCH, FAIR, ANTS, PARK, XING, BPLANE,
COAST_1HALF, REFINE_BPLANE, COAST_2HALF, CAPTURE, SHAPE, <payload phases>,
DONE`. Older profiles may still use `MCC` or a single `COAST`. Payload tokens
(`RELAY`, `SCANSAT`, `SCISAT`, `PROBE`, `CRASHPROBE`, `LANDER`,
`ASSISTLANDER`, `ROVER`, `ASSISTROVER`) come from the profile or the legacy
ship name and append their phases automatically. MechJeb flies the ascent.
PARK waits for MechJeb ascent to finish its circularization, then
verifies zero thrust/throttle before handing control to the next phase.
The broad parking-altitude gate alone is insufficient while circularization
is still running. A controller still active after 120 seconds is stopped and
the mission holds in PARK with its nodes retained for review.

If an older launch reaches XING with an expired small circularization node,
the departure corridor check rejects it. Inspect and delete that stale node
in the map, then `REBOOT.` to let XING create the actual transfer. Keep the
departure Pe corridor intact; a missing encounter is not a solved bad Pe.
The installed addon exposes `ASCENT:ENABLED`; the handoff uses that signal
and does not require the newer top-level `NODE` interface.

FR3 adds targeted rover landings (Trajectories deorbit + named/selected
waypoints, optional SCANsat site scan), Mun mapper impact-disposal flows, and
the emergency `mun_rover_emergency_surface` profile. FalconHeavy carries the
new Duna set: polar SCANsat, direct Duna lander, Duna/Ike SCISat lander, and
paired high Molniya-style Duna relays.

### Aircraft

All planes are thin configurations over `airplaneMain()` (`lib/airplane.ks`):
PREFLIGHT (checklist + trim/reverser reset) → FLIGHT → POSTFLIGHT, with
touch-and-go awareness via `MIN_FLIGHT_TIME`/`FINAL_LANDING_SPEED`.

Assists (PID, gains in `PLANE_CFG`): **AG7** toggles the autopilot (wing
leveler + altitude hold + heading hold), **AG8** flies to the Waypoint
Manager selection. Heading hold turns by **banking** (`HDG_BANK_SIGN` is the
per-airframe escape hatch); altitude hold flies vertical speed; control
authority gain-schedules with dynamic pressure. Thrust reversers engage
automatically at touchdown when **brakes are held** (a touch-and-go never
brakes) and stow on bounce, brake release, or full stop.

Shakeout: from manual mode, airborne, run `RUNPATH("0:/cmd/airtest.ks").` —
scripted step inputs for each assist with metrics logged; it detects and
flips a wrong `HDG_BANK_SIGN` automatically.

Approach data (runway position/headings/glideslope) lives in
`PLANE_APPROACHES` (KSC, Island Airfield) plus optional hand-maintained
entries in `0:/data/approaches.json`.

### SSTO spaceplane (FSS1)

`lib/ssto.ks` bridges the air and orbital worlds:
`PREFLIGHT, AIRCLIMB, ROCKETCLIMB, <any orbital work>, SSTO_DEORBIT,
REENTRY, APPROACH, DONE`. AIRCLIMB holds the airbreathing sweet spot until
thrust decay; ROCKETCLIMB toggles `SSTO_MODE_AG` (bind engine-mode/rocket
ignition there in the editor), flies a pitch program, and circularizes —
after that the spaceplane is a normal orbital vessel (goto works). Return is
a ground-track-lead deorbit, an AoA reentry hold, then glideslope+localizer
to a known runway with decision-height callouts. Engine-agnostic by config:
a Whiplash+rocket build just lowers `SSTO_SWITCH_SPEED`.

### Hover drone (FDR1)

`lib/drone.ks` — guidance ported from the ozin370 quadcopter. Two styles via
`DRONE_STYLE`: **TILT** (throttleable lift engines + reaction wheels, Kerbin)
and **RCS** (level-attitude translation for Mun/Minmus kerbal transport —
no tilting). Modes: **AG7** hover, **AG8** fly to the selected waypoint,
**AG9** land (radar-scheduled flare).
Terrain-lookahead altitude floor, low-fuel/EC autoland, sorties chained with
`restartflightplan`. Sequence: `ARM, FLY, DONE`.

## Mission profiles

Executable config files under `missions/<vehicle>/`, selected from the pad
picker or forced via `stateSet("mission_id", "<id>").` + reboot. The profile
owns the phase order; the craft script owns the hardware. Values are direct
global assignments read by the libraries.

```ks
SET MISSION_ID TO "mun_sat_delivery_3".
SET MISSION_NAME TO "Mun Satellite Delivery Contract 3".
SET TARGET_ TO "MUN".
SET PAYLOADS TO LIST("SCISAT").
SET SEQUENCE TO LIST("LAUNCH", "FAIR", "ANTS", "PARK", "XING", "BPLANE", "COAST_1HALF", "REFINE_BPLANE", "COAST_2HALF", "CAPTURE", "SHAPE", "RELAY_OPS", "DONE").
SET CAPTURE_PE TO 95789.
SET CAPTURE_INC TO 138.9.
SET CAPTURE_LAN TO 51.5.
SET SHAPE_AP TO 903586.
SET SHAPE_PE TO 95789.
SET SHAPE_INC TO 138.9.
SET SHAPE_LAN TO 51.5.
SET SHAPE_AOP TO 269.
```

Boot derives the libraries to load from `SEQUENCE`. `LIBS = ...` replaces the
computed list (escape hatch); `LIBS_EXTRA = ...` appends. While prelaunch,
boot clears any saved profile so a pad reboot re-opens the picker; after
launch, reboots keep mission and phase.

### RO8 moon landing and return

Arrival precision is budgeted separately from reaching the moon. Both RO8
profiles limit corrections of an existing encounter to 10 m/s per burn and
20 m/s total across BPLANE/REFINE_BPLANE, preserving 900 m/s on the Mun mission
or 400 m/s on Minmus according to stock vacuum dV. Optional corrections may
shift SOI entry by at most 600 seconds and raise the estimated periapsis
capture cost by at most 5 m/s. A real patch with an unusable B-plane
measurement holds instead of invoking lost-encounter acquisition. An
unconverged optional correction is never burned as a partial improvement.
During early `BPLANE`, a safe future airless encounter with the normal
`COAST_1HALF → REFINE_BPLANE` sequence hands that retry to midcourse
automatically. The mission stays active, maintains solar attitude, sets its
midpoint alarm and retries when the running coast reaches the wake time.
KAC stops warp; the coast loop performs the continuation. An overdue saved
midpoint retries immediately. The required polar plane and all correction
budgets are still checked by refinement before a burn or capture handoff.

This pre-SOI wait checks the current parent orbit's clearance and the direct
future encounter. The target's review Pe floor does not apply to waiting:
the reported 8.44 km Mun Pe can still be corrected before arrival from a
safe 78.3 km Kerbin orbit. Actual arrival/capture Pe and plane gates remain.
When a correction leaves the hypothetical Kerbin Pe inside its atmosphere,
the wait instead requires a finite elliptical time-to-atmosphere proof: the
moon encounter must precede atmospheric entry by `SOI_BUFFER_TIME` (120 s).
`STATS bplane parent-coast` reports those ETAs and the clearance decision.
Current atmospheric entry, invalid data or an unproven coast still blocks.
Converged corrections at or below the shared 0.3 m/s execution minimum are
removed and deferred through the same live retry path. A small residual
outside the strict plane tolerance therefore stays assigned to midcourse;
skipping a tiny early burn does not approve capture or abandon refinement.
After a failed midpoint refinement, the next full solve is a single final
check, normally **15 minutes before SOI entry** (`BPLANE_FINAL_REFINE_LEAD=900`).
The former policy repeatedly halved the remaining window and produced
shorter, unnecessary retry intervals. The final wake stays outside the
existing SOI/burn safety margin even if a shorter lead is configured.
A named `B-plane retry` alarm and the shared solar/clock loop keep the
mission running. The pending wake and completed checkpoint survive reboot;
small encounter-ETA changes cannot manufacture another final check.
Explicit arrival `replan` or a flown correction clears that checkpoint.
`STATS bplane retry-resume ... solvingNow=True` marks the final solve;
`retry-blocked ... after=...` records why that attempt was rejected.
`final-refinement-checkpoint-used` can follow a below-minimum correction;
it does not mean the scheduled wake was skipped.
Without KAC, the clock loop still wakes; battery/warp health checks remain.
When KAC is available, a separate `<vessel>: SOI: <body>` alarm is created
from the native encounter during BPLANE and before the midpoint/final waits.
Corrections refresh its time from the actual orbit; temporary maneuver
predictions do not retime it. Cleaning a retry alarm leaves the SOI alarm
intact, and the normal arrival wait removes it after SOI entry. Cached
alarms must still be future-dated and match the actual requested time.
`STATS soi-alarm` records the target, absolute UT, ETA and alarm ID.
Both B-plane solver modes also bound the node time to stay before native
SOI entry, retaining the 120-second SOI buffer and at least 30 seconds of
node lead. A late boot must not place a default 300-second-ahead correction
inside the target body's patch. The planner settles warp before choosing
that time, then rechecks lead and predicted entry after solving.
`STATS bplane node-time` and `STATS bplane timing` record these margins;
an exhausted window holds with `insufficient-pre-soi-burn-lead`. A late
window may still be too short to solve, align and execute safely.
If the final attempt still fails, no safe
retry window remains, or a mission correction violates its admission limits,
`ARRIVAL BLOCKED` prints the reason, settles warp to 1x and returns to the
Godspeed prompt for manual control. The saved phase stays unchanged; it
does not fly the rejected node, advance to capture or require an Abort toggle.
Timed `ARRIVAL RETRY` waits continue running and resume automatically at their
scheduled checkpoint; only a blocked arrival yields to the prompt.

RO9's Mun polar science mission has a separate correction allowance: 100 m/s
per early/refinement burn, 150 m/s total, plus a 900 m/s margin after predicted
capture. The reported 10 m/s cap left its required polar plane 70° away.
Its subsequent SHAPE allowance is 60 m/s per burn and 80 m/s total, including
the roughly 44 m/s required to lower the deliberately captured 100 km
apoapsis to the 15 km science orbit. The old 10/20 m/s cleanup allowance
could not perform that requested circularization. The 650 m/s SHAPE reserve
remains a burn-admission floor, not proof of a landing and return budget.
`STATS shape budget` includes per-burn/total caps and separate `burnOk`,
`totalOk`, `reserveOk` decisions. After archive sync, a connected reboot in
SHAPE replans from the retained orbit using this profile; it does not refund
previous shaping expenditure or skip the requested orbit.

When reusing a satellite for another orbital contract, cumulative SHAPE
spending carries across profile switches on the same body/launch. At an idle
SHAPE budget hold with no maneuver node, use
`RUNPATH("0:/cmd/shapebudget.ks",1500).` then `REBOOT.` to grant1500m/s
of further allowance. This changes only the cumulative cap to recorded
spending plus the requested allowance; it preserves the ledger, per-burn
cap, physical fuel reserve, targets and mission. A new body/launch starts
from zero as in normal SHAPE admission. This does not ignite or stage.
SHAPE now settles warp before planning/retries, including shared plane
matching, and checks finite node lead of at least60s before charging a burn.
An expired candidate holds with `budgetCharged=False` rather than consuming
allowance on a node that is already too late to execute.

Plane matching seeds a full velocity rotation, including the retrograde
component needed to preserve orbital speed. On eccentric orbits it also
projects the change onto the radial node axis. Native predicted patches
choose axis signs and retain the existing bound-orbit/periapsis checks
before refinement. `STATS plane-match plan` records
`seedModel=velocity-rotation` and the three seed components. A failed
refinement or an unaffordable correction still holds without burning.

`SHAPE_MIN_BURN_DV` (default **0.4 m/s**) applies to every final SHAPE and
DEPARTURE_SHAPE node: plane, AoP and apsis corrections, including nodes that
shrink during refinement or retry. Sub-minimum trims are removed before
budget admission, alarms or execution. The planner can continue with another
useful correction; if only tiny corrections remain outside the configured
orbit tolerances, it holds at the prompt with those errors rather than
declaring success. `STATS shape decision=skip` records the label, exact dV,
floor and ETA; `STATS shape execution` records admitted burns and live errors.
The `set-pe-for-ap` fallback is used only when the desired Ap really is below
the current Pe, never just because a normal AP trim was below the minimum.

Precision orbit profiles can explicitly lower `SHAPE_MIN_BURN_DV` and set
`SHAPE_BURN_TOLERANCE` to a finer executor residual (minimum 0.001 m/s).
The residual override applies only during each SHAPE/DEPARTURE_SHAPE burn;
the previous executor settings are restored on success or failure. It never
loosens an already stricter cutoff. All throttle, alignment, staging, impulse,
budget and final orbit checks remain active. `SHAPE_MIN_PE` defaults to
10,000 m and is shared by plane and apsis refiners; an explicit airless-body
profile may choose a different safe floor. Atmospheric bodies always retain
at least atmosphere height plus 10 km. A target Pe corridor entirely below
the floor holds before planning, with the conflicting values in the log.

An interrupted SHAPE burn now holds with its node intact, including on reboot.
After inspecting the orbit, run `RUNPATH("0:/cmd/shaperetry.ks").` and then
`REBOOT.` to calculate the remaining corrections. The command requires the
matching interrupted SHAPE/body, stable orbit, Abort clear and zero physical,
raw and pilot throttle; it clears only the attempt and matching next node,
retaining the budget, profile, overrides and last burn report. If an older
version left a different retry node, it preserves that node: inspect it and,
if unwanted, `REMOVE NEXTNODE.` before retrying the command.

The executor distinguishes its full-vector live cutoff sample from the
residual measured after thrust settles. Only a recorded `live-node-trim`
sample within tolerance allows a bounded final-sample settling margin:
the smaller of half the tolerance and 0.001 m/s. Thus a 0.001 m/s cutoff
allows a final sample up to 0.0015 m/s; it does not raise the throttle cutoff
target. Axis-only trims, invalid evidence and larger residuals remain subject
to the strict check; physical-cutoff and watchdog faults still fail. Cutoff,
sampled residual and acceptance limit are logged to nine decimal places.

The fixed-site RO9 Mun profile also permits up to 10 m/s of normal correction
in its deorbit burn. It prefers cross-track error below 250 m. At the operator's
request its deorbit cross-track limit is now 2 km, allowing the reported
1.563 km miss to proceed to powered validation. Its separate 1,500 m landing
target tolerance is unchanged; admission is not a promise of touchdown accuracy.
Other profiles retain their existing cross-track limits. Its locked
contract coordinates and light policy remain unchanged. The deorbit search
tries one burn angle across the available windows before alternate angles;
all trials still share the 64-evaluation limit. This profile first surveys up
to one Mun rotation for the eight closest unburned ground-track passes, then
tests those passes with Trajectories. Eight consecutive orbits can miss a
fixed site after its usable approach has already passed. The setting is
`TARGET_DEORBIT_PASS_LOOKAHEAD_ROTATIONS=1`; zero retains consecutive windows.
`STATS deorbit fixed-pass` reports each ranked pass UT and unburned miss;
these are seeds, not approved landing predictions. A selected pass may be
many hours away. The executor installs its KAC alarm before solar hold,
remains running through the coast, and rechecks geometry, terrain, fuel and
light before alignment. No installed bootstrap update is needed.
Far-downfield footprints first get a bounded retrograde-only refinement
before the timing/normal solve; `STATS deorbit range-seed` records its progress.
A hold now ends with
`STATS deorbit best-rejected`, showing the closest footprint's geometry
reason, light result, window, retro/normal dV, downfield/cross-track distance,
cross-track limit, impact angle and Pe. A budget stop is not proof that the
target is unreachable. After sync, a connected reboot in LAND_DEORBIT replans.
The full solver now uses a minimum-length Newton step across prograde,
radial and normal axes, with up to 16 iterations. Both line-search/total
caps and the 600-second arrival-shift/5 m/s capture-cost-increase limits
remain. These changes have source/numerical checks; native flight convergence
still needs verification.

These checks apply to retained maneuver nodes on reboot as well as new
plans. Operator previews, explicitly configured candidate review, and
interrupted burns retain the manual review policy. They do not enable
automatic retry or silently waive polar orbit/landing-site requirements.
Manual arrival holds schedule a named `Arrival review: <body>` KAC alarm at the
anchored midcourse checkpoint, or request immediate review if it is overdue.
The log prints its UT, remaining seconds and `automaticResume=False`.
This is an operator-review alarm: it does **not** restart refinement or approve
a rejected correction. If timing or KAC is unavailable, the log says so.
Explicit manual holds return to the prompt; boot does not start its
indefinite fallback solar hold afterward. No installed boot replacement is
needed. `RUNPATH("0:/cmd/arrival.ks", "status").` reports the encounter and
budget; the existing `plan`, `review`, `accept` and `replan` actions remain
explicit operator choices.

SHAPE separately has a 10 m/s per-burn / 20 m/s total cap and a 650 m/s Mun
or 200 m/s Minmus reserve. These are conservative capture/landing fuel
floors, not proof that landing or return is affordable. Budgets reserve the
planned burn cost before ignition and survive reboots; an interrupted burn
does not refund its allowance automatically. Genuine lost-encounter recovery
retains its separate existing cap; it is not treated as an optional trim.

For the reported 899 m/s Mun flight with a retained 150 m/s node, a connected
reboot into updated BPLANE rejects the correction before ignition (or clears
it and advances if the original encounter already meets the corridor).
`STATS bplane baseline`, `budget`, `comparison`, `plan`, and `decision=hold`
records explain the unburned encounter, candidate geometry and acceptance
decision. `python3 -B scripts/check_arrival_budget.py` exercises the budget,
resume, logging and capture-estimate predicates; flight validation is still
required.

A converged correction at or below the shared0.3m/s execution floor is removed.
If the unburned encounter is safe, within its permitted Pe/plane corridor and
has capture/reserve fuel, mission execution continues through the normal SOI
coast; a consumed retry checkpoint cannot block this no-burn handoff. The SOI
alarm is retained/refreshed. `BPLANE_MINIMUM_PE_TOL` optionally sets a coarser
Pe corridor for this case; its default retains `BPLANE_PE_TOL`. RO9 Kolniya
and Tundra profiles allow1500m and use matching7.8–10.8km capture limits.
Their required1deg arrival-plane limit and final100m/0.1deg SHAPE objective
remain. Unsafe/out-of-corridor encounters still hold for review.

For the fuel-limited RO8 already approaching the Mun, `munrecover` retains
its **polar survey and targeted landing** objectives. With an archive link
and the updated archive synced, run at the craft console:

```kerboscript
RUNPATH("0:/cmd/munrecover.ks").
REBOOT.
```

This replaces old nodes and runtime overrides, clears stale coast timing,
and resumes at BPLANE (CAPTURE if already inside the Mun SOI). It does not
repeat XING or reset the accumulated arrival-correction fuel ledger. Rerun
this command if an earlier recovery version left a Pe-only/equatorial node.

The recovery targets **15 km Pe / 100 km Ap, 90° inclination**, with LAN free
for the planner to choose. `BPLANE_REQUIRE_PLANE=1` forbids Pe-only fallback
or a safe-encounter handoff outside the requested plane. Before ignition,
the actual node patch must satisfy both Pe and inclination tolerances
against the nominal targets, or the targets explicitly accepted below.
Initial corrections are capped at 150 m/s, midpoint corrections at 10 m/s,
and the cumulative allowance is 160 m/s. A plane change can cost more than
the previous 50 m/s Pe-only ceiling; the planner must still leave predicted
capture cost plus 50 m/s, and CAPTURE rechecks its actual node cost. These
are capture margins, **not a guarantee of landing or return fuel**.

With `BPLANE_REVIEW_UNCONVERGED=1`, a partial solution is retained for
operator review when it has a real encounter, Pe at least 10 km, and passes
the correction/capture fuel checks. No burn occurs and no budget is charged
while presenting it. The console logs actual Pe, inclination, latitude reach,
node ETA, and capture estimates for 50, 100 and 500 km apoapsis. A 27 km Pe
and 7.81° error from polar still reaches both survey latitudes; it need not
be discarded just because it missed the nominal 15 km / 90° request.

After syncing the update, reboot the held BPLANE craft while connected to
load it and replan. At the retained-candidate prompt, inspect the map, then:

```kerboscript
RUNPATH("0:/cmd/arrival.ks", "accept", 100).
```

The command loads its own core, saved mission's band libraries, craft script,
and resume support, then reapplies the mission and runtime overrides. It can
run from a fresh console without relying on functions left by boot; this
setup preserves the retained node and review record. After syncing a command
fix, rerun `arrival.ks` directly rather than resetting the mission. Loading
takes time, so acceptance still checks the node's remaining ETA afterward.

This **accepts and resumes execution** with a 100 km capture Ap. Use `50`
for a 50 km Ap, or `500` for a higher, cheaper initial capture; omitting the
number keeps the configured Ap. At a fixed Pe, a lower capture Ap requires
more braking. The command rechecks fuel for the selected Ap before changing
any targets. Capture estimates are impulsive and do not guarantee the
low-thrust burn or landing budget.

Acceptance saves the node's actual Pe and inclination as the capture and
SHAPE targets, plus matching capture Pe limits. They survive reboots without
waiving future correction budgets; the landing coordinates and temperature
survey remain unchanged. Other runtime overrides are retained. Do not rerun
`munrecover` after accepting unless you intend to discard these overrides.
Acceptance requires the exact reviewed node, mission, body and phase; an
expired/changed node cannot inherit approval. Reboots hold a pending review
rather than automatically executing it. **Game time continues during review.**
To discard it and generate a fresh candidate at a future burn time:

```kerboscript
RUNPATH("0:/cmd/arrival.ks", "replan").
```

For `pe-recovery-outside-corridor`, inspect with `arrival.ks` action `status`.
Pe-only corrections now solve toward the middle of the arrival corridor
(500 m planning tolerance for the usual 2 km acceptance tolerance), and use
a smaller executor cutoff for admitted burns. Both solver modes share the
same admission check: a correction of **0.3 m/s or less is discarded**, rather
than scheduled. Saved nodes and execution admission use that same predicate.
The old Pe-only return bypassed this check and could schedule a 0.1 m/s node.

For airless Pe-only arrivals, early `BPLANE` leaves fine targeting to the
following `COAST_1HALF` / `REFINE_BPLANE` pair when the actual unburned encounter
is safe: Pe at least 10 km, within the coarse `BPLANE_EARLY_PE_TOL` (default
10 km) of the requested Pe, enough time before SOI entry, and fuel for capture,
its reserve and a later correction. This avoids steering and burning merely
to perfect an early Minmus Pe. There is no distance-based 0.5 m/s rule.
Set `BPLANE_EARLY_PE_TOL=0` to disable this deferral. Missing/unsafe encounters,
plane requirements, absent refinement phases and insufficient time/fuel keep
the ordinary solve/hold path. Midcourse still uses the original fine corridor;
discarding a tiny node never declares an out-of-corridor arrival successful.

A failed correction holds with its node retained, rather than deleting it
and blindly retrying. Explicit
`arrival.ks` action `replan` can discard an interrupted BPLANE/REFINE_BPLANE
correction and clear its interruption state before planning from the actual
flown orbit, including recovery from older saves whose node was already
deleted. It preserves correction spending and all fuel/capture limits.
This action does not apply to an interrupted XING departure. `status` does
not execute a burn; `replan` resumes automatic planning and execution.

For a real encounter held with `pe-recovery-not-converged-within-budget`,
`status` now prints the effective correction cap as well as the raw encounter
and capture estimate. Economy profiles normally allow only 20 m/s per arrival
correction and 30 m/s cumulatively, independent of fuel remaining onboard.
The Pe-only solver now measures all three node axes, projects trial corrections
inside the total dV limit, restores the best candidate after rejected trials,
and accepts the configured Pe corridor if the tighter internal aim is
unreachable. It does not force an equatorial or polar plane.

To explicitly allow up to **100 m/s of further corrections** and inspect the
result before burning, run with an archive connection after sync:

```kerboscript
RUNPATH("0:/cmd/arrival.ks", "budget", 100).
RUNPATH("0:/cmd/arrival.ks", "plan").
```

`budget` changes only correction allowances in the persisted override file;
the total cap becomes previously spent/reserved dV plus the requested amount.
It preserves the spent ledger, existing mission targets, plane requirements,
and capture/return reserves. For the Mun economy landing mission, correction
plus capture must still leave 1,500 m/s. The argument is an allowance, not an
estimate of the correction's actual cost.

`plan` removes stale pending nodes and previews from the flown trajectory,
without burning or advancing the mission. It refuses an interrupted burn or
ABORT state. A usable candidate is retained for review, including the capture
estimate at the configured apoapsis and fuel remaining after both burns.
Normal budget checks still reject an unaffordable correction/capture. Use
`arrival.ks` action `accept` to execute a reviewed candidate and resume; use
`plan` again if the node expires. A pending review also holds across reboot.
These commands do not diagnose whether an earlier transfer miss was throttle
overrun or finite-burn trajectory error; retain the `STATS burn cutoff` and
`STATS burn result/abort` lines for that distinction.

SHAPE verifies the accepted capture ellipse without requesting circularization;
its cleanup allowance is 10 m/s per burn, 20 m/s total, with a 50 m/s reserve.
SCIENCE_OPS runs the available experiments once, then holds for the contract
survey (`SCIENCE_OPS_HOLD=1`). The hold prints the `setphase` command for the
next phase in the active mission sequence, followed by `REBOOT.`. It does
not advance automatically. It does not fly temperature waypoints or check
contract completion. The saved temperature sites are **66.765° S, 0.528° E**
and **39.831° S, 17.824° E**, both **above 10 km ASL**; the console prints
these at the hold. Complete those readings and review remaining
fuel before advancing to the landing site (44.593° N, 24.926° W):

```kerboscript
RUNPATH("0:/cmd/setphase.ks", "LAND_DEORBIT").
REBOOT.
```

LAND_DEORBIT, LAND_ASSIST and SURFACE_RETURN_SETUP retain the original Mun
mission's site and return settings. A safe bound orbit is accepted on a
capture reboot, but SHAPE still checks inclination before survey/landing.
The optional SOI-entry-time and relative capture-cost limits are disabled
only in this recovery profile; geometry changes can change both, so recovery
checks the requested corridor and absolute capture affordability instead.
`STATS bplane comparison`, `plan`, `capture-budget`, `decision=hold`, and
`STATS capture budget` record the decisions. Offline checks:
`python3 -B scripts/check_mun_recovery.py` and
`python3 -B scripts/check_arrival_review.py`; actual convergence and flight
execution still require flight testing.

RO9's `minmus_polar_hops_return` runs a programmed four-site surface route
between two specified Minmus orbits. Select it from the fresh-mission picker.
All apsides below are metres ASL; angles are degrees.

| Leg | Ap | Pe | Inclination | LAN | Argument of Pe |
| --- | ---: | ---: | ---: | ---: | ---: |
| Initial polar orbit | 1,064,182 | 444,576 | 90 | 298.9 | 244.9 |
| After site D and ascent | 659,734 | 554,472 | 0 | Unspecified | 0.4 |
| Assisted Kerbin entry | — | 53,000 | Unspecified | Unspecified | Unspecified |

After SHAPE completes the polar objective, LAND_PREP lowers the orbit to
9.3 × 19.3 km while retaining the polar plane. Targeted deorbit lands at A;
the new `HOP_ROUTE_SETUP` phase arms B–D and saves the original return plan.
Hops use their own bounded launch burn followed by `LAND_ASSIST`; their
sequence does not include the original PRELAUNCH/LAUNCH/transfer phases.

| Site | Latitude | Longitude | Arrival |
| --- | ---: | ---: | --- |
| A | -1.080 | 1.365 | Initial landing |
| B | -1.190 | 1.596 | Hop 1 |
| C | -1.554 | 2.780 | Hop 2 |
| D | -3.029 | 2.189 | Hop 3 |

At **each of A–D**, `HOP_AUTO_REVIEW` requires settled surface contact,
sets brakes and a KAC alarm, attempts available experiments once, then waits
**600 seconds of game time at 1x** before continuing. The deadline and
experiment-attempt flag survive a reboot; rebooting does not restart the
ten-minute clock. No KAC uses the same resident clock wait. The craft keeps
its surface attitude rather than running an orbital solar rotation.
After the stop, a **30-second site menu** lists coordinates and distances.
Type a site number and ENTER to skip/revisit a site, H to hold at the prompt,
or R to start the configured return. ENTER or timeout keeps the next site
(after D, the configured return). The menu has its own KAC deadline and
cancels if surface/control safety changes.
Experiments already deployed, inoperable or unavailable can be skipped;
this is an experiment attempt, not a guarantee of four new science results.
Data is retained for return, with no automatic reset or transmission.

A–B is only about270 m, so this profile uses50 m hop prediction tolerance,
20 m terrain-refinement radius and100 m site admission. It holds if a
landing misses that site radius. Normal terrain/slope, actual attitude,
permitted landing-stage fuel and700 m/s return-reserve checks remain active.
After D's ten-minute stop, the original surface-ascent/SHAPE leg resumes
automatically. Once the specified high equatorial orbit is reached, it
holds in `SCIENCE_OPS` for contract review before departing. This review
does not deploy/reset/transmit experiments. The printed continuation is
`RUNPATH("0:/cmd/setphase.ks","RETURN_SETUP").` followed by `REBOOT.`.
The return targets Kerbin rather than KSC, enables fuel-assisted aerobraking
and preserves10 m/s for a possible periapsis repair.
Abort interrupts automatic departure; unsafe controls, motion, nodes, body,
terrain or fuel also hold for review. Clear the cause and reboot the saved
phase when ready. Keep the vessel active during its surface stops and hops.

This is an opt-in profile route: existing `cmd/hoproute.ks` routes still
stop at the prompt after each landing. Generic profile controls live in
`hop_route.ks`: `HOP_ROUTE_SITES` includes the initial landing followed by
hop sites, `HOP_SITE_DWELL_SECONDS` sets the stop, `HOP_SITE_RADIUS` sets
surface admission and `HOP_SITE_RUN_SCIENCE` enables experiment attempts.
`HOP_MENU_SECONDS` enables the bounded menu; its default 0 retains automatic
next-site selection without a menu for other profiles.
Hop launch, powered landing and surface science/menu run in separate bands,
with a reboot between them. `hop_control.ks` owns the ballistic burn; the
surface review band loads only the shared route helpers and science.
Boot caches the next band's files without executing them: review prepares
launch/return, launch prepares landing, and landing prepares surface review.
Cache copies leave4 KiB for state growth and logs and retain an existing
file if its replacement cannot fit. Caching is best effort; a missing file
can still require a link on the next boot. Ordinary missions do not load
the timed route.
Future science caching waits until verified touchdown; it does not add
archive work while the hop is falling.
The operator confirms the hop mission completed with improved approaches.
The new post-ascent review/selection command still needs native validation.

For a craft already on the surface, select a specified orbital leg directly:

```kerboscript
RUNPATH("0:/cmd/surfaceorbit.ks",659734,554472,0,0.4).
REBOOT.
```

Arguments are Ap, Pe (metres ASL), inclination, optional argument of periapsis,
and optional LAN (degrees; omitted angular targets use-1). This wrapped
command uses the live Mun/Minmus body and position, not a programmed hop site.
It requires settled touchdown, idle throttle/thrust, valid stage roles, no
node and Abort clear. It finishes any saved hop route, preserves the craft's
return hardware/entry policy and orbital-shaping budgets, and selects
`SURFACE_RETURN_SETUP` without igniting or rebooting. Reboot when ready.
The normal ascent reaches a safe parking orbit; SHAPE then establishes the
requested orbit. An eastward departure from nonzero latitude initially has
some inclination; SHAPE removes it rather than pretending the launch can be
equatorial immediately. A manual `SCIENCE_OPS` review holds the achieved orbit
before `RETURN_SETUP`; it prints the continuation command and preserves data.
Shared maneuver waits retain their KAC alarms and clock fallback. The return
provider stays cached through the orbital review. Other missions retain their
existing sequence unless they opt into `SURFACE_RETURN_REVIEW`.
For a shaped surface return, the generated parking altitude leaves1km
above the configured SHAPE periapsis floor (11km with a10km floor). Ordinary
economy returns without a shaped orbit retain their10km parking target.
If an older ascent already parked slightly below that floor, SHAPE first
tries raising the requested apoapsis from the current, higher apsis; that
burn point becomes the new periapsis. A small standalone periapsis repair
remains available when needed. The repair node itself must clear the
unchanged floor, have room for executor residuals, and pass the ordinary
fuel/minimum-dV/attitude gates. Without that headroom it holds. It never
temporarily waives the floor to raise apoapsis or change the plane.

To skip Beta after completing its temperature scan from Alpha, update the
archive, then run `RUNPATH("0:/cmd/hopnext.ks",3).` and `REBOOT.` when ready.
The command selects Gamma (-1.554,2.780) without igniting or marking it landed.
It uses the saved route, so editing profile coordinates alone does not change
an active route. If the surface checkpoint was lost, this profile can rebuild
it only at its first site, with the normal body, staging, terrain and fuel
checks. A landed route with a missing or stale departure phase recovers to
route setup/review instead of replaying the original departure. A failed
state-file replacement retains the previous file and shuts down with throttle
off. If this processor is already full, run `cmd/hopnext.ks` while linked
and safely landed **before rebooting**: it frees four replaceable descent
controller files before loading the recovery code. Mission state and route
overrides are retained. The startup recovery fix also requires updating the
installed bootstrap. While linked and landed, run these in order after pulling:

```kerboscript
RUNPATH("0:/cmd/hopnext.ks",3).
RUNPATH("0:/cmd/updateboot.ks").
REBOOT.
```

The bootstrap keeps an old library if its replacement cannot fit, uses current
archive code while linked to recover space, and stops explicitly if a required
bootstrap library or its exports are unavailable. It does not reset mission
state or fabricate an empty library registry.

RO9's `minmus_kolniya_flats_return` is a separate mission with these targets
(apsides in metres above Minmus sea level):

| Leg | Ap | Pe | Inclination | LAN | Argument of Pe |
| --- | ---: | ---: | ---: | ---: | ---: |
| First Minmus orbit | 397,272 | 9,300 | 63.4° | 79.2° | 90° |
| After Flats landing and ascent | 659,734 | 554,472 | 0° | Unspecified | 0.4° |
| Kerbin return | — | 52,000 | Unspecified | Unspecified | Unspecified |

Capture aims at 9.3 km Pe and 63.4° inclination. This profile accepts an
arrival within 1 km of that Pe and 1° of that inclination; SHAPE still
requires the final plane within 0.1° and finishes the requested LAN,
apsides and argument. This avoids chasing sub-0.3 m/s arrival corrections
for precision that belongs to SHAPE. The first orbit uses 100 m apsis
tolerances, a 0.002 m/s SHAPE burn minimum and a 0.001 m/s executor
residual: the contract can require a real 0.02 m/s correction at periapsis.
The first orbit uses an explicit 9 km SHAPE safety floor (above this profile's
8.3 km capture minimum), allowing the requested 9.3 km Pe; the high orbit
uses the default 10 km floor and its existing 500 m apsis tolerance. The fine
burn minimum and residual survive the generated surface-ascent profile.
Capture bounds and fuel reserves remain enforced.
SCIENCE_OPS holds for your review; it
does not automatically deorbit. Select a navigation waypoint inside a
Minmus Flats biome, preferably near the equator to reduce ascent plane cost,
then run the commands also printed by the hold:

```kerboscript
RUNPATH("0:/cmd/setphase.ks", "LAND_PREP").
REBOOT.
```

The generic `LAND_PREP` phase first changes the special orbit into a low
landing parking orbit. This profile keeps the 9.3 km periapsis and 63.4°
plane and lowers apoapsis to about 19.3 km; an ideal two-body calculation
requires about 45.5 m/s. That breaks the nearly repeating Kolniya ground
track. The deorbit survey can consider 48 low-orbit passes, while retaining
the 4096 geometry-sample and 64 native-prediction limits. A long selected wait
uses the existing KAC/solar maneuver approach. These are planning bounds,
not a guarantee of reaching every site or meeting the final landing error.

The advance command needs an archive link. Missing waypoint selection holds
in orbit; the profile never substitutes an automatic economy landing site.
SCANsat is optional, while terrain, braking and staging checks stay active.
Surface return first establishes a 10 km orbit, then SHAPE builds the high
equatorial ellipse before automatically starting Kerbin return. At zero
inclination LAN is undefined, so the second orbit requests no LAN.
This new route needs native flight testing and has additional shaping costs
compared with the economy mission. Budget/reserve limits hold if unaffordable.

`SURFACE_RETURN_ORBIT` optionally supplies the generated ascent profile's
`SHAPE_*` targets, tolerances and dV limits. Its `SURFACE_RETURN_SEQUENCE`
must include SHAPE; existing missions default to an empty orbit specification.
The return provider remains cached through prelaunch, ascent and shaping.

### Minmus Tundra, temperature surveys and landing

Select RO9 profile `minmus_tundra_survey_return` for this sequence:

1. Capture and finish Ap **397,272 m**, Pe **9,300 m**, inclination
   **116.6°**, LAN **337°**, argument of Pe **270°**. The existing strict
   orbital tolerances and fuel safeguards apply. The first science hold
   preserves empty thermometers. Verify the orbital contract, then use its
   printed `setphase.ks`, `LAND_PREP` and `REBOOT` commands.
2. `LAND_PREP` lowers Ap to approximately 19.3 km while keeping the 9.3 km
   Pe and retrograde plane. `ORBITAL_SURVEY` predicts overhead passes and
   takes temperature readings near the following sites, in the order its
   pass forecasts allow. Surveys precede landing to avoid another ascent
   into a plane reaching the northern sites.

   | Site | Latitude | Longitude | Minimum altitude ASL |
   | --- | ---: | ---: | ---: |
   | 1 | 52.648° | 2.235° | 6,600 m |
   | 2 | 34.308° | -12.419° | 6,600 m |
   | 3 | 52.176° | 18.898° | 6,600 m |
   | 4 | 35.436° | -18.744° | 6,600 m |
   | 5 | 52.128° | 82.575° | 6,600 m |

   The supplied 3,200–6,600 m values are **minimum thresholds**; flying
   above 6,600 m covers all of them without lowering the safety floor.
3. `SCIENCE_OPS_LOW` holds for you to verify the five contract ticks and
   stored data. A recorded deployment is not proof of contract completion.
   To release the fixed landing, run the printed commands:

   ```kerboscript
   RUNPATH("0:/cmd/setphase.ks", "LAND_DEORBIT").
   REBOOT.
   ```

4. Land at **-29.189°, 17.465°**, retaining terrain/footprint and stage
   checks. The locked site takes precedence over navigation waypoints;
   neither darkness nor lack of direct Kerbin view substitutes a new site.
   Surface return launches eastward into a low orbit near 29.189°
   inclination, then departs for a **53 km Kerbin entry** with the readings.

The prelaunch thermometer/storage check was removed at operator request.
The survey only collects into containers retained with the CPU; it never
dumps or transmits data, and resets a rerunnable thermometer only after its
data has been removed. If storage rejects a reading, it uses another empty
thermometer or holds for review with the reading intact. Selecting
`SCIENCE_OPS_RUN_ALL=0` reserves these sensors at the two review holds;
other profiles keep the existing run-all behavior.

No contract radius was supplied. `ORBITAL_SURVEY_RADIUS=1000` m is an explicit,
configurable overhead proximity criterion, **not an inferred contract
radius**. Forecasts scan at most 48 orbits and refine each remaining site's
closest sampled pass. They preserve the orbit and do not claim an optimal
tour or make plane changes. Missing passes retry in a running KAC/solar
coast; KAC is created before solar aiming, and an unavailable KAC leaves a
live clock wait at 1x. Live position/altitude checks gate every observation.
Copied persistent progress survives reboot. Abort, a new node, a changed
body, unsafe orbit or unavailable measurement holds the phase for review.

This profile and survey controller have source/conic regression checks;
native compilation, storage behavior, waypoint/contract acceptance and the
complete flight still need testing. Update from the archive with a link.

### Preparing a landing orbit

While coasting at zero throttle, compare the current orbit with the same
preparation goals used by `LAND_PREP`:

```kerboscript
RUNPATH("0:/cmd/landingroute.ks").
```

The command prints and verifies a report directly in
`0:/logs/archive/_diagnostics/`. It creates no maneuver or mission override.
LAND_PREP also records the comparison before planning its first correction.
The small shared `landing_route` library owns the preparation defaults and
target calculation, so the report and flight phase use the same goals.

The report compares two ordinary apsis-transfer orders, ideal deorbit and
ground-relative stopping costs, orbit periods and target-latitude crossing
heights. The resolved landing target supplies terrain elevation; without a
resolved target, it reports an equatorial zero-ASL reference. The Kolniya
9.3 × 397.272 km example needs about45.46m/s to reach9.3 × 19.3km. At an
equatorial zero-ASL reference, ideal total costs are about226.03m/s direct
versus230.14m/s including preparation; equatorial crossings fall from60.36km
to13.96km and period changes20200s to3028s.

These are reference costs, not a proved optimum or powered landing forecast.
The optional gravity allowance is a sensitivity calculation using the weaker
measured landing acceleration and constant surface gravity; it is unavailable
when that acceleration cannot exceed gravity. Preparation reserve margin
uses the existing **post-preparation** reserve. The separate after-landing
remainders are total stock vacuum dV references, not stage-qualified landing
fuel or a new return reserve. Plane changes and atmospheric landings are
outside this model; target longitude, terrain clearance and the staged
powered footprint still require the native deorbit checks. Existing
preparation policy, mission/survey sequence, burn budgets and safeguards stay
in charge of execution.

Insert `LAND_PREP` between an orbital objective/review and `LAND_DEORBIT` in
any mission sequence. It uses the shared orbit-shaping planners and maneuver
executor in its own library band. It can run before a landing waypoint is
chosen. Contract `SHAPE_*` goals and their strict tolerances remain available
for the original orbital objective; preparation has its own targets, budget
ledger and tolerances.

Defaults choose periapsis near the body safety floor and apoapsis 10 km
higher. An already-safe low periapsis is preserved. Inclination and LAN are
retained, so an inclined survey orbit keeps its latitude coverage. An
equatorial orbit still reaches mainly equatorial sites; request
`LAND_PREP_INC=90` when broad polar coverage warrants the plane-change cost.
Plane corrections use the actual plane intersections, choosing the slower
one, through the existing calibrated planner. Target-specific descent still
requires the ordinary reachability, terrain, light, powered-lead and fuel
checks in `LAND_DEORBIT`.

| Setting | Default | Purpose |
|---|---:|---|
| `LAND_PREP_AP`, `LAND_PREP_PE` | -1 | Automatic low apsides; nonnegative values request explicit altitudes in metres |
| `LAND_PREP_INC`, `LAND_PREP_LAN` | -1 | Preserve the current plane; set explicitly for different coverage |
| `LAND_PREP_MIN_PE` | 10,000 m | Body-specific safety floor; atmosphere+10 km remains a hard minimum |
| `LAND_PREP_ALT_TOL`, `LAND_PREP_ANG_TOL` | 1,000 m / 0.5° | Parking-orbit tolerances |
| `LAND_PREP_MIN_BURN_DV` | 0.1 m/s | Smallest preparation correction |
| `LAND_PREP_DV_CAP`, `LAND_PREP_TOTAL_DV_CAP` | 150 / 300 m/s | Per-burn and cumulative preparation allowances |
| `LAND_PREP_RESERVE_DV` | 900 m/s | Minimum vacuum dV retained after preparation burns |

The floor needs to suit the body's terrain. The reserve is a planning
allowance, not proof that landing, ascent and return are affordable.
Preparation reserves current-stage fuel and protects the tagged return stage.
It verifies physical cutoff, remeasures the achieved orbit, and advances only
when the parking goal is met. An unflown owned node survives a reboot without
a second budget charge. Interrupted burns hold; after inspecting the orbit,
`RUNPATH("0:/cmd/shaperetry.ks").` permits replanning while retaining the ledger.

When the next band's libraries are cached, preparation can continue offline.
Otherwise it stays running in the safe orbit, installing a KAC link-check
alarm before solar hold and polling by clock when KAC is unavailable. It
does not end the mission just because the radio link is down. New code needs
a connected boot; the installed bootstrap does not need replacement.
`STATS land-prep setup/budget/execution/result/wait` records decisions through
the normal archive pipeline. Source regressions and independent ground-track
geometry support this implementation; native preparation and touchdown remain
flight checks.

`RO8/mun_landing_return` and `RO8/minmus_landing_return` continue from
`LAND_ASSIST` into `SURFACE_RETURN_SETUP`. Touchdown starts a new local
`PRELAUNCH → LAUNCH → PARK → RETURN_SETUP` leg, using a 10 km polar parking
orbit. PRELAUNCH's usual 30-second auto-arm applies: press **H** there to
hold for surface science before leaving.

The generated Kerbin leg is
`ESCAPE → COAST → MCC → RETURN_TRIM → AEROBRAKE → DESCENT → DONE`.
It targets a **53 km initial periapsis** for the unshielded craft, with a
52–54 km corridor for MCC and optional KSC corrections. `RETURN_PE_TOLERANCE`
opts into this corridor; return setup preserves it across both generated
profiles, together with the chute and decoupler settings. KSC trim has a
20 m/s per-burn cap. The return MCC does not request an equatorial plane change.
The escape planner finishes its fuel-weighted search with bounded native
periapsis refinement. That prevents a cheaper but inaccurate node from
winning the search and then failing the separate 1 km departure gate.
That first refinement keeps improving trials only and limits prograde
changes to 10 m/s total. If it cannot reach the corridor, a bounded fallback
searches burn time, prograde and signed normal thrust together, using native
parent-body patches and the available vessel dV. This handles departure
planes that cannot reach Kerbin entry through prograde adjustment alone.
`STATS return-escape joint` reports trials, Pe error and burn components.
The final entry/fuel checks remain mandatory. Automatic rejection removes
the planner's unflown node and holds ESCAPE. Existing operator nodes are
preserved; explicit return previews retain their inspection policy.
MCC subsequently checks the flown orbit and acquires the entry corridor.

Aerobraking can take multiple passes. Propulsion stays attached through
AEROBRAKE; DESCENT starts only after capture and slowing below 600 m/s.
Drag may naturally lower periapsis during later passes: the corridor limits
planned entry corrections, not atmospheric evolution. KSC recovery is best
effort because intermediate passes change arrival timing; 53 km is an initial
flight-test target, not a guarantee against overheating. These profiles do
not schedule heat-shield jettison.

For a craft already in flight, sync the updated profile and libraries on a
connected reboot before relying on this return sequence. An offline reboot
uses the existing local copies. The generated-profile regression check is
`python3 scripts/check_surface_return.py`; kOS execution and thermal behavior
still require in-game validation.

The additional **RO9 science satellite** profiles are prepared for new craft;
creating these files does not select a mission or launch anything:

| Profile ID | Destination orbit |
|---|---|
| `kerbin_geostationary_satellite` | Kerbin, Ap/Pe2,863,334m, inclination0deg; no longitude slot specified |
| `kerbin_sunsync_satellite` | Kerbin, circular700km, retrograde99deg; inside the requested500-900km/96-102deg window |
| `kerbin_semisynchronous_satellite` | Kerbin, circular1,581,668m,55deg; about2h59m34s, eccentricity near zero |
| `minmus_elliptical_satellite` | Minmus, Ap1,041,045m / Pe465,764m, inclination21.6deg, LAN255.5deg, AoP157.3deg |

They launch into the useful plane, shape the destination orbit, run/transmit
available science, then hold for operator review in `SCIENCE_OPS`. The
three Kerbin missions use no interbody transfer and park at85km, leaving
room above SHAPE's80km atmospheric safety floor. The retrograde profile
targets the supplied orbit window; it does not implement Sun-tracking
station keeping. The medium-orbit altitude assumes stock Kerbin's radius
and gravitational parameter; its accepted apsis errors remain well inside
the requested2h52m23s..3h06m45s period and eccentricity<0.02 windows.
Science hardware, antenna reach and total fuel still depend on the new craft.

`RO9/mun_target_science_return` instead lands at **-10.590,99.490**, collects
surface science, then launches west to complete a retrograde equatorial
Mun orbit: **Ap1,737,680m, Pe1,543,150m, inclination180deg, AoP34.3deg**.
LAN is unconstrained. Ascent first parks at11km, then SHAPE raises the
orbit and finishes its plane/apsidal alignment. At the landing latitude,
westward ascent reaches about169.41deg; the remaining10.59deg correction
is planned in orbit after raising Ap. The shaping allowance is300m/s per
burn/500m/s total with300m/s reserved,100m apsis and0.1/0.2deg plane/AoP
tolerances. These limits do not guarantee fuel sufficiency for a given craft.
After shaping, `SCIENCE_OPS` holds at the prompt without running experiments
or automatically transmitting saved science. Check the contract, then run
`RUNPATH("0:/cmd/setphase.ks","RETURN_SETUP").` and `REBOOT.` to return to
Kerbin with the existing53km entry Pe and RO9 aerobrake assistance.
The initial arrival still captures directly into a15km/15deg Mun
orbit, sufficient for the target latitude, without the older polar-survey
detour. It keeps the target fixed, limits local terrain refinement to20m,
and retains slope/attitude/staging/fuel safeguards. This specified site can
be dark or beyond direct Kerbin view: the profile explicitly uses autonomous
landing (`LANDING_RADIO_MODE="OFFLINE"`), not a claim of relay coverage.
There are no hops, additional orbital surveys, or paid KSC-targeting detours.
The profile is prepared only; review the eventual craft's lander/return
staging and fuel before selecting it.

The separate **RO8 economy landing/return** profiles allow flexible landing
sites instead of the polar contracts:

| Profile ID | Name in the mission picker | Post-capture reserve floor |
|---|---|---|
| `mun_economy_return` | RO8 Mun Economy Landing and Return | 1,500 m/s |
| `minmus_economy_return` | RO8 Minmus Economy Landing and Return | 550 m/s |

Select one for a **fresh launch**. They wait for the target moon's orbital
plane at Kerbin launch, accept the natural arrival inclination/direction,
and correct only arrival periapsis. They do **not** force a polar or exactly
equatorial moon orbit. Capture aims directly at a near-circular 15 km orbit;
there is no separate SHAPE circularization/plane-change phase. Removing the
second capture burn reduces operations, not the ideal impulse needed for
the same final orbit. The principal savings come from dropping plane and
fixed-site requirements.

Orbital science runs once, followed by automatic ground-track site selection
and nearby terrain refinement. RO8 and RO9 Mun/Minmus economy profiles require
**Kerbin at least 15 degrees above the geometric horizon**, preferring 30 degrees
or more to leave room for burn/landing dispersions. Any sunlit hour is eligible,
with the **Sun at least 5 degrees up**. Morning's 15-degree Sun remains a soft
preference; a later-day site wins when it has substantially better Kerbin view.
At similar radio margins, the score favors rising light that will improve over
setting light. This is geometric screening, not a guarantee of a live link.
The picker searches four orbits along the existing ground track. If no site
meets both requirements, automatic selection stays in a running solar hold
in the parking orbit. A coarse forecast samples up to two moon orbital
periods (or at least eight vessel orbits/one surface rotation) to estimate
a later opportunity. It sets a named `Landing light retry` KAC alarm before
solar setup, prints the retry ETA/UT, then automatically runs a fresh nearby
site search when due. The forecast never approves a landing site or burn.
If it finds no future window, spaced rechecks continue; the displayed time
is a retry estimate, not a guaranteed landing time. Without KAC, the running
clock loop still resumes. Existing solar, battery and configured auto-warp
checks remain active. Wake intent survives reboot and is invalidated by a
changed mission, body, orbit plane/period or light policy. Successful
`landlight apply` clears it; previews remain immediate and do not start a wait.
Only an uncommitted, bound airless parking orbit can enter this wait;
retained nodes, begun burns and invalid geometry/config still need review.
The light/radio limits remain in force throughout planning.
If LAND_DEORBIT exits before any search, check `PRINT ABORT.` at the prompt.
The Abort action group can remain on across a CPU reboot. Clear it deliberately
with `SET ABORT TO FALSE.` and `REBOOT.` when ready to resume. Abort-on-entry
now prints an explicit pause instead of claiming no light/Kerbin site exists.
`STATS landing-light selector revision=2` identifies the new selector, and
`wait-rejected` records the exact orbit/node/impact gate if a wait is refused.

Each fresh economy plan in a bound parking
orbit refreshes any old locked site from the current ground track before
terrain refinement. The selected pass time travels with the site: the burn
search first tries the approaching half-orbit for that pass. Searching an
earlier pass at the same coordinates can otherwise create a large lateral
miss as Minmus rotates. Retained/interrupted burns keep their resume checks;
`LANDING_AUTO_TARGET=0` preserves an intentionally fixed site. Contract waypoints are ignored
(`LANDING_USE_WAYPOINTS=0`); these profiles do not perform the polar temperature
survey or land at the old contract coordinates. The existing targeted-deorbit
path still needs Trajectories, with SCANsat refinement when available.
The deorbit solver adjusts burn timing and retrograde dV together, then uses
up to 10 m/s normal correction if needed. Economy targets prefer lateral
miss below 250 m and reject above 500 m. Trial-node evaluations stop at 64;
geometry must pass before light/radio checks run. `STATS deorbit step` logs
retained improvements, and `STATS deorbit search` reports the evaluation count.
It also reports windows/candidates tried and whether the trial budget stopped
the search; a hold does not claim that all four orbits were exhausted.
Unflown retained nodes are rechecked against the current limits; rejection
preserves the node. Legacy profiles retain the 10–20 km downfield ballistic
lead; RO9's fixed-site profile derives its lead from the powered-range model.
For an accepted node that looks wrong, stop automation and keep that node
attached, then run `RUNPATH("0:/cmd/deorbitcheck.ks").` before clearing or
replanning it. The command writes directly to
`0:/logs/archive/_diagnostics/deorbitcheck_<vessel>_<UT>.log` and verifies the
completion record before printing success. It requires an archive link;
losing that link marks the snapshot incomplete and requests a retry. There
is no local fallback or reboot-sweep dependency, so no boot-module update is
needed. Surviving reports from the old `0:/logs/` and `1:/run/` locations are
copied into the same archive directory with a `recovered_` prefix, preserving
originals and existing archive copies. It captures the saved target,
active policy, orbit/state vectors, current/next-stage acceleration, stage dV,
engine Isp/separation slots, node components, repeated Trajectories
samples, native position at impact time and an independent rotation transform.
It leaves the node, mission phase and flight controls alone. Return the log
for inspection; a diagnostic snapshot is not a new landing plan.
The light picker and final unflown-node checks screen a wider region for
flexible economy landings: `LANDING_LIGHT_SITE_RADIUS` defaults to 21 km.
Sunlight and direct Kerbin view must have enough elevation margin across
that radius, including finite-distance parallax, at each sampled arrival
time. Rankings also reserve that margin before comparing preferred light
and radio elevations. Set the radius to `0` to use the point policy.
This is conservative planning around a shifting powered footprint, not an
exact touchdown prediction or a guarantee against terrain shadows/eclipses
throughout the region. Final local terrain and light checks remain active.
Precision targets and interrupted/suborbital recovery retain their original
point policy. A retained unflown node can now hold with `sun-site-margin` or
`kerbin-site-margin`; keep it for inspection or reselect with
`RUNPATH("0:/cmd/landlight.ks", "apply", "SUNLIT", 1).` before replanning.
The pause after `Economy planning region radius=...` is the light/radio
ground-track search: about 512 samples across four orbits by default, with
body predictions, eclipse checks and time-window checks. It logs its start,
progress every 64 samples and completion, including elapsed game seconds,
eligible sites and window-check counts. It temporarily uses the existing
landing CPU budget (capped at 2000 instructions/update), then restores it;
ABORT cancels selection, and the existing boot preamble recovers an interrupted
CPU setting. This needs the updated library, with no boot-module replacement.
`python3 scripts/replay_deorbit.py <snapshot>` independently replays bound,
same-body prograde/retrograde-only nodes from these records. It reports the
rotating target's closest pass, height and speed; it excludes powered flight,
finite burns, staging and terrain clearance along the path. A small geometric
miss is not a powered landing or disposal guarantee.
Surface ascent flies east to a 10 km parking orbit, accepting the minimum
inclination reachable from the actual landing latitude.

For a low-fuel landed save, `cmd/directreturn` previews ascent and escape
together, without a parking-orbit or KSC constraint. It reads current-stage
vacuum dV and enabled engines' limited thrust/Isp, searches headings and
finite-burn pitch profiles, and propagates the resulting coast to the moon's
SOI and a Kerbin periapsis. The default target is 53 km, accepted within 1 km,
with 20 m/s left over. `RUNPATH("0:/cmd/directreturn.ks", "status").` prints
the measured input snapshot without searching. Custom planning arguments are
`"plan", targetPeMeters, reserveDv`. Planning can take several minutes on the
flight CPU.

This is a numerical feasibility preview, not an installed direct-ascent
autopilot. It leaves the saved mission, controls and existing nodes alone;
the normal surface-return sequence still circularizes. Candidates use one
constant-thrust propulsion stage and the stock moons' circular parent orbits.
They are rechecked with finer integration and fresh live geometry, but terrain
mesh, attitude response, engine transitions and native KSP escape patches
remain unvalidated. No candidate found means this bounded search failed,
not that all possible departures are impossible. In particular, the RO9
Mun landing's 830.5 m/s cannot be assumed sufficient simply by removing the
circularization phase. Keep that save landed until a complete route is verified.

For a **targeted landing** whose retained unflown deorbit node fails the current
powered-lead check after a code update, keep the configured site and replan:

```kerboscript
RUNPATH("0:/cmd/deorbitretry.ks").
REBOOT.
```

This command removes only the next unflown node and its vessel's `Deorbit burn`
alarm. It preserves the saved phase, mission/return sequence, target and all
overrides. Other nodes and unrelated alarms remain for review. It requires
stable Mun/Minmus orbit, no recorded deorbit/interrupted ignition, Abort clear
and physical/raw/pilot throttle off, rechecked after warp settles. It neither
ignites nor reboots. The new solver and pre-burn validation retain all powered
lead, terrain, fuel, cross-track and light/radio limits. A node accepted by an
older model is not automatically accepted by the updated one.

`landlight apply` selects a new site; use it only when changing the landing
location is intended, not merely to repair a node for a configured target.
For a vessel **already parked at the Mun/Minmus in LAND_DEORBIT**, stop at the
manual prompt before ignition. With an archive link and the updated code synced:

```kos
RUNPATH("0:/cmd/landlight.ks").                         // preview saved policy; preserve old node
RUNPATH("0:/cmd/landlight.ks", "apply", "SUNLIT", 1).  // select site; remove old unflown node
REBOOT.                                              // replan and fly the new deorbit
```

Apply preserves the mission/return sequence and unrelated overrides. It refuses
descent, positive throttle/thrust, and a recorded interrupted deorbit. Do not use
it after any deorbit ignition, including a partial burn on older code without
that marker. Preview/apply each search afresh, so read the selected coordinates
and elevations. Apply does not ignite or reboot. An existing node also passes
the light/radio screen before the executor can stage or ignite; a rejected saved
node is retained for review.

The command's final argument is `LANDING_REQUIRE_KERBIN`: use `0` once relay
coverage is available to waive direct Kerbin visibility. This does not forecast
the relay network. `LANDING_KERBIN_MIN_ELEV` configures the elevation margin.
Light modes are `MORNING`, `SUNLIT` (either rising or setting, above
`LANDING_SUN_MIN_ELEV`), `AFTERNOON`, or `ANY`. `AFTERNOON` requires a falling
Sun at 30–75 degrees elevation, preferring 52.5 degrees (roughly 2:30pm at
the equator on the normalized clock). Its independent settings are
`LANDING_AFTERNOON_MIN_ELEV`, `LANDING_AFTERNOON_MAX_ELEV` and
`LANDING_AFTERNOON_PREFERRED_ELEV`. Latitude/solar declination affect the
clock-to-elevation relationship. To choose an afternoon site for this flight:

```kos
RUNPATH("0:/cmd/landlight.ks", "status").
RUNPATH("0:/cmd/landlight.ks", "preview", "AFTERNOON", 1).
RUNPATH("0:/cmd/landlight.ks", "apply", "AFTERNOON", 1).
REBOOT.
```

The status action does not reselect or fly: it prints the saved policy and
target, Kerbin elevation from independent live body positions, and a T+1800s
forecast. It also works after deorbit, while an archive link is available.
Preview/apply print both live and future Kerbin elevation for the proposed
site. These should agree closely on the stock tidally locked Mun: an obscured
site does not rotate into Kerbin view later that afternoon. Select a different
site that satisfies the Sun and Kerbin constraints together. A disagreement
over 0.5 degrees on the circular, synchronized Mun holds with
`kerbin-frame-mismatch` rather than trusting the forecast.

Other missions default to `ANY` with no
Kerbin-view requirement. The deorbit solver rechecks the actual selected
node's predicted impact time, with samples across a ±300-second touchdown
window (`LANDING_LIGHT_TIME_MARGIN`). Existing terrain/slope/fuel checks remain.

Sun ephemerides are available even in eclipse; no panel search or human Sun
measurement is needed. The screen rejects ancestor-body eclipses, but geometric
elevation does not model ridge shadows, antenna range, the location of ground
stations, or continuous CommNet availability. A direct Kerbin view is the initial
proxy for radio coverage. An incompatible morning/Kerbin geometry can require
waiting for a different solar phase or providing relay coverage.

Panel orientation uses a separate, saved **ship-frame panel axis**. Automatic
coast/reorientation first aims that axis at the current Sun and measures flow.
At least `SOLAR_REUSE_RATIO` (default 90%) of its saved successful peak reuses it;
lower flow triggers a new search. Energy-flow references scale with Sun distance;
changed panel counts invalidate the reference. Eclipse/unreadable measurements
retain the last successful reference. Old saves without a measured peak learn
one on their next successful search. Explicit forced-search commands still work.
These geometry/cache changes pass source-driven fixtures; in-game validation
of site selection, finite burns and panel telemetry is still required.

The return retains the 53 km entry target and 52–54 km correction corridor,
but omits optional KSC targeting burns: recovery can occur anywhere on
Kerbin. The engine/tank remains attached through aerobraking and separates
below 6 km in DESCENT. Use `descent_decoupler` and `descent_chutes` tags.
PRELAUNCH still auto-arms after surface touchdown; press **H** there to hold
for surface science. Existing polar/contract profiles remain available.

Arrival corrections are limited to 20 m/s per burn (10 at midpoint), 30 m/s
total, and must leave capture fuel plus the reserve above. CAPTURE checks the
reserve again. These are planning allowances for descent, ascent and return,
not craft-specific guarantees: a marginal craft may hold before capture.
The profiles use the existing direct-transfer architecture, not gravity
assists or ballistic-capture searches. Profile persistence and waypoint
settings are checked by `python3 -B scripts/check_surface_return.py`; flight
validation is still required.

For an **orbital-science-only Mun return**, select RO8 `mun_orbit_return`.
It targets 15 km low orbit, accepting a **10–20 km arrival periapsis** in the
natural arrival plane, runs experiments,
then holds in SCIENCE_OPS to let you inspect/store data before leaving.
Automatic experiment transmission is disabled. There are no landing or
surface-ascent phases. Its correction/capture checks reserve **400 m/s after
capture** for departure and Kerbin approach work; the planners still check
whether the actual capture is affordable.

To salvage the economy mission currently held at BPLANE for the 1,500 m/s
landing/return reserve, run while connected after archive sync:

```kerboscript
RUNPATH("0:/cmd/setphase.ks", "BPLANE", "mun_orbit_return").
REBOOT.
```

This switches the active profile without relaunching or clearing the spent
arrival-correction budget. BPLANE must still raise a 6.5 km arrival into the
10–20 km capture corridor; no low-periapsis checks are waived. Use this switch
on the Kerbin-side Mun approach, before entering the Mun SOI. After capture,
check that the science data is retained in parts that will return with the
probe (particularly before the engine/tank separates), collect any additional
available readings, and start the return when ready:

```kerboscript
RUNPATH("0:/cmd/setphase.ks", "RETURN_SETUP").
REBOOT.
```

An existing 19.4 km encounter now needs no precision correction. After sync,
`RUNPATH("0:/cmd/arrival.ks", "replan").` loads the updated profile and checks
the flown encounter before planning another burn. CAPTURE circularizes at
the actual periapsis when it exceeds the nominal 15 km target, subject to
the same 400 m/s post-capture reserve. This wider tolerance applies only to
`mun_orbit_return`; the contract and landing profiles retain their limits.

RETURN_SETUP writes the same 53 km shallow-entry Kerbin return used by the
economy profiles, with no optional KSC targeting burns. The orbit-only
profile is covered by `python3 -B scripts/check_surface_return.py`; actual
capture/departure costs and science recovery still need flight validation.

For an **RO8 already in Minmus orbit**, `minmus_landing_recovery` skips SHAPE
and starts a flexible-site landing directly from the current orbit. For the
reported 14.6 x 100 km ellipse, circularization alone would cost about
26 m/s, exceeding the old profile's 10 m/s SHAPE burn cap. That warning is
not a craft-specific prediction that landing is impossible.

With roughly 640 m/s, landing plus return is marginal: an idealized stock
Minmus calculation gives about 210 m/s for descent, 185 m/s for ascent to
10 km and 160 m/s for departure. Powered-descent/ascent losses, actual
departure geometry and corrections consume the remaining allowance. Run
`RUNPATH("0:/cmd/landingcheck.ks").` first; use its **surface** TWR, not the
much larger TWR at 100 km, to assess the engine's landing authority.

After archive sync, while connected and still in Minmus orbit, remove any
leftover maneuver nodes before this switch (LAND_DEORBIT resumes existing
nodes). A SHAPE budget rejection normally already removes its node:

```kerboscript
RUNPATH("0:/cmd/minmusrecover.ks").
REBOOT.
```

The command loads its own libraries, caches the profile and clears old
overrides, preventing previous contract coordinates/sequence from winning
over the new profile. It refuses to switch with a maneuver node present.
The mission selects a nearby ground-track target,
then requires SCANsat to find terrain of at most 5 degrees slope within a
1.5 km north/east search extent before planning deorbit. This is a local
terrain search, not a guarantee of reaching the Flats biome or the globally
cheapest landing. Missing coverage/no suitable site holds in orbit; choose
another ground-track site or obtain coverage before retrying. Trajectories
is still required. LAND_DEORBIT now loads the site scanner and persists its
refined coordinates for LAND_ASSIST across the band reboot.

Without SCANsat coverage, place and **select** a waypoint on a broad flat
area close to the upcoming periapsis ground track, then run:

```kerboscript
RUNPATH("0:/cmd/minmusrecover.ks", "waypoint").
REBOOT.
```

Waypoint mode records the selected Minmus coordinates in the overrides,
disables automatic/map-based site selection, and retains the recovery
sequence, Trajectories approach validation and local terrain refinement.
Changing the selected waypoint later does not redirect the saved target.
The selected site is visually assessed, not certified flat by the command.
Keep it near the ground track to avoid spending fuel on lateral guidance.
The solver chooses a burn before the site; do not wait until periapsis to
start setup. It may need a later pass if the useful burn location has passed.

The deorbit geometry fix removes spherical curvature from cross-track error,
accounts for rotation and uses consistent same-SOI position frames. It tries
several burn locations and revalidates the selected node before execution.
If this mission held on the old calculation, sync and run
`RUNPATH("0:/cmd/setphase.ks", "LAND_DEORBIT").` then `REBOOT.` while connected;
this preserves the saved waypoint overrides. The new `STATS deorbit candidate`,
`solved` and `final` lines capture the geometry if planning still holds.

A direct surface-to-Kerbin ascent is physically possible but is not an
implemented return mode: `ascentAirlessToOrbit` circularizes, RETURN_SETUP
requires ORBITING, and ESCAPE scans a bound parking orbit. Omitting PARK
does not omit circularization. A direct path needs a surface launch window,
departure-direction targeting, finite-burn guidance and a reboot-safe
handoff to the Kerbin approach. For stock Minmus, ideal surface injection
is roughly 333 m/s versus about 346 m/s for ascent to 10 km plus departure;
the circularization speed is not all wasted, because it contributes toward
escape speed. These are optimistic two-body estimates excluding losses,
rotation and geometry. Keep the existing 10 km return for this probe rather
than expecting a large fuel saving from skipping a phase.

Airless ascent circularizes with a direct burn, so its countdown has no
maneuver node. It now creates an owned `Ascent circularize` KAC KillWarp
alarm at T-60, retains the running clock wait without KAC, and settles warp
before ignition. `STATS ascent circularize plan/wait` reports the direct
burn's ignition UT, dV, acceleration and alarm ID. A connected LAUNCH boot
also retains `return_setup` when the sequence needs it after PARK, allowing
the later return-setup reboot to work offline. An incomplete cache reports
the missing library and holds instead of taking an undefined handler.

The ascent pitch program still depends on speed and vertical-speed guards;
it is not yet an optimized plan for changing stage TWR. Live console samples
include acceleration, TWR, stage, mass and remaining vacuum dV. One usable
sample per observed stage is buffered as `STATS ascent stage` and saved after
verified climb cutoff, so ordinary diagnostics add no powered-climb file I/O.

After touchdown, SCIENCE_OPS attempts available experiments without automatic
transmission and **holds on the surface**. Check stored data and fuel; about
400 m/s remaining is a useful return planning allowance, not a guarantee.
Keep the science in parts that survive the eventual engine/tank separation.
When ready to launch:

```kerboscript
RUNPATH("0:/cmd/setphase.ks", "SURFACE_RETURN_SETUP").
REBOOT.
```

This starts the normal launch countdown, eastward ascent to 10 km, and a
53 km Kerbin entry (52–54 km correction corridor). KSC targeting is enabled,
but the optional RETURN_TRIM burn is capped at 5 m/s; MCC and aerobrake
targeting have separate limits. Precise KSC recovery and unshielded thermal
survival are not assured, especially after multiple atmospheric passes.
Use `descent_decoupler` and `descent_chutes` tags. The engine/tank stays
attached through aerobraking and separates below 6 km in DESCENT. Profile
and site-handoff checks run in `scripts/check_surface_return.py`; this
recovery sequence still needs flight validation.

### Minmus science campaign

Suggested order after Minmus unlock:

1. `Falcon/minmus_equatorial_science_return` — easy equatorial capture,
   first Minmus science, then `returntokerbin`.
2. `FR3C/minmus_relay_tripack` — three-relay constellation at 500 km.
3. `FR3C/minmus_scansat_polar` — polar map of altimetry, resources, biomes.
4. `FR3C/minmus_rover` — rover landing after comms and map coverage.
5. `FR3b/minmus_crew_orbit` — crewed orbital science, then `returntokerbin`.
6. `FR3C/minmus_science_orbiter` and `FDR1/minmus_hops` — follow-on science.

## Orbital maneuvering

### Universal routing (goto)

`RUNPATH("0:/cmd/goto.ks", LEX("dest","Mun","pe",30000,"ap",100000,"inc",90,
"lan",78,"aop",270)).` — or just a name string — routes to **any body or
vessel**: parent, child, sibling moon, another planet, or a rendezvous
target. The planner (`lib/goto_plan.ks`) emits one hop's `SEQUENCE` +
config per SOI transition; multi-hop routes end each leg with the `GOTO`
phase, which replans from wherever the ship is and reboots into the next
band. Config-driven missions use the same phases and keys directly.

Orbiting telescope presets:

```ks
RUNPATH("0:/cmd/gotoduna.ks").  // 85 x 250 km Duna orbit
RUNPATH("0:/cmd/gotojool.ks").  // 250 x 15000 km Jool orbit
```

Both are thin wrappers over `cmd/goto.ks`; pass a lexicon to override `pe`,
`ap`, `inc`, `lan`, `aop`, or `reboot`.

### The precision pipeline

- **XING** — departure planning; picks the transfer window (multi-orbit LAN
  scan when `CAPTURE_LAN` is set). Local moon transfers scan the next
  `TRANSFER_SCAN_LOOKAHEAD_HOURS` from the current time, default 6h, so
  a missed-burn rescue can reacquire promptly instead of searching whole
  high-transfer orbits. The full local scan horizon is evaluated, and safe
  broad direct encounters rank by departure dV during seed selection.
  The chosen local departure is then refined toward `CAPTURE_PE` using all
  three burn axes, with no forced arrival plane. The final predicted Pe must
  be positive and within `TRANSFER_PE_TOL` (default 2 km) of the request;
  otherwise planning fails without burning. The refinement aims within
  500 m and limits the vector change from the seed to
  `TRANSFER_PE_REFINE_DV_CAP` (default 100 m/s). Saved, unburned XING nodes
  pass the same Pe gate before execution. A cheap grazing encounter is no
  longer enough. If refinement fails, the planner tries the saved coarse
  shortlist (`TRANSFER_PREVIEW_SHORTLIST`, default six), skipping duplicate
  or imminent windows and stopping at the first usable one. Each alternate
  starts from its own original seed; adjustment budgets do not accumulate
  across candidates. `STATS departure-pe solve` reports the stopping reason,
  final Pe and vector adjustment. If all fail, the best failed candidate is
  restored for the rejection report. This is not a minimum-total-mission-dV guarantee.
  Interplanetary transfers use the Lambert planner:
  analytic shortlist, patch refinement, ejection-dV ranking, and escape-path
  safety checks. Local XING leaves precise arrival-plane targeting and
  corrections for execution error to downstream `BPLANE`/`SHAPE` phases.
- **BPLANE** (`lib/arrival_bplane.ks`) — mid-coast B-plane correction: a 2×2
  Newton iteration on (B·T, B·R) steers the arrival hyperbola onto the
  requested plane (`CAPTURE_INC`/`CAPTURE_LAN`) and periapsis (`CAPTURE_PE`).
  Smooth where raw patch elements are discontinuous. If the departure burn
  still leaves the ship inside the departure SOI, BPLANE first coasts out to
  the transfer body's frame before measuring the arrival.
- **COAST_1HALF / REFINE_BPLANE / COAST_2HALF** — long transfers split around
  a timed midpoint. The first coast anchors its midpoint and sets the KAC
  alarm before solar alignment. Solar alignment, maintenance and charging
  checks share that wake deadline. The checkpoint survives reboots and
  arrival review; an overdue checkpoint advances straight to refinement.
  Live encounter timing takes priority over an old departure estimate.
  `REFINE_BPLANE` performs capped small correction burns until the
  arrival corridor is met, and the second coast waits to the SOI buffer.
- **CAPTURE** — tangential burn at Pe (preserves plane, Pe, and apsis line);
  `TARGET_AP` puts the apoapsis where the final orbit wants it.
- **SHAPE** (`lib/orbit_shape.ks`) — closed-form trim to any specified
  `SHAPE_AP/PE/INC/LAN/AOP`: one combined plane burn at the relative node,
  apsidal rotation, apsis burns. No numeric search; re-measures between
  burns so execution errors self-correct.

The older element-targeting pipeline (`MCC`, `CIRC`, `RAISE`, `INCLINE`,
`ELLIPTICAL`) remains for legacy profiles and rescue flows.
`cmd/returntokerbin.ks` runs the full moon-return + aerobrake + descent flow.
Kerbin aerobrake returns use `MCC` to establish the configured reentry Pe
corridor while preserving the arrival plane. A trajectory already inside
that corridor needs no correction. Otherwise MCC corrects after entering
Kerbin's SOI and checks the **flown orbit** before advancing. It allows up to
three corrections, with each burn limited to `MCC_RETURN_DV_CAP` (150 m/s)
and the available vacuum dV minus `MCC_RETURN_RESERVE_DV` (50 m/s). Failed
planning, insufficient fuel or failed execution holds in MCC; tiny but
necessary corrections are no longer discarded by the optional-MCC cutoff.
`RETURN_TRIM` remains an optional landing-site adjustment, not reentry
acquisition. AEROBRAKE routes a Kerbin periapsis above the atmosphere back
to MCC before coasting or stowing hardware (or holds if no MCC is available).

For an RO6 already orbiting Minmus (or another parachute probe orbiting
Mun/Minmus), use `RUNPATH("0:/cmd/returnshallow.ks").` from the manual
console with an archive link. First tag the decoupler between the retained
probe and engine/tank `descent_decoupler`, and the parachute `descent_chutes`.
The controlling CPU, power and parachute must stay with the probe after
separation. This command loads its own libraries, writes a return profile,
and **automatically reboots into ESCAPE**.

The shallow return targets an initial Kerbin Pe of **53 km**, with corrections
kept inside **52–54 km** and no forced equatorial arrival plane. It attempts
KSC targeting with a **20 m/s pre-entry RETURN_TRIM cap**. The craft holds
retrograde and retains the engine/tank through atmospheric passes. After
AEROBRAKE hands off to DESCENT (apoapsis inside the atmosphere and airspeed
below 600 m/s), it separates the tagged stage below **6 km ASL** and completes
parachute descent. Fairing deployment is disabled for this exposed probe
recipe. Multiple passes can shift the eventual landing site: KSC is best
effort, and the 53 km target does not guarantee thermal survival. Profile
persistence is checked by `python3 scripts/check_surface_return.py`; this
recipe still needs flight validation.

For a missed moon capture with an existing Kerbin exit patch, or a probe
already in Kerbin orbit, run this while linked and automation is stopped:

```kerboscript
RUNPATH("0:/cmd/kerbinrecover.ks").
```

It reads the native patch chain each time: current/predicted Kerbin Pe, Ap,
inclination, LAN, argument of Pe, total vacuum dV and active-stage dV. Its
apoapsis-burn estimate is informational, excludes targeting/losses, and is
unavailable for invalid/unbound ellipses. The verified report is written
directly to `0:/logs/archive/_diagnostics/kerbinrecover_<vessel>_<UT>.log`.
Existing nodes must be inspected first; the probe never deletes them.

`RUNPATH("0:/cmd/kerbinrecover.ks","apply").` reads the live values again,
then uses the shared return-profile writer and reboots into
`MCC → RETURN_TRIM → AEROBRAKE → DESCENT → DONE`. This bypasses a new moon
departure burn. MCC waits for actual Kerbin SOI entry using the existing
SOI-alarm/solar/clock path, then remeasures and plans against the game's
native orbit. On a stable outbound ellipse without another SOI encounter,
this recipe enables `MCC_RETURN_AT_APOAPSIS`: its own KAC/solar/clock wait
wakes 5 minutes before the live apoapsis to plan a cheaper correction.
Inbound, near-apoapsis and unbound approaches use the immediate correction;
the command does not wait another orbit. Existing 150 m/s correction/50 m/s reserve limits still apply;
failure to reach the entry corridor holds rather than flying a rejected node.
The 53 km target retains the 52–54 km corridor and arrival plane. Optional
KSC trim is capped at 20 m/s; this does not guarantee a KSC landing.
The recipe uses the same `descent_chutes` / `descent_decoupler` tags and
6 km separation as `returnshallow`. Apply refuses Abort, pending nodes,
interrupted burns, or nonzero physical/raw/pilot thrust/throttle. Ordinary
moon RETURN_SETUP still requires stable moon orbit and starts at ESCAPE.
Other return profiles leave `MCC_RETURN_AT_APOAPSIS` off by default.

To recover an existing shallow return that advanced with a high Kerbin
periapsis, wait for archive sync, then run while connected:

```kerboscript
RUNPATH("0:/cmd/setphase.ks", "MCC").
REBOOT.
```

This preserves the existing 53 km profile, chute tags and late decoupling.
Do not rerun the moon-departure setup from Kerbin orbit. Diagnostics are
persisted as `STATS return-mcc setup`, `plan`, `flown`, `status=verified`
or `status=held`. Offline checks: `python3 -B scripts/check_return_mcc.py`.

After an aerobrake pass, an outbound bound craft outside the atmosphere can
restore its entry Pe with `RUNPATH("0:/cmd/reentrype.ks",53000).` Run it from
manual mode with an archive link and at least 30 seconds before apoapsis.
It changes Pe at that apoapsis, leaving Ap and the current orbital plane
alone. The reported 51.096 km Pe / 211.5 km Ap needs about 1.594 m/s prograde
in a two-body calculation. The command checks the game's actual node for the
52–54 km corridor, 250 m target tolerance, unchanged Ap/inclination, zero
radial/normal dV and adequate fuel. Its 20 m/s correction limit is separate
from the uncapped energy-reduction assist. Existing or interrupted maneuvers
are preserved. After execution it verifies physical cutoff and live Pe,
without reading suffixes on a removed node. Reboot after success to resume
the existing aerobrake mission. This command does not circularize the orbit.

Optional propulsion lowers apoapsis while aiming to preserve the entry
periapsis. **RO9 enables this automatically**; other craft default off.
The operator switch is boolean:

```kerboscript
RUNPATH("0:/cmd/aeroassist.ks",1). // enable; use 0 to disable
```

The command saves an override for the next AEROBRAKE boot and preserves the
phase, maneuver nodes and unrelated overrides. Both generated return profiles
preserve the policy. After archive sync, reboot to load the new controller;
no installed `boot/boot.ks` replacement is needed. A reboot already inside
the atmosphere keeps normal aerobraking and waits until the following pass
to plan assistance.

Older generated profiles may explicitly save `AEROBRAKE_AP_BURN=0`, overriding
the RO9 craft default; the command's saved override enables it deliberately.
For a return stack whose final separator has another tag, an optional second
argument selects it for DESCENT:

```kerboscript
RUNPATH("0:/cmd/aeroassist.ks",1,"return_decoupler").
```

This hardware option requires AEROBRAKE, Abort clear and zero thrust/raw/pilot
throttle. It verifies one attached, stageable separator and that both the CPU
and all `descent_chutes` parts remain aboard. It preserves the configured
separation altitude (6 km in the shallow-return profile). It does not fire
the separator, ignite engines or change phase. Pull updates and use a safe
coast outside the atmosphere for the connected reboot. On RO9's3/2/1 stack,
`return_decoupler` removes the lower lander/transfer stack at final DESCENT;
it does not spend those stages' fuel sequentially during aerobraking. There
is no automatic powered landing unless that is separately configured.

After every atmospheric exit, AEROBRAKE refreshes the vessel's `Atmo entry:
<body>` KAC KillWarp alarm from the new orbit, after any capture burn and
before the next solar coast. It uses the next actual inbound atmosphere
crossing rather than Pe minus a fixed120 seconds. Preparation uses that
same crossing minus `AEROBRAKE_ENTRY_LEAD` (default900 seconds). Startup and
post-correction checks use the same path; same-name alarms are reused or
retimed through the shared helper, while other craft's alarms are preserved.
Without KAC the clock wait still runs. No alarm is invented when there is
no future crossing. `STATS aerobrake entry-alarm` logs entry/preparation UT.

The emergency capture burn after a hyperbolic skip-out first aligns at zero
throttle, then follows live orbital retrograde. It shares the optional
assist's body/stage/node/Abort, attitude and publisher-freshness interlocks.
Its existing capture, fuel and Pe-floor stops remain. Physical cutoff is
verified before restoring CPU/log policy or clearing the recovery marker.
An interrupted capture holds for review; after an explicit reboot, an
outbound hyperbola with an atmospheric Pe can retry before solar coast.

About **180 seconds before the next actual atmospheric interface**, the
controller measures usable fuel, active-engine thrust/Isp and mass. It tries
three ignition times with a variable-mass, finite-thrust vacuum prediction,
then verifies the selected forecast at a finer step. Timing comes from the
conic's atmosphere crossing, rather than an assumed interval before Pe.
The objective is to reduce orbital energy toward an apoapsis just above the
atmosphere (atmosphere height + 1 km). There is **no fixed per-pass or total
dV allowance**: measured current-stage fuel is eligible, subject to the
retained repair reserve. The craft keeps at least **10 m/s** for a later
periapsis-raising burn at apoapsis; a larger configured reserve is honored.
An audited, fueled successor can hold that reserve while the disposable
active stage uses its fuel. Without that proof, the active stage keeps it.
Older generated profiles that saved zero still receive the 10 m/s minimum.
The successor is checked again before committing the burn, and the live
throttle guard always retains the craft-wide reserve. This sets fuel aside,
without creating or executing a periapsis-repair maneuver.
A long burn can start before entry. Its steering projects deceleration along
a direction that preserves Pe, with feedback toward the configured entry Pe.
Feedback leaves errors within 100 m alone, avoiding needless radial steering
near periapsis; the corridor checks still run continuously.
Each subsequent pass recalculates from the actual orbit and remaining fuel.
A manual separation during the pre-entry wait returns to fresh planning
and entry-alarm timing. It does not clear the once-per-pass burn latch.
A powered arc that ends before atmospheric entry also refreshes the alarm:
its new conic can reach the atmosphere minutes after the old prediction.
This powered direction can be noticeably off the navball's retrograde marker
outside the atmosphere; it is recalculated from the current orbit, rather
than pointing at a future retrograde marker. The entry hold uses current
surface retrograde (or configured prograde) through a
[live steering lock](https://ksp-kos.github.io/KOS/commands/flight/cooked.html#the-special-lock-variables-for-cooked-steering).
It does not save a single retrograde snapshot through a changing coast.
An already aligned entry hold stays quiet instead of printing the same
orientation pair every second.

For the economy Kerbin return, the existing 52–54 km entry corridor remains
in force, with a 100 m inner stopping margin. The forecast can select only a
partial burn if preserving that corridor or the entry attitude requires it.
The live controller checks both Pe bounds, energy reduction, pressure,
alignment, fuel, stage/body changes, abort and control freshness. It also
stops at the forecast impulse/duration, or the apoapsis goal. These stopping
limits come from the forecast and live conditions, rather than a preset fuel
allowance. It aligns with zero throttle before ignition and verifies actual
thrust and raw/pilot throttle are zero afterward. The powered controller never
stages or activates engines. An interrupted burn attempt cannot repeat until an atmospheric entry and
exit have both been observed. The temporary 2,000 IPU planning/control budget
is restored afterward or by `bootPreamble` following interruption.

RO9 also approves the `lander_decoupler` and `return_decoupler` boundaries
for **between-pass** engine handoffs. Other vehicles retain active-engine-only
behavior unless their profile supplies `AEROBRAKE_AP_STAGE_TAGS`. At the next
entry preparation wake, off rails and at least 1 km above the atmosphere,
the craft may discard an upper stage only when both its own enabled tank
mixture and KSP's current-stage estimate put it within 1 m/s of empty.
The next engine must have fuel above the retained repair reserve. The separator
must be adjacent in the staging list and retain this CPU and every tagged
`descent_chutes` parachute. The full slot is audited: unknown modules, extra
engines/separators/chutes and retained fairings block automation. Inert RO9
tanks and legs are recognized; its tagged `main_fairing` is allowed only on
the discarded side of the approved separator.

Each handoff verifies physical cutoff before staging, records one attempt
per separator UID, and verifies the old engine departed and the new one
ignited at zero throttle. An interrupted or failed recorded event cannot
repeat automatically; inspect hardware/staging manually if it holds.
`STATS aerobrake-stage check/fuel/result` records the decision, both depletion
estimates, next-stage fuel, discarded fuel and
post-event status. A successful handoff refreshes the entry alarm, then the
normal assist planner forecasts from the new engine, fuel and wet mass.
It does **not** switch engines inside the atmosphere or spend all three stages
in one entry. Final DESCENT separation still follows its separate policy.
These staging checks have source regressions and a saved RO9 hardware audit;
native staging, compiled cache size and atmospheric performance need flight
validation after a connected reboot.

Advanced profile settings are optional; the enable flag is sufficient:

| Setting | Default | Effect |
|---|---:|---|
| `AEROBRAKE_AP_BURN` | 0; RO9 sets 1 | Enable fuel-assisted aerobraking |
| `AEROBRAKE_AP_RESERVE_DV` | 10 m/s | Craft-wide Pe-repair reserve; an audited fueled successor may hold it while a disposable stage empties |
| `AEROBRAKE_AP_PLAN_LEAD` | 180 s | Forecast lead before atmospheric entry |
| `AEROBRAKE_AP_MAX_Q` | 0.1 atm | Dynamic-pressure cutoff (about 10.1 kPa) |
| `AEROBRAKE_AP_MAX_OFF_RETRO` | 10° | Maximum atmospheric departure from surface retrograde |
| `AEROBRAKE_AP_STAGE_TAGS` | Empty; RO9 approves its two named separators | Boundaries eligible for audited between-pass engine handoffs |

Dynamic pressure uses [kOS's atmosphere units](https://ksp-kos.github.io/KOS/structures/vessels/vessel.html#attribute:VESSEL:Q).
The forecast does not model drag, heating or attitude dynamics. Actual drag
can shorten a burn through the live corridor and attitude guards; unused fuel
is reconsidered next pass. This does not establish a globally optimal or
thermally validated entry. `STATS aerobrake-assist policy/plan/forecast/align/result`
records available fuel, calculation time, ignition, predicted Pe/Ap, measured
impulse, final orbit and cutoff reason through the existing boot-log/archive
pipeline. The `align` rows distinguish pointing error from the deliberate
orbital/surface retrograde offsets. `peakFacingErr` in the result records the
largest error seen by the throttle guard; peak retrograde offsets are sampled
once a second in RAM. Only pre-burn and post-cutoff rows are written, with no
archive/state writes during positive commanded thrust. An alignment timeout
cannot enter the powered loop.
Source-driven checks: `python3 -B scripts/check_aerobrake_assist.py` and
`python3 -B scripts/check_aerobrake_staging.py`; `make check` runs the routine
suite. Host-side timings vary with system load and are not a kOS flight
timing guarantee; the flight plan records its own computation time.

Aerobrake solar coasts explicitly establish the solar attitude before
auto-warping. AEROBRAKE declares solar as a phase dependency, so profile-first
boot planning loads/caches it even when the craft's `LIBS_EXTRA` runs later.
The unavailable warning distinguishes `solar-library-not-loaded` from
`no-supported-solar-panels`, with helper/panel flags. A positive panel-flow
reading alone does not prove a solar
steering hold was installed. The coast stops warp, waits for physics to
settle, tries the saved axis first and validates it against its saved peak.
Full rediscovery is used only when needed. Alignment/search and later
maintenance re-aims share the coast's wake deadline, so they yield to entry
preparation. An incomplete attempt preserves the proven cache and does not
enable auto-warp. The log records `STATS aerobrake solar aimed=... flow=...
canWarp=...`; missing solar support, alignment timeout and expired deadlines
are reported explicitly. Eclipse handling and healthy-battery maintenance
deferrals remain active. These paths have source-driven checks, with KSP
attitude and warp-release validation still required.

Solar turns allow up to `SOLAR_AIM_TIMEOUT` (90 seconds, previously 30),
within one `SOLAR_SEARCH_TIMEOUT` budget (300 seconds). An earlier coast wake
deadline still wins. These are maximum waits: each turn finishes as soon as
the axis is within `SOLAR_AIM_TOLERANCE` (5 degrees for search measurements)
or `SOLAR_HOLD_TOLERANCE` (10 degrees for the cached solar attitude), with
rotation below 0.03. After the 1.5-second panel/readout settle, coarse turns
may remain within the existing 10-degree hold tolerance; crossing back over
5 degrees by a fraction no longer discards the whole search. Fine probes
retain their requested 1-degree precision during readout. Excessive drift
or renewed spin retries the same anchored target within the original turn
and coast deadlines. Logs include both tolerances and `readout-reacquire`.
Cache validation still requires 90% of a valid saved peak when flow is
measurable in daylight; existing eclipse/unreadable handling remains.
During maintenance, near-zero flow defers aiming only when body geometry
confirms an eclipse. A panel facing away in daylight triggers recovery.
The wider angular tolerance lets small drift settle sooner without changing
the flow threshold. The steering lock continues following the Sun. These
solar tolerances leave maneuver, landing and reentry pointing checks intact.
Solar validates the cached axis first. If discovery is needed, it measures the
six panel-part axes, then fine-tunes the winner. Four nearby tilts measure the
flow gradient in two directions; a cosine estimate proposes a final direction,
which is accepted only if its measured flow improves on the winner. This uses
total panel flow, so multiple panel groups contribute. It is a bounded local
refinement, not a guarantee of the global maximum on a shaded craft.

| Refinement setting | Default | Meaning |
|---|---|---|
| `SOLAR_REFINE_STEP` | 15° | Probe tilt on either side of each tangent axis |
| `SOLAR_REFINE_TOLERANCE` | 1° | Pointing tolerance for fine measurements and final return |
| `SOLAR_REFINE_TIMEOUT` | 45 s | Total optional refinement budget; 0 disables it |
| `SOLAR_REFINE_MIN_GAIN` | 0.002 | Require a measured gain above 0.2% before changing the winner |

Fine turns allow at most 15 seconds each within that shared budget, reserving
time for the final return to the best measured direction. A stalled refinement
retains the coarse result. An older proven cache gets this refinement without
repeating the six-axis discovery; later calls validate/reuse the learned axis.
An axis without a valid saved flow benchmark goes straight to discovery.
Fresh discoveries require a settled final return and positive daylight flow
before replacing the cache.

There is no tracking probe or inferred panel-type branch. Each turn snapshots
a complete target attitude; the live lock follows Sun motion without using
the vessel's changing attitude as its reference. The six candidates use
quarter-turn steps. Automatic discovery can stop its coarse pass at a settled
candidate reaching 90% of a valid saved peak; forced searches measure all six.
Alignment, flow, eclipse and cache safeguards remain.
Solar temporarily uses `SOLAR_MIN_IPU` (2000 by default), restoring the
prior setting after success/failure or at the next boot after interruption.
Boot-log archive copying is deferred during the search, so status messages
do not each recopy the entire log.

Automatic `solardiag_<craft>_<UTms>.log` reports go directly to
`0:/logs/archive/_diagnostics/` after a quiet search. They contain five-second
turn samples, actual and requested attitude vectors, the steering manager's
target/errors, raw control channels, angular velocity, SAS/RCS/suppression,
warp state, CPU budget, charge/flow, accessible panel/wheel field names/types,
and CPU roles. Raw control channels do not measure the steering manager's
actual torque. A separate ledger retains up to 24 settled coarse/fine readings,
including requested and actual Sun axes in craft coordinates, even if the
64-row/24,000-character detail ring fills. Sampling writes no files; dropped
detail-row counts are explicit. Exports require zero actual/raw/pilot thrust
and time before an entry deadline. Offline reports use available local log space and the existing
recursive boot sweep; otherwise details remain buffered until a safe export.
The latest compact summary survives reboot. Run
`RUNPATH("0:/cmd/solarreport.ks").` for that summary and the last verified file
path, then send the report for analysis. No installed `boot.ks` replacement
is needed. `SOLAR_DIAGNOSTICS=0` disables detailed recording. The supplied RO9
flight and its limits are recorded in [the solar review](docs/SOLAR_SEARCH_REVIEW.md).

`solarhold` and `orientForSolar` commands start a continuing hold only after
a successful orientation. A failed scan cannot silently enter an indefinite
hold at its last unsuccessful candidate.
`STATS solar search/aim/cache/sample/refine/hold` rows distinguish the search budget,
each turn's start error, elapsed time, final error and rotation rate, flow
samples, and the start/result of a maintenance re-aim. `alignment-timeout`
means that turn exhausted its allowance; `search-deadline` means the shared
search budget or earlier entry wake time ended. The gaps after the six-axis
search message and before cache validation include actual steering/settling;
they are not fixed 30-second computation delays. Failed attempts preserve
the proven cache and do not authorize auto-warp.

## Multi-CPU ships and roles

Each kOS processor boots the same `boot/boot.ks`; `CORE:TAG` routes tagged
CPUs to `roles/<tag>.ks`, untagged CPUs run the vehicle script. Each CPU has
its own `1:/` volume, so state is naturally isolated.

| CPU | Tag | Script | Role |
|---|---|---|---|
| Primary | *(empty)* | `craft/<vehicle>.ks` | Full mission |
| Lander | `lander_cpu` | `roles/lander_cpu.ks` | Post-separation deploy + science |
| Descent service | `descent_service` | `roles/descent_service.ks` | Passive until descent separation, then retrograde + chutes |
| Zombie | `zombie` | `roles/zombie.ks` | Dormant; remote-reboot backdoor |

EVA kerbals are auto-detected (no tag needed) and run `roles/EVA.ks`, which
branches on the kerbal's trait. Role scripts keep an explicit
`bootVehicleLibs()` hook because some roles do not have mission profiles;
keep them small — they usually live on OCTO-class cores.

## Extending the system

Every `cmd/` script must wrap its executable body in a local entry function
and invoke it once. Keep script parameters, directives and global defaults
at file scope; put bootstrap and command logic inside the function:

```kerboscript
PARAMETER opts IS LEXICON().

LOCAL FUNCTION _commandMain {
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().
    IF ABORT { RETURN. }
    // Command logic goes here.
}

_commandMain().
```

Use the same pattern for executable archive helpers. A file-level `RETURN`
is invalid even inside an `IF` or loop; kOS permits returns from functions
and triggers. `make check` enforces command entrypoints and return scope.
See [CLAUDE.md](CLAUDE.md) for the required coding conventions.

kOS also rejects `IF NOT DEFINED name { ... }`. To handle an absent variable,
use `IF DEFINED name { } ELSE { ... }`. The repository check flags this
parser quirk; ordinary boolean negation such as `IF NOT ABORT` is valid.

A vehicle script defines two things:

```
SET SOME_DEFAULT TO value.  // craft defaults; mission profiles override them
GLOBAL FUNCTION main { ... } // build seq + phase map, runPhases()
```

Minimal pattern (see `craft/FDR1.ks` for a real one):

```
LOCAL DEFAULT_SEQ IS LIST("XING", "COAST", "CAPTURE", "SHAPE", "DONE").

GLOBAL FUNCTION main {
    LOCAL seq IS DEFAULT_SEQ.
    IF SEQUENCE:LENGTH > 0 {
        SET seq TO phaseList(SEQUENCE).
    }
    SET launchSeq TO seq. SET xferSeq TO seq.
    IF stateGet("phase","") = "" { stateSet("phase", seq[0]). }
    LOCAL phaseMap IS phaseHandlerMap().      // optional local overrides
    phaseMapSet(phaseMap, "MYPHASE", _myPhase@).
    runPhases(phaseMap).
}
```

Aircraft instead call `airplaneMain(name, opts)` and pass checklist /
configure-hook / extra-phase options.

Config code deliberately favors direct globals over defensive lookups. Do not
add `CFG:HASKEY` or string-key config helpers; defaults belong as globals in
the file that owns the behavior, and profiles/craft/commands override those
globals. Boot runs the selected profile again after loading the required
library band, so mission values win over owning-lib defaults. A bad symbol
should fail loud during boot or flight-test, not disappear behind fallback
logic. If a config name would collide with a kOS global, use a trailing
underscore (`TARGET_`).

### Ready-made phases

| Phase(s) | Lib | Purpose |
|---|---|---|
| PRELAUNCH | prelaunch | Flight-plan card + launch-window setup |
| LAUNCH, FAIR, ANTS, PARK | launch | MechJeb ascent → parking orbit |
| XING, ESCAPE | xfer_plan, return_escape | Transfers and moon-return escapes |
| RDV | rdv_plan | Lightweight same-body Hohmann rendezvous |
| MATCH, CREW_XFER | maneuver_rendezvous | Close approach and crew transfer |
| MCC | maneuver_transfer | Legacy element-based mid-course correction |
| BPLANE, REFINE_BPLANE | arrival_bplane | Initial and midpoint B-plane corrections |
| COAST, COAST_1HALF, COAST_2HALF, CAPTURE | capture | SOI/midpoint coast + capture burn |
| SHAPE | orbit_shape | Closed-form orbit shaping to SHAPE_* |
| DUNA_AEROCAPTURE, IKE_SETUP, DUNA_ENTRY_SETUP, DUNA_ENTRY_LOWER_PE | duna_ike_setup | Duna/Ike mission glue |
| GOTO | goto_plan | Replan next hop toward `goto_dest` |
| CIRC, RAISE, INCLINE, ELLIPTICAL | maneuver_orbit | Legacy orbit cleanup |
| DROP_FOR_IMPACT_AND_RAISE_PE | payload_release | Payload impact disposal + recovery |
| TARGETED_DEORBIT, RELEASE_PROBE, RELAY_OPS, SCANSAT_OPS | payload_ops (+science) | Payload operations |
| LAND_DEORBIT | landing_deorbit (+deorbit_targeting) | Targeted landing deorbit |
| LAND_ASSIST, LAND | payload_landing, landing_main | Powered descent and assist takeover |
| ROVER | rover | Surface rover ops |
| MOLNIYA_INSERT | molniya | Molniya insertion |
| AEROBRAKE, DESCENT | aerobrake, descent | Kerbin return entry + descent |
| PREFLIGHT, FLIGHT, POSTFLIGHT | airplane | Aircraft lifecycle |
| AIRCLIMB, ROCKETCLIMB, SSTO_DEORBIT, REENTRY, APPROACH | ssto | Spaceplane lifecycle |
| ARM, FLY | drone | Drone sorties |

### Coast automation

Mission profiles can opt into hands-off long coasts:

```ks
SET COAST_AUTO_WARP TO 1.   // Requires a future KAC alarm; otherwise skipped.
```

Coast automation only enters hibernation. It does not wake probe cores; clear
hibernation manually when you want control back. Split coasts run solar/EC
health checks before long warps and can create midpoint KAC alarms for B-plane
refinement.

`idealCoastWarpRate(waitSeconds)` maps wait time to warp indices: 60s to
under 5m uses 2, up to 1h uses 3, under 3 Kerbin days uses 4, under 10 days
uses 5, and longer waits cap at 6.

### Key planner/executor functions

| Function | Lib | What it does |
|---|---|---|
| `executeManeuver()` | maneuver | Fly the next node (alarms, staging, throttle taper) |
| `planTransfer(body, pe, lan, aop)` | maneuver_transfer | Departure window + transfer node |
| `planBplaneCorrection(body, pe, inc, lan)` | arrival_bplane | Converged arrival-corridor node |
| `shapeNextBurn(targets)` / `shapeConverged(targets)` | orbit_shape | Next closed-form shaping burn |
| `gotoBuildPlan(dest)` / `gotoCommitPlan(plan)` | goto_plan | Hop routing |
| `planCapture / planCircularize / planAoPChange / planInclinationChange` | maneuver, inclination | Single-burn planners |
| `lambertSolve(r1, r2, tof, mu, flip)` | lambert | Izzo Lambert solver |
| `landingExecute()` / `targetedDeorbit()` | landing, deorbit_targeting | Powered descent / precision deorbit |
| `droneGoto(geo, agl)` etc. | drone | Drone mode commands |

## Tagged parts (VAB)

| Tag | Purpose |
|---|---|
| `main_fairing` | Fairing jettisoned by FAIR |
| `probe_decoupler`, `probe_chute` | Probe payload release |
| `scansat_decoupler` | Mapper release |
| `landing_assist_decoupler` | Legacy label only; current vacuum landing uses staging order |
| `relay_1`, `relay_2`, ... | Individual relay decouplers |
| `chute_main` | Abort parachute |
| `steering_gear` | Aircraft/drone nosewheel power steering |
| `descent_fairing`, `descent_decoupler`, `descent_chutes` | Kerbin-return descent hardware |

## Mod dependencies

**kOS**, **MechJeb** (ascent), **Trajectories** (impact prediction),
**KerbalEngineer** (burn times), **Kerbal Alarm Clock** (warp-stop alarms),
**SCANsat** (optional mapping), **Waypoint Manager** (target selection for
planes/drones/landings). SimpleJSON is only needed to run the one-time legacy
state converter.

## Development

- `python3 -B scripts/ksp_snapshot.py` — create a private full-game `.tar.gz`
  snapshot locally, plus SHA-256 checksum and embedded mod/source manifest.
  Save and quit KSP first. For the Deck installation and separate kOS repo:

  ```bash
  python3 -B "$HOME/code/kos_programs/scripts/ksp_snapshot.py" \
    --game "$HOME/Kerbal Space Program" \
    --archive-root "$HOME/code/kos_programs"
  ```

  Output defaults to `$HOME/ksp-snapshots/ksp-<UTC>.tar.gz`. It preserves the
  full installed game build, GameData (including manually changed mods),
  saves and their onboard kOS state, Ships, settings and optional kOS archive.
  kOS archive symlinks become real files so the copy stands on its own.
  Logs, git metadata, CKAN download caches and regenerable ModuleManager
  caches are omitted. It refuses overwrite, insufficient space, unexpected
  external links, and detected source-file changes; `--allow-running` is an
  explicit non-atomic live-copy option. It saves disk state, not unsaved play.
  Copy the `.tar.gz` and `.sha256` yourself, verify with `shasum -a 256 -c
  <filename>.sha256`, then extract into a fresh directory. Keep the source
  copy as a backup. The captured Windows build still needs your chosen
  Windows runtime on the Mac; Proton/Wine prefixes and Steam credentials
  are not included. Parallax's published Mac setup uses
  [CrossOver](https://github.com/Gameslinx/Parallax-Continued#installation-instructions---mac).
  This script has no SSH, install, launch, settings-change or restore action;
  only small synthetic fixtures were captured while developing it.
- `scripts/deck-diagnostics status` — read-only Steam Deck memory, GPU counters
  and process states. The fixed wrapper also supports `crash --boot previous`
  (or `current`), `logs --craft RO9 --count 12`, and
  `fetch RO9_4214328/boot_011_core.log`. Each run saves a new private report
  directory under `/tmp/ksp-deck-*`; stdout prints its path. Crash journals
  keep up to20,000 kernel lines; game logs keep256KiB tails and fetched flight
  logs keep2MiB tails, with truncation marked in `report.json`.
  Approve the exact absolute wrapper prefix once to reuse it for these
  diagnostics. There is no arbitrary-command, sudo, settings, reboot or
  flight-control action. SSH uses the existing key and pinned host identity;
  update `HOST` if the Deck address changes, and enroll host keys separately.
  Reports contain machine/flight logs; inspect them before sharing publicly.
- `make check` — routine repository contracts and source-driven numerical/control
  fixtures (Python 3 + NumPy; does not run kOS or KSP). Individual routine
  check calls target under one second; a file can contain several calls.
- `make check-slow` — explicitly run the full finite-burn predictor/independent
  Heun comparison, which still exceeds one second after optimization.
- `make check-all` — routine and slow checks together.
- `make check-times` — run all checks and list the slowest files and individual
  calls. For machine-readable results:
  `python3 -B scripts/run_checks.py --suite all --timings --json /tmp/kos-check-times.json`.
  See [check performance](docs/CHECK_PERFORMANCE.md) for measurements and scope.
- `make audit` — phase/dependency coverage and source-token counts by band,
  including warnings for guarded but unavailable handlers.
- [Codebase audit](docs/CODEBASE_AUDIT.md) — findings, repairs, remaining
  functional gaps, and flight validation priorities.
- `make watch-sync` — safe auto-pull loop for live sim iteration (ff-only,
  dirty-tree aware).
- `make release-version TAG=kos-YYYYMMDD-N` — stamp `VERSION` (printed in
  logs as `CODE version=...`), commit, tag, push.
- Code reaches the game only through this repo (the archive folder syncs
  from it), so **commit and push when a change is ready to fly**.
