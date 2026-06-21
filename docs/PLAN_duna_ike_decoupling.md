# Plan: decouple Duna from Ike (make everything Duna and/or Ike)

## Intent

Today the Duna arrival/entry/landing machinery and the Ike flyby glue are
welded together in one library and one band. We want missions to be able
to be **Duna-only**, **Ike-only (flyby)**, or **Duna + Ike** without one
dragging in the other. This is a "come back to it" refactor — this doc is
the map so we don't have to re-derive it.

## The one real coupling

`lib/duna_ike_setup.ks` owns four phase handlers — three Duna, one Ike —
and `dependencies.ks` bundles all four into a single band:

| Phase | Handler | Concern |
|---|---|---|
| `DUNA_AEROCAPTURE` | `phaseDunaAerocapture` | **Duna** |
| `DUNA_ENTRY_SETUP` | `phaseDunaEntrySetup` (rewrites to `DUNA_ENTRY_SEQUENCE`) | **Duna** |
| `DUNA_ENTRY_LOWER_PE` | `phaseDunaEntryLowerPe` | **Duna** |
| `IKE_SETUP` | `phaseIkeSetup` (rewrites to `IKE_FLYBY_SEQUENCE`) | **Ike** |

`dependencies.ks`:
- `dependencyPhases`: all four map to `"duna_ike_setup"` (lines ~90-93).
- `dependencyBands`: `DUNA_IKE_SETUP` = all four phases (line ~156).
- `dependencyBindPhase`: four bindings (lines ~192-195).

**Why it matters** (per the "bands load every phase's libs" rule): a
Duna-only aerocapture mission that uses `DUNA_AEROCAPTURE` also loads the
Ike flyby code, and an Ike flyby loads the Duna entry code — pure
coupling, and it conflates two concerns in one file.

## Where each thing lives (classification)

**Duna-only**
- `lib/duna_ike_setup.ks`: `phaseDunaAerocapture`, `phaseDunaEntrySetup`,
  `phaseDunaEntryLowerPe`, `DUNA_ENTRY_SEQUENCE`, `DUNA_ENTRY_*` config.
- `lib/landing_atmo.ks` (`ATMO_WALK`) — Duna/atmospheric landing.
- Missions: `missions/FalconHeavy/duna_scisat_lander.ks` (direct landing),
  `duna_relay_molniya_high.ks`, `duna_relay_molniya_high_2.ks`,
  `duna_scansat_polar.ks`.
- `cmd/gotoduna.ks`.
- `aerobrake`/`descent` `ATM_HEIGHTS["DUNA"]` table entries (data — keep).

**Ike-only**
- `lib/duna_ike_setup.ks`: `phaseIkeSetup`, `IKE_FLYBY_SEQUENCE`,
  `IKE_FLYBY_*` / `IKE_*` config.

**Duna + Ike (combined missions)**
- `missions/FalconHeavy/duna_ike_scisat_lander.ks` — aerocapture → SHAPE →
  Ike flyby → Duna entry/landing. The reason `duna_ike_setup` exists.
- `missions/FR3C/duna_ike_flyby_probe.ks` — Duna transfer + `FLYBY` (does
  not actually use the `IKE_SETUP` phase; named for intent).

**Incidental (NO change needed — comments/examples/data only)**
- `phases, observe, lambert, orbit_shape, maneuver_targeting, molniya,`
  `relay_constellation, solar, suborbit, airplane, drone, maneuver_plan`:
  the word "Duna"/"Ike" appears only in comments/examples or, for
  `aerobrake`/`descent`, in the atmosphere-height table. Don't chase these.

## Proposed split (the work to come back to)

1. Split `lib/duna_ike_setup.ks` into:
   - `lib/duna_entry.ks` — the three Duna phases + `DUNA_ENTRY_SEQUENCE`
     + `DUNA_*` config (reusable by any Duna lander/aerocapture mission).
   - `lib/ike_flyby.ks` — `phaseIkeSetup` + `IKE_FLYBY_SEQUENCE` + `IKE_*`.
   - Any shared state/reboot glue (`mission_cfg_*` rewrite, lib-cache
     clear) moves to a small shared helper or stays in `core`.
2. Split the band: `DUNA_ENTRY` (the three Duna phases) and `IKE_FLYBY`
   (`IKE_SETUP`), so a mission loads only what it flies.
3. Repoint `dependencyPhases` / `dependencyBindPhase` accordingly.
4. The combo mission (`duna_ike_scisat_lander`) and its setup move
   **elsewhere** (its own mission-glue file) and compose the two split
   modules — Duna entry should not be defined inside the combo.

Net: `duna_scisat_lander` (and future Duna-only aerocapture missions) use
the Duna module without Ike; a pure Ike flyby uses the Ike module without
Duna entry; the combo uses both. None forces the other.

## Status

Audit only — no split done yet. The `ATMO_WALK` insertion into the Duna
entry sequences (both `duna_scisat_lander` and `DUNA_ENTRY_SEQUENCE`)
landed alongside this doc. Related: [[powered-descent-roadmap]],
`docs/PLAN_duna_precision_landing.md`,
`docs/PLAN_falconheavy_duna_ike_aerocapture.md`.
