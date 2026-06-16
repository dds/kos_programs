// KerboScript mission profile.
SET MISSION_CFG TO LEXICON(
    "MISSION_ID", "krbcap1_suborbital_ksc",
    "MISSION_NAME", "KRBCAP1 Round-the-World Hop",
    "TARGET", "KERBIN",
    "PAYLOADS", "KRBCAP1",
    "SEQUENCE", "LAUNCH,SUBORBIT,DESCENT,DONE",
    "PARKING_ALT", 85000,
    "LAUNCH_INCLINATION", 0,
    "SUBORBIT_RETURN", 1,
    "SUBORBIT_RETURN_TOL", 40000,
    "LIBS_EXTRA", "suborbit@SUBORBIT, descent",
    "DESCENT_DECOUPLER_TAG", "descent_decoupler",
    "DESCENT_DECOUPLE_ALT", -100,
    "DESCENT_RELEASE_ALT", 38000
).
