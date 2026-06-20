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
6. **There is no compiler or test runner here.** Changes are validated by
   brace/syntax inspection and then flight-tested in the game. Be
   conservative in mission-critical paths, log generously (`STATS` lines),
   and prefer self-correcting loops (re-measure → re-plan) over open-loop
   precision.

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
- **dependencies.ks sections**: `dependencyPreamble`, `dependencyLibs`,
  `dependencyPhases`, `dependencyBands`, plus the phase-handler binding
  waterfall.
- **Missing handler** in `runPhases` ⇒ band-change request (`reload_*` state
  + reboot), not an error — that's the progressive-loading mechanism.
- **Vehicle contract**: craft scripts `SET` hardware defaults and expose
  `main()`; profiles own phase/library planning and final mission overrides.
  Role scripts may still expose `bootVehicleLibs()` for profile-less support.
  Runtime `mission_cfg_*` state is converted back into `SET NAME TO value.`
  overrides during boot.

## Map of the important code

| Area | Files |
|---|---|
| Boot/loading | `boot/boot.ks`, `lib/boot_lib.ks`, `lib/dependencies.ks`, `lib/preflight_planner.ks` |
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
- Logging: `mLog` info, `mLogWarn("STATS ...")` machine-readable metrics,
  `mLogError` + `yieldToPrompt()` for operator-needed halts. Phases log a
  `STATS ... setup` and `... result` pair. Logs are per-boot/per-core
  (`boot_###_<core>.log`); WARN-level `STATS` lines auto-archive when linked,
  so make diagnostics compact and searchable.
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
  replan, cap attempts at `MAX_RETRIES IS 5`.

## Working in this repo

- Mission profiles are KerboScript files in `missions/<vehicle>/`; each is a
  list of `SET NAME TO value.` statements.
- Boot/storage mental model: state must preserve intent, not bulky derived
  products. Persist `mission_id`, `phase`, target/config overrides, and
  reload intent. Do not cache computed band libs. If an upgraded vessel is
  wedged by old state, `RUNONCEPATH("0:/cmd/trimstate.ks").` removes the stale
  `lib_band_libs` key without loading the full boot stack.
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
  When BPLANE/SHAPE are downstream, XING's element gate is a handoff gate:
  it accepts rough real patches within `TRANSFER_DEFERRED_PE_ERR_TOL`
  (default 50 km) and `TRANSFER_DEFERRED_INC_ERR_TOL` (default 45 deg).
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
- Duna/Ike mental model: `duna_ike_setup` is mission glue, not a generic
  transfer dependency. It performs Duna aerocapture setup, rewrites the next
  Ike/Duna-entry sequence through `mission_cfg_*`, and clears reload/band
  cache state before rebooting into the next leg.
- **Commit and push when a chunk of work is done, without being asked.** The
  game's archive folder syncs from the pushed repo; unpushed code is
  untestable. Logical, bisectable commits in short-imperative style. Leave
  unrelated untracked files (e.g. `package.json`) alone.
- Career context matters: this is a hard-mode career save. Don't assume
  parts beyond the unlocked tech (Wheesley-era jets as of mid-2026; no
  RAPIERs yet). Keep new systems engine-agnostic via config globals.
- Flight-test ledger (update as things prove out): BPLANE/SHAPE flew the
  Mun contract end-to-end (2026-06); the suborbital return arc
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
- Useful sandbox: quick brace-balance check over edited `.ks` files (strip
  `//` comments and strings, count `{`/`}`) catches most structural slips.
