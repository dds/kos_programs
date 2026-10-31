"""Eeloo capture/flyby and Moho profile source checks; not a native KSP flight."""
import math
import re
from functools import lru_cache
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_codebase import ROOT, closure, dependency_tables, function_body
from check_espoir_fleet import Items, Map, Text, native, profile
from check_espoir_science import Experiment
from check_minmus_kolniya import executable
from check_surface_return import read_settings
from check_entry_landing import call

CAPTURE = (ROOT/'lib/capture.ks').read_text()
PLAN = (ROOT/'lib/maneuver_plan.ks').read_text()
FLYBY = (ROOT/'lib/flyby.ks').read_text()
FLIGHT = (ROOT/'lib/science_flight.ks').read_text()
CONIC = (ROOT/'lib/conic_time.ks').read_text()
MATH = dict(SQRT=math.sqrt,LN=math.log,SIN=lambda x:math.sin(math.radians(x)),
            ARCTAN2=lambda y,x:math.degrees(math.atan2(y,x)),CONSTANT=NS(PI=math.pi))


@lru_cache(None)
def prepared(source, name):
    code = function_body(source, name)
    parameters = re.findall(r'PARAMETER (\w+)', code)
    code = re.sub(r'PARAMETER [^.]+\.', '', code)
    code = code.replace('ADD nd.', 'fixture_add(nd).').replace('REMOVE nd.', 'fixture_remove(nd).')
    return parameters,ks.compile_nodes(ks.freeze(executable(code)))


def invoke(source, name, env, *args):
    parameters,compiled=prepared(source,name)
    local = dict(env, **dict(zip(parameters, args))) if parameters else env
    try:ks.execute(compiled,local)
    except ks.Returned as result:return result.value


def check_profiles():
    deps, phases, _ = dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    eeloo = profile('eeloo_flyby')
    assert eeloo['TARGET_'] == 'EELOO' and eeloo['BPLANE_ARRIVAL_MODE'] == 'FLYBY'
    assert eeloo['CAPTURE_INC'] == 90 and eeloo['BPLANE_REQUIRE_PLANE'] == 1
    assert eeloo['CAPTURE_OPTIONAL_FLYBY'] == eeloo['CAPTURE_ACCEPT_BOUND'] == 1
    assert eeloo['TARGET_AP'] == 5000000 and eeloo['CAPTURE_PE'] == 25000
    assert eeloo['CAPTURE_RESERVE_DV'] == 150 and eeloo['FLYBY_SCIENCE'] == 1
    assert eeloo['SEQUENCE'][-4:] == ['CAPTURE','FLYBY','SCIENCE_OPS','DONE']
    assert 'SHAPE' not in eeloo['SEQUENCE'] and eeloo['FLYBY_NEXT_TARGET'] == 'EELOO'
    assert eeloo['FLYBY_EXIT_SOI'] == eeloo['SCIENCE_OPS_RUN_ALL'] == 0
    assert eeloo['SCIENCE_OPS_HOLD'] == 1
    for cfg in (eeloo, profile('moho_lander'), profile('moho_orbital_surveyor')):
        assert cfg['MISSION_TYPE'] == 'interplanetary' and cfg['COAST_AUTO_WARP'] == 0
        assert cfg['MISSION_CACHE_NEXT_BAND'] == 1 and cfg['CAPTURE_LAN'] == -1
        for phase in cfg['SEQUENCE']:
            assert phase.lower() in phases and closure(phases[phase.lower()], deps)
        assert not {'AEROBRAKE','SCIENCE_ENTRY','RETURN_SETUP'} & set(cfg['SEQUENCE'])
    lander = profile('moho_lander')
    assert lander['TARGET_'] == 'MOHO' and lander['CAPTURE_PE'] == lander['TARGET_AP'] == 25000
    assert lander['SEQUENCE'][-6:] == ['CAPTURE','LANDING_REVIEW','LAND_DEORBIT','LAND_ASSIST','SURFACE_SCIENCE','DONE']
    assert lander['CAPTURE_RESERVE_DV'] == lander['BPLANE_CAPTURE_MARGIN'] == 1200
    assert lander['LANDING_AUTO_TARGET'] == lander['TARGET_LOCK'] == 0
    assert lander['LANDING_TARGET_REVIEW_REQUIRED'] == lander['LANDING_REQUIRE_KERBIN'] == 1
    assert lander['LANDING_SITE_MAX_SLOPE'] == 5 and lander['LANDING_DIVERT_EMERGENCY_SLOPE'] == 15
    assert lander['LANDING_RETURN_DECOUPLER_TAG'] == lander['LANDING_RELEASE_DECOUPLER_TAG'] == ''
    survey = profile('moho_orbital_surveyor')
    assert survey['TARGET_'] == 'MOHO' and survey['CAPTURE_INC'] == survey['SHAPE_INC'] == 90
    assert survey['TARGET_AP'] == survey['SHAPE_AP'] == survey['SHAPE_PE'] == 70000
    assert survey['SCANSAT_DECOUPLER_TAG'] == '' and survey['SCANSAT_DISPOSE_CARRIER'] == 0
    assert survey['SCANSAT_POWER_LOW'] < survey['SCANSAT_POWER_RESUME']
    assert 'science_flight' not in closure(phases['capture'], deps)
    assert {'science_flight','flyby'} <= closure(phases['flyby'], deps)
    assert 'maneuver' not in closure(phases['flyby'], deps)
    print('PASS: Eeloo optional high polar capture preserves flyby/science review; Moho mapper and selected-site airless lander resolve independently with fuel, terrain, radio and power guards')


