# Flight automation work

Updated 2026-10-27. Keep this list current as scope changes. A source check
passing is not native flight validation. Preserve mission safeguards and
record remaining uncertainty before closing a task.

## In progress

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

- [ ] **Emergency hyperbolic-capture burn safety.** The separate legacy
  `_aerobrakeBrakingBurn` starts full throttle before verifying alignment and
  lacks the powered assist's live Abort/freshness guards. Consolidate its
  alignment and cutoff contract without weakening emergency capture, Pe
  floor or fuel protections. This is separate from the optional finite assist
  and its new between-pass staging, which require an already bound orbit.
- [ ] **Kolniya-to-landing approach preparation.** After the first orbit
  objective, manual SCIENCE_OPS release and waypoint selection, compare
  direct powered descent, a later ground-track opportunity, and a preparatory
  orbit change. Minimize combined prep/deorbit/descent cost; preserve the
  waypoint and return reserve. Prefer low-speed plane intersections; do not
  assume apoapsis is a valid plane-change point or circularize by default.
  Use a distinct resumable phase if needed; sequences cannot repeat SHAPE.
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
- [x] First automated Mun landing and return to Kerbin succeeded. This is
  a milestone, not proof that targeted landings or fuel use are optimal.
