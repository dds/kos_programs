# Flight automation work

Updated 2026-10-27. Keep this list current as scope changes. A source check
passing is not native flight validation. Preserve mission safeguards and
record remaining uncertainty before closing a task.

## Compact working handoff

- Code checkpoints: prelaunch gate removed in `7270867`; emergency capture
  implemented in `84203cc`. Parking handoff fix is recorded below.
- Operator explicitly removed the thermometer/storage prelaunch gate. Do not
  restore it or add temperature transmission without a further request.
- Tundra XING boot004 at UT2816238.4 treats an expired4.437m/s parking node
  as a departure. Operator must inspect/delete that stale node and reboot;
  the PARK handoff fix prevents advancing while MJ is still circularizing.
- Current operator priority: landing-preparation route/cost comparison, then
  landing accuracy/fuel use and staged ascent/return efficiency. Deck renderer
  investigation is deferred; its latest read-only snapshot is
  `/tmp/ksp-renderer-config-audit-20261027.json`. Settings remain unchanged.
- Route comparison is implemented and pushed in `ea80331`; it is advisory,
  not a native powered-trajectory choice. The next flight can use LAND_PREP.
- Current interruption: finish aerobrake disposable-stage reserve and
  manual-stage/finite-burn entry replanning, then resume landing/ascent work.
  RO9_2446359 boot027 survived; operator confirms touchdown. Manual stage
  separation on that run does not validate automatic handoffs.
- Minmus3 deorbited without landing code and lost radio. Operator declined
  recovery commands; leave that flight alone. Shared body/relay radio policy
  and cached-track retention remain. Operator explicitly requested removing
  the whole-descent cache gate and accepts missing-code blackout risk; do not
  restore it. Storage reduction is now a nonblocking resilience task.
- RO9-mun2 boot025 on88feef6 now validates the normal-only fallback and full
  powered planning: 58/64 trials, cross116m, modeled residual-1212m within
  1500m. Cache gate is removed. Latest boot027 instead held after its powered
  forecast changed during coast; bounded pre-burn refit is implemented below,
  operator now confirms touchdown on887aa4d. Retrieved native diagnostics:
  ignition within1.3s of forecast; guidance miss2m, original miss638.8m due to
  terrain shift640m. Target-dependent BRAKE lateral guidance is implemented,
  shared with prediction, and awaiting native validation:
  it left1209m cross-track for APPROACH, costing119s/~205m/s estimated impulse.
  Operator authorizes2km deorbit cross-track
  for RO9 mun_landing_return only; preferred250m/normal10m/s/trials64 remain.
- Operator confirmed the Minmus3 Kolniya orbital objective succeeded. Next
  flight step is the existing LAND_PREP/landing route; the comparison is an
  optimization, not a new prerequisite. Stage handoff/next-entry KAC flight
  confirmations remain pending from the operator.
- Native bridge correction `5698546`: no top-level MJ NODE suffix exists.
  PARK uses supported ASCENT:ENABLED, then verifies physical cutoff/orbit.
- Preserve existing capture, Pe, fuel, staging and return reserve safeguards.
  Timed waits stay resident with KAC before solar and a clock fallback.
- Implemented Tundra, LAND_PREP, between-pass staging and entry-alarm/solar
  changes await native compilation/flight evidence. Do not close those tasks
  on source tests alone. Landing efficiency changes need fresh flight logs.
- Earlier Unity crash remains unresolved. Latest Deck incident has native
  TTM/DRM graphics-memory locking stalls at5039s; probable deadlock under
  severe memory pressure. See crash follow-up below. Settings unchanged, Plex
  excluded. Do not conflate the two incidents or assume a particular fix.

## In progress

