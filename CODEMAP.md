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
- `maneuver` - maneuver execution, local body transfer, capture, MCC, patch targeting.
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
- `maneuver_intersystem` - loaded only when the target is not Mun.
- `maneuver_rendezvous` - loaded only for rendezvous or asteroid profiles.

Mission profile files:

- `missions/FR3/*.cfg` - data-only FR3 mission profiles. Plain `FR3` can select one on the launch pad; legacy `FR3-MUN-...` names still work as fallback.

## Biggest Files

- `lib/maneuver.ks` - 59 KB after splitting intersystem/rendezvous code. Still the primary split candidate.
- `lib/landing.ks` - 19 KB. Split candidate if rover/lander roles diverge.
- `lib/xfer.ks` - 18 KB. Mostly phase wrappers; can shrink after `maneuver.ks` is split.
- `lib/targeting.ks` - 12 KB. Shared by probes and landing.
- `lib/lambert.ks` - 10 KB. Already profile-only for FR3.
- `lib/launch.ks` - 10 KB. Needed for all launch vehicles.
- `lib/science.ks` - 9 KB. Already profile-only for FR3.

## `maneuver.ks` Sections

- `lib/maneuver.ks`: maneuver execution, local Mun/Minmus transfer, LAN scan, closest approach search, patch targeting, capture helpers, MCC.
- `lib/maneuver_intersystem.ks`: interplanetary Lambert body transfer.
- `lib/maneuver_rendezvous.ks`: vessel rendezvous and asteroid Lambert intercept.

## Suggested Slices

- `maneuver_exec.ks`: `executeManeuver` and burn execution helpers.
- `maneuver_orbit.ks`: circularize, capture, raise Pe, AoP helpers.
- `maneuver_transfer_local.ks`: Mun/Minmus transfer and LAN scan.
- `maneuver_patch_target.ks`: coupled patch element targeting and Newton targeting.
- `maneuver_mcc.ks`: `phaseMidCourse` and MCC helpers.

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
