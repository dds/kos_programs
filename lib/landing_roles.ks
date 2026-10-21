// ============================================================
// landing_roles.ks - Explicit carrier/lander/return hardware boundaries.
// (0:/lib/landing_roles.ks)
// Tags identify roles. This module never fires a separator or engine.
// ============================================================
@LAZYGLOBAL OFF.

GLOBAL LANDING_STAGE_LIMIT IS 0.
GLOBAL LANDING_RETURN_DECOUPLER_TAG IS "return_decoupler".
GLOBAL LANDING_RELEASE_DECOUPLER_TAG IS "lander_decoupler".
GLOBAL landingRolePolicy IS LEXICON("VALID",TRUE,"RETURN",0,"RELEASE",0,"REASON","legacy").

LOCAL FUNCTION _landingRoleSeparator {
    PARAMETER tagName.
    LOCAL result IS LEXICON("VALID",TRUE,"PART",0,"REASON","absent").
    IF tagName = "" OR tagName = "none" { RETURN result. }
    LOCAL matches IS SHIP:PARTSTAGGED(tagName).
    IF matches:LENGTH = 0 { RETURN result. }
    SET result["VALID"] TO FALSE.
    SET result["REASON"] TO "duplicate-tag:"+tagName.
    IF matches:LENGTH <> 1 { RETURN result. }
    LOCAL separator IS matches[0].
    SET result["REASON"] TO "not-a-decoupler:"+tagName.
    IF NOT separator:HASMODULE("ModuleDecouple")
            AND NOT separator:HASMODULE("ModuleAnchoredDecoupler") { RETURN result. }
    SET result["VALID"] TO TRUE.
    SET result["PART"] TO separator.
    SET result["REASON"] TO "tagged".
    RETURN result.
}

GLOBAL FUNCTION vesselLandingRoleInfo {
    LOCAL returning IS _landingRoleSeparator(LANDING_RETURN_DECOUPLER_TAG).
    LOCAL release IS _landingRoleSeparator(LANDING_RELEASE_DECOUPLER_TAG).
    LOCAL result IS LEXICON("VALID",FALSE,"RETURN",returning["PART"],
        "RELEASE",release["PART"],"REASON",returning["REASON"]).
    IF NOT returning["VALID"] { RETURN result. }
    SET result["REASON"] TO release["REASON"].
    IF NOT release["VALID"] { RETURN result. }
    LOCAL returnPart IS returning["PART"].
    LOCAL releasePart IS release["PART"].
    IF returnPart <> 0 {
        SET result["REASON"] TO "return-boundary-not-stageable".
        IF returnPart:ISDECOUPLED OR NOT returnPart:STAGED
                OR returnPart:STAGE < 0 OR STAGE:NUMBER <= returnPart:STAGE { RETURN result. }
        SET result["REASON"] TO "core-not-retained-with-return".
        IF CORE:PART:DECOUPLEDIN >= returnPart:STAGE { RETURN result. }
        IF releasePart <> 0 AND NOT releasePart:ISDECOUPLED {
            SET result["REASON"] TO "overlapping-or-reversed-boundaries".
            IF releasePart = returnPart OR releasePart:STAGE <= returnPart:STAGE { RETURN result. }
        }
        LOCAL landerFound IS FALSE.
        LOCAL returnFound IS FALSE.
        FOR eng IN SHIP:ENGINES {
            IF eng:POSSIBLETHRUST > 0 AND NOT eng:THROTTLELOCK AND NOT eng:FLAMEOUT {
                IF eng:DECOUPLEDIN = returnPart:STAGE
                        AND eng:STAGE >= MAX(LANDING_STAGE_LIMIT,returnPart:STAGE+1) {
                    SET landerFound TO TRUE.
                }
                IF eng:DECOUPLEDIN < returnPart:STAGE {
                    SET result["REASON"] TO "return-engine-enabled-or-misstaged".
                    IF eng:IGNITION OR eng:STAGE > returnPart:STAGE { RETURN result. }
                    SET returnFound TO TRUE.
                }
            }
        }
        SET result["REASON"] TO "no-lander-or-return-engine-at-boundary".
        IF NOT landerFound OR NOT returnFound { RETURN result. }
    }
    SET result["VALID"] TO TRUE.
    SET result["REASON"] TO "legacy".
    IF returnPart <> 0 OR releasePart <> 0 { SET result["REASON"] TO "tagged". }
    RETURN result.
}

GLOBAL FUNCTION vesselLandingStageFloor {
    // Invalid role metadata blocks additional staging, not useful thrust
    // from an already running engine during a committed descent.
    IF NOT landingRolePolicy["VALID"] { RETURN STAGE:NUMBER+1. }
    LOCAL floorStage IS MAX(0,LANDING_STAGE_LIMIT).
    LOCAL returnPart IS landingRolePolicy["RETURN"].
    IF returnPart <> 0 {
        IF returnPart:ISDECOUPLED { RETURN STAGE:NUMBER+1. }
        // Read the current staging number from the tagged part, not saved
        // integers. A manual floor can tighten, never weaken, this boundary.
        SET floorStage TO MAX(floorStage,returnPart:STAGE+1).
    }
    RETURN floorStage.
}

GLOBAL FUNCTION vesselLandingPrepareRoles {
    LOCAL info IS vesselLandingRoleInfo().
    SET landingRolePolicy["VALID"] TO info["VALID"].
    SET landingRolePolicy["RETURN"] TO info["RETURN"].
    SET landingRolePolicy["RELEASE"] TO info["RELEASE"].
    SET landingRolePolicy["REASON"] TO info["REASON"].
    LOCAL returnStage IS -1.
    LOCAL releaseStage IS -1.
    IF info["RETURN"] <> 0 { SET returnStage TO info["RETURN"]:STAGE. }
    IF info["RELEASE"] <> 0 { SET releaseStage TO info["RELEASE"]:STAGE. }
    mLog("STATS landing roles valid=" + info["VALID"] + " reason=" + info["REASON"]
        + " floor=" + vesselLandingStageFloor()
        + " returnStage=" + returnStage + " releaseStage=" + releaseStage
        + " returnTag=" + LANDING_RETURN_DECOUPLER_TAG
        + " releaseTag=" + LANDING_RELEASE_DECOUPLER_TAG).
    RETURN info["VALID"].
}