- [ ] **RO9 Minmus polar orbit, four sites and equatorial return.** New
  profile requested: Ap1064182m/Pe444576m/inc90/LAN298.9/AoP244.9, then
  LAND_PREP and fixed A(-1.080,1.365), hops B(-1.190,1.596), C(-1.554,2.780),
  D(-3.029,2.189). Ten-minute resident KAC science stop at every site,
  automatically proceeding for this profile only. Then ascent/SHAPE to
  Ap659734m/Pe554472m/inc0/AoP0.4 and fuel-assisted Kerbin entry Pe53000m.
  A->B only~270m: tighten hop acceptance and local terrain shifts. Preserve
  existing manual hop review, staged return reserve and all flight gates.
  Implemented `missions/RO9/minmus_polar_hops_return.ks` plus generic
  HOP_ROUTE_SETUP/HOP_AUTO_REVIEW provider/band. Fixed100m surface admission,
  50m hop prediction tolerance,20m terrain-refinement radius. KAC installed
  before science; persisted600s deadline and one experiment attempt survive
  reboot. Stops remain at1x with brakes/attitude retained; unavailable KAC
  uses the resident clock. After D, restore the original shaped-orbit return.
  Existing manual routes keep HOP_REVIEW/prompt semantics. New source cases
  verify four stops/three launches, return serialization, partial setup,
  reboot deadlines, no-KAC and unsafe-control/site/fuel/terrain rejection;
  new case file0.58s, each case<0.24s. All66 routine files pass77.71s.
  Native kOS compilation/storage, short-hop dynamics, science result
  availability and the full automated mission remain unvalidated.
  Flight follow-up:0.297m/s set-pe skipped by LAND_PREP's0.3m/s minimum,
  preventing readiness; a forced LAND_DEORBIT correctly routed back to prep.
  Operator requests0.1m/s. Updated shared preparation default and explicit
  polar profile setting; other burn families and250m tolerance unchanged.
  Independent vis-viva/source replay added for exactly0.297m/s plus0.1
  admission boundary, preserving readiness, budgets and strict SHAPE policy.
  Landing preparation/route, polar mission, Kolniya and structural checks
  pass; native retry after a connected reboot remains pending.
- [ ] **Landing coast: KAC alarm for braking alignment.** RO9-minmus4
  diagnostic3243569410/boot021 confirms a resident COAST/countdown, zero
  throttle and no braking alarm. Source only printed the HUD estimate;
  maneuver alarms cover the earlier deorbit burn, not landing coast.
  Added a vessel-owned KillWarp alarm from the displayed transition ETA,
  checked every5s, strict1s reuse tolerance, reboot reuse/manual-deletion
  recovery and cleanup on coast exit/landing finish/abort. Shared alarm
  helper keeps its existing60s tolerance for other callers. No solar, warp,
  blocking wait or ignition-gate changes. Source-driven lifecycle checks
  pass; all65 routine check files passed78.11s; final guidance/alarm/structure
  checks also pass after cleanup/sentinel refinements. Native KAC/kOS flight
  confirmation remains pending; these are source fixtures, not native proof.
  Retrieved evidence `/tmp/ksp-minmus4-brake-alarm-20261027.json`.
- [ ] **Move fixed-site lateral correction into powered braking.** Native
  RO9-mun2 landingUT2956618.2, diagnostic2956003095/boot033 copied locally to
  `/tmp/kos-mun-landing-2956003/` (diagnostic + sidecar + boot031..034 +
  analysis.json). BRAKE lasts136.1s, ends1265m from guidance site, along-424m /
  cross1209m, bottom720m, hs1.5m/s, vs-20m/s. APPROACH then uses118.86s /
  ~205.176m/s sampled thrust impulse, descending720->183m. Total brake /
  alignment impulse~630.472m/s; terminal impulse~53.152m/s. Touchdown2m from
  refined site,638.8m from requested waypoint, intentional terrain shift640m;
  remaining vacuum dV1102.7m/s. Final targeting accuracy worked; late transfer
  is the efficiency problem. Source confirms _landingBrakeSteeringInfo calls
  velocity-only lmEconomyBrakeThrust; target cross-track is only returned for
  diagnostics afterward. CROSS_PID is constructed but unused in braking.
  Implemented lmBrakeLateralThrust shared by live/predicted fixed-site
  braking: geometric pursuit, up to15deg horizontal yaw, same vertical and
  total thrust, weaker-stage stopping-time scale, fade before18m/s handoff.
  Descent planning reserves cos15 authority. Target comes from cached site
  elevation, not repeated terrain queries or phantom TR impact steering.
  Native attitude/engine-up, terrain, stage/reserve and ignition guards
  remain; flexible/blind/divert/legacy paths are unchanged. The forecast now
  receives the actual body-fixed target. Staged3D cases reduce1.2km miss to
  101m (+4.02m/s impulse), +/-2km to237/235m (+9.62/7.77m/s); Minmus Flats
  single-stage1.2km becomes17m. Guided prediction agrees with independent
  inertial RK4/mass/staging physics within120m. Native flight validation is
  still open. Do not tighten the2km admission cap to hide missing feedback.
  Separately review terrain-shift policy if closer original-waypoint
  precision is requested.
