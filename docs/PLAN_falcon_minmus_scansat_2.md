# Plan: Falcon-Minmus-SCANSat-2

Draft mission profile for launching one Falcon stack to Minmus with a
detachable radar-altimetry relay satellite and an integrated multispectral
scanner/relay bus. Sat 1 separates into a low inclined mapping orbit. Sat 2
keeps the transfer bus permanently attached and reshapes into a high polar
orbit for multispectral scanning and relay coverage.

This replaces the older dual-release/disposal concept. There is no transfer
stage disposal in this mission: the transfer stage is Sat 2.

## Mission Intent

- Launch a single Falcon stack to Minmus.
- Capture into a low, inclined Minmus orbit.
- Deploy Sat 1 into its 70 km radar-altimetry orbit.
- Raise the remaining bus/Sat 2 to a 300 km apoapsis.
- Perform the 75 deg to 90 deg plane change at the raised apoapsis while
  circularizing, minimizing plane-change dV.
- Leave Sat 2 in continuous SCANsat operations at 300 km polar.
- Use both relay antennas as a dynamic relay web; no precise LAN phasing is
  required because the 70 km and 300 km orbits naturally desync.

## Target Orbits

### Sat 1: Radar Altimeter and Relay

- Body: Minmus
- Separation: detachable
- Onboard dV after release: 299 m/s
- Orbit: circular inclined
- Pe/Ap: 70 km / 70 km
- Inc: 75 deg
- Scanner: radar altimetry
- Scanner altitude limits: ideal 70 km, max 250 km
- Role: low-altitude altimetry mapper and close relay asset
- Rationale: 70 km is the installed radar altimeter's ideal altitude. A 75 deg
  inclination avoids a pure polar dwell pattern while preserving broad surface
  coverage.

### Sat 2: Multispectral Scanner and Relay Bus

- Body: Minmus
- Separation: remains integrated with transfer bus
- Orbit: circular polar
- Pe/Ap: 300 km / 300 km
- Inc: 90 deg
- Scanner: multispectral
- Scanner altitude limits: ideal 300 km, max 400 km
- Role: biome/anomaly mapper and high-altitude relay asset
- Rationale: 300 km is the installed multispectral scanner's ideal altitude.
  The polar orbit gives full surface rotation coverage over time, and the
  higher altitude improves relay line of sight.

## Flight Profile

1. **Pad setup**
   - Vessel name: `Falcon-Minmus-SCANSat-2`.
   - Sat 1 secondary CPU role tag: `zombie`.
   - Sat 1 decoupler tag: `relay_scan_1_decoupler`.
   - Sat 1 deployable antenna tag: `relay_scan_1_ant`.
   - Sat 1 deployable solar tag: `relay_scan_1_sol`.
   - Sat 2 deployable antenna tag: `relay_scan_2_ant`.
   - Sat 2 deployable solar tag: `relay_scan_2_sol`.
   - The active mission CPU remains on Sat 2/the bus for the whole mission.

2. **Launch and transfer**
   - Run the standard Falcon sequence through Minmus encounter:
     `LAUNCH, FAIR, ANTS, PARK, XING, BPLANE, COAST`.
   - Parking orbit: 85 km Kerbin.
   - Initial launch inclination: 0 deg.
   - Target the transfer and B-plane for a 75 deg Minmus arrival plane.

3. **Capture and Sat 1 release orbit**
   - Capture into 70 km x 70 km at 75 deg inclination if possible.
   - If capture leaves an eccentric orbit, shape to 70 km x 70 km at 75 deg.
   - Extend Sat 1 antenna and solar before separation.
   - Start Sat 1 radar altimetry before separation, or confirm Sat 1's own
     boot script starts it after separation.
   - Decouple `relay_scan_1_decoupler`.
   - Confirm Sat 1 has EC generation, relay link, and radar scan active.

