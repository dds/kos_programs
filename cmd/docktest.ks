// Zero-throttle endpoint alignment rehearsal. No translation or docking claim.
@LAZYGLOBAL OFF.
PARAMETER action IS "check", targetName IS "", portTag IS "docking_port".

LOCAL FUNCTION _cmdDocktest {
    IF NOT LIST("check","hold","align"):CONTAINS(action)
            OR NOT targetName:ISTYPE("String") OR NOT portTag:ISTYPE("String") OR portTag = "" {
        PRINT "Use check/hold/align, peer vessel name (or selected target), port tag (default docking_port).". RETURN.
    }
    IF NOT HOMECONNECTION:ISCONNECTED { PRINT "Docking rehearsal requires an archive link.". RETURN. }
    RUNPATH("1:/lib/boot_lib"). bootPreamble(). bootLibLoad("thrust_cutoff").
    RUNPATH("0:/lib/rendezvous_geometry.ks").
    RUNPATH("0:/lib/docking_geometry.ks").
    RUNONCEPATH("0:/lib/diagnostic_log.ks").
    LOCAL other IS rendezvousTarget(targetName). LOCAL craftRef IS SHIP.
    IF other = 0 { PRINT "Select one uniquely named peer vessel.". RETURN. }
    IF NOT LIST("DONE","SCIENCE_OPS","SCANSAT_OPS","RDV","MATCH"):CONTAINS(stateGet("phase",""))
            OR NOT rendezvousContext(craftRef,other)
            OR (other:POSITION-SHIP:POSITION):MAG > 2000
            OR (SHIP:VELOCITY:ORBIT-other:VELOCITY:ORBIT):MAG > 0.2 {
        PRINT "First match velocities: idle review prompt, same orbit/body, within2km, relative speed<=0.2m/s, no node/interruption, Abort clear.". RETURN.
    }
    LOCAL ownEnd IS rendezvousEndpoint(SHIP,portTag).
    LOCAL peerEnd IS rendezvousEndpoint(other,portTag).
    IF NOT ownEnd["OK"] OR NOT peerEnd["OK"] { PRINT "Endpoint unavailable: "+ownEnd+" / "+peerEnd. RETURN. }
    LOCAL report IS diagnosticArchiveOpen("docktest").
    IF NOT report["READY"] { RETURN. }
    diagnosticArchiveLine(report,"STATS docktest setup action="+action+" own="+SHIP:NAME+" peer="+other:NAME
        +" ownEndpoint="+ownEnd["KIND"]+" peerEndpoint="+peerEnd["KIND"]+" portTag="+portTag).
    IF ownEnd["KIND"] = "BOW" OR peerEnd["KIND"] = "BOW" {
        PRINT "Bow fallback uses a bounds envelope; its gap cannot verify physical contact.".
    } ELSE IF ownEnd["PART"]:NODETYPE <> peerEnd["PART"]:NODETYPE {
        PRINT "Port types differ; alignment only, these ports cannot dock.".
    }
    LOCAL beginUt IS TIME:SECONDS. LOCAL endUt IS beginUt+90.
    IF action = "hold" { SET endUt TO beginUt+600. }
    LOCAL alarm IS "".
    LOCAL priorRcs IS RCS.
    IF action <> "check" {
        IF NOT thrustCutoffOk(FALSE) { RETURN. }
        SET alarm TO kacEnsureAlarm("Docking rehearsal hold ends",endUt,"Resident zero-throttle hold expires at1x.",1).
        SAS OFF. RCS OFF.
    }
    // Capture the full source attitude once. Reading SHIP:FACING inside the
    // steering lock would drag the goal around as the vessel rotates.
    LOCAL initialFacing IS SHIP:FACING. LOCAL initialAxis IS ownEnd["AXIS"].
    LOCAL wanted IS SHIP:FACING. LOCAL settledSince IS -1.
    LOCAL nextRow IS 0. LOCAL outcome IS "timeout".
    UNTIL TIME:SECONDS >= endUt {
        IF NOT rendezvousContext(craftRef,other,FALSE,action = "hold") {
            SET outcome TO "context-changed". BREAK.
        }
        SET ownEnd TO rendezvousEndpoint(SHIP,portTag). SET peerEnd TO rendezvousEndpoint(other,portTag).
        IF NOT ownEnd["OK"] OR NOT peerEnd["OK"] { SET outcome TO "endpoint-lost". BREAK. }
        LOCAL gap IS rendezvousEndpointGap(ownEnd,peerEnd).
        LOCAL relativeSpeed IS (SHIP:VELOCITY:ORBIT-other:VELOCITY:ORBIT):MAG.
        LOCAL sep IS (other:POSITION-SHIP:POSITION):MAG.
        IF sep < 50 OR sep > 2000 OR relativeSpeed > 0.2 OR other:THRUST > 0.001 {
            SET outcome TO "stand-off-or-peer-motion". BREAK.
        }
        LOCAL line_ IS peerEnd["POINT"]-ownEnd["POINT"].
        IF line_:MAG < 1 { SET outcome TO "too-close". BREAK. }
        SET wanted TO ROTATEFROMTO(initialAxis,line_:NORMALIZED)*initialFacing.
        LOCAL error_ IS VANG(ownEnd["AXIS"],line_).
        LOCAL ownRate IS SHIP:ANGULARVEL:MAG*CONSTANT:RADTODEG.
        LOCAL peerRate IS other:ANGULARVEL:MAG*CONSTANT:RADTODEG.
        IF TIME:SECONDS >= nextRow OR action = "check" {
            diagnosticArchiveLine(report,"STATS docktest sample ut="+TIME:SECONDS+" sep="+sep
                +" gap="+gap["GAP"]+" lateral="+gap["SIDE"]+" facing="+error_+" opposed="+gap["ANGLE"]
                +" ownRate="+ownRate+" peerRate="+peerRate+" relV="+relativeSpeed
                +" docked="+rendezvousDocked(ownEnd,peerEnd)).
            SET nextRow TO TIME:SECONDS+5.
        }
        IF action = "check" { SET outcome TO "snapshot". BREAK. }
        LOCK STEERING TO wanted.
        IF error_ <= 2 AND ownRate <= 0.1 AND peerRate <= 0.1 AND gap["ANGLE"] <= 2 {
            IF settledSince < 0 { SET settledSince TO TIME:SECONDS. }
            IF action = "align" AND TIME:SECONDS-settledSince >= 1 {
                SET outcome TO "aligned-at-stand-off". BREAK.
            }
        } ELSE { SET settledSince TO -1. }
        WAIT 0.1.
    }
    IF action <> "check" {
        // Keep only the acquired fixed attitude under SAS when returning to
        // the prompt. The target's hold loop remains resident until expiry.
        thrustCutoffOk(). UNLOCK STEERING. SAS ON. SET RCS TO priorRcs.
        IF alarm <> "" { DELETEALARM(alarm). }
    }
    diagnosticArchiveLine(report,"STATS docktest result="+outcome+" ut="+TIME:SECONDS).
    diagnosticArchiveClose(report,"Docking rehearsal").
    PRINT "Alignment rehearsal ended. No translation, contact push or deorbit was commanded.".
}

_cmdDocktest().
