"""Execute transfer checkpoint/hold source; no KSP or KAC integration runner."""
import math
import re
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_codebase import ROOT, function_body, dependency_tables, closure
from check_runtime_contracts import KList, run

MID = (ROOT/'lib/midcourse.ks').read_text()
CAPTURE = (ROOT/'lib/capture.ks').read_text()
COAST = (ROOT/'lib/coast_wait.ks').read_text()
PHASES = (ROOT/'lib/phases.ks').read_text()
BOOT = (ROOT/'lib/boot_lib.ks').read_text()
ARRIVAL = (ROOT/'lib/arrival_bplane.ks').read_text()
SOURCE = '\n'.join((MID,CAPTURE,COAST,PHASES,BOOT,ARRIVAL))
# Console output has no role in these decisions. Keep function/branch source.
SOURCE = re.sub(r'\bPRINT\s+(?:"[^"]*"|[^."])*\.', '', SOURCE)
SOURCE = SOURCE.replace('UNLOCK STEERING.', 'fixture_unlock().')
SOURCE = SOURCE.replace('REMOVE nd.', 'fixture_remove(nd).')
SOURCE = SOURCE.replace('WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.', 'fixture_settle().')
ks.SOURCES += '\n'+SOURCE


class Lex(dict):
    LENGTH=property(len)


def environment():
    saved,events,alarms = {},[],{}
    moon=NS(NAME='Mun',ATM=NS(EXISTS=False),RADIUS=200000,SOIRADIUS=2429559)
    native=NS(HASNEXTPATCH=True,NEXTPATCHETA=10000,
              NEXTPATCH=NS(BODY=moon,HASNEXTPATCH=False))
    hit=dict(entryUt=11000,patch=NS(PERIAPSIS=15000))
    env=dict(TIME=NS(SECONDS=1000), ABORT=False,
             SHIP=NS(BODY=NS(NAME='Kerbin',ATM=NS(EXISTS=True,HEIGHT=70000)),
                     PERIAPSIS=78300,ORBIT=native,STATUS='ESCAPING'),
             WARP=0,KUNIVERSE=NS(TIMEWARP=NS(ISSETTLED=True)),
             fixture_settle=lambda:None,
             ROUND=round, LIST=lambda *xs:KList(xs),
             stateGet=saved.get,stateGetNum=saved.get,
             stateSet=lambda key,value:saved.update({key:value}),
             stateRemove=lambda key:saved.pop(key,None),
             ADDONS=NS(KAC=NS(AVAILABLE=True)),
             missionTargetBody=lambda:moon,_bplaneTargetBody=lambda:moon,
             findArrivalPatch=lambda node,target:hit,
             nextPhase=lambda seq:events.append(('advance',seq)),
             xferSeq=KList(('BPLANE','COAST_1HALF','REFINE_BPLANE','COAST_2HALF')),
             PHASES_HAS_SOLAR=True,fixture_unlock=lambda:None,
             LEXICON=lambda:Lex(),LEX=lambda *xs:Lex(zip(xs[::2],xs[1::2])),
             HASNODE=False,maneuverBurnInterrupted=lambda:False,
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
                 '_bplaneScheduleHoldReview','enterSolarCoast','_coastHealthPoll','coastHealthCheck',
                 '_bplaneHasMidcourseRefinement','_bplaneCoastEncounter','_bplaneRetryEncounter','_bplaneQueueMidcourseRetry',
                 '_bplaneHandoffMidcourseRetry','_bplaneHoldCorrection','_bplaneWaitBeforeSolverRetry'):
        env[name]=lambda *args,name=name:ks.call(name,env,*args)
    def resident(reason):
        # Run in the shared globals so the operator's ABORT write is visible
        # during the loop; ks.call normally copies the fixture environment.
        env['reason']=reason
        return run(function_body(SOURCE,'_bplaneResidentHold'),env)
    env['_bplaneResidentHold']=resident
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
    assert env['_transferArrivalUt'](env['_bplaneTargetBody']())==11000
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
    env['enterSolarCoast']=solar
    def wait(target,ut,poll,alarm,ref):
        assert env['TIME'].SECONDS==ut==6000 and alarm=='Midcourse refine: Mun'
        events.append(('wait',ut))
    env['waitUntilOrSOI']=wait
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
    env['enterSolarCoast']('COAST_1HALF',True,True,deadline)
    assert events==[('aim',deadline)] and env['TIME'].SECONDS==deadline
    # No wait after a full battery drops at the deadline, either.
    env['TIME'].SECONDS=1000;events.clear()
    env['shipPowerFraction']=lambda:1 if env['TIME'].SECONDS<deadline else .5
    assert not env['coastHealthCheck']('test',deadline)
    assert not events and env['TIME'].SECONDS==deadline
    wait=function_body(COAST,'waitUntilOrSOI')
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


