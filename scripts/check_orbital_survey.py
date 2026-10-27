"""Source-executed survey/return fixtures; not native kOS or contract validation."""
import copy
import math
import re
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_codebase import ROOT, function_body, dependency_tables, closure
from check_landing_orbit import Lex, Seq as BaseSeq
from check_surface_return import read_settings, defaults, emit_profile, literal

SOURCE = (ROOT/'lib/orbital_survey.ks').read_text()
HARDWARE = (ROOT/'lib/survey_hardware.ks').read_text()
PROFILE = (ROOT/'missions/RO9/minmus_tundra_survey_return.ks').read_text()
ks.SOURCES += '\n' + SOURCE + '\n' + HARDWARE


class Seq(BaseSeq):
    COPY=property(lambda self:Seq(self))


def fixture():
    env = ks.environment()
    read_settings(SOURCE,env,'GLOBAL')
    env.update(LEXICON=lambda *xs:Lex(zip(xs[::2],xs[1::2])),LIST=lambda *xs:Seq(xs),
               ARCCOS=lambda x:math.degrees(math.acos(x)),MOD=lambda x,y:x%y,configLiteral=literal,
               ABORT=False,phaseShouldYield=False,HASNODE=False,WARP=0,
               ORBITAL_SURVEY_BODY='Minmus',ORBITAL_SURVEY_ORBITS=1,
               SCIENCE_SURVEY_POINTS=Seq([Seq([0,0,6600])]),
               KUNIVERSE=NS(TIMEWARP=NS(ISSETTLED=True)),
               xferSeq=Seq(['ORBITAL_SURVEY','SCIENCE_OPS_LOW','LAND_DEORBIT']))
    env['SHIP'] = NS(STATUS='ORBITING',BODY=NS(NAME='Minmus',ATM=NS(EXISTS=False),RADIUS=60000),
        ORBIT=NS(ECCENTRICITY=.05,HASNEXTPATCH=False,PERIOD=3000,INCLINATION=116.6),
        PERIAPSIS=9300,APOAPSIS=19300,ALTITUDE=12000,THRUST=0,
        CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0),GEOPOSITION=NS(LAT=0,LNG=0))
    env['CORE']=NS(PART=NS(DECOUPLEDIN=-1))
    state={'phase':'ORBITAL_SURVEY','launch_time':'100','mission_id':'tundra'}
    disk={};events=[]
    def save(key,value):
        state[key]=value;disk[key]=copy.deepcopy(value)
    env.update(stateGet=lambda key,default:state.get(key,default),stateSet=save,
               thrustCutoffOk=lambda:events.append(('cutoff',)) or True,
               yieldToPrompt=lambda:env.update(phaseShouldYield=True),
               nextPhase=lambda seq:state.update(phase=seq[seq.index(state['phase'])+1]),
               fixture_wait=lambda seconds:setattr(env['TIME'],'SECONDS',env['TIME'].SECONDS+seconds))
    for name in re.findall(r'(?:LOCAL|GLOBAL) FUNCTION (\w+)',SOURCE):
        env[name]=lambda *args,name=name:ks.call(name,env,*args)
    def run():
        # WAIT UNTIL is the native warp-settling primitive, satisfied here.
        source=function_body(SOURCE,'phaseOrbitalSurvey').replace('WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.','')
        try:ks.run(ks.parse(source),env)
        except ks.Returned as result:return result.value
    return env,state,disk,events,run


class Thermometer:
    def __init__(self):
        self.HASDATA=False;self.DEPLOYED=False;self.INOPERABLE=False;self.RERUNNABLE=True
        self.readings=[];self.held=None;self.resets=0
    def RESET(self):
        assert not self.HASDATA,'a reset must never discard science'
        self.DEPLOYED=False;self.resets+=1
    def DEPLOY(self):
        assert not self.HASDATA and not self.INOPERABLE
        self.held=len(self.readings)+1;self.readings.append(self.held)
        self.HASDATA=self.DEPLOYED=True


