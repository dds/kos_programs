# Flight automation work

Updated 2026-10-31. Keep this list current as scope changes. A source check
passing is not native flight validation. Preserve mission safeguards and
record remaining uncertainty before closing a task.

## Compact working handoff

- ACTIVE31Oct: Minmus Espoir additions requested. Survey flight must achieve
  Ap1041045/Pe465764m, inc21.6/LAN255.5/AoP157.3deg, then change to polar
  mapping and start scanners on the COMPLETE probe (explicit user answer;
  no payload separation). Separate lander should allow repeated land ->
  orbit -> selected-site land excursions, coordinates supplied later. Keep
  profiles simple; add guarded reusable orbit/site commands sharing existing
  SHAPE/airless ascent/landing, preserve mission identity/progress and KAC
  waits. Existing cmd/setorbit removes nodes and is circular-only; existing
  surfaceorbit rewrites a Kerbin-return mission. Do not reuse those mutation
  paths blindly. Need per-visit surface-science context so a second site can
  gather new readings; stop after each site for commands. Implementation not
  yet started. Working idea: lean operations review, command-scoped sequences
  and existing flight phases; no bespoke repeated mission phase chains.
  Solar hold drift follow-up completed below. User confirms re-aim happens soon, wants
  fixed attitude/no deliberate rotation and one quick second verifying low
  residual motion. Found old settle threshold0.03rad/s (~1.72deg/s), and
  waitForSOI calls orientForSolar() with default lockSteeringFALSE. Fix both
  continuous one-second settling and retained coast steering; keep deadlines,
  cache reuse, wide readout tolerance and re-aim recovery. Do not add spin.

- 31Oct solar fixed-hold patch checked: native Duna Lander2 reports5082559814
  and5082641514 accepted7.244/7.401deg error with0.0282/~0.0292rad/s (about
  1.6deg/s). Replaced0.03rad/s endpoint check+blind1.5s wait with continuous
  0.1s polling,1 quiet second and0.1deg/s total-rate ceiling. Preserve initial
  acquire vs wider readout tolerance, one original turn/deadline, Abort,
  cache/flow/eclipses/CPU policies. SOI/scanner/relay coasts explicitly retain
  the anchored Sun-following steering lock; aim-only API default unchanged.
  No spin, raw steering, PID tuning or RCS introduced. SOI epoch now bounds
  solar work with or without KAC; existing alarms still precede aiming.
  Logs add rateDeg/stableSeconds/steeringHeld and recorder settle metadata.
  Exact native spin regression refuses false settlement; already-quiet case
  finishes in1..1.2s; damping/transient disturbances, no-KAC SOI coasts and
  all finite-turn/readout/recorder cases pass. All93 routine files pass193.77s;
  structural348/88/79/40,0 errors/unchanged KSC_DEORBIT warning. Report:
  /tmp/kos-solar-hold-final-20261031.json and.log. No production changes after
  final suite. One older SOI fixture updated to accept/assert explicit hold
  arguments. Native post-update rate decay/long hold still to verify after a
  connected coast reboot. Evidence:/tmp/ksp-deck-20261031T152312Z-fetch-
  {k75ern92,u7itxz52}/logs/_diagnostics/ (those two solar reports).

- 30Oct Kerbin Espoir profiles implemented/checked: user requests local surveying and
  landing, coordinates forthcoming; explicitly selected parachutes with
  optional engine assistance. Added kerbin_orbital_surveyor/kerbin_lander,
  both100km polar parking/SHAPE, no transfer/capture/body-orbit launch mode.
  Mapper retains entire probe with existing power management; lander stops
  at LANDING_REVIEW with target unlocked, uses existing cmd/landsite when
  coordinates/waypoint are ready. Kerbin entry52+/-1km (not Duna5km), SUNLIT,
  radioAUTO/requireKerbin0 (self-center is not a ground-station sightline).
  New ENTRY_LANDING_REQUIRE_POWER defaults1; Kerbin explicitly0 while keeping
  ENTRY_POWERED_LANDING1 to attempt measured-authority terminal help. Required
  Duna TWR/300m/s policy untouched. Optional Kerbin preflight still requires
  actual active engine/deorbit fuel plus50m/s, attached stock chutes and valid
  finite measurements. Runtime stopping/attitude/live throttle guards unchanged;
  no automatic staging. Surface science now accepts settled SPLASHED too,
  preserves native status in science context and stops if it changes.
  Focused local launch/profile/site/entry tests pass, including sub-unity
  Kerbin TWR and unchanged required-powered refusal, retained Pe corridor,
  weak-engine science/chute continuation and splashdown session/status change.
  Structural348 scripts/88 profiles/79 phases/40 bands,0 errors/known warning.
  All93 routine files pass131.94s; new Kerbin cases<0.07s. Report:
  /tmp/kos-espoir-kerbin-20261030.json and.log. No production changes after
  the full pass. Native52km TR footprint/chute performance and
  optional engine assistance remain unverified; no fake impact/deeper-entry
  fallback. No launch/selection/game-state modification performed.

- 30Oct native fleet update, operator UT5035205: archived logs show Duna
  Lander1/Lander2 past XING into BPLANE/Sun-SOI coast; Ike Lander1 completes
  XING at5035220.6 and hands off through ASSIST. Both recorded XING tail
  residual holds retain a Duna patch: Duna Lander1 cutoffRem0.058263865 /
  sampled0.07379429 (axis trim, limit0.05), Ike Lander1 cutoffRem0.048679966 /
  sampled0.054309281 (full trim, limit0.051). thrustStopped=True. Operator
  confirms no stale node/interrupted state. Code already reconciles actual
  trajectory with maneuverAcceptHandoff/_ren/_cpb; this is an explanation
  gap, not evidence to relax the residual guards. Added a separate durable
  last_burn_handoff diagnostic and protected summary after existing cleanup;
  burnreport prints it alongside unchanged strict cutoff evidence. Fresh
  cutoff clears stale handoff diagnostics. Successful transfer handoff rows
  now say decision=continue and use summary priority. Targeted burn completion,
  watchdog, launch/staging, transfer retry, arrival review and entry-recovery
  fixtures pass; exact native residual regression verifies guards still
  reject, handoff cleanup/persistence/reporting and original evidence remain.
  Structural audit0 errors/unchanged KSC_DEORBIT warning. Native richer
  handoff logging will appear after pulling/rebooting for a subsequent burn.
  Next useful flight: Duna Lander2 after Kerbin exit nearUT5114737.784;
  Duna Lander1 exitUT5121323.830. Check first heliocentric BPLANE actual
  correction/capture affordability and70km polar goal, then midpoint preview
  if explicitly enabled. Duna arrivals currently9406062.142 and10036152.933.
  Solar follow-up: Duna Lander1 XING search reached axis5 flow0.76 but left
  only12.85s for best-hold, which timed out; later flow0.2326. Duna Lander2
  six axes all0 at93.3pct battery, compatible with eclipse; no proof of a
  panel-direction defect from that log. No flight control/settings changed.
  Evidence:/tmp/ksp-deck-20261031T005219Z-fetch-{1rkb4hmc,umo9ymqw,
  rz0skzsz,zwbwr6bd,m6vatjok}/logs/ (boot004/006 Duna Lander1, boot005
  Duna Lander2, boot004 Ike Lander1, boot003 Ike Surveyor1 respectively).

- 30Oct implemented/checked; native flight validation pending: Espoir now
  has four canonical choices: Duna/Ike70km polar surveyors, Duna70km polar
  lander, Ike25km polar lander. Retired duna_impactor/duna_science_impact ids
  alias to duna_lander without resetting durable identity. Old generated
  Ike ops goals upgrade only while safely uncommitted in orbit. Both landers
  stop at LANDING_REVIEW for surveyed coordinates; cmd/landsite.ks uses the
  selected same-body waypoint or explicit lat/lng, persists a fixed target
  and advances only from a safe idle orbit. Unselected old LAND_DEORBIT is
  redirected before any node deletion/search. Direct Kerbin15deg policy
  retained, plus new ancestor occultation ray check (Ike behind Duna).
  Duna ATMO_DEORBIT uses native TR footprint in fixed spherical tangent
  coordinates, bounded ground survey4096 samples and time/normal coupled
  solve64 native probes; Pe5+/-3km, footprint1.5km,normal10m/s,total150m/s,
  terrain5deg/light/radio and fresh owner/intent/preburn checks retained.
  Existing compact executor supplies KAC/solar/polling/cutoff; its new
  allowStage parameter defaults true for existing missions but is false
  on this measured-active-engine atmospheric path. Owned failed probes
  removed, foreign/interrupted nodes preserved; retry command generalized
  to Ike and atmospheric deorbit. Shared airless descent retained for Ike,
  with validated staging model credit enabled (old powered-lead+credit0
  combination could never run that model).
  Duna terminal controller loads only for ENTRY_POWERED_LANDING, leaving
  ordinary science entry lean. Measured active-stage TWR>=1.5, attached stock
  chutes and300m/s terminal fuel beyond deorbit required; no future-engine
  credit or automatic staging. Drag/chutes handle high/fast entry, then
  descending stopping curve and<=20deg lateral effort; no hover for a remote
  miss. Live alignment/pilot/vessel/stage/stale/contact cutoffs, shared
  verified stop, nominal50ms control delay beside0.5s science pulses and compact5s terminal
  telemetry. Safe chute requests and600s post-touchdown science retained.
  Native capture/drag/chute/targeting/touchdown still unverified. Hardware
  question pending (attached engine/chutes and actual Duna TWR/fuel); generic
  source checks cannot establish a particular probe can land. Legacy
  ATMO_WALK is deliberately not wired: timeout can permit unaligned burn.
  Final routine suite: all92 files pass180.61s, new individual cases<=0.413s;
  structural346 scripts/86 profiles/79 phases/40 bands,0 errors and unchanged
  legacy KSC_DEORBIT warning. First run found two legacy fixtures missing the
  default-off review flag; fixed fixtures, then reran the whole suite against
  unchanged production code. Source checks cover spherical time/normal fit,
  node/target takeover, fresh/retained/flown handoff, hardware/radio/terrain
  rejection, review command and old-id/profile boot behavior, independent
  variable-mass/drag descent plus resident science/control cleanup. No source
  changes after final suite. Report:/tmp/kos-espoir-polar-landing-final-20261030.json
  and.log. Next: pull/reboot connected before arrival; at LANDING_REVIEW select
  a surveyed same-body waypoint, RUNPATH("0:/cmd/landsite.ks"). then REBOOT.
  Capture logs for native footprint convergence and terminal control/chutes.

