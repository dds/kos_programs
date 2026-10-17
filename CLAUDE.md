# CLAUDE.md

Komptroller is kOS (KerbalScript) mission automation for Kerbal Space Program.
`README.md` is the operator manual — architecture, vehicles, mission profiles,
commands. This file is what you need to *work on the code* without breaking a
mission.

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
4. **`boot/boot.ks` is installed in the VAB and cannot be updated remotely.**
   Everything else (including `boot_lib`) re-syncs at connected boots.
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
  Automatic solar orientation validates the cached axis against its saved
  measured peak before searching; reserve forced searches for explicit requests.
- Duna/Ike mental model: `duna_ike_setup` is mission glue, not a generic
  transfer dependency. It performs Duna aerocapture setup, writes the next
  Ike/Duna-entry leg as a local mission profile, and clears reload/band cache
  state before rebooting into the next leg.
- **Commit and push when a chunk of work is done, without being asked.** The
  game's archive folder syncs from the pushed repo; unpushed code is
  untestable. Logical, bisectable commits in short-imperative style. Leave
  unrelated untracked files (e.g. `package.json`) alone.
- Career context matters: this is a hard-mode career save. Don't assume
  parts beyond the unlocked tech (Wheesley-era jets as of mid-2026; no
  RAPIERs yet). Keep new systems engine-agnostic via config globals.
- Flight-test ledger (update as things prove out): RO8 Minmus recovery
  landed successfully (operator report, 2026-10-14),
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
