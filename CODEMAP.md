# kOS Program Code Map

## Boot And Mission Selection

- `boot/boot.ks` is the small VAB-installed loader. It syncs only `lib/boot_lib.ks` and `lib/dependencies.txt`, loads `boot_lib`, then delegates preamble/core and mission library loading to `boot_lib`.
- `lib/boot_lib.ks` parses the vessel name, stores `vessel_name`, `vehicle`, `target`, and `payloads` in state, reads mission profiles from the archive when connected, and refreshes compact `lib/dependencies.txt` from archive to local storage when linked.
- `lib/mission_plan.ks` owns mission `SEQUENCE` parsing and payload helpers. `lib/boot_lib.ks` expands `PREAMBLE`, `LIB`, `PHASE`, and multi-phase `BAND` rows from compact `lib/dependencies.txt`.
- `lib/dependencies.ks` is generated from `dependencies.txt` and provides the tiny phase-name to convention-delegate map used by `lib/phases.ks`.
- Dash-separated vessel names still act as legacy `vehicle-target-payload` hints; space-separated friendly names use the first word as the vehicle id and rely on mission profiles/state for mission details.
- `lib/boot_lib.ks` prunes stale local `1:/lib` files before syncing the libraries returned by `bootVehicleLibs()`, so progressive reloads actually free storage.
- `cmd/cleanup.ks` / `lib/cleanup.ks` can be run manually to delete local source `.ks` files except `1:/boot/boot.ks` and clear local logs when an older flight computer is out of space.
- `lib/resume.ks` builds `MISSION`, normalizes payload tokens, and builds common rocket sequences.
- `lib/flightplan.ks` renders shared flight-plan and checklist screens for rockets and planes.
- Vehicle scripts in `craft/` define default `CFG`, fallback library plans, craft-local handler overrides, and craft-specific mission profile tweaks. Mission profiles own `SEQUENCE`.

## FR3 Loaded Libraries And Bands

`lib/dependencies.txt` is the source of truth for FR3 dependency roots:

- `PREAMBLE = core` means every band/phase gets `core`, which expands to `state`, `logs`, `files`, `phases`, `config`, `mission_plan`, `countdown`, and `zombie`.
- `LIB` rows declare library dependencies.
- `PHASE` rows declare root libraries for phase names.
- `BAND` rows declare phase collections that should load together. Single phases intentionally do not have `BAND` rows; the phase name itself is the fallback band.

Base/shared FR3 libraries:

- `core` - always-loaded helper root.
- `dependencies` - generated phase-name to handler delegate map, loaded on demand by `phaseHandlerMap()` after band libraries are present.
- `phases` - phase machine.
- `launch` - launch, fairing, panels/antennas, parking orbit.
- `xfer_plan` - rendezvous/transfer planning phases.
- `lib_navigation` - phase angles, true anomaly helpers, AN/DN helpers.
- `countdown` - launch countdown.
- `maneuver` - maneuver execution plus simple capture/circularize/raise/AoP node helpers.
- `maneuver_transfer` - local body transfer planning and MCC, using shared patch targeting.
- `inclination` - inclination change and target inclination resolution.
- `orbit` - orbit summaries and SOI waits.
- `deorbit_targeting` - Trajectories-powered targeted deorbit.
- `payload_landing` - landing/rover payload phase wrappers.
- `mission_plan` - sequence parsing and generic payload classification helpers.
- `utils` - small shared helpers.
- `ui` - small terminal formatting helpers.

Profile-only FR3 libraries:

- `flightplan` - shared flight-plan/checklist renderer.
- `lib_term` - KSLib terminal drawing helpers, available in the archive for future positioned terminal widgets but not loaded by FR3 yet.
- `payload_ops` - loaded for probe, relay, SCANsat, or SCISAT payloads. SCANsat can either deploy first or ride the carrier onto an impact Pe, release, stage, and recover itself.
- `science` - loaded only for `SCANSAT`/`SCISAT` payloads.
- `lambert` - loaded only when the target is not Mun.
- `maneuver_intersystem` - loaded only when the target is not Mun.
- `maneuver_rendezvous` - loaded only for rendezvous or asteroid profiles.
- `landing` - loaded in the `LANDING` band with all landing phases.
- `rover` - loaded only at the post-touchdown `ROVER` reload point.

