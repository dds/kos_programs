# Flight automation work

Updated 2026-10-27. Keep this list current as scope changes. A source check
passing is not native flight validation. Preserve mission safeguards and
record remaining uncertainty before closing a task.

## Compact working handoff

- Current baseline: `7270867`, clean main, pushed. Tundra mission is launching.
- Operator explicitly removed the thermometer/storage prelaunch gate. Do not
  restore it or add temperature transmission without a further request.
- Current flight blocker: Tundra XING boot004 at UT2816238.4 treats an
  expired4.437m/s node as a departure; parking is72.7x78km. Fix the MJ parking
  handoff without weakening the arrival corridor or deleting foreign nodes.
- Emergency capture source fix is implemented; then audit cached-state
  mutations and continue the read-only Deck renderer investigation.
- Preserve existing capture, Pe, fuel, staging and return reserve safeguards.
  Timed waits stay resident with KAC before solar and a clock fallback.
- Implemented Tundra, LAND_PREP, between-pass staging and entry-alarm/solar
  changes await native compilation/flight evidence. Do not close those tasks
  on source tests alone. Landing efficiency changes need fresh flight logs.
- Deck crash is an unsolved Unity renderer failure under memory pressure;
  inspection is complete, settings unchanged, Plex excluded.

## In progress

- [ ] **Emergency hyperbolic capture safety.** Implemented zero-throttle
  alignment before live orbital-retrograde thrust. Optional assist and capture
  share body/stage/node/Abort/warp/freshness/deadline and attitude/energy guards.
  Capture preserves its0.1-unit fuel stop, configured Pe floor and bound-orbit
  stop; no staging/engine activation was added. Full-wet-mass/flow duration
  bound replaces an unlimited burn; stale publishers latch zero. Shared
  physical cutoff precedes CPU/log restoration and clearing the active marker.
  Interrupted capture cuts off and holds once for review; outbound hyperbolic
  reboot resumes can retry capture before coasting. Existing optional-assist
  checks and new independent capture/finite-slew/cutoff fixtures passed.
  Full suite deferred for the new XING flight blocker. Native validation open.
- [ ] **Tundra departure blocked by a parking node.** Native RO9_2815982
  boot003 reaches parking and advances at UT2816224.8. Boot004 XING at
  UT2816238.4 resumes a4.437m/s node with ETA-25.2s, pending=false and empty
  burn_phase. No transfer planning runs. Its missing Minmus patch is printed
  as PeKm=-0.001; this is not a solved Minmus periapsis. Likely MJ ascent is
  still finishing circularization when the loose parking gate advances.
  Operator can delete the old node and reboot. Inspect/fix ownership and
  completion at the PARK handoff; retain the real departure corridor check.
- [ ] **Latest Deck crash: renderer/memory follow-up.** Inspected before
  mission work. Crash_2026-10-27_092057394/error.log reports UnityPlayer.dll
  access violation0xc0000005 at09:20:58UTC,94% physical memory used/800MB
  free,9951MB process paging/commit and6947MB peak working set (Proton
  reporting; not Linux swap/PSS). KSP.log has12432 RenderBuiltins stack
  entries beginning09:15:00UTC after Kerbin camera/cloud setup. No kernel
  OOM/GPU-allocation error in09:15–09:24UTC. Cause remains unproven; distinguish
  renderer failure from memory pressure. ShadowMan requested8192 shadow-map
  resolution despite the separately applied Scatterer2048 setting; verify
  final ownership before changing anything. Read-only reports preserved at
  `/tmp/ksp-deck-crash-20261027.json` and
  `/tmp/ksp-deck-crash-detail-20261027.json`; full Unity logs/dump remain in
  the dated crash directory on Deck. No game settings changed. Exclude Plex.
