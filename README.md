# kos_programs

KerbalScript (kOS) mission automation framework for Kerbal Space Program.

## Overview

An autonomous flight computer system for Kerbal craft control. Handles full mission profiles from launch through orbital insertion, interplanetary transfer, payload deployment, and station-keeping. Ships can carry multiple kOS processors, each running a different role — a primary mission computer, a lander CPU, a zombie watchdog — all booting from the same `boot.ks` and routing by `CORE:TAG`.

## Structure

```
boot/
    boot.ks              Small VAB-installed loader
craft/
    FR2.ks               FR2 multi-payload launcher
    FR3.ks               FR3 next-gen rocket (leaner FR2)
    FJ1A.ks              Juno trainer jet
    FJ4B.ks              Supersonic jet with autopilot assists
    FSP1.ks              Seaplane/submersible
    X_SHOT.ks            SHRIMP sounding rocket
roles/
    lander_cpu.ks        Secondary CPU: deploy + science
    zombie.ks            Dormant watchdog — reboots other CPUs on command
    EVA.ks               EVA kerbal controller (trait-based roles)
missions/
    FR2/*.cfg            Data-only mission profiles for FR2
    FR3/*.cfg            Data-only mission profiles selectable by plain FR3
lib/
    boot_core.ks         Boot helpers: mission selection, pruning, resume
    phases.ks            Generic phase machine (runPhases, nextPhase)
    launch.ks            Reusable ascent phases (launch, fairing, parking)
    xfer.ks              Transfer/arrival phases (transfer, coast, capture, circ)
    state.ks             Persistent JSON key-value store (survives reboots)
    logs.ks              Flight logging with fault persistence
    files.ks             Storage status and directory listing
    mission_plan.ks      Mission SEQUENCE parsing and phase-to-library planning
    resume.ks            MISSION lexicon, auto-resume logic, operator helpers
    maneuver.ks          Maneuver execution + transfer/capture/circ planning
    maneuver_targeting.ks  Shared targeting helpers for transfer/MCC planners
    inclination.ks       Orbital plane change planning
    molniya.ks           Molniya orbit insertion
    orbit.ks             Orbit monitoring and stability checks
    countdown.ks         Launch countdown with audio
    payload_ops.ks       Shared payload phase implementations (deploy, deorbit, relay)
    payload_landing.ks   Minimal landing/rover payload phase wrappers
    science.ks           Experiment automation and SCANsat integration
    deorbit_targeting.ks Precision deorbit via Trajectories addon
    landing.ks           Powered descent / suicide burn
    recovery.ks          Post-abort recovery (antenna deploy, log archive)
    relay_constellation.ks  Multi-relay deployment
    plane.ks             Aircraft autopilot (roll/alt/heading hold)
    rover.ks             Ground vehicle control
    observe.ks           Periodic telemetry logger with sentinel-file control
    utils.ks             General-purpose utilities (fmtDuration, printOrbitRef)
    lib_navigation.ks    KSLib — phase angle, AN/DN calculations
    lib_circle_nav.ks    KSLib — great circle navigation
    lib_enum.ks          KSLib — list/queue/stack functional helpers
cmd/
    resume.ks            Resume mission from saved phase
    setphase.ks          Force phase, optionally changing mission profile
    dump.ks              Print state to console
    resetboot.ks         Reset boot counter
    files.ks             Print storage/file listing
    logs.ks              Archive flight log to KSC
    zombie.ks            Reboot all other CPUs on the vessel
    molniya.ks           Molniya orbit calculator (interactive)
    science.ks           Manual science collection
    sciencestatus.ks     Science status report
    scanstart.ks         Start SCANsat scanners
    scanstatus.ks        SCANsat coverage report
    scantransmit.ks      Transmit SCANsat data
```

## Vehicles

### FR2

Multi-payload launch vehicle. Ship name encodes the mission profile:

```
FR2-TARGET-TYPE1-TYPE2-...
```

Examples:
- `FR2-MUN-CRASHPROBE1-RELAY1` — Mun mission: deploy crash probe, then relay
- `FR2-MINMUS-RELAY1` — Minmus relay deployment
- `FR2-KERBIN-RELAY-MOLNIYA-03` — Kerbin Molniya relay (63.4 incl, ~3h period, northern dwell)

