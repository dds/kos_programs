"""Multi-pass entry alarms and return hardware setup; source fixtures, not KSP."""
import math
import re
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_codebase import ROOT, function_body, dependency_tables, closure
from check_aerobrake_assist import fixture as flight_fixture, AERO

PHASES = (ROOT/'lib/phases.ks').read_text()
COMMAND = (ROOT/'cmd/aeroassist.ks').read_text()


class Seq(list):
    LENGTH = property(len)


class Map(dict):
    LENGTH = property(len)
    HASKEY = dict.__contains__
    ADD = dict.__setitem__


class Number(float):
    def __radd__(self, other):
        return other+str(float(self)) if isinstance(other,str) else other+float(self)


def execute(source, env):
    source = re.sub(r'PARAMETER [^.]+\.', '', source)
    def strip(nodes):
        return [(text,strip(yes),strip(no)) for text,yes,no in nodes
                if not text.startswith('PRINT ')]
    try: ks.run(strip(ks.parse(source)),env)
    except ks.Returned as result: return result.value


def alarm_fixture(env):
    alarms, events = {}, []
    serial = [0]
    def add(kind, ut, name, note):
        serial[0] += 1
        alarm = NS(ID=str(serial[0]), TIME=ut, NAME=name, NOTES=note, ACTION='')
        alarms[alarm.ID] = alarm
        events.append(('alarm',name,ut))
        return alarm
    def delete(key):
        alarms.pop(key)
    env.update(ADDONS=NS(KAC=NS(AVAILABLE=True)), ADDALARM=add, DELETEALARM=delete,
               LISTALARMS=lambda _:list(alarms.values()), AEROBRAKE_ENTRY_LEAD=900,
               ROUND=lambda x,n=0:Number(round(x,n)), ATM_HEIGHTS=Map(Kerbin=70000))
    env['SHIP'].NAME = 'RO9'
    env['SHIP'].BODY.ATM = NS(EXISTS=True, HEIGHT=70000)
    env['kacShipAlarmName'] = lambda name: execute(function_body(PHASES,'kacShipAlarmName'),dict(env,almName=name))
    env['kacEnsureAlarm'] = lambda name,ut,note: execute(function_body(PHASES,'kacEnsureAlarm'),dict(env,almName=name,almUt=ut,almNote=note,reuseTolerance=60))
    env['_aerobrakeAtmoHeight'] = lambda: execute(function_body(AERO,'_aerobrakeAtmoHeight'),dict(env))
    env['_aerobrakeSetEntryAlarm'] = lambda: execute(function_body(AERO,'_aerobrakeSetEntryAlarm'),dict(env))
    return alarms, events


def entry_alarm(alarms):
    found = [a for a in alarms.values() if a.NAME=='RO9: Atmo entry: Kerbin']
    assert len(found)==1
    return found[0]


def check_conic_alarm_and_reboot():
    env,sim,_,refresh = flight_fixture(before_entry=180)
    alarms,events = alarm_fixture(env)
    alarms['other'] = NS(ID='other',NAME='RO9-Minmus3: Burn',TIME=999999,ACTION='KillWarp')
    alarms['stale'] = NS(ID='stale',NAME='RO9: Atmo entry: Kerbin',TIME=-1,ACTION='KillWarp')
    when = env['_aerobrakeSetEntryAlarm']()
    assert abs(when-180)<.001 and entry_alarm(alarms).TIME==when
    assert 'stale' not in alarms and 'other' in alarms
    alarm_id = entry_alarm(alarms).ID
    assert entry_alarm(alarms).ACTION=='KillWarp'
    assert env['_aerobrakeSetEntryAlarm']()==when and entry_alarm(alarms).ID==alarm_id
    # Same ellipse, now outbound: ETA:Pe wraps, and the next INBOUND
    # atmosphere crossing must be alarmed, not the exit just observed.
    period = 2*math.pi*math.sqrt(((653000+47600000)/2)**3/3.5316e12)
    env['ETA'].PERIAPSIS = period-env['ETA'].PERIAPSIS
    env['SHIP'].VELOCITY.ORBIT = -env['SHIP'].VELOCITY.ORBIT
    when = env['_aerobrakeSetEntryAlarm']()
    assert when>180 and when<period and entry_alarm(alarms).TIME==when
    assert entry_alarm(alarms).ID!=alarm_id and 'other' in alarms and len(alarms)==2
    env['ADDONS'].KAC.AVAILABLE=False
    assert env['_aerobrakeSetEntryAlarm']()==when # Clock wait still has a deadline.
    for invalid in (0,-1,math.nan,math.inf):
        before=dict(alarms)
        env['aerobrakeApEntryEta']=lambda _,value=invalid:value
        assert env['_aerobrakeSetEntryAlarm']()==-1 and alarms==before
    env['SHIP'].BODY.ATM.EXISTS=False
    assert env['_aerobrakeSetEntryAlarm']()==-1
    print('PASS: real conic entry alarm handles inbound/outbound ellipses, replaces stale times, reuses on reboot, preserves other craft alarms, and retains a clock deadline without KAC; invalid/no-crossing epochs never fabricate an alarm')


