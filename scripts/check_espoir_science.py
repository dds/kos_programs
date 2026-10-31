"""Espoir profile, data-preserving science and resident waits; not a KSP VM."""
import json
import re
from types import SimpleNamespace as NS

from check_codebase import ROOT, closure, dependency_tables, function_body
from check_minmus_kolniya import execute
from check_runtime_contracts import KList, KString
from check_surface_return import read_settings

FLIGHT = (ROOT/'lib/science_flight.ks').read_text()
ENTRY = (ROOT/'lib/science_entry.ks').read_text()
PROFILE = (ROOT/'missions/Espoir/duna_lander.ks').read_text()


class Map(dict):
    LENGTH = property(len)
    HASKEY = dict.__contains__
    REMOVE = dict.pop
    COPY = property(lambda self: Map(self))
    VALUES = property(lambda self: KList(self.values()))


def lex(*items):
    return Map(zip(items[::2], items[1::2]))


def run(source, name, env):
    body = function_body(source, name)
    body = re.sub(r'PARAMETER [^.]+\.', '', body)
    body = re.sub(r'WAIT UNTIL [^.]+\.', 'fixture_settled().', body)
    body = body.replace('BRAKES ON.', 'fixture_brakes().')
    body = body.replace('CHUTESSAFE ON.', 'fixture_chutes().')
    return execute(body, env)


def check_profile_and_boot():
    cfg = read_settings(PROFILE, {})
    assert cfg['TARGET_'] == 'DUNA' and cfg['MISSION_TYPE'] == 'interplanetary'
    assert cfg['SEQUENCE'][-6:] == ['SHAPE','LANDING_REVIEW','ATMO_DEORBIT','SCIENCE_ENTRY','SURFACE_SCIENCE','DONE']
    assert cfg['CAPTURE_PE'] == cfg['TARGET_AP'] == cfg['SHAPE_PE'] == cfg['SHAPE_AP'] == 70000
    assert cfg['CAPTURE_MIN_PE'] >= 60000 and cfg['CAPTURE_INC'] == 90
    assert cfg['BPLANE_PE_ONLY'] == 0 and cfg['BPLANE_REQUIRE_PLANE'] == 1
    assert cfg['ENTRY_POWERED_LANDING'] == cfg['LANDING_TARGET_REVIEW_REQUIRED'] == 1
    assert cfg['TARGET_LOCK'] == cfg['LANDING_AUTO_TARGET'] == cfg['LANDING_FLEXIBLE_SITE'] == 0
    assert cfg['SCIENCE_ENTRY_MOON'] == 'IKE' and cfg['SCIENCE_ENTRY_MAX_PASSES'] == 3
    assert cfg['SCIENCE_ENTRY_CHUTES']==1
    assert not re.search(r'RO9|return_decoupler|lander_decoupler|SET .*STAGE TO',
                         '\n'.join(line for line in PROFILE.splitlines() if not line.startswith('//')))
    deps, phases, bands = dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    for phase in cfg['SEQUENCE']:
        assert phase.lower() in phases and closure(phases[phase.lower()], deps)
    entry_libs = closure(phases['science_entry'], deps)
    assert {'science_entry','science_flight','solar','thrust_cutoff','aerobrake_ap_math'} <= entry_libs
    assert not {'descent','landing_main','duna_ike_setup','maneuver'} & entry_libs
    assert bands['science_entry'] == ['science_entry']
    bindings = function_body((ROOT/'lib/dependencies.ks').read_text(),'dependencyBindPhase')
    assert 'phaseScienceEntry@' in bindings
    cache_src = (ROOT/'lib/mission_type.ks').read_text()
    for band in ('XFER_BPLANE','XFER_ARRIVE','SCIENCE_ENTRY','LAUNCH'):
        roots = run(cache_src,'missionTypeCacheRoots',dict(bandKey=band,currentPhase="",SEQUENCE=KList(cfg['SEQUENCE']),
                    missionTypeConditionalRoots=lambda _:KList(['entry_landing']),
                    missionAppendUnique=lambda dest,rows:dest.extend(x for x in rows if x not in dest),
                    LIST=lambda *xs:KList(xs)))
        assert ('science_entry' in roots) == (band in ('XFER_BPLANE','XFER_ARRIVE'))
    assert 'bootLibLoad("rocket_craft")' in (ROOT/'craft/Espoir.ks').read_text()
    print('PASS: Espoir polar parking/site review precedes atmospheric deorbit; optional terminal provider resolves without adding descent/RO9 hardware assumptions to ordinary science entry')


