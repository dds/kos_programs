"""Programmed site stops/progress/fresh return profiles; no native KSP VM."""
import json
import math
from types import SimpleNamespace as NS

import check_hop_route as hop
from check_codebase import ROOT, function_body, dependency_tables, closure
from check_surface_return import defaults, read_settings, emit_profile

PROFILE = (ROOT/'missions/RO9/minmus_polar_hops_return.ks').read_text()
ROUTE = (ROOT/'lib/hop_route.ks').read_text()
hop.HOP += '\n'+ROUTE
hop.ks.SOURCES += '\n'+ROUTE


class Lex(hop.Lex):
    HASKEY = dict.__contains__
    COPY = property(lambda self: Lex(self))


def native(value):
    if isinstance(value, list): return hop.Items(native(v) for v in value)
    if isinstance(value, dict): return Lex({k:native(v) for k,v in value.items()})
    return value


def configuration():
    return read_settings(PROFILE, defaults())


def distance(a,b,c,d):
    a,b,c,d = map(math.radians,(a,b,c,d))
    return 120000*math.asin(min(1,math.sqrt(math.sin((a-c)/2)**2+math.cos(a)*math.cos(c)*math.sin((b-d)/2)**2)))


def fixture():
    env,state,updates,events,_ = hop.fixture()
    env.update(native(configuration()))
    env.update(geoDistance=distance,LEXICON=lambda *xs:Lex(zip(xs[::2],xs[1::2])),
               configLiteral=lambda value:json.dumps(value,sort_keys=True),phaseShouldYield=False,
               HOP_TARGET_LAT=0,HOP_TARGET_LNG=0)
    env.update(getTarget=lambda:'Minmus',hopChooseSite=lambda default:default)
    state.update(phase='HOP_ROUTE_SETUP',hop_route_active=False,mission_id='minmus_polar_hops_return')
    state.pop('hop_route_restore')
    env['SHIP'].LATITUDE,env['SHIP'].LONGITUDE = env['HOP_ROUTE_SITES'][0]
    env['SHIP'].THRUST=0
    env['SHIP'].CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0)
    env['ADDONS']=NS(KAC=NS(AVAILABLE=True))
    alarms={};serial=[0]
    def alarm(name,ut,note,tolerance=60):
        if not env['ADDONS'].KAC.AVAILABLE:return ''
        assert ut>env['TIME'].SECONDS
        for key,old in alarms.items():
            if old==ut:return key
        serial[0]+=1;key='alarm-'+str(serial[0]);alarms[key]=ut
        events.append(('alarm',ut));return key
    env.update(kacEnsureAlarm=alarm,DELETEALARM=lambda key:alarms.pop(key,None),
               scienceRunAll=lambda:events.append(('science',env['TIME'].SECONDS)) or 1)
    for name in ('hopRoutePrepare','phaseHopRouteSetup','phaseHopAutoReview','_hopPrepLandingAssist','_hopApplyPending'):
        env[name]=lambda *args,name=name:hop.execute(name,env,*args)
    # This pure predicate runs every simulated second. Reuse the fixture's
    # compiled source body instead of reparsing it thousands of times.
    env['_hopDwellSafe']=lambda index:hop.ks.call('_hopDwellSafe',env,index)
    env['bootLibBandForPhase']=lambda phase:'HOP_ROUTE' if phase=='HOP_AUTO_REVIEW' else ('HOP' if phase=='HOP' else 'RETURN_SETUP')
    return env,state,updates,events,alarms


def rebooting(fn):
    try:fn()
    except hop.Reboot:return
    raise AssertionError('expected saved reboot handoff')


def arm(env,state,updates):
    rebooting(env['phaseHopRouteSetup'])
    env.update(updates)
    assert state['phase']=='HOP_AUTO_REVIEW' and state['hop_route_index']==0