def check_multi_pass_order():
    env,sim,_,refresh = flight_fixture(before_entry=100)
    alarms,events = alarm_fixture(env)
    env['TIME'].SECONDS=1000
    times=[1100,9000,22000]
    exits=[0]
    ship=env['SHIP']
    ship.ALTITUDE=80000;ship.AIRSPEED=3200
    ship.ORBIT.APOAPSIS=35000000
    def eta(_):
        assert ship.ORBIT.ECCENTRICITY<1, 'alarm forecast ran before capture repair'
        return times[exits[0]]-env['TIME'].SECONDS
    def coast(ut):
        assert entry_alarm(alarms).TIME==times[exits[0]]
        events.append(('solar',ut))
        env['TIME'].SECONDS=max(env['TIME'].SECONDS,ut)
    def orient():
        if ship.ALTITUDE>70000:
            ship.ALTITUDE=60000
        elif exits[0]<2:
            exits[0]+=1;ship.ALTITUDE=80000
            if exits[0]==1:ship.ORBIT.ECCENTRICITY=1.01
        else:
            ship.ORBIT.APOAPSIS=65000;ship.AIRSPEED=500
    def capture():
        events.append(('capture',))
        ship.ORBIT.ECCENTRICITY=.9
    env.update(aerobrakeApEntryEta=eta, aerobrakeApRecover=lambda:True,
               aerobrakeApObserve=lambda _:None, _aerobrakeSolarWait=coast,
               _aerobrakeOrient=orient, _aerobrakeBrakingBurn=capture,
               _aerobrakeTrimReentryPe=lambda:None, _aerobrakeDecouple=lambda:None,
               _aerobrakeRetractSolarPanels=lambda:None, _aerobrakeRetractAntennas=lambda:None,
               _aerobrakeCloseExtendBays=lambda:None, _aerobrakeAdvance=lambda:events.append(('advance',)),
               AEROBRAKE_PE_TARGETING=0,AEROBRAKE_TARGETING=0,AEROBRAKE_AP_BURN=0,
               phaseShouldYield=False,AEROBRAKE_BRAKE_PE_FLOOR=52000,AEROBRAKE_PE=53000,
               REENTRY_PE=53000,AEROBRAKE_CORRECTION_PE_MIN=52000,AEROBRAKE_CORRECTION_PE_MAX=54000,
               AEROBRAKE_HANDOFF_SPEED=600,fixture_wait=lambda dt:setattr(env['TIME'],'SECONDS',env['TIME'].SECONDS+dt))
    env['_aerobrakeAwaitEntry']=lambda alt,inside,stage:execute(function_body(AERO,'_aerobrakeAwaitEntry'),dict(env,atmHeight=alt,inPass=inside,entryStage=stage))
    env['_aerobrakeThroughThickPart']=lambda alt:execute(function_body(AERO,'_aerobrakeThroughThickPart'),dict(env,atmHeight=alt))
    source=function_body(AERO,'phaseAerobrake')
    execute(source,env)
    created=[e[2] for e in events if e[0]=='alarm']
    assert created==times,(created,events)
    assert events.index(('capture',))<events.index(('alarm','RO9: Atmo entry: Kerbin',9000))<events.index(('solar',8100))
    assert events.index(('alarm','RO9: Atmo entry: Kerbin',22000))<events.index(('solar',21100))
    assert env['passNum']==3 and events[-1]==('advance',) and len(alarms)==1
    print('PASS: three real phase-loop passes refresh next-entry KillWarp alarms after exits/capture repair and before solar holds; no per-tick alarm churn, no duplicate or prompt exit, 900s entry-based preparation preserved')