- Earlier30Oct (entry-only policy superseded above): user added four
  parachutes to a Duna science impactor and welcomes
  opportunistic landing. Keep duna_impactor mission id/entry5km+/-3km/sequence;
  display name now Duna Atmospheric Science. Profile enables new
  SCIENCE_ENTRY_CHUTES=1 (shared default0). Tiny inline helper requests native
  CHUTESSAFE repeatedly only during primary atmospheric descent at1x, active
  vessel, Abort clear and physical/raw/pilot throttle zero. No staging,
  forced deploy, pressure/full-open changes, powered landing or new band.
  Stock ModuleParachute support verified in official kOS docs/VesselUtils.cs;
  RealChute not forced. Empty/safe getter is not interpreted as landing proof.
  Existing60s landed science remains. cmd/entrychutes.ks,0/1 writes only its
  override for reboot. Source fixtures cover four partially safe chutes,
  changing safety/no hardware and flight/control/config refusals plus real
  entry phase/surface dwell/command. Read-only Deck GameData lists ReStock
  and no RealChute directory. All89 routine files pass133.01s; new chute
  policy regression0.020s, structural0 errors/unchanged legacy KSC_DEORBIT
  warning. Report:/tmp/kos-duna-entry-chutes-20261030.json and.log. Native
  parachute deployment and survival depend on actual hardware/mass/settings/
  terrain, still unverified.

- 30Oct user authorizes opt-in automatic midpoint diagnostics. New
  cmd/assistmcc.ks,1 (or0) saves ASSIST_MIDCOURSE_PREVIEW, default0; reboot
  loads assist_midcourse/shared search+baseline+archive helpers only in
  enabled interplanetary XFER_BPLANE. No new phase/bootstrap, automatic
  candidate installation or assist execution. REFINE previews a planned
  correction before fresh direct admission/reserve/burn; pristine/accepted
  minimum paths create/remove a zero-dV seed. Native context/owner helpers
  shared. Bound started/done marker saves before probing and prevents
  repeat/reboot scans; interrupted preview holds before any node replan,
  including when disabled. Explicit arrival action replan clears marker
  and discards node. Existing KAC/midpoint schedule,64/1536/20game/30wall,
  50m/s radius, science-extra0 and180s ignition margin retained. Archive
  assistmcc_<craft>_<UT>.log reports original vector, native patches, policy,
  results and elapsed; no-link/unsafe timing/unsupported/late-retry skips.
  Verified compute expiry continues direct; restoration/context changes
  hold and preserve foreign edits. Real-source synthetic search/seed/phase/
  loading/command fixtures pass, including a corridor that changes during
  preview: the no-correction path rechecks before advancing. All89 routine
  files pass134.11s; every new case<0.77s. Structural0 errors/unchanged legacy
  KSC_DEORBIT warning. Final report:/tmp/kos-assist-midcourse-final-20261030.json
  and.log. Two old archive-writer assertions now check actual flight closures
  rather than forbid declaring an optional dependency. No source edits after
  final full suite. Native midpoint run and successful acquisition/adoption
  still need flight proof.

- 30Oct native assist preview5028809 confirms bounded-native-drift-v2 works:
  reference verified, drift0.000631781m/s within0.005312796 tolerance;
  priceGuardDv0.010625592. Actual search runs62 node probes/667 position
  samples in17.86game/18.15wall seconds. No admissible assist, restored=True,
  noBurn=True, cancelled=False. Tiers33 unscored/29 closest-approach/0 moon/
  0 terminal/0 proven route; bestTier0 loss18.84796 (distance/Ike SOI radius),
  offsets(12.5,37.5,0)m/s within50m/s radius. Original Duna Pe27,388.6km.
  No Ike encounter acquired in this fixed-epoch bounded search; this does
  not prove none exists, nor validate an assist/capture flight. Keep the
  original powered transfer; later targeted correction/capture nodes may
  be more informative. Native search/normal restoration now observed;
  successful acquisition/final admission remain unverified.
  Evidence:/tmp/ksp-deck-20261030T223739Z-fetch-uu8a1xet/logs/_diagnostics/
  assistsearch_Espoir-Duna-Surveyor1_5028809.log; matching boot006 in
  fetch-uqqe6rv9/logs/Espoir-Duna-Surveyor1_5026703/boot_006_core.log also
  confirms initial XING six-axis solar search returns aimed=True/flow1.09.

- 30Oct native assist preview5027117 confirms reference-node-dv-changed:
  snapshot1062.33770850232/live1062.33822439338m/s, drift0.000515891m/s.
  Snapshot-price fix works, but original1e-5 derived-magnitude tolerance
  rejects with raw PRN/UT ownership unchanged. No trials/burn; node restored.
  Calibrate that check to5ppm bounded1..10mm/s; raw ownership1e-5, exact
  price>=its own snapshot, native itinerary/capture/timing proofs unchanged.
  Twice the allowance is charged against savings, optional science spending
  and fuel reserve; initial/final cost comparison shared, final fuel freshly
  rechecked. referencePolicy=bounded-native-drift-v2, DV_TOLERANCE and
  priceGuardDv identify/report the change. Source fixtures replay measured
  drift, tolerance boundaries, tiny raw edits, price/science/fuel limits.
  All88 routine files pass133.06s; new measured-drift regression0.015s,
  structural0 errors/unchanged legacy KSC_DEORBIT warning. Report:
  /tmp/kos-assist-native-drift-20261030.json and.log. Native retry pending.
  Evidence:/tmp/ksp-deck-20261030T222115Z-fetch-p24ztiga/logs/_diagnostics/
  assistsearch_Espoir-Duna-Surveyor1_5027117.log; matching boot004 in
  fetch-faou9mhu/logs/Espoir-Duna-Surveyor1_5026703/boot_004_core.log.

- 30Oct native assist preview5027687: Espoir-Ike-Surveyor1 is currently using
  duna_orbital_surveyor (craft name differs), fuel3907.233m/s, node1062.42445,
  Duna Pe32,409km. New rough-arrival policy runs, but reference consistency
  rejects before trials in0.04game/0.048wall seconds; restored/no burn.
  Likely micro-drift issue: price sampled ND:DELTAV:MAG earlier, exact
  COST>=freshMAG inequality contradicts the existing1e-5 snapshot/live
  tolerance. Both adapter price and NODE_DV now use one snapshot; cost still
  covers its own node snapshot exactly, live1e-5 and raw PRN/UT ownership
  checks unchanged. Full and parent-prefix capture pricing unchanged.
  New reference-check records numeric cost/snapshot/live/drift/epoch and
  specific bound/goal/price/identity reasons on first/final validation.
  referencePolicy=snapshot-price-v1 identifies updated diagnostics. Synthetic
  micro-drift reproduces old refusal; unchanged tolerance/underprice/goal/
  bound/epoch and takeover guards pass. Exact native cause remains unproven
  until the new check row is captured; do not blindly widen its tolerance.
  Evidence:/tmp/ksp-deck-20261030T215401Z-fetch-4bg87pes/logs/_diagnostics/
  assistsearch_Espoir-Ike-Surveyor1_5027687.log; matching boot005 in
  fetch-w0rm9hwq/logs/Espoir-Ike-Surveyor1_5026714/boot_005_core.log.
  Boot005 confirms initial XING solar aim succeeds:5027610.7..5027647.5,
  cached-axis settle then bounded fine probe/return; flow1.08, battery85%,
  aimed=True/parkedDeparture=True. Native T-180 burn reacquisition unverified.
  Operator advised normal XING can proceed (preview did not change node),
  first of each role before duplicates, but park fleet first and use actual
  departure/alarm order to preserve the pending Mun return appointment.
  All88 routine files pass179.64s; new snapshot regression0.030s, structural
  0 errors/unchanged legacy KSC_DEORBIT warning. Report:
  /tmp/kos-assist-reference-snapshot-20261030.json and.log. Native reference
  retry remains pending; new diagnostics can confirm or falsify micro-drift
  as the cause of this specific native refusal.

- 30Oct long-XING solar request: the executor already had a solar hook but
  XFER_PLAN omitted the library. xfer_plan now declares solar; maneuver itself
  remains independent so other burn bands may shed it. Long-coast threshold
  unchanged (>8min before centered ignition). One initial cached-axis-first
  aim, existing KAC-before-solar and optional warp policy; search and health
  maintenance share the existing ignition-180s realignment deadline. Verified
  idle bound parking orbit above atmosphere with no next patch may bypass
  launch-age/first-boot guards; other contexts retain them. Initial aim skips
  absent solar/Abort/nonzero controls/physical thrust/invalid deadlines.
  Solar failure is nonfatal; the executor still reacquires the burn vector
  at180s,60s,10s and ignition. Focused actual alarm/coast/relock source fixture
  covers early/short waits, failed/deadline/unavailable solar, unsafe controls,
  normal guards, no KAC and unchanged disabled automatic warp. Structural
  audit0 errors/legacy KSC_DEORBIT warning. All88 routine files pass134.41s;
  report:/tmp/kos-xing-solar-20261030.json and.log. New test originally took
  5.125s reparsing each simulated health tick. Preparing fixture code once
  preserves every tick/guard and reduces it to0.100s; the complete solar
  fixture rerun passes in0.911s. Supplemental report:
  /tmp/kos-xing-solar-focused-20261030.json and.log. No production edits after
  the full suite. Native solar-coast/reacquisition validation remains pending.

- 30Oct native assist preview5027134 fetched, Espoir-Ike-Surveyor1/XING:
  departure1061.872m/s, available3928.312, Duna Pe29,308,980m vs85km fallback.
  Stopped in0.02game/0.029wall seconds before any trial, reason
  original-node-capture-not-validated, restored=True/noBurn=True. Matching
  boot004 deliberately allows this rough transfer for later BPLANE targeting.
  Extend the existing departure-only LOWER reference to XING ORBIT goals
  at the same planet or its immediate moon; source pending-capture. Preserve
  actual future/unbound passage, configured safe floor and full candidate
  route/capture/plane/fuel/timing/savings guards. No invented later capture
  savings: conservative reference can still reject useful assists. New
  reported-case source fixture searches/restores, but rejects an otherwise
  complete synthetic Ike route that fails the conservative cost comparison.
  Diagnostic now marks baselinePolicy=xing-arrival-lower despite code=unknown.
  Read-only settings confirms map CONIC_PATCH_LIMIT5; careerPatchesAhead3 is
  separate tracking-station API metadata, not this failure's cause. Evidence:
  /tmp/ksp-deck-20261030T212145Z-fetch-0pfhs4tz/logs/_diagnostics/
  assistsearch_Espoir-Ike-Surveyor1_5027134.log and fetch-ykqlpbgg/logs/
  Espoir-Ike-Surveyor1_5026596/boot_004_core.log. All88 routine files pass
  127.71s; reported-case regression0.371s, structural0 errors/unchanged legacy
  KSC_DEORBIT warning. Report:/tmp/kos-assist-orbit-prefix-20261030.json and.log.
  Native retry remains pending. Operator reports Mun return override worked;
  detailed correction/entry results not yet read. The requested long pre-XING
  solar aim follows in the item above, retaining burn lead.

