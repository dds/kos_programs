"""Source-driven landing-window forecast/coast checks, not a KSP runner."""
import json
import math
import re
from types import SimpleNamespace as NS

import numpy as np

import check_landing_guidance as ks
import check_landing_light as light
import check_midcourse as mid
from check_codebase import ROOT, function_body, dependency_tables, closure
from check_runtime_contracts import run

WAIT=(ROOT/'lib/landing_light_wait.ks').read_text()
SOURCE=WAIT+'\n'+light.LIGHT+'\n'+light.DEORBIT+'\n'+mid.SOURCE
SOURCE=re.sub(r'\bPRINT\s+(?:"[^"]*"|[^."])*\.', '', SOURCE)
SOURCE=SOURCE.replace('WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.','fixture_settle().')
ks.SOURCES=SOURCE+'\n'+ks.SOURCES


class Lex(dict):
    LENGTH=property(len)
    KEYS=property(lambda self:list(self))
    COPY=property(lambda self:Lex(self))


class Flag:
    value=False
    def __bool__(self):return self.value


def fixture():
    env,saved,events,alarms,moon,_=mid.retry_environment()
    moon.NAME='Minmus'
    env['SHIP'].BODY=moon
    env['SHIP'].STATUS='ORBITING'
    env['SHIP'].PERIAPSIS=15000
    env['SHIP'].ORBIT=NS(PERIOD=100,ECCENTRICITY=0,HASNEXTPATCH=False,INCLINATION=20,LAN=30)
    env['ADDONS'].TR=NS(AVAILABLE=True,HASIMPACT=False)
    saved.update(phase='LAND_DEORBIT',mission_id='minmus_economy_return',launch_time=12)
    env.update(ABORT=Flag(),LEXICON=lambda *xs:Lex(zip(xs[::2],xs[1::2])),
               LANDING_LIGHT_MODE='SUNLIT',LANDING_REQUIRE_KERBIN=1,
               landingRequireKerbin=lambda:env['LANDING_REQUIRE_KERBIN'],
               LANDING_KERBIN_MIN_ELEV=15,LANDING_LIGHT_TIME_MARGIN=300,
               landingSunBand=lambda:dict(MIN=5,MAX=30),landingPlanningRadius=lambda:21000,
               landingLightActive=lambda:True,thrustCutoffOk=lambda:True,
               coastHealthCheck=lambda *args:True,COAST_HEALTH_CHECK=0,
               idealCoastWarpRate=lambda _:1,
               fixture_settle=lambda:events.append(('settled',)),
               fixture_wait=lambda dt:setattr(env['TIME'],'SECONDS',env['TIME'].SECONDS+dt))
    for name in re.findall(r'(?:GLOBAL|LOCAL) FUNCTION (\w+)',WAIT+'\n'+mid.COAST):
        env[name]=lambda *args,name=name:ks.call(name,env,*args)
    env['orientForSolar']=lambda *args:events.append(('aim',args[-1])) or True
    env['trySolarHoldTick']=lambda ref,deadline=0:events.append(('tick',deadline)) or 1
    env['coastAutoWarp']=lambda *args:events.append(('warp',args)) or True
    return env,saved,events,alarms


def site(found,**extra):
    return Lex(FOUND=found,REASON='ok' if found else 'kerbin-below-margin',
               LAT=19,LNG=37,UT=2000 if found else 0,SCAN_END=5000,STEP=100,**extra)


