// Espoir: transmit flyby/atmospheric science, then attempt a Duna impact.
// Hardware/power/radio/thermal capability must be checked on the new build.
// No mandatory capture, return, RO9 staging, or powered landing assumptions.
SET MISSION_ID TO "duna_science_impact".
SET MISSION_NAME TO "Espoir — Duna Science and Impact".
SET MISSION_TYPE TO "interplanetary".
SET MISSION_CACHE_NEXT_BAND TO 1.
SET TARGET_ TO "DUNA".
SET PAYLOADS TO LIST("PROBE").
SET SEQUENCE TO LIST("PRELAUNCH","LAUNCH","FAIR","ANTS","PARK","XING","ASSIST","ASSIST_COAST","BPLANE","COAST_1HALF","REFINE_BPLANE","COAST_2HALF","SCIENCE_ENTRY","DONE").
SET PARKING_ALT TO 85000.
SET LAUNCH_INCLINATION TO 0.
SET LAUNCH_PLANE_MODE TO "".

// Deep positive atmospheric Pe retains the shared arrival solver's domain.
// This is an entry/impact attempt, not a promise of a particular impact site.
SET BPLANE_ARRIVAL_MODE TO "ENTRY".
SET CAPTURE_PE TO 5000.
SET CAPTURE_INC TO -1.
SET CAPTURE_LAN TO -1.
SET CAPTURE_AOP TO -1.
SET BPLANE_PE_ONLY TO 1.
SET BPLANE_REQUIRE_PLANE TO 0.
SET BPLANE_PE_TOL TO 3000.
SET BPLANE_DV_CAP TO 150.
SET REFINE_BPLANE_DV_CAP TO 50.
SET BPLANE_TRIM_DV_CAP TO 50.
SET BPLANE_TRIM_TOTAL_DV_CAP TO 150.
SET BPLANE_TRIM_RESERVE_DV TO 50.

// Sampling boundaries, ASL: low space / low atmosphere. These are editable
// for a modified science system; the experiment still decides availability.
SET SCIENCE_ENTRY_BANDS TO LEXICON("DUNA",LIST(140000,12000),"IKE",LIST(50000,0)).
SET SCIENCE_ENTRY_MOON TO "IKE".
SET SCIENCE_ENTRY_MOON_MIN_PE TO 20000.
SET SCIENCE_ENTRY_PREPARE_LEAD TO 180.
SET SCIENCE_ENTRY_MAX_PASSES TO 3.
SET SCIENCE_ENTRY_MIN_EC TO 0.05.
SET COAST_AUTO_WARP TO 1.

// Only an existing free Ike flyby with a proven subsequent Duna entry.
SET MISSION_ASSIST_ROUTE TO LIST(
    LEXICON("BODY","Ike","MIN_PE",20000),
    LEXICON("BODY","Duna","MODE","ENTRY","MIN_PE",2000,"MAX_PE",8000)).
SET MISSION_ASSIST_SEQUENCE TO SEQUENCE.
SET MISSION_ASSIST_SETTINGS TO LEXICON("CAPTURE_PE",5000,"BPLANE_PE_TOL",3000).
SET ASSIST_RESERVE_DV TO 50.
SET MISSION_ASSIST_SCIENCE TO 1.
