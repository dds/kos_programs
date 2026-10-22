// One-site route using the same guarded configuration as programmed hops.
// RUNPATH("0:/cmd/hop.ks",lat,lng[,tolerance,pitch,maxBurn,maxApKm,verticalTwr]).
PARAMETER targetLat.
PARAMETER targetLng.
PARAMETER toleranceM IS 750.
PARAMETER pitchDeg IS 45.
PARAMETER maxBurnSeconds IS 90.
PARAMETER maxApKm IS 5.
PARAMETER hopTwr IS 2.5.

LOCAL FUNCTION _cmdHop {
    RUNPATH("0:/cmd/hoproute.ks",LIST(LIST(targetLat,targetLng)),700,
        toleranceM,pitchDeg,maxBurnSeconds,maxApKm,hopTwr).
}

_cmdHop().