- 30Oct Espoir entry profiles consolidated: duna_impactor is the single
  canonical launch profile, with interplanetary launch mode/16 transfer
  samples,5km Pe±3km, no automatic warp and unchanged assist/burn reserves.
  Ike sampling defaults off; cmd/flybyscience.ks,1 (or0) writes only
  MISSION_ASSIST_SCIENCE for the next boot. Shared flag now covers optional
  moon sampling in both ASSIST_COAST and SCIENCE_ENTRY; Duna science stays
  enabled. Ike bands/20km native encounter/subsequent-entry guards remain
  active with sampling off. No new detour budget, entry burn or landing code.
  Deleted duplicate duna_science_impact source. Its saved Espoir mission id
  resolves to canonical config while retaining historical identity and its
  old sampling opt-in before runtime overrides. Cleanup keeps the real
  canonical bytecode; old-cache-only offline boots retain their provider.
  Manual assist preview uses the same alias/intent helpers without saving
  mission state. Existing science counters/assist records/phase/alarms do not
  migrate. No new band or bootstrap replacement; a connected boot is needed
  to cache the updated boot library/profile. Scalar capability keeps the
  ordinary manual preview working with an older cached boot library too.
  All88 routine files verified:87 passed the129.56s suite; the remaining
  arrival-profile audit expected at least5 entries before consolidation.
  Replaced that count with explicit coverage of the4 remaining atmospheric
  entry profiles; its rerun passes. No production edits after the suite.
  New alias/sampling/handoff regressions take0.017–0.051s. Structural0 errors,
  unchanged legacy KSC_DEORBIT warning. Report:
  /tmp/kos-espoir-consolidation-20261030.json and.log (original count failure
  retained). Native compile/reboot/flight validation remains pending.

- 30Oct live Mun return MCC held with10.7m/s remaining, Pe54km, reason
  fuel-reserve (default50). User requests spending it toward52km entry.
  cmd/returnmcc.ks,52000,0 writes scoped overrides only, then operator REBOOT:
  live vessel budget minus explicit reserve,52–52.25km acquisition inside
  unchanged52–54km correction safety bounds. Keeps mission, phase, alarms,
  staging, assistance and10m/s later aerobrake repair reserve. No node/burn
  acceptance or deletion; stopped Kerbin-return MCC only,600s Pe lead,
  warp-settle/context recheck. Existing MCC affordability/actual-orbit handoff
  remain mandatory. Source replay covers reported reserve hold and unsafe
  contexts; native correction pending. Rescue command commits c43dc61/ebc4a09
  pushed; operator instructed to pull, run command and REBOOT.
  Operator retry exposed an incorrect command state-only mission_type check:
  bootApplyMissionConfig clears that field for profile-owned intent. Use
  shared missionTypeDetect, with saved Kerbin target fallback after command
  preamble, and print context/controls on refusal. Regression now models the
  missing state field and executes the real resolver. Native boot036 confirms
  Pe54.037km,10.7m/s, fuel-reserve after Kerbin SOI; no node or late-approach
  evidence. Log:/tmp/ksp-deck-20261030T201306Z-fetch-ta9p32l6/logs/
  RO9_5008684/boot_036_core.log.

- 30Oct return policy: all11 RO9 moon-return profiles now target52km. Optional
  RETURN_PE_MIN survives surface-ascent profile generation and clamps the
  generated MCC/site/aerobrake correction floor to52km; tolerance remains1km,
  upper bound53km. Explicit economy hop return uses the same goal/floor.
  New floor defaults-1, preserving older RO8/other profiles and53km helper
  defaults. Invalid bounds hold before replacing the Kerbin-return mission.
  Existing generated returns keep their saved intent until explicitly
  retargeted. Normal MCC reserve50 and aerobrake repair reserve10 unchanged;
  rescue command alone explicitly releases MCC reserve. Alarm ownership,
  waiting, physical staging and assist enable flags unchanged. Focused source
  checks pass through two fresh generated-profile loads for every RO9 return.
  Routine88-file suite210.42s:87 passed, only the legacy exact RO8/RO9 profile
  comparison failed on this requested policy difference. Updated comparison
  asserts52km + floor explicitly, still compares every other inherited field;
  its standalone rerun passes. No production edits after that suite. Report:
  /tmp/kos-ro9-entry52-20261030.json and.log (first-pass failure retained).
  Structural0 errors/unchanged legacy KSC_DEORBIT warning. Native52km
  entry/thermal outcome and low-fuel MCC execution still require flight
  evidence. No bootstrap replacement or remote game/control/save changes.

- 30Oct native assist test UT5016249: fetched requested diagnostic through the
  approved read-only Deck wrapper, plus boot004. Espoir-impacter1/duna_impactor
  in XING: nd1063.910655m/s, Duna Pe19,907,948.56m vs entry2–8km. Old helper
  stopped before probes (0.02game seconds), original node preserved, because
  it demanded completed entry even for the reference. Boot calls this an
  intentional rough/dumb departure with later BPLANE targeting. Deck settings
  read-only confirmed CONIC_PATCH_LIMIT3; user is reverting/restarting with5.
  No game/config changes made remotely.
  New XING ENTRY reference can use only the mandatory departure cost as LOWER,
  source departure-only-pending-entry, after safe native approach proof above
  atmosphere. All future corrections unpriced/nonnegative; no invented capture
  savings. Orbital reference and non-XING entry rules stay unchanged.
  Shared assistTrace extracts the SAME ordered/Pe/parent/chronology guards;
  assistEvaluate retains full candidate terminal orbit/entry checks. Traces
  contain borrowed PATCH/NODE_DV, not a complete-goal cost; never persisted.
  Schema2 logs measured native DELTAV, compact route/policy literals, reference
  source, read-only CAREER():PATCHLIMIT, and an open-hyperbolic-tail warning.
  Such a tail may be truncated lookahead, not a guaranteed patch-limit diagnosis.
  New fixture uses reported Pe/PRN/measuredDV (native MAG differs0.00436m/s from
  printed PRN norm), exercises positive full search, unsafe/truncated prefixes,
  wrong phase, incomplete/unsafe candidates, and warning/no-warning horizons.
  All88 routine check files pass262.67s; new reported-case regressions
  take0.375/0.718s. Structural0 errors, unchanged KSC_DEORBIT warning.
  Results:/tmp/kos-assist-entry-prefix-20261030.json and.log.
  Remains manual, restores node, no burns/staging/warp/alarms/phase mutations.
  Native rerun with5 patches pending; no claim of real assist acquisition.
  Evidence:/tmp/ksp-deck-20261030T192429Z-fetch-27c_bh2q/logs/_diagnostics/
  assistsearch_Espoir-impacter1_5016249.log and corresponding
  /tmp/ksp-deck-20261030T192429Z-fetch-tkom900u/logs/Espoir-impacter1_5015869/
  boot_004_core.log. Future usability: longer-lead manual MCC previews remain
  queued; normal~300s correction lead can be too short for this command.

- 30Oct Espoir fleet policy update: user disables automatic warp in all
  Espoir configs and removes the dedicated Ike impactor; Ike surface flights
  now use ike_lander with the existing soft-landing/science safeguards.
  All5 remaining launch profiles set COAST_AUTO_WARP=0. Both Ike operations
  settings maps explicitly carry0; normal IKE_SETUP serialization and assist
  terminal overrides preserve it through fresh boots. KAC/solar/resident-clock
  wait logic is unchanged. Removed missions/Espoir/ike_impactor.ks and current
  documentation/test enumerations; generic SCIENCE_IMPACT remains available
  for other uses. Updated existing profile/handoff checks cover0 on all
  profiles and both continuation paths. Fleet/assist/manual-preview/wait
  checks pass; all88 routine check files pass136.62s. Structural0 errors,
  unchanged legacy KSC_DEORBIT warning. Results:
  /tmp/kos-espoir-fleet-policy-20261030.json and.log. No bootstrap/runtime code
  change or remote game/profile deployment.

- 30Oct manual assist preview: user now authorizes commit/push for Deck use,
  but requests a COMMAND rather than automatic mission integration.
  RUNPATH("0:/cmd/assistsearch.ks"). Requires a linked manual prompt,1x,
  zero controls/physical thrust, Abort off and one unflown node >300s ahead.
  Selected archive profile (cached fallback) + runtime overrides supply route
  and mandatory capture goal. Custom route/fallback/reserve/radius/science/
  seek arguments supported. Function-only archive helpers assist_search,
  assist_search_native and assist_preview are absent from all phase bands.
  Fixed epoch,50m/s command radius (kernel default20),64 node/1536 separation samples,20 game/30
  wall seconds; STOP_UT ends180s before the estimated full burn start.
  Three candidate basins, missing-moon closest-approach score, whole native
  final goal; no extrapolated post-flyby savings. Baseline prices actual original
  node + configured capture, charges an already-achieving bound node once;
  EXACT equivalent goal or LOWER mandatory parent-capture prefix, never an
  optimized direct-route claim. Science allowance0. Default reserve >=100m/s
  and selected assist/capture policy.
  The command radius exceeds25m/s minimum gain:20m/s cannot net25m/s saving
  against an already-planned capture priced as just the original burn.
  Each probe restores original node;
  takeover/edits/frame/phase/burn changes cancel without overwriting.
  Archive report writes original vector BEFORE probes, raw native chain,
  policy/cost/progress/candidate legs/timing/restoration, directly under
  0:/logs/archive/_diagnostics/assistsearch_*.log. Native error restoration is
  not guaranteed: operator quicksaves and reviews the original record.
  No candidate installation, burn, staging, alarm, phase or mission changes.
  Shared validator's single-terminal/outward-departure args stay opt-in;
  automatic callers/defaults unchanged. Earlier Sun-only tests missed the
  initial Kerbin escape prefix. New source fixtures exercise real cost adapter,
  all6 Espoir defaults, bound capture without double charging and actual command
  unsafe/loading/profile/archive failure paths. All88 routine check files
  pass136.97s; every new case <=0.564s. Structural0 errors, unchanged legacy
  KSC_DEORBIT warning. Results:/tmp/kos-assistsearch-manual-20261030.json and.log.
  Automatic phase hooks, durable intent/handoff, optimized direct comparison,
  native compile/performance/storage/flight evidence remain open. No bootstrap
  rebuild, Deck deployment/game controls/save edits. See
  docs/PLAN_local_assist_search.md and README manual command section.