class Experiment:
    def __init__(self):
        self.HASDATA = self.DEPLOYED = self.INOPERABLE = False
        self.RERUNNABLE = True
        self.DATA = KList()
        self.events = []
        self.transmitter = True
    def DEPLOY(self):
        assert not self.HASDATA and not self.INOPERABLE
        self.DEPLOYED = True
        self.events.append('deploy')
    def RESET(self):
        assert not self.HASDATA and self.RERUNNABLE and not self.INOPERABLE
        self.DEPLOYED = False
        self.events.append('reset')
    def TRANSMIT(self):
        assert self.HASDATA
        self.events.append('request')
        if self.transmitter:
            # Native stock kOS queues then immediately dumps the module copy.
            # This fixture deliberately supplies NO delivery acknowledgement.
            self.HASDATA = False
            self.DATA = KList()
            if not self.RERUNNABLE: self.INOPERABLE = True
    def reading(self):
        self.HASDATA = True
        self.DATA = KList([NS(TITLE='Reading',TRANSMITVALUE=4)])


def instrument_fixture(saved=None):
    saved = {} if saved is None else saved
    clock = NS(SECONDS=100)
    exp = Experiment()
    def get(key, default=''): return saved.get(key, default)
    def put(key, value):
        # Verify the borrowed state wasn't changed before commit, then
        # serialize/deserialize as on a reboot, rather than retaining aliases.
        assert key not in saved or value is not saved[key]
        saved[key] = Map(json.loads(json.dumps(value)))
    env = dict(ABORT=False, experiment=exp,instrumentId='p:0',context='Duna:SPACE_HIGH',
               canTransmit=True,HOMECONNECTION=NS(ISCONNECTED=True),TIME=clock,
               stateGet=get,stateSet=put,LEXICON=lex,
               _scienceFlightDeployAfter=Map(),_scienceFlightTransmitAfter=Map())
    def step(): return run(FLIGHT,'_scienceFlightStep',env)
    return env, saved, exp, step


def check_data_lifecycle():
    env,saved,exp,step = instrument_fixture()
    step()
    assert exp.events == ['deploy'] and 'science_flight_samples' not in saved
    step(); assert exp.events == ['deploy'] # asynchronous deploy still pending
    exp.reading(); step()
    assert exp.events == ['deploy','request'] and not exp.HASDATA
    assert saved['science_flight_samples']['p:0'] == 'Duna:SPACE_HIGH'
    assert not saved['science_flight_pending']
    step(); assert exp.events == ['deploy','request'] # avoid repeating this context
    env['context'] = 'Duna:SPACE_LOW'; env['TIME'].SECONDS += 11
    step(); assert exp.events[-2:] == ['reset','deploy']
    # Reboot between deployment and data arrival: intent survives; only
    # the eventual data, not the request, can complete the new context.
    new,_,_,step2 = instrument_fixture(saved)
    new.update(experiment=exp,context='Duna:FLYING_HIGH',canTransmit=False)
    exp.reading(); step2()
    assert saved['science_flight_samples']['p:0'] == 'Duna:SPACE_LOW'
    assert exp.HASDATA and exp.events[-1] == 'deploy'
    for link,power in ((False,True),(True,False),(False,False)):
        new['HOMECONNECTION'].ISCONNECTED=link;new['canTransmit']=power
        step2()
        assert exp.HASDATA and exp.events[-1]=='deploy'
    new['HOMECONNECTION'].ISCONNECTED=True;new['canTransmit']=True
    step2(); assert exp.events[-1]=='request' and not exp.HASDATA
    step2(); assert exp.events[-2:]==['reset','deploy']
    assert 'FLYING_HIGH' in saved['science_flight_pending']['p:0']
    assert all('delivered' not in key.lower() for key in saved)
    assert 'deliveryConfirmed=False' in FLIGHT and ':DUMP(' not in FLIGHT
    print('PASS: actual source preserves old readings through low power/lost link/reboot, records only obtained data, and queues transmission without inventing a delivery receipt or resetting pending data')