**Payload types:** `RELAY`, `CRASHPROBE`/`PROBE`, `SCANSAT`, `SCISAT`, `STKSAT` (stub), `LANDER`, `MOLNIYA`

**Phase sequence:** LUNCH -> FAIR -> ANTS -> PARK -> XING -> MCC -> COAST -> CAPTURE -> [probe phases] -> CIRC -> RAISE -> INCLINE -> [relay/sat ops] -> [LAND_DEORBIT -> LAND] -> DONE

**Molniya sequence:** ...same... -> CIRC -> MOLNIYA_INSERT -> INCLINE -> [relay/sat ops] -> DONE

FR2 keeps a full `LIBS` fallback for legacy name-driven flights. Profile-driven FR2 missions should set `SEQUENCE = ...` in `missions/FR2/*.cfg`, so the selected mission decides the phase order and boot derives the libraries to sync.

### FR3

Next-gen rocket. Standard ascent + transfer + orbit phases, plus combined mapper/rover Mun missions. FR3 can still read target/payload tokens from a ship name such as `FR3-MUN-ASSISTROVER-01`, but the preferred path is a plain `FR3` craft with a mission profile selected on the pad.

**Payload types:** `RELAY`, `SCANSAT`, `SCISAT`, `LANDER`, `ASSISTLANDER`, `ROVER`, `ASSISTROVER`, `PROBE`, `CRASHPROBE`

For a Mun mapper + rover run, put `SCANSAT` before the landing payload in the ship name. Example: `FR3-MUN-SCANSAT-ASSISTROVER-01`. This deploys the SCANsat in a 250 km polar orbit, then continues to targeted rover landing using explicit landing coordinates, a named waypoint, or the selected map waypoint.

Mission profiles live under `missions/FR3/` and use simple `KEY = VALUE` lines:

```
MISSION_ID = mun_rover
MISSION_NAME = Mun Rover Lander
TARGET = MUN
PAYLOADS = ASSISTROVER
SEQUENCE = LUNCH,FAIR,ANTS,PARK,XING,MCC,COAST,CAPTURE,CIRC,RAISE,INCLINE,LAND_DEORBIT,LAND_ASSIST,LAND,ROVER,DONE
CAPTURE_PE = 15000
CAPTURE_INC = 90
LANDING_ASSIST_DECOUPLER_TAG = probe_decoupler
LANDING_ASSIST_MAX_TILT = 15
```

Keep mission profiles in this key/value format for the current boot flow. `lib/state.ks` uses the simplejson addon for persistent state, but mission profile parsing happens through the boot path before the vehicle script is running. Most of that boot logic now lives in compiled `lib/boot_core.ks`; switching profiles to JSON would still require a VAB-side boot compatibility check before flight.

Mission profiles own the phase sequence. A profile says what mission steps happen and in what order; the craft script maps those phase names to hardware-specific implementations. This lets a mission such as `mun_scansat_polar` use the same high-level steps for FR2 and FR3 while each craft executes staging, fairings, payload release, and recovery with its own code.

Boot derives the required libraries from `SEQUENCE` for simple craft. Profiles can still override or extend boot-time library choices when needed:

```
SEQUENCE = LUNCH,FAIR,ANTS,PARK,XING,MCC,COAST,CAPTURE,SCANSAT_IMPACT_RELEASE,SCANSAT_OPS,DONE
LIBS = phases,flightplan,launch,xfer,maneuver,orbit,payload_ops,science
LIBS_EXTRA = observe
```

`LIBS` is an escape hatch that replaces the craft fallback or sequence-derived library list for simple craft such as FR2. `LIBS_EXTRA` appends mission-specific libraries to the computed list. FR3 uses a more advanced banded loader instead of a single static `LIBS` line; its selected profile still controls the loaded code through payloads, `SEQUENCE`, phase state, reload flags, and optional `LIBS_EXTRA`.