def check_minmus_opposition_forecast():
    env,_=light.hierarchy_environment(moon_name='Minmus',moon_phase=0)
    moon,ship=env['SHIP'].BODY,env['SHIP']
    epoch=env['TIME'].SECONDS
    period=2*math.pi*math.sqrt(75000**3/1.7658e9)
    ship.ORBIT=NS(PERIOD=period,ECCENTRICITY=0,INCLINATION=20,LAN=0)
    native=env['POSITIONAT']
    def spin():
        angle=2*math.pi*(env['TIME'].SECONDS-epoch)/moon.ROTATIONPERIOD
        return np.array(((math.cos(angle),-math.sin(angle),0),
                         (math.sin(angle),math.cos(angle),0),(0,0,1)))
    env['LATLNG']=lambda lat,lng:light.Geo(lat,lng,moon,spin())
    def positionat(obj,ut):
        if obj is not ship:return native(obj,ut)
        phase,inc=2*math.pi*(ut-epoch)/period,math.radians(20)
        return moon.POSITION+75000*np.array((math.cos(phase),math.sin(phase)*math.cos(inc),
                                            math.sin(phase)*math.sin(inc)))
    def geo(pos):
        rel=spin().T@(pos-moon.POSITION)
        return env['LATLNG'](math.degrees(math.asin(rel[2]/np.linalg.norm(rel))),
                             math.degrees(math.atan2(rel[1],rel[0])))
    moon.GEOPOSITIONOF=geo
    env.update(POSITIONAT=positionat,LANDING_LIGHT_MODE='SUNLIT',
               LANDING_SUN_MIN_ELEV=5,LANDING_KERBIN_MIN_ELEV=15,
               LANDING_FLEXIBLE_SITE=1,LANDING_ECONOMY_BRAKE=1,
               LANDING_LIGHT_SCAN_ORBITS=4,LANDING_LIGHT_SCAN_SAMPLES=64)
    env['lmGroundGeoAt']=lambda ut:ks.call('lmGroundGeoAt',env,ut)
    ks.SOURCES+='\n'+(ROOT/'lib/landing_math.ks').read_text()
    assert not env['landingLitGroundTrack']()['FOUND']
    estimated=env['landingLitGroundTrack'](True)
    assert estimated['FOUND'] and estimated['UT']>epoch+4*period
    assert estimated['STEP']>=2*moon.ORBIT.PERIOD/512-1
    assert env['CONFIG'].IPU==150
    env['TIME'].SECONDS=estimated['UT']-max(600,period*.35)-2*period
    actual=env['landingLitGroundTrack']()
    assert actual['FOUND'] and actual['UT']>env['TIME'].SECONDS
    assert env['landingPlanningLight'](actual['LAT'],actual['LNG'],actual['UT'],True)['OK']
    print('PASS: native-frame Minmus opposition has no near-term site; a bounded coarse forecast finds a later window and a fresh inclined-ground-track search validates it at wake')