FR3 progressive library bands:

- `LAUNCH`: `LAUNCH`, `FAIR`, `ANTS`, `PARK`. FR3 overrides `PARK` to stop after parking orbit and reboot into the transfer band.
- `XFER_PLAN`: `XING`.
- `RENDEZVOUS`: `RDV`.
- `XFER_ARRIVE`: `COAST`, `CAPTURE`.
- `XFER_ORBIT`: `CIRC`, `RAISE`, `INCLINE`, `ELLIPTICAL`, `DROP_FOR_IMPACT_AND_RAISE_PE`.
- `PAYLOAD_OPS`: `TARGETED_DEORBIT`, `RELEASE_PROBE`, `RELAY_OPS`, `SCANSAT_OPS`.
- `LANDING`: `LAND_DEORBIT`, `LAND_ASSIST`, `LAND`, so landing does not reboot between adjacent descent phases.
- Single-phase steps such as `MCC` and `ROVER` fall back to their phase name as the band.
- Empty or legacy `MAIN` startup phase state is treated as no real phase yet. FR3 asks `bootDefaultBandForVehicle()` for the first band: rockets start in `LAUNCH`, aircraft/sea/spaceplanes start in `PREFLIGHT`, and rovers start in `ROVER`.
- SCANsat profiles can insert `DROP_FOR_IMPACT_AND_RAISE_PE` after capture while still in the transfer band, lowering the attached carrier's Pe before releasing and recovering the mapper.
- Band/reload state is saved via `state.ks` as `lib_band`, `lib_band_phase`, `lib_band_libs`, `reload_required`, `reload_reason`, `reload_next_phase`, and `reload_next_band`.

Mission profile files:

- `missions/FR3/*.cfg` - data-only FR3 mission profiles. Plain `FR3` can select one on the launch pad; legacy `FR3-MUN-...` names still work as fallback.
- `missions/FR3/mun_rover_emergency_surface.cfg` - emergency mode that soft-lands the second stage and releases the rover on the surface.
- `craft/FR3.ks` - FR3 vehicle entry point. It keeps default CFG, ascent sanity checks, FR3-specific landing defaults, sequence construction, boot-time phase-band/library selection, cleanup metadata, and `main()`. Shared phase-name bindings live in `lib/phases.ks`; FR3 only overrides `PARK`.

## Biggest Files

- `lib/maneuver_transfer.ks` - transfer planning and MCC.
- `lib/maneuver.ks` - burn execution and simple node planners.
- `lib/landing.ks` - 19 KB. Split candidate if rover/lander roles diverge.
- `lib/xfer_plan.ks` / `lib/capture.ks` / `lib/maneuver_orbit.ks` - transfer, arrival, and orbit-cleanup phase wrappers.
- `lib/deorbit_targeting.ks` - 12 KB. Shared by probes and landing.
- `lib/lambert.ks` - 10 KB. Already profile-only for FR3.
- `lib/launch.ks` - 10 KB. Needed for launch bands.
- `lib/science.ks` - 9 KB. Already profile-only for FR3.

## `maneuver.ks` Sections

- `lib/maneuver.ks`: maneuver execution, capture/circularize/raise/AoP helpers.
- `lib/maneuver_transfer.ks`: local Mun/Minmus transfer, LAN scan, closest approach search, MCC.
- `lib/maneuver_intersystem.ks`: interplanetary Lambert body transfer.
- `lib/maneuver_rendezvous.ks`: vessel rendezvous and asteroid Lambert intercept.

## Suggested Slices

- `maneuver.ks`: already holds `executeManeuver` and simple node helpers.
- `maneuver_transfer.ks`: already holds Mun/Minmus transfer, LAN scan, and MCC.
- `maneuver_patch_target.ks`: coupled patch element targeting and Newton targeting.

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