def hardware(env,reject=False):
    experiment=Thermometer();collected=[]
    def collect():
        if experiment.HASDATA and not reject:
            collected.append(experiment.held);experiment.HASDATA=False;experiment.held=None
    container=NS(COLLECTALL=collect)
    def part(module,group=-1):
        return NS(NAME='sensorThermometer' if module=='ModuleScienceExperiment' else 'scienceBox',
                  DECOUPLEDIN=group,HASMODULE=lambda name:name==module,
                  GETMODULE=lambda name:experiment if name=='ModuleScienceExperiment' else container)
    therm=part('ModuleScienceExperiment');store=part('ModuleScienceContainer')
    env['SHIP'].PARTS=Seq([therm,store])
    env['SHIP'].PARTSNAMED=lambda name:Seq([therm]) if name=='sensorThermometer' else Seq()
    return experiment,collected,therm,store


def check_hardware_and_review_before_launch():
    env,state,_,events,_=fixture();experiment,_,therm,store=hardware(env)
    env['surveyHardwareReady']=lambda count:ks.call('surveyHardwareReady',env,count)
    assert env['surveyHardwareReady'](5)
    store.DECOUPLEDIN=2;assert not env['surveyHardwareReady'](5)
    env['SHIP'].PARTS=Seq([therm]*5);assert env['surveyHardwareReady'](5)
    experiment.DEPLOY();assert not env['surveyHardwareReady'](5)
    preflight=function_body((ROOT/'lib/prelaunch.ks').read_text(),'phasePrelaunch')
    assert preflight.index('surveyHardwareReady(')<preflight.index('confirmLaunch()')
    cfg=read_settings(PROFILE,defaults())
    from check_minmus_kolniya import execute
    conditional=function_body((ROOT/'lib/mission_type.ks').read_text(),'missionTypeConditionalRoots')
    for surveys in (True,False):
        for band in ('PRELAUNCH','LAUNCH','SHAPE'):
            roots=execute(conditional,dict(SEQUENCE=Seq(cfg['SEQUENCE'] if surveys else ['PRELAUNCH','LAUNCH']),
                bandKey=band,LIST=lambda *xs:Seq(xs)))
            assert ('survey_hardware' in roots)==(surveys and band=='PRELAUNCH')
    env.update(cfg,fixture_unlock=lambda:None,fixture_lock=lambda *_:None,
               scienceRunAll=lambda:(_ for _ in ()).throw(AssertionError('spent thermometer at review')),
               orbitSummary=lambda:None,scienceStatus=lambda:None,
               stateGet=lambda key,default: 'SCIENCE_OPS' if key=='phase' else default,
               xferSeq=Seq(cfg['SEQUENCE']))
    execute(function_body((ROOT/'lib/science.ks').read_text(),'phaseScienceOps'),env)
    assert env['phaseShouldYield'] and not events and cfg['SCIENCE_OPS_RUN_ALL']==0
    print('PASS: prelaunch rejects missing/discarded storage and spent thermometers before arming; five retained empty sensors are an alternative; first orbit review preserves empty sensors instead of running them early')


