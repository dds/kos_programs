// ============================================================
// fr3_payload.ks - FR3 payload classification helpers
// ============================================================

GLOBAL FUNCTION fr3HasPayload {
    PARAMETER payloadName.
    FOR ptype IN missionPayloads() {
        IF normalizePayloadType(ptype) = payloadName:TOUPPER { RETURN TRUE. }
    }
    RETURN FALSE.
}

GLOBAL FUNCTION fr3HasLandingPayload {
    FOR ptype IN missionPayloads() {
        LOCAL t IS normalizePayloadType(ptype).
        IF t = "LANDER" OR t = "ASSISTLANDER"
                OR t = "ROVER" OR t = "ASSISTROVER" {
            RETURN TRUE.
        }
    }
    RETURN FALSE.
}
