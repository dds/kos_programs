"""Execute transfer checkpoint/hold source; no KSP or KAC integration runner."""
import math
import re
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_codebase import ROOT, function_body, dependency_tables, closure
from check_runtime_contracts import KList, run

MID = (ROOT/'lib/midcourse.ks').read_text()
CAPTURE = (ROOT/'lib/capture.ks').read_text()
PHASES = (ROOT/'lib/phases.ks').read_text()
BOOT = (ROOT/'lib/boot_lib.ks').read_text()
ARRIVAL = (ROOT/'lib/arrival_bplane.ks').read_text()
SOURCE = '\n'.join((MID,CAPTURE,PHASES,BOOT,ARRIVAL))
# Console output has no role in these decisions. Keep function/branch source.
SOURCE = re.sub(r'\bPRINT\s+(?:"[^"]*"|[^."])*\.', '', SOURCE)
SOURCE = SOURCE.replace('UNLOCK STEERING.', 'fixture_unlock().')
ks.SOURCES += '\n'+SOURCE


def environment():
    saved,events,alarms = {},[],{}
    moon=NS(NAME='Mun')
    native=NS(HASNEXTPATCH=True,NEXTPATCHETA=10000,
              NEXTPATCH=NS(BODY=moon,HASNEXTPATCH=False))
    hit=dict(entryUt=11000,patch=NS(PERIAPSIS=15000))
    env=dict(TIME=NS(SECONDS=1000), ABORT=False, SHIP=NS(BODY='Kerbin',ORBIT=native,
             STATUS='ESCAPING'), ROUND=round, LIST=lambda *xs:KList(xs),
             stateGet=saved.get,stateGetNum=saved.get,
             stateSet=lambda key,value:saved.update({key:value}),
             stateRemove=lambda key:saved.pop(key,None),
             ADDONS=NS(KAC=NS(AVAILABLE=True)),
             missionTargetBody=lambda:moon,_bplaneTargetBody=lambda:moon,
             findArrivalPatch=lambda node,target:hit,
             nextPhase=lambda seq:events.append(('advance',seq)),
             xferSeq=KList(('BPLANE','COAST_1HALF','REFINE_BPLANE','COAST_2HALF')),
             PHASES_HAS_SOLAR=True,fixture_unlock=lambda:None,
             trySolarHoldTick=lambda ref,deadline=0:ref,
             shipHasSolarPanels=lambda:True,shipSolarFlow=lambda:1,
             shipPowerFraction=lambda:.5,
             HUDTEXT=lambda *_:None,YELLOW='yellow')
    env.update({name:float(value) for name,value in re.findall(
        r'GLOBAL (\w+) IS (\d+(?:\.\d+)?)\.',SOURCE)})
    def alarm(name,ut,note):
        events.append(('alarm',name,ut,note))
        if not env['ADDONS'].KAC.AVAILABLE:return ''
        alarms[name]=(ut,note)
        return name
    env['kacEnsureAlarm']=alarm
    env['DELETEALARM']=lambda key:alarms.pop(key,None)
    for name in ('midcourseRefineUt','midcourseClearReviewAlarm','_transferArrivalUt',
                 '_bplaneScheduleHoldReview','_enterSolarCoast','_coastHealthPoll','coastHealthCheck'):
        env[name]=lambda *args,name=name:ks.call(name,env,*args)
    return env,saved,events,alarms,moon,hit


def check_checkpoint_persistence():
    env,saved,_,_,_,_=environment()
    assert env['midcourseRefineUt'](1000,11000)==6000
    for now,expected in ((2500,6000),(6500,6500)):
        env['TIME'].SECONDS=now
        assert env['midcourseRefineUt'](now,11000)==expected
        assert saved['midcourse_refine_ut']==6000
    assert env['midcourseRefineUt'](6500,21000)==13750
    assert saved['midcourse_refine_arrival_ut']==21000
    assert env['midcourseRefineUt'](6500,6800)==6500
    # Actual unburned patch takes priority over an old XING estimate.
    saved.update(xing_arrival_ut=16000,xing_arrival_target='Mun')
    env['TIME'].SECONDS=1000
    assert env['_transferArrivalUt'](NS(NAME='Mun'))==11000
    assert saved['xing_arrival_ut']==11000
    print('PASS: review/coast checkpoint is anchored across reboots, overdue checkpoints refine now, changed arrivals re-anchor, live patch wins over departure estimate')