def check_profile_and_return():
    cfg=read_settings(PROFILE,defaults())
    assert [cfg['SHAPE_'+key] for key in ('AP','PE','INC','LAN','AOP')]==[397272,9300,116.6,337,270]
    assert cfg['CAPTURE_INC']==116.6 and cfg['CAPTURE_AOP']==270 and cfg['CAPTURE_DIR']=='RETROGRADE'
    assert cfg['SHAPE_MIN_PE']==cfg['LAND_PREP_MIN_PE']==cfg['ORBITAL_SURVEY_MIN_PE']==9000
    assert cfg['SHAPE_ALT_TOL']==100 and cfg['SHAPE_MIN_BURN_DV']==.002
    seq=cfg['SEQUENCE'];assert len(seq)==len(set(seq))
    assert seq[11:]==['SHAPE','SCIENCE_OPS','LAND_PREP','ORBITAL_SURVEY','SCIENCE_OPS_LOW','LAND_DEORBIT','LAND_ASSIST','SURFACE_RETURN_SETUP']
    assert cfg['SCIENCE_SURVEY_POINTS']==[[52.648,2.235,6600],[34.308,-12.419,6600],
        [52.176,18.898,6600],[35.436,-18.744,6600],[52.128,82.575,6600]]
    assert cfg['TARGET_LAT']==-29.189 and cfg['TARGET_LNG']==17.465
    assert cfg['TARGET_LOCK']==1 and cfg['LANDING_USE_WAYPOINTS']==cfg['LANDING_AUTO_TARGET']==cfg['LANDING_FLEXIBLE_SITE']==0
    assert cfg['SCIENCE_OPS_HOLD']==1 and cfg['AUTO_TRANSMIT']==0
    deps,phases,bands=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    roots=closure(phases['orbital_survey'],deps)
    assert {'science','landing_math','solar','thrust_cutoff'}<=roots
    assert not {'maneuver','deorbit_targeting','landing_main','orbit_shape'}&roots
    assert bands['orbital_survey']==['orbital_survey']
    cfg.update(BODY_NAME='MINMUS',PARKING_ALT=10000,LAUNCH_INCLINATION=29.189,LAUNCH_AZIMUTH=90)
    ascent=read_settings(emit_profile('phaseSurfaceReturnSetup',cfg),defaults())
    assert ascent['SEQUENCE']==['PRELAUNCH','LAUNCH','PARK','RETURN_SETUP']
    assert ascent['LAUNCH_INCLINATION']==abs(cfg['TARGET_LAT']) and ascent['SURFACE_RETURN_ORBIT']=={}
    ascent['targetPe']=ascent['RETURN_PE']
    home=read_settings(emit_profile('phaseReturnSetup',ascent),{})
    assert home['AEROBRAKE_PE']==home['ESCAPE_PE']==53000
    assert home['CAPTURE_INC']==-1 and home['DESCENT_DECOUPLER_TAG']=='return_decoupler'
    print('PASS: exact Tundra -> safe low survey orbit -> five above6600m sites -> review -> fixed landing -> eastward low-orbit ascent ->53km Kerbin return survives fresh generated profiles; survey band excludes maneuver/landing controllers')


def check_forecast_and_geometry():
    env,_,_,_,_=fixture()
    # A known moving subpoint, including the date-line crossing. Real shared
    # lmGroundGeoAt is independently exercised by the existing conic checks.
    env['lmGroundGeoAt']=lambda ut:NS(LAT=0,LNG=(ut-900)*.12)
    result=env['_surveyForecast'](Seq())
    assert result['FOUND'] and abs(result['UT']-900)<1 and result['MISS']<50
    assert env['_surveyDistance'](NS(LAT=0,LNG=179.9),[0,-179.9,6600])<210
    assert env['_surveyDistance'](NS(LAT=89.9,LNG=180),[89.9,0,6600])<210
    env['lmGroundGeoAt']=lambda ut:NS(LAT=40,LNG=0)
    assert not env['_surveyForecast'](Seq())['FOUND']
    assert not env['_surveyForecast'](Seq([0]))['FOUND']
    print('PASS: bounded coarse/refined search recovers a known overhead crossing; spherical distances handle poles/date line, completed sites are excluded and misses do not authorize observations')


