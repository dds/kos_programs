# Plan: Surface Return ESCAPE Storage Pressure

## Summary

After `cmd/surfacereturn.ks` configured the Mun surface-return flow, the vessel
successfully relaunched and reached the return setup handoff. On the reboot into
`ESCAPE`, the CPU ran out of local storage.

The likely primary cause is not the surface-return wrapper itself. The `ESCAPE`
band is already isolated, but it currently loads the same heavy generic
transfer stack as `XING`. For a Mun/Minmus-to-Kerbin return we only need a
small moon escape planner plus maneuver execution. Instead, the boot plan wants
the full local/interplanetary transfer machinery:

```text
state, logs, files, phases, dependencies, config, mission_type, core,
hohmann_transfer, countdown, solar, orbit_nodes, maneuver, lambert,
maneuver_targeting, lib_navigation, inclination, maneuver_intersystem,
orbit, lib_bplane_math, maneuver_transfer, xfer_plan
```

That is too much for a 100 KB volume once `boot`, `state.json`, the cached
mission config, the craft script, and required preamble libraries are also
present.

Recommended fix: split `ESCAPE` away from the generic `xfer_plan` root and give
Kerbin moon returns their own lightweight escape phase library. Also prune
one-time surface-return config after it is converted into active
Kerbin-return config.

## Field Evidence

### State At Failure

The vessel had already transitioned into Kerbin-return mode:

```text
vessel_name = FalconHeavy-Mun-SCISat-2
boot_count = 6
vehicle = FalconHeavy
target = KERBIN
payloads = LIST("RETURN")
lib_band = ESCAPE
mission_type = kerbin_return
mission_id = kerbin_return
mission_name = Return to Kerbin
phase = ESCAPE
```

The active return sequence was:

```text
mission_cfg_SEQUENCE =
  ESCAPE, COAST, MCC, AEROBRAKE, DESCENT, DONE
```

The cached band plan was:

```text
lib_band_phase = ESCAPE
lib_band_libs =
  state
  logs
  files
  phases
  dependencies
  config
  mission_type
  core
  hohmann_transfer
  countdown
  solar
  orbit_nodes
  maneuver
  lambert
  maneuver_targeting
  lib_navigation
  inclination
  maneuver_intersystem
  orbit
  lib_bplane_math
  maneuver_transfer
  xfer_plan
```

Important detail: the file listing did not include all libraries from
`lib_band_libs`. In particular, `orbit.ksm`, `lib_bplane_math.ksm`,
`maneuver_transfer.ksm`, and `xfer_plan.ksm` were missing from the shown local
`lib/` directory. That suggests boot had planned the band, began syncing and
loading it, then ran out of storage before all required files were present.

### File Listing At Failure

The volume was essentially full:

```text
Capacity     100000 bytes
Free Space      419 bytes
```

Notable local files:

```text
boot/boot.ks                 5258 bytes
run/state.json              15049 bytes
run/mission_cfg_overrides.ks  699 bytes
craft/FalconHeavy            2946 bytes
missions/FalconHeavy/mun_grand_tour_alpha.ks 1958 bytes
```

Notable loaded libraries:

```text
boot_lib.ksm           16162
dependencies.ksm        4962
state.ksm               2539
logs.ksm                3265
files.ksm               1222
phases.ksm              8030
config.ksm              1535
mission_type.ksm        1133
core.ksm                 374
maneuver_intersystem.ksm 2198
resume.ksm              2174
inclination.ksm         2365
lib_navigation.ksm      3817
lambert.ksm             2437
maneuver.ksm           10045
orbit_nodes.ksm         2061
solar.ksm               7067
countdown.ksm            407
hohmann_transfer.ksm    1878
```

The missing required libraries would have needed still more space, so the
failure is structural rather than a few bytes of incidental slack.

## Current Dependency Shape

`lib/dependencies.ks` currently maps:

```ks
"ESCAPE", LIST("xfer_plan")
"XING",   LIST("xfer_plan")
```

