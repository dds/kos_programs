# CLAUDE.md

## What this is

KerbalScript (kOS) mission automation for Kerbal Space Program. The main vehicles are FR2 and FR3 multi-payload launchers, plus aircraft, rover, EVA, and role scripts. Scripts run on in-game kOS processors with tight storage limits (OCTO probe = 10,000 bytes).

## Language

KerbalScript (.ks files) — a scripting language for the kOS mod. Not Python, not JavaScript, but looks similar. Key differences from mainstream languages:
- `LOCAL` = local scope, `GLOBAL` = exported/public
- `PARAMETER` for function args
- `SET x TO value.` for assignment (note the period — all statements end with `.`)
- `LOCK` binds a variable to a live expression (re-evaluated every tick)
- `WHEN ... THEN { }` = async trigger (runs once when condition is true, use `PRESERVE.` to keep it armed)
- `LEXICON()` = dictionary, `LIST()` = array
- String methods: `:SPLIT()`, `:TRIM()`, `:CONTAINS()`
- All identifiers are case-insensitive

## Architecture

### Boot chain
`boot/boot.ks` → syncs only `boot_lib` plus `dependencies.txt` → loads `boot_lib` → calls `bootPreamble()` to load core/preamble libs → detects EVA kerbals via `kerbalEVA` root part → parses ship name (or auto-sets vehicle=EVA, target=body) → resolves `roles/` and `craft/` scripts for CORE:TAG or vehicle script → reads the selected mission config from archive and stores `mission_cfg_*` keys in `state.json` → syncs + runs vehicle/role script (defines CFG, bootVehicleLibs(), main()) → loads `bootVehicleLibs()` through `bootLibLoadList()` → loads resume/recovery through `bootLibLoad()` → manual override window → auto-resume or manual

### CORE:TAG routing (multi-CPU ships)
If `CORE:TAG` is non-empty, boot resolves the tag via `_resolveScript()` checking `roles/` then `craft/` then root. Each processor has its own `1:/` volume so state is naturally isolated. Untagged CPUs always load the vehicle script from `craft/`.

A typical multi-CPU ship (FR2 to Mun/Minmus/Duna/remote Kerbin) has three processors:
- **Primary** (untagged) — runs the vehicle script (FR2.ks), handles the full mission
- **Lander CPU** (tagged `lander_cpu`) — runs `roles/lander_cpu.ks`, activates post-separation for deploy + science
- **Zombie** (tagged `zombie`) — runs `roles/zombie.ks`, closes its terminal and goes dormant. Operator can open it later to reboot stuck CPUs

### Action groups and manual intervention
Action group 0 toggles power on the kOS processor and opens/closes its terminal window. Pressing `0` a few times in KSP power-cycles the CPU, forces a reboot, and opens the terminal. Boot then gives a 5-second window to press any key for manual mode before auto-resuming the mission. This is the standard way to interrupt a running mission and get a console.

### Zombie: remote reboot for manual control
The zombie is a dormant backup CPU (usually a tiny OCTO on the upper stage). If the primary mission computer gets stuck, the operator can:
1. Right-click the zombie's probe core → open kOS terminal
2. Run `RUNPATH("1:/cmd/zombie.ks").`
3. This power-cycles every other CPU on the vessel, forcing fresh reboots
4. The primary reboots into its 5s manual-mode window, giving the operator control

The zombie itself is unaffected since `cmd/zombie.ks` skips the CPU running it. The `cmd/zombie.ks` script can also be run from any CPU — the role just ensures there's always a clean, idle CPU available.

### Pre-launch config screen
On first boot (or when phase is LAUNCH), FR2 shows a flight plan summary listing all CFG values grouped by mission phase (ascent, transfer, orbit, probe). A 30s countdown with progress bar auto-launches; press ENTER to skip. Edit CFG values in the kOS terminal during the countdown to override defaults.