def retry_environment():
    env,saved,events,alarms,moon,hit=environment()
    saved.update(phase='BPLANE',mission_id='mun_science')
    env.update(phaseShouldYield=False,BPLANE_REQUIRE_PLANE=1,CAPTURE_INC=90,
               CAPTURE_PE=15000,CAPTURE_LAN=-1,BPLANE_PE_ONLY=0,
               MAX_BURNS=2,MIN_EXEC_DV=.3,COAST_AUTO_WARP=0,
               bplanePauseForReview=lambda:False,_bplaneCoastOutOfDepartureSoi=lambda _:True,
               _bplaneWantInc=lambda:90,bplaneResetWarnings=lambda:None,
               _bplaneLogBaseline=lambda *_:None,_bplaneDeferPeToMidcourse=lambda *_:False,
               _bplaneCurrentCorridorOk=lambda *_:False,measureArrival=lambda *_:0,
               _bplaneExistingNodeAcceptable=lambda *_:False)
    def advance(seq):
        phase=saved['phase']
        saved['phase']=seq[seq.index(phase)+1]
        events.append(('advance',saved['phase']))
    def yield_prompt():
        env['phaseShouldYield']=True
        events.append(('yield',saved['phase']))
    def wait(dt):
        # Conic refresh waits have no native propagation in this fixture.
        if dt<1:return
        env['TIME'].SECONDS+=dt
        env['SHIP'].ORBIT.NEXTPATCHETA=hit['entryUt']-env['TIME'].SECONDS
    def forbidden(*_):raise AssertionError('rejected correction reached burn/capture')
    env.update(nextPhase=advance,yieldToPrompt=yield_prompt,fixture_wait=wait,
               _bplaneReserveCorrection=forbidden,_bplaneExecuteCorrection=forbidden,
               bplaneCorrectionAllowed=forbidden)
    # Execute the actual unconverged-kernel decision tail. Synthetic planner
    # responses isolate orchestration; no claim of native solver convergence.
    tail=function_body(SOURCE,'_bplanePlanFullAttempt').split(
        'IF NOT converged AND NOT acquired {',1)[1]
    tail='IF NOT converged AND NOT acquired {'+tail
    def plan(target,pe,inc,lan,cap=-1,note='',allow=False):
        events.append(('plan',saved['phase'],allow))
        local=dict(env,converged=False,acquired=False,nd=None,targetBody=target,
                   dvCap=10,measF=1,allowMidcourseRetry=allow)
        return run(tail,local)
    env['_bplanePlanFullAttempt']=plan
    env['_bplaneTrimCap']=lambda target,cap:cap
    env['_bplanePlanFullCorrection']=lambda *args:ks.call('_bplanePlanFullCorrection',env,*args)
    env['planBplaneCorrection']=lambda target,pe,inc,lan,cap=-1,note='',allow=False:env['_bplanePlanFullCorrection'](target,pe,inc,lan,10 if cap<0 else cap,note,allow)
    env['fixture_remove']=lambda nd:events.append(('remove',nd))
    return env,saved,events,alarms,moon,hit