On boot, `lib/boot_core.ks` reads mission profiles from `0:/missions/<craft>` when a KSC link is available, falling back to cached `1:/missions/<craft>` files only when offline. After a profile is selected, the key/value config is persisted into state and stale local mission config files are pruned so they do not occupy flight-computer storage.

Vessel names can be friendly. Dash-separated names such as `FR3-MUN-SCANSAT-01` still provide legacy `vehicle-target-payload` hints. Space-separated names such as `FR3 Mun Mini SCANSat 1` are treated as display names: boot uses the first word as the craft script (`FR3`) and lets the selected mission profile provide target/payload details. Boot stores the display name in `state["vessel_name"]` and prefers persisted `vehicle`, `target`, and `payloads` after launch so later vessel renames do not break in-flight reboots.

While the vessel is still prelaunch, `lib/boot_core.ks` clears any saved mission profile and profile config before selecting a mission. This lets you reboot on the pad after choosing the wrong profile and get the mission picker again. Once launched, in-flight reboots keep the saved mission and phase state.

FR3 uses progressive reload points to stay under kOS storage limits. Launch loads only launch/countdown/orbit plus landing support when needed; after parking it advances to the next phase and halts so a reboot can load transfer libraries without `launch.ks`. Rover landing missions then reload again after assist-stage release for full `landing.ks`, and after touchdown for `rover.ks`. Boot prunes stale files from `1:/lib` before syncing each band.

`craft/FR3.ks` is intentionally kept small enough to fit comfortably on the primary kOS volume. Boot compiles the selected craft script to `1:/craft/*.ksm` and deletes the local source copy when connected. Mission profile tweaks, sequence construction, phase mapping, payload classification, and launch confirmation display live in small `lib/fr3_*.ks` modules. These are loaded through the FR3 library bands and can be compiled like the rest of the libraries.

Important in-flight constraint: `boot/boot.ks` itself is installed on the kOS processor in the VAB/SPH and cannot be updated remotely during a mission. Remote reboots can load updated mission configs, craft scripts, commands, and libraries from the archive, including `lib/boot_core.ks` and `lib/mission_plan.ks` after the installed boot has synced them once. Any fix that changes the installed boot stub must be applied before launch or by another VAB-side update path.

The current band and pending reload are saved in mission state (`lib_band`, `lib_band_libs`, `reload_required`, `reload_reason`, `reload_next_phase`, `reload_next_band`) so a reboot or state dump shows why the computer is waiting.

The archive-root `VERSION` file contains the code tag printed by `logs.ks` at boot as `CODE version=...`. Boot copies it into `1:/state/code_version.state` when connected, so archived logs can be matched back to a Git tag even after later code changes. Use `make release-version TAG=kos-YYYYMMDD-N` to stamp `VERSION`, commit it, create the matching Git tag, and push branch plus tag.

For live sim iteration, use `make watch-sync` instead of a raw `while true; do git pull origin main; sleep 2; done` loop. The helper fetches first, fast-forwards only when safe, skips updates when the worktree is dirty, and uses a lock so overlapping sync ticks do not race with each other.

Phase transitions archive the current flight log when a KSC link is available. Archive is append-and-rotate: new local log lines are appended to the remote archive, then the local log spool is truncated to a short marker so storage is recovered during flight. If no link is available, the transition still proceeds and the log is archived later by boot/recovery or an operator `RUNPATH("1:/cmd/logs.ks").`

Successful maneuver planners also archive the current flight log when a KSC link is available, immediately after the final planned-node summary and before execution/coast. WARN-level `STATS` lines summarize phase entry orbit state, maneuver setup/alignment/result, transfer/MCC solver results, capture/circularization/raise/inclination cleanup, landing deorbit, assist descent handoff, powered landing, rendezvous, and asteroid-intercept plan details. Each `STATS` line also triggers an immediate archive when connected, so the archive captures breadcrumbs even if the next phase fails.

Emergency rover surface-release mode is available via `missions/FR3/mun_rover_emergency_surface.cfg`. It changes the sequence to skip the separate rover powered landing phase: the second stage lands the whole stack, releases the rover on the surface, then reboots into rover recovery. On an active mission, set `stateSet("mission_id", "mun_rover_emergency_surface").` and reboot so boot reloads the emergency config.