- [ ] **Preserve BRAKE/APPROACH diagnostic samples through touchdown.** The
  bounded detailed-control ring retains mainly late terminal/settle rows;
  phase totals/transitions survived, but detailed earlier controls rotated
  out. Retain bounded representative first/last/per-stage control samples
  across phases without adding synchronous archive I/O during powered ticks,
  changing guidance cadence, or introducing hovering for export.
  Implemented a separate12-row/3000-character BRAKE history, sampled15s/on
  stage changes and exported through existing quiet-coast/touchdown gates.
  Includes lateral active/yaw/geometric cross/TR cross/alignment/throttle.
  Source tests prove it survives terminal ring eviction with no powered I/O.
  Representative APPROACH history/native recorder validation remain open.

- [ ] **Minmus final B-plane micro-correction must continue safely.** Native
  RO9_2815982 boot010 atUT3019581.9: Tundra arrivalPe~8.3km/inc116.71deg,
  converged0.0715m/s candidate was skipped, then the consumed final retry
  checkpoint wrongly blocked progression. Common planner now removes the
  tiny node, checks the unburned encounter/parent coast/required plane and
  capture+reserve fuel, then both phase handlers consume a fresh no-burn
  handoff instead of retrying. Retry state clears; SOI alarm is refreshed;
  no budget is charged/refunded. Default no-burn Pe tolerance is unchanged;
  explicit BPLANE_MINIMUM_PE_TOL1500 for Kolniya/Tundra matches their revised
  7.8..10.8km capture corridor. Required1deg plane and final100m/0.1deg SHAPE
  remain. Real phase/retry fixtures reproduce the0.0715m/s case in both
  profiles with/without KAC, including changed-patch and unsafe/fuel/plane
  rejection. Native connected reboot/resume remains unvalidated.
  All64 routine check files passed92.81s; final cached-elevation guidance /
  range/recovery/structural and minimum-handoff/midcourse/Pe/SOI checks pass.


- [x] **Fix false hull clearance and capped-direction deorbit stall.** Native
  UT2885788..2885817 reports hull2223..2358m, normal-10m/s and cross1458m
  inside the2km cap, but along-track residual-14489m; no-improving-step35/64.
  ALT:RADAR can fall back to ASL while bounds bottom radar queries terrain;
  subtracting them is not physical vessel size. Forecast now snapshots the
  bounding box once and uses its enclosing radius about CoM for every gate
  probe. Preserves future terrain/target and live bottom-radar safety. New
  geometric/legacy/origin diagnostics distinguish the measurements.
  Added measured retro-only fallback when coupled time/normal directions
  stall and hard cross-track is already acceptable; epoch/normal stay fixed,
  existing trust/fuel/normal/cross/trial/reserved-forecast/final checks remain.
  All62 routine check files passed in68.82s; final origin/radar diagnostics,
  invalid-bounds and full-forecast radar-invariance regressions also pass in
  targeted range checks. Native boot032 now confirms hull4.67m and stable
  lead~67197m across a long coast despite legacy radar offset1764->3207m.
  Predicted ignition2956310.2 vs actual2956311.5; landed successfully.
  Lateral-guidance efficiency remains open as a separate task above.
  Closest-pass ranking remains unchanged; preferring the earliest feasible
  window is still open.