def check_retry_and_one_shot():
    env,saved,exp,step=instrument_fixture()
    step();env['TIME'].SECONDS+=9;step()
    assert exp.events==['deploy']
    env['context']='Duna:SPACE_LOW';env['TIME'].SECONDS+=100;step()
    assert exp.events==['deploy'] # slow animated request must not be cancelled
    env['TIME'].SECONDS=110;exp.DEPLOYED=False # native unavailable request ended
    step()
    assert exp.events==['deploy','deploy'] # unavailable result is retryable
    exp.reading();exp.transmitter=False;step()
    for seconds in (0,1,29):
        env['TIME'].SECONDS=110+seconds;step()
    assert exp.events.count('request')==1 and exp.HASDATA
    env['TIME'].SECONDS=140;step()
    assert exp.events.count('request')==2 and exp.HASDATA
    exp.transmitter=True;exp.RERUNNABLE=False;env['TIME'].SECONDS=170;step()
    assert exp.INOPERABLE and not exp.HASDATA
    prior=exp.events[:];env['context']='Duna:FLYING_LOW';step()
    assert exp.events==prior
    print('PASS: asynchronous/unavailable deployment retries at10s, unsuccessful queueing at30s; one-shot instruments become inoperable without an illicit reset')


def check_module_enumeration():
    calls=[]
    class Module:
        def __init__(self,typed):self.typed=typed
        def ISTYPE(self,name):return self.typed and name=='ScienceExperimentModule'
    modules=[Module(True),Module(False),Module(True)]
    part=NS(UID=KString('part-id'),MODULES=KList(modules),GETMODULEBYINDEX=modules.__getitem__)
    # KOS string concatenation coerces numeric index; translate that single
    # expression for this fixture, not the module enumeration/control flow.
    body=function_body(FLIGHT,'scienceFlightPulse').replace('part:UID+":"+index','instrumentKey(index)')
    execute(body,dict(context='test',canTransmit=True,ABORT=False,SHIP=NS(PARTS=[part]),
                     instrumentKey=lambda i:'part-id:'+str(i),
                     _scienceFlightStep=lambda *args:calls.append(args)))
    assert [row[1] for row in calls]==['part-id:0','part-id:2']
    print('PASS: multiple typed experiments on one part are discovered by unique module index; unsupported modules receive no science operations')


def entry_fixture():
    primary=NS(NAME='DUNA',ATM=NS(EXISTS=True,HEIGHT=50000))
    orbit=NS(BODY=primary,HASNEXTPATCH=False)
    ship=NS(BODY=primary,ORBIT=orbit,ALTITUDE=200000,STATUS='ESCAPING')
    env=dict(SHIP=ship,TIME=NS(SECONDS=100),SCIENCE_ENTRY_BANDS=Map(DUNA=KList([140000,12000])),
             SCIENCE_ENTRY_PREPARE_LEAD=180,SCIENCE_ENTRY_MOON='IKE',SCIENCE_ENTRY_MOON_MIN_PE=20000)
    return env,primary