FR3 no longer carries default placeholder surface coordinates. Targeted deorbit and landing use a named mission waypoint first, then the currently selected map waypoint, then explicit numeric lat/lng only when a mission profile or saved state provides them.

Mun rover landing profiles use an extended targeted-deorbit scan window and set `TARGET_DEORBIT_PROCEED_ON_MISS = 0`, so a landing run stops and logs the miss instead of committing to a wrong deorbit burn.

When `LANDING_SITE_SCAN_ENABLE = 1`, targeted deorbit samples SCANsat `ELEVATION` and `SLOPE` around the selected/named waypoint, then retargets Trajectories to the lowest-score nearby site with known altimetry and acceptable slope. If SCANsat is unavailable or no scanned candidate passes the slope limit, it keeps the original waypoint and logs `STATS site-scan`.

For a fast-follow Mun mapper, use `mission_id = mun_scansat_polar` on either FR2 or FR3. The matching profile under `missions/FR2/` or `missions/FR3/` targets a 70 km polar Mun orbit and deploys the payload tagged `scansat_decoupler`.

The Mun mapper profiles use an attached-stack disposal flow: the carrier locks retrograde and burns to a low/impact periapsis before SCANsat release, then the mapper stages and recovers itself to mapping orbit. SCANsat recovery nodes are capped by `SCANSAT_MAX_NODE_DV` so a bad planner result is rejected instead of executing an absurd burn.

### FJ1A

Juno-powered trainer jet. Low speed (cruise ~80 m/s), broad wings. Same phase structure as FJ4B but with lower airspeed thresholds appropriate for the Juno engine. Supports optional SCIENCE payload for biome collection flights.

### FJ4B

Supersonic jet with autopilot assists. Manually-flown with `plane.ks` integration. Phases: PREFLIGHT -> FLIGHT -> POST_FLIGHT. Auto-collects science on biome changes when SCIENCE payload is present.

### FSP1

Seaplane/submersible. Similar to FJ4B with water landing support. Phases: PREFLIGHT -> FLIGHT -> SPLASHDOWN -> SURFACE_OPS. Dive operations stub (future `marine.ks`).

### X_SHOT (SHRIMP)

Simple sounding rocket script. Launches, hibernates probe core, collects thermometer and barometer data on descent and landing.

## Dependencies

- **kOS** — Kerbal Operating System mod
- **MechJeb** — Ascent guidance (launch phase)
- **Trajectories** — Impact prediction (probe targeting)
- **SCANsat** — Orbital scanning (optional)
- **KerbalEngineer** — Burn time calculations
- **simplejson** — JSON serialization for state persistence

## Usage

1. Set boot file to `boot/boot.ks` on the kOS processor
2. Name the vessel with either `VEHICLE-TARGET-TYPE...` or a friendly name beginning with the vehicle id
3. Boot selects a mission profile when available, loads the craft/role script, then syncs the mission-selected or craft-computed `LIBS`
4. Press any key within 5s of boot to enter manual mode, or wait to auto-resume
5. On first boot, FR2 shows a flight plan summary with all config values and a 30s countdown — press ENTER to launch immediately or wait for auto-launch

### Action groups

Action group 0 toggles power on the kOS processor and opens/closes its terminal. In KSP, pressing `0` a few times will power-cycle the CPU, interrupting whatever it's doing and forcing a reboot. This is the primary way to break into a running mission and get a console — the kOS terminal opens on reboot, and boot's 5-second manual mode window gives you a chance to intervene before auto-resume kicks in.

### Manual mode commands

All commands are run via `RUNPATH(...)` in the kOS terminal:

```
RUNPATH("1:/cmd/resume.ks").              // resume from saved phase
RUNPATH("1:/cmd/setphase.ks", "PHASE").   // force phase, keep saved mission
RUNPATH("1:/cmd/dump.ks").                // print state to console
RUNPATH("1:/cmd/resetmission.ks").        // clear selected mission profile
RUNPATH("1:/cmd/resetboot.ks").           // reset boot counter
RUNPATH("1:/cmd/files.ks").               // storage/file listing
RUNPATH("1:/cmd/logs.ks").                // archive flight log to KSC
RUNPATH("1:/cmd/zombie.ks").              // reboot all other CPUs
RUNPATH("1:/cmd/molniya.ks").             // Molniya orbit calculator
```

