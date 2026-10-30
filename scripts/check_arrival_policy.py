"""Arrival event, timing and safe disk-prefetch source fixtures; not a KSP VM."""
import math
import re
from types import SimpleNamespace as NS
import check_midcourse as mid
import check_landing_guidance as ks
from check_codebase import ROOT, function_body, dependency_tables, closure
from check_runtime_contracts import run, KList
from arrival_fixture import EventEta

POLICY=(ROOT/'lib/arrival_policy.ks').read_text()
BOOT=(ROOT/'lib/boot_lib.ks').read_text()


def fixture():
    env,saved,events,alarms,target,hit=mid.retry_environment()
    target.NAME='Duna';target.ATM.EXISTS=True;target.ATM.HEIGHT=50000
    target.RADIUS=320000;target.SOIRADIUS=47921949;target.MU=3.0136321e11
    env['SHIP'].BODY.ATM.EXISTS=False
    saved.update(phase='REFINE_BPLANE',mission_id='duna_orbital_surveyor')
    hit['entryUt']=100000
    patch=hit['patch'];patch.PERIAPSIS=85000;patch.ECCENTRICITY=2
    patch.ETA=EventEta(env['TIME'],150000)
    env['SHIP'].ORBIT.NEXTPATCHETA=99000
    env['CAPTURE_PE']=85000
    env.update(LN=math.log,ARCTAN2=lambda y,x:math.degrees(math.atan2(y,x)))
    return env,saved,events,alarms,target,hit


def check_intent_and_events():
    env,_,_,_,target,hit=fixture()
    env.update(targetBody=target,desiredPe=85000,hit=hit,patch=hit['patch'],startUt=100000)
    assert run(function_body(POLICY,'arrivalModeOk'),env)
    assert env['arrivalGoalPolicyOk'](hit,target,85000)
    env['BPLANE_ARRIVAL_MODE']='ENTRY'
    assert not env['arrivalGoalPolicyOk'](hit,target,85000)
    env['BPLANE_PE_TOL']=3000;env['desiredPe']=5000;hit['patch'].PERIAPSIS=5000
    assert run(function_body(POLICY,'arrivalModeOk'),env)
    crossing=env['arrivalPatchRadiusUt'](hit['patch'],50000,100000)
    assert 100000<crossing<150000
    assert env['arrivalGoalPolicyOk'](hit,target,5000)
    assert env['arrivalRequiredCaptureDv'](hit['patch'],target)==0
    # Independent numerical integration of dt/dnu validates the conic clock.
    rp=325000;p=rp*3;mu=target.MU
    nu=math.acos((p/370000-1)/2);n=1000;step=nu/n
    values=[p**1.5/math.sqrt(mu)/(1+2*math.cos(i*step))**2 for i in range(n+1)]
    integral=step/3*(values[0]+values[-1]+sum((4 if i%2 else 2)*values[i] for i in range(1,n)))
    assert abs((150000-crossing)-integral)<1e-5
    patch=hit['patch'];patch.HASNEXTPATCH=True;patch.NEXTPATCHETA=140000-env['TIME'].SECONDS
    assert not env['arrivalGoalPolicyOk'](hit,target,5000) # Pe beyond Ike transition.
    patch.HASNEXTPATCH=False
    for mode,desired in (('ORBIT',5000),('ENTRY',1000),('ENTRY',48000),('bad',5000)):
        env.update(BPLANE_ARRIVAL_MODE=mode,desiredPe=desired)
        assert not run(function_body(POLICY,'arrivalModeOk'),env)
    target.ATM.EXISTS=False;env['BPLANE_ARRIVAL_MODE']='ENTRY'
    assert not run(function_body(POLICY,'arrivalModeOk'),env)
    print('PASS: explicit orbit/entry intent, actual in-patch Pe and inbound atmospheric crossing; independent conic integration agrees and an Ike-truncated Duna conic cannot authorize entry')