def check_wakes_and_moon_geometry():
    env,primary=entry_fixture()
    etas={140000:200,50000:400}
    env['aerobrakeApEntryEta']=etas.__getitem__
    assert run(ENTRY,'_scienceEntryWakeUt',env)==300
    env['SHIP'].ORBIT=NS(HASNEXTPATCH=True,NEXTPATCHETA=100)
    assert run(ENTRY,'_scienceEntryWakeUt',env)==170
    etas[50000]=100
    assert run(ENTRY,'_scienceEntryWakeUt',env)==100 # preparation due now
    env.update(primary=primary)
    moon=NS(NAME='IKE')
    end=NS(BODY=primary,PERIAPSIS=5000,ETA=NS(PERIAPSIS=600),HASNEXTPATCH=False)
    ike=NS(BODY=moon,PERIAPSIS=25000,HASNEXTPATCH=True,NEXTPATCH=end,NEXTPATCHETA=400)
    start=NS(BODY=primary,HASNEXTPATCH=True,NEXTPATCH=ike,NEXTPATCHETA=200)
    env['SHIP'].ORBIT=start
    assert run(ENTRY,'_scienceEntryMoonCheck',env)
    for pe,pe_eta in ((60000,600),(5000,350),(5000,float('nan'))):
        end.PERIAPSIS=pe;end.ETA.PERIAPSIS=pe_eta
        assert not run(ENTRY,'_scienceEntryMoonCheck',env)
    end.PERIAPSIS=5000;end.ETA.PERIAPSIS=600
    end.HASNEXTPATCH=True;end.NEXTPATCHETA=550;end.NEXTPATCH=NS(BODY=NS(NAME='SUN'),HASNEXTPATCH=False)
    assert not run(ENTRY,'_scienceEntryMoonCheck',env) # Pe extrapolated beyond this patch
    end.NEXTPATCHETA=700
    assert run(ENTRY,'_scienceEntryMoonCheck',env)
    ike.PERIAPSIS=10000
    assert not run(ENTRY,'_scienceEntryMoonCheck',env)
    env['SCIENCE_ENTRY_MOON']=''
    assert run(ENTRY,'_scienceEntryMoonCheck',env)
    print('PASS: science/entry/SOI deadlines choose the earliest wake; native optional Ike must clear its floor and retain an actual future Duna Pe inside the same patch, not an extrapolated or past Pe')


def check_resident_wait():
    for alarm,healthy,interrupt in (('owned',True,''),('',True,''),('owned',False,''),
                                    ('owned',True,'abort'),('owned',True,'soi')):
        env,primary=entry_fixture();events=[]
        env.update(wakeUt=150,ABORT=False,WARP=0)
        def alarm_fn(*args):events.append('alarm');return alarm
        def solar(*args):
            assert events==['alarm'];events.append('solar');return 1
        def wait(dt):
            env['TIME'].SECONDS+=dt
            if interrupt=='abort':env['ABORT']=True
            if interrupt=='soi':env['SHIP'].BODY=NS(NAME='IKE')
        env.update(kacEnsureAlarm=alarm_fn,enterSolarCoast=solar,
                   solarCoastCanWarp=lambda *_:healthy,
                   coastAutoWarp=lambda *args:events.append(('warp',args[-1])),
                   trySolarHoldTick=lambda flow,*_:flow,fixture_wait=wait,
                   fixture_settled=lambda:None,DELETEALARM=lambda value:events.append(('delete',value)))
        run(ENTRY,'scienceEntryWait',env)
        assert (('warp','owned') in events)==(bool(alarm) and healthy)
        assert env['WARP']==0
        assert env['TIME'].SECONDS==(105 if interrupt else 150)
        assert (('delete','owned') in events)==bool(alarm)
    print('PASS: running wait owns its alarm before solar, requires that alarm plus power health to warp, resumes by clock without KAC and cleans up on wake/abort/SOI change')