After launch, to force a specific mission profile on the next reboot:

```
RUNPATH("1:/cmd/resetmission.ks", "mun_scansat_polar").
```

### Hot-reloading a lib

```
COPYPATH("0:/lib/maneuver.ks", "1:/lib/maneuver.ks").
RUNPATH("1:/lib/maneuver.ks").
```

### Pulling a cmd script mid-flight

```
COPYPATH("0:/cmd/dump.ks", "1:/cmd/dump.ks").
RUNPATH("1:/cmd/dump.ks").
```

## Multi-CPU Ships (CORE:TAG Routing)

Ships with multiple kOS processors use **CORE:TAG** to route each CPU to a different script. All processors share the same `boot/boot.ks`, but tagged CPUs load a role-specific script instead of the vehicle script.

**How it works:**
1. Boot parses the ship name as usual (vehicle, target, payloads)
2. If `CORE:TAG` is non-empty, boot resolves the tag by checking `roles/`, then `craft/`, then root
3. If the tag has no matching script, the CPU falls through to the normal vehicle script (with a warning)
4. Untagged CPUs always load the vehicle script from `craft/`

Each processor has its own `1:/` volume, so state files are naturally isolated — no conflicts between CPUs.

### Typical multi-CPU layout

A typical interplanetary mission (Mun, Minmus, Duna, or remote Kerbin) uses three CPUs:

| CPU | CORE:TAG | Script | Role |
|---|---|---|---|
| Primary (main probe core) | *(empty)* | `craft/FR2.ks` | Mission computer — ascent, transfer, capture, orbit ops |
| Lander (OCTO on lander) | `lander_cpu` | `roles/lander_cpu.ks` | Post-separation deploy + science collection |
| Zombie (OCTO on upper stage) | `zombie` | `roles/zombie.ks` | Dormant watchdog — remote reboot capability |

### Available role scripts

| Script | Tag | Purpose |
|---|---|---|
| `roles/lander_cpu.ks` | `lander_cpu` | Post-landing deploy (antennas, solar) + science collection |
| `roles/zombie.ks` | `zombie` | Dormant watchdog — closes terminal and waits for operator |
| `roles/EVA.ks` | `EVA` | Trait-based EVA kerbal controller (scientist/engineer/generic) |

### Zombie: remote reboot

The zombie is a secondary kOS CPU (usually a tiny OCTO probe core on the upper stage or service module) that boots, closes its own terminal, and goes silent. Its purpose: if the primary mission computer gets stuck — infinite loop, bad state, unresponsive — the operator can regain control remotely.

**To use the zombie:**
1. In KSP, right-click the zombie's probe core and open its kOS terminal
2. The zombie's boot.ks has already loaded; it printed a hint and went idle
3. Run: `RUNPATH("1:/cmd/zombie.ks").`
4. This power-cycles every *other* kOS CPU on the vessel, forcing them to reboot
5. The primary mission computer reboots fresh, hits the 5s manual mode window, and the operator can intervene

The zombie itself is unaffected by the reboot command since `cmd/zombie.ks` skips the CPU that's running it. This gives you a reliable backdoor to recover a stuck mission computer without needing physical access (action groups, EVA, etc.).

The `cmd/zombie.ks` script can also be run from any CPU's terminal — it's not exclusive to the zombie role. The role just ensures there's always a clean, idle CPU available to run it from.

### EVA

Set boot file to `boot/boot.ks` on a kOS-EVA processor. Boot auto-detects EVA kerbals by checking if the root part is `kerbalEVA` — no special naming or CORE:TAG needed. It sets vehicle=EVA and target=current body, then resolves `roles/EVA.ks`. The EVA script auto-detects the kerbal's trait (Scientist, Engineer, Pilot) to run role-specific logic. Scientists auto-collect and transmit science; engineers and generics get interactive stubs.

### Writing a role script