def capture_fixture(fuel=1300, vinf=1760):
    cfg = read_settings(CAPTURE, {}, 'GLOBAL')
    cfg.update(profile('eeloo_flyby'))
    cfg = native(cfg)
    target = NS(NAME=Text('Eeloo'), MU=7.4410815e10, RADIUS=210000, SOIRADIUS=119082940,
                ATM=NS(EXISTS=False))
    rp = target.RADIUS+25000
    orbit = NS(ECCENTRICITY=1+rp*vinf**2/target.MU, SEMIMAJORAXIS=-target.MU/vinf**2,
               HASNEXTPATCH=True, NEXTPATCHETA=10000, INCLINATION=90)
    ship = NS(BODY=target, PERIAPSIS=25000, APOAPSIS=-1, ORBIT=orbit,
              DELTAV=NS(VACUUM=fuel), THRUST=0, CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0))
    state = dict(phase='CAPTURE')
    events = []
    env = dict(cfg, **MATH, SHIP=ship, KUNIVERSE=NS(ACTIVEVESSEL=ship), TIME=NS(SECONDS=100),
        ETA=NS(PERIAPSIS=1000), WARP=0, ABORT=False, HASNODE=False,
        missionTargetBody=lambda:target, midcourseClearReviewAlarm=lambda:None,
        stateGet=lambda key,default='':state.get(key,default), xferSeq=cfg['SEQUENCE'],
        maneuverBurnInterrupted=lambda:False, yieldToPrompt=lambda:events.append('hold'),
        fixture_wait=lambda _:None, orbitSummary=lambda:None, maneuverUiArchiveLog=lambda _:None,
        nextPhase=lambda _:events.append('next'), MAX_RETRIES=5)
    def node(ut, radial, normal, prograde):
        # Independent periapsis speed -> post-impulse orbital energy.
        speed = math.sqrt(vinf**2+2*target.MU/rp)+prograde
        a = 1/(2/rp-speed**2/target.MU)
        ap = 2*a-rp-target.RADIUS
        return NS(DELTAV=NS(MAG=abs(prograde)),ORBIT=NS(PERIAPSIS=25000,APOAPSIS=ap,ECCENTRICITY=1-rp/a))
    def add(nd): env['HASNODE']=True; events.append(('plan',nd.DELTAV.MAG,nd.ORBIT.APOAPSIS))
    def remove(nd): env['HASNODE']=False; events.append('remove')
    def burn():
        events.append('burn'); env['HASNODE']=False
        orbit.ECCENTRICITY=.9; ship.APOAPSIS=5000000
        return True
    env.update(NODE=node, fixture_add=add, fixture_remove=remove, executeManeuver=burn)
    for source, names in ((PLAN,('_sar','planCapture')), (CAPTURE,('_captureContinueFlyby',))):
        for name in names:
            env[name]=lambda *args,source=source,name=name:invoke(source,name,env,*args)
    return env, ship, state, events


