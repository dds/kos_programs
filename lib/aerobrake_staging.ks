// ============================================================
// aerobrake_staging.ks - Audited serial-stage handoffs between entries.
// (0:/lib/aerobrake_staging.ks)
// Never called by the powered controller. No staging inside atmosphere.
// ============================================================
@LAZYGLOBAL OFF.

// Own-stage enabled mixture, independent of KSP's sometimes stale dV.
// -1 means unmodelled hardware; zero means a valid, empty fuel group.
LOCAL FUNCTION _aeroStageFuelDv {
    PARAMETER enginePart.
    PARAMETER fuelGroup.
    PARAMETER wetMass.
    IF NOT (wetMass > 0 AND enginePart:VISP > 0)
            OR enginePart:THROTTLELOCK OR enginePart:MULTIMODE { RETURN -1. }
    LOCAL mixture IS enginePart:CONSUMEDRESOURCES.
    IF mixture:LENGTH = 0 { RETURN -1. }
    LOCAL mixtureUnits IS 1e30.
    LOCAL mixtureDensity IS 0.
    FOR fuel IN mixture:VALUES {
        IF NOT (fuel:RATIO > 0 AND fuel:DENSITY > 0) { RETURN -1. }
        LOCAL units IS 0.
        FOR part IN SHIP:PARTS {
            IF part:DECOUPLEDIN = fuelGroup {
                FOR held IN part:RESOURCES {
                    IF held:NAME = fuel:NAME AND held:ENABLED {
                        IF NOT (held:AMOUNT >= 0 AND held:AMOUNT < 1e30) { RETURN -1. }
                        SET units TO units+held:AMOUNT.
                    }
                }
            }
        }
        SET mixtureUnits TO MIN(mixtureUnits,units/fuel:RATIO).
        SET mixtureDensity TO mixtureDensity+fuel:RATIO*fuel:DENSITY.
    }
    LOCAL fuelMass IS mixtureUnits*mixtureDensity.
    IF NOT (fuelMass >= 0 AND fuelMass < wetMass) { RETURN -1. }
    RETURN enginePart:VISP*CONSTANT:G0*LN(wetMass/(wetMass-fuelMass)).
}

LOCAL FUNCTION _aeroStageCoasting {
    PARAMETER atmHeight.
    PARAMETER peLow.
    PARAMETER peHigh.
    RETURN AEROBRAKE_AP_BURN > 0 AND NOT ABORT AND NOT HASNODE
        AND AEROBRAKE_REENTRY_DIR <> "PROGRADE" AND NOT phaseShouldYield
        AND NOT stateGet("aerobrake_ap_active",FALSE)
        AND SHIP:STATUS <> "LANDED" AND SHIP:STATUS <> "SPLASHED"
        AND SHIP:ALTITUDE > atmHeight+1000 AND SHIP:ORBIT:ECCENTRICITY < 1
        AND SHIP:PERIAPSIS >= peLow+100 AND SHIP:PERIAPSIS <= peHigh-100
        AND SHIP:Q >= 0 AND SHIP:Q <= AEROBRAKE_AP_MAX_Q
        AND SHIP:THRUST <= 0.001 AND SHIP:CONTROL:MAINTHROTTLE <= 0
        AND SHIP:CONTROL:PILOTMAINTHROTTLE <= 0 AND WARP = 0
        AND KUNIVERSE:TIMEWARP:ISSETTLED AND STAGE:READY
        AND aerobrakeApEntryEta(atmHeight) > 60.
}

// Part:STAGE includes inert tanks/legs in native saves. Audit modules, not
// just part count. Unknown modules block automation. The one additional
// staging action admitted is RO9's main_fairing on the discarded side;
// its fairing/shrouds can never be retained protection for the probe.
LOCAL FUNCTION _aeroStageUnexpectedModule {
    PARAMETER part.
    PARAMETER separator.
    PARAMETER arriving.
    PARAMETER nextStage.
    LOCAL passive IS LIST("ModulePartVariants","ModuleCargoPart","KOSNameTag",
        "KRnDModule","AYPart","GPWSGear","ModuleTestSubject","ModuleColorChanger",
        "FXModuleThrottleEffects","ModuleWheelBase","ModuleWheelSuspension",
        "ModuleWheelDeployment","ModuleWheelLock","ModuleWheelDamage",
        "ModuleCargoBay","ModuleStructuralNode","ModuleStructuralNodeToggle",
        "ModuleRestockModifyFairingMaterials").
    FOR moduleName IN part:MODULES {
        LOCAL allowed IS passive:CONTAINS(moduleName).
        IF part = arriving AND (moduleName = "ModuleEngines" OR moduleName = "ModuleEnginesFX"
                OR moduleName = "ModuleJettison") { SET allowed TO TRUE. }
        IF part = separator AND (moduleName = "ModuleDecouple" OR moduleName = "ModuleAnchoredDecoupler"
                OR moduleName = "ModuleToggleCrossfeed") { SET allowed TO TRUE. }
        IF part:TAG = "main_fairing" AND part:DECOUPLEDIN = nextStage
                AND moduleName = "ModuleProceduralFairing" { SET allowed TO TRUE. }
        IF NOT allowed { RETURN moduleName. }
    }
    RETURN "".
}

