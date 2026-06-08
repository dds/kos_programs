# kOS Program Code Map

## Boot And Mission Selection

- `boot/boot.ks` is the small VAB-installed loader. It syncs core libraries, loads `lib/boot_core.ks` and `lib/mission_plan.ks`, resolves the craft/role script, and dispatches resume/manual mode.
- `lib/boot_core.ks` parses the vessel name, stores `vessel_name`, `vehicle`, `target`, and `payloads` in state, reads mission profiles from the archive when connected, and prunes stale local `1:/missions` files after persisting config into state.
- `lib/mission_plan.ks` owns mission `SEQUENCE` parsing and the phase-to-library dependency map. Craft scripts use it to derive `LIBS` from the selected profile while keeping `boot_core.ks` focused on boot mechanics.
- Dash-separated vessel names still act as legacy `vehicle-target-payload` hints; space-separated friendly names use the first word as the vehicle id and rely on mission profiles/state for mission details.
- `lib/boot_core.ks` prunes stale local `1:/lib` files before syncing the selected `LIBS`, so progressive reloads actually free storage.
- `cmd/cleanup.ks` / `lib/cleanup.ks` can be run manually to delete local source `.ks` files except `1:/boot/boot.ks` and clear local logs when an older flight computer is out of space.
- `lib/resume.ks` builds `MISSION`, normalizes payload tokens, and builds common rocket sequences.
- `lib/flightplan.ks` renders shared flight-plan and checklist screens for rockets and planes.
- Vehicle scripts in `craft/` define default `CFG`, fallback library plans, phase maps, and craft-specific mission profile tweaks. Mission profiles own `SEQUENCE`.

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
- `deorbit_targeting` - Trajectories-powered targeted deorbit.
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
- `payload_ops` - loaded for probe, relay, SCANsat, or SCISAT payloads. SCANsat can either deploy first or ride the carrier onto an impact Pe, release, stage, and recover itself.
- `science` - loaded only for `SCANSAT`/`SCISAT` payloads.
- `lambert` - loaded only when the target is not Mun.
- `maneuver_intersystem` - loaded only when the target is not Mun.
- `maneuver_rendezvous` - loaded only for rendezvous or asteroid profiles.
- `landing` - loaded only at the post-assist `LAND` reload point.
- `rover` - loaded only at the post-touchdown `ROVER` reload point.

FR3 progressive library bands:

- `LAUNCH`: `fr3_payload`, `fr3_profile`, `fr3_sequence`, `fr3_ui`, `launch`, `countdown`, `orbit`, and landing support for landing payloads. Stops after `PARK` when `RELOAD_AFTER_PARK=1`.
- `TRANSFER`: `fr3_payload`, `fr3_profile`, `fr3_sequence`, `xfer`, `countdown`, `maneuver`, `inclination`, `orbit`, and optional Lambert/rendezvous libraries.
- `PAYLOAD_OPS`: FR3 mission runtime plus probe, relay, or SCANsat operation libraries only.
- `LAND_ASSIST`: FR3 mission runtime, targeted deorbit, and assist-stage release, including maneuver countdown support.
- `LAND`: FR3 mission runtime plus full powered landing, including maneuver countdown support.
- `ROVER`: FR3 mission runtime plus rover driving/co-pilot code.
- SCANsat profiles can insert `SCANSAT_IMPACT_RELEASE` after capture while still in the transfer band, lowering the attached carrier's Pe before releasing and recovering the mapper.
- Band/reload state is saved via `state.ks` as `lib_band`, `lib_band_phase`, `lib_band_libs`, `reload_required`, `reload_reason`, `reload_next_phase`, and `reload_next_band`.

Mission profile files:

- `missions/FR3/*.cfg` - data-only FR3 mission profiles. Plain `FR3` can select one on the launch pad; legacy `FR3-MUN-...` names still work as fallback.
- `missions/FR3/mun_rover_emergency_surface.cfg` - emergency mode that soft-lands the second stage and releases the rover on the surface.
- `craft/FR3.ks` - slim vehicle entry point. It keeps default CFG, ascent sanity checks, boot-time phase-band/library selection, cleanup metadata, and `main()`.
- `lib/fr3_*.ks` - compiled FR3 mission runtime modules. Profile, sequence, payload classification, and launch UI are separate so bands can load only what they need.

## Biggest Files

- `lib/maneuver.ks` - 59 KB after splitting intersystem/rendezvous code. Still the primary split candidate.
- `lib/landing.ks` - 19 KB. Split candidate if rover/lander roles diverge.
- `lib/xfer.ks` - 18 KB. Mostly phase wrappers; can shrink after `maneuver.ks` is split.
- `lib/deorbit_targeting.ks` - 12 KB. Shared by probes and landing.
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
- landing: `deorbit_targeting`, `payload_landing`, `landing`.
- rover mission reloads: landing support during launch/assist release, full `landing` after assist release, `rover` after touchdown.

It does not need:

- SCANsat/science.
- Lambert interplanetary transfer.
- rendezvous or asteroid intercept.
- relay/probe release phases unless their payload tokens are present.