def check_rotating_retrograde_route():
    env,_,_,_,_=fixture()
    cfg=read_settings(PROFILE,{})
    env.update(SCIENCE_SURVEY_POINTS=Seq(Seq(site) for site in cfg['SCIENCE_SURVEY_POINTS']),ORBITAL_SURVEY_ORBITS=48)
    radius=60000;axis=(9300+19300+2*radius)/2;ecc=(19300-9300)/(2*axis)
    period=2*math.pi*math.sqrt(axis**3/1.7658e9)
    env['SHIP'].ORBIT.PERIOD=period
    inc,lan,aop=map(math.radians,(116.6,337,270))
    def ground(ut):
        mean=(2*math.pi*ut/period)%(2*math.pi);ea=mean
        for _ in range(5):ea-=(ea-ecc*math.sin(ea)-mean)/(1-ecc*math.cos(ea))
        ta=2*math.atan2(math.sqrt(1+ecc)*math.sin(ea/2),math.sqrt(1-ecc)*math.cos(ea/2))
        arg=ta+aop
        x=math.cos(lan)*math.cos(arg)-math.sin(lan)*math.sin(arg)*math.cos(inc)
        y=math.sin(lan)*math.cos(arg)+math.cos(lan)*math.sin(arg)*math.cos(inc)
        z=math.sin(arg)*math.sin(inc)
        return NS(LAT=math.degrees(math.asin(z)),LNG=math.degrees(math.atan2(y,x))-360*ut/40400)
    env['lmGroundGeoAt']=ground
    done=Seq();attempts=0
    while len(done)<5 and attempts<10:
        result=env['_surveyForecast'](done)
        if result['FOUND']:
            assert result['SITE'] not in done and result['MISS']<=1000
            assert env['_surveyDistance'](ground(result['UT']),env['SCIENCE_SURVEY_POINTS'][result['SITE']])<=1000
            done.ADD(result['SITE']);env['TIME'].SECONDS=result['UT']+10
        else:env['TIME'].SECONDS+=period*24
        attempts+=1
    assert len(done)==5,(done,attempts)
    print('PASS: independent rotating retrograde Kepler fixture reaches all five actual requested northern sites in a preserved116.6deg9.3x19.3km plane, with bounded forecast retries and zero survey maneuver dV')


def check_readonly_forecast_cancellation():
    for fault in ('abort','node','body','orbit','thrust'):
        env,_,_,_,_=fixture();samples=[]
        def ground(ut):
            samples.append(ut)
            if len(samples)==3:
                if fault=='abort':env['ABORT']=True
                if fault=='node':env['HASNODE']=True
                if fault=='body':env['SHIP'].BODY=NS(NAME='Mun',RADIUS=200000,ATM=NS(EXISTS=False))
                if fault=='orbit':env['SHIP'].APOAPSIS=31000
                if fault=='thrust':env['SHIP'].THRUST=.1
            return NS(LAT=0,LNG=0)
        env['lmGroundGeoAt']=ground
        result=env['_surveyForecast'](Seq())
        assert not result['FOUND'] and len(samples)<=32 and not env['_surveySafe'](),fault
    print('PASS: forecast is read-only; live Abort/node/body changes cancel per sample, orbit/thrust changes cancel within one32-sample batch, and every rejected forecast fails the full live admission predicate before any observation')


def check_preservation_and_observe_guards():
    env,_,_,_,_=fixture();experiment,collected,therm,store=hardware(env)
    # Existing data must be collected, never reset while still held.
    experiment.DEPLOY();assert env['_surveyObserve'](0)
    assert collected==[1] and experiment.held==2 and experiment.resets==1
    env['_surveyStore']();assert collected==[1,2]
    for fault in ('node','abort','body','pe','ap','patch','thrust','pilot','warp','altitude','position','retention','inoperable'):
        env,_,_,_,_=fixture();experiment,_,therm,_=hardware(env)
        if fault=='node':env['HASNODE']=True
        if fault=='abort':env['ABORT']=True
        if fault=='body':env['SHIP'].BODY.NAME='Mun'
        if fault=='pe':env['SHIP'].PERIAPSIS=8999
        if fault=='ap':env['SHIP'].APOAPSIS=30001
        if fault=='patch':env['SHIP'].ORBIT.HASNEXTPATCH=True
        if fault=='thrust':env['SHIP'].THRUST=.1
        if fault=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.1
        if fault=='warp':env['WARP']=1
        if fault=='altitude':env['SHIP'].ALTITUDE=6600
        if fault=='position':env['SHIP'].GEOPOSITION.LAT=10
        if fault=='retention':therm.DECOUPLEDIN=2
        if fault=='inoperable':experiment.INOPERABLE=True
        assert not env['_surveyObserve'](0) and not experiment.readings,fault
    env,_,_,_,_=fixture();experiment,collected,_,_=hardware(env,reject=True)
    experiment.DEPLOY();assert env['_surveyReadyThermometer']()==0
    assert experiment.HASDATA and experiment.held==1 and not collected and experiment.resets==0
    print('PASS: old/new readings survive collection; duplicate refusal holds intact; node/Abort/body/Pe/Ap/patch/thrust/warp/altitude/proximity/retention/hardware guards prevent measurements')