def check_live_wait_and_target_selection():
    for kac in (False,True):
        env,saved,events,alarms=fixture()
        env['ADDONS'].KAC.AVAILABLE=kac
        calls=[]
        def search(forecast=False):
            calls.append((forecast,env['TIME'].SECONDS))
            if forecast:return site(True)
            return site(len(calls)>1)
        env['landingLitGroundTrack']=search
        selected=[]
        env.update(LANDING_AUTO_TARGET=1,LANDING_AUTO_TARGET_MINUTES=5,
                   _landingWriteTargetOverrides=lambda:selected.append((env['TARGET_LAT'],env['TARGET_LNG'])))
        automatic=function_body(SOURCE,'_autoLandingTarget')
        assert run(automatic,env)
        assert [kind for kind,_ in calls]==[False,True,False]
        assert calls[-1][1]==1200 and selected==[(19,37)]
        assert saved['phase']=='LAND_DEORBIT' and 'landing_light_wait' not in saved
        assert not env['phaseShouldYield'] and not alarms
        if kac:assert next(i for i,e in enumerate(events) if e[0]=='alarm')<next(i for i,e in enumerate(events) if e[0]=='aim')
        assert any(e[0]=='tick' for e in events)
        assert not any(e[0] in ('advance','yield') for e in events)
    # Follow the real phase/confirmation chain too, with burn mechanics
    # stubbed only after fresh target selection and the completed wait.
    env,saved,events,alarms=fixture()
    calls=[]
    def search(forecast=False):calls.append(forecast);return site(forecast or len(calls)>2)
    target=Lex(FOUND=True,LAT=0,LNG=90,SOURCE='old locked config')
    def persist():target.update(LAT=env['TARGET_LAT'],LNG=env['TARGET_LNG'])
    def execute():
        assert env['TIME'].SECONDS>=1200 and target['LAT']==19 and target['LNG']==37
        assert 'landing_light_wait' not in saved
        events.append(('execute',));return True
    env.update(landingLitGroundTrack=search,LANDING_AUTO_TARGET=1,
               LANDING_AUTO_TARGET_MINUTES=5,LANDING_FLEXIBLE_SITE=1,
               LANDING_SKIP_TARGET_SEARCH=0,LANDING_CONFIRM_TARGET=0,
               launchSeq=NS(CONTAINS=lambda phase:phase in ('LAND_DEORBIT','LAND_ASSIST')),
               vesselLandingPrepareRoles=lambda:True,
               landingApplyMissionConfig=lambda:None,_resumeExistingLandingDeorbitNode=lambda:False,
               landingResolveTarget=lambda:target,_landingWriteTargetOverrides=persist,
               _autoLandingTarget=lambda:run(function_body(SOURCE,'_autoLandingTarget'),env),
               _confirmLandingTarget=lambda:ks.call('_confirmLandingTarget',env),
               _landingTargetedDeorbit=execute,
               _advanceAfterLandDeorbit=lambda:events.append(('advance','LAND_ASSIST')))
    run(function_body(SOURCE,'phaseLandDeorbit'),env)
    assert calls==[False,True,False] and events[-2:]==[('execute',),('advance','LAND_ASSIST')]
    assert not env['phaseShouldYield'] and not alarms
    print('PASS: automatic target selection stays live, installs KAC before solar, polls without KAC and selects only the fresh post-wake site; no prompt exit, burn or phase advance')


def check_reboot_and_overdue_wait():
    env,saved,_,_=fixture()
    env['landingLitGroundTrack']=lambda forecast=False:site(forecast)
    def interrupted(*args):raise RuntimeError('reboot')
    env['orientForSolar']=interrupted
    try:env['landingAwaitLitGroundTrack']()
    except RuntimeError as error:assert str(error)=='reboot'
    else:raise AssertionError('missing simulated reboot')
    persisted=json.loads(json.dumps(saved),object_hook=Lex)
    wake=persisted['landing_light_wait']['wakeUt']
    for now in (1000,wake+5):
        env,resumed,events,alarms=fixture()
        resumed.update(json.loads(json.dumps(persisted),object_hook=Lex))
        env['TIME'].SECONDS=now
        def search(forecast=False):
            assert not forecast and env['TIME'].SECONDS>=wake
            return site(True)
        env['landingLitGroundTrack']=search
        assert env['landingAwaitLitGroundTrack']()['FOUND']
        assert env['TIME'].SECONDS==max(now,wake)
        assert 'landing_light_wait' not in resumed and not alarms
        assert any(e[0]=='aim' for e in events)==(now<wake)
    print('PASS: JSON-persisted wake survives reboot without moving later or searching early; overdue intent searches immediately and clears its alarm/state')


