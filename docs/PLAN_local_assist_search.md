# Local gravity-assist acquisition: manual preview

2026-10-30. User authorizes committing/pushing a manual command for Steam Deck
testing, without automatic mission integration. These helpers are **not loaded
by any flight band or mission**. Existing opportunistic ASSIST behavior is
unchanged. Only the operator command loads the acquisition search.

- [Search kernel](../lib/assist_search.ks): candidate generation and budgets.
- [Native adapter](../lib/assist_search_native.ks): node ownership, native
  trajectory scoring, total-cost admission and restoration.
- [Manual command and baseline](../lib/assist_preview.ks), exercised by
  [command fixtures](../scripts/check_assist_preview.py).
- [Search fixtures](../scripts/check_assist_search.py): synthetic patch
  responses, not a KSP propagator or native compiler.

## Operator test

Quicksave, enter a linked manual prompt at1x with throttle/Abort off, and retain
one unflown node more than five minutes ahead:

```kos
RUNPATH("0:/cmd/assistsearch.ks").
```

The default uses the selected Espoir profile and runtime overrides. Original
node restored; candidate reported only. Copy the verified
`0:/logs/archive/_diagnostics/assistsearch_<craft>_<UT>.log` back for review.
Original PRN/epoch is written before the first probe. A native runtime error
can still leave a trial node: use that record or reload the quicksave. No
engine, staging, alarm, phase or automatic continuation is added.

## Library call

The caller already owns one unflown maneuver. Its normal planner supplies the
direct alternative, the route and the latest safe time to finish searching.

```kos
LOCAL limits IS assistSearchLimits().
SET limits["STOP_UT"] TO latestSafeSolveUt.
LOCAL proposal IS searchAssistNode(ownedNode,route,seekIndex,directAssessor@,limits).
IF proposal["OK"] AND proposal["RESTORED"] {
    // Original node is still installed. Review proposal["AXES"].
    // Apply only after checking ownership again, then run the ordinary
    // departure/correction/capture admission against fresh native patches.
}
```

`seekIndex` selects the missing encounter in the ordered route. For an Ike
assist into Duna it is Ike's index. For Duna flyby -> Ike capture, Duna may
already be predicted; select Ike's index to score the missing moon encounter.
The search changes radial/normal/prograde components at the **same epoch**.
It neither selects a departure date nor creates an extra maneuver.

## Search and scoring

Start with the existing node. Probe seven axis/diagonal directions, both
signs, at two radii. Retain three small candidate basins, then refine the best
basin using coordinate steps; try alternatives and halve the step when no
improvement is found. Retain the best *admissible* candidate separately from
the progress scores. Freshly probe that candidate before returning it.

Progress ranks, from least to most complete:

1. No encounter: minimize same-epoch ship/moon separation over the predicted
   parent-body passage. Thirteen coarse times plus five interval refinements
   make this bounded and useful before an Ike patch exists.
2. Encounter exists but terminal patch is absent: retain the basin without
   inventing a post-flyby orbit or savings.
3. Ordered bodies exist but terminal geometry is wrong: reduce the Pe/plane
   residual while preserving a separate admissibility decision.
4. Shared `assistEvaluate` proves the whole native itinerary: rank total
   remaining node plus terminal capture cost.

Only rank 4 can be accepted. The shared validator still checks actual finite
patch events, outgoing flybys, parent-body clearance, requested Pe bands and
inclination. A close pass or a soft goal score earns no fuel-saving credit.
Unsupported route constraints, including LAN/AoP, reject the preview rather
than disappearing from its comparison.

Kernel defaults: a 20 m/s vector-change radius, 64 node probes, 1,536 separation
samples, 20 game seconds and 30 wall seconds. `STOP_UT` is an additional
mandatory caller deadline; the default zero refuses to start. The caller must
derive it from its real solver/alignment/burn/SOI margins. Direct-cost
callbacks must also observe this budget. There is no new wait phase, alarm
or warp controller. A sample-count ceiling limits separation calls; once
exhausted, those calls cannot guide more near-miss probes. A complete native
candidate can still be checked within the remaining node/time budgets.
The manual command uses a50m/s radius: improving an existing capture node
priced as just that burn by25m/s is impossible within a20m/s change radius.
Its deadline is180s before the estimated full burn start. These are preview
limits, with no candidate installation or execution.

## Comparing the right costs

`directAssessor(node, terminalGoal, budget)` is deliberately a required
delegate. The manual command supplies the read-only implementation in
`lib/assist_preview.ks`. It prices the current node plus the configured
required capture; broader optimized direct-route planning is still absent.
The delegate returns:

```text
OK, BOUND="EXACT"|"LOWER", GOAL, COST, NODE_DV, UT
```

`GOAL` must identify the same terminal objective. `NODE_DV` and `UT` must
match the installed original node. `COST` includes that node's complete burn
and all priced future operations from the current state. Spent XING fuel is
never charged again. Refresh the reference only with the original node
restored; a price calculated on an assist trial is not a direct alternative.