def check_arrival_hold_alarm():
    for interrupted in (False,True):
        env,saved,events,alarms,_,_=environment()
        saved['phase']='BPLANE'
        env.update(HASNODE=interrupted,maneuverBurnInterrupted=lambda:interrupted,
                   yieldToPrompt=lambda:events.append(('yield',)))
        ks.call('_bplaneHoldCorrection',env,'unconverged-optional-correction')
        assert events[-1]==('yield',) and saved['phase']=='BPLANE'
        ut,note=alarms['Arrival review: Mun']
        assert ut==6000 and 'does not resume' in note
        assert saved['midcourse_refine_ut']==6000
        env['TIME'].SECONDS=2500
        env['_bplaneScheduleHoldReview']('unconverged-optional-correction')
        assert len(alarms)==1 and alarms['Arrival review: Mun'][0]==6000
        env['TIME'].SECONDS=6500
        env['_bplaneScheduleHoldReview']('unconverged-optional-correction')
        assert alarms['Arrival review: Mun'][0]==6501  # Immediate review, not a later midpoint.
        assert saved['midcourse_refine_ut']==6000
        env['midcourseClearReviewAlarm']()
        assert not alarms and 'arrival_review_alarm' not in saved
    for unavailable in ('kac','patch','past','nan'):
        env,saved,_,alarms,_,hit=environment()
        if unavailable=='kac':env['ADDONS'].KAC.AVAILABLE=False
        if unavailable=='patch':env['findArrivalPatch']=lambda *_:0
        if unavailable in ('past','nan'):hit['entryUt']=0 if unavailable=='past' else math.nan
        env['_bplaneScheduleHoldReview']('test')
        assert not alarms
    print('PASS: arrival hold yields with a named anchored review alarm; interrupted node remains owned; missing timing/KAC cannot invent automatic resumption')


def check_alarm_before_solar():
    env,saved,events,alarms,_,_=environment()
    saved['arrival_review_alarm']='Arrival review: Mun'
    alarms['Arrival review: Mun']=(6000,'held')
    def solar(label,orient,health,deadline):
        assert deadline==6000 and 'Arrival review: Mun' not in alarms
        assert alarms['Midcourse refine: Mun'][0]==deadline
        events.append(('solar',deadline))
        env['TIME'].SECONDS=deadline
        return 1
    env['_enterSolarCoast']=solar
    def wait(target,ut,poll,alarm,ref):
        assert env['TIME'].SECONDS==ut==6000 and alarm=='Midcourse refine: Mun'
        events.append(('wait',ut))
    env['_waitUntilOrSOI']=wait
    ks.call('phaseCoast1Half',env)
    assert [row[0] for row in events]==['alarm','solar','wait','advance']
    assert not alarms
    events.clear()
    env['SHIP'].ORBIT.NEXTPATCHETA=11000-env['TIME'].SECONDS
    ks.call('phaseCoast1Half',env)
    assert [row[0] for row in events]==['advance'],'overdue checkpoint cannot start another solar wait'
    deps,_,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    assert 'midcourse' in closure(['arrival_bplane'],deps) & closure(['capture'],deps)
    assert 'capture' not in closure(['arrival_bplane'],deps)
    print('PASS: automatic coast installs its alarm before solar work, shares the wake deadline, cleans review alarm and advances immediately when overdue')