def check_phase_lifecycle():
    for case in ('entry','surface','skipout','pass-limit','node','bad-config','abort'):
        env,primary=entry_fixture();saved={};events=[]
        cfg=read_settings(PROFILE,{})
        saved['mission_id']=cfg['MISSION_ID']
        env.update(cfg)
        env['ENTRY_POWERED_LANDING']=0 # Isolate shared science lifecycle; controller separately integrated.
        env['SCIENCE_ENTRY_BANDS']=Map({key:KList(value) for key,value in cfg['SCIENCE_ENTRY_BANDS'].items()})
        env.update(ABORT=False,HASNODE=False,WARP=4,SAS=True,xferSeq=KList(cfg['SEQUENCE']),
                   missionTargetBody=lambda:primary,thrustCutoffOk=lambda:events.append('cutoff') or True,
                   stateGet=lambda key,default='':saved.get(key,default),
                   stateGetNum=lambda key,default=0:saved.get(key,default),
                   stateSet=lambda key,value:saved.__setitem__(key,value),
                   LEXICON=lex,HOMECONNECTION=NS(ISCONNECTED=True),
                   ADDONS=NS(SCANSAT=NS(AVAILABLE=False)),shipPowerFraction=lambda:1,
                   fixture_settled=lambda:events.append('settled'),fixture_unlock=lambda:events.append('unlock'),
                   fixture_lock=lambda value:events.append(('lock',value)),
                   fixture_brakes=lambda:events.append('brakes'),
                   nextPhase=lambda *_:events.append('advance'),
                   _scienceEntryHold=lambda why:events.append(('hold',why)))
        ship=env['SHIP'];ship.PERIAPSIS=5000;ship.VERTICALSPEED=-200;ship.AIRSPEED=1200
        ship.THRUST=0;ship.CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0)
        env.update(KUNIVERSE=NS(ACTIVEVESSEL=ship),fixture_chutes=lambda:events.append('safe-chutes'),
                   _scienceEntryChutes=lambda primary:run(ENTRY,'_scienceEntryChutes',dict(env,primary=primary)))
        ship.ALTITUDE=30000
        def context():return run(ENTRY,'scienceEntryContext',env)
        def pulse(*args):events.append(('science',args[0]))
        def wait(dt):
            env['TIME'].SECONDS+=dt
            if case=='entry':
                ship.ALTITUDE=10000
                if env['TIME'].SECONDS>=102:env['ABORT']=True
        env.update(scienceFlightPulse=pulse,scienceEntryContext=context,fixture_wait=wait,
                   scienceEntrySample=lambda primary:run(ENTRY,'scienceEntrySample',dict(env,primary=primary)),
                   _scienceEntryWakeUt=lambda:run(ENTRY,'_scienceEntryWakeUt',env),
                   _scienceEntryMoonCheck=lambda primary:run(ENTRY,'_scienceEntryMoonCheck',dict(env,primary=primary)),
                   aerobrakeApEntryEta=lambda height:0 if ship.ALTITUDE<=height else -1)
        if case=='surface':ship.STATUS='LANDED'
        if case in ('skipout','pass-limit'):ship.ALTITUDE=100000
        if case=='pass-limit':saved.update(science_entry_id=cfg['MISSION_ID']+':0:DUNA',science_entry_passes=3)
        if case=='node':env['HASNODE']=True
        if case=='bad-config':env['SCIENCE_ENTRY_PREPARE_LEAD']=float('nan')
        if case=='abort':env['ABORT']=True
        # Only the language's implicit number->string coercion is adapted.
        body=function_body(ENTRY,'phaseScienceEntry').replace('stateGetNum("launch_time",0)','flightStamp()')
        body=re.sub(r'WAIT UNTIL [^.]+\.', 'fixture_settled().', body).replace('BRAKES ON.','fixture_brakes().')
        env['flightStamp']=lambda:'0'
        execute(body,env)
        assert env['WARP']==0
        if case=='entry':
            contexts=[row[1] for row in events if isinstance(row,tuple) and row[0]=='science']
            assert any('FLYING_HIGH' in ctx for ctx in contexts) and any('FLYING_LOW' in ctx for ctx in contexts)
            assert saved['science_entry_passes']==1 and 'advance' not in events
            assert ('lock','LOCK STEERING TO SHIP:SRFRETROGRADE') in events
            assert 'safe-chutes' in events
        elif case=='surface':
            assert events.count('advance')==1 and 'brakes' in events
            assert env['TIME'].SECONDS==160
        elif case=='skipout':assert ('hold','no-future-atmospheric-crossing') in events
        elif case=='pass-limit':assert ('hold','entry-pass-limit-without-touchdown') in events
        elif case=='node':assert ('hold','unexpected-maneuver-node') in events
        elif case=='bad-config':assert ('hold','invalid-entry-configuration') in events
        elif case=='abort':assert events==['settled']
        assert not any(isinstance(e,tuple) and e[0]=='warp' for e in events)
    print('PASS: actual phase samples high/low atmosphere at1x with live retrograde, preserves pass count on reboot, stops on abort/node/invalid config/skipout and advances only after surface science dwell')