def check_profile_and_return():
    cfg=configuration()
    assert [cfg['SHAPE_'+k] for k in ('AP','PE','INC','LAN','AOP')]==[1064182,444576,90,298.9,244.9]
    assert cfg['CAPTURE_PE']==cfg['TARGET_PE']==444576 and cfg['TARGET_AP']==1064182
    assert cfg['LAND_PREP_AP']==19300 and cfg['LAND_PREP_PE']==9300
    assert cfg['LAND_PREP_MIN_BURN_DV']==.1
    assert cfg['SEQUENCE'][-5:]==['LAND_PREP','LAND_DEORBIT','LAND_ASSIST','HOP_ROUTE_SETUP','SURFACE_RETURN_SETUP']
    assert len(cfg['SEQUENCE'])==len(set(cfg['SEQUENCE']))
    sites=[[-1.080,1.365],[-1.190,1.596],[-1.554,2.780],[-3.029,2.189]]
    assert cfg['HOP_ROUTE_SITES']==sites
    assert [cfg['TARGET_LAT'],cfg['TARGET_LNG']]==sites[0]
    ranges=[distance(*a,*b) for a,b in zip(sites,sites[1:])]
    assert all(cfg['HOP_TOLERANCE']<r<15000 for r in ranges)
    assert 260<ranges[0]<275 and cfg['HOP_TOLERANCE']==50
    assert cfg['TERRAIN_CHECK_RADIUS']==20 and cfg['HOP_SITE_RADIUS']==100
    assert cfg['HOP_SITE_DWELL_SECONDS']==600 and cfg['HOP_SITE_RUN_SCIENCE']==1 and cfg['AUTO_TRANSMIT']==0
    cfg.update(BODY_NAME='MINMUS',PARKING_ALT=cfg['SURFACE_RETURN_PARKING_ALT'],
               LAUNCH_INCLINATION=cfg['SURFACE_RETURN_INCLINATION'],LAUNCH_AZIMUTH=90)
    surface=read_settings(emit_profile('phaseSurfaceReturnSetup',cfg),defaults())
    assert surface['SEQUENCE']==['PRELAUNCH','LAUNCH','PARK','SHAPE','RETURN_SETUP']
    assert [surface['SHAPE_'+k] for k in ('AP','PE','INC','LAN','AOP')]==[659734,554472,0,-1,.4]
    assert surface['SHAPE_ALT_TOL']==100 and surface['SHAPE_RESERVE_DV']==300
    surface['targetPe']=surface['RETURN_PE']
    home=read_settings(emit_profile('phaseReturnSetup',surface),{})
    assert all(home[k]==53000 for k in ('ESCAPE_PE','CAPTURE_PE','REENTRY_PE','AEROBRAKE_PE'))
    assert home['AEROBRAKE_TARGETING']==0 and home['DESCENT_DECOUPLER_TAG']=='return_decoupler'
    # Actual common serializer persists assist policy across both generated legs.
    policy=function_body((ROOT/'lib/return_setup.ks').read_text(),'_writeCoastAutomation')
    assert 'configLiteral(AEROBRAKE_AP_BURN)' in policy and 'configLiteral(AEROBRAKE_AP_RESERVE_DV)' in policy
    assert cfg['AEROBRAKE_AP_BURN']==1 and cfg['AEROBRAKE_AP_RESERVE_DV']==10
    print('PASS: exact polar/landing/A-B-C-D/equatorial goals and53km assisted return persist through fresh generated return profiles;270m first hop cannot be skipped by the50m threshold')


def check_four_stops_three_hops():
    env,state,updates,events,alarms=fixture()
    original=list(env['SEQUENCE'])
    arm(env,state,updates)
    assert state['hop_route_restore']['SEQUENCE']==original
    for index,site in enumerate(env['HOP_ROUTE_SITES']):
        env['SHIP'].LATITUDE,env['SHIP'].LONGITUDE=site
        state.update(phase='HOP_AUTO_REVIEW',hop_route_index=index)
        before=env['TIME'].SECONDS
        rebooting(env['phaseHopAutoReview'])
        assert env['TIME'].SECONDS>=before+602 and not alarms
        if index<3:
            assert state['phase']=='HOP' and state['hop_route_pending']==index+1
            assert [updates['HOP_TARGET_LAT'],updates['HOP_TARGET_LNG']]==env['HOP_ROUTE_SITES'][index+1]
            env['_hopApplyPending']()
            env['HOP_TARGET_LAT'],env['HOP_TARGET_LNG']=env['HOP_ROUTE_SITES'][index+1]
            env['_hopPrepLandingAssist']()
            assert updates['SEQUENCE']==['HOP','LAND_ASSIST','HOP_AUTO_REVIEW']
        else:
            assert state['phase']=='SURFACE_RETURN_SETUP' and not state['hop_route_active']
            assert not state['hop_route_automatic'] and updates['SEQUENCE']==original
    assert len([e for e in events if isinstance(e,tuple) and e[0]=='science'])==4
    timeline=[e[0] for e in events if isinstance(e,tuple) and e[0] in ('alarm','science')]
    assert timeline==['alarm','science']*4
    print('PASS: settled A gets a600s alarm/science stop, exactly three pending hop launches visit B/C/D, and the fourth stop restores the original shaped-orbit return without prompt exits')


