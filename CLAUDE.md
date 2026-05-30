# CLAUDE.md

## What this is

KerbalScript (kOS) mission automation for Kerbal Space Program. The main vehicle is FR2, a multi-payload launcher. Scripts run on in-game kOS processors with tight storage limits (OCTO probe = 10,000 bytes).

## Language

KerbalScript (.ks files) — a scripting language for the kOS mod. Not Python, not JavaScript, but looks similar. Key differences from mainstream languages:
- `LOCAL` = local scope, `GLOBAL` = exported/public
- `PARAMETER` for function args
- `SET x TO value.` for assignment (note the period — all statements end with `.`)
- `LOCK` binds a variable to a live expression (re-evaluated every tick)
- `WHEN ... THEN { }` = async trigger (runs once when condition is true, use `PRESERVE.` to keep it armed)
- `LEXICON()` = dictionary, `LIST()` = array
- String methods: `:SPLIT()`, `:TOUPPER()`, `:TRIM()`, `:CONTAINS()`
- All identifiers are case-insensitive

## Architecture

### Boot chain
`boot/boot.ks` → detects EVA kerbals via `kerbalEVA` root part → parses ship name (or auto-sets vehicle=EVA, target=body) → syncs core libs (state, logs, files) → loads core libs → `_resolveScript()` checks `roles/` and `craft/` dirs (then root fallback) for CORE:TAG or vehicle script → syncs + runs vehicle/role script (defines CFG, LIBS, main()) → syncs + loads LIBS → loads resume.ks → manual override window → auto-resume or manual

### CORE:TAG routing (multi-CPU ships)
If `CORE:TAG` is non-empty, boot resolves the tag via `_resolveScript()` checking `roles/` then `craft/` then root. Each processor has its own `1:/` volume so state is naturally isolated. Untagged CPUs always load the vehicle script from `craft/`.

### Pre-launch config screen
On first boot (or when phase is LAUNCH), FR2 shows a flight plan summary listing all CFG values grouped by mission phase (ascent, transfer, orbit, probe). A 30s countdown with progress bar auto-launches; press ENTER to skip. Edit CFG values in the kOS terminal during the countdown to override defaults.

### Storage model
- `0:/` = archive (unlimited, only accessible near KSC)
- `1:/` = local volume on the processor (limited — OCTO has 10,000 bytes)
- Files must be copied from archive to local before use in flight

### LIBS convention
Each vehicle script declares `GLOBAL LIBS IS LIST(...)` — the list of lib names (without path/extension) that the vehicle needs. Boot syncs and loads only these libs, keeping storage usage minimal.

### State persistence
JSON file at `1:/state/state.json` via `lib/state.ks`. Survives reboots. Use `stateGet(key, default)` / `stateSet(key, value)`.

### Phase machine (`lib/phases.ks`)
- `runPhases(phaseMap)` — main loop. Takes a LEXICON mapping phase names to delegates. Reads current phase from state, calls the matching delegate, loops until DONE.
- `nextPhase(seq)` — advance to next phase in a given sequence LIST. Persists to state.
- `phaseDone()` — generic mission-complete cleanup.

Vehicle scripts build their own sequence LIST and phase LEXICON, then call `runPhases()`.

## Code conventions

- 4-space indentation, no tabs
- File headers: `// ============` block with filename, description, path
- No inline comments — keep files lean for storage constraints
- Private functions: `LOCAL FUNCTION _name { }` (underscore prefix)
- Public functions: `GLOBAL FUNCTION name { }` (camelCase)
- Config: `GLOBAL CFG IS LEXICON(...)` at top of vehicle scripts
- Logging: `mLog()`, `mLogWarn()`, `mLogError()`, `mLogPhase()`
- State: `stateGet()` / `stateSet()` — never raw file I/O for mission state
- Parts found by tag name (set in VAB), not by index

## File roles

- `boot/` — bootstrap only, keep minimal for easy reloading
- `lib/` — reusable libraries, loaded via `RUNPATH()`
- `cmd/` — operator commands, run manually from terminal (NOT synced at boot)
- `craft/` — vehicle flight computers (FR2.ks, FR3.ks, FJ1A.ks, FJ4B.ks, FSP1.ks, X_SHOT.ks)
- `roles/` — role scripts for CORE:TAG routing and EVA (lander_cpu.ks, EVA.ks)

### Key libs

| Lib | Purpose |
|---|---|
| `phases.ks` | Generic phase machine (runPhases, nextPhase, phaseDone) |
| `launch.ks` | Reusable ascent phases (launch, fairing, extend, parking) |
| `xfer.ks` | Transfer/arrival phases (transfer, coast, capture, circ, raise, incl) |
| `state.ks` | Persistent JSON key-value store |
| `logs.ks` | Flight logging with fault persistence |
| `files.ks` | Storage status and directory listing |
| `resume.ks` | MISSION lexicon, operator helpers, resumeMission() |
| `maneuver.ks` | Maneuver node execution with dynamic throttle |
| `inclination.ks` | Orbital plane change planning + etaToTrueAnomaly() |
| `molniya.ks` | Molniya (highly elliptical) orbit insertion |
| `orbit.ks` | Orbit monitoring and stability checks |
| `countdown.ks` | Launch countdown with audio |
| `targeting.ks` | Precision deorbit via Trajectories addon |
| `science.ks` | Experiment automation and SCANsat integration |
| `landing.ks` | Powered descent / suicide burn |
| `relay_constellation.ks` | Multi-relay deployment |
| `plane.ks` | Aircraft autopilot |
| `rover.ks` | Ground vehicle control |
| `utils.ks` | General-purpose utilities (fmtDuration, printOrbitRef) |

## Key constraints

- **Storage is scarce.** OCTO probes have 10,000 bytes; the primary FR2 probe core has ~100KB and runs near capacity. Minimize comments, avoid unnecessary whitespace. Use LIBS to load only what you need.
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

A git pre-commit hook enforces formatting on `.ks` files:
- No trailing whitespace
- Files end with exactly one newline
- No tab characters (4-space indent)

Run `./scripts/install-hooks.sh` to install.