- Current assist-search design scope (30Oct): user excludes departure-date
  selection. Explore nearby geometry around the existing XING node at its
  selected epoch, recheck the actual post-burn orbit, and consider an assist
  as an alternative at the normal midcourse refinement checkpoint. Also
  consider inspecting an already-required Duna capture node for a useful
  partial capture -> Ike -> final Duna orbit/entry. Searches consume compute,
  not propellant; combine steering with an existing burn when practical and
  compare total remaining cost from the actual current state. Reuse closest-
  approach scoring before a moon patch exists, then require the whole native
  post-flyby mission goal. Avoid separate direct-then-assist corrective burns
  and repeated discretionary late searches. Direct atmospheric-entry science
  detours need explicit science/fuel policy when they cannot save delta-v.
  Manual acquisition preview above is source-validated and authorized for push;
  automatic phase integration and optimized direct-route pricing remain open.

- 30Oct follow-up: user requests wiring assistcheck into Duna/Ike missions.
  All six Espoir launch sequences now have ASSIST -> ASSIST_COAST after XING.
  Optional already-native ordered chains: Ike flyby -> Duna orbit/entry,
  or Duna flyby -> direct Ike capture, retaining original powered fallback.
  Shared assist_route validates real future events, geometry and terminal
  ORBIT/ENTRY goals. New burns retain25m/s gain/minimum/cap and live reserve;
  valid natural itineraries require no burn. Generic assist_plan/runtime/coast
  bind serializable route/settings/node/progress to mission/launch/vehicle;
  native proof after burn/each encounter, explicit interrupted/edited-node
  recovery, and idempotent terminal override -> phase checkpoint -> reboot.
  Original profile identity survives; consumed route state clears afterward.
  Coast excludes optimizer, KAC precedes solar, no-KAC polls the clock,
  one anchored midpoint per long body passage plus native SOI/Pe events,
  critical seconds at1x without per-second alarm/solar/log churn. Repeated
  moons are consumed by distinct observed periapsis epochs, not body name.
  Optional science only on existing duna_science_impact intent. Cache retains
  fallback + terminal providers only while branch is ahead; no new cache gate.
  Complete source tests cover all profiles/overrides, real optimizer/executor
  path with synthetic native response, reboot boundaries, controls/budgets/
  clocks/alarms, long cadence and repeated moons. All86 routine check files
  pass262.21s; every new assist case <1s (slowest0.886s). Structural audit
  has0 errors and the unchanged legacy KSC_DEORBIT handler warning.
  Still opportunistic: absent encounter acquisition, optimized direct-route
  comparison, multi-capture tour planning and native compile/storage/flight
  evidence remain open. No bootstrap rebuild or remote game/code changes.

- 30Oct priorities: user resumes interplanetary reliability, efficient phase/
  band boundaries, and generic gravity assists for future tours. Audit and
  finish parked arrival-intent/timing work first; validate orbital capture
  versus atmospheric-entry policies, persistent approach/final wakes and safe
  orbital disk prefetch. Then isolate Duna/Ike setup bands and implement a
  bounded reusable assist planner with explicit encounter/final-body intent,
  native-patch validation and powered fallback. No game control/deployment.
  Do not count analytic candidates or source tests as flown assist validation.
  Source changes now distinguish ORBIT/ENTRY/FLYBY, require actual in-patch
  planetary Pe/atmospheric crossing, estimate finite correction duration with
  the limiter applied once, and bound long approaches to approach+final wakes
  while retaining the short-moon single retry. Espoir opts into safe idle
  two-future-band orbital prefetch plus an explicit profile-rewrite handoff;
  no falling-hop copy or new cache gate.
  CAPTURE preserves existing/interrupted maneuvers and always checks finite
  available fuel. Duna atmospheric handlers and Ike setup split into separate
  providers/bands with shared settings and a compatibility root.
  Generic gravity_assist/cmd/assistcheck previews bounded refinement of an
  existing native ordered flyby/capture itinerary; repeated bodies supported.
  It never flies nodes or changes the mission. Parent/flyby/event/plane/fuel/
  ownership guards and a fresh final native check; comparison is with the
  existing itinerary, not an optimized direct alternative. Default25m/s net
  gain and100m/s post-capture reserve (command accepts explicit reserve).
  Remaining: acquire missing opportunities, compare direct/capture/assist
  alternatives, automatic flyby handoff/tour orchestration, powered Duna
  science entry, native flight/compiled storage evidence. Capture deliberately
  holds existing/unflown nodes after reboot until ownership can be persisted
  and revalidated; interrupted burns still need explicit recovery.
  All85 routine check files pass176.58s on final source, including legacy
  Eve/Duna entry compatibility and the complete initial Ike transfer/refine/
  capture cache manifest. Every new arrival/assist case runs under1s.
  Structural audit:0 errors, unchanged legacy KSC_DEORBIT handler warning.
  Source-token band comparison: combined Duna/Ike26097 -> Ike setup9306;
  native KSM bytes unmeasured. No bootstrap rebuild required.
  Native Deck diagnostics unavailable (no route to host).

- Espoir Ike soft lander requested29Oct: ike_lander profile and local
  ike_lander_ops handoff added,25km circular capture with650m/s post-capture
  floor, natural plane, flexible sunlit/DIRECT Kerbin>=15deg site. Shared
  powered-lead/economy/terrain checks; normal5deg, existing emergency15deg;
  no RO9 tags, proactive stage disposal, relaunch or return. SURFACE_SCIENCE
  owns a600s persistent deadline/KAC review alarm, typed collection/transmit
  at1x after verified settled touchdown/cutoff, no landed solar steering.
  Small science_surface/science_flight/cutoff closure retained only in LANDING
  missions that use the phase, so touchdown handoff can load offline. DONE
  stops landed for manual review. Session is bounded even without radio;
  queue submission is not R&D confirmation, retained data may need later
  transmission. Physical payload/science selection remains operator-owned.
  Source checks cover fresh-boot handoff settings, conditional retention,
  DIRECT radio,600s session/no-KAC/low-power/no-link/Abort/motion/config and
  resumed deadline; all83routinecheckfiles pass114.90s. Native compilation,
  storage and flight remain pending. No game controls/deployment.

- Espoir fleet profiles requested29Oct: Duna and Ike polar SCANsat surveyors,
  separate Duna and Ike science impactors now have source profiles. Optional
  IKE_MISSION_SETTINGS extends the existing handoff, serializing the new local
  operations identity, payload, capture/shape/scan/impact settings while empty
  retains FalconHeavy flyby->Duna entry. New SCIENCE_IMPACT owns a validated
  negative-Pe deorbit, cutoff, resident science, KAC/solar checkpoints and1x
  near terrain. Shared entry context/wait helpers exported without changing
  atmospheric behavior. No mission selection, game controls or deployment.
  Follow-up ike_lander now supplies the separate soft-landing variant;
  impact cannot collect a planned landed-biome observation. Hardware, native
  arrival/refinement, power/radio and flight validation remain outstanding.
  Historical29Oct profile work did not resume arrival WIP;30Oct does (above).
  New source fixtures exercise real profile serialization through fresh boots,
  unsafe-handoff refusal, legacy behavior, native-node admission, failed-burn
  preservation and impact waits. All83routine check files pass105.30s; fleet
  check0.49s, native compilation/storage/flight remain unverified. Existing
  science_flight deploys every available module; it does NOT ration duplicate
  non-rerunnable Goo/Science Jr units between contexts. Per-instrument context
  scheduling remains open; user is choosing the physical science payload.

- Latest retry boot018 at4918637 confirms hBias0, free13495. Different
  rank1 pass now seeds cross274m at21/64. Powered residuals-21074,-13229,
  -18842m; no-improving-step at48/64 despite16 trials left. Zero bias did
  not resolve this trajectory; old scalar-state replay was not native proof.
  Orbital planner now reuses landingDeorbitNodeReady's actual powered dV
  derivative on a stalled provisional node, fixed epoch/normal, max7 models.
  Reserve7 inside64 before call; far frozen-goal inner fits keep8 slots
  (one validation +7 direct), near-root polish unchanged. No tolerance or
  geometry/terrain/fuel/light/normal/state guard relaxed, no new bootstrap.
  Only fresh idle unflown orbital planning can own/remove the probe. Retained
  nodes/interrupted burns stay on existing recovery. Shared admission returns
  solution +matching fresh policy; compact refit suppresses intermediate full
  snapshots, retains final once and reports last reason/error. Synthetic
  flat-ballistic/finite-powered response anchored at29529/48370m reproduces
  old48/64 hold and solves both derivative signs at55/64. Budget boundary,
  bad models, physical/terrain/light/state guards and cleanup tested. Native
  actual derivative/solve still unverified. All82routinecheckfiles pass106.58s.
  Compact refit admission rows use
  INFO reserve, original preburn rows stay SUMMARY; seven intermediate
  samples cannot spend protected final model/result/error space.
  Read-only evidence:/tmp/ksp-deck-20261029T182343Z-fetch-smx0jl1v/logs/
  RO9_4854889/boot_018_core.log. Snapshot now gives actual exhaust2892.9618/
  3089.0947, fuel.171711/.225, drop.42125/0, startMass1.40845. Previous
  hardware assumptions345/290s were illustrative; use measured data next.
  Historical29Oct Duna/Ike pause superseded by30Oct work above.
  No game controls, code deployment or save edits.

- Latest Mun retry: native RO9_4854889 boot017 at4918463 confirms storage
  improvement: phase free7038->13826bytes. New failure is an H-gate plateau:
  fresh powered residuals-687,-687,-682m while downfield57570->58091m and
  AIM58257->58773m, cross41..42m. Earlier feasibility fix was insufficient.
  Fixed mission TARGET_TOLERANCE500 inherited deliberate UNDERSHOOT_BIAS500
  plus100m ignition lead/15m margin. H-trigger follows the target, making
  node-only root fitting ineffective. mun_target_science_return now explicitly
  sets bias0; legacy default500, other profiles and all safety gates unchanged.
  Actual live/forecast gate + variable-mass predictor replay of logged scalar
  ignition, flat terrain datum and explicit55/2kN,345/290s assumptions gives
  ~-730->-235m capture, H ignition0.94s later, V clearance reserve>1.5km.
  This is not exact native TR/terrain/attitude validation. Final forecast now
  includes hLead/hBias and actual first/last engine fuel/exhaust/thrust/drop,
  initial mass/count to remove these hardware assumptions on the next run.
  All81routinecheckfiles pass140.10s; native corrected retry pending.
  No deployment, craft controls or save edits.