def check_capture_and_safe_fallback():
    for fuel,vinf,expected in ((1400,1760,'burn'),(1300,1760,'flyby'),(700,1760,'flyby'),
                               (1100,1278,'burn'),(1400,2266,'flyby')):
        env,ship,state,events=capture_fixture(fuel,vinf)
        invoke(CAPTURE,'phaseCapture',env)
        node=next(e for e in events if isinstance(e,tuple))
        assert abs(node[2]-5000000)<1e-6
        if expected=='burn':
            assert events[-2:]==['burn','next'] and node[1]+150<=fuel
        else:
            assert events[-2:]==['remove','next'] and 'burn' not in events
    for fault in ('disabled','abort','foreign-node','interrupted','pilot','wrong-vessel',
                  'atmosphere','late-pe','truncated-pe','wrong-next-phase','nan-fuel','nan-node'):
        env,ship,state,events=capture_fixture(700)
        if fault=='disabled':env['CAPTURE_OPTIONAL_FLYBY']=0
        if fault=='abort':env['ABORT']=True
        if fault=='foreign-node':env['HASNODE']=True
        if fault=='interrupted':env['maneuverBurnInterrupted']=lambda:True
        if fault=='pilot':ship.CONTROL.PILOTMAINTHROTTLE=.1
        if fault=='wrong-vessel':env['KUNIVERSE'].ACTIVEVESSEL=NS()
        if fault=='atmosphere':ship.BODY.ATM.EXISTS=True
        if fault=='late-pe':env['ETA'].PERIAPSIS=-1
        if fault=='truncated-pe':ship.ORBIT.NEXTPATCHETA=500
        if fault=='wrong-next-phase':env['xferSeq']=Items(['CAPTURE','SHAPE'])
        if fault=='nan-fuel':ship.DELTAV.VACUUM=math.nan
        if fault=='nan-node':env['planCapture']=lambda *_:NS(DELTAV=NS(MAG=math.nan))
        invoke(CAPTURE,'phaseCapture',env)
        assert events[-1]=='hold' and 'next' not in events and 'burn' not in events,(fault,events)
        if fault=='foreign-node':assert env['HASNODE'] and 'remove' not in events
    env,ship,_,events=capture_fixture(1400)
    def interrupted_burn():
        events.append('burn');env['maneuverBurnInterrupted']=lambda:True;return False
    env['executeManeuver']=interrupted_burn
    invoke(CAPTURE,'phaseCapture',env)
    assert events[-2:]==['burn','hold'] and 'next' not in events
    print('PASS: real capture planner matches independent conic energy at three arrival speeds; finite affordable burns execute, unaffordable captures remove only their node and fly by, unsafe/invalid/interrupted contexts still hold')


def flyby_fixture(link=True, power=.8):
    cfg = native(profile('eeloo_flyby'))
    clock = NS(SECONDS=700.)
    target = NS(NAME=Text('Eeloo'),RADIUS=210000,MU=7.4410815e10,SOIRADIUS=119082940,HASBODY=False,ATM=NS(EXISTS=False))
    rp,vinf=235000,1760
    ecc=1+rp*vinf**2/target.MU
    orbit=NS(ECCENTRICITY=ecc,PERIOD=20000)
    ship=NS(BODY=target,ORBIT=orbit,PERIAPSIS=25000,VERTICALSPEED=-1,ALTITUDE=1e6,
            DELTAV=NS(VACUUM=800))
    saved={'mission_id':Text('eeloo_flyby')}; events=[]; alarms={}; observed=[]; exp=Experiment()
    exp.ISTYPE=lambda kind:kind=='ScienceExperimentModule'
    part=NS(UID=Text('p'),MODULES=Items(['science']),GETMODULEBYINDEX=lambda _:exp)
    ship.PARTS=Items([part])
    def lex(*rows):return Map(zip(rows[::2],rows[1::2]))
    def put(key,value):
        saved[key]=value
        if key=='science_flight_samples':observed.extend(value.values())
    def position():
        # Independent hyperbolic Kepler solve, not the production conic-time formula.
        mean=abs(clock.SECONDS-1000)*math.sqrt(target.MU/(target.MU/vinf**2)**3)
        h=math.asinh(mean/ecc)
        for _ in range(20):h-=(ecc*math.sinh(h)-h-mean)/(ecc*math.cosh(h)-1)
        ship.ALTITUDE=(target.MU/vinf**2)*(ecc*math.cosh(h)-1)-target.RADIUS
        ship.VERTICALSPEED=1 if clock.SECONDS>1000 else -1
        if exp.DEPLOYED and not exp.HASDATA and saved.get('science_flight_pending',{}).get('p:0'):
            exp.reading()
    def wait(dt):clock.SECONDS+=dt;position()
    def alarm(name,ut,*_):alarms[name]=ut;return name
    def solar(ref,deadline=0):
        events.append(('solar',clock.SECONDS,deadline))
        assert clock.SECONDS<deadline or deadline==0
        return .8
    env=dict(cfg,**MATH,SHIP=ship,KUNIVERSE=NS(ACTIVEVESSEL=ship),TIME=clock,ETA=NS(PERIAPSIS=300),
        ABORT=False,WARP=0,HASNODE=False,xferSeq=cfg['SEQUENCE'],LEXICON=lex,LIST=lambda *xs:Items(xs),
        stateGet=lambda key,default='':saved.get(key,default),stateGetNum=lambda key,default=0:saved.get(key,default),
        stateSet=put,fixture_wait=wait,thrustCutoffOk=lambda:True,missionTargetBody=lambda:target,
        orbitSummary=lambda:None,trySolarHoldTick=solar,shipPowerFraction=lambda:power,
        enterSolarCoast=lambda label,orient,health,deadline:solar(-1,deadline),
        yieldToPrompt=lambda:events.append('hold'),nextPhase=lambda _:events.append('next'),
        kacEnsureAlarm=alarm,DELETEALARM=lambda key:alarms.pop(key),
        _scienceFlightDeployAfter=Map(),_scienceFlightTransmitAfter=Map(),HOMECONNECTION=NS(ISCONNECTED=link))
    for source,names in ((FLYBY,('_flybySample','_flybyLowEntryUt','_flybyPeriapsisUt')),
                         (FLIGHT,('scienceFlightPulse','_scienceFlightStep'))):
        for name in names:env[name]=lambda *args,source=source,name=name:invoke(source,name,env,*args)
    env['conicTimeFromPe']=lambda *args:call(CONIC,'conicTimeFromPe',env,*args)
    position()
    return env,ship,saved,events,alarms,observed,exp