- [ ] **New RO9 Minmus Tundra / survey / landing / science-return mission.**
  First achieve Ap397272m, Pe9300m, inclination116.6deg, LAN337deg,
  AoP270deg. Then choose an efficient order for five overhead orbital
  temperature surveys above the supplied3200–6600m minimum thresholds and
  a landing at lat-29.189/lon17.465. Survey sites:
  (52.648,2.235), (34.308,-12.419), (52.176,18.898),
  (35.436,-18.744), (52.128,82.575). Return the science to Kerbin.
  Implemented `missions/RO9/minmus_tundra_survey_return.ks`: exact first
  orbit and review -> generic LAND_PREP retaining116.6deg/9.3km Pe while
  lowering Ap to~19.3km -> ORBITAL_SURVEY -> contract-review hold -> fixed
  landing -> eastward29.189deg low-orbit ascent ->53km Kerbin entry.
  Survey-first avoids an ascent into the northern survey plane after landing;
  no global optimality claim. All readings use >6600m ASL, retaining the9km
  safety floor. Configurable1km overhead criterion is not a supplied contract
  radius. Bounded rotating ground-track forecasts, closest-pass refinement,
  KAC-before-solar resident retries, live position/altitude admission and
  copied persistent progress are implemented. Measurements are not contract
  verification; manual release follows the five readings. Operator removed
  the prelaunch thermometer/storage gate; its helper was also removed. No
  transmit/dump; reset only after data collection; duplicate refusal holds.
  First orbital review now reserves sensors instead of pre-deploying them.
  Independent retrograde conic/source fixtures reach all five actual sites;
  source checks cover hardware/data preservation, waits/cancellation, two
  fresh return profiles and reboot progress. All57 routine check files
  passed in78.11s; targeted survey/loading/legacy-profile checks and the
  structural audit were rerun after the final loading refinement. Audit:
  zero errors, existing missing `ksc_deorbit` handler warning unchanged.
  Native compile/cache size,
  storage behavior, contract acceptance, full landing and return pending.
- [ ] **Generic landing-orbit preparation / Kolniya mission.** Implemented
  reusable LAND_PREP in its own band, after SCIENCE_OPS review and before
  target-specific LAND_DEORBIT. Automatic low apsides preserve an already-low
  safe Pe; current inclination/LAN remain unless explicitly requested.
  Uses shared real plane-intersection/apsis planners, executor, cutoff,
  return-stage floor, separate budget and KAC/solar waits. Owned unflown
  nodes and reserved cost survive reboot; incomplete burns require explicit
  shaperetry. Full next-band cache inspection allows offline progression;
  otherwise a running link-check wait replaces a prompt exit. New code needs
  a connected boot; no installed bootstrap change.
  Native Minmus3 boot021/022 is9.3x397.2km/i63.39, with repeating best site
  misses~40.2km and deorbit normal cap10m/s unable to repair them. The ideal
  source/conic fixture uses45.46m/s to prepare9.3x19.3km, retaining plane and
  all waypoint/contract/return intent. Period changes20200->3028s; the profile
  surveys48 low-orbit passes under unchanged4096 geometry/64 native limits.
  Regressions cover budget/floor/plane/patch guards, disk-persisted ownership,
  reboot, cutoff/interruption, cache/link/no-KAC waits and inflight rerouting.
  All 56 routine check files passed in 110.36 s; each new preparation case
  took less than 0.18 s in the timing pass. Structural audit has no errors;
  its missing `ksc_deorbit` handler warning predates this change.
  Native compilation/cache size, actual preparation, deorbit solve and full
  Flats landing/high-equatorial-orbit/Kerbin return still need validation.
- [ ] **Use excess fuel across return stages safely.** Implemented RO9
  tagged 3→2→1 handoffs at the next entry-preparation wake, outside atmosphere
  and after warp release. Requires physical cutoff, CPU/chute retention,
  full staging-slot module audit, current-stage stock AND own-tank depletion
  to the repair allowance, and next-engine fuel above that allowance.
  One attempt per separator UID survives reboot; failed verification holds.
  Next engine gets a fresh forecast and refreshed entry alarm. Original
  powered stage-change/alignment/Pe/pressure/reserve cutoffs remain intact.
  Source regressions include both handoffs, 50 rejection cases, persistence
  races and failed/interrupted events. Read-only saved RO9 inspection confirmed
  actual inert tank/leg stage indices and the disposable `main_fairing` layout.
  All 55 routine check files passed in 101.33 s; new staging file passed in
  under one second when run separately. `make audit` reports no errors and
  the pre-existing missing `ksc_deorbit` handler warning.
  Native flight and compiled cache size remain unverified. This deliberately
  uses successive entries, not in-atmosphere stage changes during one burn.
- [ ] **Aerobrake: refresh the next-entry KAC alarm after every skip-out.**
  Replace the stale first-pass alarm after drag and any capture burn, before
  the next solar coast. Use the actual next inbound atmosphere crossing,
  preserve other alarms and the running clock wait without KAC. Implemented;
  the three-pass source regression and all 54 check files passed. Native
  next-pass alarm timing still needs validation after a connected reboot.