- Historical29Oct priority: Mun deorbit near-root rejection AND storage.
  User paused Duna/Ike on29Oct, resumed30Oct. The original WIP is preserved
  separately at /tmp/kos-duna-ike-paused-20261029-1fk3rmgq (tracked.patch,
  files/, manifest.json); restored and hardened in30Oct work above.
  The parked snapshot was NOT fully passing; current validation is separate.
  Native RO9_4854889 boot014:14.94deg,14x15.1km, reaches locked-10.59deg
  site. Solver cross=0 and final51265/51903m powered residual-638m; mission
  tolerance500m, so rejection is legitimate, not a plane/reachability failure.
  New near-root scalar polish uses one0.25m/s probe plus a~0.1m/s proposal
  instead of coupled time/normal probes; full forecast still required.
  Regression with reported residual + synthetic curved native response
  improves to~42m at64/64; changed-model/invalid/cross/budget guards reject.
  Native orbit does not need changing to fix this convergence issue.
  Archive boot014 spent almost its whole8797-byte free budget on48 rank
  rows; later powered failure is only console evidence. Disk now retains3
  ranks, compact model rows and one full final forecast; routine details
  console-only/explicit verbose. INFO stops at4096 free; final SUMMARY/WARN/
  ERROR/PHASE can use room down to unchanged1024-byte hard state reserve.
  Source disk replay retains final model/reason within the reported budget.
  Follow-up native boot015 captured the final forecast successfully, then
  held at down44146/aim44648m (residual-502 vs500 tolerance), cross30m,
  trial63/64. The raw merit charged lateral error inside its allowed band,
  rejecting fully admissible range corrections with slightly higher cross.
  Feasible candidates now outrank infeasible ones before raw cost; source
  regression reproduces old hold and accepts~54m cross after fresh forecast
  at63/64. Limits and target unchanged; native improvement still pending.
  Storage: cleanup8428->8510 removed82bytes because all declared providers
  were needed by its unconditional closure. Split landing_light_search
  from runtime validation. LAND_DEORBIT conditionally loads wait/search only
  for AUTO_TARGET and SCANsat picker for ENABLE/REQUIRE_SITE; fixed target
  retains offline admission/forecast/staging/light/radio/cutoff providers.
  Existing compiled wait3633 +picker1667 =5300bytes, plus search split;
  exact new compiled fit/savings pending. Loader flags owned by core
  mission_type, terrain scalar defaults by landing_config, so profile values
  survive optional loads. Required-site still holds when no site found.
  Source tests execute actual profile flags, planner/cleanup closure and
  fixed target path without optional symbols. All80routinecheckfiles pass
  105.15s; native compiled storage/flight retry remain pending.
  No remote controls, log deletions, code deployment or save edits.

- Historical Duna/Ike arrival review (29Oct; source fixes30Oct above):
  the900s final BPLANE retry was a fixed
  configurable pre-SOI wake, not a geometry/execution-time prediction.
  _bplaneCoastEncounter explicitly excludes atmospheric targets; therefore
  _bplaneRetryEncounter, minimum-correction arrival acceptance and the final
  retry did not generalize to Duna. Preserve the original guard's intent:
  distinguish intended atmospheric entry from orbital capture, retain parent
  coast/plane/fuel/Abort/node ownership checks, and validate the actual future
  atmospheric crossing. Add bounded, persistent approach checkpoints using
  solve/alignment/burn time and sensitivity; remeasure after SOI changes and
  any Ike encounter. Espoir currently samples only incidental native Ike
  encounters with a subsequent Duna entry; active Ike targeting remains open.
  Intent/timing/prefetch now have source fixes; flight validation and active
  opportunity acquisition remain open.

- Urgent entry follow-up (29Oct): RO9_4880796 boot026 holds42.617s before
  atmospheric interface despite Pe53km/Ap94.7km. Previous reentryresume was
  deliberately outside-only; do not relax its native-goal/cutoff acceptance
  while drag changes Pe. Added cmd/entrynow: zero throttle/live surface
  retrograde before loading, refresh old aero function cache, restore the
  existing craft/profile/overrides and resume main with passive-entry intent.
  Same mission/launch/body persists mode across boots. No burn/node erased;
  all Pe/site/assist/capture burns and entry separation deferred. Normal
  hardware stow and slow-flight DESCENT handoff remain. New AEROBRAKE boots
  automatically protect entry from a pending node/repair within120s or inside
  atmosphere. Source replay of recorded42.617s state and inside/drag48kmPe
  reaches descent with marker/node retained and no engine planning/staging.
  All77routinecheckfiles passed99.81s; final direction/warp guards also
  checked in focused aero replays. Native flight confirmation pending;
  no remote control/save changes.

- Current RO9 interruption: native RO9_4880796 boot024 repaired43.2->53km
  after its pass, but8.648m/s burn aborted on0.008181178 residual against an
  unnecessarily strict0.005 limit. boot025 holds despite deleting the node
  because durable interrupted markers remain. Implemented Pe-sensitivity
  cutoff, intent-bound achieved-orbit reconciliation and explicit legacy
  cmd/reentryresume recovery. No common executor/attitude/cutoff relaxation;
  historical report and unrelated nodes retained. Source/independent conic
  tests pass; all76routinecheckfiles pass135.25s. Native corrected recovery
  pending. This saved flight still
  logs AEROBRAKE_AP_BURN=False: command aeroassist1 is a separate operator
  choice before reboot. No remote craft control or save changes.
- Resume after urgent RO9 recovery: Espoir configurable powered science entry.
  Operator selected DIRECT CONTROLLED DESCENT, not deliberate multi-pass
  capture. Reuse powered-entry controller in SCIENCE_ENTRY, preserve science
  sampling between powered intervals, add conditional library/cache roots
  with safe orbital prefetch; no in-atmosphere reboot or forced capture.
  Implementation remains queued while this live craft is unblocked.

- Latest native geo SHAPE failure atUT4868219: RO9_4704531 boot013 is at
 2863km but55.156deg. Pure-normal seed935m/s warps apsides; coordinate cost
  shrinks it to603m/s/20.41deg and rejects. Implemented full speed-preserving
  rotation seed with native sign/Pe validation; independent144 conic cases
  and recorded failure pass. Specific satellite has only~813.5m/s implied
  remaining after prior122m/s circularization vs~935 direct correction;
  reserve/fuel/allowance guards stay active. Native new policy pending.
- Latest mission update: mun_target_science_return now fixed Mun landing,
  surface science, westward ascent/11km parking, retrograde equatorial
  AP1737680 PE1543150 INC180 AOP34.3 (LAN free), orbital review then53km
  assisted Kerbin return. Preserve powered landing/terrain and reserve
  safeguards. First operator request was geo setphase command (provided).
  No remote activation/launch; native mission validation pending.
- Latest satellite reuse blocker: sun-sync->medium SHAPE RO9_4704531
  boot005 charges945.4m/s plane node even though its ETA was already-9455.7s.
  Planning ran under warp; actual burn never fired. All2185.2m/s available
  across stages is counted correctly. Total1900 cap rejects next retry
  with1749.3 already charged. Warp settling and pre-budget finite60s lead
  gate implemented; cmd/shapebudget1500 grants1500 further allowance without
  erasing ledger or changing the per-burn cap/100m/s reserve. Native retry pending.
- Latest solar blocker: RO9 return atUT4665077 repeatedly aborts coarse
  search when acquired4.9deg drifts to5.15..5.25deg during readout. Geometry
  steering works; no valid cache is ever saved. Implemented5deg acquisition/
  existing10deg coarse readout band, strict1deg fine probes and bounded
  reacquisition. Source replay now finishes six axes and reuses saved peak;
  native corrected search pending. Low-flow maintenance now checks eclipse
  geometry before waiting, so daylight mispointing can recover.
- Latest native SHAPE issue: RO9_4218202 boot019 plane9.742m/s took66.3s
  atUT4257230..4257296 because engine10% and throttle50% limits stacked.
  Acceleration-based duration limiting and existing live taper replace those
  fixed dV limits; source simulation passes, native new timing pending.
  Previous floor dead end is resolved in flight:55.8777m/s combined raise
  reached~10x659.7km and proceeded to plane/apsis shaping. Keep Pe floor,
  requested elements, precision and300m/s reserve. Full objective pending.
- Latest operator priority: prepare four RO9 satellite missions and one new
  targeted Mun return, without activating profiles or launching craft. Hop
  mission completed successfully with improved approach. Espoir is now the
  selected Duna science/impact mission, using new hardware; the first source
  profile/continuous science-entry phase is prepared. Ike is opportunistic,
  currently native encounters only; active detours and hardware validation
  remain open. Current probe's VAB-roof question is a separate feasibility
  task, not authorization to command it remotely.
- Snapshot request is script-only. No further laptop SSH, DNS changes or
  transfers; operator will handle the Mac runtime and copy themselves.
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

- [ ] **Assisted recovery and automatic between-pass Pe repair.** Native
  RO9_4880796 boot022: no enabled-assist policy/forecast; passive entry at
  4885785, exit4885950 leaves1549.8kmAp/52.8kmPe. Manual recovery loaded
  aerobrake_config defaults0 and serialized them without restoring RO9's
  effective policy. kerbinrecover now replays craft/profile/overrides after
  defaults and explicitly enables assistance, preserving limits/reserve/tags.
  Its real coast writer is tested through a fresh profile boot (including
  an old disabled profile and custom pressure/attitude/larger-reserve values).
  The10m/s reserve had no automatic repair consumer: multipass code only
  refreshed the next-entry alarm. New shared reentry_pe validates the
  existing20m/s/active-fuel/native-Pe/Ap/plane/axis/timing guards and verifies
  cutoff/live orbit. Manual command and automatic path share execution.
  AEROBRAKE_PE_TARGETING schedules an apoapsis repair after skip-out or
  outbound reboot if drift>250m, with owned KAC before resident solar wait;
  no repair in atmosphere, on inbound leg or after final sub-atmosphere Ap.
  Optional assistance still retains>=10m/s; repair may spend it down to the
  existing0.5m/s margin. Audited empty-stage handoff may precede repair on
  a bound vacuum coast even when Pe has drifted; no entry/burn corridor or
  hardware guard is waived. No fuel => report/passive descent, failed burn
  => retained recovery information/hold. Per-pass entry alarm refreshes after
  repair; subsequent powered forecast uses the corrected orbit. Policy logs
  now show disabled as well as enabled. Solar waits own their wake alarms
  and react to Abort/body changes, without warping on an unrelated alarm.
  All76 routine check files pass137.46s; new repair/recovery files each<1s.
  Final added source cases also run the real stager at51.096km Pe: CPU,
  parachute and nonempty-stage hazards still reject, and the real powered
  forecast still refuses the drifted Pe before repair. Native flight pending.
  Current
  operator says inside atmosphere: do not reboot there. After skip-out,
  linked aeroassist1 +REBOOT enables the corrected next-pass flow without
  restarting MCC. Read-only evidence /tmp/ksp-deck-20261029T020914Z-fetch-
  lvetde5h andqgdo9lfw. No live controls, code or save modified remotely.