def check_running_waits_and_cancellation():
    for fault in ('ok','no-kac','abort','node','body'):
        env,_,_,events,_=fixture()
        env.update(kacEnsureAlarm=lambda *args:events.append(('alarm',args[1])) or ('' if fault=='no-kac' else 'owned'),
            enterSolarCoast=lambda *args:events.append(('solar',)) or 1,
            DELETEALARM=lambda alarm:events.append(('delete',alarm)))
        def wait(*args):
            events.append(('clock',args[1],args[3]))
            env['TIME'].SECONDS=args[1]
            if fault=='abort':env['ABORT']=True
            if fault=='node':env['HASNODE']=True
            if fault=='body':env['SHIP'].BODY.NAME='Mun'
        env['waitUntilOrSOI']=wait
        assert bool(env['_surveyWait'](900))==(fault in ('ok','no-kac'))
        assert events[0][0]=='alarm' and events[1][0]=='solar' and events[2][0]=='clock'
        assert (len(events)==4)==(fault!='no-kac')
    print('PASS: each solar coast owns KAC before aiming, remains in a live clock wait without KAC, deletes only its alarm and rejects Abort/new node/body change on wake')


def check_phase_progress_and_reboot():
    env,state,disk,events,run=fixture();experiment,collected,_,_=hardware(env)
    env['SCIENCE_SURVEY_POINTS']=Seq([Seq([0,0,6600]),Seq([0,1,6600]),Seq([0,2,6600])])
    def forecast(done):
        index=next(i for i in range(3) if i not in done)
        env['SHIP'].GEOPOSITION.LNG=index
        return Lex(FOUND=True,SITE=index,UT=env['TIME'].SECONDS+200,MISS=0)
    env['_surveyForecast']=forecast
    env['_surveyWait']=lambda when:setattr(env['TIME'],'SECONDS',when) or True
    run()
    assert state['phase']=='SCIENCE_OPS_LOW' and disk['orbital_survey']['DONE']==[0,1,2]
    assert collected==[1,2,3] and not experiment.HASDATA and experiment.resets==2
    # Fresh phase entry copies nested progress; mutating its local list did
    # not change an already-recorded object without stateSet/durable IO.
    prior=copy.deepcopy(disk['orbital_survey']);state['phase']='ORBITAL_SURVEY'
    env['_surveyForecast']=lambda *_:(_ for _ in ()).throw(AssertionError('repeated survey'))
    run();assert disk['orbital_survey']==prior and state['phase']=='SCIENCE_OPS_LOW'
    # A timer miss retries in-process, then an operator Abort retains phase.
    env,state,disk,events,run=fixture();hardware(env)
    env['_surveyForecast']=lambda _:Lex(FOUND=False,MISS=10000)
    def cancel(when):events.append(('running-retry',when));env['ABORT']=True;return False
    env['_surveyWait']=cancel;run()
    assert state['phase']=='ORBITAL_SURVEY' and env['phaseShouldYield']
    assert len([event for event in events if event[0]=='running-retry'])==1
    print('PASS: source phase collects three distinct readings, persists copied progress, resumes a completed reboot without repeats, advances only to contract review, and keeps a missed-pass retry resident until operator cancellation')


if __name__=='__main__':
    check_hardware_and_review_before_launch()
    check_profile_and_return()
    check_forecast_and_geometry()
    check_rotating_retrograde_route()
    check_readonly_forecast_cancellation()
    check_preservation_and_observe_guards()
    check_running_waits_and_cancellation()
    check_phase_progress_and_reboot()