def check_science_and_resident_clock():
    for link,power in ((True,.8),(False,.8),(True,.1)):
        env,ship,saved,events,alarms,observed,exp=flyby_fixture(link,power)
        low=env['_flybyLowEntryUt'](ship.BODY,1000)
        invoke(FLYBY,'phaseFlyby',env)
        assert events[-1]=='next' and not alarms and env['TIME'].SECONDS>=1600
        assert all(e[1]<low for e in events if isinstance(e,tuple) and e[0]=='solar')
        assert 'eeloo_flyby:Eeloo:SPACE_HIGH' in observed
        if link and power>=.3:assert 'eeloo_flyby:Eeloo:SPACE_LOW' in observed
        else:assert exp.HASDATA and 'request' not in exp.events
        assert saved['flyby_pe_ut']==1000
        # Reboot after the pass: the stored epoch does not move the deadline.
        assert env['_flybyPeriapsisUt'](ship.BODY)==1000
    env,ship,saved,events,alarms,_,_=flyby_fixture()
    def abort(dt):env['ABORT']=True;env['TIME'].SECONDS+=dt
    env['fixture_wait']=abort
    invoke(FLYBY,'phaseFlyby',env)
    assert 'next' not in events and not alarms
    env,ship,_,events,alarms,_,_=flyby_fixture()
    env['kacEnsureAlarm']=lambda *_:''
    invoke(FLYBY,'phaseFlyby',env)
    assert events[-1]=='next' and env['TIME'].SECONDS>=1600
    env,ship,saved,_,_,_,_=flyby_fixture()
    ship.ORBIT.ECCENTRICITY=.8;ship.VERTICALSPEED=1
    env['ETA'].PERIAPSIS=19990
    assert env['_flybyPeriapsisUt'](ship.BODY)==690 # just completed capture
    for fault in ('node','vessel'):
        env,ship,_,events,alarms,_,_=flyby_fixture()
        def intervene(dt):
            env['TIME'].SECONDS+=dt
            if fault=='node':env['HASNODE']=True
            else:env['KUNIVERSE'].ACTIVEVESSEL=NS()
        env['fixture_wait']=intervene
        invoke(FLYBY,'phaseFlyby',env)
        assert events[-1]=='hold' and 'next' not in events and not alarms
    # The extracted phase retains legacy unpowered moon flyby -> parent
    # retargeting, with an exit alarm and no science or engine calls.
    env,ship,saved,events,alarms,observed,_=flyby_fixture()
    target=ship.BODY;target.HASBODY=True;target.BODY=NS(NAME=Text('Kerbin'))
    ship.ORBIT.HASNEXTPATCH=True;ship.ORBIT.NEXTPATCHETA=500
    env.update(FLYBY_SCIENCE=0,FLYBY_POST_PE_HOLD=0,FLYBY_EXIT_SOI=1,FLYBY_NEXT_TARGET='')
    def legacy_wait(dt):
        env['TIME'].SECONDS+=dt
        if env['TIME'].SECONDS>=1200:ship.BODY=target.BODY
    env['fixture_wait']=legacy_wait
    invoke(FLYBY,'phaseFlyby',env)
    assert events[-1]=='next' and not alarms and not observed and saved['target']=='Kerbin'
    print('PASS: actual flyby phase runs supported high/low-space science with no close-pass solar search, retains data without power/link, owns/cleans KAC clocks, polls without KAC and preserves the same pass across reboot/capture and Abort')


if __name__=='__main__':
    check_profiles()
    check_capture_and_safe_fallback()
    check_science_and_resident_clock()
