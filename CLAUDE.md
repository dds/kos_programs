# CLAUDE.md

Komptroller is kOS (KerbalScript) mission automation for Kerbal Space Program.
`README.md` is the operator manual — architecture, vehicles, mission profiles,
commands. This file is what you need to *work on the code* without breaking a
mission.

`TASKS.md` tracks current work, queued changes and outstanding flight checks.
Read it when resuming and update it when work is added, completed or blocked;
distinguish source-test results from native mission validation.

2026-10-27 Tundra/survey mission: RO9 minmus_tundra_survey_return requests
397272/9300m,116.6deg,LAN337,AoP270. User clarified3200-6600m are ABOVE
thresholds, not an altitude band. Use >6600m for every site, keep9km floor.
SCIENCE_OPS_RUN_ALL defaults1; this profile0 reserves empty thermometers at
orbital holds. Operator explicitly removed the prelaunch thermometer/storage
gate and its survey_hardware helper; do not reinstate it.
ORBITAL_SURVEY owns a separate band, shares lmGroundGeoAt/coast_wait/solar/
cutoff, never maneuvers. Survey-first retains the broad retrograde plane;
LAND_PREP lowers Ap once. Five coords and landing coords are separate.
1km overhead radius is explicit policy, not a discovered contract radius.
Stock ScienceExperimentModule DEPLOY/HASDATA/RERUNNABLE and retained
ScienceContainerModule COLLECTALL are documented APIs. RESET only after
HASDATA becomes false; a declined duplicate must remain intact, using another
sensor or holding. Observed deployment is NOT a contract completion API.
After five observations advance only to SCIENCE_OPS_LOW/manual tick review.
Copy nested DONE list before mutation/stateSet. KAC before solar on every
resident wait; no-KAC remains a clock wait. Native APIs/flight still unproven.

2026-10-27 generic landing preparation: LAND_PREP -> landing_orbit is a
dedicated band sharing orbit_shape/maneuver/roles/coast_wait. It changes the
special orbit into a low landing parking orbit, independently of target
selection. Default automatic Pe preserves an already-low safe Pe; Ap is10km
higher. Retain the current plane unless LAND_PREP_INC/LAN is explicit; use
real plane intersections through shapeNextBurn, never assume Ap is a node.
Scope planner tolerances/floor/minimum and BURN_STAGE_LIMIT, restore them on
every normal return, and keep the original SHAPE goals/ledger untouched.
land_prep_budget stores context, spent, owned node UT and reserved cost in
one state update. Before mutating a stateGet Lexicon COPY it: stateGet returns
the cached object and stateSet can suppress a flush of that same object.
COPY is shallow; nested edits need separate copies. Owned unflown nodes
resume without double charging; started burns hold until explicit shaperetry
(now SHAPE or LAND_PREP, same body/node/idle guards). The phase never removes
foreign/started nodes. Only its newly rejected unflown node is removed.
Generic completion precedes target-specific deorbit checks. Inflight missions
already in LAND_DEORBIT route through their newly added LAND_PREP when the
flight/body/mission ready marker is missing; committed descent is untouched.
Check the next band's full local closure without loading it here; use the
shared KAC-before-solar clock wait for a missing-link cache handoff. New
phase loading requires a connected boot, no installed bootstrap update.
Minmus3 boot021/022 already in9.3x397.2km/i63.39 got repeating~40.2km site
misses. Generic defaults with9km floor produce9.3x19.3km/i63.4 (~45.5m/s,
period20200->3028s in the ideal fixture). Its deorbit geometry survey now
considers48 passes;4096 geometry/64 native trial caps remain. Source fixtures
do not prove native cache size, plane execution or final targeted touchdown.

2026-10-27 return audit: native RO9_2446359 boot019 UT2783434 entered
AEROBRAKE at Kerbin Pe53.135km/Ap35038.7km. Its generated local profile
saved AP_BURN0 (despite craft default1), descent_decoupler at6km; actual
saved hardware has only return_decoupler stage1 and lander_decoupler stage2,
both attached, and retained descent_chutes/CPU. aeroassist now accepts an
optional final-descent tag, validates attached separator/CPU/chutes and
stopped controls before saving ONLY policy/tag overrides. Does not stage,
ignite, reboot or change altitude/phase. Final separation is still AFTER
AEROBRAKE's captured/slow handoff. Between-pass staging now has its own
`aerobrake_staging` library, outside the powered controller. RO9 approves
only its two named boundaries; other vehicles default to an empty list.
At the next entry-prep wake require bound orbit, off rails, >1km above atmo,
>60s entry lead, corridor/pressure/idle controls, adjacent tagged separator,
retained CPU/chutes, one conventional departing/arriving engine and audited
slot modules. Native Part:STAGE also labels inert tanks/legs, so a part-count
whitelist is wrong. Recognize their known passive modules; only permit
main_fairing deployment on the discarded side, never retained protection.
Require both stock and own-stage mixture dV near the repair allowance,
and next-stage mixture fuel above it. Verified cutoff precedes persisted
one-attempt-per-separator UID and STAGE; recheck context/hardware after state
I/O, verify retained-vessel identities without reading detached part suffixes,
hold on failure and never repeat a recorded event. Refresh KAC before fresh
next-stage planning. No in-atmosphere handoff or same-pass burn rearming.
Serialize tag policy through both generated return legs; native staging and
compiled size remain unvalidated. The legacy emergency capture burn has a
separate alignment/watchdog gap queued in TASKS.md; do not confuse its
unconditional throttle lock with the guarded optional assist.
Native solar panel is supported ModuleDeployableSolarPanel, so unavailable
was not Kopernicus renaming: bootPlannedMissionLibs runs BEFORE the craft
adds solar via LIBS_EXTRA; generated return profile lacks that extra and
old AEROBRAKE closure had no solar. Declare it explicitly in dependencies,
not a bootstrap workaround. Warning now distinguishes missing helper/panels.
After atmospheric exits/capture burns, refresh the owned entry alarm using
aerobrakeApEntryEta and use the same crossing for solar preparation. Initial
and post-correction setup share that helper. Native stage sequence, next-pass
alarm and solar attitude still require flight validation; see TASKS.md.

## The language (kerboscript, `.ks`)

Looks like Python/JS; is neither.

- **Every statement ends with a period.** Forgetting the `.` is the #1 error.
- `SET x TO v.` assign · `LOCAL x IS v.` declare · `PARAMETER p.` args
- `LOCK x TO expr.` binds to a live expression (re-evaluated every tick);
  `UNLOCK x.` releases. `LOCK STEERING` / `LOCK THROTTLE` fly the ship.
- `WHEN cond THEN { ... }` is an async trigger; it runs **once** unless the
  body executes `PRESERVE.` (or returns true).
- `LEXICON()` = dict, `LIST()` = array, `delegate@` = function reference,
  `:CALL()` invokes one.
- Identifiers AND string comparisons are case-insensitive — never add
  `TOUPPER`/`TOLOWER` just to compare.
- **No escape sequences in strings.** `"\""` is a syntax error (flight-found)
  and there is no way to embed a double quote in a string literal. When
  printed text needs quotes, use single quotes (`PRINT "RUNPATH('0:/cmd/x')."`)
  — or `CHAR(34)` concatenation if it must be exact.
- **Never use bare `r`, `v`, or `q` as variable names** — they shadow the
  `R()`/`V()`/`Q()` rotation/vector/quaternion constructors. Use `rMag`,
  `rVec`, `vel`, `res`, etc. Be equally careful shadowing bound names
  (`up`, `north`, `body`, `target`, `alt`, `eta`).
- `LOCAL FUNCTION` is file-private; `GLOBAL FUNCTION` is exported to the
  whole CPU. Use `@LAZYGLOBAL OFF.` in new libs.
- **Wrap every command's executable body in a `LOCAL FUNCTION` and invoke
  it once at the end of the file.** Keep script `PARAMETER` declarations,
  directives and global defaults at file scope; put bootstrap/loading and
  command logic inside the entry function, with helpers nested as needed.
  Apply this to executable archive helpers such as `lib/burn_check.ks` too.
  `RETURN` is legal only inside a function or trigger, never at file scope;
  an `IF` or loop does not make it legal. Flight-found: `burncheck` failed to
  compile because its archive helper had guarded top-level returns
  (2026-10-16). `make check` now enforces command wrappers and return scope.
- No exceptions; errors crash the program. Guard division, `ARCCOS`/`SQRT`
  domains, and `NORMALIZED` on possibly-zero vectors.
- **Coordinate frames are treacherous.** KSP's frame is left-handed and
  conventions (e.g. `FACING:ROLL` range, orbit-normal direction) are easy to
  get wrong from memory. House pattern: derive signs **empirically at
  runtime** — build both candidates and pick the one matching a measured
  reference (see `_normalMirrorSign` in `lib/orbit_shape.ks`, the rotation
  sense probe in `planPlaneMatch`, `HDG_BANK_SIGN` in `lib/airplane.ks`), or
  use cross-product-free identities and numeric differentiation of
  `POSITIONAT` (see `lib/arrival_bplane.ks`).
