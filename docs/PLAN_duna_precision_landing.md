# Plan: Duna precision landing (aerobrake + drift-baselined atmo walk + powered terminal)

## Goal

Bring the airless ~200 m landing precision to Duna by closing the loop
*inside* the atmosphere, then combining it with chutes and a powered
terminal touchdown. The vacuum `COAST_MCC` walk explicitly refuses to
run in air (`landing_main.ks`: "Vacuum landing FSM requested on body
with atmosphere; continuing with powered descent only") because drag
continuously moves the predicted impact and corrupts the pulse
attribution.

## The chain

```
DUNA_AEROCAPTURE → SHAPE        get into a Duna orbit (existing)
AEROBRAKE  (target-aware)       correction burn aims the entry at the site
ATMO_WALK  (NEW, this plan)     drift-baselined closed-loop correction in the glide
DESCENT    (descent.ks)         chutes, bulk deceleration once subsonic
TERMINAL   (landing_terminal)   powered precise soft touchdown (later step)
```

Enablers already shipped: ascent pitches over sooner; `aerobrake`
targets the resolved landing site (`landingResolveTarget`) instead of
hardcoded KSC, skipping targeting on non-Kerbin bodies when no site is
set.

## Decisions (2026-06-21)

1. **Thrust-only** correction for now (no lift-vector / AoA steering).
   Fine for low-L/D probe landers.
2. **No fabricated ballistic lead.** Trajectories' impact prediction
   already includes drag, so `ATMO_WALK` aims at the *real* target and
   feeds back on the drag-inclusive prediction. Any residual (e.g.
   chute drift) is mopped up by the powered terminal — we do not
   hardcode a downfield phantom the way the vacuum deorbit does.
3. **ΔV budget**: the craft have ~1100 m/s spare, so this is not ΔV-
   constrained. Cap the walk at `ATMO_WALK_MAX_DV` and stop early if
   remaining ΔV drops below `ATMO_WALK_RESERVE_DV` (kept for the
   terminal). With 1100 spare neither limit should bind; they exist so
   a low-fuel craft degrades gracefully to "chutes land it untargeted"
   rather than starving the touchdown.

## The drift-baselined corrector (control authority)

Never model drag. Each cycle:

1. **Baseline** — throttle 0, hold a stable entry attitude
   (surface-retrograde), record the Trajectories impact-to-target
   offset at the start and end of a short window. The delta / time is
   the **drag drift rate** (a horizontal 2-D vector): drag's live
   signature, measured, not modeled.
2. **Pulse** — steer the correction direction (horizontal, toward the
   target = −offset) and fire a small measured ΔV pulse.
3. **Attribute** — `pulse_effect = Δoffset − drift_rate × window`. Only
   the excess over baseline drift is the pulse. Project onto the
   correction direction to get effectiveness (m of offset closed per
   m/s), and adapt the gain (smoothed) so subsequent pulse sizes are
   right.
4. **Re-measure → re-plan** every cycle (drag changes with density and
   speed), until offset ≤ tolerance, an altitude/speed floor, or a ΔV
   limit — then hand to `DESCENT`.

Closed-loop and self-correcting: even a wrong initial gain converges
because every cycle pulses toward the current offset and re-measures.
The drift subtraction is what stops drag motion being mis-credited to a
pulse (the failure that flipped a measured direction and doubled a miss
on Kerbin).

## Hand-off to chutes / terminal

- `ATMO_WALK` stops at `ATMO_WALK_FLOOR_ALT` (well above chute-deploy)
  and hands to `DESCENT`, which arms/deploys chutes for the bulk
  deceleration.
- A later step lets the body-agnostic powered terminal
  (`landing_terminal`) run in atmosphere for the final precise meters
  (optionally cutting chutes low). Not in this first track.

## Per-craft notes (three probes inbound)

- Two probes: 4 drogues + 1 XL chute — best terminal margin.
- One probe: 2 drogues, no XL — descends faster under chutes, needs
  more powered-terminal authority; lands harder if terminal is absent.
- One probe **may have no radio** → it cannot sync this new code and
  will fly whatever was installed at the VAB. `ATMO_WALK` only helps a
  craft that booted with it; the others fall back to untargeted
  aerobrake + chutes. Accepted risk.

We get ~one test, one real attempt, maybe a spare test. So: conservative
pulses, generous `STATS` logging every cycle, hard floors, and graceful
skips when Trajectories/target/atmosphere preconditions aren't met.

## Wiring

- New `lib/landing_atmo.ks` owns `phaseAtmoWalk` (`ATMO_WALK`).
- `dependencies.ks`: lib deps `landing_config, utils, orbit`; phase
  `ATMO_WALK → landing_atmo`; its own single-phase band; handler bind.
- Mission integration: insert `ATMO_WALK` between `AEROBRAKE` and
  `DESCENT` in the Duna entry sequence (the `duna_ike_setup`
  entry-leg rewrite) once the track is flight-confirmed.

## Status

Not flight-proven. First flight is the tuning pass for
`ATMO_WALK_GAIN0`, pulse sizes, baseline window, and the floor.
Related: [[powered-descent-roadmap]].