- `EXACT` means an equivalent-goal direct plan priced using the same cost
  model. This is not a claim of exact finite-burn physics.
- `LOWER` requires a demonstrated mandatory prefix of the normal fallback.
  For example, if the configured fallback requires paid Duna capture before
  Ike transfer, its verified node plus required Duna capture is a lower bound
  only if omitted future costs are nonnegative. An estimate of a convenient
  hypothetical Ike transfer cannot serve as this certificate.

The first native report at UT5016249 exposed another prefix: XING entry
missions intentionally permit a rough Duna approach before BPLANE targets the
final2–8km atmospheric corridor. In XING only, a safe native approach above
the atmosphere can establish a departure-only LOWER bound. The baseline must
prove ordered parent clearance, an actual future in-patch planetary Pe and an
unbound planetary approach. It prices the measured node DELTAV; future entry
corrections remain nonnegative and unpriced. It does not claim the original
node already achieves entry, or reserve an invented capture burn.

The shared `assistTrace` factors ordered geometry checks out of
`assistEvaluate`. Its transient PATCH reference is for immediate use only;
it returns NODE_DV, not a complete-goal COST. Candidate validation always goes
through `assistEvaluate`, which retains terminal geometry and actual
atmospheric-crossing checks. No automatic flight caller uses a trace alone.

For an already-created capture maneuver, inspect its actual bound post-node
orbit and the requested Pe/Ap/plane. Do not mistake that post-burn orbit for
an incoming hyperbola and charge another assumed capture. The manual baseline
adapter now checks a bound post-node orbit with no outgoing patch, requested
Pe/Ap/plane and a small numerical apsis tolerance before pricing just the node.

A candidate must save at least 25 m/s against the reference, fit live total
fuel plus the configured reserve (at least100m/s by default), avoid standalone burns at or below 0.3 m/s, and
leave time for the node burn and terminal capture. A small adjustment combined
with an already-large burn does not create a separate tiny burn. Capture
duration uses the existing staged burn estimate; normal admission must still
validate staging, finite burn behavior, target geometry and mission reserves.

Science expenditure defaults to zero. An explicit `SCIENCE_EXTRA_DV` allowance
may buy a *new* route within that allowance; it cannot continually justify
retuning an existing assist. A probe already on free Duna entry has no capture
cost to save. Its Ike science detour therefore normally needs this opt-in.

## Node transaction and cancellation

Require the active vessel, one owned node, zero physical/control/pilot thrust,
1x, no Abort and no interrupted burn. Bind the search to vessel, body, phase,
mission identity, launch identity, epoch and original vector. Recheck those
values after yields and before inspecting nodes following an active-vessel
change. Every probe restores the original vector before the next one.

Abort and ordinary deadline exhaustion restore the untouched owned probe.
Node edits/removal, frame or mission changes, control takeover and interrupted
burns cancel without overwriting the intervention. If safe restoration is
impossible, report `RESTORED=False`; the caller must retain manual review and
must not execute the remaining trial vector. No node is created or deleted,
and no mission state, engine, staging or reboot operation is performed here.
There is no exception recovery guarantee: a native runtime error during a
probe could still interrupt restoration. That limitation needs native testing
before flight integration.

The returned scalars include fixed `EPOCH`, proposed `AXES`/`OFFSETS`, modeled
`COST`, `DIRECT_COST`, `DIRECT_BOUND`, `EXTRA_DV`, `TRIALS`, `POSITIONS`, `STOP`,
`RESTORED`, `CANCELLED` and `NEEDS_ADMISSION=True`. No patch/node objects are
retained in the result. The manual command writes summaries, progress counts
and candidate leg events directly to the archive; no per-probe disk log.
Telemetry tier codes are -1 invalid,0 near miss,1 encounter,2 unmet terminal
goal,3 complete native proof. The five count-array entries follow that order.
Schema2 uses compact configuration literals instead of multiline collection
dumps, includes the direct reference SOURCE, records CAREER():PATCHLIMIT and
warns on an exposed hyperbolic tail without a next patch. This is an observation
of possibly truncated lookahead, not proof that every missing encounter is
caused by the patch limit. The command never changes game/career limits.
No mission phase is wired to consume these results.

## Integration points to review

| Point | Baseline and proposed use |
| --- | --- |
| XING before execution | Price the existing departure and mandatory fallback capture. Search that node at its selected epoch, then run normal departure admission once on the selected alternative. |
| Immediately after XING | Re-measure the actual flown state. If a correction is already necessary, compare direct and assist versions of that correction. Otherwise search only under an explicit discretionary fuel policy. |
| Normal MCC/refinement | Treat direct and assist geometry as alternatives for the same next burn. Use the existing scheduled checkpoint; do not burn direct first and then undo it for an assist. |
| Duna capture planning | Inspect the owned capture node for partial capture -> Ike -> final Duna goal, price against the verified direct capture, then freshly validate the complete replacement. |

