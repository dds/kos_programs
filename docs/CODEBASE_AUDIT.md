# Komptroller codebase audit

Reviewed 2026-10-16, starting at `cf9a544`. Scope: all 249 KerboScript files,
74 shipped profiles, dependency and phase metadata, boot/configuration order,
recovery paths, and the offline regression suite. The structural scan covers
the whole repository; manual control-flow review concentrated on boot,
storage, maneuver execution, landing, rendezvous, and payload handoffs.

The phase/band architecture fits resumable career missions, but several
refactors left callers, configuration declarations, and loading metadata out
of agreement. Those linkage defects are more actionable than rewriting the
flight solvers. Smaller phase bands improve storage without weakening the
departure, capture, landing, or reserve checks.

The system still cannot guarantee an entire mission through arbitrary
offline reboots. KSC return recipes also currently lack their atmospheric
deorbit handler. These remain functional gaps, even though offline fixtures
pass. No changes in this audit have been flight-tested in KSP.

## Repairs made

| Area | Finding and resulting behavior |
|---|---|
| Final boot configuration | `resume.ks` redeclared target, payload and rendezvous settings after the final mission profile. Defaults now stay in `boot_lib`; resume preserves the selected configuration. Legacy name-driven sequences recover payload hints from state; a selected profile clears those hints even when its payload list is explicitly empty. |
| Profile-less craft | The installed boot invokes the generic planner before loading craft scripts, bypassing their default-library hooks. The planner now loads safe craft hooks when no profile sequence exists. `X_SHOT`, whose top-level code launches the vessel, stays at its original boot entry point. |
| Library registry | `BOOT_LIB_RAN` was never updated by the loader. The SCANsat landing-site gate could never see `landing_site`. Successful loads now register; skipped archive libraries do not. |
| Flight dependencies | `deorbit_targeting` called an executor absent from its closure; `scansat_ops` required science functions without declaring them; `lander_cpu` used science while its custom phase names resolved only core libraries. Molniya and inclination also lacked their orbit-summary and maneuver-diagnostic dependencies. These edges are now explicit. |
| Offline current bands | B-plane math was globally archive-only despite being needed by in-flight BPLANE/FREE_RT. It is now cached. MCC also caches its targeting helper instead of silently skipping it on an offline reboot. Future-band availability remains a separate issue. |
| Cleanup | Source cleanup deleted overrides and source-only craft/runtime libraries. It now retains overrides, profiles, the installed boot, and source files without a compiled replacement. |
| Rover configuration | The controller read 20 undeclared `ROVER_*` globals while an unused dictionary held their intended values. Those values now initialize the actual globals. The rover phase belongs to `rover.ks`, eliminating the unrelated landing dependency. |
| Rover dispatch | Empty configuration became `DONE` before the craft fallback could run; its main also omitted shared sequences. Defaults and shared sequence initialization now work, and shutdown no longer spins the phase runner. |
| Science and telemetry | Science logging used an undeclared interval; its historical 60-second value is restored. Drone telemetry no longer reads absent airplane variables. The drone library's resource threshold now uses the same percent units as its resource check and craft defaults. |
| Phase failures | A failed targeted deorbit advanced toward probe release. `LAND` advanced even after an aborted descent. Both hold on failure; unavailable landing tracks release controls and stop before calling missing guidance functions. |
| Compact deorbit burn | Startup could activate every inactive engine, and timeout/thrust-loss exits reported success and deleted all nodes. It now uses bounded next-engine staging, honors abort, gates alignment, tapers without a throttle floor, caps measured thrust/mass impulse independently of the node, and retains an incomplete node. Successful execution removes only its own node. |
| Rendezvous | MATCH skipped missing targets and could report success after five passes at an unsafe distance or relative speed. It now holds on missing/wrong-SOI targets, failed velocity burns, abort and unmet arrival criteria; coasting is bounded and final relative velocity must be below 0.2 m/s. |
| Diagnostic settings | Archive maneuver diagnostics reset `BURN_BRIEF` every invocation. Defaults now belong to the executor, preserving operator settings. |
| Duplicate implementations | Removed superseded ESCAPE and landing phase exports from unrelated libraries. Their dedicated implementations and safeguards remain. Removed unused configuration dictionaries and an exactly repeated SCANsat enable predicate. |
| Profile identity | Renamed the KA201 file to match its existing `MISSION_ID`, preserving the identifier already persisted by vessels. |
| Operator commands | The wrong-body guard in `kscsplash` logged an error and continued into planning. It now returns. Legacy FR2 RECIRC/DEPLOY_SAT paths explicitly hold instead of calling a missing planner or claiming unimplemented deployment succeeded. |
| Verification | Replaced the hook for a missing dependency generator and the empty Make target with `make check`. Updated the stale two-axis recovery check to execute the current three-axis source through the existing harness. Added repository-contract and runtime-failure fixtures. |

## Loading reductions

The old PAYLOAD_OPS band loaded probe deorbit, probe release, ordinary relay
operations, and constellation insertion together. Relay work therefore paid
for the precision deorbit solver and unrelated planners. Ordinary relay and
constellation operations now have separate bands. TARGETED_DEORBIT and
RELEASE_PROBE remain together, avoiding a new reboot between the deorbit
burn and probe separation.

Counts below include the dependency closure and core libraries, excluding
boot/resume/craft scripts and mission extras. Tokens count identifiers and
punctuation after comments and strings are masked. They measure source
complexity, **not compiled KSM bytes or a guarantee that a core will fit**.