Role scripts live in `roles/` and follow the same contract as vehicle scripts — define `CFG`, `LIBS`, and `main()`. They have access to `SHIP:NAME` parsing results via state (`vehicle`, `target`, `payloads`) set by boot on first boot of any CPU.

Keep role scripts lightweight (minimal LIBS) since secondary CPUs are often on storage-constrained probe cores.

## Creating a New Vehicle

Boot is generic — any vehicle works. Create `craft/MYVEHICLE.ks`, then either name the ship `MYVEHICLE-TARGET[-stuff]` for legacy name hints or use a friendly name beginning with `MYVEHICLE` and select a mission profile. Boot checks `craft/` first, then falls back to root for backwards compatibility.

A vehicle script must define three things:

```
GLOBAL CFG IS LEXICON(...).                  // vehicle config defaults
GLOBAL LIBS IS missionSequenceLibs(...).      // sequence-derived libs plus fallback
GLOBAL FUNCTION main { ... }                 // entry point
```

For simple phase-driven craft, prefer a fallback sequence and `missionSequenceLibs(...)`. This keeps the craft usable with legacy vessel-name missions while allowing a selected profile `SEQUENCE` to drive library sync at boot:

```
LOCAL DEFAULT_SEQ IS LIST("PREFLIGHT", "FLIGHT", "POST_FLIGHT", "DONE").
GLOBAL LIBS IS missionSequenceLibs(
    missionLibsForPhases(DEFAULT_SEQ, LIST("orbit")),
    LIST("orbit")
).
```

Inside `main()`, resolve the active phase sequence from `CFG["SEQUENCE"]` when present, build a phase map LEXICON mapping names to function delegates, and call `runPhases(phaseMap)`. Each phase function calls `nextPhase(seq)` when done.

### Available lib phases

These are ready-made phases you can drop into your phase map:

**From `launch.ks`** (needs: `maneuver`, `countdown`, `orbit`):
- `phaseLaunch@` — MechJeb ascent, staging, abort monitoring
- `phaseFairing@` — jettison tagged `main_fairing` at `CFG["FAIRING_ALT"]`
- `phaseExtendAnts@` — deploy panels/antennas at `CFG["EXTEND_ALT"]`
- `phaseParking@` — wait for stable parking orbit

All call `nextPhase(launchSeq)` — set `launchSeq` to your sequence before calling `runPhases()`.

**From `xfer.ks`** (needs: `maneuver`, `orbit`, `inclination`):
- `phaseTransfer@` — plan + execute transfer burn to `missionTargetBody()`
- `phaseCoast@` — coast to target SOI
- `phaseCapture@` — capture burn, target Ap = `CFG["RELAY_ALT"]`
- `phaseCirc@` — circularize (handles impact threats)
- `phaseRaiseAlt@` — raise orbit to `CFG["RELAY_ALT"]` + circularize
- `phaseInclCorrect@` — plane change to `CFG["TARGET_INCLINATION"]`

All call `nextPhase(xferSeq)` — set `xferSeq` to your sequence.

**From `maneuver.ks`** (needs: `maneuver`, `maneuver_targeting`, `orbit`):
- `phaseMidCourse@` — mid-course correction using Newton's method. Corrects PE (prograde), AoP (radial), and LAN (normal) independently. Capped at 50 m/s total dV. Skips if encounter is already on target.

Calls `nextPhase(xferSeq)`.

**From `payload_ops.ks`** (needs: `deorbit_targeting`, `landing`, `orbit`, `science` as appropriate):
- `phaseTargetedDeorbit@` — precision deorbit for crash probes
- `phaseReleaseProbe@` — arm chutes, decouple, orient for solar panels
- `phaseRelayOps@` — relay on-station (orbit summary, periodic monitoring)
- `phaseLandDeorbit@` — lander deorbit burn
- `phaseLand@` — powered descent via `landingExecute()`

All call `nextPhase(launchSeq)`.

**From `molniya.ks`** (needs: `maneuver`, `orbit`, `inclination`):
- `phaseMolniyaInsert@` — prograde burn to achieve target period/AoP from circular orbit. Reads `CFG["MOLNIYA_PERIOD"]` and `CFG["MOLNIYA_AOP"]`

Calls `nextPhase(xferSeq)`.

