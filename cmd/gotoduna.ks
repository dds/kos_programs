// ============================================================
// cmd/gotoduna.ks - Preset Duna transfer for an orbiting telescope
// (0:/cmd/gotoduna.ks)
//
// Usage:
//   RUNPATH("0:/cmd/gotoduna.ks").
//   RUNPATH("0:/cmd/gotoduna.ks", LEX("ap", 500000, "reboot", FALSE)).
//
// Defaults target an 85 x 250 km equatorial Duna orbit. Duna's
// atmosphere ends at 50 km, so 85 km leaves a practical correction
// margin while still keeping capture efficient.
// ============================================================

PARAMETER opts IS LEXICON().

LOCAL plan IS LEXICON(
    "dest", "Duna",
    "pe", 85000,
    "ap", 250000,
    "inc", 0,
    "reboot", TRUE
).

FOR key IN opts:KEYS {
    IF plan:HASKEY(key) { plan:REMOVE(key). }
    plan:ADD(key, opts[key]).
}

RUNPATH("0:/cmd/goto.ks", plan).
