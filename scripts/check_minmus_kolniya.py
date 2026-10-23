"""Specified two-orbit Minmus mission across fresh profile boots, not KSP."""
import re
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_codebase import ROOT, function_body, dependency_tables, closure
from check_runtime_contracts import KList
from check_surface_return import defaults, read_settings, emit_profile, emit_surface_orbit

PROFILE=(ROOT/'missions/RO9/minmus_kolniya_flats_return.ks').read_text()


def configuration():return read_settings(PROFILE,defaults())


def executable(source):
    source=re.sub(r'UNLOCK (?:THROTTLE|STEERING)\.', 'fixture_unlock().',source)
    def strip(nodes):
        return [(text,strip(yes),strip(no)) for text,yes,no in nodes if not text.startswith('PRINT ')]
    return strip(ks.parse(source))


def execute(source,env):
    try:ks.run(executable(source),env)
    except ks.Returned as result:return result.value


def check_requested_orbits_across_boots():
    initial=configuration()
    assert initial['CAPTURE_PE']==initial['TARGET_PE']==9300
    assert initial['CAPTURE_INC']==63.4 and initial['CAPTURE_LAN']==-1
    assert initial['TARGET_AP']==397272 and initial['BPLANE_REQUIRE_PLANE']==1
    assert [initial['SHAPE_'+key] for key in ('AP','PE','INC','LAN','AOP')]==[397272,9300,63.4,79.2,90]
    assert initial['SEQUENCE'][10:]==['CAPTURE','SHAPE','SCIENCE_OPS','LAND_DEORBIT','LAND_ASSIST','SURFACE_RETURN_SETUP']
    assert len(initial['SEQUENCE'])==len(set(initial['SEQUENCE']))
    # Execute the real optional serializer; no original globals are carried
    # into the ascent or home boots except its generated SET statements.
    initial.update(BODY_NAME='MINMUS',PARKING_ALT=initial['SURFACE_RETURN_PARKING_ALT'],
                   LAUNCH_INCLINATION=initial['SURFACE_RETURN_INCLINATION'],LAUNCH_AZIMUTH=90)
    surface=read_settings(emit_profile('phaseSurfaceReturnSetup',initial),defaults())
    assert surface['SEQUENCE']==['PRELAUNCH','LAUNCH','PARK','SHAPE','RETURN_SETUP']
    assert surface['PARKING_ALT']==10000 and surface['LAUNCH_INCLINATION']==0
    assert [surface['SHAPE_'+key] for key in ('AP','PE','INC','LAN','AOP')]==[659734,554472,0,-1,.4]
    assert surface['SHAPE_RESERVE_DV']==300 and surface['SHAPE_TOTAL_DV_CAP']==250
    assert surface['SHAPE_ALT_TOL']==500 and surface['SHAPE_ANG_TOL']==.1
    surface['targetPe']=surface['RETURN_PE']
    home=read_settings(emit_profile('phaseReturnSetup',surface),{})
    assert home['SEQUENCE']==['ESCAPE','COAST','MCC','AEROBRAKE','DESCENT','DONE']
    assert all(home[key]==52000 for key in ('ESCAPE_PE','CAPTURE_PE','REENTRY_PE','AEROBRAKE_PE'))
    assert home['MCC_AEROBRAKE_SAFE_PE_MIN']==home['AEROBRAKE_BRAKE_PE_FLOOR']==51000
    assert home['MCC_AEROBRAKE_SAFE_PE_MAX']==53000 and home['CAPTURE_INC']==-1
    assert home['ESCAPE_KSC_TARGET']==home['AEROBRAKE_TARGETING']==0
    assert home['DESCENT_DECOUPLER_TAG']=='descent_decoupler' and home['AEROBRAKE_ARM_CHUTES']==1
    assert not emit_surface_orbit(defaults()) # All existing missions stay unchanged.
    assert all('SHAPE_' in line for line in emit_surface_orbit(initial))
    for ap,pe in ((397272,9300),(659734,554472)):
        assert (ap-pe)/(ap+pe+120000)>.004 # Neither requested AoP is discarded as circular.
    print('PASS: exact Kolniya targets precede landing; fresh surface/ascent boot replaces them with the high equatorial orbit, then preserves52km Kerbin entry and hardware through the home boot')