**From `phases.ks`**:
- `phaseDone@` — unlock controls, SAS on, log complete

### Available lib functions

These are building blocks you can call inside your own phase functions:

| Function | Lib | What it does |
|---|---|---|
| `planTransfer(body, pe, lan, aop)` | maneuver | Plan transfer with optional LAN/AoP targeting |
| `planCapture(body, alt)` | maneuver | Plan capture burn at Pe |
| `planCircularize()` | maneuver | Add circ node at next Ap |
| `planRaisePeNow(alt)` | maneuver | Emergency Pe raise at current position |
| `planAoPChange(targetAoP)` | maneuver | Radial burn to rotate argument of periapsis |
| `executeManeuver()` | maneuver | Execute next node, returns TRUE/FALSE |
| `landingExecute()` | landing | Full powered descent sequence |
| `targetedDeorbit()` | deorbit_targeting | Precision deorbit using Trajectories |
| `planMolniyaInsert(period, aop)` | molniya | Plan Molniya insertion burn from circular orbit |
| `orbitSummary()` | orbit | Log current orbit parameters |
| `scienceRunAll()` | science | Run all experiments |
| `scienceTransmitAll()` | science | Transmit all science data |
| `recoveryMode()` | recovery | Post-abort recovery (antennas, log archive, operator prompt) |
| `roverInit()` | rover | Start rover steering loop |
| `roverSetWaypoint(lat,lng)` | rover | Drive to coordinates |
| `constellationDeploy(count,alt)` | relay_constellation | Deploy relay constellation |

### Example: Lander

Ship name: `LANDER-MUN`

```
// LANDER.ks — Mun/Minmus lander
GLOBAL CFG IS LEXICON(
    "PARKING_ALT",       80000,
    "FAIRING_ALT",       60000,
    "EXTEND_ALT",        65000,
    "CAPTURE_PE",        15000,
    "RELAY_ALT",         20000,
    "TARGET_INCLINATION", 0,
    "CIRC_ECC_TOL",      0.01,
    "LAUNCH_INCLINATION", 0,
    "LAUNCH_AZIMUTH",     0,
    "LAUNCH_STAGE_LIMIT", 0
).

LOCAL DEFAULT_SEQ IS LIST(
    "LUNCH", "FAIR", "ANTS", "PARK",
    "XING", "COAST", "CAPTURE", "CIRC",
    "LAND", "SCIENCE", "DONE"
).

GLOBAL LIBS IS missionSequenceLibs(
    missionLibsForPhases(DEFAULT_SEQ, LIST("science", "config")),
    LIST("science", "config")
).

GLOBAL FUNCTION main {
    LOCAL seq IS DEFAULT_SEQ.
    IF CFG:HASKEY("SEQUENCE") { SET seq TO phaseListFromString(CFG["SEQUENCE"]). }
    SET launchSeq TO seq.
    SET xferSeq TO seq.
    IF stateGet("phase","") = "" { stateSet("phase", seq[0]). }

    LOCAL phaseMap IS LEXICON(
        "LUNCH",       phaseLaunch@,
        "FAIR",        phaseFairing@,
        "ANTS",        phaseExtendAnts@,
        "PARK",        phaseParking@,
        "XING",        phaseTransfer@,
        "COAST",       phaseCoast@,
        "CAPTURE",     phaseCapture@,
        "CIRC",        phaseCirc@,
        "LAND",        _phaseLand@,
        "SCIENCE",     _phaseScience@
    ).
    runPhases(phaseMap).
}

LOCAL FUNCTION _phaseLand {
    landingExecute().
    nextPhase(launchSeq).
}

LOCAL FUNCTION _phaseScience {
    scienceRunAll().
    scienceTransmitAll().
    mLog("Science complete.").
    nextPhase(launchSeq).
}
```

### Example: Rover

Ship name: `ROVER-KERBIN` (already landed, no ascent phases)