- [x] **KSC recovery deorbit funding across stages.** Native
  RO9_4879463 boot017 at4879483 caps the solve at150m/s and rejects its
  140m/s node/1442.481km Pe. Live diagnostic:2863.2215x2863.3144km,
  inc55.156,813.434m/s total,159.507m/s active stage2; independent ideal
  deorbit to53km is441.007m/s. Recovery now opts into a negative MCC cap
  meaning live whole-stack fuel minus unchanged50m/s reserve. Ordinary
  moon-return150m/s cap remains. Shared setup/runtime config and generated
  profile preserve cap/reserve through reboot. Recovery derives the engine
  floor from CPU/tagged chute retention, then uses the existing executor's
  depleted-stage handoff to stage1/return_decoupler; no new stager or early
  separation. Fresh archive writer bypasses old RUNONCEPATH at the held
  prompt. Source checks execute real budget/serialization/stage owner,
  delayed ignition and protected-floor/Abort/fueled-stage cases. Native
  retry now confirmed in RO9_4880796 boot019:440.937m/s plan under763.4
  budget, flown53.234kmPe with unchanged55.16deg plane; phase verified in
  one burn. The archive lacks the earlier staging trace, so exact separation
  event validation remains separate. All75 routine checks passed107.60s.
  Command is
  kerbinrecover apply again
  after pull, automatic reboot, no bootstrap build. Read-only evidence:
  /tmp/ksp-deck-20261029T011555Z-fetch-l6lfy49n and
  /tmp/ksp-deck-20261029T011636Z-fetch-kzl_qgzk. No live flight changes.
- [ ] **Large plane corrections stuck because of pure-normal seed.**
  Native RO9_4704531 boot013 at4868189..4868219: correct2863.2x2863.3km
  altitude, inc55.156, want0. Seed935m/s normal-only has12.36deg error but
  huge Ap inflation; optimizer prefers603m/s and20.41deg, then discards.
  Boot012 similarly failed17.58deg before circularizing122.051m/s instead.
  Full rotation now includes retrograde and (off-apsis) radial components,
  derives velocities only from elements, chooses signs via stable native
  predictions and unchanged plane/apsis cost, retains Pe/bound/quality gates.
  Source independent144 eccentric/circular/axis-sign/retrograde cases retain
  apsides and hit plane; reproduces old12.36deg seed and actual planner
  admission. New seed logging identifies the model/components. No manual
  node/burn, no safeguard relaxation. Read-only logs in
  /tmp/ksp-deck-20261029T001825Z-fetch-{ajqo1_k5,1bmz9nzf}/logs/.
  Native corrected seed/finite burn pending. This satellite may be unable
  to fund direct correction:935.5 remaining before122.05 circularization
  implies~813.5 now vs~935 correction plus100reserve. Keep that separate
  from the solver bug; total4135.8 cap also remains insufficient for935
  after3379.9 already charged. Do not remove guards to force the maneuver.
  All74 routine check files passed104.10s. Corrected native flight pending;
  this seed preserves current apsides rather than optimizing a combined
  plane/circularization maneuver.
- [ ] **Mun target landing -> retrograde contract orbit -> return.** Same
  mission ID and landing(-10.590,99.490), capture15km/15deg, powered lead and
  tight local terrain policy. Surface science runs once, then generic
  surface return generates PRELAUNCH/LAUNCH/PARK/SHAPE/SCIENCE_OPS/RETURN_SETUP.
  Westward ascent avoids an unnecessary full plane reversal;169.41deg
  attainable at this latitude, then finish180deg at high Ap. Orbit targets
  AP1737680/PE1543150m, INC180/LAN-1/AOP34.3deg;100m/.1/.2 tolerances,
  minDv.002/burnTol.001, perburn300/total500/reserve300m/s. Generated review
  holds with RUN_ALL0/AUTO_TRANSMIT0, prints operator RETURN_SETUP+REBOOT.
  Original53km assisted home entry/chutes/hardware remain. Shared fallback
  heading now270 for retrograde, achievable-inc telemetry clamps upper
  latitude limit too. Actual controller heading was already correct.
  Source fixture now executes actual setup heading/parking prelude before
  serializing, and checks exact orbit/review/west heading/home policy across
  fresh boots. Existing prograde return fixtures pass. Native flight pending;
  no remote mission activation or bootstrap recompilation.
  All73 routine check files passed94.20s; new mission flight validation pending.
- [ ] **Orbital-contract reuse: expired plane node charged to SHAPE ledger.**
  Native RO9_4704531 boot005, local read-only evidence:
  /tmp/ksp-deck-20261028T230148Z-fetch-dfed8zys/logs/RO9_4704531/boot_005_core.log.
  Completed sun-sync at700km/99deg, selected medium1581.668km/55deg. Ap raise
 196.97m/s succeeds; plane945.4m/s planning runs under warp and returns
  eta-9455.7s. Charged on803.9 ledger before executor misses window, leaving
  1749.3 charged; next945.4 retry fails1900 total cap. All2185.2m/s total
  vessel fuel is counted;519 active/1012 lander/654 return isn't the problem.
  Added warp settlement at SHAPE/plane planning and retry, common finite
  60s lead check before any charge/execution. Expired nodes hold uncharged.
  Added cmd/shapebudget.ks: bounded additional allowance, preserves ledger,
  targets, phase, per-burn cap and100m/s reserve; idle SHAPE/no-node/Abort
  clear only. Matching body/launch spending baseline; new ID starts zero.
  Source native-node/warp/real-budget/command rejection fixtures pass.
  Pull then RUNPATH("0:/cmd/shapebudget.ks",1500). REBOOT. No bootstrap build,
  remote flight changes or automatic refund of earlier recorded attempts.
  Corrected native mission remains pending.
  All73 routine check files passed91.21s, including native missed-node replay.
- [ ] **Solar search readout-boundary regression on return.** Read-only
  RO9_4417586 boot028/029 and diagnostics4665056018/4665069698 confirm
  acquired4.932deg, readout5.252deg => immediate failure of whole search,
  repeated at5.155deg. Most90s budget unused; no peak/axis saved; ends on a
  dark orientation. Manager/target match, no warp/suppression/thrust, EC~89%.
  Local evidence /tmp/ksp-deck-20261028T210235Z-fetch-*/logs/.
  Coarse readout now uses existing10deg hold band after5deg acquisition;
  fine measurements retain1deg. Excess drift/spin reacquires same anchored
  target within original turn/coast deadline. Cache requires completed
  valid search/return and measured flow as before. Actual source jitter
  regression completes six axes, returns to winner, persists peak and
  reuses it on next call. Added strict fine/readout-spin/reacquisition cases.
  Near-zero maintenance flow now requires actual eclipse before waiting;
  daylight zero/very-low flow initiates recovery. Native corrected behavior
  pending. Header settlePolicy and per-aim readoutTolerance/reacquire rows
  distinguish this version in next archives. No bootstrap rebuild or remote
  flight/library/state changes.
  All72 routine check files passed99.59s; corrected native flight pending.
- [ ] **SHAPE excessive partial-throttle burns.** Read-only boot019 evidence:
  /tmp/ksp-deck-20261028T200230Z-fetch-bueku20u/logs/RO9_4218202/boot_019_core.log.
  Plane9.742m/s atUT4257230.1..4257296.3 took66.3s, node residual0.000988m/s.
  Legacy engine10% and main-loop50% stacked, effective~5% configured power.
  Replaced fixed dv buckets with relative engine-limit scaling based on
  available acceleration and2s minimum full-throttle impulse duration.
  Existing partial/zero limits respected during setup. Shared main/live
  time-to-go taper governs final precision instead of a blanket50% ceiling.
  Attitude/axis/rebound/impulse/stale-command/physical-stop/staging/fuel guards
  remain. Setup records thrustScale. Source-driven108 delayed-control/accel/
  burn/heartbeat cases plus prior120 delayed tails pass. Native duration,
  precision and final orbital objective still need flight confirmation;
  no remote flight/library/state changes. No bootstrap compilation needed.
  All72 routine check files passed127.65s; new case count corrected to108.
- [ ] **Low parking orbit vs SHAPE safety-floor dead end.** Retrieved RO9
  logs with approved diagnostic wrapper; local evidence:
  /tmp/ksp-deck-20261028T185848Z-fetch-kef4ikf6/logs/RO9_4218202/boot_018_core.log
  plus boot017 ascent in sibling fetch-rl7fofni. Native shape has Pe9.52km,
  Ap10.031km, inc3.029deg, floor10km; set-ap55.5678m/s preserves low Pe and
  is correctly rejected, plane candidate also below floor. set-pe54.2671
  swaps apsides at the low current Ap rather than reaching554km Pe, cost272.3
  rejected. Solver exits0 burns at4218577.2. Root mismatch: direct ascent's
  99%-parking Pe target/0.3m/s capture residual vs later10km hard floor.
  Added a floor-recovery step using a native node above the unchanged
  floor, three residual budgets/10m minimum margin and explicit Ap headroom.
  Prefer raising the requested Ap from the existing Ap: above-circular
  prograde thrust makes that already-high point the new Pe, repairing the
  floor mismatch in the same~55.8m/s transfer burn. A~0.28m/s floor-pe repair
  remains available when a combined raise is unnecessary/unavailable.
  Bound orbit/above-atmosphere, node quality, min-dV, budget, plane and physical
  executor gates remain. No legal repair means hold. Independent apsis
  fixture reproduces the combined raise then reaches both requested apsides
  in two burns through actual SHAPE seed/cost/budget/phase code with1mm/s residuals; no
  optimizer, attitude or plane/AoP flight proof. Future shaped surface setup
  selects at least floor+1km parking; plain economy returns stay10km.
  Three new Kerbin satellite profiles use85km rather than78km below their
  80km floor. Generated-profile fixture now executes the actual parking
  helper instead of injecting a caller's PARKING_ALT. Native retry pending;
  no live node/phase/flight state changed on the Deck.
  Operator questioned necessity of the check:10km is configurable conservative
  policy, not a proven physical terrain bound. Keep proposed-orbit admission
  until independent terrain clearance can replace it; selecting a legal burn
  does not make the protection redundant. Do not confuse initial low Pe with
  permission for arbitrary below-floor future nodes.
  All72 routine check files passed95.03s after the combined-raise update.
  New test independently propagates tangent impulses, preserves the final
  target dictionary and requires every proposed/achieved Pe above10km with
  actual seed/cost/minimum/budget/phase logic. LAND_PREP's fixture now binds
  the real private floor helpers called by shapeNextBurn. Native next burn
  should be set-pe-for-ap~55.8m/s at current Ap; follow normal SHAPE with the
  same goals/review. Native boot019 now confirms first55.8777m/s raise
  completed with0.000999m/s residual and~10x659.7km, followed by plane/apsis
  refinement; original admission dead end is resolved. Full final orbit
  remains unconfirmed. Pull and connected REBOOT in SHAPE to load any further
  changes; do not rerun surface selection from orbit. No bootstrap recompile.
