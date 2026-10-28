// Select a numbered saved hop site without igniting. Omit the number for
// a bounded site menu. Site3 is Gamma in RO9's polar-hops mission.
// RUNPATH("0:/cmd/hopnext.ks",3). then REBOOT. when ready.
@LAZYGLOBAL OFF.
PARAMETER siteNumber IS -1.

LOCAL FUNCTION _cmdHopnext {
    IF ABORT OR HASNODE OR SHIP:STATUS <> "LANDED" OR SHIP:BODY:ATM:EXISTS
            OR SHIP:VELOCITY:SURFACE:MAG > 0.5 OR SHIP:THRUST > 0.001
            OR SHIP:CONTROL:MAINTHROTTLE > 0 OR SHIP:CONTROL:PILOTMAINTHROTTLE > 0 {
        PRINT "Hop selection requires a settled airless landing, idle controls, no node and Abort clear.".
        RETURN.
    }
    IF HOMECONNECTION:ISCONNECTED AND EXISTS("0:/lib/boot_lib.ks") {
        RUNPATH("0:/lib/boot_lib.ks").
    } ELSE { RUNPATH("1:/lib/boot_lib"). }
    bootPruneLandedHopCache().
    bootPreamble().
    bootLibLoad("hop_route").
    LOCAL vehicle IS stateGet("vehicle","").
    LOCAL mission IS stateGet("mission_id","").
    IF vehicle = "" OR mission = "" {
        PRINT "Select the original mission first; no hop configured.". RETURN.
    }
    bootLibLoad("craft/"+vehicle).
    IF NOT bootApplyMissionConfig(vehicle,mission,HOMECONNECTION:ISCONNECTED) { RETURN. }
    // The active state route is authoritative. Profile edits do not rewrite
    // its progress or preserved return plan. A lost route can be rebuilt only
    // at the configured first site through the ordinary preparation gates.
    IF NOT stateGet("hop_route_active",FALSE) {
        IF NOT hopRoutePrepare() { RETURN. }
    }
    LOCAL selected IS siteNumber.
    IF selected < 0 {
        LOCAL defaultSite IS stateGetNum("hop_route_index",0)+2.
        IF defaultSite > stateGet("hop_route_sites",LIST()):LENGTH { SET defaultSite TO 0. }
        SET selected TO hopChooseSite(defaultSite).
    }
    IF selected < 0 { PRINT "No hop selected; original route retained.". RETURN. }
    // Select only the next pending leg. The completed-site index advances
    // when HOP actually starts, never when the operator skips another site.
    stateSet("phase",hopReviewPhase()).
    IF selected = 0 {
        hopFinishRoute(FALSE).
        PRINT "Configured return selected. REBOOT. when ready.". RETURN.
    }
    IF NOT hopSelectSite(selected,FALSE) { RETURN. }
    PRINT "Hop site " + selected + " selected. REBOOT. when ready to fly the hop.".
}

_cmdHopnext().