def check_manual_stage_wait():
    source=function_body(AERO,'_aerobrakeAwaitEntry')
    for event in ('stage','entry','abort','hold','landed','in-pass'):
        env,sim,data,refresh=flight_fixture(before_entry=180)
        env.update(atmHeight=70000,inPass=event=='in-pass',entryStage=1)
        count=[0]
        def wait(dt):
            assert dt==.5
            env['TIME'].SECONDS+=dt;count[0]+=1
            if count[0]==2:
                if event=='stage':env['STAGE'].NUMBER=0
                if event=='entry':env['SHIP'].ALTITUDE=69999
                if event=='abort':env['ABORT']=True
                if event=='hold':env['phaseShouldYield']=True
                if event=='landed':env['SHIP'].STATUS='LANDED'
        env['fixture_wait']=wait
        assert execute(source,env)==(event=='stage'),event
        assert count[0]==(0 if event=='in-pass' else 2)
        assert data=={} # Wait cannot reset the pass latch or arm a burn.
    phase=function_body(AERO,'phaseAerobrake')
    change=phase.index('IF _aerobrakeAwaitEntry(')
    assert change<phase.index('_aerobrakeSetEntryAlarm()',change)
    assert 'thrustCutoffOk()' in phase[change:phase.index('stage-changed-replan',change)]
    assert 'aerobrake_ap_pass_used' not in source+phase
    print('PASS: real pre-entry wait detects manual staging within0.5s, returns to fresh alarm/planning at verified zero thrust, preserves the pass latch and responds to entry/Abort/hold/landing')


def check_manual_stage_phase_replan():
    env,sim,data,refresh=flight_fixture(before_entry=100)
    alarms,events=alarm_fixture(env)
    ship=env['SHIP'];ship.ALTITUDE=80000;ship.AIRSPEED=3000;ship.ORBIT.APOAPSIS=1e6
    env['STAGE'].NUMBER=3
    expected=[100.];plans=[];waits=[0]
    def coast(when):env['TIME'].SECONDS=max(env['TIME'].SECONDS,when)
    def wait(dt):
        env['TIME'].SECONDS+=dt;waits[0]+=1
        assert waits[0]<4,'manual stage failed to reach fresh planning'
        if waits[0]==1:
            env['STAGE'].NUMBER=2;ship.MASS=.7
            expected[0]=env['TIME'].SECONDS+200
        else:ship.ALTITUDE=69999
    def assist(*args):
        plans.append((env['STAGE'].NUMBER,ship.MASS,entry_alarm(alarms).TIME))
        if len(plans)==2:
            expected[0]=env['TIME'].SECONDS+80 # A powered arc changed entry.
            return dict(OK=True,ENTERED=False)
        return dict(OK=False,REASON='fixture-no-burn')
    def orient():
        if ship.ALTITUDE<70000:ship.ORBIT.APOAPSIS=65000;ship.AIRSPEED=500
    env.update(aerobrakeApEntryEta=lambda _:expected[0]-env['TIME'].SECONDS,
               aerobrakeApRecover=lambda:True,_aerobrakeSolarWait=coast,
               aerobrakeApStageCoast=lambda *args:False,aerobrakeApAssist=assist,
               _aerobrakeOrient=orient,_aerobrakeTrimReentryPe=lambda:None,
               _aerobrakeDecouple=lambda:None,_aerobrakeRetractSolarPanels=lambda:None,
               _aerobrakeRetractAntennas=lambda:None,_aerobrakeCloseExtendBays=lambda:None,
               _aerobrakeAdvance=lambda:events.append(('advance',)),
               AEROBRAKE_AP_BURN=1,AEROBRAKE_PE_TARGETING=0,AEROBRAKE_TARGETING=0,
               AEROBRAKE_BRAKE_PE_FLOOR=52000,AEROBRAKE_PE=53000,REENTRY_PE=53000,
               AEROBRAKE_CORRECTION_PE_MIN=52000,AEROBRAKE_CORRECTION_PE_MAX=54000,
               AEROBRAKE_HANDOFF_SPEED=600,fixture_wait=wait)
    env['_aerobrakeAwaitEntry']=lambda alt,inside,stage:execute(function_body(AERO,'_aerobrakeAwaitEntry'),dict(env,atmHeight=alt,inPass=inside,entryStage=stage))
    env['_aerobrakeThroughThickPart']=lambda alt:execute(function_body(AERO,'_aerobrakeThroughThickPart'),dict(env,atmHeight=alt))
    execute(function_body(AERO,'phaseAerobrake'),env)
    assert plans==[(3,1.,100.),(2,.7,200.5)],plans
    assert events[-1]==('advance',) and len(alarms)==1 and not data
    assert entry_alarm(alarms).TIME==100.5
    assert [e[2] for e in events if e[0]=='alarm']==[100.,200.5,100.5]
    print('PASS: complete phase loop replans after manual3→2 separation, refreshes entry alarm for the new stage AND the pre-entry powered arc, then enters descent normally; no duplicate pass/reset or prompt exit')