def check_automatic_retry_through_coast():
    for kac in (True,False):
        env,saved,events,alarms,_,_=retry_environment()
        env['ADDONS'].KAC.AVAILABLE=kac
        saved['arrival_review_alarm']='Arrival review: Mun'
        if kac:alarms['Arrival review: Mun']=(6000,'old manual stop')
        run(function_body(SOURCE,'phaseBplane'),env)
        assert saved['phase']=='COAST_1HALF' and not env['phaseShouldYield']
        assert saved['midcourse_refine_ut']==6000 and 'bplane_midcourse_retry' not in saved
        assert 'Arrival review: Mun' not in alarms
        assert ('plan','BPLANE',True) in events and not any(row[0]=='yield' for row in events)
        ticks=[]
        env['trySolarHoldTick']=lambda ref,deadline=0:ticks.append((env['TIME'].SECONDS,deadline)) or ref
        def enter(label,orient,health,deadline):
            assert label=='COAST_1HALF' and deadline==6000
            assert ('Midcourse refine: Mun' in alarms)==kac
            return 1
        env['enterSolarCoast']=enter
        env['waitUntilOrSOI']=lambda *args:ks.call('waitUntilOrSOI',env,*args)
        ks.call('phaseCoast1Half',env)
        assert env['TIME'].SECONDS==6000 and saved['phase']=='REFINE_BPLANE'
        assert len(ticks)>400 and all(deadline==6000 for _,deadline in ticks)
        assert not env['phaseShouldYield']
        # The midpoint must retry instead of silently waiving the polar goal.
        # The later retry remains resident too. Explicit ABORT stops it;
        # a rejected result still cannot execute or enter capture.
        env['measureArrival']=lambda *_:dict(pe=15000,inc=45,lan=0)
        env['_bplaneCorridorError']=lambda *_:dict(planeErr=45,peErr=0)
        env['_bplaneCorridorOk']=lambda *_:False
        def abort_retry(target):
            events.append(('resident-retry',saved['phase']))
            env['ABORT']=True
            return False
        env['_bplaneWaitBeforeSolverRetry']=abort_retry
        run(function_body(SOURCE,'phaseRefineBplane'),env)
        assert saved['phase']=='REFINE_BPLANE'
        assert ('resident-retry','REFINE_BPLANE') in events
        assert ('plan','REFINE_BPLANE',True) in events
        assert env['CAPTURE_INC']==90 and env['BPLANE_REQUIRE_PLANE']==1
    print('PASS: actual rejection tail and phase handlers hand off without yielding, maintain a live timed solar coast, wake at midpoint and retry with polar/burn gates intact; KAC absence still polls the clock')


def check_retry_eligibility_and_resume():
    for failure in ('abort','interrupted','node','patch','invalid-pe','unsafe-parent','nan-parent','infinite-parent','nan','late','path','atmosphere','phase'):
        env,saved,events,_,moon,hit=retry_environment()
        if failure=='abort':env['ABORT']=True
        if failure=='interrupted':env['maneuverBurnInterrupted']=lambda:True
        if failure=='node':env['HASNODE']=True
        if failure=='patch':env['findArrivalPatch']=lambda *_:0
        if failure in ('invalid-pe','nan'):hit['patch'].PERIAPSIS=-moon.RADIUS if failure=='invalid-pe' else math.nan
        if failure=='unsafe-parent':env['SHIP'].PERIAPSIS=69999
        if failure=='nan-parent':env['SHIP'].PERIAPSIS=math.nan
        if failure=='infinite-parent':env['SHIP'].PERIAPSIS=math.inf
        if failure=='late':hit['entryUt']=env['TIME'].SECONDS+900
        if failure=='path':env['xferSeq']=KList(('BPLANE','CAPTURE'))
        if failure=='atmosphere':moon.ATM.EXISTS=True
        if failure=='phase':saved['phase']='REFINE_BPLANE'
        assert not env['_bplaneQueueMidcourseRetry']('unconverged-optional-correction'),failure
        assert 'bplane_midcourse_retry' not in saved and not events
    env,saved,events,_,moon,_=retry_environment()
    assert env['_bplaneQueueMidcourseRetry']('unconverged-optional-correction')
    assert saved['bplane_midcourse_retry']['mission']=='mun_science'
    env['TIME'].SECONDS=2500
    def forbidden_plan(*_):raise AssertionError('reboot restarted solver instead of retained coast')
    env['planBplaneCorrection']=forbidden_plan
    run(function_body(SOURCE,'phaseBplane'),env)
    assert saved['phase']=='COAST_1HALF' and saved['midcourse_refine_ut']==6000
    for key,value in (('mission_id','different_mission'),('launch_time',12345)):
        env,saved,events,_,moon,_=retry_environment()
        assert env['_bplaneQueueMidcourseRetry']('unconverged-optional-correction')
        saved[key]=value
        assert not env['_bplaneHandoffMidcourseRetry'](moon)
        assert saved['phase']=='BPLANE' and 'bplane_midcourse_retry' not in saved
    print('PASS: deferred retry excludes unsafe/missing encounters, abort, interrupted/manual nodes, late/unsupported paths; reboot resumes bound intent without moving the midpoint; other missions cannot inherit it')


