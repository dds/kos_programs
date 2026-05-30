# kos_programs

KerbalScript (kOS) mission automation framework for Kerbal Space Program.

## Overview

An autonomous flight computer system for Kerbal craft control. Handles full mission profiles from launch through orbital insertion, payload deployment, and station-keeping.

## Structure

```
boot/
    boot.ks              Bootstrap — parses ship name, resolves craft/roles
craft/
    FR2.ks               FR2 multi-payload launcher
    FR3.ks               FR3 next-gen rocket (leaner FR2)
    FJ1A.ks              Juno trainer jet
    FJ4B.ks              Supersonic jet with autopilot assists
    FSP1.ks              Seaplane/submersible
    X_SHOT.ks            SHRIMP sounding rocket
roles/
    lander_cpu.ks        Secondary CPU: deploy + science
    EVA.ks               EVA kerbal controller (trait-based roles)
lib/
    phases.ks            Generic phase machine (runPhases, nextPhase)
    launch.ks            Reusable ascent phases (launch, fairing, parking)
    xfer.ks              Transfer/arrival phases (transfer, coast, capture, circ)
    state.ks             Persistent JSON key-value store (survives reboots)
    logs.ks              Flight logging with fault persistence
    files.ks             Storage status and directory listing
    resume.ks            MISSION lexicon, auto-resume logic, operator helpers
    maneuver.ks          Maneuver node execution with dynamic throttle
    inclination.ks       Orbital plane change planning
    molniya.ks           Molniya orbit insertion
    orbit.ks             Orbit monitoring and stability checks
    countdown.ks         Launch countdown with audio
    science.ks           Experiment automation and SCANsat integration
    targeting.ks         Precision deorbit via Trajectories addon
    landing.ks           Powered descent / suicide burn
    relay_constellation.ks  Multi-relay deployment
    plane.ks             Aircraft autopilot (roll/alt/heading hold)
    rover.ks             Ground vehicle control
cmd/
    resume.ks            Resume mission from saved phase
    setstate.ks          Force a phase change
    dump.ks              Print state to console
    resetboot.ks         Reset boot counter
    files.ks             Print storage/file listing
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
- `FR2-KERBIN-RELAY-MOLNIYA-03` — Kerbin Molniya relay (63.4° incl, ~3h period, northern dwell)

**Payload types:** `RELAY`, `CRASHPROBE`/`PROBE`, `SCANSAT`, `SCISAT`, `STKSAT` (stub), `LANDER`, `MOLNIYA`

**Phase sequence:** LAUNCH -> FAIRING -> EXTEND_ANTS -> PARKING -> TRANSFER -> COAST -> CAPTURE -> [probe phases] -> CIRC -> RAISE_ALT -> INCL_CORRECT -> [relay/sat ops] -> [LAND_DEORBIT -> LAND] -> DONE

**Molniya sequence:** ...same... -> CIRC -> INCL_CORRECT -> MOLNIYA_INSERT -> [relay/sat ops] -> DONE (inclination correction before insertion since plane changes are cheaper in circular orbits)

FR2.ks declares `GLOBAL LIBS IS LIST(...)` to tell boot which libs to load. New vehicles do the same — boot only syncs what the vehicle needs.

### FR3

Next-gen rocket. Leaner than FR2 — no probe/molniya phases. Standard ascent + transfer + orbit phases with stubs for lander payloads.

**Payload types:** `RELAY`, `SCANSAT`, `SCISAT`, `LANDER`

### FJ1A

Juno-powered trainer jet. Low speed (cruise ~80 m/s), broad wings. Same phase structure as FJ4B but with lower airspeed thresholds appropriate for the Juno engine. Supports optional SCIENCE payload for biome collection flights.

### FJ4B

Supersonic jet with autopilot assists. Manually-flown with `plane.ks` integration. Phases: PREFLIGHT → FLIGHT → POST_FLIGHT. Auto-collects science on biome changes when SCIENCE payload is present.

### FSP1

Seaplane/submersible. Similar to FJ4B with water landing support. Phases: PREFLIGHT → FLIGHT → SPLASHDOWN → SURFACE_OPS. Dive operations stub (future `marine.ks`).

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
2. Name the vessel following the `VEHICLE-TARGET-TYPE...` convention
3. Boot syncs core libs, loads vehicle script, syncs vehicle's LIBS
4. Press any key within 5s of boot to enter manual mode, or wait to auto-resume
5. On first boot, FR2 shows a flight plan summary with all config values and a 30s countdown — press ENTER to launch immediately or wait for auto-launch

### Manual mode commands

All commands are run via `RUNPATH(...)` in the kOS terminal:

```
RUNPATH("1:/cmd/resume.ks").              // resume from saved phase
RUNPATH("1:/cmd/setstate.ks", "PHASE").   // force a phase
RUNPATH("1:/cmd/dump.ks").                // print state to console
RUNPATH("1:/cmd/resetboot.ks").           // reset boot counter
RUNPATH("1:/cmd/files.ks").               // storage/file listing
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

**Example:** Ship named `FR2-MUN-LANDER` with two processors:
- Main CPU (untagged) → boots `FR2.ks` (flight control)
- Secondary CPU (tagged `lander_cpu`) → boots `lander_cpu.ks` (deploy + science)

Each processor has its own `1:/` volume, so state files are naturally isolated — no conflicts between CPUs.

### Available role scripts