- [x] **Reusable read-only Deck diagnostic wrapper.** Operator requests fewer
  repeated approvals. Added executable scripts/deck-diagnostics with fixed
  status/crash/logs/fetch actions and a reusable exact absolute-path approval.
  No arbitrary remote commands, sudo, configuration/game writes or restart
  actions. Strict existing SSH host/key; request travels on stdin. Bounded
  archive reads reject traversal and symlink escapes; reports stay in fresh
  private local /tmp directories. Source tests cover admission, fixed argv,
  symlinks, size limits, virtual GPU counters and actual CLI report handling.
  Exact wrapper prefix permission saved. Live status/crash/log listing/fetch
  all succeeded through that same saved permission. Source checks pass.
- [x] **Portable game capture script.** Scope clarified: only provide a local
  script; no laptop SSH/DNS edits/transfers. Added scripts/ksp_snapshot.py:
  full installed game/mods/saves/ships/settings and optional separate kOS repo,
  safe archive-link dereference, embedded manifest and SHA256. Excludes logs,
  git/download/MM caches; rejects overwrite, low disk, outside links/cycles,
  running game by default and detected file changes. Tests use synthetic
  fixtures only. Operator handles Mac runtime/copy; captured platform build
  is unchanged. No game snapshot, laptop access or DNS change performed.
- [ ] **New RO9 satellite and Mun science profiles.** Added inactive files:
  kerbin_geostationary_satellite2863334m/0deg;
  kerbin_sunsync_satellite700km/99deg;
  kerbin_semisynchronous_satellite1581668m/55deg/~10774s;
  minmus_elliptical_satellite1041045/465764m,21.6/255.5/157.3deg;
  mun_target_science_return(-10.590,99.490), then53km Kerbin return. Science
  satellites transmit and hold for review; no unnecessary transfer on Kerbin.
  Mun uses15deg arrival to reach latitude, fixed local refinement and an
  explicit mission-local offline/dark-site waiver, no polar survey/hops/KSC
  detours. Existing terrain/thrust/stage/return reserve gates retained. Tests
  check actual window margins, bindings and two fresh return serializations.
  No profile selected, craft/override/state modified or mission started.
  Await native craft validation; no craft exists for the new Mun mission yet.
  Full70-file routine run passed69 files; the sole failure was the old
  RO8/RO9 clone check assuming all new RO9 profiles had RO8 equivalents.
  Registered the five intentional RO9-only profiles and reran that entire
  check successfully, plus snapshot/profile fixtures after final edits.
- [ ] **Generic surface ascent to a specified orbit, then review/home.**
  Operator is at Delta and requests659734/554472m,0deg,AoP0.4, without hard
  coded coordinates. Existing polar-hop profile already has these orbital
  targets, but its generated ascent sequence goes straight from SHAPE to
  RETURN_SETUP. Add a simple guarded selection command and an orbital review
  stop, preserving stored science and the original return hardware/entry
  policy. Do not invoke the command or launch the craft remotely.
  Implemented cmd/surfaceorbit.ks(Ap,Pe,Inc,AoP[,LAN]): validates live settled
  moon state/roles and bound orbit, restores/finishes any active hop route,
  preserves original return and shaping policy, persists the selected leg,
  and prints REBOOT without ignition. Fresh SURFACE_RETURN_SETUP then launches
  into safe parking/SHAPE/SCIENCE_OPS review/RETURN_SETUP. Review deploys no
  experiments and does not auto-depart; printed setphase command releases it.
  Original polar-hop profile now also has this review after its specified
  equatorial ellipse. Shared return_setup emits the opt-in review settings;
  review bands keep the return provider/config through cleanup. Other missions
  remain opt-out. Source tests use Delta and unrelated coordinates, retained
  budgets/tags, fresh profile generation, actual manual-review hold, and20
  rejection cases with unchanged state. Native flight/remaining fuel pending.
  Full71-file routine suite passed89.49s, including all satellite/snapshot,
  boot/cache, return serialization and hop checks. Existing unrelated
  ksc_deorbit warning remains. No live command or flight action performed.
  Post-push review found configLiteral did not support Lexicon values:
  a SURFACE_RETURN_ORBIT override would become quoted display text. Added
  shared recursive LEXICON serialization and a regression executing the real
  configLiteral AND missionOverrideUpdate, then reloading the emitted SET
  text after selection. It covers the orbit, review sequence, retained return
  Pe and nested list/map/boolean values; a dict-only override stub had hidden
  this. Use the serializer follow-up with72a512b, not that commit alone.
  Command refreshes the function-only config source when linked before any
  override write, avoiding RUNONCEPATH retaining the old serializer at the
  current surface prompt. Full71-file suite passed93.10s with serializer;
  the final command-refresh/real-writer case is also covered by its focused
  check. No need to reboot into an automatic surface route just to select.
- [ ] **Espoir Duna science flyby and impact attempt.** Operator selected
  Espoir (French for hope), a different probe rather than RO9, and Ike only
  if fuel/trajectory allow. Prepare a craft adapter/profile without RO9
  stage numbers or tags. Reuse interplanetary transfer/refinement, then
  continuously collect/transmit science through approach and entry; the
  existing FLYBY wait does not collect atmospheric science. An existing
  native Ike encounter can be sampled without buying a Duna capture.
  Active Ike detours require a validated subsequent Duna entry and hardware
  budget; do not silently replace the primary mission with capture/Ike setup.
  No physical craft supplied yet: radio, power, heating and optional chute
  survival remain unverified. Do not launch or activate a profile remotely.
  Source implementation now includes craft/Espoir.ks and the
  duna_science_impact profile:85km parking, existing transfer/BPLANE pair,
  5km+/-3km Duna entry, no capture/return/staging/assumed powered landing.
  Dedicated SCIENCE_ENTRY band continuously samples typed stock/DMagic
  modules, preserves old data/animated requests, retries unavailable requests
  and queues transmission with a home link/5% EC floor. Native TRANSMIT
  removes data immediately on queueing: logs explicitly do not claim
  delivery. Actual R&D credit remains to be confirmed in game.
  Body/altitude/SCANsat-biome contexts and sampling progress survive reboot.
  Solar waits own KAC alarms before steering, require the owned alarm/power
  health to warp, resume by clock without KAC, and stop for SOI/Abort.
  Entry uses live surface retrograde at1x with zero thrust and no band
  reboot. Native Ike passes need>=20km Pe plus a future in-patch Duna entry;
  no extra detour planner exists yet. Three passive atmospheric passes are
  bounded; skipout/missed entry holds rather than claiming impact success.
  Disk-only arrival prefetch is nonblocking. No bootstrap rebuild required.
  Follow-up found bootCacheNextBand currently defers all synchronization
  until LANDED (the hop rule). Espoir's new arrival cache roots are declared
  and retained but are not yet copied during flight; extend/test this for
  an idle orbital coast before relying on an offline SCIENCE_ENTRY handoff.
  All75 routine check files pass106.90s, including the new0.43s science
  lifecycle/phase/wait checks. Native compilation/storage/flight remain
  pending. No game state or selected mission changed.
- [ ] **VAB rooftop landing feasibility.** Current probe has160m/s in the
  leg-bearing stage,654m/s and parachute after dropping it, estimated Kerbin
  TWR below1. Recommend KSC vicinity for this vehicle; a deliberate powered
  roof landing needs measured near-surface TWR, retained landing gear, a
  measured roof height/footprint and collider-aware terminal guidance.
  Existing KSC targeting is not roof precision; MechJeb targets terrain
  elevation. Do not hardcode an unmeasured VAB height or promise chute
  placement. Existing cmd/landatksc also has an unresolved KSC_DEORBIT
  handler; do not present it as a working recovery command.
- [ ] **28Oct18:33 hop-transition Deck crash.** Operator saw apparent approach
  success before hard crash; save has about20s ballistic impact estimate.
  Boot f3a9b3cf restarted18:36. Previous kernel journal now recovered locally:
  /tmp/ksp-deck-kernel-prev-20261028-1835.log,10257lines/1264596bytes. First
  relevant GPU errors18:33:16CET: amdgpu_vm_validate failed / Not enough memory
  for command submission. TTM lru bulk-move/reservation WARNs in
  UnityGfxDeviceW3825 follow18:35:53; do not equate this evidence with the
  earlier pure lock-hang or claim an exact offending mod. Last archived
  boot011 entered LAND_ASSIST atUT4215340.5; no approach recorder swept yet.
  No game/save/settings changed. Operator later confirms improved hops and
  completion of the mission after reload. Root mod/driver cause remains open.
- [x] **Hop approach overshoot and repeated lateral correction.** Operator
  confirms the hop mostly worked. Native RO9_4214328/boot007 and diagnostic
  landingdiag_RO9_4214365637 show Gamma touchdown4.1m from the fixed target,
  but145.36s/78.035m/s APPROACH. BRAKE handed321m/15.3m/s to refinement;
  its20s timeout handed106m/9m/s at72m terrain clearance to the12deg upright
  controller. That momentum exceeds the upright stopping distance. The
  detailed approach rows were evicted by final descent; direction reversals
  are operator-observed, not reconstructable from that ring alone.
  Added shared response/stopping-distance speed limit with a damped final
  position loop. Close fixed-site economy brakes now retain full-vector
  arrest below18m/s until upright capture is feasible; predictor shares the
  same decision. Physical attitude/cutoff, tilt, terrain, altitude, target
  tolerance and return-stage safeguards remain. Sparse approach history
  retains entry plus seven recent rows (<=2kB), every15s, no powered I/O;
  HUD/archive report closing speed, transverse drift and lateral authority.
  Source simulations at the reported brake state capture without passing
  the target in65-71s/~50-53m/s impulse for mirrored cross-drift and prescribed
  0/1/3s steering lags. Flat constant-mass physics, not a native flight replay;
  an already-too-late APPROACH entry cannot undo its stopping distance.
  Operator confirms improved subsequent hops and completed mission. Native
  efficiency metrics remain unavailable; do not turn subjective improvement
  into measured fuel/landing-error claims. No bootstrap change.
  All67 routine check files passed90.11s; existing unrelated ksc_deorbit
  warning unchanged. No live flight controls or Deck files changed.
- [x] **Record native NOT DEFINED syntax quirk.** Pulled operator574ce79,
  preserving both the positive IF DEFINED/ELSE boot fix and compiled boot.ksm.
  Documented the rule in README/CLAUDE and added a masked-source guard plus
  regressions so the Python fixture cannot silently admit this invalid form.
  No other executable NOT DEFINED occurrences found; no flight code changed.
  Structural, runtime-contract and bootstrap-install checks all pass; existing
  unrelated missing ksc_deorbit warning unchanged. No recompilation required
  beyond the compiled bootstrap supplied in574ce79.
