# kos_programs

KerbalScript (kOS) mission automation framework for Kerbal Space Program.

## Overview

An autonomous flight computer system for spacecraft control, built around the **FR2** multi-payload launch vehicle. Handles full mission profiles from launch through orbital insertion, payload deployment, and station-keeping.

## Structure

```
boot/
    boot.ks              Bootstrap — parses ship name, demand-loads libs
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
FR2.ks                   FR2 vehicle flight computer
X_SHOT.ks                SHRIMP booster script
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

**Payload types:** `RELAY`, `CRASHPROBE`/`PROBE`, `SCANSAT`, `SCISAT`, `STKSAT` (stub)

**Phase sequence:** LAUNCH -> FAIRING -> EXTEND_ANTS -> PARKING -> TRANSFER -> COAST -> CAPTURE -> [payload phases] -> CIRC -> RAISE_ALT -> INCL_CORRECT -> [ops phases] -> DONE

FR2.ks declares `GLOBAL LIBS IS LIST(...)` to tell boot which libs to load. New vehicles do the same — boot only syncs what the vehicle needs.

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

```
resumeMission().           // resume from saved phase
setState("PHASE_NAME").    // force a phase
resetBootCount().          // reset boot counter
patchAndRun("0:/path").    // hot-patch a file from archive
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

## Tagged Parts (VAB)

The flight computer finds parts by tag name, not by index:

| Tag | Purpose |
|---|---|
| `main_fairing` | Procedural fairing to jettison |
| `probe_decoupler` | Decoupler between relay and impactor |
| `probe_chute` | Parachute on probe payload |
| `chute_main` | Abort parachute |
| `relay_1`, `relay_2`, ... | Individual relay decouplers |