def check_safe_chute_policy():
    for fault in ('ok','off','abort','warp','inactive','other-body','above-atmo','rising','level',
                  'landed','splashed','physical-thrust','pilot','raw','nan-alt','nan-vs','airless'):
        env,primary=entry_fixture();ship=env['SHIP'];requests=[]
        ship.ALTITUDE=30000;ship.VERTICALSPEED=-200;ship.THRUST=0
        ship.CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0)
        env.update(primary=primary,SCIENCE_ENTRY_CHUTES=1,ABORT=False,WARP=0,
                   KUNIVERSE=NS(ACTIVEVESSEL=ship),fixture_chutes=lambda:requests.append('native-safe'))
        if fault=='off':env['SCIENCE_ENTRY_CHUTES']=0
        if fault=='abort':env['ABORT']=True
        if fault=='warp':env['WARP']=1
        if fault=='inactive':env['KUNIVERSE'].ACTIVEVESSEL=NS()
        if fault=='other-body':ship.BODY=NS(NAME='IKE')
        if fault=='above-atmo':ship.ALTITUDE=50000
        if fault=='rising':ship.VERTICALSPEED=1
        if fault=='level':ship.VERTICALSPEED=0
        if fault=='landed':ship.STATUS='LANDED'
        if fault=='splashed':ship.STATUS='SPLASHED'
        if fault=='physical-thrust':ship.THRUST=1
        if fault=='pilot':ship.CONTROL.PILOTMAINTHROTTLE=.1
        if fault=='raw':ship.CONTROL.MAINTHROTTLE=.1
        if fault=='nan-alt':ship.ALTITUDE=float('nan')
        if fault=='nan-vs':ship.VERTICALSPEED=float('nan')
        if fault=='airless':primary.ATM.EXISTS=False
        run(ENTRY,'_scienceEntryChutes',env)
        assert requests==(['native-safe'] if fault=='ok' else []),(fault,requests)
    # The native setter, not a speed guessed by this script, selects which
    # of four stock chutes can open. Revisit rather than latch the first pass.
    safe=[True,False,True,False];opened=set()
    env,primary=entry_fixture();ship=env['SHIP']
    ship.ALTITUDE=30000;ship.VERTICALSPEED=-100;ship.THRUST=0
    ship.CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0)
    env.update(primary=primary,SCIENCE_ENTRY_CHUTES=1,ABORT=False,WARP=0,KUNIVERSE=NS(ACTIVEVESSEL=ship),
               fixture_chutes=lambda:opened.update(i for i,allowed in enumerate(safe) if allowed))
    run(ENTRY,'_scienceEntryChutes',env);assert opened=={0,2}
    safe[:]=[True]*4
    run(ENTRY,'_scienceEntryChutes',env);assert opened=={0,1,2,3}
    safe.clear();run(ENTRY,'_scienceEntryChutes',env) # No hardware is also a no-op.
    body=function_body(ENTRY,'_scienceEntryChutes')
    assert 'CHUTESSAFE ON.' in body and 'CHUTES ON.' not in body
    assert ':DOEVENT' not in body and 'STAGE.' not in body
    command=(ROOT/'cmd/entrychutes.ks').read_text()
    for enabled,mission,accepted in ((0,'test',True),(1,'test',True),(2,'test',False),(1,'',False)):
        changes=[]
        run(command,'_cmdEntrychutes',dict(enabled=enabled,RUNPATH=lambda *_:None,bootPreamble=lambda:None,
            stateGet=lambda *_:mission,LEXICON=lex,missionOverrideUpdate=changes.append))
        assert changes==([lex('SCIENCE_ENTRY_CHUTES',enabled)] if accepted else [])
    print('PASS: optional chute requests require primary-body descent,1x, active craft and idle thrust/controls; native CHUTESSAFE gates each deployment, repeats as safety changes, tolerates no chutes and flag command changes only its override')


