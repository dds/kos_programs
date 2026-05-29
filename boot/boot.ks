// ============================================================
// boot.ks  —  Generic mission boot  (0:/boot/boot.ks)
// Minimal and stable — do not add logic here.
// All resume/manual/phase logic lives in resume.ks
// ============================================================

CLEARSCREEN.
PRINT "=== BOOT: " + SHIP:NAME + " ===".

// ── Parse ship name: VEHICLE-TARGET-TYPE1-TYPE2 ────────────
LOCAL rawTokens IS SHIP:NAME:SPLIT("-").
LOCAL tokens IS LIST().
FOR t IN rawTokens {
    LOCAL trimmed IS t:TRIM.
    IF trimmed <> "" { tokens:ADD(trimmed). }
}
IF tokens:LENGTH < 2 {
    PRINT "BOOT ERROR: name must be VEHICLE-TARGET[-TYPE...]".
    PRINT "Got: " + SHIP:NAME.
    WAIT UNTIL FALSE.
}
LOCAL vehicleName IS tokens[0].
LOCAL targetName  IS tokens[1]:TOUPPER.
LOCAL payloadTypes IS LIST().
LOCAL idx IS 2.
UNTIL idx >= tokens:LENGTH {
    payloadTypes:ADD(tokens[idx]:TOUPPER).
    SET idx TO idx + 1.
}

// ── Ensure local dirs ──────────────────────────────────────
LOCAL FUNCTION ensureDir { PARAMETER p. IF NOT EXISTS(p) { CREATEDIR(p). } }
ensureDir("1:/lib").
ensureDir("1:/boot").
ensureDir("1:/logs").
ensureDir("1:/state").
ensureDir("1:/cmd").

// ── Sync archive → local ───────────────────────────────────
PRINT "Syncing...".
COPYPATH("0:/boot/boot.ks",           "1:/boot/boot.ks").
COPYPATH("0:/lib/countdown.ks",       "1:/lib/countdown.ks").
COPYPATH("0:/lib/state.ks",           "1:/lib/state.ks").
COPYPATH("0:/lib/logs.ks",            "1:/lib/logs.ks").
COPYPATH("0:/lib/maneuver.ks",        "1:/lib/maneuver.ks").
COPYPATH("0:/lib/inclination.ks",     "1:/lib/inclination.ks").
COPYPATH("0:/lib/orbit.ks",           "1:/lib/orbit.ks").
COPYPATH("0:/lib/files.ks",           "1:/lib/files.ks").
COPYPATH("0:/lib/resume.ks",          "1:/lib/resume.ks").
COPYPATH("0:/lib/landing.ks",         "1:/lib/landing.ks").
COPYPATH("0:/lib/science.ks",         "1:/lib/science.ks").
COPYPATH("0:/lib/relay_constellation.ks", "1:/lib/relay_constellation.ks").
COPYPATH("0:/lib/rover.ks",           "1:/lib/rover.ks").
COPYPATH("0:/cmd/resume.ks",          "1:/cmd/resume.ks").
COPYPATH("0:/cmd/setstate.ks",        "1:/cmd/setstate.ks").
COPYPATH("0:/cmd/dump.ks",            "1:/cmd/dump.ks").
COPYPATH("0:/cmd/resetboot.ks",       "1:/cmd/resetboot.ks").
COPYPATH("0:/cmd/files.ks",           "1:/cmd/files.ks").
COPYPATH("0:/cmd/science.ks",         "1:/cmd/science.ks").
COPYPATH("0:/cmd/sciencestatus.ks",   "1:/cmd/sciencestatus.ks").
COPYPATH("0:/cmd/scanstart.ks",       "1:/cmd/scanstart.ks").
COPYPATH("0:/cmd/scanstatus.ks",      "1:/cmd/scanstatus.ks").
COPYPATH("0:/cmd/scantransmit.ks",    "1:/cmd/scantransmit.ks").
COPYPATH("0:/" + vehicleName + ".ks", "1:/" + vehicleName + ".ks").
PRINT "Sync complete.".

// ── Load libs ──────────────────────────────────────────────
RUNPATH("1:/lib/state.ks").
stateInit().
RUNPATH("1:/lib/logs.ks").
initLog().
RUNPATH("1:/lib/countdown.ks").
RUNPATH("1:/lib/maneuver.ks").
RUNPATH("1:/lib/inclination.ks").
RUNPATH("1:/lib/science.ks").
RUNPATH("1:/lib/relay_constellation.ks").
RUNPATH("1:/lib/orbit.ks").
RUNPATH("1:/lib/files.ks").
RUNPATH("1:/lib/landing.ks").

// ── Init state on first boot ───────────────────────────────
LOCAL bootCount IS stateGetNum("boot_count", 0) + 1.
stateSetNum("boot_count", bootCount).
IF bootCount = 1 {
    stateSet("vehicle",  vehicleName).
    stateSet("target",   targetName).
    stateSet("payloads", payloadTypes:JOIN(",")).
}
mLog("=== BOOT #" + bootCount + " === " + SHIP:NAME + " ===").

// ── Manual override window ─────────────────────────────────
PRINT " ".
PRINT "Press ENTER within 5s for manual mode...".
LOCAL overrideStart IS TIME:SECONDS.
LOCAL manualMode IS FALSE.
WAIT UNTIL TIME:SECONDS > overrideStart + 5 OR TERMINAL:INPUT:HASCHAR.
IF TERMINAL:INPUT:HASCHAR {
    LOCAL ch IS TERMINAL:INPUT:GETCHAR().
    IF ch = "#13" OR ch = "#10" {
        SET manualMode TO TRUE.
    }
}

IF manualMode {
    PRINT "Manual mode — type RUNPATH('1:/cmd/resume.ks'). to continue.".
    mLog("Manual override at boot.").
    UNLOCK ALL.
    SET SAS TO TRUE.
    // Drop to terminal — operator takes over
} ELSE {
    PRINT "Auto-resuming...".
    RUNPATH("1:/lib/resume.ks").
} 