def hardware_fixture():
    separator=NS(HASMODULE=lambda name:name=='ModuleDecouple',ISDECOUPLED=False,STAGED=True,STAGE=1)
    chute=NS(HASMODULE=lambda name:name=='ModuleParachute',DECOUPLEDIN=-1)
    tags={'return_decoupler':Seq([separator]),'descent_chutes':Seq([chute])}
    state=dict(phase='AEROBRAKE',mission_id='kerbin_return',launch_time=2446359)
    updates=[]
    env=dict(enabled=1,descentTag='return_decoupler',ABORT=False,
             SHIP=NS(PARTSTAGGED=lambda tag:tags.get(tag,Seq()),THRUST=0,
                     CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0)),
             CORE=NS(PART=NS(DECOUPLEDIN=-1)),LEXICON=lambda *args:Map(zip(args[::2],args[1::2])),
             RUNPATH=lambda _:None,bootPreamble=lambda:None,stateGet=state.get,
             missionOverrideUpdate=lambda values:updates.append(dict(values)))
    return env,state,updates,tags


def check_hardware_policy():
    body=function_body(COMMAND,'_cmdAeroassist')
    env,state,updates,tags=hardware_fixture()
    execute(body,env)
    assert updates==[dict(AEROBRAKE_AP_BURN=1,DESCENT_DECOUPLER_TAG='return_decoupler')]
    assert state==dict(phase='AEROBRAKE',mission_id='kerbin_return',launch_time=2446359)
    for change in (
        lambda e,s,t:e.update(enabled=123), lambda e,s,t:s.update(phase='DESCENT'),
        lambda e,s,t:e.update(ABORT=True), lambda e,s,t:setattr(e['SHIP'],'THRUST',1),
        lambda e,s,t:setattr(e['SHIP'].CONTROL,'MAINTHROTTLE',.1),
        lambda e,s,t:setattr(e['SHIP'].CONTROL,'PILOTMAINTHROTTLE',.1),
        lambda e,s,t:t.pop('return_decoupler'),
        lambda e,s,t:t['return_decoupler'].append(t['return_decoupler'][0]),
        lambda e,s,t:setattr(t['return_decoupler'][0],'HASMODULE',lambda _:False),
        lambda e,s,t:setattr(t['return_decoupler'][0],'ISDECOUPLED',True),
        lambda e,s,t:setattr(t['return_decoupler'][0],'STAGED',False),
        lambda e,s,t:setattr(t['return_decoupler'][0],'STAGE',-1),
        lambda e,s,t:setattr(e['CORE'].PART,'DECOUPLEDIN',1),
        lambda e,s,t:t.pop('descent_chutes'),
        lambda e,s,t:setattr(t['descent_chutes'][0],'HASMODULE',lambda _:False),
        lambda e,s,t:setattr(t['descent_chutes'][0],'DECOUPLEDIN',1)):
        env,state,updates,tags=hardware_fixture();change(env,state,tags)
        before=dict(state);execute(body,env)
        assert not updates and state==before
    env,state,updates,tags=hardware_fixture()
    env.update(enabled=0,descentTag='')
    execute(body,env)
    assert updates==[dict(AEROBRAKE_AP_BURN=0)] # Existing boolean command unchanged.
    assert not re.search(r'(?<!:)\b(?:STAGE|REBOOT|LOCK|REMOVE)\b', re.sub(r'"[^"\n]*"|//[^\n]*','',COMMAND))
    print('PASS: optional aeroassist tag saves only the requested enable/final-separator overrides, preserves phase/budget/altitude intent, refuses16 invalid/control/CPU/chute hazards, and never fires hardware; legacy boolean calls unchanged')