def check_retry_is_mission_owned():
    # Mission handlers enable live retry; public previews default off.
    for allow in (False,True):
        env,_,_,_,moon,_=retry_environment()
        calls=[]
        env['_bplaneTrimCap']=lambda *_:10
        env['_bplanePlanFullCorrection']=lambda *args:calls.append(args) or 0
        assert ks.call('planBplaneCorrection',env,moon,15000,90,-1,-1,'',allow)==0
        assert calls[0][-1]==allow
    env,saved,events,_,_,_=retry_environment()
    env['_bplaneHoldCorrection']('unconverged-optional-correction')
    assert env['phaseShouldYield'] and 'bplane_midcourse_retry' not in saved
    env,saved,events,_,_,_=retry_environment()
    env['BPLANE_REVIEW_UNCONVERGED']=1
    env['_bplaneOfferReview']=lambda *_:env['yieldToPrompt']()
    run(function_body(SOURCE,'phaseBplane'),env)
    assert env['phaseShouldYield'] and saved['phase']=='BPLANE'
    assert 'bplane_midcourse_retry' not in saved
    preview=function_body(ARRIVAL,'bplanePreviewCorrection')
    assert 'TRUE)' not in preview.split('planBplaneCorrection(',1)[1].split(').',1)[0]
    command=function_body((ROOT/'cmd/arrival.ks').read_text(),'_arrivalCommand')
    replan=command.split('IF action = "replan" {',1)[1].split('LOCAL saved IS',1)[0]
    assert 'stateRemove("bplane_midcourse_retry")' in replan
    print('PASS: live retries are mission-owned; operator previews and explicit review retain their stop/review policy')


def check_overdue_retry_handoff():
    env,saved,events,_,_,_=retry_environment()
    saved.update(midcourse_refine_ut=1200,midcourse_refine_arrival_ut=11000)
    env['TIME'].SECONDS=2500
    env['SHIP'].ORBIT.NEXTPATCHETA=8500
    run(function_body(SOURCE,'phaseBplane'),env)
    assert saved['phase']=='COAST_1HALF' and not env['phaseShouldYield']
    def forbidden(*_):raise AssertionError('overdue retry started another solar coast')
    env['enterSolarCoast']=forbidden
    ks.call('phaseCoast1Half',env)
    assert saved['phase']=='REFINE_BPLANE' and env['TIME'].SECONDS==2500
    assert saved['midcourse_refine_ut']==1200
    print('PASS: a reboot after the retained midpoint advances immediately to refinement instead of exiting or inventing another wait')


