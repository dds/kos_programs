// Manual docking rehearsal endpoints; not loaded by RDV/MATCH bands.
@LAZYGLOBAL OFF.

// A tagged docking port takes precedence. An ambiguous/mistagged endpoint
// fails; it must never silently turn a requested port into a bow fallback.
// Bounds are a conservative envelope, NOT a collider/contact measurement.
GLOBAL FUNCTION rendezvousEndpoint {
    PARAMETER ves, portTag IS "docking_port".
    IF ves:ISDEAD OR NOT ves:LOADED OR NOT ves:UNPACKED {
        RETURN LEX("OK",FALSE,"REASON","vessel-not-unpacked").
    }
    LOCAL tagged IS ves:PARTSTAGGED(portTag).
    IF tagged:LENGTH > 1 { RETURN LEX("OK",FALSE,"REASON","ambiguous-port-tag"). }
    IF tagged:LENGTH = 1 {
        LOCAL part_ IS tagged[0].
        IF NOT part_:ISTYPE("DockingPort") { RETURN LEX("OK",FALSE,"REASON","tag-is-not-a-port"). }
        RETURN LEX("OK",TRUE,"KIND","PORT","POINT",part_:NODEPOSITION,
            "AXIS",part_:PORTFACING:FOREVECTOR,"PART",part_,"REASON","ok").
    }
    LOCAL axis_ IS ves:FACING:FOREVECTOR.
    LOCAL corner IS ves:BOUNDS:FURTHESTCORNER(axis_).
    LOCAL reach IS MAX(0,VDOT(corner-ves:POSITION,axis_)).
    RETURN LEX("OK",TRUE,"KIND","BOW","POINT",ves:POSITION+axis_*reach,
        "AXIS",axis_,"REASON","bounds-envelope").
}

GLOBAL FUNCTION rendezvousEndpointGap {
    PARAMETER ownEnd, peerEnd.
    LOCAL offset_ IS peerEnd["POINT"]-ownEnd["POINT"].
    LOCAL along_ IS VDOT(offset_,ownEnd["AXIS"]).
    RETURN LEX("GAP",along_,"SIDE",(offset_-ownEnd["AXIS"]*along_):MAG,
        "ANGLE",VANG(ownEnd["AXIS"],-peerEnd["AXIS"]),"DIST",offset_:MAG).
}

GLOBAL FUNCTION rendezvousDocked {
    PARAMETER ownEnd, peerEnd.
    IF ownEnd["KIND"] <> "PORT" OR peerEnd["KIND"] <> "PORT" { RETURN FALSE. }
    LOCAL port_ IS ownEnd["PART"]. LOCAL peer_ IS peerEnd["PART"].
    RETURN port_:HASPARTNER AND peer_:HASPARTNER AND port_:PARTNER = peer_ AND peer_:PARTNER = port_.
}