- [x] **Wider Mun targeted deorbit cross-track, operator authorized.** At
  UT2885617.1, best rejected candidate cross1.563km already used normal-10m/s;
  the earlier departure window has passed. Existing profile setting raised
  from0.5km to2km for RO9 mun_landing_return only. Preferred250m, target
  coordinates, touchdown tolerance1500m and other physical/model/radio/fuel
  checks remain. Admission still requires fresh powered validation. Native
  boot032 accepted cross1917m; boot033 landed2m from the refined site, but
  BRAKE left1209m cross-track for APPROACH. The missing lateral guidance is
  tracked separately above; wider admission is not an efficiency fix. Targeted solver,
  variable-mass predictor and structural checks passed; boundary cases admit
  1563/2000m and reject2001m under the configured2km cap.


- [ ] **RO9-mun2 powered forecast changes during coast.** Native boot027
  retained footprint118214m/cross220m, but lead119365->126363m and ignition
  moved13.2s earlier. Initial residual-1152m passed; final-8149m held without
  thrust. Terrain-dependent gate is suspected, not established; new rows
  expose local terrain/target elevation/hull/ASL/vertical gate and ignition
  coordinates. Added300s pre-burn wake with bounded same-node retro-only
  refit (7 forecasts, 3 iterations, 5m/s step/10m/s change, original2..120
  retro bounds), unchanged fresh admission/terrain/radio/fuel limits and
  exact rollback on failure. Original90s final validation remains; another
  change holds. KAC precedes solar; no prompt exit on the scheduled wait.
  Executor refreshes impulse/timing after accepted refinement. Source cases
  cover reported8.15km drift with both response signs and rejection/rollback
  for invalid/cross/normal/fuel/terrain/radio/abort/deadline/committed/active
  thrust states. All62 routine check files passed in68.90s; final body-change
  stop guards also passed targeted solver checks. Native boot032 now
  establishes the radar-derived hull error and stable lead after887aa4d;
  that root cause is closed above. A native exercise of the bounded refit
  itself remains unconfirmed because this flight did not require one.


- [x] **RO9-mun2 powered validation starved by ballistic preference.**
  Read RO9_2518776 boot023: first valid seed cross368m/downfield13235m,
  retro31.78m/s/normal-6.26m/s passed hard500m cap. Search chased250m,
  consumed64/64 on worse later passes, then held withpoweredPass=0 and
  geometryReason=not-checked atUT2884581.6. Implemented shared stopping
  predicate: a powered mission hands off the first physically admitted /
  radio-accepted geometric seed; inner polishing also conserves those
  trials for mandatory finite-burn fitting. All hard limits and64-trial
  cap unchanged; no trial reset, tolerance widening or target change.
  New diagnostics expose seed/hard/preferred cross values, trials left and
  zero-forecast budget exhaustion. Synthetic reported-seed regression runs
  actual full outer/Newton/powered code: old policy64/64/no model checks;
  new33/64/four checks, with cross/normal/fuel/radio/model rejections retained.
  Complete landing remains unvalidated; native planning evidence follows.
  The operator subsequently removed the whole-descent cache/storage gate.
  All62 routine check files passed in75.50s;
  no new structural errors (existing missingksc_deorbit handler warning).
  **Follow-up:** latest boot023 on53e23f0 endsUT2871292.6. First pass stalls
  atcross736m/downfield12827m,retro32.33/normal-5; later passes worse;64/64.
  Added measured normal-only fallback after singular or non-improving coupled
  Newton response, only when already inside the downfield band. Time/retro
  remain fixed; existing5m/s step/10m/s total bounds, line search, fuel/lead/
  trial/reserved-validation limits remain. Diagnostics expose failed response
  deltas and accepted method. Synthetic nonlinear/singular/mirrored cases
  recover736m while preserving downfield acceptance; infeasible caps/budgets
  still reject. Real full-search source fixture improves64->16 trials and
  includes a mandatory powered check. All62 routine check files passed in
  71.50s; the final nonfinite-range guard also passed targeted solver checks.
  Native boot025 on88feef6 now succeeds: normal-only recovers736m cross to0m
  at18 trials; five powered forecasts converge in58/64 trials, final cross
  116m and modeled residual-1212m within1500m. Accepted node15.79m/s at
  UT2885483.33; no burn yet because the cache guard alone blocked ignition.
  This validates planning, not descent performance. Captured earlier retry log:
  `/tmp/kos-mun2-deorbit-2871292.log` (boot023 is overwritten by save reloads).