def check_stale_context_and_failure_guards():
    for fault in ('mission','body','mode','node','descent','patch','impact','started','atmosphere','period-zero','period-nan'):
        env,saved,events,alarms=fixture()
        context=env['_landingLightWaitContext']()
        saved['landing_light_wait']=Lex(context=Lex(context),wakeUt=2000,estimateUt=2400,
                                        forecastFound=True,alarm='old-light')
        alarms['old-light']=(2000,'')
        if fault in ('mission','body','mode'):context[fault]='different'
        if fault=='node':env['HASNODE']=True
        if fault=='descent':env['SHIP'].STATUS='SUB_ORBITAL'
        if fault=='patch':env['SHIP'].ORBIT.HASNEXTPATCH=True
        if fault=='impact':env['ADDONS'].TR.HASIMPACT=True
        if fault=='started':saved['deorbit_burn_started']='true'
        if fault=='atmosphere':env['SHIP'].BODY.ATM.EXISTS=True
        if fault.startswith('period-'):env['SHIP'].ORBIT.PERIOD=0 if fault=='period-zero' else math.nan
        saved['landing_light_wait']['context']=context
        calls=[]
        def search(forecast=False):calls.append(forecast);return site(True)
        env['landingLitGroundTrack']=search
        result=env['landingAwaitLitGroundTrack']()
        stale=fault in ('mission','body','mode')
        assert result['FOUND']==stale and calls==([False] if stale else [])
        if not stale:
            expected={'node':'maneuver-node-present','descent':'not-orbiting',
                      'patch':'future-orbit-patch','impact':'predicted-impact',
                      'started':'deorbit-already-started','atmosphere':'atmospheric-body',
                      'period-zero':'invalid-orbit-period','period-nan':'invalid-orbit-period'}
            assert result['REASON']==expected[fault]
        assert not alarms and 'landing_light_wait' not in saved
        assert not any(e[0]=='aim' for e in events)
    for reason in ('invalid-light-config','kerbin-frame-mismatch'):
        env,saved,events,alarms=fixture()
        report=site(False);report['REASON']=reason
        env['landingLitGroundTrack']=lambda forecast=False:report
        assert not env['landingAwaitLitGroundTrack']()['FOUND']
        assert not alarms and not saved.get('landing_light_wait')
    print('PASS: stale mission/body/policy intent is discarded; retained nodes, descent, patch/impact, started burns, atmosphere and invalid geometry/config cannot enter the orbital wait')


def check_wait_interruptions():
    for fault in ('abort','node','descent','body-during-solar','phase'):
        env,saved,events,alarms=fixture()
        calls=[]
        def search(forecast=False):calls.append(forecast);return site(forecast)
        env['landingLitGroundTrack']=search
        if fault=='body-during-solar':
            def aim(*args):env['SHIP'].BODY=NS(NAME='Other',ATM=NS(EXISTS=False));return True
            env['orientForSolar']=aim
        else:
            def elapsed(dt):
                env['TIME'].SECONDS+=dt
                if fault=='abort':env['ABORT'].value=True
                if fault=='node':env['HASNODE']=True
                if fault=='descent':env['SHIP'].STATUS='SUB_ORBITAL'
                if fault=='phase':saved['phase']='LAND_ASSIST';env['ABORT'].value=True
            env['fixture_wait']=elapsed
        assert not env['landingAwaitLitGroundTrack']()['FOUND']
        assert calls==[False,True] and not alarms and not saved.get('landing_light_wait')
        assert not any(e[0] in ('advance','yield') for e in events)
    print('PASS: abort/new node/descent and a body change during solar stop the live wait before another search or burn; alarms are cleaned and no phase is advanced')


def check_forecast_fallback_and_dependencies():
    env,saved,events,alarms=fixture()
    calls=[]
    def search(forecast=False):
        calls.append((forecast,env['TIME'].SECONDS))
        return site(len(calls)>=5 and not forecast)
    env['landingLitGroundTrack']=search
    result=env['landingAwaitLitGroundTrack']()
    assert result['FOUND'] and len(calls)==5
    near=[when for forecast,when in calls if not forecast]
    assert len(near)==3 and all(after-before>=100 for before,after in zip(near,near[1:]))
    assert not alarms and 'landing_light_wait' not in saved
    deps,_,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    assert {'landing_light_wait','coast_wait','solar','thrust_cutoff'}<=closure(['landing_deorbit','landing_light_wait'],deps)
    assert 'landing_light_wait' not in closure(['landing_main'],deps)
    assert 'landing_light_wait' not in closure(['landing_light'],deps) # Operator previews never wait.
    print('PASS: an exhausted coarse forecast schedules spaced rechecks rather than spinning or approving a site; offline solar/cutoff dependencies belong only to orbital landing setup')