def check_reported_low_periapsis_retry():
    env,saved,events,_,_,hit=retry_environment()
    hit.update(entryUt=15220.57559)
    hit['patch'].PERIAPSIS=8440
    env['SHIP'].ORBIT.NEXTPATCHETA=hit['entryUt']-1000
    run(function_body(SOURCE,'phaseBplane'),env)
    assert saved['phase']=='COAST_1HALF' and not env['phaseShouldYield']
    assert 1000<saved['midcourse_refine_ut']<hit['entryUt']-env['BPLANE_LEAD']
    # This is permission to wait before arrival, not to accept an 8.44 km Pe
    # or a 70-degree plane miss. The actual final admission remains required.
    assert 'bplaneCorrectionAllowed(nd, targetBody, BPLANE_DV_CAP,TRUE,TRUE)' in function_body(SOURCE,'phaseBplane')
    assert 'required-arrival-corridor' in function_body(SOURCE,'bplaneCorrectionAllowed')
    assert hit['patch'].PERIAPSIS==8440 and not any(row[0]=='yield' for row in events)
    print('PASS: reported 8.44 km Mun Pe with safe 78.3 km Kerbin orbit retains the scheduled pre-SOI retry; final arrival/plane admission is unchanged')


def check_later_live_solver_retries():
    for kac in (True,False):
        env,saved,events,alarms,moon,hit=retry_environment()
        saved['phase']='REFINE_BPLANE'
        env['ADDONS'].KAC.AVAILABLE=kac
        hit['patch'].PERIAPSIS=8440
        ticks=[]
        def enter(label,orient,health,deadline):
            assert label=='BPLANE retry' and orient and health
            assert ('B-plane retry: Mun' in alarms)==kac
            assert env['TIME'].SECONDS<deadline<hit['entryUt']-env['BPLANE_LEAD']
            events.append(('solar',deadline))
            return 1
        env['enterSolarCoast']=enter
        env['trySolarHoldTick']=lambda ref,deadline:ticks.append((env['TIME'].SECONDS,deadline)) or ref
        env['waitUntilOrSOI']=lambda *args:ks.call('waitUntilOrSOI',env,*args)
        attempts=[]
        node=NS(DELTAV=NS(MAG=20))
        def attempt(*args):
            attempts.append((env['TIME'].SECONDS,args[4]))
            return -1 if len(attempts)<3 else node
        env['_bplanePlanFullAttempt']=attempt
        caps=[]
        env['_bplaneTrimCap']=lambda target,cap:caps.append(cap) or cap
        result=env['_bplanePlanFullCorrection'](moon,15000,90,-1,30,'',True)
        assert result is node and len(attempts)==3 and caps==[30]*3
        assert attempts[0][0]<attempts[1][0]<attempts[2][0]<hit['entryUt']-env['BPLANE_LEAD']
        assert len(ticks)>500 and not alarms and saved['phase']=='REFINE_BPLANE'
        assert not env['phaseShouldYield'] and not any(row[0]=='yield' for row in events)
    # Explicit abort stops the shared wait before any solar/warp work.
    env,_,events,_,moon,_=retry_environment()
    env.update(ABORT=True,solarRef=-1,targetBody=moon,targetUt=2000)
    run(function_body(SOURCE,'waitUntilOrSOI'),env)
    assert env['TIME'].SECONDS==1000 and not events
    print('PASS: later unconverged mission solves remain live, schedule alarms before solar, poll without KAC and retry with freshly capped budgets; ABORT cannot start a wait')


def check_retry_deadline_resident_hold():
    for failure in ('late','missing','unsafe-parent','wrong-body','overslept'):
        env,saved,events,alarms,moon,hit=retry_environment()
        saved['phase']='REFINE_BPLANE'
        if failure=='late':hit['entryUt']=env['TIME'].SECONDS+env['BPLANE_LEAD']
        if failure=='missing':env['findArrivalPatch']=lambda *_:0
        if failure=='unsafe-parent':env['SHIP'].PERIAPSIS=69999
        if failure=='wrong-body':env['SHIP'].ORBIT.NEXTPATCH.BODY=NS(NAME='Minmus')
        if failure=='overslept':
            env['enterSolarCoast']=lambda *_:1
            def oversleep(*_):env['TIME'].SECONDS=hit['entryUt']
            env['waitUntilOrSOI']=oversleep
        waits=[]
        def stop(dt):
            waits.append(dt)
            env['ABORT']=True  # Operator aborts the resident, 1x hold.
        env.update(targetBody=moon,fixture_wait=stop,WARP=4)
        result=run(function_body(SOURCE,'_bplaneWaitBeforeSolverRetry'),env)
        assert result is False and waits==[1] and env['WARP']==0
        assert not alarms and saved['phase']=='REFINE_BPLANE' and not env['phaseShouldYield']
        assert not any(row[0]=='yield' for row in events)
    print('PASS: exhausted/invalid retry windows and an overslept deadline stop at a resident 1x intervention hold, without yielding, advancing or accepting the rejected burn')