### Storage model
- `0:/` = archive (unlimited, only accessible near KSC)
- `1:/` = local volume on the processor (limited — OCTO has 10,000 bytes)
- Files must be copied from archive to local before use in flight

### Mission sequence, phases, and boot libraries
Mission profiles own `SEQUENCE`: the ordered mission steps. `lib/boot_lib.ks` reads compact `lib/dependencies.txt` to expand preamble roots, library dependencies, phase roots, and multi-phase bands. `lib/dependencies.ks` is generated from the `PHASE` rows and only binds phase names to convention delegates such as `LAUNCH -> phaseLaunch@`.

For craft and roles, define `GLOBAL FUNCTION bootVehicleLibs { RETURN ... . }`. Use profile `LIBS = ...` only as an escape hatch; otherwise derive libraries from `SEQUENCE` and append extras with `LIBS_EXTRA`. Edit `lib/dependencies.txt` one line at a time for shared dependency updates. Keep it comment-free and compact because it is copied as text to the probe core.

Mission profile `.cfg` files are not copied to the probe core. Boot reads them from `0:/missions/<craft>/` when connected, parses the selected profile once, and persists the values into `1:/run/state.json`.

### State persistence
JSON file at `1:/run/state.json` via `lib/state.ks`. Survives reboots. Use `stateGet(key, default)` / `stateSet(key, value)`.

### Phase machine (`lib/phases.ks`)
- `runPhases(phaseMap)` — main loop. Takes a LEXICON mapping phase names to delegates. Reads current phase from state, calls the matching delegate, loops until DONE.
- `phaseHandlerMap()` — loads `lib/dependencies.ks` on demand, then builds the loaded-band phase handler map.
- `phaseMapSet(map, phase, delegate)` — add or override a handler.
- `nextPhase(seq)` — advance to next phase in a given sequence LIST. Persists to state.
- `phaseDone()` — generic mission-complete cleanup.

Vehicle scripts build their own sequence LIST, call `phaseHandlerMap()`, add craft-specific handlers, then call `runPhases()`. Shared phase functions should follow the case-insensitive convention `PHASE_NAME -> phasePhaseName`, with underscores converted to camel case.

## Code conventions

- 4-space indentation, no tabs
- File headers: `// ============` block with filename, description, path
- Liberal comments encouraged in `.ks` source files — they are compiled to KSM bytecode before upload, so comments have zero storage cost. Keep copied text files such as `dependencies.txt` compact.
- Private functions: `LOCAL FUNCTION _name { }` (underscore prefix)
- Public functions: `GLOBAL FUNCTION name { }` (camelCase)
- kOS string comparisons are case-insensitive; do not add `TOUPPER`/`TOLOWER` just to compare strings.
- Config: `GLOBAL CFG IS LEXICON(...)` at top of vehicle scripts
- Logging: `mLog()`, `mLogWarn()`, `mLogError()`, `mLogPhase()`
- State: `stateGet()` / `stateSet()` — never raw file I/O for mission state
- Parts found by tag name (set in VAB), not by index

## File roles

- `boot/` — bootstrap only, keep minimal for easy reloading
- `lib/` — reusable libraries, loaded via `RUNPATH()`
- `cmd/` — operator commands, run manually from terminal (NOT synced at boot)
- `craft/` — vehicle flight computers (FR2.ks, FR3.ks, FJ1A.ks, FJ4B.ks, FBIJ.ks, FSP1.ks, X_SHOT.ks)
- `roles/` — role scripts for CORE:TAG routing (lander_cpu.ks, zombie.ks, EVA.ks)

### Key libs