def check_existing_entry_profiles():
    # Preserve intentional legacy atmospheric arrivals under the new default
    # orbit policy. This audits all static entry profiles, not just Espoir.
    atmospheres={'DUNA':50000,'EVE':90000,'KERBIN':70000,'JOOL':200000,'LAYTHE':50000}
    entries=[]
    for path in (ROOT/'missions').rglob('*.ks'):
        source=path.read_text()
        body=re.search(r'SET TARGET_ TO "([^"]+)"',source,re.I)
        pe=re.search(r'SET CAPTURE_PE TO ([0-9.]+)',source,re.I)
        if not body or not pe or body[1].upper() not in atmospheres:continue
        if float(pe[1])>=atmospheres[body[1].upper()] or not re.search(r'"(?:REFINE_)?BPLANE"',source):continue
        assert re.search(r'SET BPLANE_ARRIVAL_MODE TO "ENTRY"',source,re.I),path
        entries.append(path)
    assert len(entries)>=5
    print('PASS: every static B-plane atmospheric-entry profile explicitly retains entry intent, including legacy Eve and Duna missions')


def check_timing_and_cadence():
    env,saved,events,alarms,target,hit=fixture()
    env['_bplaneTrimCap']=lambda target,cap:cap
    env['enterSolarCoast']=lambda *_:1
    env['waitUntilOrSOI']=lambda *args:ks.call('waitUntilOrSOI',env,*args)
    assert env['_bplaneWaitBeforeSolverRetry'](target,'below-execution-minimum',.1,30)
    first=env['TIME'].SECONDS
    assert saved['bplane_retry_wait']['checkpoint']=='approach'
    assert first<99100
    assert env['_bplaneWaitBeforeSolverRetry'](target,'below-execution-minimum',.1,30)
    assert env['TIME'].SECONDS==99100 and saved['bplane_retry_wait']['checkpoint']=='final'
    assert not env['_bplaneWaitBeforeSolverRetry'](target,'below-execution-minimum',.1,30)
    assert env['TIME'].SECONDS==99100 and env['phaseShouldYield'] and not alarms
    assert len([e for e in events if e[0]=='alarm'])==2
    # A reboot while waiting for the final check must not relabel it as a
    # new approach checkpoint and grant another final attempt afterward.
    env,saved,events,alarms,target,hit=fixture()
    saved['bplane_retry_wait']=mid.Lex(mission=saved['mission_id'],launch=saved.get('launch_time',0),
        phase=saved['phase'],target=target.NAME,wakeUt=99100,alarm='',waiting=True,checkpoint='final')
    env['enterSolarCoast']=lambda *_:1
    env['waitUntilOrSOI']=lambda *args:ks.call('waitUntilOrSOI',env,*args)
    assert env['_bplaneWaitBeforeSolverRetry'](target,'below-execution-minimum',.1,30)
    assert env['TIME'].SECONDS==99100 and saved['bplane_retry_wait']['checkpoint']=='final'
    assert not env['_bplaneWaitBeforeSolverRetry'](target,'below-execution-minimum',.1,30)
    assert len([e for e in events if e[0]=='alarm'])==1 and not alarms
    env,_,_,_,_,_=fixture()
    engine=env['SHIP'].ENGINES[0]
    engine.THRUSTLIMIT=10;engine.AVAILABLETHRUST=5.5
    seconds=env['arrivalBurnSeconds'](50)
    assert abs(seconds-(2*50/(5.5/1.287)+2))<1e-9 # AVAILABLETHRUST includes limiter.
    engine.AVAILABLETHRUST=0
    assert env['arrivalBurnSeconds'](50)<0
    # A long low-thrust correction moves the node midpoint later. Prove the
    # full centered interval, not merely its trailing half, fits after wake.
    engine.AVAILABLETHRUST=.055
    duration=env['arrivalBurnSeconds'](100)
    timing=env['arrivalRetryTiming'](hit,100,.3,-1,True)
    midpoint=max(env['BPLANE_LEAD'],duration/2+env['BPLANE_SOLVE_ALLOWANCE']
                 +max(30,env['BPLANE_EXISTING_NODE_MIN_ETA']))
    assert duration>4000 and timing['OK'] and timing['WAKE']<timing['LATEST']
    assert timing['WAKE']+10+midpoint+duration/2+env['SOI_BUFFER_TIME']<hit['entryUt']
    print('PASS: long planetary approaches get at most approach+final retries, short moon cadence remains separate; thrust limiter applied once and no thrust cannot authorize a timed burn')