- **Never use `VELOCITYAT` to plan a future burn.** Its frame is offset
  by the body's own motion between now and t — flight-proven ~62 m/s at
  the Mun over a 2148s ETA, enough to flip a planned apoapsis burn
  retrograde. Use the numeric `POSITIONAT` derivative (`_velAt` /
  `_velMagAt` in orbit_shape/maneuver). The error hides at periapsis
  (drift ⊥ fast velocity) and bites at slow, far-future burn points.
  Corollary: `nd:ORBIT` (the game's own node propagation) is
  trustworthy — refine against it rather than against predictions.

## Hard constraints

1. **Storage**: OCTO cores have 10,000 bytes; large cores ~100 KB. Source is
   compiled to KSM before upload, so comments/whitespace in `.ks` are free —
   only compiled size matters.
2. **No archive in flight**: outside KSC link range nothing can be fetched
   from `0:/`. Anything a mission may need offline must be loaded at boot;
   operator commands are archive-only and require a link.
3. **Reboots happen** (power, quickload, scene change, band reload). Every
   phase must be resumable from `1:/run/state.json` via `stateGet`/`stateSet`
   — never raw file I/O for mission state.
4. **`boot/boot.ks` is initially installed in the VAB.** Changes to it require
   an installed bootstrap update; syncing `boot_lib` alone cannot change its
   top-level actions. `cmd/updateboot.ks` compiles the archive source in kOS,
   copies to an alternate local boot slot, then selects CORE:BOOTFILENAME.
   It requires a link and zero physical/raw/pilot throttle, preserves the old
   selected file, and leaves reboot timing to the operator. Other code
   (including `boot_lib`) re-syncs at connected boots.
5. **Bands load the libraries of EVERY phase in the band**, not just the
   mission's. Code used by only some missions goes in its own phase/band
   (costs those missions one reboot; costs everyone else nothing) —
   `payload_release`, `duna_ike_setup`, and the split landing tracks are
   worked examples.
6. **There is no kOS compiler or KSP flight runner here.** `make check` runs
   structural and source-driven Python fixtures; `make audit` reports band
   complexity and unresolved handlers. These supplement syntax inspection
   and flight testing in the game, not replace them. Be
   conservative in mission-critical paths, log generously (`STATS` lines),
   and prefer self-correcting loops (re-measure → re-plan) over open-loop
   precision.
   Routine individual checks should take less than one second. Optimize the
   fixture harness before reducing frequency; preserve assertions, integration
   steps and tolerances. `make check-times` profiles files and individual calls;
   `make check-all` includes the explicitly requested `make check-slow` pass.
   Run that full pass when changing the direct-ascent predictor or its harness.
   The routine pass retains direct-return context, conic and orchestration checks.

## Architecture in one screen

- **Boot**: `boot/boot.ks` → syncs `boot_lib` + `dependencies` → preamble
  libs → EVA/`CORE:TAG` routing (`roles/`) or vehicle script (`craft/`) →
  selected mission id persisted in state; profile copied to
  `1:/missions/<vehicle>/` and run as planning `SET` overrides → mission
  phase band synced/compiled/run → vehicle defaults/main loaded → profile
  re-run so mission/body overrides win → stale terminal input drained,
  post-boot manual-mode window → resume. Boot replans band libs every time;
  do not persist derived lib lists such as `lib_band_libs`.
- **Phases**: profiles own `SEQUENCE`; `runPhases(map)` dispatches by the
  persisted `phase` key; handlers call `nextPhase(seq)`. Sequences cannot
  repeat a phase name (lookup is by value) — multi-hop routes use the `GOTO`
  continuation phase instead. Shared handler naming convention:
  `PHASE_NAME → phasePhaseName`, bound by `lib/dependencies.ks` after the
  phase's band is loaded.
- **dependencies.ks sections**: `dependencyLibs` (including the `core` preamble),
  `dependencyPhases`, `dependencyBands`, plus the phase-handler binding
  waterfall.
- **Missing handler** in `runPhases` ⇒ band-change request (`reload_*` state
  + reboot), not an error — that's the progressive-loading mechanism.
- **Vehicle contract**: craft scripts `SET` hardware defaults and expose
  `main()`; profiles own phase/library planning and final mission overrides.
  Role scripts may still expose `bootVehicleLibs()` for profile-less support.
  Runtime config overrides live in `1:/run/mission_overrides.ks`, which is
  an ordinary `SET NAME TO value.` script applied after the mission profile.

## Map of the important code

| Area | Files |
|---|---|
| Boot/loading | `boot/boot.ks`, `lib/boot_lib.ks`, `lib/dependencies.ks` |
| Phase machine | `lib/phases.ks`, `lib/resume.ks`, `lib/state.ks`, `lib/logs.ks` |
| Ascent | `lib/launch.ks` (MechJeb), `lib/countdown.ks` |
| New maneuver pipeline | `lib/goto_plan.ks` (routing), `lib/arrival_bplane.ks` (B-plane MCC/refinement), `lib/orbit_shape.ks` (closed-form shaping), `lib/maneuver.ks` (node execution), `lib/maneuver_plan.ks` (single-burn planners — split out so burn-only bands like BPLANE/SHAPE skip the planner weight) |
| Transfer planners | `lib/xfer_plan.ks`, `lib/maneuver_transfer.ks`, `lib/maneuver_intersystem.ks`, `lib/lambert.ks`, `lib/lib_bplane_math.ks` |
| Legacy/rescue maneuver libs | `lib/maneuver_targeting.ks`, `lib/maneuver_orbit.ks`, `lib/maneuver_rendezvous.ks`, `lib/maneuver_mcc.ks` |
| Payloads/landing | `lib/payload_ops.ks`, `lib/payload_release.ks`, `lib/payload_landing.ks`, `lib/landing_main.ks`, `lib/landing_deorbit.ks`, `lib/deorbit_targeting.ks`, `lib/aerobrake.ks`, `lib/descent.ks` |
| Duna/Ike | `lib/duna_ike_setup.ks`, `missions/FalconHeavy/duna_*` |
| Atmosphere craft | `lib/airplane.ks` (assists + `airplaneMain`), `lib/ssto.ks`, `lib/drone.ks`, `lib/rover.ks` |
| Telemetry | `lib/observe.ks` (archive-first), `STATS` lines in every planner |
| Operator | `cmd/` (see README table); `cmd/airtest.ks` is the assist tuning card |
| KSLib vendored | `lib/lib_navigation.ks`, `lib/lib_circle_nav.ks`, `lib/lib_enum.ks` |

## Conventions

- 4-space indent, no tabs. File header: `// ====` block with name, purpose,
  archive path.
- `LOCAL FUNCTION _name` private (underscore), `GLOBAL FUNCTION camelCase`
  public. (Some pre-refactor GLOBALs in `maneuver_targeting.ks` still carry
  underscores — rename when that solver is retired, not before.)
- Logging: `mLog` info, `mLog("STATS ...")` persisted decision metrics,
  `mLogError` + `yieldToPrompt()` for operator-needed halts. Phases log a
  `STATS ... setup` and `... result` pair. Logs are per-boot/per-core
  (`boot_###_<core>.log`). STATS and non-INFO events are saved by default;
  full INFO chatter is opt-in via LOG_INFO_TO_FILE. Respect the local
  LOG_FILE_RESERVE_BYTES budget; keep per-tick diagnostics out of STATS.
- **Config is globals, not a safety wrapper.** Defaults live as `GLOBAL X IS`
  declarations in the file that owns the behavior, craft/profile scripts
  override with `SET X TO value.`, and libraries read `X` directly. Boot may
  run the selected profile once to discover `SEQUENCE` / `LIBS_EXTRA`, then
  runs it again after the selected library band loads so profile values win.
  Do not add
  `CFG:HASKEY`, string-key config helpers, `TOUPPER`/`TOLOWER` comparison
  wrappers, or defensive "optional config" layers. If a config symbol is
  wrong or missing, crashing loudly is better than hiding a latent mission bug
  behind bloated fallback code; git blame and flight logs are the debugger.
  If a config name would collide with a kOS global, add a trailing underscore
  (for example `TARGET_`) to mark it as ours.
- Parts are found by VAB tag (`SHIP:PARTSTAGGED`), never by index.
- Retry pattern for burns: plan → `executeManeuver()` → on failure wait,
  replan, cap attempts at `MAX_RETRIES IS 5`. **XING exception:** once
  `burn_started` is persisted, a failed/reboot-interrupted departure must
  preserve its node and hold (or accept a valid arrival handoff), never
  blindly plan another parking-orbit departure. Stage transitions happen
  inside the same executor call and retain the original node/progress.
  A late zero-thrust sample must re-enter recovery, never bypass staging
  with a no-thrust abort. The bounded automatic stage sequence falls back
  to a live manual-recovery wait. After a terminal hold, only the explicit
  `cmd/resumeburn.ks` request permits XING to continue the retained node now.
  `burn_departure_*` survives burn cleanup and is cleared only after
  `nextPhase` saves the phase beyond XING. On reload, inspect the actual
  encounter first; never interpret a cleaned-up flown departure as unflown.
  Release throttle/steering locks after cutoff before archive log I/O.

## Working in this repo

- Mission profiles are KerboScript files in `missions/<vehicle>/`; each is a
  list of `SET NAME TO value.` statements.
- Console instructions must use runnable `cmd/` scripts for library helpers.
  Embed calls such as `missionOverrideClear()` in a script that loads its own
  boot preamble; do not ask the operator to call them at the console after
  another script exits.
- Launch timing: PRELAUNCH chooses/persists `launch_window`; the small
  shared `launch_window` library waits after LAUNCH has loaded. Do not wait
  until the window and then reboot. `LAUNCH_PLANE_LEAD` calibrates ascent
  geometry only; PARK's `planeErr` and planned/actual liftoff UT are the
  calibration evidence. Launch-east-now clears timed-plane intent.
- Boot/storage mental model: state must preserve intent, not bulky derived
  products. Persist `mission_id`, `phase`, runtime progress markers, and
  reload intent. Do not cache computed band libs. If an upgraded vessel is
  wedged by old state, `RUNONCEPATH("0:/cmd/trimstate.ks").` removes the stale
  `lib_band_libs` key without loading the full boot stack. In-flight leg
  setup that defines a whole next mission (e.g. `return_setup`) must create or
  copy a compact local profile at `1:/missions/<vehicle>/<id>.ks` using literal
  `LOG "SET NAME TO ..."` lines for dynamic runpath/flight values — boot
  already RUNPATHs that for the selected `mission_id`. Short-lived overrides go
  in `1:/run/mission_overrides.ks`; the override file is rewritten as a full
  current override set, not accumulated as state.
  Craft/roles/archive profiles must use `bootLibSync`, just like libraries.
  Execute explicit local `.ksm` paths first; accept `.ks` and extensionless
  legacy craft files offline. The old installed bootstrap raw-copied craft
  to `1:/craft/RO9`, while its resolver required an extension, causing the
  reported empty-main offline boot. Updating boot_lib fixes discovery;
  updating the installed boot fixes uniform craft compilation. Normalize
  both `.ksm` and `.ks` cached mission IDs, and invalidate stale `.ksm` when
  regenerating a local source profile. Do not compile mission_overrides.
- Transfer-planning mental model: for
  `XING,BPLANE,COAST_1HALF,REFINE_BPLANE,COAST_2HALF,CAPTURE,SHAPE`,
  `XING` must produce a real target SOI patch, but it should not be treated
  as the owner of exact arrival plane/AoP. `BPLANE` can correct a rough
  hyperbolic encounter using smooth B-plane coordinates; it cannot repair
  a non-encounter. When debugging local Minmus transfers, first check
  `STATS local-transfer ... patch=` and `STATS soi-refine ... finalPatch=`.
  If `patch=False`, element targeting will report `no-patch`/`PeErr=10000km`
  because it has no target-body orbit to measure, not because the requested
  final orbit is impossible. Patch-chain searches are direct-transfer by
  default: a wrong-body intermediate encounter (for example Mun before a
  Minmus target) is rejected unless `ALLOW_GRAVITY_ASSIST=1` is explicitly
  configured for future assist planning.
  Local `XING` scans `TRANSFER_SCAN_LOOKAHEAD_HOURS` from now (default 6h),
  capped by `TRANSFER_SCAN_STEP_MINUTES`, so missed-burn rescue replans do
  not search whole high-orbit periods before trying a correction.
  Local XING refines the selected departure to CAPTURE_PE with a three-axis
  minimum-norm Pe solve, then requires positive Pe within TRANSFER_PE_TOL
  (default 2 km). Broad encounter seeds cannot bypass this final gate, even
  with BPLANE downstream. Saved unburned nodes pass the same check; flown
  departures retain existing recovery/handoff rules. Arrival-plane precision
  remains downstream. TRANSFER_DEFERRED_INC_ERR_TOL (45 deg) only influences
  raw seed scoring; do not confuse that with a validated arrival-plane budget.
  Interplanetary `XING` uses Lambert seeds; validate against KSP patch
  creation, ejection dV, escape Pe, and departure/target body frames before
  trusting any analytic score. If a Lambert burn is already near complete,
  hand it forward instead of replanning against an escape trajectory.
- Landing mental model: `LAND_DEORBIT` is its own band and only gets the
  deorbit solver; powered descent lives in `landing_main` plus dynamically
  loaded tracks (`landing_coast`, `landing_brake`, `landing_terminal`).
  Keep it that way. The target is the real landing site, while the deorbit
  solver deliberately aims a downfield phantom impact to preserve braking
  authority. `docs/LANDING_TARGETING.md` is the current design note.
  Economy sites use `landing_light` for future surface Sun/Kerbin geometry;
  `solar_axis` is a ship-frame panel axis, never a geographical Sun vector.
  BODY prediction uses a future local orbit about the CURRENT parent center:
  subtract `bdy:BODY:POSITION` from `POSITIONAT(bdy, ut)`, then accumulate
  parent orbits to a common root (`_landingBodyOffsetAt`). Subtracting two
  raw BODY predictions at different hierarchy levels injects parent motion.
  The old light fixture missed this by moving all bodies together; nested
  native-frame fixtures must preserve the Mun's tidal-lock radio invariant.
  Morning/afternoon Sun preferences never override the direct Kerbin gate.
  Preserve unrelated overrides with `missionOverrideUpdate` when changing
  a target/policy. `cmd/landlight` previews/applies only from an unflown moon
  parking orbit; retained deorbit nodes still pass the executor's light gate.
  An automatic light/radio no-site result must remain in a RUNNING solar
  coast, never a KAC alarm plus yield/Godspeed. landing_light_wait owns only
  context-bound wake intent, not a cached site. The optional forecast mode
  in landingLitGroundTrack is bounded512 samples over a long horizon and
  only estimates a retry; rerun the normal local search at wake. The shared
  coast_wait stayInBody mode stops on departure/new node/unsafe orbit;
  normal arrival waits retain their target-entry termination. Install KAC
  before solar, keep no-KAC clock polling/health checks, and preserve the
  original body across solar setup. Manual landlight apply clears wait
  state/alarm, preview never waits. New code needs a connected boot to cache
  landing_light_wait and its manifest; no installed bootstrap change.
  Flight-found follow-up: ABORT is a persistent KSP action group, not a
  reboot-cleared script flag. An active group skipped the selector's UNTIL
  loop before any search STATS, but the caller misreported a light failure.
  LAND_DEORBIT now explicitly pauses at entry when Abort is on; NEVER clear
  it automatically. Instruct the operator to PRINT ABORT., then deliberately
  SET ABORT TO FALSE. and REBOOT. when ready. Selector revision/admission
  reasons distinguish cancellation, safety rejection and an actual no-site
  result; do not weaken guards based on a generic no-target message.
  RO9's fixed-site Mun profile now explicitly enables normal deorbit10m/s,
  preferred cross250m/maximum500m. The old implicit zero cap applied even
  though economy profiles already opted in. Keep its target lock and do not
  enable flexible/economy landing or waive night/radio policy implicitly.
  Deorbit candidate order is angle-first across windows, so early windows
  cannot consume all trials on their alternate angles before later passes.
  Keep the global64 budget; no guarantee all8 windows receive native trials.
  The fixed-site profile also opts into a geometry-only pass survey over one
  surface rotation (TARGET_DEORBIT_PASS_LOOKAHEAD_ROTATIONS=1, default0).
  Keep the closest scanOrbits minima, anchor each pre-pass window to its UT;
  auto-picker pass context bypasses the survey. Eight consecutive polar
  orbits can all miss after the usable burn for a just-overhead site passed.
  Survey max4096 coarse geometry samples plus bounded minimum refinements;
  no trial nodes. Far-range seeds get six bounded improving-only scalar
  retro steps before coupled timing/normal refinement, within the same64
  budget. Long node coasts install KAC before solar and stay resident.
  Targeted new/retained unflown nodes supply fresh admission callback after
  coast; do not remove terrain/fuel/light checks or change the site to fit a
  bad pass. deorbit_burn declares coast_wait for offline solar availability.
  Native UT2477634 retained-node report: target44.593/-24.926, dv38.5,
  ETA40005s, new powered aim82706m versus actual downfield62904m/cross50m,
  captureDownfield-19808m. Operator thinks it predates a code update and
  explicitly requests replanning. Treat that as a legitimate model admission
  rejection, not proof the new forecast is wrong; do not waive the~20km miss.
  cmd/deorbitretry removes ONLY the next unflown node and vessel Deorbit burn
  alarm, preserving target/phase/mission/return/overrides. Requires stable
  moon orbit, no deorbit or interrupted-burn marker, Abort clear, physical/
  raw/pilot controls zero before/after settling warp. No automatic reboot or
  burn; operator runs it then REBOOT. Additional nodes remain for review.
  Retained-node refusal must recommend this command, NOT landlight apply:
  that command intentionally chooses another site. Admission logs now include
  required aim/min/max/residual plus node UT/dV. New source guards/byte-exact
  state-preservation tests do not prove native landing accuracy.
  On exhaustion print STATS deorbit best-rejected with geometry/light
  reasons, window, both burn components and actual downfield/cross/FPA/Pe.
  Powered RO9 fixed-site Mun landing now opts into LANDING_STAGE_BRAKE_CREDIT1
  and LANDING_ECONOMY_BRAKE1 while retaining FLEXIBLE_SITE0 and geographic
  gates. Only flexible sites suppress H/overshoot gates; descending control
  must not implicitly waive a fixed target. landing_stage_brake is a shared pure budget library; neither it nor the
  shared brake math may pull the landing FSM into the orbital band.
  Credit only bounded current-stage impulse: single controllable engine,
  adjacent serial discard, enabled local tank mixture, rocket equation and
  stock dV minimum. Unsupported/empty/unknown/atmospheric cases fall back to
  the whole weaker-stage stop. Keep full gravity,80% net reserve, separate
  reaction/staging pauses, clearance and live attitude/cutoff guards.
  PLAN_ACC remains the weaker stage; logs expose brakeStageDv and flags.
  Native UT2517847-2518232 fixed-site Mun report: dr18966/Hbrake19046,
  hs525.5,Veta22 but Hsupptrue; ignition dr13189/Hgate19171,~6km late.
  Old V-ETA20s arming suppressed a valid independent modeled H deadline.
  lmHorizontalBrakeGateArmed now shared by flight/planner: valid mass/fuel
  powered fixed-site ranges arm independently; legacy/invalid models keep
  old high-altitude guard, flexible economy still suppresses geography.
  V envelope/attitude/terrain/fuel guards unchanged. hModel logs evidence.
  Same flight ended BRAKE at4960m miss/594m control height/hs0.4/vs-19.6;
  APPROACH then slowed10.3->4.3m/s as its3km altitude ramp shrank, while its
  triangle-time descent estimate ignored that cap. Powered fixed-site recovery
  now uses signed accelerate/cruise/brake timing, response-aware stopping
  distance and coupled stopping-height cap; descend only through surplus
  height and compensate tilt. Keep55m/s/30deg/20% reserve/throttle bounds,
  unchanged final slow corridor and target tolerance. Safe terminal BRAKE
  handoff permits residual<=18m/s only after vertical capture, not during
  unsafe flare. Legacy/flexible approaches retain prior policy.
  Flat constant-thrust source replay:148.5s/283.9m/s impulse vs1166.5s/1923.5;
  target/speed tolerance unchanged, signed/cross starts checked. This is NOT
  native terrain/attitude/mass/fuel or precision-landing validation. A5km miss
  from600m with nearly zero lateral speed cannot be recovered on gravity
  alone: fix the main burn timing first, do not waive the requested site.
  Recovery-only math ships inside landing_terminal's dynamic track, not
  landing_math/orbital planning. Only the cheap H-arming predicate is shared.
  ECONOMY_BRAKE's stopping geometry must match its controller regardless of
  STAGE_BRAKE_CREDIT: full vector above APPROACH_HSPEED, original flare below.
  The separate credit flag controls measured fuel only. Both RO8/RO9 economy
  moon profiles now opt into bounded credit; do not enable POWERED_LEAD or
  disable fixed-site geographic gates just because a mission uses this control.
  Automatic solar orientation validates the cached axis against its saved
  measured peak before searching; reserve forced searches for explicit requests.
  Scheduled mission waits must stay in the running coast loop. KAC KillWarp
  alarms do not restart scripts or resume yielded phases. Early unconverged
  optional B-plane trims with a safe future airless encounter hand off to the
  existing COAST_1HALF/REFINE_BPLANE pair, preserving the midpoint and all later
  burn/plane/fuel gates. Do not replace that with a review alarm plus prompt
  exit or an unrelated indefinite solar hold (operator correction,2026-10-20).
  Pre-SOI coast safety is the parent orbit's clearance/direct encounter and
  a finite wake before arrival; do not apply the target review Pe floor to
  that wait. The actual 8.44 km Mun Pe excluded the previous automatic path.
  A parent Pe inside its atmosphere can also be safe until a moon encounter:
  prove encounterETA+SOI_BUFFER_TIME < time to inbound atmospheric crossing
  using the current ellipse and ETA:PERIAPSIS. Never substitute future Pe
  alone for that timed proof. Unknown/current-entry hazards still reject.
  A converged node skipped by the shared minimum must also keep its mission
  retry: early BPLANE hands to midpoint; REFINE waits/replans later. Do not
  turn that skip into finished-outside-required-corridor or waive the plane.
  Later full-solver failures use the same solar/clock wait from coast_wait,
  then one final check at entry-BPLANE_FINAL_REFINE_LEAD (default900s), bounded
  by SOI/burn margins. Do not repeatedly halve the remaining time: the operator
  reports4-5 wakes on one Mun trip. Persist waiting/completed checkpoint bound
  to mission/launch/phase/target; boot waits BEFORE a full solve, and ETA jitter
  cannot recreate a consumed final check. Explicit replan/flown corrections
  clear it and its alarm. retry-resume logs solvingNow=True; retry-blocked
  logs after=<rejection>. final-refinement-checkpoint-used can legitimately
  follow a second below-execution-minimum result; it alone does not prove
  a skipped wake. Do not add repeated timers or bypass the shared0.3m/s floor.
  Operator correction (2026-10-22): ARRIVAL BLOCKED must print its reason,
  settle warp at1x and yieldToPrompt, preserving the phase. Do not wait in an
  UNTIL ABORT loop or start a tail solar hold; the operator needs Godspeed
  without toggling the persistent Abort action group. Timed ARRIVAL RETRY
  stays live and automatically wakes; only blocked arrival failures yield.
  Mission admission/window failures yield for intervention; previews/explicit review/interrupted
  burns retain their manual policy. Never accept an unconverged required
  plane just to keep the phase machine moving.
  SOI alarms are separate from midpoint/final retry alarms. Create/refresh
  the native encounter alarm in BPLANE, after successful/partial corrections
  and before coast/solar waits; retry cleanup must leave it intact. Check
  actual KAC TIME as well as saved soi_alarm_ut before reusing an ID: the
  old ensureSoiAlarm fast path bypassed generic expiry checks. Arrival waits
  remove SOI alarms after crossing; no-KAC paths still poll the clock/body.
  Shared coast waits must discard inherited warp on entry and settle at1x
  on every exit. Auto-warp needs the wait's own nonempty, future alarm ID;
  an unrelated future alarm cannot protect a missing/expired wake alarm.
  Clean midpoint health alarms even when warp is declined. User-directed
  hop surface review is explicitly manual: settle2s, set brakes, print
  local RUNPATH("1:/run/hop"[,"waypoint"/"return"]) commands, then yield at1x.
  No N/R listener, invented departure alarm or solar pointing. The local
  prompt script reloads cached libraries/settings: kOS forbids calling a
  program's user functions from the terminal. Actions recheck surface/body/
  Abort and applicable fuel/terrain before rebooting;
  hopReturn starts economy Kerbin return through existing safety gates.
  Timed waits, operator review, and short attitude/
  powered-control ticks have different purposes: do not add KAC to every WAIT.
  Both solver modes must share pre-SOI node creation: settle warp, cap the
  configured node epoch at native entry minus SOI_BUFFER_TIME minus1s,
  require BPLANE_EXISTING_NODE_MIN_ETA lead, then recheck lead/solved entry
  before admission. Do not accept the node's current target-body patch as
  a workaround: that silently changes the correction frame and entry epoch.
- Duna/Ike mental model: `duna_ike_setup` is mission glue, not a generic
  transfer dependency. It performs Duna aerocapture setup, writes the next
  Ike/Duna-entry leg as a local mission profile, and clears reload/band cache
  state before rebooting into the next leg.
- **Commit and push when a chunk of work is done, without being asked.** The
  game's archive folder syncs from the pushed repo; unpushed code is
  untestable. Logical, bisectable commits in short-imperative style. Leave
  unrelated untracked files (e.g. `package.json`) alone.
- Missed Minmus capture recovery (2026-10-23): user reports a predicted
  Kerbin52,446,066mAp/9,895,530mPe/i54.821/LAN82.932/AoP21.140,2261m/s in
  stages595/1012/654 while still in Minmus SOI. These are a diagnostic fixture,
  NEVER flight constants. cmd/kerbinrecover probes the native current/future
  Kerbin patch and vessel/stage dV every invocation. Default check is read-only
  with a verified direct archive diagnostic; apply reuses phaseReturnSetup's
  profile writer via explicit MCC entry, not stable-moon ESCAPE. Existing
  callers default to ESCAPE with their original moon/orbit guards. Apply
  revalidates native patch, Abort/node/interruption and physical/raw/pilot
  cutoff before state/profile edits. Entry53km/corridor52-54km, no forced
  equatorial plane, optional KSC20m/s RETURN_TRIM and existing late-separation
  tags; KSC precision remains unproven. Ideal apoapsis estimate~108.06m/s is
  informational, NOT the actual MCC burn/cost. MCC uses existing SOI alarm/
  live solar/clock wait and checks actual body/Abort after wake before planning.
  Recovery alone enables MCC_RETURN_AT_APOAPSIS (other profiles default0),
  persisted by the shared writer: a stable outbound Kerbin ellipse with no
  future SOI wakes300s before native apoapsis via coast_wait, with its own
  KAC alarm before solar and no-KAC clock fallback. Inbound/unbound/near-apo
  attempts do not wait an extra orbit. Reject another SOI, bad ETA or an
  interrupted wait; keep150m/s correction and50m/s reserve. The same reported
  ellipse needs~156m/s if burned immediately at45Mm versus108m/s at apoapsis;
  do not raise the cap to hide poor burn timing. Native execution unproven.
  Never use a Minmus-frame burn to apply a Kerbin-frame estimate, never bake
  pasted elements into recovery, and do not claim native flight validation.
- Career context matters: this is a hard-mode career save. Don't assume
  parts beyond the unlocked tech (Wheesley-era jets as of mid-2026; no
  RAPIERs yet). Keep new systems engine-agnostic via config globals.
- Flight-test ledger (update as things prove out):
  Latest reviewed targeted Mun archive: landingdiag_RO9_2157921508_boot_014_core
  plus.boot.log. Main brake ended4051m short; APPROACH320s/519.5m/s impulse,
  hover30s/48.7m/s; touchdown requestedMiss2791/guidanceMiss2279/targetShift640m.
  This is physical touchdown, NOT pinpoint success. The20.6km gate matches
  older3s nominal timing; a0a23c8's timing fix gives18.4km at this snapshot,
  fuel-aware gate17.5km vs about17.1km flown. Do not attribute all error to
  mass or apply an unexplained geographic offset. Shared landing_brake_math
  owns the unchanged live/forecast control law. landing_brake_fuel snapshots
  stage-local enabled mixture/stock cap, evolving mass and dry separation;
  landing_prediction integrates it only in orbital planning, not throttle
  locks/live guidance. Stage roles and reserved return fuel remain protected.
  Forecast uses native conic H/V ignition and full controller through capture,
  target-height terrain and ideal attitude; no powered-terrain/touchdown
  guarantee. Independent inertial RK4 agrees within120m in the fixture.
  Assumed345/290s Isp replay gives16.74km/155s vs ~17.05km/154s flown;
  actual engine suffixes missing, so not an exact native reproduction.
  New landing archive engine rows record thrust/exhaust/fuel/dryDrop for that.
  V gravity/reserve/clearance/delay, facing/up, stage and physical cutoff
  remain unchanged. Unsupported precision stacks hold rather than silently
  authorize an old model. RO9 fixed Minmus now opts in with normal10m/s and
  cross500m, retaining its locked coordinates; economy remains flexible.
  Programmed rocket hops use the ORIGINAL mission plus scoped overrides and
  a durable route index, not a replacement profile discarding return intent.
  HOP_REVIEW MUST stop after every landing, including the last; its local
  prompt script explicitly continues, selects a waypoint or returns home.
  User replaced the former N/R listener with Godspeed plus printed commands.
  Never auto-clear
  Abort, repeat an interrupted launch, stage into return, or restore a thrust
  limiter before physical zero. Capture limits by engine UID and persist
  once before liftoff for reboot recovery. Cache both launch/landing/review
  halves only for routes. Default return700m/s is an allowance, not a solved
  return guarantee; stage-only launch/landing budget also has to pass.
  New hops and numerical prediction still require flight tests. Commands
  configure routes without ignition/reboot; prompt actions explicitly reboot
  into the chosen next leg. Cache the return_setup provider for route bands too.
  Return-provider warning follow-up: dispatcher binds only CURRENT phase;
  the earlier idea that this was harmless future-band noise was WRONG.
  Cross-compiled function pointers live as $name*, while DEFINED bareName
  can test an ordinary $name variable and falsely report unavailable after
  a successful load. RETURN_SETUP/SURFACE_RETURN_SETUP now test the scalar
  RETURN_SETUP_LOADED marker assigned at the end of return_setup, not bare
  function names. Missing/stale providers still hold and require a connected
  reboot. No late import/reset of return settings. Fixtures must model the
  scalar/function-pointer distinction rather than assuming DEFINED(name)
  works for any declared function. Audit other cross-library bare DEFINED
  function probes before trusting them. Native reload still needed.
  RO9 minmus_kolniya_flats_return is intentionally not an RO8 clone:
  capture Pe9300/inc63.4, SHAPE Ap397272/Pe9300/inc63.4/LAN79.2/AoP90,
  explicit SCIENCE_OPS hold, then selected Flats waypoint landing. Capture
  leaves LAN unspecified so SHAPE can finish it after the arrival asymptote.
  Confirmed native arrival Pe8.7km/planeErr0.8deg produced a0.1324m/s final
  trim, correctly skipped at shared minimum0.3, then resident checkpoint-used.
  This profile now admits coarse arrival plane1deg (Pe tolerance1000m and
  capture bounds8300-10300m unchanged); mandatory SHAPE still requires0.1deg
  at the requested LAN before science/landing. No global tolerance waiver,
  no tiny burn and no bypass of final precision or reserve budgets. Source
  fixtures reproduce rejection/wake and check the coarse/final gate split;
  native capture/SHAPE still needs flight validation.
  RO9-minmus3 Kolniya native report (2026-10-26): SHAPE schedules a4h-away
  set-pe-for-ap trim displayed0.1m/s, cost0.87. Two proven source gaps:
  fallback ran on any remaining AP error, including a normal AP trim skipped
  below its seed minimum, despite its own comment requiring targetAP<currentPE;
  and the0.4m/s floor covered initial apsis seeds only, not plane/AoP or
  optimizer-shrunk nodes. Fallback now requires actual geometric need.
  _shapeNodeAboveMinimum is shared by seed/final planning and the common
  execution boundary, including retries; log rawdV/floor/ETA/label. Tiny
  plane/AoP trims fall through to other useful corrections. Keep strict
  convergence/tolerances and budget ledgers; if ONLY sub-minimum corrections
  remain, hold SHAPE explicitly, never advance to science/landing or silently
  relax the Kolniya goal. Update planned label after retries. Optimizer cost
  is a weighted objective, not proof the burn is valuable/within tolerance.
  Source regressions cover final shrink, all node types, fallback geometry,
  retry/execution admission and preserved hold. Native flight still unproven.
  Follow-up native report: ApErr=-770m PeErr=+960m planeErr0.012deg
  AoPErr0.045deg did NOT satisfy the contract. Tiny SHAPE burns are necessary
  for this precision mission; do not apply the optional-arrival burn policy
  to contract completion. Kolniya now requires100m apsides, minimumDv0.002,
  SHAPE_BURN_TOLERANCE0.001 (scoped to executor calls; restores previous
  absolute/max residual on success/failure and never loosens stricter values).
  The usual executor absolute0.05 would skip the required~0.0234m/s AP trim.
  Shared SHAPE_MIN_PE defaults10000; this profile explicitly sets9000, ABOVE
  its existing8300 capture minimum, to allow9300 Pe. All plane/apsis safety
  gates use the same floor; atmosphere+10000 clearance cannot be reduced.
  Impossible target Pe corridor below floor holds before planning. Generated
  surface-orbit profile serializes optional MIN_BURN_DV/BURN_TOLERANCE/MIN_PE,
  with its existing500m apsides, same burn precision, and10000 floor for
  the high orbit (100m there would require~0.0018m/s AP trims, below0.002).
  Source/ideal-tangent replay of reported errors reaches100m using~0.0234
  and0.1909m/s; real source governor reaches0.001 residual without overshoot
  in its scalar fixture. Neither establishes native engine/physics precision.
  Native follow-up: governor live-node-trim at rounded0.001 followed by
  sampledResidual rounded0.001 triggered residual-outside-tolerance. Exact
  drift is unknown because both were logged to3places. Final acceptance now
  uses _burnFinalResidualLimit: ONLY finite, nonnegative full-vector
  live-node-trim evidence <=ABS tolerance gets a settling margin of
  MIN(0.001,0.5*tolerance); precision limit0.0015, usual0.05 limit0.051.
  Larger/axis-only/reversal/rebound/invalid evidence is not excused; physical
  cutoff/watchdog faults and strict SHAPE element convergence remain. No
  governor/throttle target changes. Nine-place residual/limit diagnostics;
  classify final residual/rebound BEFORE saving last_burn_report so it
  captures the real fault. Source regression covers live-latch then late
  sample, boundaries and fault preservation; exact native drift still needs
  new telemetry. _shapeInterruptedHold prevents automatic removal/retries
  of a flown interrupted node, at entry and after failure (restore precision
  first). cmd/shaperetry is an explicit stable-orbit SHAPE-only reset: match
  body/attempt/node time, physical/raw/pilot zero, Abort clear, recheck after
  warp settle; clear burn_* only after boot CPU restoration, keep mission,
  budget and last report. Old versions may already have replaced the node:
  mismatch is preserved; operator inspects/removes it then reruns command.
  Surface return writes optional SURFACE_RETURN_ORBIT fields to the NEW local
  profile's SHAPE_* (Ap659734/Pe554472/inc0/noLAN/AoP0.4) and sequences
  PRELAUNCH/LAUNCH/PARK/SHAPE/RETURN_SETUP, then Kerbin Pe52000. Empty orbit
  settings preserve existing missions; nonempty settings without SHAPE hold
  before profile/state changes. Keep return_setup through PRELAUNCH/LAUNCH/
  SHAPE cleanup for sequences containing RETURN_SETUP. Waypoint selection
  is required; do not replace it with an economy site or waive terrain/fuel
  gates. No new bootstrap, native mission flight testing still required.
  Repeated RO9 targeted Mun deorbit held on powered-lead-not-converged at54/64;
  operator supplied aim63610/range20847/ballistic84457m. No final downfield or
  residual was supplied. Definite control bug:3 forecasts each optionally
  refined, but the third changed node was never checked before the loop limit.
  Powered polish now continues under the same64 native trial cap, reserves
  one inner-refiner trial for fresh model validation and stops on no changed
  node. Geometry/model read the same attached probe; all temporary nodes are
  removed. Never accept the last frozen-policy result without recomputing
  its powered lead. Fixed coordinates, normal/fuel/cross/FPA and final terrain,
  light and pre-burn admission stay intact. Added powered-fit residual/reason
  rows and hold stop/pass/geometry summary so another failure is diagnosable.
  Source fixtures reproduce third-step success at53/64, actual inner Newton
  against a footprint-dependent lead originally converged in7 forecasts
  at55/64, and a
  boundary case spends63 on refinement/64 on validation. Missing impacts,
  model errors, drifting goals, no progress and insufficient budget still hold.
  Not a native replay or proof that the reported last node would have passed;
  a new connected boot/retry and logs remain needed.
  New native UT2741348-2741430 report after6635266: geometric seed18/64,
  powered residuals-16380,-10464,-15216,-5253,-3989m at19,34,50,55,61trials.
  The moving lead grew34.7->70.6km; inner Newton wasted multiple accepted
  steps on each frozen goal, leaving no3-probe+validation budget at61/64.
  Powered-only refinement now caps EACH inner call at1 accepted step, then
  forecasts afresh; initial geometric solving keeps its prior step policy.
  _targetPoweredStepAim uses actual fresh capture residual versus downfield
  to propose a secant root only with positive slope0.1-2 and250m changes;
  bound shift to3 current residuals. Noisy/reversed/nonfinite slopes fall
  back to model AIM, and a non-improving secant proposal gets one bounded
  plain-model fallback if budget permits. These are trial goals, NEVER
  acceptance gates. Same64 total counter,1 validation reserve, actual1500m
  lead tolerance, cross/normal/fuel/FPA/terrain/light gates remain. New row
  STATS deorbit powered-step exposes mode/goal/slope. Actual coupled source
  regression improves7forecasts/55trials to3/39. Observed lead-curve plus
  independent nonlinear geometry fixtures hold the old policy at63, pass
  new at35/39; interpolation/extrapolation is TEST ONLY, not a native replay
  or flight constants. Need native replan; do not loosen the goal to fly a
  rejected~4km-short candidate or simply raise the cap.
  2026-10-21: operator reports FIRST SUCCESSFUL AUTOMATED MUN LANDING AND
  RETURN TO KERBIN, with the newest RO9 mun_economy_return craft landed back
  on Kerbin. This closes the previously pending whole-flight outcome for the
  497+654m/s Mun-touchdown /430m/s pre-circularization run below. Treat it as
  an operator-confirmed successful round trip and a working baseline; no final
  diagnostic archive, exact flown code version, final fuel or touchdown speeds
  supplied. The run included operator debugging/reboots and linked recovery
  of RETURN_SETUP, so it does not prove an unattended clean run or every
  subsequent preventative fix. Flexible-site touchdown does not validate
  fixed-coordinate accuracy. Stage-aware ascent efficiency, powered-footprint
  prediction and clean offline/alarm handoffs remain optimization priorities.
  Operator requests about10m/s retained by powered aerobrake assistance for
  a possible later apoapsis Pe raise. AEROBRAKE_AP_RESERVE_DV now defaults10;
  shared aerobrakeApReserveDv applies MAX(10,configured) in both the forecast
  budget and live latched cutoff, and policy/result diagnostics show the
  effective amount. Legacy generated return profiles explicitly serialized0;
  they must not bypass this new allowance. Larger reserves remain intact.
  This reserves fuel only, not an automatic repair burn or a guarantee10m/s
  covers every orbit. No fixed total/per-pass cap, attitude/Pe/pressure/staging
  or cutoff safeguard was removed. Source cases cover both ship/stage limits
  at/below/above reserve, latched cutoff, insufficient-budget no-start,
  legacy0, larger100 and finite-fuel planar burns with the10m/s allowance.
  The newest Mun economy craft subsequently reached a reported10673m Ap /
  8103m Pe with430m/s vacuum dV before a small circularization trim. Relative
  to1151m/s at touchdown the displayed budget fell~721m/s; that is not an
  integrated-thrust measurement. The user observes poor response to the
  lander/return TWR change. _vacuumAscentPitch is still speed-based with VS
  floors; no stage-aware efficiency improvement is claimed. Added console
  acc/TWR/mass/stage/dV samples, buffering one usable observation per stage
  until verified cutoff for STATS logging; don't add disk I/O to powered climb.
  The circularization countdown~1000s had no node (intentional direct burn)
  AND no owned KAC alarm (bug). It now owns a reusableT-60 KillWarp alarm,
  passes only that ID to coastAutoWarp, keeps a1x clock fallback without KAC
  and settles warp before ignition/Abort/early target completion. Existing
  live cutoff, taper, time/dV limits and stage recovery stay intact.
  User then hit undefined phaseReturnSetup in dependencies while booting
  RETURN_SETUP offline; a linked reboot recovered. Source return_setup is
  declared correctly, but LAUNCH cleanup needn't retain its future provider.
  Conditional roots now keep return_setup+aerobrake_config during LAUNCH
  when SEQUENCE contains RETURN_SETUP; both boot planners share that path.
  Ordinary launch missions do not pay for it. Missing return delegates now
  leave the existing explicit missing-handler hold, with link/reboot guidance.
  Do not late-import config-owning libraries after profile application without
  restoring the profile: defaults could reset the53km return corridor.
  Current recovery is operator-confirmed; preventative cache/alarm updates
  still require flight validation. No installed bootstrap update is needed.
  Operator reports the newest RO9 Mun economy craft has landed, retaining
  497m/s in lander2 and654m/s in return1 (1151m/s staged sum). It came short
  of the original Trajectories target; no diagnostic archive, final miss,
  hover duration, stage-role log or code-version line supplied for this run.
  This confirms reported touchdown, not pinpoint accuracy or a native
  validation of every2f87166 change. Prior illustrative10km-parking/53km-entry
  estimate~877m/s leaves~274m/s for losses/corrections before any differences
  in site altitude, geometry or thrust; plausible margin, not a return guarantee.
  Surface-return setup clears the landing override, defaults ASCENT_STAGEDFalse,
  uses the still-active lander engine at liftoff and arms independent exhaustion
  staging. Preserve the497m/s for ascent rather than discarding it prelaunch.
  Ascent and return were pending at this checkpoint; the later successful
  Kerbin touchdown is recorded at the top of this ledger.
  New RO9 Mun economy flight reported premature V ignition: height9422m,
  bottom11058m, ASL13918m, targetElev4497m, hs513.2/vs-18.2,
  active39.78/plan=reserve2.45m/s2 (surface TWR~1.50), stage3,
  Vgate9432m/VnowTrue, Hgate207518m/HnowFalse, vectorGateFalse.
  Operator confirmed brakeStageDv0/stageCredit0. This exposed our previous
  fixed-profile-only opt-in and incorrect coupling of vector geometry to
  fuel credit. Rounded source replay gives oldV9455m vs corrected no-credit
  V4503m, ETA13.4s. This is at the SAME recorded state; falling increases
  the gate, so do not promise ignition at4.5km. H suppression remains correct.
  Downrange17600 transcription conflicts with gate/rangeError89903; don't
  infer an actual landing miss from that number. Source regressions load all
  four economy profiles and cover no-credit/disabled-credit geometry, zero
  alignment throttle, unchanged low-speed flare. Weak2.45m/s2-only full-g,
  3s-delay point mass retains~301m modeled capture clearance from gate+1m;
  separate illustrative200m/s bounded transfer burn preserves flare after
  both3s gaps. Routine44 files pass; slowest individual0.87s. No native
  flight or whole-mission fuel success claimed.
  User prefers explicit part roles over stage-number inference. Optional
  return_decoupler identifies the return/lander boundary; lander_decoupler
  identifies complete-lander release from transfer/carrier. landing_roles
  validates unique stock separator modules, return staging, retained CPU and
  plausible engines; it derives floor=return separator STAGE+1, tightened by
  an existing numeric limit. No tags preserves legacy policy. Tags do NOT
  fire hardware or install a surveyor/lander mission/control handoff.
  Resolver runs before orbital planning/burning and powered-descent setup,
  recomputes from physical tags after reboot, persists no derived numbers.
  Invalid roles refuse unflown deorbit; committed descent keeps active-engine
  guidance with conservative future thrust and blocks additional staging,
  including cached activation. Do not abort a falling craft just for metadata.
  Existing separation, ignition, throttle, staging-settle and fuel guards remain.
  cmd/landingcheck and STATS landing roles report effective floor and reason;
  new manifest/helper needs a connected boot, not an installed-bootstrap update.
  Source tests cover tagged3/2/1, renumbered6/5/4, absent/partial/released/custom
  tags, invalid/duplicate/order/CPU/engine cases, orbital hold and committed
  recovery. Routine275 cases/44 files pass; slowest individual0.93s.
  Native tagged hardware flight still needs validation.
  User later asks whether827m/s on the leg-carrying landing stage suffices
  from15km Mun circular orbit, and considers reducing the return tank to
  lighten descent. Treat827 as a descent-stage reading, not a verified total
  return budget; lander/return TWR and exact revised allocations remain needed.
  Efficient descent can make827 plausible, but near-unity TWR, long hover or
  large translation can consume the margin. Smaller return tank improves
  lander mass/dV/TWR but spends ascent/return margin. Existing ascent can burn
  leftover lander fuel before discarding legs/tanks; do not assume 1165 stays
  unchanged after a tank resize or promise affordability without a full budget.
  New-style RO9 mun_economy_return: operator reports LKO total3270m/s;
  transfer3 has1371 before883.1m/s departure, lander2 has735, return1 has1165.
  Components sum3271 (rounding). Return1 is intended for surface liftoff;
  leftover lander2 fuel can also assist ascent. Crossfeed2->1 is confirmed
  disabled. About488m/s transfer fuel remains after departure, before capture
  and corrections. More promising than the prior896m/s total touchdown,
  but no complete new-flight return budget is yet validated.
  Default landing floor0 would select return1 after lander2 exhaustion.
  cmd/landingstages2 validates actual engine/core/idle conditions and saves
  LANDING_STAGE_LIMIT2 only for this flight, preserving mission/phase/target.
  It does not configure the running game until the operator executes it.
  Do NOT set floor2 for every RO9: older craft use lander1. Crossfeed isolation
  is separate; do not claim staging alone protects propellant. Surface return
  profile creation clears landing overrides; ascent has its own staging and
  ASCENT_STAGED defaultsfalse, allowing leftover lander fuel before separation.
  Bounded transfer credit may ignore an INACTIVE engine below the explicit
  floor: only discarded-stage enabled propellant contributes, retained mass
  still bounds lander acceleration, and active parallel propulsion rejects.
  Optional fueled-stage disposal retains its stricter multi-stage rejection.
  New source tests cover actual3->2 handoff/blocked1, the unreserved risk,
  wet return mass, retained-fuel exclusion and configuration refusals. Routine
  271 cases/43 files pass, slowest individual0.89s. Native three-stage
  descent/ascent remains untested; the floor can leave descent without thrust
  if permitted lander fuel is insufficient, so do not call it a fuel guarantee.
  Operator clarification after the896m/s touchdown: this was intended as a
  TARGETED landing. Better braking/refinement at a local fallback is not a
  completed contract-site mission. Direct-return experimentation is deferred
  to the next craft. Fresh RO9 mun_landing_return explicitly sets flexible0;
  preserve its locked contract coordinates and bounded local terrain search.
  cmd/landfallback is a deliberate recovery concession, never the normal
  targeted-flight procedure; its output now states that the target may be
  replaced. The orbital powered-lead/target accuracy still needs validation.
  After8926227, the operator reports this committed Mun descent did much
  better: a smart braking burn, descent onto the flat side of a crater and
  excellent refinement, with896m/s dV remaining at touchdown (operator report).
  This is positive qualitative native-flight evidence for the revised
  powered-descent/recovery path. No new archive was inspected; target miss,
  hover duration and touchdown speeds are unknown.896m/s is not an approved
  return budget: prior illustrative10km-parking/53km-entry estimate877m/s
  leaves only19m/s before finite-burn/steering losses. Directreturn remains
  preview-only; the automatic surface-return sequence still circularizes.
  The available saves were already post-deorbit, so this report does NOT
  validate the new orbital powered-lead solve. Preserve the working descent
  behavior while measuring landing fuel and ascent/return feasibility.
  Next measured ignition: control6101/bottom7977/ASL10212/targetElev4113m,
  hs516.1/vs-44.9, active44.68/plan2.72, stageDv223.9, Hgate42847/Vgate4775,
  Vfalse/Veta6.6, Htrue. Post-separation BRAKE d39974, hs286.7,
  vs-32.3/-32.1, thr1/cutnone. Height at later row unknown. Craft paused,
  only post-deorbit saves; operator authorized landing off-site for this run.
  This is geographic range mismatch despite working thrust, not proven hover.
  RO9 fixed profile opts LANDING_POWERED_LEAD1: nominal geographic range
  differs from conservative vertical deadline. Sixteen speed intervals model
  full lateral authority with gravity support/centrifugal change, mid-descent
  radius, actual finite serial-stage impulse and both latency gaps. V safety
  unchanged. Orbital12-step native coast forecast derives ballistic minus
  powered travel, charges deorbit fuel first and refits inside64 trials with
  fresh validation after changes. New/retained/pre-burn share policy. Unknown/model
  failure retains orbit. Shared budget/lead only enter deorbit, never FSM tracks.
  Supplied ignition reproduces43km Hgate -> about23km nominal. Actual-controller
  point masses differ <700m in two stated cases (later height assumed5km).
  Independent15km-ap Mun conic asks about37km lead, not old15km. Limited
  approximation, not native accuracy/minimum fuel/full-flight validation.
  cmd/landfallback preserves return mission/phase and enables existing checked
  local fallback after zero-throttle/manual interrupt and connected reboot.
  It waives no site safeguards and cannot guarantee a no-hover search.
  Brake stopRangeError and capture targetDist plus archive recorder measure
  model error. Routine268 checks/42 files pass; slowest individual0.79s.
  Do not promise this already-burned trajectory reaches contract.
  Further ignition reading confirms H-trigger: alt12741/control height8628,
  hs510/vs-30.8,active44.68/plan2.72,stageDv223.9; vGate6286,vEta8.4,
  hGate74180,downrange74695,targetVs-27. D74695-600lead/bias=74095 inside
  Hgate despite Vgatefalse. Later11098radar is a current local reading.
  Replace staged full-control gate's aMax-g triangle bound with the exact
  thrust-vector root, retaining80% net reserve, full surfaceg, margin, clearance
  and both delays. Rounded inputs yield Hgate40.6km/Vgate3.46km/Veta25.7s;
  measured early snapshot coasts. Full net helper is now resident budget code,
  not a dynamically loaded brake-track definition. No-fuel fallback credits
  only the weaker engine's exact vector; legacy mode retains triangle budget.
  Pure vertical/underpowered checks unchanged.200 independent physical norm
  tests and worst-surface-g finite-fuel boundary runs pass; native accuracy,
  minimum-fuel whole landing and return budget remain pending. Operator's goal
  is a late descending main burn and short gentle flare, not geographic hover.
  Routine261 cases/41 files pass; slowest individual0.91s after eliminating
  redundant fixture function-scope keyword dictionaries. Integration steps,
  tolerances and assertions were preserved.
  Next retry prevented immediate phase-entry burn, but operator reports later
  braking/separation still too far from site. Supplied BRAKE d73988/trErr21195,
  x566,aErr0.3,hs418.5,vs-31/-36.4,siteSearchfalse,thr0. No height/gate row.
  This proves neither hover nor premature ignition. Source model at illustrative
  acc44.68,plan2.72,gEff.58,height9000 reproduces target-36.397 and a nearly
  horizontal command:0.3deg error below horizon trips the correct guard.
  Stage settling remains an alternative explanation for the actual zero.
  Add1deg constant-magnitude upward aim margin (config clamped0-2), retain
  actual no-engine-down cutoff. BRAKE cut/up telemetry distinguishes causes.
  Operator is reloading an earlier save; native cause/ignition timing pending.
  After successful fixed-site deorbit, operator reports immediate BRAKE at
  radar14869m/control height9149m, hs504.9/vs-3.8, acc44.68/planAcc2.72;
  shifted target640m. Paused game then crashed; no remaining-fuel/begin row.
  Exact speed/acc/height numbers reproduce Hgate152km/Veta12.7s, allowing H
  ignition within alignment lead. Whole-stop-on-weak-stage assumption ignores
  usable transfer fuel; legacy fixed-site controller also commands vertical0.
  Added opt-in staged envelope plus existing descending full-vector mode for
  this profile, preserving fixed-site geographic gates. Illustrative313m/s
  transfer credit changes Hgate48.3km/Veta38s; actual fuel here is unknown.
  Paired finite-fuel curved models reach horizontal capture with high-hover
  159->0s and impulse594->502m/s; ignition control-height9147->7611m. Neither
  endpoint is a full landing/return or target-accuracy proof. Full-surface-g
  boundary run retains flare margin with two3s unpowered gaps. Native flight
  pending; routine258 cases/41 files pass with all individual calls below1s.
  Do not promise a low-altitude suicide burn on a weak/fuel-poor stack.
  Follow-up fixed-site failure: window2 angle50, retro25.57/normal-10,
  downfield49.22km/cross31.313km versus0.5km cap, FPA4.71, Pe-20.662km.
  This is a large miss at saturated normal authority, not grounds to waive
  cross limits. It does not by itself establish which future pass is viable.
  Added geometry pass ranking and range preconditioning: a just-overhead
  44.593deg polar15km Mun conic fails the prior eight consecutive windows,
  then solves a later pass in22 trials (downfield15.08km/cross3.4m/normal-3.3).
  Coast source fixtures verify KAC-before-solar, continued polling, fresh
  admission and interrupted-wait refusal. Routine252 cases in40 check files
  pass; new pass/coast cases each run below1s. Native KSP flight remains untested.
  Mun fixed-site deorbit held: normalCap0, windows2/8, trials64/64. Operator
  cannot reconstruct scrolled candidates and asks for an end summary. Current
  patch enables bounded normal10 and stricter250/500m cross preference/cap,
  spreads seed angles across passes and retains the nearest rejected actual
  footprint for a final summary. Routine247 source cases include synthetic
  15km polar Mun solutions for both normal signs, the disabled-authority
  rejection, later-window budget regression and actual failure-tail summary
  state. No native flight diagnosis identifies the exact best rejected
  footprint from the supplied hold alone; do not promise this retry succeeds.
  After the solar-wait patch, Minmus 15km circular reboot exited with only
  phase-entry STATS, no light search, and generic no-site/refresh-failed text.
  Operator confirmed PRINT ABORT. returns TRUE. This reproduces the exact
  early exit; no geometry failure was established by that boot. Added phase
  Abort guard, selector revision2, exact rejection reasons, and cancellation
  messages while retaining deliberate Abort control. Routine244 cases pass,
  including an Abort-on-entry phase replay with no search/solar/burn or state
  mutation. Clearing Abort and actual orbital solar hold await flight evidence.
  Minmus operator reports no sunlit+Kerbin-visible site; the rejection is
  correct but _confirmLandingTarget used to yield/Godspeed. Automatic light
  selection now forecasts, persists a retry, enters solar coast with its
  timer already installed, and reselects after wake without exiting.
  Forecast estimates are not a promise of a reachable/safe site. Routine243
  cases across39 scripts cover a native-frame inclined Minmus opposition
  forecast/fresh search, KAC/no-KAC continuation, JSON reboot/overdue/stale
  waits, safety/abort/body-change guards, fallback cadence, battery/health
  warp gating and CPU restoration. Native kOS/KAC/warp flight unverified.
  RO9 mun_landing_return captured successfully, then SHAPE rejected set-ap
  dv43.79, spent3.27, remaining1752.1, reserve650. Its profile requested
  captureAp100km then circular15km but allowed only10m/s per burn/20total.
  Both caps, not the reserve, reject the mandatory~44m/s circularization.
  This profile now allows60per/80total; reserve650, spent ledger, polar/site
  goals and other profiles remain. Shape budget logs expose all caps and
  individual admission results. Routine235 source cases include independent
  vis-viva, the reported admission and three guarded rejections with no charge.
  1708.31m/s after the reported burn is not a certified round-trip budget:
  a stock zero-elevation impulsive estimate is~589 descent+584 ascent to10km
  +313 aligned Kerbin departure=1486m/s, leaving only~222 for losses/margins.
  Actual terrain, staging, fixed-site diversion and return-plane geometry
  are missing. Operator confirms313m/s is transfer-stage fuel: after shaping
  about269m/s remains there and must contribute to descent before separation.
  Mun profile uses default fuel-first staging (discard threshold0); early
  fueled discard is enabled only on Minmus economy profiles. This proves
  source policy, not an actual impact/disposal or complete fuel-use outcome.
  Mun polar profile still flies precision guidance, not flexible economy;
  hovering/target corrections can exceed the~222m/s idealized margin.
  The automatic return still circularizes; directreturn is a
  preview, not an executable replacement. Do not promise the return from a
  total-vacuum-dV sample or treat650m/s as sufficient fuel after touchdown.
  Operator's UT1865900 REFINE log has a measurable native Mun patch with
  entry1866063.7, then existing-patch-unmeasurable. The old300s node lead
  crosses SOI with only163s left; findArrivalPatch walks NEXT patches and
  cannot find Mun when the node already starts there. Shared node creation
  now bounds both full/Pe-only seeds before entry with the existing120s
  buffer plus1s. Reported epoch permits about41.8s lead; post-solve lead and
  retimed entry still must pass, otherwise a manual timing hold. The normal
  final900s checkpoint and all size/plane/fuel/alarm safeguards remain.
  Routine234 source checks across38 scripts pass, including the actual
  patch walker with modeled node frames, both seed paths, warp settlement,
  abort and post-solve expiry. No native KSP propagation/alignment proof.
  Why this phase entered only163s before SOI is not established by the log.
  Operator asks whether retry changes disabled SOI alarms. They remained in
  COAST_2HALF/waitForSOI but were absent during earlier long B-plane waits.
  Current fix schedules the independent native SOI alarm before B-plane and
  midpoint/final coast work, refreshes after actual correction execution,
  and installs it before solar setup in arrival/standalone SOI waits.
  Expired/mis-timed cached IDs are replaced even when saved UT looks valid.
  Routine230 cases cover alarm independence, reboot reuse/cache loss,
  correction retiming, no-KAC polling and cleanup on actual SOI entry.
  Native KAC UI/warp-stop behavior still needs flight confirmation.
  Operator reports overly frequent B-plane retries (4-5 during a Mun trip).
  Reposted log is the older UT1853933 terminal hold and has no new wake rows;
  source confirms the latest scheduler waits half the remaining safe window,
  which yields progressively shorter intervals. Current policy retains the
  normal midpoint then one final check900s before SOI, preserving larger
  required burn/SOI margins. Wait/completed intent survives reboot, with
  stale mission/target/alarm cleanup and no spent-fuel reset. Routine225
  source cases cover bounded final cadence, persisted pre-solver waits,
  overdue/retimed checkpoints, ETA jitter and explicit replan/burn cleanup.
  Flight timing/adequate final correction lead still need operator validation.
  Operator reports the three-axis fix flew a36.3m/s correction successfully:
  UT1853929 residual0.05m/s, parent Kerbin Pe42.6km/Ap11370.8km, then actual
  Mun Pe13.6km/inc90.21deg. A converged0.09506m/s trim was skipped correctly
  but the phase fell into a resident terminal hold at planeErr0.21deg vs0.2.
  Current fix defers a below-minimum converged candidate via the shared
  live retry path in BOTH modes, preserving0.3m/s floor/final0.2deg plane.
  Parent coast safety now proves atmospheric entry timing when its whole
  hypothetical ellipse has a low Pe; the native moon patch truncates it.
  Routine222 source cases cover the first burn + tiny candidate + actual
  midpoint wake, later tiny retries until useful, and18 ellipses checked against
  independent true-anomaly time integration. Arrival/capture still unproven.
  Complete RO9 log at UT1851812 confirms the previous deferred retry did NOT
  activate: native Mun Pe8.44km failed the 10km review floor, despite safe
  Kerbin Pe78.3km and 14220s until encounter. Solver saturated10m/s, reduced
  planeErr88.75->70.01deg, final Pe31.7km, offPlane0, available2019.1m/s.
  Current patch separates pre-SOI wait safety from arrival acceptance,
  uses a three-axis minimum-norm B-plane residual step (prograde was omitted
  from Newton), and allows16 iterations. RO9 mun_landing_return gets100m/s
  per correction/150total with900m/s AFTER capture; plane, time-shift600s,
  capture-cost-increase5m/s and cumulative budget checks remain mandatory.
  Later unconverged full solves stay in timed solar/clock retries; mission
  admission/window failures now print ARRIVAL BLOCKED and yield at1x to the
  Godspeed prompt (operator correction,2026-10-22), retaining the saved phase.
  Operator previews and interrupted burns still require deliberate review.
  Routine219 source checks include actual8.44km eligibility, KAC/no-KAC live
  retries, deadline/abort holds, six admission guards, 50 independent
  least-squares comparisons, synthetic polar convergence/cap rejection, and
  offline craft/profile compile/copy/cold-load/updater cases. No native kOS
  compiler or KSP integration runner; actual flight convergence is unproven.
  Historical6daffcd attempt (superseded by the complete log above):
  The operator tested07ea7db and reports review in7948s, then Godspeed. This
  confirms the manual-review change failed the intended automatic wake flow.
  Early mission BPLANE now explicitly enables deferred retry on an unflown
  unconverged optional full correction. Reject/remove its node, bind pending
  intent to mission/launch/target, then enter the existing COAST_1HALF handler;
  its alarm, live solar/clock wait and REFINE_BPLANE retry stay in the mission.
  Midpoints already past advance immediately. Abort, interrupted/manual nodes,
  unsafe/missing/late encounters and absent coast/refinement pair cannot defer.
  This delays an attempt, never accepts a bad burn or waives the polar goal.
  Preview/review commands and midpoint solves do not enable this early policy.
  Routine207 source checks include rejection-tail -> actual phase -> live wait
  -> midpoint retry, with/without KAC, reboot intent and unchanged rejection
  of a subsequent unconverged required-plane correction. Native convergence,
  actual KAC timing and a successful flight remain unproven.
  RO9 Mun science return flight reports decision=hold reason=
  unconverged-optional-correction followed by solar engagement, no alarm and
  no wake time (2026-10-19). Source confirms hold yields before COAST_1HALF;
  the installed boot then started its indefinite solar command. Midcourse
  had not been scheduled. bootResumeOrManual now marks deliberate yields
  manual using the installed tail guard (no boot.ks replacement). Arrival
  holds use raw encounter timing to anchor a review alarm; this alarm does
  NOT auto-resume or waive required polar plane, budget or interrupted-node
  ownership. Unburned Pe/plane error and exact solver failure remain unknown.
  New small midcourse library shares the unchanged timing policy with capture;
  capture sets the midpoint alarm BEFORE solar and propagates its deadline
  through alignment, health waits and maintenance. Past checkpoints refine now;
  native arrival timing wins over stale XING estimates. Expired KAC alarms
  cannot be reused as a future wake. Routine203 source checks cover review
  alarms, reboot anchoring, overdue handoff, deadline and boot-tail behavior;
  no KSP/KAC integration or successful polar correction proof yet.
  Supplied solardiag_RO9_1644877384.log: anchored-six-axis search completed
  successfully in63.78s, final flow0.3813675, no alignment timeout or dropped
  rows. Winner fixed-5 is craft axis(0,.866,.5), the panel-part -Y axis;
  final error3.63deg, battery39.45->38.25pct. Most time was turning/settling.
  This file establishes that this attempt worked, not a global power maximum.
  New coarse-to-fine source probes +/-15deg in two tangent directions at1deg
  tolerance; a cosine gradient only proposes an independently measured peak.
  Measured gain must exceed.2pct. Optional45s budget, <=15s/turn, reserves the
  normal final-return allowance; abort/eclipsed/unreadable/failed final return
  cannot replace a good cache. Valid older coarse caches refine directly once;
  saved solar_axis_tolerance allows subsequent quick validation. Invalid
  benchmarks skip the redundant cache trial. SOLAR_REFINE_TIMEOUT0 disables
  refinement. Five finite 3D source replays cover tilted/diagonal mounts;
  separate fixtures cover multiple panels, nonlinear/worse peak, noise,
  partial/stalled refinement, cache upgrade and deadlines. These are models,
  not KSP proof of refinement timing or gains. Recorder schema2 keeps24
  settled comparisons outside the detail ring, including actualSunAxis.
  rawCommand denotes SHIP:CONTROL channels, not measured cooked-steering
  torque; ALLFIELDS contains names/types, not live wheel/panel values.
  Routine197 source checks pass across33 files; this run's slowest individual
  check was0.708s. Refinement still requires a flight report for validation.
  Solar rewrite after repeated fixed-2 ~90deg/90s timeouts (operator report,
  the earlier stalled attempt still has no raw file): cache-first, then one six-axis loop; tracking
  probe/type inference removed. _solarAim snapshots a full target and its
  Sun vector once; its live lock transports that target with Sun motion,
  without SHIP:FACING feedback. Nonidentity-frame and finite 3D-turn fixtures
  execute actual aim/settle/search source; this is not proof of KSP wheel
  dynamics or the precise reported stall cause. SOLAR_MIN_IPU2000 is scoped
  and persisted for bootPreamble recovery. Defer boot-log archive copying
  during search. Angle/rate/readout/flow/cache/eclipse/deadline guards remain.
  Resident solar_diagnostics records 5s samples (64 rows/24k chars), requested
  versus manager/actual attitude, commands, errors, rate, suppression/SAS,
  warp, CPU and power plus panel/wheel fields and CPU roles. Quiet verified
  reports go directly to archive/_diagnostics/solardiag_*.log; offline fallback
  uses the recursively swept local log directory when space permits. No
  file I/O in samples, and no export with thrust, imminent deadline or ABORT.
  A compact last_solar_summary persists; cmd/solarreport prints it and the last
  verified path (possibly earlier than the current buffered attempt). The
  two solar commands no longer enter a blind hold after failed orientation
  or replace the live solar lock with a self-referential current-facing lock.
  Routine192 source checks pass; measured individual checks remain below1s.
  An unflown 0.1 m/s B-plane correction reportedly fell to a 0.0 display
  during the attitude turn/wait. Craft has no RCS; no engine burn had begun.
  Exact residual drift versus rounding/physics noise remains unmeasured.
  Confirmed source defect: Pe-only returned before the normal solver's
  minimum-size gate. Both kernels now return candidates through one common
  admission gate (reject <=0.3 m/s), reused for saved nodes and execution.
  The old <0.2 safe-handoff branch was redundant with that shared floor.
  Do not reintroduce a Pe-only bypass or a distance/0.5 m/s rule. Early
  airless Pe-only BPLANE can leave fine targeting to an immediate coast/refine
  pair: native current encounter >=10km Pe, <=10km target error by default,
  >3*BPLANE_LEAD to SOI, and fuel for capture/reserve/later correction. Bad
  encounters, plane contracts and final refinement retain strict gates.
  These are source-fixture checks, not flight proof. Logs now distinguish
  setup versus ignition residual at four decimals; they do not prove the
  underlying unpowered residual-change cause.
  New RO9 Mun files landingdiag_RO9_1619274662_boot_011_core.log and its
  .boot.log sidecar are one session, not duplicate descents (operator-success
  report). Landed733.4m/s, guidanceMiss11.3m, targetShift57322m. Main burn141.2s
  (stage2->1, weak2kN/2.76m/s2) descended9.4->3.2km, so no demonstrated high
  hover. Five brake/coast/restart cycles; 351m approach at521m took76.1s and
  25.503kg,41.8% of mass consumed after horizontal capture. Initial dV and298
  evicted recorder rows prevent a complete fuel comparison with830.5m/s flight.
  User prioritizes upfront checked footprint, late coupled braking and gentle
  touchdown, minimizing hovering/translation. Economy now retains flare
  attitude during short unpowered gate intervals; high surplus height still
  coasts and all ignition/alignment/cutoff guards stay. One post-capture,
  zero-command/physical-thrust footprint check may bypass a large approach
  only with normal terrain/light/reachability/clearance acceptance; no new
  hover/search on rejection. LANDING_ECONOMY_TERMINAL_RETARGET0 opts out;
  precision unchanged. Fast airless vertical profile inverts a conservative
  bound on the existing coupled envelope, uses actual vertical/weak-stage
  authority and keeps the gentle final ramp. Require twice its nominal max
  deceleration before acceleration of descent; low-authority cases retain
  original schedule (do not claim their original final ramp is validated).
  Conditional terminal model96.3->53.4s,169.1->100.7m/s; five eligible models
  pass0.2s lag. These are not KSP or whole-flight/optimal-staging proof.
  Upfront coast footprints remain provisional; no fully optimized native
  staged powered-descent planner is implemented. Routine186 cases pass.
  Recorder schema3 retains bounded per-FSM-state time/powered/impulse/slow
  descent/entry/max-gap totals across ring eviction; scalar thrust/mass
  integration avoids counting stage mass loss as propellant. Start/checkpoint
  native dV/mass are saved, with no new burn-time archive I/O or hover.
  RO8 Minmus recovery landed successfully (operator report, 2026-10-14),
  305 m from the requested waypoint with ~380 m/s remaining. The operator
  reported prolonged corrections and a wasteful hover; exact state history
  and any terrain-driven target shift were not captured. Surface ascent
  reached orbit but circularization overburned. A 181 m/s preview with Kerbin
  Pe 22,050 km was rejected; the operator retired this probe after transmitting
  science. RO9 Mun economy descent crashed after BRAKING_BURN began only
  seconds before impact (operator report, 2026-10-15); no crash log was available.
  Removing unintended coast-MCC thrust may have exposed older brake-gate and
  steering weaknesses. The subsequent coupled braking/terrain/latency gates,
  next-stage thrust reserve and nonblocking descent staging pass source-driven
  point-mass/hardware fixtures, but remain unverified in KSP. A subsequent
  RO9 Mun transfer also missed its intended arrival: the operator reports
  a 1,780 km Mun Pe, about 3 h to Pe, and 550 + 1,400 m/s remaining in the
  transfer/lander stages. Pe-only recovery failed under economy correction limits;
  a 300 m/s recovery allowance subsequently failed the correction-plus-capture
  budget. The operator subsequently corrected the overburn diagnosis: the
  planned node itself predicted about 2,200 km Mun Pe and went beyond the
  Mun's orbit. Treat this flight as a planning failure, not a confirmed
  executor failure. The economy path targeted zero Pe and accepted any patch
  after an unchecked refinement. Local departure now targets requested Pe
  and rejects outside-corridor nodes; source-driven synthetic fixtures pass,
  and the operator reports a good planned encounter on retry, but ignition
  entered BURN WAIT. This is the no-usable-thrust path; hardware evidence is
  pending. A separate watchdog publication race was fixed by refreshing the
  timestamp before exposing positive throttle; interleaving fixtures pass,
  but successful flight execution remains unverified. After an explicit
  no-thrust retry, planning rejected an 856 m/s node with 1,058 km Mun Pe.
  The solver now tries its stored alternate windows, projects trial vector
  changes inside the existing cap, and logs each solve's stop reason.
  Synthetic alternate-window/budget-edge checks pass; the exact flight
  solver failure is not yet established. Independent thrust/mass impulse and
  stale-command limits, physical cutoff verification/shutdown, and a compact
  persistent burn report now have source-driven fixtures, not flight proof.
  Three-axis Pe recovery, budget-boundary/corridor fixes and explicit
  `arrival` budget/plan-only commands have synthetic response fixtures only.
  RO9 zero-throttle investigation (2026-10-16): the passive
  `descent_service` role held a competing zero throttle lock before separation.
  It now releases its own lock while attached and retains cutoff/steering
  after separation. This is a confirmed source defect, not confirmation that
  this RO9 carries that role. `cmd/burncheck.ks` prints current engines, CPU
  roles, suppression/IPU and read-only timed governor probes. No cutoff is
  bypassed.
  The operator subsequently reported only 'Burn start', with no tick or
  BURN WAIT output after ten minutes. The governor's high-priority callback
  can starve the main loop at kOS's default 150 IPU, before the first command
  is published. The executor now uses at least BURN_MIN_IPU (2000 by default,
  bounded by kOS's maximum), restoring the prior value after control release
  or in bootPreamble after interruption. The operator reports a successful
  burn after transferretry/reboot with this change (2026-10-16), supporting
  the instruction-budget diagnosis. Exact prior IPU/timing and full mission
  completion were not reported. The operator also found burncheck's invalid
  top-level RETURN statements; all cmd bodies and its archive helper now
  use local entry functions, with a repository-wide return-scope check.
  Later in the same flight, the operator reports roughly 10% throttle after
  LAND_DEORBIT, followed by immediate BRAKE and then APPROACH above 14 km.
  At 13 km, approach held about 35% throttle, hs=54.96 and vs=-5.89 m/s;
  about 960 m/s remained after braking. Final outcome and the ignition gate
  telemetry are unknown. The compact executor now shares physical cutoff
  verification, with a longer latency-aware taper. All direct burn families
  use `thrust_cutoff`; raw/pilot commands, post-release thrust and forced
  shutdown are checked, and phase advancement respects a cutoff hold.
  Passed/high-altitude target gates and terminal handoffs have new regression
  cases; physical stopping, terrain and next-stage limits remain active.
  These changes are not yet flight-proven. Further landing-footprint,
  approach-budget and sequence validation work is recorded in
  `docs/FLIGHT_SEQUENCE_VALIDATION.md`.
  On 2026-10-17 the operator suspected the new morning site lacked Kerbin
  visibility and requested an afternoon alternative. Nested body-frame
  regression reproduced a false acceptance: +18.36 deg predicted versus
  -15.92 deg actual in the fixture. Common-root body prediction and an
  independent live-position Mun consistency gate fix that source defect;
  AFTERNOON prefers a falling 52.5 deg Sun. Exact flight coordinates and
  in-game verification remain pending. `cmd/landlight status` provides live
  and predicted site elevations without changing the target/node/phase.
  Later on 2026-10-17, a completed deorbit raised `Must attach node first`
  at the compact executor's steering lock. Cached control values and
  owner-file steering release now prevent callbacks from reading a removed
  node. After reboot, BRAKE reportedly started near 12 km; its initial gate
  telemetry is unavailable. APPROACH then displayed bottom=2504 m,
  d=79622 m, hs=7.2/7.1 and vs=-0.3/-0.3. Terminal admission incorrectly used
  distant target elevation; it now uses hull clearance. Economy profiles
  can divert to a surveyed ballistic site after an excessive miss/correction
  estimate, preserving slope, Sun/Kerbin and return-intent checks. Failure
  holds for manual review. Fine scanning runs before powered guidance; a
  scoped 2000-IPU landing floor restores on cleanup/reboot. Shared geometry
  is in `landing_light_math`; orbital search/node checks stay out of powered
  descent. These changes have source fixtures only. Do not claim the early
  12 km ignition cause is established or tune away the stopping margins;
  `cmd/landingcheck` now retrieves its saved decision after future attempts.
  The next RO9 economy flight aborted descent after rejecting a flat fallback
  site solely for Kerbin view. The operator reported Kerbin=-1.11 degrees,
  explicitly accepted it, and then prioritized autonomous landing without a
  link after deorbit. `LANDING_DIVERT_REQUIRE_KERBIN` now defaults to 0;
  orbital planning keeps its +5-degree requirement. An opt-in strict diversion
  uses a 7-degree allowance bounded at -2 degrees. Do not restore a radio-only
  post-deorbit abort by default. Sunlight, slope and cutoff gates remain active.
  Economy planning now prioritizes radio margin: Kerbin >=15 degrees,
  preferred >=30, Sun >=5 at any sunlit hour; morning 15-degree Sun and rising
  light are soft preferences. Explicit MORNING/AFTERNOON modes remain available.
  Source geometry/ranking fixtures pass; flight verification is pending.
  The operator's ~68% BRAKE observation is consistent with the 0.8*(a-g)
  vector arrest budget plus gravity support, not a full-thrust suicide burn.
  A constant-g TWR=4, hs=400, vs=-60 fixture reproduces 68.34%; it is not a
  measurement of this craft. Braking optimization must change the gate and
  controller together; do not bypass the reserve or force throttle alone.
  After the operator rejected the hover, economy profiles enabled
  `LANDING_ECONOMY_BRAKE=1`: geographic target range cannot trigger the burn,
  but the unchanged combined velocity/terrain gate still can. Main braking
  uses an exact full-thrust vector and a downward flare-entry target, with
  the original 80% envelope retained for ignition and final-flare safety.
  The weaker-stage, latency, residual lateral speed, clearance, taper and
  engine-down protections remain. A paired point-mass fixture reduced high
  hover from 45.4 to 0 s and brake-to-approach impulse from 534.1 to 440.6 m/s;
  these are model values, not flight or whole-mission savings. Staged and
  variable-centrifugal-support fixtures exist in `check_landing_economy.py`.
  A subsequent RO9 suborbital reboot provided an ignition log: hs=522,
  vs=-46.7, hull clearance ~4244 m, acc=46.06, planAcc=2.72, vEta=0;
  BRAKE_ALIGN error=118.5 deg, ignition ~116.7 deg. The next stage delivered
  2.76 m/s2, validating that reserve estimate. The urgent vertical gate
  explicitly bypassed alignment. Never reinstate that exception: a stopping
  deadline does not justify wrong-direction thrust. The brake vector owner
  now zeros throttle beyond 15 deg or with actual facing below the horizon,
  shared by alignment, state entry, live braking and stage changes. The
  duplicated `retroErr` field is removed; hold/ready logs and saved ignition
  throttle expose the guard. `check_landing_alignment.py` covers the reported
  values, actual state entry and finite slew, but is not flight validation.
  This late state also requests targetVs=0 in economy mode: the conservative
  weak-stage stopping envelope is ~16 km at these speeds. Do not promise
  continuous descent or remove the reserve without budgeting useful remaining
  transfer-stage impulse and turning/staging time.
  On the next retry the operator confirmed that turning now precedes thrust
  (flight evidence for the alignment fix only). BRAKING_BURN then ran at
  ~7.3 km radar, hs=355.72, vs=-30.11. Replaying those values with the earlier
  2.72/2.76 m/s2 reserve yields V_GATE=7586/7325 m; economy targetVs is about
  -36/-37 m/s with effective g~1.03. This supports the gate arithmetic, not
  a completed landing or an optimal burn. Subsequent HUD: vs=-16.9/-11.3,
  throttle=1; later radar=1.14 km, hs=35. `check_reported_weak_lander` now
  replays the 7.3 km entry using only constant 2.76 m/s2 thrust/mass, a
  three-second ignition delay and changing centrifugal support; modeled
  terminal capture is ~567 m, with no high hover. Actual reserve/target
  readings at that later position were not supplied; that attempt aborted
  on the subsequent terrain rejection described below.
  The next report reached ~857 m but aborted after a terrain diversion:
  d=29584, hs=23.6->17.55, vs=-21.4->-28.28, remaining dV~1020. The
  candidate grade=.238 (~13.4 deg) failed the normal 5-deg gate; synchronous
  cutoff/grids plus FALSE returned the craft to an unpowered prompt hold.
  Do not reinstate that committed-descent abort for candidate rejection.
  Flexible missions now skip boot grids, validate one local candidate/tick
  after horizontal arrest, and retain powered braking while searching.
  The operator explicitly authorized up to 15 deg ONLY after normal search
  failure; economy profiles set LANDING_DIVERT_EMERGENCY_SLOPE=15, default0.
  Every tier keeps fine slope, clearance, correction-time and light/radio
  checks. Both tiers exhausted => powered arrest/intervention unless materially
  changed braking conditions permit the single fresh search cycle below;
  no accepted unsafe target. End-of-burn physical cutoff and alignment safeguards remain.
  check_landing_divert models the reported low-altitude restart with constant
  2.76 m/s2, 3 s latency and .238 terrain: emergency acceptance at15.2s,
  terminal handoff >140 m; not flight/CPU/fuel/terrain-mesh validation.
  RO9 Minmus later hovered at1475m, zero horizontal/vertical speed, d=7980m,
  remainingDv1329; normal and15-degree emergency search exhausted with last
  reason=reachability/grade=-1 (operator report, no full log). The source
  latched EXHAUSTED forever, even when near candidates tested during braking
  had become reachable. A Minmus/12-degree fixture reproduces that defect at
  12->0m/s. One new normal/emergency cycle now rechecks the updated stopping
  footprint after material speed/center change and earlier reach rejections.
  No gate is relaxed. Counts expose all rejection categories instead of only
  the last outer point. A separate1481m rest/7980m miss flat point mass selects
  a .1-grade local site at15.2s and coasts/brakes into descending vertical
  guidance at288m; not actual terrain, fuel, attitude or flight validation.
  On retry the operator still hovered at1352m: emergency15 search ended with
  232 samples, terrainRejected42/reachRejected190/lightRejected0, lastDist781m,
  transit204.1s. Those totals combine normal/emergency passes and do not prove
  the best emergency slope. A 100m grid can miss small safe patches. Search
  radius/step now fit the upright correction range (minimum20m spacing), and
  each pass logs its best measured slope. Economy pending/exhausted search no
  longer forces early alignment/ignition or holds above the stopping envelope.
  After horizontal capture, a pending economy diversion can replace an old
  datum beyond the low-speed coast corridor (minimum1km) with local hull
  clearance/highest observed search terrain. Nearby sites, moving/upward
  craft, enabled coast corrections, precision and accepted targets retain
  the original guard. This is not a general removal of terrain constraints.
  Provisional terrain/light sampling runs during coast/braking, with fresh
  actual gates before accepting cached sites. It cannot certify a future
  footprint or bypass the weaker-stage envelope. A flat, instantaneous-attitude
  Minmus6km/120m/s/-60m/s fixture has one main braking entry and descending
  terminal handoff at529m, no high hover. Single-burn optimality, finite-stage
  timing and actual steep terrain remain unverified. cmd/divertcheck writes
  raw terrain/correction-time data and a boot-log sidecar directly to archive;
  it samples for up to6 game seconds between points, with loading/export extra,
  and never controls flight. Use a saved test state or separately held craft.
  After 2a27aa2, the operator reported an "ok landing" on the RO9 Mun economy
  retry (2026-10-17). This is flight evidence for successful descent after the
  alignment and terrain-abort repairs. The supplied boot_012_core.log then
  confirmed grade=.076 (~4.35 deg), emergency=False, Sun12.4/Kerbin7 deg,
  targetShift6435 m, guidanceMiss12.6 m, requestedMiss6447.6 m, remainingDv830.5.
  Main braking lasted146.1s; TARGET_REFINE exited after15.8s on its climb
  limiter, APPROACH lasted61.4s, VERTICAL_DESCENT43.4s. The log ends at the
  reboot into RETURN_SETUP; actual surface-return setup/ascent is not logged.
  Landing cost lacks a starting dV sample. A stock-body impulsive estimate
  for the configured 10 km parking/53 km Kerbin Pe route is ~565 ascent
  +313 departure=877 m/s before finite-burn losses, exceeding830.5. This is
  an estimate, not a live return node or a proof of impossibility. The return
  executor checks affordability only once in orbit; a coupled pre-ascent
  budget remains an open planning gap. Do not claim return is affordable.
  A Minmus orbit near20 deg raised an equatorial-target concern, but the
  reported landing-light node lat19.045/lng129.478 identifies the REAL target,
  not the impact. dist/downfield19.23km and cross.04/7.18km alone describe
  the intended phantom overshoot; no plane-change defect is established.
  Logs now label target/impact/hit coordinates. Fresh flexible automatic
  plans in bound orbit refresh cached targets from the current ground track;
  no eligible light/radio site holds instead of reverting to the old lock.
  Precision/manual sites and retained/interrupted nodes remain protected.
  Source-driven20-degree Minmus policy fixtures pass, not flight validation.
  The operator then reported that ground-track refresh did NOT fix the
  slow/wandering deorbit solve or missing north/south correction. Confirmed
  source causes: economy profiles left NORMAL_DV_CAP=0; the solver polished
  a 1-D retrograde root; light checks preceded footprint rejection. The
  replacement measures downrange/cross response jointly, tries timing first
  (+/-120s) then bounded normal, with shared trust scaling and improving-only
  backtracking. Economy permits normal10m/s, prefers cross250m, rejects>500m.
  A global64-trial budget and scoped planning IPU floor bound work; boot
  restores landing_prior_ipu after interruption. Final/retained UNFLOWN bound
  nodes keep geometry/FPA/terrain/light/cutoff checks plus fuel/normal caps.
  Do not add a new planning hold to interrupted/suborbital recovery. Independent
  20-degree Kepler/source fixtures cover both normal signs, timing-only,
  nonlinear backtracking, saturation, singular response, budgets, geometry
  before light and CPU restoration; these are not Trajectories/KSP flight proof.
  The next Minmus attempt held with no accepted footprint; its old message
  claimed four orbits even when the 64-trial budget could stop early. Confirmed
  linkage defect: the light picker returned a future ground-track pass UT,
  but _autoLandingTarget discarded it after logging, and the solver started
  at earlier passes. Minmus rotation can put that site kilometres sideways.
  Fresh auto plans now carry transient pass context through terrain refinement
  and try its approaching half-orbit first, then later windows. Fixed targets
  reset that context; retained/interrupted recovery and all native acceptance,
  normal/fuel, light, terrain and cutoff gates remain. Logs report actual
  windows/candidates/trials and stop reason. An independent20-degree Minmus
  fixture reproduces the old64-trial hold and resolves eight selected unburned
  ground-track sites within16 trials and <1m/s normal. Not yet flight-validated.
  The operator subsequently reported another accepted, visibly off-target
  Minmus node: target18.241,76.9115, optional SCANsat search found no safe
  site, then Executing deorbit burn T+7031s. Paused, still unflown in orbit.
  They request dismantling/rebuilding LAND_DEORBIT and authorize diagnostic
  command metrics. Do not explain this accepted node away as a temporary
  trial, or treat the previous Kepler fixtures as live integration proof.
  cmd/deorbitcheck captures the retained node, native/TR contacts and both
  longitude/quaternion transforms, policy and vectors, in a separate log.
  It has no flight/phase/node mutations. TR source confirms node inclusion
  but asynchronous buffer publication; a fixed0.5s wait is not a freshness
  guarantee. Actual discrepancy evidence is pending; retain all existing
  guards while separating site selection, node planning and final validation.
  The operator could not find the diagnostic after running/rebooting. Its
  first version wrote linked reports outside logs/archive and used a local
  fallback whose collection depended on the installed boot. Schema2 writes ONLY to
  0:/logs/archive/_diagnostics, requires a link and verifies its completion
  row before success. Mid-capture link loss stays incomplete after reconnect.
  Legacy root/local reports are copied there without deleting originals.
  No installed boot-module update is required for this diagnostic routing.
  landingcheck now uses the same archive writer and readback verification;
  both reports include current-stage vacuum dV, active/reserve acceleration
  and engine Isp/separation slots. The shared writer stays archive-only and
  outside flight-band dependencies. Use these reports, not console copying.
  Landing also has a small resident landing_diagnostics recorder: actual
  candidate neighbors/reasons, no second scan; 64-row/16,000-character buffer.
  It appends directly to logs/archive/_diagnostics/landingdiag_* only during
  verified zero-thrust COAST with conservative V_ETA and H_ETA>=60s (15s cadence), or
  after landing/abort cutoff. Final checkpoint is read back and boot log copied.
  No logging-driven hover, burn-time archive access or installed boot update.
  Offline/no safe coast means deferred export; buffered rows are not reboot
  persistent and eviction counts are explicit. The larger operator-only
  diagnostic_log helper remains outside flight dependencies.
  The operator subsequently reports a renewed hover at260m (2026-10-17),
  with no state/commanded-speed log yet. This remains unresolved: do not
  claim the earlier high-coast repairs establish an efficient terminal
  landing. The recorder keeps the real HUD current/commanded speeds,
  distance, throttle and pending-search flag every2s to distinguish a
  deliberate approach/search hold from tracking failure on the next retry.
  Schema2 adds unrounded controller targets plus continuous local/target/
  control/burn heights, search exhaustion, state age, physical thrust/mass,
  facing-up fraction and raw/pilot throttle. A source replay at260m/zero
  velocity reproduces targetVs0/17.79% throttle for exhausted search with
  g.491/acc2.76, versus -5m/s/zero initial throttle for active search. This
  establishes a mechanism, not which branch the live craft occupied.
  The operator then reports the Minmus lander landed and reached return
  planning, but ESCAPE held at dV170.20/available1038, predicted Kerbin
  Pe54717 versus53000. Landing success does not resolve the hover's cause.
  Confirmed planner mismatch: the fuel-weighted score can favor a Pe outside
  the separate1km entry gate. A bounded native-Pe polish now follows that
  search (six iterations, improving-only backtracking, +/-5m/s steps and
  +/-10m/s total prograde change). Already acceptable nodes keep their cost.
  The existing1km/fuel rejection gates and downstream actual-orbit MCC
  corridor remain; no tolerance relaxation or new BPLANE phase. Prescribed
  response/source fixtures pass, native KSP flight evidence still pending.
  Follow-up Minmus failure (25.14deg,9.5x10km,1195.8m/s available): the
  separable timing/thrust seed stopped at Pe1578.6km; its one-axis polish
  made no improvement. Do not relax the1km entry gate. Failed polish now
  invokes a native-patch time/prograde/signed-normal pattern search, with
  a joint time/thrust coarse seed, available-dV bound,256 trial/32 round/
  20 game-second limits and Abort. Planning settles warp first. Independent
  Kepler/SOI fixtures for inclined Minmus with the physical escape seed reach
  the corridor in202-211m/s;
  this is not a native replay or finite-burn proof. Automatic entry/fuel/
  lost-patch/Abort rejection removes only its unflown node before yielding;
  a pre-existing operator node blocks replanning without deletion. Explicit
  previews still retain their inspection node. No installed bootstrap change.
  Optional AEROBRAKE_AP_BURN now enables fuel-driven, finite-burn Ap reduction
  with Pe-preserving steering. Default0; RO9 explicitly enables1 (authorized
  craft difference from RO8). cmd/aeroassist takes ONLY boolean0/1. No fixed
  total/pass dV caps: usable fuel is MIN(ship,stage vacuum dV) minus optional
  reserve(default0). Config survives both generated return profiles. Plan at
  actual conic atmospheric-interface ETA180s, three ignition candidates plus
  finer verification, variable mass, automatic goalAp atmosphere+1km. Forecast
  is VACUUM, not a drag/thermal certificate. Native live upper/lower entry Pe
  corridor+100m margins, energy reduction, pressure<=.1atm, alignment<=5deg,
  atmospheric surface-retrograde limit10deg, fuel/stage/node/abort/freshness
  remain mandatory. Forecast impulse/time limits are computed, not preset dV
  allowances. No staging/activation. Physical cutoff precedes state/log I/O.
  Interrupted attempts retain their pass latch until observed entry AND exit;
  outside-atmosphere alone cannot re-arm a pre-entry burn. Planning/control
  IPU2000 is scoped; bootPreamble restores aerobrake_prior_ipu on interruption.
  Late inside-atmo boots skip assist until next pass. Entry alignment now
  compares the commanded surface-relative direction, fixing its mismatched
  orbital reference without widening the2deg/60s guard. Planar conic/source
  fixtures supplement flight tests; atmosphere/thermal/engine-lag validation
  and actual pass-count savings remain unestablished.
  Routine suite:157 cases pass; each measured<1s. The new long source-owner
  replay is0.75s after a fixture-local three-component vector magnitude
  optimization; steps/tolerances remain unchanged. New checks include869m/s
  uncapped eligibility/execution, useful-energy stopping with3200m/s,
  reserve100m/s, independent conic/time/Pe derivatives, drag/stale control,
  interruption/cutoff latches and profile persistence. Pe feedback uses a100m
  deadband to avoid large radial corrections for tiny near-Pe conic drift.
  Operator reports an apparently fixed off-retrograde powered burn, ending
  with153m/s left, then repeated aligned RETROGRADE entry logs. Native post-burn
  Pe/Ap and cutoff reason are not yet available: do not certify that burn from
  the navball or conic fixtures. Powered guidance intentionally departs from
  retrograde outside atmosphere to preserve Pe (about23deg at the illustrative
  fixture's3-minute point), so the old entry message did not describe the
  subsequent burn. Separate confirmed defect: entry LOCK used a sampled
  steerDir/refVec; moving-velocity source fixture reproduces41.7deg stale
  heading after coast. New _aerobrakeEntryDirection reads live suffixes for
  steering AND alignment after helper return; aligned rechecks are quiet.
  Explicit pre-ignition timeout retains zero thrust. STATS align begin/checked
  shows commanded offsets versus actual pointing error; result reports guard
  peakFacingErr and RAM-sampled peak offsets. No diagnostic I/O during thrust.
  Routine suite now161 cases, including finite-slew0/5deg/s ignition guards
  and moving retro/prograde entry targets. No KSP attitude/engine proof.
  On atmosphere exit the operator reports Pe51096m, Ap211.5km, and a newly
  very inclined orbit (pre/post inclinations and burn-cutoff Pe still absent).
  This is NOT a proven correctly flown assist. Guidance should be in span(r,v);
  investigate actual plane change separately from post-cutoff atmospheric Pe
  loss. User prioritizes raising Pe at the new Ap while still outbound.
  cmd/reentrype(target metres,default53000) reuses planLowerPe's element-based
  apoapsis vis-viva planner (also valid for positive prograde dV), validates
  native corridor/plane/Ap/time/fuel, then uses the existing executor and cutoff.
  No phase/profile mutations or circularization; failed/retained nodes survive.
  Independent Cartesian/inclined-conic fixtures reproduce1.594m/s for the
  reported orbit. This is a command recovery, not flight proof or an automatic
  between-pass Pe restoration. The older automatic trim still plans at now+60.
  Recovery chunk:163 routine cases pass, every measured individual<1s.
  After running recovery the operator reports 'Aerobrake: orienting for solar'
  without an apparent turn. Confirmed source linkage: _aerobrakeSolarWait
  UNLOCKed steering, then trySolarHoldTick(-1) accepted any positive flow as
  a new reference without calling orientForSolar. Source fixture reproduces
  an immediate warp with no orientation attempt. Coast now explicitly aims
  off rails before warp, using cached-first validation, with a wake deadline.
  orientForSolar's optional fourth arg, and solarHoldTick/trySolarHoldTick's
  optional second arg, propagate that deadline. Initial alignment required
  <2deg and angular rate<.03 before flow sampling;
  timeout/partial attempts cannot overwrite proven axis/peak. orient returns
  Boolean success; non-holding callers release steering after a failed aim.
  No new launch/pad search bypass outside the explicitly safe aerobrake coast.
  Existing eclipse/charge/flow maintenance deferrals remain. Those ticks are
  maintenance, never a replacement for explicitly installing a solar hold.
  Initial zero-flow re-aim also waits for actual warp release. STATS exposes
  aimed/flow/canWarp or unavailable/timeout/deadline; no false success message.
  Routine172 cases cover positive-flow initialization, failed/unavailable
  solar, bounded search/re-aim, cache preservation and maintenance deferrals.
  Source evidence only; this does not resolve the reported burn-plane change.
  Solar follow-up (operator timestamps1615136->1615218 before axis2/6,
  then alignment-timeout-or-deadline): reboot briefly appeared to help,
  but this is not evidence for stale code as the cause. Source had 30s per
  turn and repeatedly scanned opposite axes. SOLAR_AIM_TIMEOUT now90s;
  SOLAR_SEARCH_TIMEOUT300s bounds the entire call, capped by an earlier
  caller wake deadline. Same six axes now use perpendicular consecutive
  steps, with the first perpendicular axis closest to the current Sun
  direction. Probe+scan travel falls720-><=465deg before the final best-axis
  return; this is a geometry result, not flight timing proof. Automatic
  recovery stops at a settled candidate meeting the valid saved peak ratio;
  forced scans and invalid benchmarks still require full discovery.
  Per-turn start/result STATS records error/rate/time/label and separates
  alignment-timeout from search-deadline. Hold re-aim start/result and cache
  threshold/axis samples now persist as STATS; the aim waits are instrumented.
  176 routine cases include 40s turn success, stalled turn/deadline exits,
  all-axis preservation in60 rotated/reflected frames, early stopping and
  total-budget/cache preservation. Alignment/readout/cache safeguards stay;
  physical flight performance and repeated re-aim causes remain unproven.
  Operator requested broader solar alignment tolerance: SOLAR_AIM_TOLERANCE
  defaults5deg for measurements; SOLAR_HOLD_TOLERANCE10deg for cached-axis
  reuse, still gated by the valid saved flow benchmark. Rate<.03 and the
  1.5s readout wait remain; pointing/rate now rechecked after that wait too.
  Live steering still follows the Sun. Burn/landing/reentry tolerances are
  unchanged. Routine179 cases include angle boundaries, 8deg cached reuse
  with good flow, poor-flow/forced-search rejection and post-readout drift.
  Timing follow-up: ideal-attitude aero fixtures now normalize the full
  direction directly, reserving trig slew for finite-turn tests. Steps and
  tolerances are unchanged. Host load still moves the full codebase audit
  around1s; don't hide it in the slow pass or claim a hard wall-time bound.
  The supplied deorbitcheck_RO9_1305239.log actually AGREES between TR/native
  impact coordinates within0.2m (quaternion also agrees); this snapshot does
  not show a stale prediction or incorrect longitude transform. An independent
  two-body replay matches node Pe within0.12m and impact within3.1m. Its target
  is17km off the plane NOW but rotates65.8deg into a pass within65m of the
  actual descent path, ~2.93km above target terrain. These model numbers do
  NOT certify powered touchdown, local terrain or staging/disposal. Do not
  force a plane change based on the present-day map target. Reported hardware
  is1.287t/55kN, stage2->engine1, next-stage surfaceTWR5.59 (~2.74m/s2).
  Current-stage dV is still needed to budget strong-stage braking/disposal;
  the controller currently stages only when usable thrust runs out. The
  operator wants separation before touchdown while the discarded stage still
  impacts; that behavior is not implemented or guaranteed by this diagnostic.
  The subsequent landingcheck_RO9_1306245.log measures current stage364.9m/s,
  total1817.1, activeAcc42.74434, reserveAcc2.74024. Torch stage2 drops in1;
  Ant stage1 stays, 2kN/315s Isp. After14.85m/s deorbit, ~350m/s transfer dV
  remains, so ordinary ~134m/s main braking will NOT exhaust it. New optional
  LANDING_STAGE_DISCARD_HSPEED=80 in RO8/RO9 Minmus economy profiles performs
  an elective fueled-stage handoff during braking, only for an adjacent
  serial stack retaining the active CPU and all lander engines, with no
  additional propulsion whose fuel would inflate the lander budget. It
  reserves the existing weaker-stage envelope and braking dV plus700m/s;
  requires a bound descending, node-free, atmosphere-free orbit passing
  below measured periapsis terrain. A shared stage event verifies physical
  zero; the tick-driven pending cutoff blocks all throttle publishers and
  cancels after1s or invalidated clearance/budget. Existing recovery/limits
  and alignment remain. Mun defaults stay fuel-first. cmd/landingdisposal
  saves only these two overrides for the next landing-band boot, no node,
  phase, target or return changes. Contact is predicted, not debris clearance
  or component destruction. No flight validation yet.
  A flat target-elevation replay of the actual node opens the production
  gate54s/7.4km AFTER target pass. A point mass with measured thrust/Isp/mass,
  fuel depletion, instantaneous attitude and3s initial +3s stage delay ends
  main braking at1306m/8.1km aimpoint miss (transfer retained) or733m/9.3km
  (80m/s handoff). Both keep downward speed>20m/s, ~134m/s impulse. These
  are model values, not terminal landing/terrain/debris/CPU proof. The fixed
  ballistic lead still does NOT certify an exact powered target landing.
  To protect landing quality despite this footprint shift, orbital economy
  site search and UNFLOWN native acceptance now reserve a21km geographic
  Sun/radio region (LANDING_LIGHT_SITE_RADIUS, 0 opts out), with parallax
  and the existing time window. This is a planning margin, not a guaranteed
  touchdown region or terrain/eclipse certificate. Rankings also reserve it
  before evaluating preferred Sun/Kerbin elevation. The recorded target's
  Sun15.8/Kerbin29.5 fails the new regional margin on Minmus; replan it.
  Precision sites and interrupted/suborbital recovery keep the original
  point policy; all physical diversion/terrain/cutoff gates remain active.
  Landing previously never read ABORT. The guidance owner now latches its
  existing abort/cleanup path before loading another track; all throttle
  commands and both elective/ordinary staging also honor ABORT. Source
  fixtures cover abort during pending cutoff and missing-track recovery.
  The requested Mun return is direct ascent to Kerbin Pe53km, no KSC/mandatory
  parking orbit. cmd/directreturn is a LANDED, single-stage MODEL PREVIEW ONLY:
  bounded heading/pitch/dV search, RK4 mass/thrust, analytic SOI handoff, actual
  current-stage budget and fine-integration recheck. It never launches or
  changes phases/nodes. No native patch/terrain/attitude/resume controller is
  certified; do not bypass circularization in the existing ascent and call it
  a validated direct return. The synthetic ~977m/s/320s-Isp fixture is not a
  measured RO9 budget or an impossibility proof for its830.5m/s landed save.
  Do not treat this one landing as proof of optimal fuel use or
  broad terrain/craft coverage. BPLANE/SHAPE flew the
  Mun contract end-to-end (2026-06). RO8 `minmus_landing_return` recovered
  a lost encounter after a staged, low-thrust departure via BPLANE and
  reached COAST_1HALF (operator report, 2026-10-12). Midpoint refinement,
  capture/landing/return, and the new cutoff/input safeguards remain
  unverified on that flight. The companion RO8 `mun_landing_return` is
  the planned same-craft follow-up, not the Falcon profiles.
  The suborbital return arc
  (`lib/suborbit.ks` v3: elements-only arc + coast + targeted walk) is
  flight-proven — single-boot KRBCAP1 round-the-world hop, landed exactly
  on its predicted impact. The landatksc/KSC_DEORBIT recipe, native JSON
  state, and the scansat duty cycle flew real missions; the discover+focus
  deorbit scan found a 0.9km pass quickly on a 28-orbit polar hunt. Recent
  Duna/FalconHeavy Lambert, REFINE_BPLANE, Duna/Ike, high Molniya relay, and
  split landing-storage work is current but still needs careful flight
  confirmation. Still **not flight-proven**: goto, the rescue
  PRELAUNCH/MATCH/CREW_XFER chain, the reworked airplane control loops, SSTO
  phases, the drone. The legacy coupled solver (`_targetPatchElementsCoupled`
  and friends) is retired-in-place: the stale `deorbit_targeting ->
  maneuver_targeting` dep is already severed; delete the lib once the
  rendezvous/intersystem flows stop importing it.
- Audit status (2026-10-16): `docs/CODEBASE_AUDIT.md` records boot/config,
  dependency, cleanup, rover, phase-handoff and propulsion repairs. They have
  source fixtures only. `KSC_DEORBIT` lost its atmospheric handler during the
  vacuum solver refactor; historical flight proof does not apply to the
  current recipe. Its missing binding now holds explicitly. Offline
  future-band/landing-track availability and crash-safe state replacement
  remain open. Do not remove the legacy targeting solver: MCC still uses it.
- Useful sandbox: quick brace-balance check over edited `.ks` files (strip
  `//` comments and strings, count `{`/`}`) catches most structural slips.