- [ ] **Reduce landing storage use without blocking deorbit.** Native
  RO9_2460361 boot026 had13,719bytes free; additional compiled landing /
  tracks / return files measured59,130bytes. After deorbit, radio loss left
  payload_landing unavailable. Operator declined further rescue commands.
  Whole-set cache admission was implemented, then explicitly removed at the
  operator's request accepting blackout risk. Both entry/ignition checks and
  unused landing_handoff helper are removed; normal post-burn library sync
  remains. Keep both dynamic LANDING tracks, conditional return provider and
  cached-track retention. Shared landing_radio defaults to direct Kerbin on
  Mun/Minmus with configurable relays; this independent site policy remains.
  Storage improvements are optional resilience work, not a new flight gate.
  Source checks verify uncached burns, normal band/track loading and unchanged
  physical/radio admission. All62 routine check files passed in65.12s; no new
  structural errors. Native descent with this layout remains open.
  No installed bootstrap update is required; use a connected reboot.
- [ ] **Aerobrake disposable fuel and pre-entry replanning follow-up.**
  Native boot027 spent370.31m/s and retained10.03m/s in stage3. After manual
  separation, stage2 DID forecast and burn619.27m/s, ending52.7km Pe/77.5km
  Ap; operator confirms landing. Implemented shared full hardware/fuel audit
  for zero active-stage reserve only with a funded successor. Final/unknown
  engines keep the10m/s minimum; the craft-wide live reserve always remains.
  Own and stock stage estimates must both fall<=1m/s before separation.
  Manual staging now wakes the resident pre-entry wait, verifies cutoff,
  refreshes KAC and replans. The same-pass attempt latch remains intact.
  Finite burns ending before entry refresh their alarm too: native stage2
  moved actual entry~399s beyond the old pre-burn alarm. Source checks cover
  full disposable fuel use, successor funding/identity changes, live reserve,
  both handoffs, original50 rejection cases, complete manual-stage phase
  progression and fresh post-burn alarms. All61 routine check files passed
  in61.66s; new individual cases took<=0.57s. Additional higher-reserve
  assertions passed in the final targeted staging check. Native automatic
  handoffs/new reserve/alarm behavior still need validation after a connected
  reboot. No live game controls or settings were changed.
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
  Combined source checks now cover this and the parking handoff. Native
  validation remains open; neither actual capture nor cache size is proven.
- [ ] **Tundra departure blocked by a parking node.** Native RO9_2815982
  boot003 reaches parking and advances at UT2816224.8. Boot004 XING at
  UT2816238.4 resumes a4.437m/s node with ETA-25.2s, pending=false and empty
  burn_phase. No transfer planning runs. Its missing Minmus patch is printed
  as PeKm=-0.001; this is not a solved Minmus periapsis. Likely MJ ascent is
  still finishing circularization when the loose parking gate advances.
  Implemented PARK wait for MJ ascent/circularization to finish, physical
  cutoff and final orbit recheck before advancement.120s timeout or Abort
  stops ascent and holds without deleting nodes. Native reboot found that
  Addon(MJAddon) lacks a top-level NODE suffix; removed that dependency and
  made the fixture omit it. DLL strings were insufficient API validation.
  Departure diagnostics now distinguish a missing target patch; no Pe
  corridor or Tundra target was relaxed. Source fixtures cover the reported
  orbit, delayed completion, retained foreign nodes, timeout/Abort/failed
  cutoff/degraded orbit, and existing departure corridor/refinement cases.
  Current probe: inspect/delete the expired node, REBOOT. Future launches:
  validate native MJ completion, node cleanup and XING planning after update.
  All59 routine check files passed in70.94s, including both capture and
  parking handoff regressions; structural audit has no new errors.
