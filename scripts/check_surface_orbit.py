"""Generic landed orbit selection and fresh-boot review; no real flight or disk."""
import re
from types import SimpleNamespace as NS

import check_hop_selection as selection
from check_codebase import ROOT, function_body, dependency_tables, closure, command_entrypoint_errors
from check_surface_return import defaults, read_settings, emit_profile
from check_minmus_kolniya import execute

SOURCE=(ROOT/'cmd/surfaceorbit.ks').read_text()


def fixture(active=True):
    env,state,updates,events,alarms=selection.fixture()
    if active:
        assert env['hopRoutePrepare']()
        state.update(hop_route_index=3,phase='HOP_AUTO_REVIEW')
    env.update(apoapsis=659734,periapsis=554472,inclination=0,argumentOfPe=.4,longitudeOfAN=-1,
               surface_orbit_defined=lambda:'SURFACE_RETURN_ORBIT' in env)
    env['SHIP'].BODY.SOIRADIUS=2247428
    class Orbit(selection.route.Lex):
        KEYS=property(lambda self:list(self.keys()))
    env['SURFACE_RETURN_ORBIT']=Orbit(env['SURFACE_RETURN_ORBIT'])
    env['_hopRestoreSavedLimits']=lambda:events.append('limits-restored')
    updates.clear();events.clear()
    return env,state,updates,events,alarms


def command(env):
    code=function_body(SOURCE,'_cmdSurfaceorbit')
    code=code.replace('DEFINED SURFACE_RETURN_ORBIT','surface_orbit_defined()')
    try:selection.hop.ks.run(selection.hop.without_prints(selection.hop.ks.parse(code)),env)
    except selection.hop.ks.Returned:pass


def check_selection_and_review():
    for active,position in ((True,(-3.029,2.189)),(True,(20,40)),(False,(-15,170))):
        env,state,updates,events,alarms=fixture(active)
        env['SHIP'].LATITUDE,env['SHIP'].LONGITUDE=position
        original=env['SURFACE_RETURN_ORBIT'].copy()
        command(env)
        assert state['phase']=='SURFACE_RETURN_SETUP' and not state.get('hop_route_active',False)
        assert state['mission_id']=='minmus_polar_hops_return'
        assert updates['SURFACE_RETURN_SEQUENCE']==['PRELAUNCH','LAUNCH','PARK','SHAPE','SCIENCE_OPS','RETURN_SETUP']
        assert updates['SURFACE_RETURN_REVIEW']==1 and updates['SURFACE_RETURN_INCLINATION']==0
        orbit=updates['SURFACE_RETURN_ORBIT']
        assert [orbit[key] for key in ('AP','PE','INC','AOP','LAN')]==[659734,554472,0,.4,-1]
        assert orbit['RESERVE_DV']==original['RESERVE_DV'] and orbit['TOTAL_DV_CAP']==original['TOTAL_DV_CAP']
        assert not any(item=='reboot' for item in events) and not alarms
        assert 'limits-restored' in events
        cfg=dict(env);cfg.update(updates,BODY_NAME='MINMUS',PARKING_ALT=10000,
                                 LAUNCH_INCLINATION=0,LAUNCH_AZIMUTH=90)
        fresh=read_settings(emit_profile('phaseSurfaceReturnSetup',cfg),defaults())
        assert fresh['SCIENCE_OPS_HOLD']==1 and fresh['SCIENCE_OPS_RUN_ALL']==0
        assert fresh['SEQUENCE']==updates['SURFACE_RETURN_SEQUENCE']
        assert [fresh['SHAPE_'+key] for key in ('AP','PE','INC','AOP')]==[659734,554472,0,.4]
        assert fresh['RETURN_PE']==53000 and fresh['RETURN_DESCENT_DECOUPLER_TAG']=='return_decoupler'
        review=[]
        def unexpected_science():
            raise AssertionError('orbital review must not reset/deploy/transmit stored science')
        phase=function_body((ROOT/'lib/science.ks').read_text(),'phaseScienceOps')
        execute(phase,dict(fresh,fixture_unlock=lambda:None,fixture_lock=lambda *_:None,
            fixture_wait=lambda delay:review.append(('wait',delay)),orbitSummary=lambda:None,
            scienceStatus=lambda:None,scienceRunAll=unexpected_science,SCIENCE_SURVEY_POINTS=[],
            SHIP=NS(BODY=NS(NAME='Minmus'),STATUS='ORBITING',PERIAPSIS=554472,
                    APOAPSIS=659734,DELTAV=NS(VACUUM=400)),
            stateGet=lambda *_:'SCIENCE_OPS',xferSeq=selection.route.hop.Items(fresh['SEQUENCE']),
            yieldToPrompt=lambda:review.append('held'),nextPhase=lambda *_:review.append('departed')))
        assert review==[('wait',10),'held'],review
    assert not command_entrypoint_errors(SOURCE)
    assert not re.search(r'\b(?:REBOOT|STAGE|LOCK|ACTIVATE|executeManeuver)\b',re.sub(r'//[^\n]*|"[^"\n]*"','',SOURCE))
    print('PASS: actual Delta/other-site/non-route selection preserves the original mission/return hardware and orbit budgets, finishes hops, stages a reboot only, and generates the exact equatorial ellipse plus manual review')


