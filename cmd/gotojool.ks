// ============================================================
// cmd/gotojool.ks - Preset Jool transfer for an orbiting telescope
// (0:/cmd/gotojool.ks)
//
// Usage:
//   RUNPATH("0:/cmd/gotojool.ks").
//   RUNPATH("0:/cmd/gotojool.ks", LEX("ap", 25000000)).
//
// Defaults target a 250 x 15000 km equatorial Jool orbit. Jool's
// atmosphere ends at 200 km, so 250 km keeps clear of atmosphere;
// the high apoapsis makes initial capture much less expensive than
// forcing a low circular orbit immediately.
// ============================================================

PARAMETER opts IS LEXICON().

LOCAL plan IS LEXICON(
    "dest", "Jool",
    "pe", 250000,
    "ap", 15000000,
    "inc", 0,
    "reboot", TRUE
).

FOR key IN opts:KEYS {
    IF plan:HASKEY(key) { plan:REMOVE(key). }
    plan:ADD(key, opts[key]).
}

RUNPATH("0:/cmd/goto.ks", plan).