def check_optional_flyby_sampling():
    command=(ROOT/'cmd/flybyscience.ks').read_text()
    for enabled in (0,1):
        env,primary=entry_fixture();calls=[]
        env.update(MISSION_ASSIST_SCIENCE=enabled,SCIENCE_ENTRY_MIN_EC=.05,
                   scienceFlightPulse=lambda *args:calls.append(args),
                   scienceEntryContext=lambda:env['SHIP'].BODY.NAME,shipPowerFraction=lambda:1,
                   primary=primary)
        run(ENTRY,'scienceEntrySample',env)
        assert calls==[('DUNA',True)]
        env['SHIP'].BODY=NS(NAME='IKE')
        run(ENTRY,'scienceEntrySample',env)
        assert calls==([('DUNA',True),('IKE',True)] if enabled else [('DUNA',True)])
        # Turning sampling off must not waive the same native encounter gate.
        env['SHIP'].ORBIT=NS(BODY=env['SHIP'].BODY,PERIAPSIS=10000,HASNEXTPATCH=False)
        assert not run(ENTRY,'_scienceEntryMoonCheck',env)
    for enabled,mission,accepted in ((0,'duna_impactor',True),(1,'duna_impactor',True),
                                    (0,'duna_science_impact',True),(-1,'duna_impactor',False),
                                    (2,'duna_impactor',False),(1,'',False)):
        saved=dict(mission_id=mission,phase='ASSIST_COAST',launch_time=1000,soi_alarm_id='owned')
        settings=dict(AEROBRAKE_AP_RESERVE_DV=10,BPLANE_TRIM_RESERVE_DV=50,
                      MISSION_ASSIST_SCIENCE=1)
        writes=[]
        def update(values):writes.append(dict(values));settings.update(values)
        env=dict(enabled=enabled,RUNPATH=lambda *_:None,bootPreamble=lambda:None,
                 stateGet=saved.get,LEXICON=lex,missionOverrideUpdate=update)
        before=saved.copy();run(command,'_cmdFlybyscience',env)
        assert saved==before and bool(writes)==accepted
        if accepted:assert writes==[dict(MISSION_ASSIST_SCIENCE=enabled)]
        assert settings['AEROBRAKE_AP_RESERVE_DV']==10 and settings['BPLANE_TRIM_RESERVE_DV']==50
    print('PASS: one persisted boolean controls optional moon science, primary science always samples, disabled science retains unsafe-Ike refusal, and command preserves mission/phase/alarms/budgets')


if __name__=='__main__':
    check_profile_and_boot()
    check_data_lifecycle()
    check_retry_and_one_shot()
    check_module_enumeration()
    check_wakes_and_moon_geometry()
    check_resident_wait()
    check_phase_lifecycle()
    check_optional_flyby_sampling()
    check_safe_chute_policy()