and:

```ks
"xfer_plan", LIST("maneuver_transfer", "orbit")
"maneuver_transfer", LIST(
    "hohmann_transfer",
    "maneuver",
    "maneuver_intersystem",
    "maneuver_targeting",
    "lib_navigation",
    "orbit",
    "lib_bplane_math"
)
"maneuver_intersystem", LIST(
    "lambert",
    "maneuver",
    "maneuver_targeting",
    "lib_navigation",
    "inclination"
)
```

That makes sense for generic `XING`, where the target might be local,
interplanetary, inclined, or require the legacy targeting helpers. It is
overkill for `ESCAPE` when the target is simply the current body's parent.

`phaseEscape` in `lib/xfer_plan.ks` calls `planTransfer(target, ...)`, and
`planTransfer` lives in `lib/maneuver_transfer.ks`. That one call drags in the
whole planner.

## Root Causes

### 1. ESCAPE Uses Generic Transfer Planning

For surface return, `ESCAPE` should mean:

```text
current body = Mun or Minmus
target body  = current body's parent, Kerbin
plan one moon-escape burn
execute it
advance to COAST
```

Instead, the current code enters the same planner used for arbitrary transfers.
That brings in local moon transfer, interplanetary Lambert, B-plane measuring,
legacy targeting, and navigation helpers.

### 2. One-Time Surface-Return Config Remains In State

The state dump still contains setup-only values after `RETURN_SETUP` has already
converted them:

```text
mission_cfg_PARKING_ALT
mission_cfg_LAUNCH_INCLINATION
mission_cfg_RETURN_SEQUENCE
mission_cfg_RETURN_PE
mission_cfg_RETURN_REENTRY_DIR
mission_cfg_RETURN_KSC_TARGET
mission_cfg_RETURN_ARM_CHUTES
```

Some of those are harmless, but they consume space in `state.json` and
`mission_cfg_overrides.ks`. The duplicated `RETURN_SEQUENCE` is particularly
unhelpful once `mission_cfg_SEQUENCE` has become the active return sequence.

### 3. Cached Band State Can Overstate What Actually Synced

The state says the `ESCAPE` band contains 22 libraries, but the file listing
does not show the final required files. This is a symptom of the storage
failure, not a separate design bug, but it can make diagnosis confusing.

## Options

### Option A: Split ESCAPE Into A Lightweight Return-Escape Library

Create a new library, for example:

```text
lib/return_escape.ks
```

Move or reimplement only the moon-parent escape behavior needed by Kerbin
returns:

```ks
GLOBAL FUNCTION phaseEscape {
    // target = BODY:BODY
    // plan Mun/Minmus -> parent-body periapsis
    // executeManeuver()
    // nextPhase(xferSeq)
}
```

Then change dependencies:

```ks
"ESCAPE", LIST("return_escape")
"XING",   LIST("xfer_plan")
"return_escape", LIST("maneuver", "orbit")
```

It may not even need `orbit`; `maneuver` already pulls `countdown`, `solar`,
and `orbit_nodes`, and `xferSeq`/`nextPhase` come from the core phase machine.
Keep the first version conservative and include `orbit` if `orbitSummary()` is
used.

Expected benefit: removes the need for these from the `ESCAPE` band:

```text
hohmann_transfer
lambert
maneuver_targeting
lib_navigation
inclination
maneuver_intersystem
lib_bplane_math
maneuver_transfer
xfer_plan
```

This is the largest and cleanest storage win.

Tradeoff: `ESCAPE` becomes specialized. If some non-return mission relies on
`ESCAPE` for a generic departure, it would need either the old planner under a
different phase or a config flag. In the current codebase, `ESCAPE` appears to
be used primarily as "leave child body for parent body", so specialization is
reasonable.

### Option B: Keep xfer_plan But Split maneuver_transfer Internals

Instead of adding `return_escape`, split `lib/maneuver_transfer.ks` into:

```text
lib/escape_transfer.ks       // parent-body escape only
lib/local_transfer.ks        // moon-to-moon/local transfer
lib/interplanetary_transfer.ks
```

Then `xfer_plan` could load only what each phase needs.

Expected benefit: cleaner long-term architecture.

Tradeoff: larger refactor, higher risk, and slower to flight-test. The current
need is narrower than this.

### Option C: Prune Surface-Return State Only

After `phaseReturnSetup`, remove one-time setup keys:

```text
mission_cfg_RETURN_SEQUENCE
mission_cfg_RETURN_PE
mission_cfg_RETURN_REENTRY_DIR
mission_cfg_RETURN_KSC_TARGET
mission_cfg_RETURN_ARM_CHUTES
mission_cfg_RETURN_DESCENT_*
mission_cfg_PARKING_ALT
mission_cfg_LAUNCH_INCLINATION
mission_cfg_LAUNCH_AZIMUTH
```

Keep active return keys:

```text
mission_cfg_SEQUENCE
mission_cfg_ESCAPE_PE
mission_cfg_CAPTURE_PE
mission_cfg_CAPTURE_INC
mission_cfg_AEROBRAKE_REENTRY_DIR
mission_cfg_AEROBRAKE_ARM_CHUTES, if enabled
mission_cfg_DESCENT_*, if enabled
mission_cfg_KEEP_WARP / COAST_*
```

Expected benefit: reduces `state.json` and `mission_cfg_overrides.ks`.

Tradeoff: not enough alone. The missing libraries in the dump are far larger
than the setup-state savings.

### Option D: Remove Optional Runtime Files Before ESCAPE

Try to delete cached mission profile, command files, logs, or other files before
loading the escape band.

Expected benefit: might recover a few kilobytes.

Tradeoff: this is fragile. The dump only has 419 bytes free before several
required libraries are even present. File pruning might help marginal cases,
but this one needs a band-size fix.

### Option E: Use Existing Heavy Planner But Fewer Extra Configs

Do not split code; just ensure `LIBS_EXTRA` is empty, reduce state, and keep
the existing `ESCAPE` band.

Expected benefit: smallest code change.

Tradeoff: likely insufficient. `mission_cfg_LIBS_EXTRA` is already removed by
return setup, and the heavy dependency chain remains.

## Recommended Plan

Do Option A plus the safe part of Option C.

### Step 1: Add `lib/return_escape.ks`

Implement a small planner based on the existing `_planEscapeTransfer` math:

```text
1. targetBody = BODY:BODY
2. targetPe = ESCAPE_PE, defaulting to REENTRY_PE or 30000
3. compute two-level vis-viva seed
4. create a prograde node near next periapsis
5. optionally scan departure time over one local orbit
6. optionally scan/refine prograde dV
7. executeManeuver()
8. nextPhase(xferSeq)
```

For first flight, keep the KSC longitude targeting optional but consider
leaving it out if `RETURN_KSC_TARGET` is false. In the provided state,
`RETURN_KSC_TARGET = 0`, so we do not need KSC-targeting code for this mission.

Minimum viable version:

- no Lambert
- no B-plane math
- no generic `newtonTarget`
- no interplanetary planner
- no local moon target planner
- no `lib_navigation`
- no `inclination`

### Step 2: Change Dependencies

Change:

```ks
"ESCAPE", LIST("xfer_plan")
```

to:

```ks
"ESCAPE", LIST("return_escape")
```

Add:

```ks
"return_escape", LIST("maneuver", "orbit")
```

Leave:

```ks
"XING", LIST("xfer_plan")
```

unchanged.

This preserves the generic departure planner for Kerbin launches and local
moon/interplanetary transfers.

### Step 3: Keep `phaseEscape` Binding Stable

`dependencyBindPhase` can still bind:

```ks
phaseMapSet(phaseMap, "ESCAPE", phaseEscape@)
```

as long as `return_escape.ks` exports `GLOBAL FUNCTION phaseEscape`.