| Lib | Purpose |
|---|---|
| `core.ks` | Always-loaded helpers (`contains`, `phaseIn` compatibility wrapper) |
| `config.ks` | Shared config utilities (cfgSet, cfgFromState, applyMissionState, phaseListFromString) |
| `phases.ks` | Generic phase machine and central phase handler registry |
| `launch.ks` | Reusable ascent phases (launch, fairing, extend, parking) + rocketMain() skeleton |
| `xfer_plan.ks` | Transfer/rendezvous planning phases (RDV, XING) |
| `capture.ks` | Coast and capture phases |
| `maneuver_orbit.ks` | Orbit cleanup phases (CIRC, RAISE, INCLINE, ELLIPTICAL, DROP_FOR_IMPACT_AND_RAISE_PE) |
| `state.ks` | Persistent JSON key-value store |
| `logs.ks` | Flight logging with fault persistence |
| `files.ks` | Storage status and directory listing |
| `boot_lib.ks` / `dependencies.txt` | Boot helpers plus text-driven preamble, library dependency, phase root, and multi-phase band expansion |
| `mission_plan.ks` | Mission `SEQUENCE` parsing and payload helpers |
| `resume.ks` | MISSION lexicon, operator helpers, resumeMission(), buildRocketSequence() |
| `maneuver.ks` | Maneuver node execution with dynamic throttle, planCapture, planCircularize, planAoPChange |
| `maneuver_transfer.ks` | planTransfer (LAN via multi-orbit scan, PE via Newton on dV) and phaseMidCourse |
| `lambert.ks` | Lambert solver (RSVP port, GPL-3.0). lambertSolve(r1,r2,tof,mu,flip), orbitalStateVectors. For future interplanetary use |
| `inclination.ks` | Orbital plane change planning + etaToTrueAnomaly() |
| `molniya.ks` | Molniya orbit insertion (molniyaParams, printMolniyaSummary, planMolniyaInsert, phaseMolniyaInsert) |
| `orbit.ks` | Orbit monitoring and stability checks |
| `countdown.ks` | Launch countdown with audio |
| `payload_ops.ks` | Shared payload phases — phaseTargetedDeorbit, phaseReleaseProbe (chute arm, sunward orient, decouple), phaseRelayOps |
| `payload_landing.ks` | Landing/rover payload phase wrappers |
| `deorbit_targeting.ks` | Precision deorbit via Trajectories addon |
| `science.ks` | Experiment automation and SCANsat integration |
| `landing.ks` | Powered descent / suicide burn |
| `recovery.ks` | Post-abort recovery — safe antenna deploy, flight log archive, operator prompt |
| `relay_constellation.ks` | Multi-relay deployment |
| `airplane.ks` | Aircraft autopilot |
| `rover.ks` | Ground vehicle control |
| `observe.ks` | Periodic telemetry logger with sentinel-file control |
| `utils.ks` | General-purpose utilities (fmtDuration, printOrbitRef) |
| `lib_navigation.ks` | KSLib — phase angle, AN/DN, orbital vectors |
| `lib_circle_nav.ks` | KSLib — great circle bearing/distance |
| `lib_enum.ks` | KSLib — functional list/queue/stack operations |

### Observation mode (`lib/observe.ks`)

Periodic telemetry logging to a separate file from the flight/fault log. Designed for long flight tests (3+ hours).

- **Log file**: `1:/run/obs_<shipname>_<time>.log` — one compact ~100-byte line per entry
- **Fields**: `T spd gspd alt vs hdg pit rol thr free` + plane-specific (`auth wbrk wstr wlev ahld hhld`) when `planeActive`
- **Config**: `OBS_CFG` lexicon — `INTERVAL` (default 120s), `MIN_FREE` (default 2000 bytes), `STOP_FILE` (`1:/run/obs_off`)
- **Sentinel file** (`1:/run/obs_off`): checked at log time, not every tick. Auto-created on abort, low storage, or `observeStop()`. Deleted by `observeStart()` to re-enable.
- **Integration**: craft scripts add `"observe"` from `bootVehicleLibs()` and call `observeStart()` in preflight. `_launchAbort()` creates the sentinel to halt logging on abort.
- **Budget**: 120s interval over 3 hours = ~90 entries = ~9KB

### Manual mode