- [ ] **Deck kernel graphics-memory hang at uptime5039s.** Read-only
  inspection2026-10-27: SteamOS3.9.5 / kernel7.2.7-valve2. First warning
  gamescope-xwm1727 blocked122s, implying onset~4917s; dxvk-cs5232 shares
  amdgpu_gem_fault -> ttm_tt_populate -> ttm_global_swapout mutex wait.
  Kernel identifies dxvk-submit5230 as likely mutex owner; its stack waits
  in __drm_exec_lock_obj during ttm_device_swapout buffer eviction. Same
  stacks persist614s, then hung-task reports are suppressed. Strong evidence
  for a graphics-memory lock deadlock; exact defect/lock cycle not proven.
  No accompanying OOM-kill, kernel Oops or runtime GPU reset. Available RAM
  ~157MiB; zram full7.2GiB plus disk swap2.6GiB. Game5186 remainsD, RSS1.94GiB /
  swap7.65GiB. GPU reports GTT8.22GiB against8GiB budget, VRAM0.78/1GiB;
  GTT/RSS/system counts overlap. TTM pages_min=pages_limit=2097152. Do not
  increase these limits or swap blindly. Current vmstat/PSI activity is low
  after the stall; it does not disprove earlier allocation pressure. A ps
  memory query also stalled. Raw dmesg2552lines and structured report saved:
  `/tmp/ksp-deck-dmesg-20261027.txt`, `/tmp/ksp-deck-hang-20261027.json`.
  Next: verify applicable Valve kernel/TTM fixes and reduce measured graphics /
  texture memory demand; no specific patch or mod cause is established.
  No settings/process/power changes. Separate from the earlier Unity fault.
  Recurrence recovered after operator reboot: prior boot32952dec, first
  warning uptime8848.456s (20:22:26CET), gamescope-xwm14915/dxvk-cs16902
  blocked122s in ttm_global_swapout; likely owner dxvk-submit16900 waits
  in __drm_exec_lock_obj during GPU buffer validation/eviction. Same7.2.7
  kernel and lock-stack signature. Full previous journal saved2113lines /
  205603bytes to `/tmp/ksp-deck-previous-kernel-32952dec-20261027.log`.
  No OOM-kill/runtime GPU reset found in that complete previous-boot log;
  precise driver defect/mod cause remains unproven. New bootaa1c9c6e at
  uptime1862s already has RAMavailable121MiB, swap8.40GiB (zram full plus
  disk1.17GiB), GTT7.28/8GiB, VRAM0.78/1GiB. No D-state threads in the
  inspected KSP/gamescope processes then; DXVK waits are ordinary futex /
  poll. PSI memoryavg10~0.19%, so tight capacity is not proof of current
  active thrashing. Structured snapshot/thread waits/previous-kernel tail /
  vmstat saved `/tmp/ksp-deck-reboot-followup-20261027.json`. Old pending
  SSH inspection completed at uptime499s after reboot: RAMavailable9.68GiB,
  swap0, KSPRSS1.17GiB; asset loading/scene differs, not a proven leak.
  Current game already running; no game settings/processes/power changed.
  Low-impact follow-up re-read active settings/MM cache: stock texture
  quality already2, density0.15, Deferred SSR on/half-resolution, reflections
  already low; NoIVAplaceholder/MHdisabled remain. Texture-loader overrides
  reverted: active AsyncUploadPersistentBuffer=true, MaxTextureLoadMemory
  absent/automatic, upload buffer128MB. Recommend restoring false/256MB via
  a local MM override surviving package updates (same visuals; loading /
  allocation tradeoff; peak cap is not a resident-texture cap). Settings
  unchanged this turn. ShadowMan source hardcodes8192 but initializes before
  Scatterer, which is configured2048: startup log is NOT proof of effective
  8192 allocation. Verify runtime ownership before changing/counting savings.
  Optional next modest cut: disable Deferred SSR, keeping basic reflection
  probes/lighting. Reports `/tmp/ksp-deck-low-impact-settings-20261027.json`
  and `/tmp/ksp-deck-memory-overrides-20261027.json` preserve configuration.
  Latest crash21:25:22..23CET is now directly diagnosed: AMDGPU repeatedly
  reports amdgpu_vm_validate failed / Not enough memory for command
  submission (804 paired failures in final interval). gamescope1559 logs
  DRM flip ENOSPC / fatal flip error then SIGABRT at21:25:23; gaming session
  restarts and KSP exits. Game filesystem still has47.3GiB free; this ENOSPC
  is from display submission. No new Unity crash dump found (only09:20UTC
  report), Linux OOM-kill or same hung-task stack in captured interval.
  This establishes GPU allocation failure/compositor abort, not the exact
  mod/leak/driver allocation defect. Post-exit RAMavailable12.3GiB. Evidence:
  `/tmp/ksp-deck-latest-crash-20261027.json`,
  `/tmp/ksp-deck-gamescope-crash-20261027.json`,
  `/tmp/ksp-gamescope-kernel-end-20261027.log`,
  `/tmp/ksp-gamescope-core-info-20261027.txt`.
  Installed `docs/steamdeck/DeckMemory.cfg` with user authorization: loader
  false/256 plus Deferred SSRfalse. Source verifies ModuleManagerPostLoad
  reloads/applies KSPTL config; Deferred reads patched GameDatabase settings.
  Installed while KSP was closed at2026-10-27T20:47:44Z to
  `~/Kerbal Space Program/GameData/zzz_DeckTweaks/DeckMemory.cfg`; readback
  matches repository SHA256 c5c71cc281dcb50dc6e353f403eeda72949b12f1adbcc379517c8940a78bd291.
  Config snapshots/rollback manifest: `~/ksp-memory-backups/20261027T204744Z`.
  Post-reboot21:14..21:15UTC: fresh MM cache confirms false/256/SSRfalse;
  startup logs both FINAL patches plus KSPTL ModuleManagerPostLoad. Native
  RO9-minmus4 FLIGHT loaded; NoIVAplaceholder/MHdisabled also persist.
  RAMavailable0.485GiB, swap5.80GiB logical zram/0disk, GTT6.31/8GiB,
  VRAM0.83/1GiB. Memory PSI full avg10 declined15.28% to4.73% after loading;
  vmstat follow-up shows modest swap-ins/no swap-outs, not heavy disk churn.
  Current-boot journal has no matching allocation/hung-task/OOM/GPU-reset
  failure signatures. Settings applied, but memory headroom still tight;
  long-run stability and comparable-scene savings remain unproven. Evidence:
  `/tmp/ksp-deck-post-settings-verification-20261027.json` and
  `/tmp/ksp-deck-post-settings-settled-20261027.json`. Shadow resolution is
  deliberately unchanged pending actual runtime ownership verification.
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
  full staging-slot module audit, current-stage stock AND own-tank estimates
  <=1m/s, and next-engine fuel above the retained repair allowance.
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
  Native boot027 confirms a refreshed alarm/solar wake after the first exit;
  the new post-powered-arc refresh still needs flight validation.
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