def check_parking_coast_health():
    for scenario in ('healthy','low-battery','failed-health'):
        env,saved,events,alarms=fixture()
        env.update(COAST_AUTO_WARP=1,COAST_HEALTH_CHECK=1,SOLAR_HOLD_EC=.6)
        env['coastEnsureHealthAlarm']=lambda ut,label:env['kacEnsureAlarm'](label,ut,'health')
        if scenario=='low-battery':
            env.update(shipSolarFlow=lambda:0,shipPowerFraction=lambda:.2,
                       trySolarHoldTick=lambda *_:0)
        if scenario=='failed-health':env['coastHealthCheck']=lambda *_:False
        calls=[]
        def search(forecast=False):calls.append(forecast);return site(forecast or len(calls)>2)
        env['landingLitGroundTrack']=search
        assert env['landingAwaitLitGroundTrack']()['FOUND']
        warps=[event for event in events if event[0]=='warp']
        assert bool(warps)==(scenario=='healthy')
        assert len(warps)==(2 if scenario=='healthy' else 0)
        assert env['TIME'].SECONDS==1200 and calls==[False,True,False]
        assert not alarms and not env['phaseShouldYield']
    print('PASS: parking waits retain the shared midpoint health/solar warp policy; low battery or failed health stays at 1x while the live timer still resumes')


def check_forecast_abort_scope():
    env,_=light.hierarchy_environment(moon_name='Minmus')
    saved={}
    env.update(ABORT=Flag(),stateSet=lambda key,value:saved.update({key:value}),
               stateRemove=lambda key:saved.pop(key,None))
    def sample(ut):
        assert env['CONFIG'].IPU==2000 and saved['landing_prior_ipu']==150
        env['ABORT'].value=True
        return light.Geo(0,0,env['SHIP'].BODY,np.eye(3))
    env['lmGroundGeoAt']=sample
    result=env['landingLitGroundTrack'](True)
    assert not result['FOUND'] and result['REASON']=='aborted'
    assert env['CONFIG'].IPU==150 and not saved
    print('PASS: cancelling the long forecast cannot select a candidate or leak its temporary CPU budget')


def check_abort_on_phase_entry():
    env,saved,events,alarms=fixture()
    env['ABORT'].value=True
    def forbidden(*args):raise AssertionError('Abort-on-entry reached search/wait/burn')
    env.update(landingApplyMissionConfig=lambda:None,
               landingLitGroundTrack=forbidden,enterSolarCoast=forbidden,
               _confirmLandingTarget=forbidden,_resumeExistingLandingDeorbitNode=forbidden)
    before=dict(saved)
    run(function_body(SOURCE,'phaseLandDeorbit'),env)
    assert bool(env['ABORT']) and env['phaseShouldYield']
    assert events==[('yield','LAND_DEORBIT')] and saved==before and not alarms
    # Direct callers still get cancellation without running a picker.
    result=env['landingAwaitLitGroundTrack']()
    assert not result['FOUND'] and result['REASON']=='aborted'
    assert env['_landingLightWaitBlockReason']()=='abort-active'
    print('PASS: confirmed Abort-on reboot reports an explicit phase pause, performs no search/solar/burn and never clears Abort or changes saved intent')


if __name__=='__main__':
    check_minmus_opposition_forecast()
    check_live_wait_and_target_selection()
    check_reboot_and_overdue_wait()
    check_stale_context_and_failure_guards()
    check_wait_interruptions()
    check_forecast_fallback_and_dependencies()
    check_parking_coast_health()
    check_forecast_abort_scope()
    check_abort_on_phase_entry()