def check_orbital_prefetch_guards():
    for fault in ('','disabled','node','abort','raw','pilot','thrust','burn','soi','link','entry','falling','landing'):
        saved={};ship=NS(STATUS='ORBITING',PERIAPSIS=85000,ALTITUDE=200000,VERTICALSPEED=100,
            THRUST=0,CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0),
            BODY=NS(ATM=NS(EXISTS=True,HEIGHT=50000)),ORBIT=NS(HASNEXTPATCH=True,NEXTPATCHETA=50000))
        env=dict(SHIP=ship,MISSION_CACHE_NEXT_BAND=1,HOMECONNECTION=NS(ISCONNECTED=True),
                 ABORT=False,HASNODE=False,stateGet=lambda key,default='':saved.get(key,default))
        if fault=='disabled':env['MISSION_CACHE_NEXT_BAND']=0
        if fault=='node':env['HASNODE']=True
        if fault=='abort':env['ABORT']=True
        if fault=='raw':ship.CONTROL.MAINTHROTTLE=.1
        if fault=='pilot':ship.CONTROL.PILOTMAINTHROTTLE=.1
        if fault=='thrust':ship.THRUST=.1
        if fault=='burn':saved.update(burn_pending='true',burn_started='true')
        if fault=='soi':ship.ORBIT.NEXTPATCHETA=100
        if fault=='link':env['HOMECONNECTION'].ISCONNECTED=False
        if fault=='entry':ship.PERIAPSIS=45000
        if fault=='falling':ship.STATUS='SUB_ORBITAL';ship.VERTICALSPEED=-10
        if fault=='landing':ship.STATUS='LANDED'
        assert run(function_body(BOOT,'bootCacheSafe'),env)==(fault in ('','landing')),fault
    import check_boot_install as boot
    env,files,events,_=boot.fixture()
    env.update(ABORT=False,HASNODE=False,BOOT_CACHE_PENDING=True,BOOT_CACHE_LIBS=boot.Items([boot.Text('next')]),MISSION_CACHE_NEXT_BAND=1)
    env['SHIP']=NS(STATUS='ORBITING',PERIAPSIS=85000,THRUST=0,
        CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0),
        BODY=NS(ATM=NS(EXISTS=True,HEIGHT=50000)),ORBIT=NS(HASNEXTPATCH=False))
    files['0:/lib/next.ks']='SET simulated_throttle TO 1.'
    env['bootCacheNextBand']()
    assert '1:/lib/next.ksm' in files and 'simulated_throttle' not in env and not env['BOOT_CACHE_PENDING']
    print('PASS: idle orbital prefetch actually compiles/copies without RUNPATH; nodes, burn/controls, imminent SOI, atmospheric danger, no link and falling hops defer it')


def check_next_distinct_band():
    from check_espoir_fleet import profile
    src=(ROOT/'lib/mission_type.ks').read_text();deps,phases,bands=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    def band(phase,fallback=''):
        return next((key.upper() for key,ps in bands.items() if phase.lower() in ps),fallback)
    for name,current in (('duna_impactor','REFINE_BPLANE'),('ike_lander','COAST_1HALF'),('ike_lander','IKE_SETUP')):
        cfg=profile(name)
        env=dict(cfg,MISSION_CACHE_HANDOFF_PHASES=cfg.get("MISSION_CACHE_HANDOFF_PHASES",KList()),currentPhase=current,bandKey=band(current),LIST=lambda *xs:KList(xs),
                 bootLibBandForPhase=band,
                 bootLibBandRoots=lambda key:KList(root for phase in bands[key.lower()] for root in phases[phase]),
                 missionTypeConditionalRoots=lambda _:KList(),missionAppendUnique=lambda dest,rows:dest.extend(x for x in rows if x not in dest))
        # function has parameters, evaluated by the existing source harness.
        roots=run(function_body(src,'missionTypeCacheRoots'),env)
        expected='science_entry' if name=='duna_impactor' else 'ike_setup'
        if current != 'IKE_SETUP':
            assert expected in closure(roots,deps),(name,roots)
        if name=='ike_lander':
            retained=closure(roots,deps)
            assert {'xfer_plan','maneuver_transfer','arrival_bplane','arrival_policy','capture','maneuver_plan'}<=set(retained)
            # The rewrite clears the initial manifest instead of retaining
            # interplanetary departure code throughout later landing boots.
            assert not cfg['IKE_MISSION_SETTINGS']['MISSION_CACHE_HANDOFF_PHASES']
    print('PASS: selected mission prefetch follows two future distinct bands, skipping resident coasts, and retains the explicit Ike operations rewrite handoff')


if __name__=='__main__':
    check_intent_and_events()
    check_existing_entry_profiles()
    check_timing_and_cadence()
    check_orbital_prefetch_guards()
    check_next_distinct_band()