LOCAL FUNCTION _aeroStagePlan {
    PARAMETER pendingUid IS "".
    LOCAL result IS LEXICON("OK",FALSE,"REASON","no-adjacent-tagged-boundary").
    LOCAL nextStage IS STAGE:NUMBER-1.
    IF nextStage < 0 { RETURN result. }
    LOCAL separator IS 0.
    FOR tagName IN AEROBRAKE_AP_STAGE_TAGS {
        LOCAL matches IS SHIP:PARTSTAGGED(tagName).
        IF matches:LENGTH > 1 {
            SET result["REASON"] TO "duplicate-separator-tag". RETURN result.
        }
        IF matches:LENGTH = 1 {
            LOCAL found IS matches[0].
            IF NOT (found:HASMODULE("ModuleDecouple") OR found:HASMODULE("ModuleAnchoredDecoupler")) {
                SET result["REASON"] TO "tag-is-not-separator". RETURN result.
            }
            IF found:STAGE = nextStage AND NOT found:ISDECOUPLED {
                IF separator <> 0 {
                    SET result["REASON"] TO "ambiguous-separator-tags". RETURN result.
                }
                SET separator TO found.
            }
        }
    }
    IF separator = 0 { RETURN result. }
    SET result["REASON"] TO "separator-not-stageable-or-prior-attempt".
    IF NOT separator:STAGED OR CORE:PART:DECOUPLEDIN >= nextStage
            OR (stateGet("aerobrake_ap_stage_attempt","") = separator:UID
                AND pendingUid <> separator:UID) { RETURN result. }
    LOCAL chutes IS SHIP:PARTSTAGGED("descent_chutes").
    SET result["REASON"] TO "parachutes-not-retained".
    IF chutes:LENGTH = 0 { RETURN result. }
    FOR chute IN chutes {
        IF NOT chute:HASMODULE("ModuleParachute") OR chute:DECOUPLEDIN >= nextStage { RETURN result. }
    }
    LOCAL departing IS 0.
    LOCAL arriving IS 0.
    SET result["REASON"] TO "unsupported-engine-layout".
    FOR eng IN SHIP:ENGINES {
        IF eng:IGNITION {
            IF departing <> 0 OR eng:DECOUPLEDIN <> nextStage
                    OR eng:STAGE <> STAGE:NUMBER OR eng:THROTTLELOCK OR eng:MULTIMODE { RETURN result. }
            SET departing TO eng.
        }
        IF eng:STAGE = nextStage {
            IF arriving <> 0 OR eng:IGNITION OR eng:DECOUPLEDIN >= nextStage
                    OR eng:THROTTLELOCK OR eng:MULTIMODE OR eng:FLAMEOUT
                    OR NOT eng:ALLOWRESTART OR NOT (eng:POSSIBLETHRUST > 0) { RETURN result. }
            SET arriving TO eng.
        }
    }
    IF departing = 0 OR arriving = 0 { RETURN result. }
    // STAGE fires the whole slot, including modules on the intended engine
    // and separator. Reject unknown modules there too, not just extra parts.
    LOCAL accountedMass IS 0.
    LOCAL retainedMass IS 0.
    FOR part IN SHIP:PARTS {
        IF part:STAGE = nextStage {
            LOCAL unexpected IS _aeroStageUnexpectedModule(part,separator,arriving,nextStage).
            IF unexpected <> "" {
                SET result["REASON"] TO "unexpected-stage-module:"+part:NAME+":"+unexpected.
                RETURN result.
            }
        }
        SET accountedMass TO accountedMass+part:MASS.
        IF part:DECOUPLEDIN < nextStage { SET retainedMass TO retainedMass+part:MASS. }
    }
    SET retainedMass TO retainedMass+MAX(0,SHIP:MASS-accountedMass).
    LOCAL currentFuel IS _aeroStageFuelDv(departing,nextStage,SHIP:MASS).
    LOCAL nextFuel IS _aeroStageFuelDv(arriving,arriving:DECOUPLEDIN,retainedMass).
    LOCAL reserve IS aerobrakeApReserveDv().
    LOCAL stockFuel IS STAGE:DELTAV:VACUUM.
    SET result["REASON"] TO "fuel-not-depleted-or-next-reserve-unavailable".
    // Both independent estimates must say the active stage is at its reserve.
    // A transient stock zero alone must never discard a fueled stage.
    IF NOT (currentFuel >= 0 AND currentFuel <= reserve+1
            AND stockFuel >= 0 AND stockFuel <= reserve+1
            AND nextFuel > reserve+1 AND nextFuel < 1e30) { RETURN result. }
    RETURN LEXICON("OK",TRUE,"REASON","reserve-reached","STAGE",nextStage,
        "SEPARATOR",separator,"DEPARTING",departing,"ARRIVING",arriving,
        "BODY",SHIP:BODY:NAME,"SEPARATOR_UID",separator:UID,
        "DEPARTING_UID",departing:UID,"ARRIVING_UID",arriving:UID,
        "CURRENT_DV",currentFuel,"NEXT_DV",nextFuel,"MASS_AFTER",retainedMass).
}