```
// ROVER.ks — Surface rover
GLOBAL CFG IS LEXICON().

LOCAL DEFAULT_SEQ IS LIST("DRIVE", "DONE").
GLOBAL LIBS IS missionSequenceLibs(
    missionLibsForPhases(DEFAULT_SEQ, LIST("rover", "science", "orbit", "config")),
    LIST("rover", "science", "orbit", "config")
).

GLOBAL FUNCTION main {
    LOCAL seq IS DEFAULT_SEQ.
    IF CFG:HASKEY("SEQUENCE") { SET seq TO phaseListFromString(CFG["SEQUENCE"]). }
    SET launchSeq TO seq.
    IF stateGet("phase","") = "" { stateSet("phase", seq[0]). }

    LOCAL phaseMap IS LEXICON(
        "DRIVE", _phaseDrive@
    ).
    runPhases(phaseMap).
}

LOCAL FUNCTION _phaseDrive {
    roverInit().
    roverSetWaypoint(-0.0972, -74.5577).
    WAIT UNTIL roverStatus() = "ARRIVED".
    scienceRunAll().
    scienceTransmitAll().
    roverShutdown().
    nextPhase(launchSeq).
}
```

### Example: Moon Tug

Ship name: `TUG-MUN` (starts in orbit, no ascent phases)

```
// TUG.ks — Orbital tug / transfer stage
GLOBAL CFG IS LEXICON(
    "CAPTURE_PE",        20000,
    "RELAY_ALT",         50000,
    "TARGET_INCLINATION", 0,
    "CIRC_ECC_TOL",      0.005,
    "INCL_TOLERANCE",    0.01,
    "MAX_INCL_CHANGE_DV", 200
).

LOCAL DEFAULT_SEQ IS LIST(
    "XING", "COAST", "CAPTURE",
    "CIRC", "RAISE", "INCLINE",
    "STATION", "DONE"
).

GLOBAL LIBS IS missionSequenceLibs(
    missionLibsForPhases(DEFAULT_SEQ, LIST("config")),
    LIST("config")
).

GLOBAL FUNCTION main {
    LOCAL seq IS DEFAULT_SEQ.
    IF CFG:HASKEY("SEQUENCE") { SET seq TO phaseListFromString(CFG["SEQUENCE"]). }
    SET xferSeq TO seq.
    SET launchSeq TO seq.
    IF stateGet("phase","") = "" { stateSet("phase", seq[0]). }

    LOCAL phaseMap IS LEXICON(
        "XING",    phaseTransfer@,
        "COAST",       phaseCoast@,
        "CAPTURE",     phaseCapture@,
        "CIRC",        phaseCirc@,
        "RAISE",   phaseRaiseAlt@,
        "INCLINE", phaseInclCorrect@,
        "STATION",     _phaseStation@
    ).
    runPhases(phaseMap).
}

LOCAL FUNCTION _phaseStation {
    UNLOCK STEERING.
    SET SAS TO TRUE.
    orbitSummary().
    mLog("Tug on station. Awaiting commands.").
    nextPhase(launchSeq).
}
```

### Tips

- **Storage-constrained probes**: Put mission order in `SEQUENCE` and let boot derive the libs. A rover sequence with only rover/science phases uses far less than the full FR2 stack.
- **No ascent?** Skip `launch.ks` entirely. Start your sequence at `TRANSFER` or whatever your first phase is.
- **Custom phases**: Write `LOCAL FUNCTION _phaseName { ... nextPhase(launchSeq). }` and add to the map. Mix freely with lib phases.
- **Reboot safety**: The phase machine persists to state. On reboot, boot reloads everything and `main()` re-enters at the saved phase.
- **CFG keys**: Lib phases read from `CFG` — check which keys each lib phase expects (documented above). Only define the keys your phases actually use.

## Tagged Parts (VAB)

The flight computer finds parts by tag name, not by index:

| Tag | Purpose |
|---|---|
| `main_fairing` | Procedural fairing to jettison |
| `probe_decoupler` | Decoupler between relay and impactor |
| `probe_chute` | Parachute on probe payload |
| `scansat_decoupler` | Decoupler between carrier/lander and SCANsat mapper |
| `landing_assist_decoupler` | Decoupler between lander and expendable landing-assist stage |
| `chute_main` | Abort parachute |
| `relay_1`, `relay_2`, ... | Individual relay decouplers |