That avoids changing mission sequences.

### Step 4: Prune One-Time Surface Return Keys

In `phaseReturnSetup`, after writing active return config, remove keys that are
only useful before return setup:

```text
RETURN_SEQUENCE
RETURN_PE
RETURN_REENTRY_DIR
RETURN_KSC_TARGET
RETURN_ARM_CHUTES
RETURN_DESCENT_FAIRING_TAG
RETURN_DESCENT_DECOUPLER_TAG
RETURN_DESCENT_CHUTES_TAG
PARKING_ALT
LAUNCH_INCLINATION
LAUNCH_AZIMUTH
```

Be careful not to remove the active keys that downstream phases read.

### Step 5: Add Storage Telemetry

Add a `STATS` line in `phaseReturnSetup` or `return_escape` showing:

```text
phase=ESCAPE
free=<CORE:VOLUME:FREESPACE>
sequence=<return sequence>
```

This makes the next field report easier to compare.

## Proposed Lightweight ESCAPE Dependencies

Current planned ESCAPE band:

```text
state
logs
files
phases
dependencies
config
mission_type
core
hohmann_transfer
countdown
solar
orbit_nodes
maneuver
lambert
maneuver_targeting
lib_navigation
inclination
maneuver_intersystem
orbit
lib_bplane_math
maneuver_transfer
xfer_plan
```

Target lightweight ESCAPE band:

```text
state
logs
files
phases
dependencies
config
mission_type
core
countdown
solar
orbit_nodes
maneuver
orbit
return_escape
```

If `orbitSummary()` is not necessary in `return_escape`, remove `orbit` too.

## Risks

### Risk: Simpler escape planner gives less accurate Kerbin periapsis

The current generic planner runs scans and then generic targeting. A lighter
planner may be less precise.

Mitigation:

- retain the existing `_planEscapeTransfer` time and prograde scans in the new
  library;
- keep MCC immediately after `COAST`, which can correct the arrival;
- accept a rough Kerbin encounter as long as it has a real Kerbin patch.

### Risk: Some mission uses ESCAPE for a generic non-return departure

Mitigation:

- search mission profiles before changing;
- if needed, introduce a separate `GENERIC_ESCAPE` or keep a config flag:
  `ESCAPE_PLANNER = GENERIC`.

Current evidence points to `ESCAPE` being a parent-body escape phase, so this
is probably low risk.

### Risk: Removing setup keys loses operator visibility

Mitigation:

- log the copied values before deleting them;
- keep active return keys in `mission_cfg_*`;
- do not delete `mission_name`, `mission_id`, `target`, or `payloads`.

### Risk: The actual bottleneck is boot preamble size

The preamble is large, but the file listing shows the failure occurred while
trying to load a heavy phase band. A smaller `ESCAPE` band is still the right
first fix.

## Non-Goals

- Do not rewrite the generic `XING` transfer planner in this pass.
- Do not remove `maneuver_transfer` from Kerbin launch transfers.
- Do not change return mission sequence names.
- Do not depend on manual deletion of files from the kOS console.

## Acceptance Criteria

A successful fix should produce a post-return-setup reboot where:

1. `phase = ESCAPE`
2. `lib_band = ESCAPE`
3. all required `lib_band_libs` files are present locally
4. free space is comfortably above emergency margin, ideally at least 10 KB
5. `phaseEscape` can plan and execute a moon escape burn
6. after the burn, the mission advances to `COAST`
7. later `MCC`, `AEROBRAKE`, `DESCENT`, and `DONE` continue to band-load
   normally

## Suggested First Implementation

1. Add `lib/return_escape.ks`.
2. Copy only the parent-body escape math from `_planEscapeTransfer`.
3. Remove generic dependencies from `ESCAPE`.
4. Add one-time return setup cleanup.
5. Push and flight-test the same surface-return scenario.

This keeps the patch small, makes the storage win large, and leaves the
existing generic transfer system intact for normal launch-to-target missions.