- [ ] **Graphics-memory reductions preserving the preferred look.** Operator
  values shiny/specular parts and ReStock/ReStockPlus. Preserve Magpie/TU/
  Deferred appearance by default. Permanent inventory now saved at
  docs/steamdeck/mod-inventory-20261028.json: folder presence28Oct, CKAN IDs /
  AVC versions / measured package sizes26Oct, dates explicitly separated.
  Fresh registry/size refresh refused SSH; no remote changes made. Ocean /
  atmosphere cuts are low priority for this airless Minmus freeze; earlier
  scene resources may persist but that residency has not been measured.
  Recorded disk sizes: Parallax terrain1981MiB/scatter1190MiB/planet250MiB;
  BetterDres173MiB incl8K colour/normal/height maps/rings; BoulderCo68MiB;
  Magpie~0.8MiB/configs only. Do not present disk sizes as VRAM savings.
  Official Parallax1.0.5/1.0.6 assets examined; no ready low-resolution stock
  texture variant verified. Modern Parallax uses Unity bundles: selective
  lower-resolution overrides/rebuilds are feasible but not a simple settings
  toggle. Loose DDS colour/normal reductions are easier; preserve format,
  alpha channels, mipmaps, height/biome data and shininess. User has already
  set stock texture quality2; don't propose that as a new fix.
  Next candidates: audit ReStock's blacklist so unused stock assets aren't
  loaded alongside replacements; consider optional BetterDres visual assets
  only if operator doesn't value that planet's revamp (it changes geography,
  so no casual removal), optional BoulderCo cloud/city-light texture quality.
  Verify texture residency before promises. OPM folders here appear to be
  KSPedia/delta-v charts; CKAN snapshot has no full OPM package, so do not
  recommend removing an assumed Outer Planets Mod. Most utilities are small
  graphics consumers; a400MiB Burst compiler ZIP is not a400MiB GPU texture.
  Sources: Parallax release1.0.3 bundle migration; KSPTextureLoader bundle
  override precedence docs; ReStock Asset Blacklist and Whitelist wiki;
  Deferred compatibility docs / Magpie's TU shiny-config description.
- [ ] **Bootstrap undefined BOOT_LIB_RAN / full-volume installer.** Operator
  recompiled boot.ks but line194 still dereferenced an absent export. Actual
  early bootstrap _syncLib bypassed the safer shared installer, deleted old
  boot_lib first and continued after a failed copy/load. Added size preflight,
  old-copy retention, linked archive fallback and explicit missing-export /
  dependencies stop before registry use. Shared safe landed-hop cache prune
  now works before state initialization; startup retries cache copies after
  freeing space. hopnext uses the same helper. No state reset or fake registry
  initialization. This change DOES require installing new boot/boot.ks; use
  hopnext while landed/linked, cmd/updateboot.ks, then reboot. Real bootstrap
  functions are exercised against the151B-free case and missing-offline case.
  All67 routine check files passed73.04s. Operator supplied compiled bootstrap
  in574ce79 and now confirms a successful hop. Full offline/storage recovery
  validation remains separate; preserve the operator's compiled bootstrap.
- [ ] **Latest Deck crash (2026-10-28).** Operator requests investigation
  after the bootstrap repair. Read current/previous kernel/journal, KSP/Unity
  crash evidence and memory/GPU counters; do not restart anything or infer
  the earlier GPU-memory failure has repeated without new evidence.
  Bootstrap fix committed/pushed2ae0dff first. Native audit now confirms same
  TTM/DRM locking-hang pattern: boot77dd7b67, kernel7.2.7-valve2; first report
  16:48:16CET already122s blocked (onset~16:46:14). dxvk-cs4481 and
  UnityGfxDeviceW4490 D/ttm_global_swapout, likely mutex owner dxvk-submit4479
  waiting at __drm_exec_lock_obj. Still stuck17:10; KSP4434 remains alive.
  Full current kernel2138lines/214137bytes at
  /tmp/ksp-deck-crash-kernel-20261028.log; JSON thread snapshot beside it;
  broader snapshot /tmp/ksp-deck-crash-20261028.json. No inspected kernel
  OOM-kill/GPU-reset/allocation-failure evidence. Separate eglinfo SIGSEGV at
  17:04 is later, not the cause of the16:46 KSP freeze. RAMavailable~541MiB,
  swapused~10.75GiB; KSP RSS1.29GiB/swap8.58GiB. GPUActive counter~8.02GiB
  overlaps other memory accounting; do not add these as independent totals.
  No system/game/settings actions were taken. Driver defect/trigger unresolved.
  Research: primary KSP/DXVK issue5140 covers GTT overspill/Parallax and resource
  pressure; it does NOT demonstrate the same kernel lockup. Defrag-off trial
  failed for that reporter; WineD3D helped a different commenter, but current
  Parallax explicitly requires Proton/DX11, so no blind renderer switch.
  https://github.com/doitsujin/dxvk/issues/5140
  Upstream2026-07-03 Natalie Vock TTM/drm_exec eviction patch series discusses
  memory-contention locking failures; patch presence/applicability here unproven:
  https://lore.kernel.org/lkml/20260703-ttm_2_drm_exec-v1-0-43685ac1286b@gmx.de/
  Fresh graphics audit /tmp/ksp-deck-graphics-audit-20261028.json confirms
  1280x720,2xAA,TEXTURE_QUALITY2,density0.15,range1,Scatterer2048shadow,
  low-res atmospherefalse/ocean reflections true, persistent-uploadfalse /
  temporary256/DeferredSSRfalse. NoIVA/MH changes already handled earlier.
  Next low-impact candidates: Scatterer low-resolution atmosphere and ocean
  reflection reduction; larger savings likely need visual texture/bundle
  inventory or controlled Parallax comparison, not yet measured. Largest loose
  DDSs are BetterDres8K maps and ReStock/stock4K parts; disk sizes do not prove
  actual GPU residency. Parallax bundles were not counted by the DDS-only scan.
  DXVK maxDeviceMemory/maxSharedMemory are reported amounts, not hard limits;
  current maxMemoryBudget is a debug budget with documented severe performance
  risk. No config or mod changes applied during this audit.
- [ ] **Hop boot storage exhaustion after f075e3c.** Native saveUT4212185
  confirms199849/200000bytes used, only151bytes free; return_setup absent,
  state15896bytes. State survived with Gamma pending2 but phase review.
  Operator authorizes separate launch/landing/science reboots. Split hop
  controller from surface helpers, narrow loaded phase bands and stage only
  the next phase's cache with state/log headroom. Inspect pending phase handoff
  so Gamma is not replaced by default Beta. Keep write verification/cutoff.
  Implemented hop_control/provider split and disk-only next-band caching:
  review->launch/return, launch->landing, landing->review; at least4KiB
  headroom for optional cache copies. Current file is not deleted when its
  replacement cannot fit. No mandatory blackout/cache admission gate added.
  hopnext frees four archived/recoverable descent files before any library
  load on a linked settled active route, preserving state/overrides. Use it
  before rebooting the full processor. Root cause of stuck review also
  found: stateSaveReloadState wrote reload_next_phase but not phase; no boot
  reader consumes that metadata. Helper now commits phase last. Actual helper
  JSON test replaces the old special phase-setting stub, and pending Gamma
  in an old review checkpoint is revalidated without defaulting to Beta.
  Source fixtures reproduce exact199849B/151B-free accounting, safe failure /
  old-file retention, recovery space, no execution of future cache, and
  loaded-vs-cached providers. Native compile/new free space/flight pending.
  Future cache sync runs only while landed, including the post-touchdown
  wrappers before reboot; no science prefetch during a falling short hop.
  All67 routine check files passed91.79s; final cache deferral passed nine
  affected files, structural audit300 scripts/77 profiles/72 phases/32 bands,
  0 errors (existing unrelated ksc_deorbit warning). No live code/controls
  were changed on the Deck; current native free space/compilation/flight must
  be confirmed after the operator installs this version.
- [ ] **RO9 polar landing audit and surface-hop recovery/menu.** Retrieved
  boot017/018, landingdiag4208486237 and its sidecar to
  `/tmp/kos-ro9-4208486/`; raw current save/state captures under
  `/tmp/ksp-ro9-4209204-*.json`. Native surface coordinates -1.0861463,
  1.364514 are~6.5m from Alpha, after159.22s APPROACH/~94.62m/s impulse.
  Three-second transfer BRAKE at7.6km enabled lateral guidance but yaw~1deg;
  then unpowered coast and a low-speed flare with lateral correction off.
  Review staged correction horizon and cross/along capture; no native proof
  yet of a controller fix. Keep the controller change separate from the
  surface recovery fix; instant higher yaw alone would not account for the
  ensuing coast and could overshoot sideways. Automatic reboot from HOP_ROUTE_SETUP changed
  boot018/RO9_3268520 to boot001/RO9_4209170, empty progress/route state and
  original mission PRELAUNCH. User confirms no manual reset/file changes.
  Implemented overwrite/readback verification without delete-first state
  writes; native SaveFile null result is not dereferenced. A failed write
  retains the checkpoint and stops CPU/throttle/warp. The old deletion was
  unsafe, but no captured native I/O exception proves it caused this reset.
  Target-surface opted-in routes now recover to guarded setup/review, and
  HOP no longer gets generic PRELAUNCH inserted. It retains its own engine,
  budget, attitude, cutoff and bounded-burn guards, with node/motion checks
  at entry and just before ignition. Added30s KAC site menu after600s stop,
  clock fallback, default continuation/H hold/R configured return. Wrapped
  cmd/hopnext.ks selects a numbered pending site without ignition/reboot;
  site3 is Gamma. Existing saved route is authoritative; reconstruction after
  state loss requires Alpha proximity and normal body/stage/terrain/fuel
  admission. Return orbit/entry settings and completed-site index survive.
  Operator completed Alpha/Beta temperature scans from this landing; skip
  Beta next. Retain all body/idle/stage/terrain/fuel and flight guards.
  Operator now confirms the hop mostly worked; retrieved Gamma touchdown
  confirms4.1m miss. Remaining route/menu/offline storage tests and corrected
  approach flight validation are pending. Source
  tests cover actual command, cold/active recovery, menu/alarms/cancellation,
  integrated600s+30s continuation and null/failed state writes. Initial full
  routine pass:67 files/44.90s; final full routine pass67 files/44.52s.
  Final menu1x/hold-command refinements passed the seven affected check files;
  structural audit299 scripts/77 profiles/72 phases/32 bands,0 errors (the
  pre-existing missing ksc_deorbit handler warning remains unrelated).
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
