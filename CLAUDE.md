# CLAUDE.md

kOS (KerbalScript) mission automation for Kerbal Space Program. `README.md`
is the operator manual — architecture, vehicles, mission profiles, commands.
This file is what you need to *work on the code* without breaking a mission.

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
   only compiled size matters. `lib/dependencies.txt` is copied as **text**:
   keep it compact and comment-free.
2. **No archive in flight**: outside KSC link range nothing can be fetched
   from `0:/`. Anything a mission may need offline must be loaded at boot or
   declared in a `CMD` row (compiled to `1:/cmd/` while linked).
3. **Reboots happen** (power, quickload, scene change, band reload). Every
   phase must be resumable from `1:/run/state.json` via `stateGet`/`stateSet`
   — never raw file I/O for mission state.
4. **`boot/boot.ks` is installed in the VAB and cannot be updated remotely.**
   Everything else (including `boot_lib`) re-syncs at connected boots.
5. **Bands load the libraries of EVERY phase in the band**, not just the
   mission's. Code used by only some missions goes in its own phase/band
   (costs those missions one reboot; costs everyone else nothing) —
   `payload_release` is the worked example.
6. **There is no compiler or test runner here.** Changes are validated by
   brace/syntax inspection and then flight-tested in the game. Be
   conservative in mission-critical paths, log generously (`STATS` lines),
   and prefer self-correcting loops (re-measure → re-plan) over open-loop
   precision.

## Architecture in one screen

- **Boot**: `boot/boot.ks` → syncs `boot_lib` + `dependencies.txt` → preamble
  libs → EVA/`CORE:TAG` routing (`roles/`) or vehicle script (`craft/`) →
  mission profile from `0:/missions/<vehicle>/` persisted as `mission_cfg_*`
  state → `bootVehicleLibs()` roots synced/compiled/run → 5 s manual-mode
  window → resume.
- **Phases**: profiles own `SEQUENCE`; `runPhases(map)` dispatches by the
  persisted `phase` key; handlers call `nextPhase(seq)`. Sequences cannot
  repeat a phase name (lookup is by value) — multi-hop routes use the `GOTO`
  continuation phase instead. Shared handler naming convention:
  `PHASE_NAME → phasePhaseName` (underscores → camelCase), bound by the
  generated `lib/dependencies.ks`.
- **dependencies.txt rows**: `PREAMBLE` (always-loaded roots), `LIB`
  (dependency edges), `PHASE` (phase → roots), `BAND` (phases that load
  together; a phase without a band is its own band), `CMD` (phase → operator
  commands installed offline).
- **Missing handler** in `runPhases` ⇒ band-change request (`reload_*` state
  + reboot), not an error — that's the progressive-loading mechanism.
- **Vehicle contract**: `GLOBAL CFG IS LEXICON(...)`, `bootVehicleLibs()`,
  `main()`. Aircraft delegate to `airplaneMain()`; profile values land in
  `CFG` via `mission_cfg_*` state.

## Map of the important code

| Area | Files |
|---|---|
| Boot/loading | `boot/boot.ks`, `lib/boot_lib.ks`, `lib/dependencies.txt` (+generated `.ks`), `lib/mission_plan.ks` |
| Phase machine | `lib/phases.ks`, `lib/resume.ks`, `lib/state.ks`, `lib/logs.ks` |
| Ascent | `lib/launch.ks` (MechJeb), `lib/countdown.ks` |
| New maneuver pipeline | `lib/goto_plan.ks` (routing), `lib/arrival_bplane.ks` (B-plane MCC), `lib/orbit_shape.ks` (closed-form shaping), `lib/maneuver.ks` (node execution + single-burn planners) |
| Legacy maneuver pipeline | `lib/maneuver_transfer.ks`, `lib/maneuver_targeting.ks`, `lib/maneuver_orbit.ks`, `lib/maneuver_rendezvous.ks`, `lib/maneuver_intersystem.ks`, `lib/lambert.ks` |
| Payloads/landing | `lib/payload_ops.ks`, `lib/payload_release.ks`, `lib/payload_landing.ks`, `lib/landing.ks`, `lib/deorbit_targeting.ks`, `lib/aerobrake.ks`, `lib/descent.ks` |
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
  `STATS ... setup` and `... result` pair.
- Config flows CFG-ward: libs read `CFG` keys with per-lib `_cfg(key,
  default)` helpers; per-craft tuning goes in the craft's configure hook or
  the mission profile — never hardcoded in libs.
- Parts are found by VAB tag (`SHIP:PARTSTAGGED`), never by index.
- Retry pattern for burns: plan → `executeManeuver()` → on failure wait,
  replan, cap attempts at `MAX_RETRIES IS 5`.

## Working in this repo

- **After editing `lib/dependencies.txt`, run `make dependencies`.**
  (Pre-commit hook does it too: `pre-commit install`.)
- **Commit and push when a chunk of work is done, without being asked.** The
  game's archive folder syncs from the pushed repo; unpushed code is
  untestable. Logical, bisectable commits in short-imperative style. Leave
  unrelated untracked files (e.g. `package.json`) alone.
- Career context matters: this is a hard-mode career save. Don't assume
  parts beyond the unlocked tech (Wheesley-era jets as of mid-2026; no
  RAPIERs yet). Keep new systems engine-agnostic via CFG gates.
- Flight-test ledger (update as things prove out): BPLANE/SHAPE flew the
  Mun contract end-to-end (2026-06); the suborbital return arc
  (`lib/suborbit.ks` v3: elements-only arc + coast + targeted walk) is
  flight-proven — single-boot KRBCAP1 round-the-world hop, landed exactly
  on its predicted impact. The landatksc/KSC_DEORBIT recipe and the
  scansat duty cycle flew real missions. Still **not flight-proven**:
  goto, the rescue PRELAUNCH/MATCH/CREW_XFER chain, the reworked airplane
  control loops, SSTO phases, the drone. The legacy coupled solver
  (`_targetPatchElementsCoupled` and friends) is retired-in-place: the
  stale `deorbit_targeting -> maneuver_targeting` dep is already severed;
  delete the lib once the rendezvous/intersystem flows stop importing it.
- Useful sandbox: quick brace-balance check over edited `.ks` files (strip
  `//` comments and strings, count `{`/`}`) catches most structural slips.