- [ ] **Continue landing accuracy and efficiency validation.** Targeted
  landings must meet their locked target; economy sites may divert under
  their explicit policy. Validate powered-lead convergence, burn timing
  across stage changes and recovery without prolonged low-altitude hovering.
  Last source fixes: `6635266` and `90099ef`; new flight logs still needed.
  Rechecked live braking/flare/approach against the shared forecast: the
  validated fixed-site H deadline and response-aware approach fixes are
  present. Automatic archives already record stage hardware, control
  commands and cumulative per-phase impulse/time. Compare those on the next
  post-LAND_PREP descent before changing the controller again.
- [ ] **Continue ascent/return efficiency work.** Account for changing TWR
  across lander/return stages and compare direct Kerbin departure against
  parking-orbit insertion. Preserve entry corridor and fuel reserves.
  Explored a live-TWR/gravity-support pitch floor in a separate point-mass
  experiment. It did not change the tested nominal ascents, so it was not
  adopted or credited with savings. Existing pitch, staging and reserve
  policy remain unchanged. Stage-aware ascent optimization remains open;
  the existing per-stage acceleration/fuel trace is needed for flight review.

## Flight validation / measurements pending

- [ ] **Post-upgrade Deck memory observation,2026-10-27.** Both updates now
  verified: Parallax plugin1.0.6 and scatter textures1.0.5. During the newly
  solved Mun deorbit coast, available RAM470->638MiB, total swap7.38->7.33GiB,
  GTT6.32GiB steady (pre-hang8.22GiB). KSP RSS3.38GiB/swap5.61GiB at first
  sample; overlapping graphics counts must not be added. Six-second vmstat
  sample: no swap-out, modest164–376KiB/s swap-in, memory PSI avg10 zero.
  Improved compared with the hang, but <1GiB available is still tight; this
  is not a matched-scene savings benchmark or long-session stability proof.
  Snapshots:/tmp/ksp-deck-memory-after-20261027.json and
  /tmp/ksp-deck-memory-followup-20261027.txt. Effective shadow-map allocation
  remains the next visual-memory investigation. No settings or game-control
  changes made during inspection.