def check_solar_and_health_deadlines():
    env,_,events,_,_,_=environment()
    env.update(SOLAR_CHARGE_FULL_EC=.995,SOLAR_CHARGE_CHECK_DT=5,
               SOLAR_CHARGE_CHECK_MIN_DELTA=.01)
    deadline=1003
    def charging(dt,delta):
        env['TIME'].SECONDS+=dt
        events.append(('charging',dt))
        return False
    def orient(force,lock,override,wake):
        assert wake==deadline
        events.append(('aim',wake))
        env['TIME'].SECONDS=wake
        return False
    env.update(shipBatteriesCharging=charging,orientForSolar=orient,
               fixture_wait=lambda dt:setattr(env['TIME'],'SECONDS',env['TIME'].SECONDS+dt))
    assert not env['coastHealthCheck']('test',deadline)
    assert events==[('charging',3)] and env['TIME'].SECONDS==deadline
    events.clear();env['TIME'].SECONDS=1000
    env['_enterSolarCoast']('COAST_1HALF',True,True,deadline)
    assert events==[('aim',deadline)] and env['TIME'].SECONDS==deadline
    # No wait after a full battery drops at the deadline, either.
    env['TIME'].SECONDS=1000;events.clear()
    env['shipPowerFraction']=lambda:1 if env['TIME'].SECONDS<deadline else .5
    assert not env['coastHealthCheck']('test',deadline)
    assert not events and env['TIME'].SECONDS==deadline
    wait=function_body(CAPTURE,'_waitUntilOrSOI')
    assert 'trySolarHoldTick(solarRef, targetUt)' in wait
    assert 'trySolarHoldTick(solarRef, midUt)' in wait
    print('PASS: solar alignment and health/readout waits cannot consume a passed midpoint budget; maintenance re-aims inherit the wake time')


def check_boot_hold_returns_prompt():
    for held in (False,True):
        env=dict(hl=False,bootCheckManualKey=lambda:True,phaseShouldYield=held,
                 BOOT_MANUAL_REQUESTED=False,HOMECONNECTION=NS(ISCONNECTED=False),
                 stateGet=lambda *_:'BPLANE')
        run(function_body(SOURCE,'bootResumeOrManual'),env)
        assert env['BOOT_MANUAL_REQUESTED']==held
    boot=function_body(BOOT,'bootResumeOrManual')
    assert boot.index('IF phaseShouldYield')>boot.index('resumeMission()')
    installed=(ROOT/'boot/boot.ks').read_text()
    tail=installed[installed.index('LOCAL tailSolarInSpace'):]
    assert 'IF NOT BOOT_MANUAL_REQUESTED' in tail
    assert 'RUNPATH("0:/cmd/orientForSolar.ks")' in tail
    print('PASS: deliberate phase yield uses the installed boot manual flag to suppress indefinite tail solar hold without replacing boot.ks')


def check_expired_alarm_replacement():
    for previous,reuse in ((1001,True),(999,False),(2000,False)):
        removed,created=[],[]
        old=NS(TIME=previous,NAME='RO9: review',ID='old')
        new=NS(ID='new',ACTION='')
        def add(*args):created.append(args);return new
        env=dict(TIME=NS(SECONDS=1000),ADDONS=NS(KAC=NS(AVAILABLE=True)),
                 kacShipAlarmName=lambda name:'RO9: '+name,
                 LISTALARMS=lambda _: [old], DELETEALARM=removed.append,ADDALARM=add)
        result=ks.call('kacEnsureAlarm',env,'review',1002,'operator review')
        assert result==('old' if reuse else 'new')
        assert removed==([] if reuse else ['old'])
        assert len(created)==(0 if reuse else 1)
        if not reuse:assert new.ACTION=='KillWarp'
    print('PASS: near-time future KAC alarms reuse their ID; expired or shifted alarms are replaced rather than mistaken for a future wake')


if __name__=='__main__':
    check_checkpoint_persistence()
    check_arrival_hold_alarm()
    check_alarm_before_solar()
    check_solar_and_health_deadlines()
    check_boot_hold_returns_prompt()
    check_expired_alarm_replacement()
