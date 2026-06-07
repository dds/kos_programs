# kOS Program Code Map

## Boot And Mission Selection

- `boot/boot.ks` parses the vessel name, stores `vehicle`, `target`, and `payloads` in state, syncs the vehicle script, then syncs and loads that vehicle's `LIBS`.
- `lib/resume.ks` builds `MISSION`, normalizes payload tokens, and builds common rocket sequences.
- Vehicle scripts in `craft/` define default `CFG`, `LIBS`, phase sequence, phase map, and mission profile tweaks.

## FR3 Loaded Libraries

Base FR3 libraries:

- `phases` - phase machine.
- `launch` - launch, fairing, panels/antennas, parking orbit.
- `xfer` - rendezvous/transfer/coast/capture/orbit finalization phase wrappers.
- `lib_navigation` - phase angles, true anomaly helpers, AN/DN helpers.
- `countdown` - launch countdown.
- `maneuver` - maneuver execution, transfer planning, capture, MCC, rendezvous, asteroid intercept.
- `inclination` - inclination change and target inclination resolution.
- `orbit` - orbit summaries and SOI waits.
- `targeting` - Trajectories-powered targeted deorbit.
- `landing` - deorbit, powered descent, landing-assist release.
- `payload_landing` - minimal landing phase wrappers for landing-only missions.
- `utils` - small shared helpers.

Profile-only FR3 libraries:

- `payload_ops` - loaded for probe, relay, SCANsat, or SCISAT payloads.
- `science` - loaded only for `SCANSAT`/`SCISAT` payloads.
- `lambert` - loaded only when the target is not Mun.

## Biggest Files

- `lib/maneuver.ks` - 83 KB. Primary split candidate.
- `lib/landing.ks` - 19 KB. Split candidate if rover/lander roles diverge.
- `lib/xfer.ks` - 18 KB. Mostly phase wrappers; can shrink after `maneuver.ks` is split.
- `lib/targeting.ks` - 12 KB. Shared by probes and landing.
- `lib/lambert.ks` - 10 KB. Already profile-only for FR3.
- `lib/launch.ks` - 10 KB. Needed for all launch vehicles.
- `lib/science.ks` - 9 KB. Already profile-only for FR3.

## `maneuver.ks` Sections

- Lines 12-180: maneuver execution, circularize, encounter helpers.
- Lines 209-702: body transfer planning, local transfer, interplanetary transfer, LAN scan.
- Lines 719-1191: vessel rendezvous, asteroid intercept, Lambert intercept refinement.
- Lines 1208-1657: coupled PE/INC/LAN/AoP patch targeting helpers.
- Lines 1678-1900: generic Newton patch targeting.
- Lines 1901-1961: capture, raise Pe, AoP helpers.
- Lines 1973-2191: mid-course correction and execution helpers.

## Suggested Slices

- `maneuver_exec.ks`: `executeManeuver` and burn execution helpers.
- `maneuver_orbit.ks`: circularize, capture, raise Pe, AoP helpers.
- `maneuver_transfer_local.ks`: Mun/Minmus transfer and LAN scan.
- `maneuver_transfer_lambert.ks`: interplanetary transfer and `lambert.ks` dependency.
- `maneuver_patch_target.ks`: coupled patch element targeting and Newton targeting.
- `maneuver_mcc.ks`: `phaseMidCourse` and MCC helpers.
- `maneuver_rendezvous.ks`: rendezvous and asteroid intercept.

## Current FR3 Mun Rover Requirement

`FR3-MUN-LANDER-01` or `FR3-MUN-ASSISTLANDER-01` needs:

- launch stack: `phases`, `launch`, `countdown`, `orbit`, `lib_navigation`, `inclination`.
- Mun transfer/capture: local transfer, capture, circularize, raise/incline, MCC, patch targeting.
- landing: `targeting`, `landing`, landing payload phases.

It does not need:

- SCANsat/science.
- Lambert interplanetary transfer.
- rendezvous or asteroid intercept.
- relay/probe release phases unless their payload tokens are present.