def check_resident_admission_guards():
    for reason in ('planned-encounter-missing','required-arrival-corridor','correction-budget',
                   'correction-plus-capture-budget','arrival-time-shift','capture-cost-increase'):
        env,saved,events,alarms,moon,_=retry_environment()
        saved['phase']='REFINE_BPLANE'
        node=NS(DELTAV=NS(MAG=20))
        original=dict(entryUt=11000,patch=NS(PERIAPSIS=15000,INCLINATION=90,LAN=0))
        planned=dict(entryUt=11000,patch=NS(PERIAPSIS=15000,INCLINATION=90,LAN=0))
        env['SHIP'].DELTAV=NS(VACUUM=2019.1)
        env.update(nd=node,targetBody=moon,phaseCap=100,checkCorridor=True,missionOwned=True,
                   BPLANE_CAPTURE_MARGIN=900,BPLANE_MAX_ARRIVAL_SHIFT=600,
                   BPLANE_MAX_CAPTURE_DV_INCREASE=5,BPLANE_TRIM_RESERVE_DV=900,
                   _bplaneTrimSpent=lambda _:0,_bplaneTrimCap=lambda *_:100,
                   _bplaneElementPlaneError=lambda *_:0,
                   bplaneCaptureCost=lambda *_:280)
        if reason=='planned-encounter-missing':planned=0
        if reason=='required-arrival-corridor':planned['patch'].PERIAPSIS=27000
        if reason=='correction-budget':node.DELTAV.MAG=101
        if reason=='correction-plus-capture-budget':env['SHIP'].DELTAV.VACUUM=1199
        if reason=='arrival-time-shift':planned['entryUt']=11601
        if reason=='capture-cost-increase':
            env['bplaneCaptureCost']=lambda patch,_:286 if patch is planned['patch'] else 280
        env['findArrivalPatch']=lambda nd,_:planned if nd else original
        waits=[]
        def stop(dt):
            waits.append(dt)
            env['ABORT']=True
        env.update(fixture_wait=stop,WARP=5)
        guard=function_body(SOURCE,'bplaneCorrectionAllowed').replace(
            'PARAMETER nd, targetBody, phaseCap.',
            'PARAMETER nd. PARAMETER targetBody. PARAMETER phaseCap.')
        result=run(guard,env)
        assert result is False and env['reason']==reason and waits==[1]
        assert env['WARP']==0 and not env['phaseShouldYield'] and not alarms
        assert saved['phase']=='REFINE_BPLANE' and not any(row[0]=='yield' for row in events)
        assert 'bplane_budget_spent' not in saved
    # An interrupted execution still owns its node and explicitly yields for
    # review even when called from the mission; no speculative retry/cleanup.
    env,_,events,_,_,_=retry_environment()
    env.update(HASNODE=True,maneuverBurnInterrupted=lambda:True)
    env['_bplaneHoldCorrection']('correction-execution-failed',True)
    assert env['HASNODE'] and env['phaseShouldYield'] and events[-1][0]=='yield'
    print('PASS: all six mission admission rejections retain their limits in resident 1x holds, charge no budget and never advance; interrupted burns still retain their node and require explicit review')


if __name__=='__main__':
    check_checkpoint_persistence()
    check_arrival_hold_alarm()
    check_alarm_before_solar()
    check_solar_and_health_deadlines()
    check_boot_hold_returns_prompt()
    check_expired_alarm_replacement()
    check_automatic_retry_through_coast()
    check_retry_eligibility_and_resume()
    check_retry_is_mission_owned()
    check_overdue_retry_handoff()
    check_reported_low_periapsis_retry()
    check_later_live_solver_retries()
    check_retry_deadline_resident_hold()
    check_resident_admission_guards()
