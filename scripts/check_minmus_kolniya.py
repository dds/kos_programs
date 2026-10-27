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
    assert initial['SHAPE_ALT_TOL']==100 and initial['SHAPE_MIN_PE']==9000
    for profile in (initial,surface):
        assert profile['SHAPE_MIN_BURN_DV']==.002 and profile['SHAPE_BURN_TOLERANCE']==.001
    assert surface['SHAPE_MIN_PE']==10000
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


def check_coarse_arrival_strict_final_orbit():
    cfg=configuration()
    arrival=(ROOT/'lib/arrival_bplane.ks').read_text()
    current=function_body(arrival,'_bplaneCurrentCorridorOk')
    element=function_body(arrival,'_bplaneElementPlaneError')
    # The fixture supplies parameters directly, including multi-parameter
    # declarations not otherwise needed by this small source interpreter.
    current=re.sub(r'PARAMETER [^.]+\.', '',current)
    element=re.sub(r'PARAMETER [^.]+\.', '',element)
    patch=NS(PERIAPSIS=8700,INCLINATION=64.2,LAN=300)
    env=dict(cfg,targetBody=NS(NAME='Minmus'),wantPe=9300,wantInc=63.4,wantLan=-1,
             findArrivalPatch=lambda *_:dict(patch=patch))
    env['_bplaneElementPlaneError']=lambda inc,lan,want_inc,want_lan:execute(element,
        dict(inc=inc,lan=lan,wantInc=want_inc,wantLan=want_lan))
    assert cfg['BPLANE_ANG_TOL']==1 and cfg['BPLANE_REQUIRE_PLANE']==1
    assert execute(current,env)
    env['BPLANE_ANG_TOL']=.2
    assert not execute(current,env) # Reproduce the overly strict old profile.
    env['BPLANE_ANG_TOL']=cfg['BPLANE_ANG_TOL']
    for pe,inc,allowed in ((8700,62.6,True),(8300,63.4,True),(10300,63.4,True),
                           (8299,63.4,False),(10301,63.4,False),(9300,64.401,False)):
        patch.PERIAPSIS=pe;patch.INCLINATION=inc
        assert bool(execute(current,env))==allowed,(pe,inc)
    class Errors(dict):
        HASKEY=dict.__contains__
    converged=function_body((ROOT/'lib/orbit_shape.ks').read_text(),'shapeConverged')
    final=dict(cfg,targets={},shapeErrors=lambda _:Errors(AP=0,PE=0,PLANE=.8,AOP=0))
    assert not execute(converged,final)
    final['shapeErrors']=lambda _:Errors(AP=0,PE=0,PLANE=.09,AOP=0)
    assert execute(converged,final)
    assert cfg['CAPTURE_MIN_PE']==8300 and cfg['CAPTURE_MAX_PE']==10300
    assert cfg['SHAPE_ANG_TOL']==.1 and cfg['SHAPE_RESERVE_DV']==900
    assert cfg['SEQUENCE'].index('SHAPE')<cfg['SEQUENCE'].index('SCIENCE_OPS')<cfg['SEQUENCE'].index('LAND_DEORBIT')
    assert 'LOCAL MIN_EXEC_DV      IS 0.3.' in arrival
    print('PASS: reported8.7km/0.8deg arrival passes only the coarse Kolniya gate; bad Pe/>1deg still rejects, mandatory SHAPE still rejects0.8deg and needs0.1deg before science/landing;0.3m/s minimum and fuel reserves remain')


if __name__=='__main__':
    check_requested_orbits_across_boots()
    check_manual_release_and_waypoint_required()
    check_surface_shaping_cache_and_gate()
    check_coarse_arrival_strict_final_orbit()
