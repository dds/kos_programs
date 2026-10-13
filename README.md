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
| `RUNPATH("0:/cmd/returnrescue.ks").` | Repair an in-flight Kerbin return and resume at MCC |
| `RUNPATH("0:/cmd/resumeburn.ks").` | After inspection, continue an interrupted XING burn now using its retained node |
| `RUNPATH("0:/cmd/arrival.ks", "review").` | Inspect a retained partial arrival; actions `accept` / `replan`, optional capture Ap in km |
| `RUNPATH("0:/cmd/arrival.ks", "status").` | Show actual arrival Pe, capture fuel estimate, correction spending and interrupted-burn reason without flying |
| `RUNPATH("0:/cmd/airtest.ks").` | Airplane assist shakeout card (see [Aircraft](#aircraft)) |
| `RUNPATH("0:/cmd/setphase.ks", "PHASE").` | Force a phase, keep the mission |
| `RUNPATH("0:/cmd/resetmission.ks").` | Clear the profile; next boot shows the picker |
| `RUNPATH("0:/cmd/dump.ks").` | Print persistent state |
| `RUNONCEPATH("0:/cmd/trimstate.ks").` | Remove bulky stale state keys after a tight-storage boot |
| `RUNPATH("0:/cmd/convertstatejson.ks").` | Convert legacy SimpleJSON state to native kOS JSON |
| `RUNPATH("0:/cmd/logs.ks").` | Archive the flight log to KSC |
| `RUNPATH("0:/cmd/scan.ks", "status").` | SCANsat/science: `start` / `status` / `transmit` |
| `RUNPATH("0:/cmd/setlanding.ks", "assist").` | Landing overrides from archive: `deorbit` / `assist` |
| `RUNPATH("0:/cmd/setorbit.ks", ...).` | Set orbit targets for the next phases |
| `RUNPATH("0:/cmd/geodistance.ks", lat1, lng1, lat2, lng2).` | Surface distance between two lat/lng points on the current body |
| `RUNPATH("0:/cmd/kscsplash.ks").` | Target water splashdown offshore of KSC |
| `RUNPATH("0:/cmd/zombie.ks").` | Power-cycle every *other* CPU on the vessel |

Emergency landing rescue is archive-only: run `0:/cmd/landassist.ks`,
`0:/cmd/landmin.ks`, or `0:/cmd/landingrescue.ks` while linked.

Commands require archive access. If you need one, get a link and run the
archive copy directly.

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

Long, low-thrust burns can leave transverse node error because a maneuver
node models an instantaneous impulse. The live throttle guard tapers the
remaining component along the craft's thrust direction near cutoff, and
latches off if the powered residual rebounds from its best value. A stopped
burn with residual error is checked against the actual arrival trajectory;
it is not declared precise just because the engines stopped. Controls are
unlocked after cutoff, including failed burns. This is cutoff protection,
not a finite-duration transfer optimizer.

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

`boot/boot.ks` (installed in the VAB, **not remotely updatable**) syncs only
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

### Phase machine and sequences

Mission profiles own `SEQUENCE` — the ordered phase names. Craft scripts map
phase names to handlers and call `runPhases(phaseMap)`; each handler calls
`nextPhase(seq)` when done. The current phase persists to state, so any
reboot resumes exactly where it left off. Shared phases follow the naming
convention `PHASE_NAME -> phasePhaseName`; generated bindings map the current
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
dependencyPreamble()             roots loaded always
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
unconverged optional correction also holds rather than spending its budget
on a partial improvement.

These checks apply to retained maneuver nodes on reboot as well as new
plans. Rejected nodes are removed; the original trajectory is retained and
the current phase yields to the console. **A hold does not stop game time.**
It does not silently waive the polar orbit or landing-site requirements.
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
a smaller executor cutoff for tiny burns. A failed correction holds with its
node retained, rather than deleting it and blindly retrying. Explicit
`arrival.ks` action `replan` can discard an interrupted BPLANE/REFINE_BPLANE
correction and clear its interruption state before planning from the actual
flown orbit, including recovery from older saves whose node was already
deleted. It preserves correction spending and all fuel/capture limits.
This action does not apply to an interrupted XING departure. `status` does
not execute a burn; `replan` resumes automatic planning and execution.

SHAPE verifies the accepted capture ellipse without requesting circularization;
its cleanup allowance is 10 m/s per burn, 20 m/s total, with a 50 m/s reserve.
SCIENCE_OPS runs the available experiments once, then holds for the contract
survey (`SCIENCE_OPS_HOLD=1`). It does not fly temperature waypoints or check
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
and nearby terrain refinement. Contract waypoints are ignored
(`LANDING_USE_WAYPOINTS=0`); these profiles do not perform the polar temperature
survey or land at the old contract coordinates. The existing targeted-deorbit
path still needs Trajectories, with SCANsat refinement when available.
Surface ascent flies east to a 10 km parking orbit, accepting the minimum
inclination reachable from the actual landing latitude.

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
It targets 15 km low orbit in the natural arrival plane, runs experiments,
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
13–17 km capture corridor; no low-periapsis checks are waived. Use this switch
on the Kerbin-side Mun approach, before entering the Mun SOI. After capture,
check that the science data is retained in parts that will return with the
probe (particularly before the engine/tank separates), collect any additional
available readings, and start the return when ready:

```kerboscript
RUNPATH("0:/cmd/setphase.ks", "RETURN_SETUP").
REBOOT.
```

RETURN_SETUP writes the same 53 km shallow-entry Kerbin return used by the
economy profiles, with no optional KSC targeting burns. The orbit-only
profile is covered by `python3 -B scripts/check_surface_return.py`; actual
capture/departure costs and science recovery still need flight validation.

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
  direct encounters inside the correction corridor rank by departure dV
  rather than closeness to the target's center. This is not a minimum-total-
  mission-dV guarantee. Interplanetary transfers use the Lambert planner:
  analytic shortlist, patch refinement, ejection-dV ranking, and escape-path
  safety checks. When `BPLANE`/`SHAPE` follow, XING is only a handoff gate: it
  must create a real target patch, but it leaves exact arrival geometry to the
  downstream phases.
- **BPLANE** (`lib/arrival_bplane.ks`) — mid-coast B-plane correction: a 2×2
  Newton iteration on (B·T, B·R) steers the arrival hyperbola onto the
  requested plane (`CAPTURE_INC`/`CAPTURE_LAN`) and periapsis (`CAPTURE_PE`).
  Smooth where raw patch elements are discontinuous. If the departure burn
  still leaves the ship inside the departure SOI, BPLANE first coasts out to
  the transfer body's frame before measuring the arrival.
- **COAST_1HALF / REFINE_BPLANE / COAST_2HALF** — long transfers split around
  a timed midpoint. The first coast preserves solar attitude and can set a KAC
  alarm, `REFINE_BPLANE` performs capped small correction burns until the
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
| `landing_assist_decoupler` | Expendable descent-assist stage |
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

- `make watch-sync` — safe auto-pull loop for live sim iteration (ff-only,
  dirty-tree aware).
- `make release-version TAG=kos-YYYYMMDD-N` — stamp `VERSION` (printed in
  logs as `CODE version=...`), commit, tag, push.
- Code reaches the game only through this repo (the archive folder syncs
  from it), so **commit and push when a change is ready to fly**.