def check_reboot_no_kac_and_faults():
    env,state,updates,events,alarms=fixture();arm(env,state,updates)
    class Interrupted(Exception):pass
    wait=env['fixture_wait']
    def interrupt(seconds):
        wait(seconds)
        if env['TIME'].SECONDS>102:raise Interrupted()
    env['fixture_wait']=interrupt
    try:env['phaseHopAutoReview']()
    except Interrupted:pass
    until=state['hop_site_dwell']['UNTIL']
    env['fixture_wait']=wait
    rebooting(env['phaseHopAutoReview'])
    assert env['TIME'].SECONDS==until and len([e for e in events if isinstance(e,tuple) and e[0]=='science'])==1
    assert not alarms
    env,state,updates,events,alarms=fixture();arm(env,state,updates)
    env['ADDONS'].KAC.AVAILABLE=False
    rebooting(env['phaseHopAutoReview'])
    assert env['TIME'].SECONDS>=602 and not alarms
    for fault in ('abort','node','airborne','body','moving','throttle','pilot','physical','miss','fuel','terrain'):
        env,state,updates,events,alarms=fixture();arm(env,state,updates)
        updates.clear()
        wait=env['fixture_wait']
        def change(seconds):
            wait(seconds)
            if env['TIME'].SECONDS>5:
                if fault=='abort':env['ABORT']=True
                elif fault=='node':env['HASNODE']=True
                elif fault=='airborne':env['SHIP'].STATUS='FLYING'
                elif fault=='body':env['SHIP'].BODY.NAME='Mun'
                elif fault=='moving':env['SHIP'].VELOCITY.SURFACE.MAG=1
                elif fault=='throttle':env['SHIP'].CONTROL.MAINTHROTTLE=.2
                elif fault=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.2
                elif fault=='physical':env['SHIP'].THRUST=1
        env['fixture_wait']=change
        if fault=='miss':env['SHIP'].LATITUDE+=1
        if fault=='fuel':env['SHIP'].DELTAV.VACUUM=600
        if fault=='terrain':env['landingTerrainGrade']=lambda *_:1
        env['phaseHopAutoReview']()
        assert events[-1]=='yield' and not updates and 'hop_route_pending' not in state,fault
        assert not alarms,fault
    print('PASS: interrupted/rebooted dwell retains its deadline and one experiment attempt; no-KAC clock wake works; Abort/nodes/body/motion/controls/site miss/fuel/terrain prevent automatic launch and clean alarms')


def check_setup_and_offline_roots():
    for fault in ('valid','already-active','bad-first','bad-coord','too-far','abort','airborne','roles'):
        env,state,updates,events,alarms=fixture()
        if fault=='already-active':state['hop_route_active']=True
        if fault=='bad-first':env['SHIP'].LATITUDE+=1
        if fault=='bad-coord':env['HOP_ROUTE_SITES'][1][0]=math.nan
        if fault=='too-far':env['HOP_ROUTE_SITES'][1][0]=50
        if fault=='abort':env['ABORT']=True
        if fault=='airborne':env['SHIP'].STATUS='FLYING'
        if fault=='roles':env['vesselLandingPrepareRoles']=lambda:False
        if fault=='valid':
            arm(env,state,updates)
            restore=state['hop_route_restore']
            # Repeat a partial setup handoff using the temporary sequence.
            state['phase']='HOP_ROUTE_SETUP'
            arm(env,state,updates)
            assert state['hop_route_restore']==restore
        else:
            env['phaseHopRouteSetup']()
            assert not updates and events[-1]=='yield',fault
    deps,phases,bands=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    assert bands['hop_route']==['hop_route_setup','hop_auto_review']
    assert 'science' in closure(phases['hop_auto_review'],deps)
    conditional=function_body((ROOT/'lib/mission_type.ks').read_text(),'missionTypeCacheRoots')
    loaded_policy=function_body((ROOT/'lib/mission_type.ks').read_text(),'missionTypeConditionalRoots')
    for seq in (configuration()['SEQUENCE'],['HOP','LAND_ASSIST','HOP_AUTO_REVIEW']):
        for band in ('LANDING','HOP','HOP_ROUTE'):
            scope=dict(bandKey=band,SEQUENCE=hop.Items(seq),LIST=lambda *xs:hop.Items(xs))
            try:hop.ks.run(hop.ks.parse(conditional),scope)
            except hop.ks.Returned as result:extra=result.value
            cached=closure(extra,deps)
            if band=='LANDING':
                assert {'hop_route','hop','science'}<=cached and 'hop_control' not in cached
                assert 'return_setup' not in cached
            elif band=='HOP':
                assert {'landing_main','landing_coast','landing_brake'}<=cached
                assert not {'science','hop_route','return_setup'} & cached
            else:
                assert {'hop_control','return_setup'}<=cached and 'landing_main' not in cached
            active_phase={'HOP':'hop','LANDING':'land_assist','HOP_ROUTE':'hop_auto_review'}[band]
            try:hop.ks.run(hop.ks.parse(loaded_policy),scope)
            except hop.ks.Returned as result:loaded_extra=result.value
            loaded=closure(['core']+phases[active_phase]+list(loaded_extra),deps)
            assert ('science' in loaded)==(band=='HOP_ROUTE')
            assert ('hop_control' in loaded)==(band=='HOP')
            assert ('landing_main' in loaded)==(band=='LANDING')
            assert 'return_setup' not in loaded
    assert 'hop_route' not in closure(phases['hop_review'],deps)
    print('PASS: guarded setup preserves restore intent; launch/landing/science providers load in separate bands and cache only their next transition; ordinary manual review does not load the timed phase')


if __name__=='__main__':
    check_profile_and_return()
    check_four_stops_three_hops()
    check_reboot_no_kac_and_faults()
    check_setup_and_offline_roots()