GLOBAL FUNCTION aerobrakeApStageCoast {
    PARAMETER atmHeight.
    PARAMETER peLow.
    PARAMETER peHigh.
    IF AEROBRAKE_AP_STAGE_TAGS:LENGTH = 0 OR NOT _aeroStageCoasting(atmHeight,peLow,peHigh) { RETURN FALSE. }
    LOCAL plan IS _aeroStagePlan().
    mLog("STATS aerobrake-stage check ok=" + plan["OK"] + " reason=" + plan["REASON"]
        + " stage=" + STAGE:NUMBER + " Pe=" + SHIP:PERIAPSIS + " Ap=" + SHIP:APOAPSIS).
    IF NOT plan["OK"] { RETURN FALSE. }
    IF NOT thrustCutoffOk(FALSE) { RETURN FALSE. }
    LOCAL priorDeferral IS LOG_ARCHIVE_DEFERRED.
    SET LOG_ARCHIVE_DEFERRED TO 1.
    // Persist one attempt per physical separator BEFORE firing. A reboot
    // between this write and verification must not repeat that stage event.
    stateSet("aerobrake_ap_stage_attempt",plan["SEPARATOR_UID"]).
    // State writes can yield. Recheck all hardware and fuel before STAGE;
    // only this RAM owner can admit the just-recorded attempt once.
    LOCAL checked IS _aeroStagePlan(plan["SEPARATOR_UID"]).
    IF NOT _aeroStageCoasting(atmHeight,peLow,peHigh)
            OR SHIP:BODY:NAME <> plan["BODY"]
            OR STAGE:NUMBER <> plan["STAGE"]+1 OR NOT checked["OK"] {
        SET LOG_ARCHIVE_DEFERRED TO priorDeferral. RETURN FALSE.
    }
    IF checked["SEPARATOR"] <> plan["SEPARATOR"] OR checked["ARRIVING"] <> plan["ARRIVING"]
            OR checked["DEPARTING"] <> plan["DEPARTING"] {
        SET LOG_ARCHIVE_DEFERRED TO priorDeferral. RETURN FALSE.
    }
    STAGE.
    WAIT 0.5.
    LOCAL stopped IS thrustCutoffOk(FALSE).
    IF NOT stopped { RETURN FALSE. }
    LOCAL valid IS NOT ABORT AND NOT HASNODE AND SHIP:BODY:NAME = plan["BODY"]
        AND STAGE:NUMBER = plan["STAGE"].
    // Inspect the retained vessel. A detached/destroyed Part reference is
    // not a reliable place to read suffixes after a staging event.
    FOR part IN SHIP:PARTS {
        IF part:UID = plan["SEPARATOR_UID"] AND NOT part:ISDECOUPLED { SET valid TO FALSE. }
    }
    LOCAL departed IS TRUE.
    LOCAL arrived IS FALSE.
    FOR eng IN SHIP:ENGINES {
        IF eng:UID = plan["DEPARTING_UID"] { SET departed TO FALSE. }
        IF eng:UID = plan["ARRIVING_UID"] AND eng:IGNITION AND NOT eng:FLAMEOUT
                AND eng:AVAILABLETHRUST > 0 { SET arrived TO TRUE. }
        IF eng:IGNITION AND eng:UID <> plan["ARRIVING_UID"] { SET valid TO FALSE. }
    }
    SET LOG_ARCHIVE_DEFERRED TO priorDeferral.
    mLog("STATS aerobrake-stage result verified=" + (valid AND departed AND arrived)
        + " stage=" + STAGE:NUMBER + " departingGone=" + departed + " nextIgnited=" + arrived
        + " discardedDv=" + plan["CURRENT_DV"] + " nextDv=" + plan["NEXT_DV"]
        + " massBeforeForecast=" + SHIP:MASS + " cutoffOk=" + stopped).
    IF NOT (valid AND departed AND arrived) {
        mLogError("Aerobrake stage handoff not verified; inspect staging/engines manually at zero throttle. No automatic repeat.").
        yieldToPrompt(). RETURN FALSE.
    }
    // No prior forecast survives the change of mass/engine. The normal
    // next-entry planning path measures the new stage at its own 180s wake.
    RETURN TRUE.
}