| Operation | Libraries before → after | Source tokens before → after |
|---|---:|---:|
| Ordinary relay | 21 → 12 | 30,202 → 9,988 (67% lower) |
| Relay constellation | 21 → 15 | 30,202 → 20,026 (34% lower) |
| Probe deorbit/release | 21 → 18 | 30,202 → 20,490 (32% lower) |
| Rover | 12 → 9 | 10,605 → 8,393 (21% lower) |
| Landing deorbit | 16 → 17 | 18,536 → 19,561 (6% higher) |

Landing deorbit deliberately adds the shared engine-selection/staging policy
and an independent impulse limit. Deleting checks to recover those bytes
would recreate the defects this audit addresses. Use `make audit` to inspect
the current band sizes; actual storage admission needs in-game KSM sizes.

## Remaining work in priority order

1. **Restore atmospheric KSC deorbit as a separate, validated behavior.**
   `phaseKscDeorbit` was removed in `0b14227` when `deorbit_targeting` was
   replaced with a vacuum landing solver. Its binding, eight shipped profiles,
   and `landat`/`landatksc` command flow survived. Binding now guards the absent
   delegate so `runPhases` logs and holds. The new vacuum solver targets a
   10–20 km downfield impact for powered braking; substituting it for the old
   atmospheric entry, orbit-stay/biome, and impact-walk behavior would not
   preserve the recipe. Restore a dedicated atmospheric library and verify
   reboot-after-burn handling, reentry Pe, orbital stay, and touchdown error.

2. **Make offline loading an explicit mission contract.** `bootCleanup`
   keeps the current band, while `runPhases` can reboot into a future band
   whose files were never cached. XING planners remain archive-only, and
   `landing_main` dynamically fetches coast/brake tracks before reclaiming
   their disk files. Current-band caching fixes do not solve those future
   transitions. A planner should calculate the files needed until the next
   guaranteed link, measure their compiled sizes, and refuse departure or
   show an explicit hold if they cannot fit. Landing must verify all required
   guidance is resident before committing to impact. Exercise this on real
   10 KB and 100 KB cores with the link disabled across power cycles.

3. **Make state replacement recoverable.** `state.ks::_flush` deletes
   `state.json` before writing its replacement. Power loss between operations
   can lose the phase and burn ledger. Multiple `stateSet` calls also expose
   intermediate records. Preserve the lazy-load guard and the durable
   departure/phase ordering. Design a bounded generation/backup protocol
   against actual kOS file semantics, and test interruption at every write.
   Also define value/ownership semantics for lists and lexicons: `stateSet`
   currently uses string representations to decide whether a write is needed.

4. **Unify the guarantees of propulsion paths.** The main maneuver executor
   has live-lock freshness/impulse checks and physical cutoff verification;
   compact deorbit now has a loop-level impulse limit but lacks the same
   scheduling watchdog and physical shutdown verification. Rendezvous,
   atmospheric walks, drones and descent have other controllers. Extract
   small shared cutoff primitives only after their scheduling and byte costs
   are measured. Keep controller-specific staging and trajectory limits.
   A hung control loop or persistent physical thrust needs a KSP test, beyond
   the point-mass fixtures added here.

5. **Finish or narrow advertised automation.** `scienceInit` detects biome
   and situation changes but its change branch is still a placeholder.
   FSP1 marine operations are explicitly unimplemented. Rendezvous still
   uses future `VELOCITYAT` vectors and uncalibrated node-basis signs despite
   the documented frame hazards. Fix those using measured frame references
   and real rendezvous flights before calling rescue automation proven.

6. **Reduce ownership and profile drift.** Shared config defaults are
   redeclared in many libraries; boot's final profile replay masks most
   conflicts, but ad-hoc library loads can still reset values. Falcon and
   FalconHeavy duplicate shared rocket helpers; RO8 and RO9 duplicate profiles.
   Consolidate only with sequence/config parity checks and measured per-core
   storage results. Removing `maneuver_targeting` wholesale is unsafe:
   `maneuver_mcc` still calls its coupled solver and return Pe targeting,
   while local/interplanetary planners use its patch and axis helpers.

## Validation and flight follow-up

`make check` runs all 17 check scripts, including the structural scan of 249
scripts, 74 profiles, 67 phases and 29 bands. The scan emits a warning for
the intentionally guarded missing KSC handler. Existing maneuver cutoff,
departure corridor, return reserve, launch/staging, and landing geometry
fixtures remain in the suite. New fixtures cover boot defaults and load
registration, cleanup persistence, failure handoffs, compact burn completion
and interruption, and rendezvous arrival criteria. Python 3 and NumPy are
required for the numerical fixtures.

These checks execute selected source expressions/control flow or inspect
repository contracts. They do not compile KerboScript, model the real part
APIs, prove attitude stability, or measure KSM storage. Next flight checks:

- Boot a profile-less aircraft and rover, and reboot with an existing mission
  profile; verify target/payload/rendezvous settings survive.
- On a staged test vessel, test deorbit success, exhausted thrust, abort and
  cutoff; verify reserved engines remain inactive and failed nodes remain.
- Test BPLANE and MCC reboots offline after caching their current bands,
  separately from the unresolved offline future-band problem.
- Test MATCH at close range with substantial relative velocity, a wrong-SOI
  target, failed thrust and abort; CREW_XFER must require a verified arrival.
- Measure actual compiled storage, including the added staging helper, on the
  smallest cores before relying on the revised landing-deorbit band.
