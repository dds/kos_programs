# kOS Program Code Map

## Boot And Mission Selection

- `boot/boot.ks` parses the vessel name, stores `vehicle`, `target`, and `payloads` in state, compiles the selected vehicle script to `1:/craft/*.ksm`, then syncs and loads that vehicle's `LIBS`.
- `boot/boot.ks` reads mission profile files from the archive when connected and prunes stale local `1:/missions` files after persisting the selected config into state.
- `boot/boot.ks` prunes stale local `1:/lib` files before syncing the selected `LIBS`, so progressive reloads actually free storage.
- `lib/resume.ks` builds `MISSION`, normalizes payload tokens, and builds common rocket sequences.
- `lib/flightplan.ks` renders shared flight-plan and checklist screens for rockets and planes.
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
- `landing_assist` - targeted deorbit plus assist-stage hover/release for landing missions before rover separation.
- `payload_landing` - minimal landing phase wrappers for landing-only missions.
- `utils` - small shared helpers.
- `ui` - small terminal formatting helpers.
- `fr3_payload` - FR3 payload classification helpers.
- `fr3_profile` - FR3 mission profile tweaks.
- `fr3_sequence` - FR3 sequence construction and phase map.

Profile-only FR3 libraries:

- `flightplan` - shared flight-plan/checklist renderer, loaded by FR3 only for launch confirmation.
- `fr3_ui` - launch confirmation display, loaded only in the launch band.
- `lib_term` - KSLib terminal drawing helpers, available in the archive for future positioned terminal widgets but not loaded by FR3 yet.
- `payload_ops` - loaded for probe, relay, SCANsat, or SCISAT payloads.
- `science` - loaded only for `SCANSAT`/`SCISAT` payloads.
- `lambert` - loaded only when the target is not Mun.
- `maneuver_intersystem` - loaded only when the target is not Mun.
- `maneuver_rendezvous` - loaded only for rendezvous or asteroid profiles.
- `landing` - loaded only at the post-assist `LAND` reload point.
- `rover` - loaded only at the post-touchdown `ROVER` reload point.

FR3 progressive library bands:

- `LAUNCH`: `fr3_payload`, `fr3_profile`, `fr3_sequence`, `fr3_ui`, `launch`, `countdown`, `orbit`, and `landing_assist` for landing payloads. Stops after `PARK` when `RELOAD_AFTER_PARK=1`.
- `TRANSFER`: `fr3_payload`, `fr3_profile`, `fr3_sequence`, `xfer`, `countdown`, `maneuver`, `inclination`, `orbit`, and optional Lambert/rendezvous/science libraries.
- `PAYLOAD_OPS`: FR3 mission runtime plus probe, relay, or SCANsat operation libraries only.
- `LAND_ASSIST`: FR3 mission runtime, targeted deorbit, and assist-stage release, including maneuver countdown support.
- `LAND`: FR3 mission runtime plus full powered landing, including maneuver countdown support.
- `ROVER`: FR3 mission runtime plus rover driving/co-pilot code.
- Band/reload state is saved via `state.ks` as `lib_band`, `lib_band_phase`, `lib_band_libs`, `reload_required`, `reload_reason`, `reload_next_phase`, and `reload_next_band`.

Mission profile files:

- `missions/FR3/*.cfg` - data-only FR3 mission profiles. Plain `FR3` can select one on the launch pad; legacy `FR3-MUN-...` names still work as fallback.
- `missions/FR3/mun_rover_emergency_surface.cfg` - emergency mode that soft-lands the second stage and releases the rover on the surface.
- `craft/FR3.ks` - slim vehicle entry point. It keeps default CFG, mission-state intake, and library-band selection.
- `lib/fr3_*.ks` - compiled FR3 mission runtime modules. Profile, sequence, payload classification, and launch UI are separate so bands can load only what they need.

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
- rover mission reloads: `landing_assist` during launch/assist release, full `landing` after assist release, `rover` after touchdown.

It does not need:

- SCANsat/science.
- Lambert interplanetary transfer.
- rendezvous or asteroid intercept.
- relay/probe release phases unless their payload tokens are present.
