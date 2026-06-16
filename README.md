# kos_programs

KerbalScript (kOS) mission automation for Kerbal Space Program. Autonomous,
reboot-safe flight computers for rockets, airplanes, spaceplanes, hover
drones, rovers, and EVA kerbals — driven by data-only mission profiles, with
progressive code loading to fit tiny in-game processors.

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
3. Launch to the pad/runway. Boot syncs code from the archive, shows the
   mission profile picker (when profiles exist under `missions/<vehicle>/`),
   and runs the vehicle script.
4. Press any key within 5 s of any boot for **manual mode**; otherwise the
   mission auto-resumes from saved state.

## Operations

### Breaking into a running mission

Action group **0** toggles power on the kOS processor and its terminal.
Pressing `0` a few times power-cycles the CPU, forcing a reboot — then the
5-second manual-mode window gives you a console. On multi-CPU ships the
dormant **zombie** core can reboot every other CPU remotely
(`RUNPATH("1:/cmd/zombie.ks").` from its terminal).

### Operator commands

Run from a manual-mode terminal. `0:/cmd/...` needs a KSC link; commands
listed in `CMD` rows of `lib/dependencies.json` are pre-installed at
`1:/cmd/<name>` so they work at fields with **no radio** (Island Airfield).

| Command | What it does |
|---|---|
| `RUNPATH("0:/cmd/goto.ks", "Minmus").` | Route to any body/vessel (see [goto](#universal-routing-goto)) |
| `RUNPATH("1:/cmd/restartflightplan").` | Rewind the phase machine for the next sortie/leg (offline-safe) |
| `RUNPATH("0:/cmd/returntokerbin.ks").` | Full automated moon→Kerbin return (escape/MCC/aerobrake/descent) |
| `RUNPATH("0:/cmd/airtest.ks").` | Airplane assist shakeout card (see [Aircraft](#aircraft)) |
| `RUNPATH("1:/cmd/setphase.ks", "PHASE").` | Force a phase, keep the mission |
| `RUNPATH("1:/cmd/resetmission.ks").` | Clear the profile; next boot shows the picker |
| `RUNPATH("1:/cmd/dump.ks").` | Print persistent state |
| `RUNPATH("1:/cmd/logs.ks").` | Archive the flight log to KSC |
| `RUNPATH("1:/cmd/scan.ks", "status").` | SCANsat/science: `start` / `status` / `transmit` |
| `RUNPATH("0:/cmd/setlanding.ks", "tag", "probe_decoupler").` | Landing overrides from archive: `tag` / `deorbit` / `assist` |
| `RUNPATH("0:/cmd/setorbit.ks", ...).` | Set orbit targets for the next phases |
| `RUNPATH("0:/cmd/kscsplash.ks").` | Target water splashdown offshore of KSC |
| `RUNPATH("1:/cmd/zombie.ks").` | Power-cycle every *other* CPU on the vessel |

Emergency landing rescue is archive-only: run `0:/cmd/landassist.ks`,
`0:/cmd/landmin.ks`, or `0:/cmd/landingrescue.ks` while linked.

Only `CMD`-row commands are *guaranteed* on `1:/cmd`; others are local when a
craft's cleanup keep-list retained them or you copied them while linked
(`COPYPATH("0:/cmd/x.ks", "1:/cmd/x.ks").`). When in KSC range, `0:/cmd/...`
always works.

### Multi-leg flights

Airline-style missions (land, swap passengers, fly on) and drone sorties end
each leg normally, then `RUNPATH("1:/cmd/restartflightplan").` archives the
leg's log, rewinds `phase` to the start of the sequence, stamps a fresh
`launch_time`, and reboots. Mission config is untouched. Works offline.

## Architecture

### Boot chain

`boot/boot.ks` (installed in the VAB, **not remotely updatable**) syncs only
`lib/boot_lib.ks` + `lib/dependencies.json`, then delegates: preamble/core
libs load, EVA kerbals are auto-detected (root part `kerbalEVA`), `CORE:TAG`
routes tagged CPUs to `roles/`, untagged CPUs load `craft/<vehicle>.ks`.
The selected mission profile is read from `0:/missions/<vehicle>/` once,
persisted into state as `mission_cfg_*`, and never needed in flight again.
The craft script's `bootVehicleLibs()` returns the library roots to sync;
boot compiles them to KSM (comments cost nothing), prunes stale files, runs
them, then auto-resumes or drops to manual mode.

### Phase machine and sequences

Mission profiles own `SEQUENCE` — the ordered phase names. Craft scripts map
phase names to handlers and call `runPhases(phaseMap)`; each handler calls
`nextPhase(seq)` when done. The current phase persists to state, so any
reboot resumes exactly where it left off. Shared phases follow the naming
convention `PHASE_NAME → phasePhaseName` (e.g. `DROP_FOR_IMPACT_AND_RAISE_PE
→ phaseDropForImpactAndRaisePe`); the bindings are generated into
`lib/dependencies.ks` by `make dependencies`.

### Progressive loading (bands)

Storage is the scarce resource (OCTO = 10 KB, big cores ≈ 100 KB), so code
loads in **bands**: groups of phases whose libraries load together. When the
sequence reaches a phase outside the loaded band, the machine saves
`reload_*` state and asks for a reboot; the next boot loads only the new
band. **A band loads the libraries of every phase in it**, regardless of the
mission — so per-mission code (e.g. ScanSat disposal) lives in its own
phase/band rather than inside a shared band.

### dependencies.json

`lib/dependencies.json` is the compact source of truth, copied as text to the
probe core and parsed with kOS JSON support:

```
"preamble": ["core"]             roots loaded always
"libs": { name: [deps...] }      library dependency edges
"phases": { phase: [roots...] }  libraries a phase needs
"bands": { name: [phases...] }   phases that load together
"cmds": { phase: [cmds...] }     operator cmds installed to 1:/cmd at boot
```

After editing it, run `make dependencies` (also a pre-commit hook) to
regenerate `lib/dependencies.ks`.

### State, logs, telemetry

- **State**: JSON at `1:/run/state.json` via `stateGet`/`stateSet` — never
  raw file I/O for mission state. Survives reboots, quickloads, power loss.
- **Flight log**: `mLog`/`mLogWarn`/`mLogError`; WARN-level `STATS ...` lines
  summarize every plan/burn/phase for post-flight analysis. Archived to
  `0:/logs/archive/` append-and-rotate at phase transitions and after every
  planned maneuver when linked.
- **Observation telemetry** (`lib/observe.ks`): periodic one-line samples
  streamed straight to `0:/logs/obs/` when linked (offline lines buffer
  locally and flush on reconnect). `cmd/airtest.ks` drops the interval to 1 s
  for PID tuning.

### Storage model

`0:/` is the archive (unlimited, KSC link required); `1:/` is the local
volume. Source compiles to KSM before upload, so comment liberally in `.ks`
files. Once out of link range nothing new can be fetched — everything a
mission might need must be loaded (or `CMD`-installed) while connected.

## Vehicles

| Craft | Type | Notes |
|---|---|---|
| `FR2` | Multi-payload launcher | Legacy name-driven flights + profiles |
| `FR3` | Multi-payload launcher | Banded loading, profile-first, rover/mapper missions |
| `FJ1A` | Juno trainer jet | `airplaneMain()` configuration |
| `FJ4B` | Supersonic jet | No landing assist — pilot owns the rollout |
| `FBIJ` | Business jet | GAP airline missions, multi-leg, touch-and-go aware |
| `FSP1` | Seaplane | SPLASHDOWN/SURFACE_OPS water phases |
| `FSS1` | SSTO spaceplane | Template for the Whiplash/RAPIER era |
| `FDR1` | Hover drone | Kerbin (lift engines) and Mun/Minmus (RCS) |
| `ROVER` | Surface rover | Waypoint driving + science |
| `X_SHOT` | Sounding rocket | SHRIMP thermometer/barometer drops |

### Rockets (FR2 / FR3)

Standard sequence: `LAUNCH, FAIR, ANTS, PARK, XING, MCC|BPLANE, COAST,
CAPTURE, <orbit/payload phases>, DONE`. Payload tokens (`RELAY`, `SCANSAT`,
`SCISAT`, `PROBE`, `CRASHPROBE`, `LANDER`, `ASSISTLANDER`, `ROVER`,
`ASSISTROVER`) come from the profile or the legacy ship name and append
their phases automatically. MechJeb flies the ascent. FR3 adds targeted rover
landings (Trajectories deorbit + named/selected waypoints, optional SCANsat
site scan), Mun mapper impact-disposal flows, and the emergency
`mun_rover_emergency_surface` profile.

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

Data-only `KEY = VALUE` files under `missions/<vehicle>/`, selected from the
pad picker or forced via `stateSet("mission_id", "<id>").` + reboot. The
profile owns the phase order; the craft script owns the hardware. Values land
in `CFG` at boot.

```ini
MISSION_ID = mun_sat_delivery_3
MISSION_NAME = Mun Satellite Delivery Contract 3
TARGET = MUN
PAYLOADS = SCISAT
SEQUENCE = LAUNCH,FAIR,ANTS,PARK,XING,BPLANE,COAST_1HALF,REFINE_BPLANE,COAST_2HALF,CAPTURE,SHAPE,RELAY_OPS,DONE
CAPTURE_PE = 95789
CAPTURE_INC = 138.9
CAPTURE_LAN = 51.5
SHAPE_AP = 903586
SHAPE_PE = 95789
SHAPE_INC = 138.9
SHAPE_LAN = 51.5
SHAPE_AOP = 269
```

Boot derives the libraries to load from `SEQUENCE`. `LIBS = ...` replaces the
computed list (escape hatch); `LIBS_EXTRA = ...` appends. While prelaunch,
boot clears any saved profile so a pad reboot re-opens the picker; after
launch, reboots keep mission and phase.

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
  high-transfer orbits. When `BPLANE`/`SHAPE` follow, XING accepts rough
  real patches within the deferred handoff tolerances and leaves precise
  arrival geometry to those phases.
- **BPLANE** (`lib/arrival_bplane.ks`) — mid-coast B-plane correction: a 2×2
  Newton iteration on (B·T, B·R) steers the arrival hyperbola onto the
  requested plane (`CAPTURE_INC`/`CAPTURE_LAN`) and periapsis (`CAPTURE_PE`).
  Smooth where raw patch elements are discontinuous.
- **CAPTURE** — tangential burn at Pe (preserves plane, Pe, and apsis line);
  `TARGET_AP` puts the apoapsis where the final orbit wants it.
- **SHAPE** (`lib/orbit_shape.ks`) — closed-form trim to any specified
  `SHAPE_AP/PE/INC/LAN/AOP`: one combined plane burn at the relative node,
  apsidal rotation, apsis burns. No numeric search; re-measures between
  burns so execution errors self-correct.

The older element-targeting pipeline (`MCC`, `CIRC`, `RAISE`, `INCLINE`,
`ELLIPTICAL`) remains for legacy profiles until BPLANE/SHAPE are
flight-proven (test mission: `missions/FR3/mun_sat_delivery_3.json`).
`cmd/returntokerbin.ks` runs the full moon-return + aerobrake + descent flow.

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
branches on the kerbal's trait. Role scripts follow the same contract as
vehicle scripts (`CFG`, `bootVehicleLibs()`, `main()`); keep them small —
they usually live on OCTO-class cores.

## Extending the system

A vehicle script defines three things:

```
GLOBAL CFG IS LEXICON(...).            // config defaults (profile overrides)
GLOBAL FUNCTION bootVehicleLibs { ... } // library roots for boot to sync
GLOBAL FUNCTION main { ... }            // build seq + phase map, runPhases()
```

Minimal pattern (see `craft/FDR1.ks` for a real one):

```
LOCAL DEFAULT_SEQ IS LIST("XING", "COAST", "CAPTURE", "SHAPE", "DONE").

GLOBAL FUNCTION bootVehicleLibs {
    LOCAL cachedLibs IS bootCachedVehicleLibs().
    IF cachedLibs:LENGTH > 0 { RETURN cachedLibs. }
    RETURN bootLibBand("XFER").
}

GLOBAL FUNCTION main {
    LOCAL seq IS DEFAULT_SEQ.
    IF stateGet("mission_cfg_SEQUENCE", "") <> "" {
        SET seq TO phaseListFromString(stateGet("mission_cfg_SEQUENCE", "")).
    }
    SET launchSeq TO seq. SET xferSeq TO seq.
    IF stateGet("phase","") = "" { stateSet("phase", seq[0]). }
    LOCAL phaseMap IS phaseHandlerMap().      // generated shared bindings
    phaseMapSet(phaseMap, "MYPHASE", _myPhase@).
    runPhases(phaseMap).
}
```

Aircraft instead call `airplaneMain(name, opts)` and pass checklist /
configure-hook / extra-phase options.

### Ready-made phases

| Phase(s) | Lib | Purpose |
|---|---|---|
| LAUNCH, FAIR, ANTS, PARK | launch | MechJeb ascent → parking orbit |
| XING, ESCAPE | xfer_plan | Transfers and escapes |
| RDV | rdv_plan | Lightweight same-body Hohmann rendezvous |
| MATCH, CREW_XFER | maneuver_rendezvous | Close approach and crew transfer |
| MCC | maneuver_transfer | Legacy element-based mid-course correction |
| BPLANE | arrival_bplane | B-plane arrival corridor |
| COAST, CAPTURE | capture | SOI coast + capture burn |
| SHAPE | orbit_shape | Closed-form orbit shaping to SHAPE_* |
| GOTO | goto_plan | Replan next hop toward `goto_dest` |
| CIRC, RAISE, INCLINE, ELLIPTICAL | maneuver_orbit | Legacy orbit cleanup |
| DROP_FOR_IMPACT_AND_RAISE_PE | payload_release | Payload impact disposal + recovery |
| TARGETED_DEORBIT, RELEASE_PROBE, RELAY_OPS, SCANSAT_OPS | payload_ops (+science) | Payload operations |
| LAND_DEORBIT, LAND_ASSIST, LAND, ROVER | payload_landing | Targeted landings, rovers |
| MOLNIYA_INSERT | molniya | Molniya insertion |
| AEROBRAKE, DESCENT | aerobrake, descent | Kerbin return entry + descent |
| PREFLIGHT, FLIGHT, POSTFLIGHT | airplane | Aircraft lifecycle |
| AIRCLIMB, ROCKETCLIMB, SSTO_DEORBIT, REENTRY, APPROACH | ssto | Spaceplane lifecycle |
| ARM, FLY | drone | Drone sorties |

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

**kOS** (with `ADDONS:JSON` simplejson), **MechJeb** (ascent), **Trajectories**
(impact prediction), **KerbalEngineer** (burn times), **Kerbal Alarm Clock**
(warp-stop alarms), **SCANsat** (optional mapping), **Waypoint Manager**
(target selection for planes/drones/landings).

## Development

- `make dependencies` — regenerate `lib/dependencies.ks` (pre-commit hook:
  `pre-commit install`).
- `make watch-sync` — safe auto-pull loop for live sim iteration (ff-only,
  dirty-tree aware).
- `make release-version TAG=kos-YYYYMMDD-N` — stamp `VERSION` (printed in
  logs as `CODE version=...`), commit, tag, push.
- Code reaches the game only through this repo (the archive folder syncs
  from it), so **commit and push when a change is ready to fly**.
