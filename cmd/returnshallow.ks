// ============================================================
// returnshallow.ks — Gentle Kerbin return from Mun/Minmus orbit
// (0:/cmd/returnshallow.ks)
//
// Usage: RUNPATH("0:/cmd/returnshallow.ks").
// Requires an archive link, a parachute tagged descent_chutes,
// and the engine/tank separation decoupler tagged descent_decoupler.
// Keep the controlling CPU, power and parachute on the retained probe.
// Targets 53 km +/- 1 km, preserves arrival inclination, and attempts
// KSC targeting with a 20 m/s pre-entry trim cap. Multiple atmospheric
// passes are expected; neither thermal survival nor KSC landing is assured.
// Retains the engine/tank through aerobraking; separates below 6 km
// in DESCENT, after AEROBRAKE's captured/slow handoff. No fairing required.
// Writes a resumable return profile and reboots into ESCAPE automatically.
// ============================================================

RUNPATH("1:/lib/boot_lib").
bootPreamble().
bootLibLoad("return_setup").

IF stateGet("vehicle", "") = "" {
    PRINT "Shallow return requires a saved vehicle identity.".
} ELSE IF SHIP:PARTSTAGGED("descent_decoupler"):LENGTH = 0
        OR SHIP:PARTSTAGGED("descent_chutes"):LENGTH = 0 {
    PRINT "Tag the engine/tank decoupler descent_decoupler and chute descent_chutes, then retry.".
} ELSE {
    SET RETURN_SEQUENCE TO LIST("ESCAPE", "COAST", "MCC", "RETURN_TRIM", "AEROBRAKE", "DESCENT", "DONE").
    SET RETURN_PE TO 53000.
    SET RETURN_PE_TOLERANCE TO 1000.
    SET RETURN_REENTRY_DIR TO "RETROGRADE".
    SET RETURN_KSC_TARGET TO 1.
    SET RETURN_KSC_TRIM_DV_CAP TO 20.
    SET RETURN_ARM_CHUTES TO 1.
    SET RETURN_DESCENT_FAIRING_TAG TO "none".
    SET RETURN_DESCENT_DECOUPLER_TAG TO "descent_decoupler".
    SET RETURN_DESCENT_CHUTES_TAG TO "descent_chutes".
    SET RETURN_DESCENT_DECOUPLE_ALT TO 6000.
    PRINT "Shallow return: engine/tank retained through aerobraking; separation below 6 km in DESCENT.".
    phaseReturnSetup().
}
