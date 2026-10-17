// ============================================================
// transferretry.ks — replan an unflown departure after deleting its node.
// Only for an operator-confirmed no-thrust attempt in low Kerbin orbit.
// Usage: RUNPATH("0:/cmd/transferretry.ks"). Then REBOOT.
// ============================================================
@LAZYGLOBAL OFF.

LOCAL FUNCTION _cmdTransferretry {
    RUNPATH("1:/lib/boot_lib").
    bootPreamble().

    LOCAL FUNCTION _transferRetry {
        IF stateGet("phase", "") <> "XING" {
            mLogError("Transfer retry requires saved phase XING."). RETURN FALSE.
        }
        IF HASNODE {
            mLogError("Transfer retry requires the old node to be deleted first."). RETURN FALSE.
        }
        IF ABORT OR SHIP:THRUST > 0.001 OR SHIP:CONTROL:PILOTMAINTHROTTLE > 0 {
            mLogError("Transfer retry requires throttle off, no thrust, and ABORT cleared."). RETURN FALSE.
        }
        IF SHIP:BODY:NAME <> "Kerbin" {
            mLogError("Transfer retry is only for an unflown Kerbin parking-orbit departure."). RETURN FALSE.
        }
        IF SHIP:ORBIT:ECCENTRICITY >= 1 OR SHIP:ORBIT:HASNEXTPATCH
                OR SHIP:PERIAPSIS <= SHIP:BODY:ATM:HEIGHT
                OR SHIP:APOAPSIS > 500000 {
            mLogError("Transfer retry refused: orbit is outside the low Kerbin parking corridor. Use arrival recovery for a flown transfer.").
            RETURN FALSE.
        }
        stateSet("last_transfer_retry", "ut=" + TIME:SECONDS
            + " previousStatus=" + stateGet("burn_status", "")
            + " previousReason=" + stateGet("burn_abort_reason", "")
            + " PeKm=" + ROUND(SHIP:PERIAPSIS / 1000, 1)
            + " ApKm=" + ROUND(SHIP:APOAPSIS / 1000, 1)).
        // Clear attempt and departure-flown markers together. Keep mission,
        // runtime overrides, launch history and last_burn_report intact.
        stateRemovePrefix("burn_").
        stateRemove("xing_arrival_ut").
        stateRemove("xing_arrival_target").
        stateSet("reload_required", "false").
        stateSet("reload_reason", "").
        stateSet("reload_next_phase", "").
        stateSet("reload_next_band", "").
        mLog("STATS transfer retry reset=True phase=XING operator=no-thrust-attempt").
        RETURN TRUE.
    }

    IF _transferRetry() {
        PRINT "Unflown departure attempt cleared. Mission and overrides retained.".
        PRINT "REBOOT to load updates and plan a new transfer from the current orbit.".
    }
}

_cmdTransferretry().