- [ ] **RO9 return hardware and powered-assist setup.** Native RO9 flight
  `RO9_2446359`, boot 019 at UT 2783434, Pe 53.135 km / Ap 35038.7 km: generated
  `kerbin_return` explicitly saves `AEROBRAKE_AP_BURN=0`. It overrides the
  craft default. The profile requests `descent_decoupler` at 6 km, but the
  saved vessel has only `return_decoupler` (stage 1) and `lander_decoupler`
  (stage 2); stage 3 Torch is active, stage 2/1 Spark engines are inactive.
  `descent_chutes` stays with the CPU above both separators.
  `cmd/aeroassist.ks` now optionally selects a final DESCENT separator after
  verifying CPU/chute retention; 16 rejection cases passed. No hardware fires
  in the command. Operator application and final native separation still
  need validation; no live flight changes were made by the agent.
- [ ] **Aerobrake solar hold reports unavailable.** Native boot logs show
  `STATS aerobrake solar status=unavailable coasting-without-solar-aim`.
  Root cause found: profile-first boot planning precedes craft LIBS_EXTRA;
  AEROBRAKE did not declare solar. Native RO9 has a supported stock panel.
  Dependency and distinct missing-helper/panel diagnostics implemented;
  source loading/aim/deadline checks passed. Native solar hold still needs
  validation after a connected reboot, without weakening entry waits.

## Next changes

- [ ] **Landing-preparation efficiency refinements.** The generic LAND_PREP
  now deliberately provides a low parking orbit for broad target coverage.
  A future optional comparison can estimate direct descent versus a parking
  change for a known site, including descent cost/reserve. Do not reintroduce
  a target-specific optimizer into the generic phase or assume Ap is a plane
  intersection. Retain the waypoint and native final deorbit checks.
- [ ] **Audit mutable persistent-state collections.** stateGet returns its
  cached Lexicon; in-place mutation can make stateSet skip its flush. The new
  preparation ledger copies flat metadata before each edit and its fixture
  exercises cache-reference semantics plus a separate disk snapshot. Audit
  other callers before changing shared state behavior; no other flight bug
  has yet been attributed to this pattern.
- [ ] **Continue landing accuracy and efficiency validation.** Targeted
  landings must meet their locked target; economy sites may divert under
  their explicit policy. Validate powered-lead convergence, burn timing
  across stage changes and recovery without prolonged low-altitude hovering.
  Last source fixes: `6635266` and `90099ef`; new flight logs still needed.
- [ ] **Continue ascent/return efficiency work.** Account for changing TWR
  across lander/return stages and compare direct Kerbin departure against
  parking-orbit insertion. Preserve entry corridor and fuel reserves.

## Flight validation / measurements pending

- [ ] **Minmus3 Kolniya contract completion.** `e9d94c3` is in the Deck
  archive. Native boot018 shows the 0.023342 m/s AP correction succeeded,
  leaving AP error about -40 m; a 0.190152 m/s PE correction is scheduled.
  Need the final SHAPE errors and in-game contract completion. Fine trims
  are necessary: current profile uses 100 m apsis tolerance, 0.002 m/s minimum,
  0.001 m/s cutoff and 9 km Pe floor. Do not waive these targets on a skip.
- [ ] **Deck memory headroom.** Five approved settings applied and verified:
  Scatterer shadows 2048, nonpersistent 128 MB upload buffer, 256 MB temporary
  texture-load budget, NoIVA placeholder mode, Making History optional
  features disabled while retaining parts. Backup on Deck:
  `~/ksp-memory-backups/20261027T061853Z/`. Native startup skipped 120 IVA
  models / 197 textures. Loaded flight still had only 0.61 GiB available,
  KSP 3.85 GiB RSS / 3.98 GiB swapped and 6.24 GiB graphics GTT allocation; these
  counts overlap. No matched baseline proves total savings. Compare scenes
  and investigate texture/Parallax cuts before calling memory work complete.
  Plex will be closed; exclude it from further tuning recommendations.

## Completed checkpoints

- [x] Public SSH keys installed for `deck@10.200.26.154`; both verified in
  fresh password-disabled logins. Never put credentials in this file.
- [x] SHAPE minimum/fallback and precision fixes pushed (`2618381`,
  `a7a41a3`); bounded post-cutoff settling and explicit `shaperetry` recovery
  pushed (`e9d94c3`). 53 check files passed before the current work.
- [x] Aerobrake KAC/solar dependency fixes and optional validated final
  separator configuration implemented and documented; 54 check files passed.
  Keep the native validation entries above open until flight evidence arrives.
- [x] RO9 between-pass stage handoffs implemented with saved-hardware layout,
  depletion, complete slot-module, interruption and fresh-forecast regressions;
  all 55 routine check files passed. Native staging remains open above.
- [x] Generic LAND_PREP phase and Minmus3 integration implemented; 56 routine
  check files passed. Native preparation and the full mission remain open.
- [x] First automated Mun landing and return to Kerbin succeeded. This is
  a milestone, not proof that targeted landings or fuel use are optimal.
