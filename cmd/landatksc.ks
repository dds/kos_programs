// ============================================================
// cmd/landatksc.ks  —  Land near KSC from Kerbin orbit
// (0:/cmd/landatksc.ks)
//
// Preset wrapper around cmd/landat.ks: targets the water just
// offshore of KSC unless coordinates or a waypoint are given.
// All landat options pass through (entry_pe, tolerance,
// max_orbits, samples, refine, strict, descent_* tags).
//
// Usage:
//   RUNPATH("0:/cmd/landatksc.ks").
//   RUNPATH("0:/cmd/landatksc.ks", LEX("entry_pe", 25000)).
//
// (cmd/kscsplash.ks remains the one-shot version: it flies only
// the burn and leaves entry to the operator.)
// ============================================================

PARAMETER opts IS LEXICON().

IF NOT opts:HASKEY("lat") AND NOT opts:HASKEY("lng")
        AND NOT opts:HASKEY("waypoint") {
    opts:ADD("lat", -0.10).
    opts:ADD("lng", -74.25).
}
IF NOT opts:HASKEY("name") {
    opts:ADD("name", "Land at KSC").
}

RUNPATH("0:/cmd/landat.ks", opts).