- [ ] **Next Deck memory reductions, recommendations only.** Verified CKAN
  baseline: ParallaxContinued1.0.4 with scatter textures1.0.3. Operator upgrade
  now verified plugin1.0.6 AND scatter pack1.0.5; operator completed both
  upgrades after the CKAN retry. Upstream
  release1.0.5 fixes a2GB scene-start VRAM spike and reports scatter usage
  800MB->74MB on Kerbin;1.0.6 is current. Update plugin AND matching scatter
  assets together before judging whether Parallax must be removed. These are
  upstream measurements, not promised Deck savings. Release notes:
  https://github.com/Gameslinx/Parallax-Continued/releases
  Next verify ShadowMan's logged8192 shadow request vs Scatterer2048 actual
  rendering ownership; cap the real map at2048, then compare the same scene.
  Further candidates: stock TEXTURE_QUALITY1->2 (half->quarter resolution,
  custom texture loaders may bypass), Deferred screen-space reflections,
  Parallax visual range/shadows. Scatter density already0.15; reducing it
  alone does not guarantee texture memory is freed. Keep NoIVA/mission-editor
  reductions. Do not sum GTT+RSS or equate asset-bundle disk bytes with RAM.
  No additional game settings or mods changed for these recommendations.
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

- [x] Landing-preparation reference comparison (operator priority3): added
  shared `landing_route` goals/cost math, read-only `cmd/landingroute.ks`
  direct-to-archive report and automatic pre-planning LAND_PREP diagnostics.
  Reports ideal direct/prepared descent, two ordinary transfer orders, return
  remainder, correctly scoped preparation reserve, periods and latitude
  crossing heights, plus optional gravity sensitivity using weaker measured
  descent acceleration. Kolniya reference:45.46m/s prep,226.03 vs230.14m/s
  ideal total, equatorial crossing60.36->13.96km, period20200->3028s.
  Advisory only: no automatic route selection or bypass of mission/survey,
  target longitude/terrain, staging, native powered footprint or fuel guards.
  All61 routine check files passed in79.41s; native report/flight still need
  validation. Continue landing/ascent efficiency next; stage/KAC confirmations
  remain pending from operator.
- [x] Minmus3 Kolniya orbital objective: operator confirmed success on
  2026-10-27. Keep100m/0.1deg final shaping tolerances,0.002m/s burn minimum,
  0.001m/s cutoff and9km Pe floor. Landing/high equatorial orbit/return remain
  separate objectives awaiting validation.
- [x] Cached-state caller audit: fixed final B-plane checkpoint consumption,
  landing-light replacement alarm and hop waypoint replacement/append. Each
  now copies its collection before mutation; shared state semantics, guards,
  budgets and scheduling policy are unchanged. Reviewed current lib/cmd
  collection reads and mutation paths; staging attempt marker is scalar,
  payload/solar/review reads are read-only, and existing LAND_PREP/survey/
  launch-window writers already copy or replace their records. New fixtures
  execute actual stateGet/stateSet, JSON reboot immediately before later
  writes, and removal of each fix to reproduce lost persistence. All60 check
  files passed in72.69s; the later MJ compatibility correction passed its
  focused handoff checks. Native occurrence in past incidents is unproven.
- [x] Emergency capture live interlocks and MJ parking-controller handoff
  implemented;59 routine check files passed. Native validation remains above.
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