At boot, pressing any key within 5s enters manual mode. The terminal displays environment data (body, status, altitude, airspeed/position for atmospheric or orbit params for orbital), mission state (vehicle, target, phase, boot count), storage, and contextual info for loaded libs (airplane config, observation status). No commands are offered — the kOS console cannot call loaded functions directly without a helper script. The `cmd/` directory contains scripts that can be run via `RUNPATH()` but these are not synced at boot and require archive access.

### Rover power steering (`lib/rover.ks`)

Uses `SHIP:CONTROL:PILOTWHEELSTEER` (not `PILOTMAINSTEER`, which doesn't exist in kOS) scaled by a speed-dependent factor to reduce steering sensitivity at higher speeds.

### Transfer planning (`lib/maneuver_transfer.ks`)

`planTransfer` uses a 3-step process:
1. **Hohmann estimate** — phase angle math gives initial departure time and dV
2. **LAN selection** (when `CAPTURE_LAN` is set) — multi-orbit scan. Each orbital period produces a different approach geometry and therefore a different LAN at the target. Scans `±N` orbits around the Hohmann estimate (N = max(6, target period / ship period)), finds valid encounters via `_findEncounter`, reads LAN from the conic patch, and picks the orbit with lowest LAN error. Logs each candidate.
3. **PE convergence** — Newton's method on dV magnitude. 0.5 m/s epsilon, 0.7 damping, +/-15% dV bounds, 200m tolerance.

LAN is controlled by which orbital period to depart on, PE is controlled by dV — these are separable. AoP is reported but corrected later by MCC (radial burns mid-transfer).

### Mid-course correction (`lib/maneuver_transfer.ks`)

`phaseMidCourse` fires at the coast midpoint (local transfers) or 1 hour past SOI transition (interplanetary). Corrects PE (prograde), AoP (radial), and LAN (normal) via independent Newton iterations, each with 0.5 m/s epsilon and 0.7 damping. Total dV capped at 50 m/s. Skips if encounter is already on target.

### Capture orbit targeting

Optional CFG keys for precise orbital plane control at the target body:

- `CAPTURE_INC` — target inclination after capture. Corrected via `planInclinationChange()` post-capture. The later `INCL_CORRECT` phase (using `TARGET_INCLINATION`) acts as a safety net.
- `CAPTURE_LAN` — target longitude of ascending node. Achieved by timing transfer departure via Newton's method on departure time in `planTransfer`.
- `CAPTURE_AOP` — target argument of periapsis. Corrected post-capture via `planAoPChange()`, a pure radial burn at the orbit intersection point. Also refined mid-transfer by MCC.

Corrections run in order: AoP first (in-plane), then INC (out-of-plane). All are optional and skipped when the corresponding CFG key is absent.

## Key constraints

- **Storage is scarce at runtime.** OCTO probes have 10,000 bytes; the primary FR2 probe core has ~100KB. Source files are compiled to KSM bytecode before upload, so comments and whitespace are free — only the compiled size matters. Use `bootVehicleLibs()` to load only what you need.
- **No archive access in flight.** Once out of KSC physics range, you can't pull new files from 0:/.
- **Reboots happen.** Power loss, quickload, scene changes all trigger reboot. Everything must be resumable via the state file.
- **Periods end statements.** Forgetting the `.` at the end of a statement is the #1 syntax error.

## Dependencies (kOS addons)

- MechJeb (`ADDONS:MJ`) — ascent guidance
- Trajectories (`ADDONS:TR`) — impact prediction
- SCANsat — orbital scanning
- KerbalEngineer — burn time calculations
- simplejson (`ADDONS:JSON`) — JSON serialization

## Pre-commit

This repo uses the Python pre-commit framework. Install hooks with `pre-commit install`. The local hook regenerates `lib/dependencies.ks` from `lib/dependencies.txt`; run `make dependencies` or `pre-commit run generate-dependencies-ks --all-files` manually when needed.