| Script | Tag | Purpose |
|---|---|---|
| `roles/lander_cpu.ks` | `lander_cpu` | Post-landing deploy (antennas, solar) + science collection |
| `roles/EVA.ks` | `EVA` | Trait-based EVA kerbal controller (scientist/engineer/generic) |

### EVA

Set boot file to `boot/boot.ks` on a kOS-EVA processor. Boot auto-detects EVA kerbals by checking if the root part is `kerbalEVA` — no special naming or CORE:TAG needed. It sets vehicle=EVA and target=current body, then resolves `roles/EVA.ks`. The EVA script auto-detects the kerbal's trait (Scientist, Engineer, Pilot) to run role-specific logic. Scientists auto-collect and transmit science; engineers and generics get interactive stubs.

### Writing a role script

Role scripts live in `roles/` and follow the same contract as vehicle scripts — define `CFG`, `LIBS`, and `main()`. They have access to `SHIP:NAME` parsing results via state (`vehicle`, `target`, `payloads`) set by boot on first boot of any CPU.

Keep role scripts lightweight (minimal LIBS) since secondary CPUs are often on storage-constrained probe cores.

## Creating a New Vehicle

Boot is generic — any vehicle works. Create `craft/MYVEHICLE.ks`, name your ship `MYVEHICLE-TARGET[-stuff]`, and boot handles the rest. Boot checks `craft/` first, then falls back to root for backwards compatibility.

A vehicle script must define three things:

```
GLOBAL CFG IS LEXICON(...).          // vehicle config values
GLOBAL LIBS IS LIST(...).            // which libs to load
GLOBAL FUNCTION main { ... }         // entry point
```

Inside `main()`, build a phase sequence LIST, a phase map LEXICON mapping names to function delegates, and call `runPhases(phaseMap)`. Each phase function calls `nextPhase(seq)` when done.

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

**From `molniya.ks`** (needs: `maneuver`, `orbit`, `inclination`):
- `phaseMolniyaInsert@` — prograde burn to achieve target period/AoP from circular orbit. Reads `CFG["MOLNIYA_PERIOD"]` and `CFG["MOLNIYA_AOP"]`

Calls `nextPhase(xferSeq)`.

**From `phases.ks`**:
- `phaseDone@` — unlock controls, SAS on, log complete

### Available lib functions

These are building blocks you can call inside your own phase functions:

| Function | Lib | What it does |
|---|---|---|
| `landingExecute()` | landing | Full powered descent sequence |
| `targetedDeorbit()` | targeting | Precision deorbit using Trajectories |
| `planMolniyaInsert(period, aop)` | molniya | Plan Molniya insertion burn from circular orbit |
| `planCircularize()` | maneuver | Add circ node at next Ap/Pe |
| `planLowerPe(alt)` | maneuver | Add node to lower Pe |
| `planRaisePeNow(alt)` | maneuver | Emergency Pe raise at current position |
| `executeManeuver()` | maneuver | Execute next node, returns TRUE/FALSE |
| `orbitSummary()` | orbit | Log current orbit parameters |
| `scienceRunAll()` | science | Run all experiments |
| `scienceTransmitAll()` | science | Transmit all science data |
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

GLOBAL LIBS IS LIST(
    "phases", "launch", "xfer",
    "countdown", "maneuver", "orbit",
    "inclination", "landing"
).

GLOBAL FUNCTION main {
    LOCAL seq IS LIST(
        "LAUNCH", "FAIRING", "EXTEND_ANTS", "PARKING",
        "TRANSFER", "COAST", "CAPTURE", "CIRC",
        "LAND", "SCIENCE", "DONE"
    ).
    SET launchSeq TO seq.
    SET xferSeq TO seq.
    IF stateGet("phase","") = "" { stateSet("phase", seq[0]). }

    LOCAL phaseMap IS LEXICON(
        "LAUNCH",      phaseLaunch@,
        "FAIRING",     phaseFairing@,
        "EXTEND_ANTS", phaseExtendAnts@,
        "PARKING",     phaseParking@,
        "TRANSFER",    phaseTransfer@,
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

GLOBAL LIBS IS LIST(
    "phases", "orbit", "rover", "science"
).

GLOBAL FUNCTION main {
    LOCAL seq IS LIST("DRIVE", "DONE").
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

GLOBAL LIBS IS LIST(
    "phases", "xfer",
    "maneuver", "orbit", "inclination"
).

GLOBAL FUNCTION main {
    LOCAL seq IS LIST(
        "TRANSFER", "COAST", "CAPTURE",
        "CIRC", "RAISE_ALT", "INCL_CORRECT",
        "STATION", "DONE"
    ).
    SET xferSeq TO seq.
    SET launchSeq TO seq.
    IF stateGet("phase","") = "" { stateSet("phase", seq[0]). }

    LOCAL phaseMap IS LEXICON(
        "TRANSFER",    phaseTransfer@,
        "COAST",       phaseCoast@,
        "CAPTURE",     phaseCapture@,
        "CIRC",        phaseCirc@,
        "RAISE_ALT",   phaseRaiseAlt@,
        "INCL_CORRECT", phaseInclCorrect@,
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

- **Storage-constrained probes**: Only list the libs you need. A rover with just `phases`, `rover`, `science` uses far less than the full FR2 stack.
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
| `chute_main` | Abort parachute |
| `relay_1`, `relay_2`, ... | Individual relay decouplers |