def check_solar_dependency_and_wait():
    deps,phases,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    env=dict(db='LAUNCH',SEQUENCE=Seq(['AEROBRAKE','DESCENT','DONE']),LIBS=Seq(),
             phaseSequenceEnsurePrelaunch=lambda sequence:sequence,bootEnsureInitialPhase=lambda _:None,
             stateGet=lambda key,default='':'AEROBRAKE' if key=='phase' else default,
             stateSet=lambda *_:None,bootLibBandForPhase=lambda *_:'AEROBRAKE',
             bootLibBandRoots=lambda _:Seq(phases['aerobrake']),
             missionTypeConditionalRoots=lambda _:Seq(),missionTypeCacheRoots=lambda _:Seq(),missionExtraLibs=lambda:Seq(),
             bootLibResolve=lambda roots:Seq(closure(roots,deps)),
             missionAppendUnique=lambda dest,items:dest.extend(x for x in items if x not in dest))
    libs=execute(function_body((ROOT/'lib/boot_lib.ks').read_text(),'bootPlannedMissionLibs'),env)
    assert 'solar' in libs and 'solar_diagnostics' in libs
    # Reproduce the installed planner seeing a generated profile before the
    # craft script can supply LIBS_EXTRA; the phase itself now owns solar.
    for loaded,panels in ((True,True),(True,False),(False,True)):
        events=[]
        def have_panels():
            assert loaded,'called an unloaded solar helper'
            return panels
        env=dict(wakeUt=200,TIME=NS(SECONDS=0),WARP=0,
                 SHIP=NS(ALTITUDE=80000,STATUS='ORBITING'),PHASES_HAS_SOLAR=loaded,
                 shipHasSolarPanels=have_panels,_aerobrakeAtmoHeight=lambda:70000,
                 orientForSolar=lambda force,lock,override,wake:events.append(('aim',wake)) or True,
                 shipSolarFlow=lambda:1,shipPowerFraction=lambda:1,SOLAR_HOLD_EC=.75,
                 coastAutoWarp=lambda wake,*_:events.append(('warp',wake)),
                 trySolarHoldTick=lambda ref,wake:ref,fixture_unlock=lambda:None,fixture_settle=lambda:None)
        env['fixture_wait']=lambda dt:setattr(env['TIME'],'SECONDS',env['TIME'].SECONDS+dt)
        source=function_body(AERO,'_aerobrakeSolarWait')
        source=source.replace('WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.','fixture_settle().')
        source=source.replace('UNLOCK STEERING.','fixture_unlock().')
        execute(source,env)
        assert env['TIME'].SECONDS==200 and events.count(('aim',200))==int(loaded and panels)
        if not loaded:assert env['reason']=='solar-library-not-loaded'
        elif not panels:assert env['reason']=='no-supported-solar-panels'
    print('PASS: profile-first AEROBRAKE boot resolves/caches solar independently of late craft extras; supported panels receive an explicit aim and wake deadline, missing helpers/panels retain the clock wait with distinct diagnostics')


if __name__=='__main__':
    check_conic_alarm_and_reboot()
    check_multi_pass_order()
    check_manual_stage_wait()
    check_manual_stage_phase_replan()
    check_hardware_policy()
    check_solar_dependency_and_wait()
