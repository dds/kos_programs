// ============================================================
// cmd/markrunway.ks  —  Capture the runway you are parked on
// (0:/cmd/markrunway.ks)
//
// Park at the runway threshold, point the nose down the
// centerline, and run this. It records name, position, field
// elevation, and both runway headings into the persistent
// approach database (0:/data/approaches.json), which
// lib/airplane.ks merges into PLANE_APPROACHES at planeInit —
// so approach briefs, the SSTO APPROACH phase, and landing
// tooling work at every field you have ever tagged.
//
// Works OFFLINE (this command is in the planes' CMD install):
// with no KSC link the entry is queued on the local volume and
// merged into the archive automatically the next time the
// command runs with a link (any airfield, any vessel).
//
// Usage (parked, aligned with the runway):
//   RUNPATH("1:/cmd/markrunway", "Atacama").
//   RUNPATH("1:/cmd/markrunway", "Kojave Sands", 3.5).   // custom glideslope
// ============================================================

PARAMETER rwName IS "".
PARAMETER gs IS 3.0.

RUNPATH("1:/lib/boot_lib").
bootPreamble().

LOCAL ARCHIVE_DB IS "0:/data/approaches.json".
LOCAL PENDING_DB IS "1:/run/approaches_pending.json".

LOCAL FUNCTION _loadDb {
    PARAMETER path_.
    IF NOT EXISTS(path_) { RETURN LEXICON(). }
    RETURN ADDONS:JSON:PARSEORELSE(OPEN(path_):READALL:STRING, LEXICON()).
}

LOCAL FUNCTION _saveDb {
    PARAMETER path_, db.
    IF EXISTS(path_) { DELETEPATH(path_). }
    LOG ADDONS:JSON:STRINGIFY(db) TO path_.
}

LOCAL err IS FALSE.
IF rwName = "" {
    PRINT "ERROR: name the runway, e.g.".
    PRINT "  RUNPATH(" + CHAR(34) + "1:/cmd/markrunway" + CHAR(34) + ", "
        + CHAR(34) + "Atacama" + CHAR(34) + ").".
    SET err TO TRUE.
}
IF SHIP:STATUS <> "LANDED" OR SHIP:GROUNDSPEED > 1 {
    PRINT "ERROR: park ON the runway first (status=" + SHIP:STATUS
        + " gspd=" + ROUND(SHIP:GROUNDSPEED, 1) + ").".
    SET err TO TRUE.
}

IF NOT err {
    LOCAL hdg1 IS ROUND(SHIP:FACING:YAW, 0).
    LOCAL hdg2 IS hdg1 + 180.
    IF hdg2 >= 360 { SET hdg2 TO hdg2 - 360. }

    LOCAL entry IS LEXICON(
        "name", rwName,
        "match", rwName:TOUPPER,
        "lat", ROUND(SHIP:LATITUDE, 4),
        "lng", ROUND(SHIP:LONGITUDE, 4),
        "elev", ROUND(SHIP:ALTITUDE, 0),
        "hdg1", hdg1,
        "hdg2", hdg2,
        "gs", gs,
        "radius", 25000
    ).

    LOCAL key IS rwName:TOUPPER:REPLACE(" ", "_").

    IF HOMECONNECTION:ISCONNECTED {
        IF NOT EXISTS("0:/data") { CREATEDIR("0:/data"). }
        LOCAL db IS _loadDb(ARCHIVE_DB).
        // Sweep in anything queued offline at earlier fields.
        LOCAL pending IS _loadDb(PENDING_DB).
        FOR pKey IN pending:KEYS {
            IF db:HASKEY(pKey) { db:REMOVE(pKey). }
            db:ADD(pKey, pending[pKey]).
        }
        IF pending:KEYS:LENGTH > 0 {
            DELETEPATH(PENDING_DB).
            PRINT "Merged " + pending:KEYS:LENGTH + " queued runway(s) from offline fields.".
        }
        IF db:HASKEY(key) { db:REMOVE(key). }
        db:ADD(key, entry).
        _saveDb(ARCHIVE_DB, db).
        PRINT "Runway saved to archive database.".
    } ELSE {
        LOCAL db IS _loadDb(PENDING_DB).
        IF db:HASKEY(key) { db:REMOVE(key). }
        db:ADD(key, entry).
        _saveDb(PENDING_DB, db).
        PRINT "NO LINK — runway queued locally; merges at next connected run.".
    }

    PRINT " ".
    PRINT "Runway: " + rwName.
    PRINT "  Position .. " + entry["lat"] + ", " + entry["lng"]
        + "  elev " + entry["elev"] + "m".
    PRINT "  Headings .. " + hdg1 + " / " + hdg2
        + "   glideslope " + gs + "deg".
    mLog("Runway marked: " + rwName + " " + entry["lat"] + ","
        + entry["lng"] + " elev=" + entry["elev"]
        + " hdgs=" + hdg1 + "/" + hdg2 + ".").
}