An accepted branch also needs durable route intent, the existing ASSIST_COAST
handoff and revalidation after the flown burn. Admission must understand the
saved assist intent: direct-arrival-only constraints cannot silently veto a
valid alternate itinerary, or silently disappear. Keep the common timing,
fuel, staging and control guards, and validate the branch's complete goal.
These phase hooks are **not**
implemented. On an ordinary no-solution result with restoration
confirmed, keep the existing powered plan. Interrupted/changed ownership
continues to require review.

## Shared validation change and remaining evidence

The preview makes two opt-in additions to `lib/assist_route.ks`: allow a single
terminal leg when explicitly requested, and permit a specified first outward
departure patch such as Kerbin -> Sun. Default callers retain their old
two-leg and ancestor-transit rules. Departure permission still requires the
actual next patch to be the body's parent, safe Pe and forward chronology.
Earlier assist fixtures began in Sun orbit and missed the fact that the
post-XING craft can still be escaping Kerbin. Automatic mission callers are not
changed to use the opt-in; the manual search and baseline explicitly use it.

Synthetic fixture result: the original vector `(0,0,900)` has no Ike
encounter. The search returns `(12.5,0,900)` after 63 node probes and 1,150
separation samples, with modeled cost 1,213.15 versus 1,305.16 m/s, and restores
the original node. This demonstrates control flow in an invented response
surface, **not** a Duna flight solution or measured KSP performance.

Fixtures also exercise initial Kerbin escape, a wrong terminal Pe after a
successful encounter, entry-science policy, fuel/reference failure, resource
exhaustion, stale final proof and control/ownership changes. Native compilation,
patched-conic update latency, numerical derivatives, actual solve time and
finite-burn execution remain unverified. The coarse closest-approach samples
can miss narrow minima; limited game patch lookahead can hide downstream legs.
Neither case authorizes an extrapolated assist.

Historical sketch validation:87 routine check files passed124.86s. The manual
command adds tests for its actual direct-cost adapter, all current Espoir policies,
already-achieving capture nodes and command control flow. Final routine timing
results: all88 files passed136.97s, every new case <=0.564s; structural0
errors and the unchanged legacy KSC_DEORBIT warning. Report:
`/tmp/kos-assistsearch-manual-20261030.json` and `.log`. These source fixtures
remain distinct from native flight evidence.

After the first native report, the rough-XING entry fix passes all88 routine
files in262.67s; reported-case regressions take0.375/0.718s, structural0 errors
with the unchanged KSC_DEORBIT warning. Results:
`/tmp/kos-assist-entry-prefix-20261030.json` and `.log`. A corrected native run
with the user's increased prediction depth is still pending.

Native follow-up5027134, Ike surveyor: original departure1061.872m/s,
3928.312m/s available, Duna Pe29,308,980m versus85km capture target. The same
reference gate still stopped orbital profiles before any trial (0.02s),
restored=True. Extend the departure-only LOWER reference to XING ORBIT goals
at the same parent or its immediate moon. Require an actual future unbound
native passage above the fallback floor; keep other phases/mixed or unrelated
goals strict. Source is departure-only-pending-capture. Full candidate route,
capture, plane, reserve, timing and savings checks remain. Unknown later
direct correction/capture costs are still unpriced, so this comparison can
reject a useful assist; it cannot claim the uncalculated capture savings.
Reported-case fixture runs the search and restores the node, but correctly
rejects a complete synthetic Ike encounter whose capture defeats that bound.
Deck settings.cfg is confirmed at CONIC_PATCH_LIMIT5; CAREER():PATCHLIMIT3
is the tracking-station API value, not a reading of that map setting. Neither
value caused this baseline refusal. No game settings are changed by the tool.
All88 routine check files pass127.71s, new reported-case regression0.371s;
structural0 errors and unchanged legacy KSC_DEORBIT warning. Report:
`/tmp/kos-assist-orbit-prefix-20261030.json` and `.log`. Corrected native
orbital search still requires a flight run.

Native5027687 reaches the new rough-arrival policy but fails reference
consistency before trials. An exact price>=later live-node-DV comparison
can contradict the separate1e-5 drift tolerance for a departure-only bound.
Price and NODE_DV now share one snapshot; the validator checks that price
against its own snapshot, retaining the original live tolerance, goal,
bound, epoch and raw-vector ownership checks. Specific reference-check
metrics are recorded even on rejection. The synthetic micro-drift case
demonstrates the bug; native causal confirmation still needs those metrics.
No unpriced later costs are added and no admission limit is widened.
All88 routine check files pass179.64s; snapshot regression0.030s, structural
0 errors/unchanged legacy KSC_DEORBIT warning. Report:
`/tmp/kos-assist-reference-snapshot-20261030.json` and `.log`.

Relevant native API references: [future-position prediction](https://ksp-kos.github.io/KOS/commands/prediction.html),
[orbit patches](https://ksp-kos.github.io/KOS/structures/orbits/orbit.html), and
[active vessel / real time](https://ksp-kos.github.io/KOS/structures/misc/kuniverse.html),
and [career prediction limits](https://ksp-kos.github.io/KOS/general/career_limits.html).