def check_manual_release_and_waypoint_required():
    cfg=configuration();events=[]
    science=function_body((ROOT/'lib/science.ks').read_text(),'phaseScienceOps')
    env=dict(cfg,fixture_unlock=lambda:None,fixture_lock=lambda *_:None,
             fixture_wait=lambda seconds:events.append(('wait',seconds)),orbitSummary=lambda:None,
             scienceStatus=lambda:None,scienceRunAll=lambda:0,
             SHIP=NS(BODY=NS(NAME='Minmus'),STATUS='ORBITING',PERIAPSIS=9300,APOAPSIS=397272,DELTAV=NS(VACUUM=1500)),
             stateGet=lambda key,default='':'SCIENCE_OPS',xferSeq=KList(cfg['SEQUENCE']),
             yieldToPrompt=lambda:events.append(('hold',)),nextPhase=lambda *_:events.append(('advance',)))
    execute(science,env)
    assert events==[('wait',10),('hold',)]
    assert '0:/cmd/setphase.ks' in science
    landing=(ROOT/'lib/landing_config.ks').read_text()
    resolver=function_body(landing,'landingResolveTarget')
    env=dict(cfg,waypointNamed=lambda *_:0,selectedWaypoint=lambda:0)
    assert not execute(resolver,env)['FOUND']
    env['selectedWaypoint']=lambda:NS(NAME='Flats',GEOPOSITION=NS(LAT=0,LNG=0))
    resolved=execute(resolver,env)
    assert resolved['FOUND'] and resolved['LAT']==resolved['LNG']==0 and resolved['SOURCE']=='selected waypoint:Flats'
    events=[]
    env.update(landingResolveTarget=lambda:dict(FOUND=False),_autoLandingTarget=lambda:False,
               landingLightActive=lambda:False,yieldToPrompt=lambda:events.append('hold'))
    confirm=function_body((ROOT/'lib/landing_deorbit.ks').read_text(),'_confirmLandingTarget')
    assert execute(confirm,env) is False and events==['hold']
    assert cfg['LANDING_AUTO_TARGET']==cfg['LANDING_FLEXIBLE_SITE']==0
    assert cfg['LANDING_POWERED_LEAD']==cfg['LANDING_ECONOMY_BRAKE']==cfg['LANDING_STAGE_BRAKE_CREDIT']==1
    assert cfg['LANDING_SITE_SCAN_ENABLE']==cfg['LANDING_REQUIRE_SITE']==0
    print('PASS: completed first orbit holds until explicit phase release; selected Flats waypoint including0,0 resolves, missing selection holds without automatic site substitution or SCANsat requirement')


def check_surface_shaping_cache_and_gate():
    deps,phases,bands=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    for phase in configuration()['SURFACE_RETURN_SEQUENCE']:
        assert phase.lower() in phases and closure(phases[phase.lower()],deps)
    conditional=function_body((ROOT/'lib/mission_type.ks').read_text(),'missionTypeConditionalRoots')
    class Sequence(KList):
        CONTAINS=list.__contains__
    for band in ('PRELAUNCH','LAUNCH','SHAPE'):
        extra=execute(conditional,dict(bandKey=band,SEQUENCE=Sequence(configuration()['SURFACE_RETURN_SEQUENCE']),LIST=lambda *xs:KList(xs)))
        assert 'return_setup' in extra
        assert 'aerobrake_config' in closure(extra,deps)
    setup=function_body((ROOT/'lib/return_setup.ks').read_text(),'phaseSurfaceReturnSetup')
    assert setup.index('SURFACE_RETURN_ORBIT:LENGTH')<setup.index('stateSet("mission_id"')
    class Orbit(dict):
        LENGTH=property(len)
    events=[]
    execute(setup,dict(BODY=NS(NAME='Minmus'),SHIP=NS(STATUS='LANDED'),
            SURFACE_RETURN_ORBIT=Orbit(AP=659734),SURFACE_RETURN_SEQUENCE=Sequence(['PRELAUNCH','LAUNCH','PARK','RETURN_SETUP']),
            yieldToPrompt=lambda:events.append('hold')))
    assert events==['hold']
    print('PASS: generated ascent uses real phase bindings and keeps return_setup through prelaunch/launch/shaping cleanup; specifying post-ascent elements without SHAPE holds before changing mission identity')


if __name__=='__main__':
    check_requested_orbits_across_boots()
    check_manual_release_and_waypoint_required()
    check_surface_shaping_cache_and_gate()