4. **Bus reshape to Sat 2 orbit**
   - Burn prograde from the 70 km orbit to raise apoapsis to 300 km.
   - Coast to apoapsis.
   - At apoapsis, perform a combined circularization and plane-change burn to
     target 300 km x 300 km at 90 deg.
   - This burn should change both speed and plane in one maneuver rather than
     running an immediate low-altitude plane change.

5. **Sat 2 operations**
   - Extend Sat 2 antenna and solar if not already deployed.
   - Start Sat 2 multispectral scanner.
   - Enter `SCANSAT_OPS` for power-guarded mapping to required coverage.
   - End in `DONE` with solar hold.

## Config Sketch

The Falcon mission config is a normal selectable profile. It flies the primary
target first, then a command loads the secondary target:

```cfg
MISSION_ID = minmus_scansat_pair
MISSION_NAME = Falcon Minmus SCANSat 2
TARGET = MINMUS
PAYLOADS = SCANSAT
SEQUENCE = LAUNCH,FAIR,ANTS,PARK,XING,BPLANE,COAST_1HALF,REFINE_BPLANE,COAST_2HALF,CAPTURE,SHAPE,DONE

PARKING_ALT = 85000
LAUNCH_INCLINATION = 0

CAPTURE_PE = 70000
CAPTURE_INC = 75
CAPTURE_DIR = INCLINED

SHAPE_PE = 70000
SHAPE_AP = 70000
SHAPE_INC = 75

SECONDARY_SEQUENCE = SHAPE,SCANSAT_OPS,DONE
SECONDARY_RELEASE_TAG = relay_scan_1_decoupler
SECONDARY_RELEASE_ANTENNA_TAG = relay_scan_1_ant
SECONDARY_RELEASE_SOLAR_TAG = relay_scan_1_sol
SECONDARY_SHAPE_PE = 300000
SECONDARY_SHAPE_AP = 300000
SECONDARY_SHAPE_INC = 90

SCANSAT_TARGET_COVERAGE = 99.1
SCANSAT_REQUIRED_TYPES = MULTISPECTRAL
SCANSAT_POWER_LOW = 0.30
SCANSAT_POWER_RESUME = 0.60
SOLAR_REORIENT_PERIOD = 21600
```

After the primary mission reaches `DONE`, run:

```ks
RUNPATH("0:/cmd/secondarytarget.ks").
```

That command releases Sat 1, marks the secondary target active, and reboots.
Falcon then resumes through the existing `SHAPE,SCANSAT_OPS,DONE`
phases with normal band-change reboots.

After switching to Sat 1, run:

```ks
RUNPATH("0:/cmd/scansatops.ks", "LOW_RES_ALTIMETRY").
```

That marks the zombie core for SCANsat operations and reboots it into the
small SCANsat library set for radar altimetry.

## Known Gaps

1. **Sat 1 wakeup is manual.**
   Sat 1's secondary core is tagged `zombie` and does not automatically arm or
   detect separation. After release, switch to Sat 1 and run `scansatops.ks`.

2. **Sat 2 should not use single-SCANsat release behavior.**
   The integrated bus is already the SCANsat payload. `SCANSAT_OPS` should be
   used only for mapping/power management, with no decoupler release expected.
   The profile sets `SCANSAT_DECOUPLER_TAG = none`, so the phase treats the
   scanner as already attached/on-station.

3. **Arrival-plane targeting needs validation.**
   The plan asks `BPLANE`/capture to target a 75 deg Minmus orbit. The capture
   config can request `CAPTURE_INC = 75`, but the actual B-plane solver and
   capture phase should be verified in simulation/logs before trusting the
   final insertion.

4. **Scanner type names need a live SCANsat check.**
   The config sketch uses `MULTISPECTRAL`. The exact string must match what
   `ADDONS:SCANSAT:ALLSCANTYPES` reports for the installed part.

5. **Sat 1 separation clearance still matters.**
   The bus raises apoapsis soon after releasing Sat 1. The current command waits
   briefly after decoupling, but it does not do an active clearance nudge.