def check_rejections_and_caching():
    for fault in ('abort','node','airborne','body','atmosphere','motion','thrust','pilot','raw',
                  'ap','pe','soi','inc','aop','lan','identity','profile','roles','route-body','restore'):
        env,state,updates,events,alarms=fixture()
        if fault=='abort':env['ABORT']=True
        if fault=='node':env['HASNODE']=True
        if fault=='airborne':env['SHIP'].STATUS='SUB_ORBITAL'
        if fault=='body':env['SHIP'].BODY.NAME='Kerbin'
        if fault=='atmosphere':env['SHIP'].BODY.ATM.EXISTS=True
        if fault=='motion':env['SHIP'].VELOCITY.SURFACE.MAG=1
        if fault=='thrust':env['SHIP'].THRUST=1
        if fault=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.1
        if fault=='raw':env['SHIP'].CONTROL.MAINTHROTTLE=.1
        if fault=='ap':env['apoapsis']=10000
        if fault=='pe':env['periapsis']=9999
        if fault=='soi':env['apoapsis']=3e6
        if fault=='inc':env['inclination']=181
        if fault=='aop':env['argumentOfPe']=360
        if fault=='lan':env['longitudeOfAN']=float('nan')
        if fault=='identity':state['mission_id']=''
        if fault=='profile':env['bootApplyMissionConfig']=lambda *_:False
        if fault=='roles':env['vesselLandingPrepareRoles']=lambda:False
        if fault=='route-body':state['hop_route_body']='Mun'
        if fault=='restore':state['hop_route_restore']=selection.route.Lex()
        before=state.copy()
        command(env)
        assert state==before and not updates,(fault,state,updates)
    source=(ROOT/'lib/mission_type.ks').read_text()
    code=function_body(source,'missionTypeConditionalRoots')
    deps,_,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    for following in ('RETURN_SETUP','SURFACE_RETURN_SETUP'):
        env=dict(bandKey='PAYLOAD_OPS',SEQUENCE=NS(CONTAINS=lambda value:value==following),
                 LIST=lambda *xs:selection.route.hop.Items(xs),missionHasPayload=lambda _:False)
        try:selection.hop.ks.run(selection.hop.ks.parse(code),env)
        except selection.hop.ks.Returned as returned:roots=returned.value
        assert 'return_setup' in roots and 'aerobrake_config' in closure(roots,deps)
        assert 'hop_control' not in closure(roots,deps) and 'landing_brake' not in closure(roots,deps)
    review=[]
    execute(function_body((ROOT/'lib/return_setup.ks').read_text(),'phaseSurfaceReturnSetup'),
        dict(BODY=NS(NAME='Minmus'),SHIP=NS(STATUS='LANDED'),
            SURFACE_RETURN_ORBIT=selection.route.Lex(AP=659734),SURFACE_RETURN_REVIEW=1,
            SURFACE_RETURN_SEQUENCE=selection.route.hop.Items(['PRELAUNCH','LAUNCH','PARK','SHAPE','RETURN_SETUP']),
            yieldToPrompt=lambda:review.append('held')))
    assert review==['held']
    print('PASS: invalid/unsafe orbit and surface state leave the route/phase/overrides untouched; orbital-review band retains the return provider and entry policy')


if __name__=='__main__':
    check_selection_and_review()
    check_rejections_and_caching()
