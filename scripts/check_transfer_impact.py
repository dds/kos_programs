"""Impact departures and explicit staging review; real source, no native KSP VM."""
import copy
import re
from types import SimpleNamespace as NS

import check_departure_pe as departure
import check_relay_constellation as harness
from check_codebase import ROOT, function_body
from check_espoir_fleet import Items, Text, native

CONTROL=(ROOT/'lib/xfer_plan.ks').read_text()
BURN=(ROOT/'lib/maneuver.ks').read_text().replace('REMOVE NEXTNODE.','fixture_remove(NEXTNODE).')
PHASES=(ROOT/'lib/phases.ks').read_text()


def fixture(pe=-20000, success=False):
    primary=NS(NAME=Text('Kerbin'))
    target=NS(NAME=Text('Mun'),BODY=primary,ATM=NS(EXISTS=False),RADIUS=200000,SOIRADIUS=2429559)
    patch=NS(BODY=target,PERIAPSIS=pe,HASNEXTPATCH=False)
    orbit=NS(BODY=primary,ECCENTRICITY=.8959,HASNEXTPATCH=True,NEXTPATCH=patch,NEXTPATCHETA=20000)
    ship=NS(BODY=primary,ORBIT=orbit,STATUS=Text('ORBITING'),PERIAPSIS=84800,APOAPSIS=11885400,
        THRUST=0,CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0))
    node=NS(TIME=5163628.787739,DELTAV=NS(MAG=.176211516))
    reason='' if success else 'residual-outside-tolerance'
    report=Text('STATS last-burn phase=XING body=Kerbin ut=5163658.95 plannedDv=856.600117 '
        'residual=0.176211516 reason=live-vector-passed-target cutoffFault='+reason+
        ' shutdownAttempted=False thrustStopped=True')
    saved=dict(phase=Text('XING'),mission_id=Text('mun_contract_survey_return'),launch_time=native(5156306),
        burn_departure_target=Text('Mun'),burn_departure_time=native(5163596.8),last_burn_report=report)
    if not success:saved.update(burn_pending=Text('true'),burn_started=Text('true'),burn_phase=Text('XING'),
        burn_body=Text('Kerbin'),burn_node_time=node.TIME,burn_dv=856.600117,burn_abort_reason=reason,
        burn_abort_residual=.176211516,burn_abort_time=5163659.6)
    events=[];alarms={};world=dict(patch=patch)
    env=dict(SHIP=ship,TIME=NS(SECONDS=5163659.7),KUNIVERSE=NS(ACTIVEVESSEL=ship),
        ABORT=False,WARP=0,phaseShouldYield=False,BURN_RESUME_REQUESTED=False,HASNODE=not success,NEXTNODE=node,
        TRANSFER_POST_BURN_HANDOFF_SOI_MULT=1,TRANSFER_IMPACT_MIN_LEAD=1800,
        xferSeq=Items([Text('XING'),Text('BPLANE'),Text('COAST_1HALF')]),
        fixture_text=Text,fixture_unlock=lambda:events.append('unlock'),fixture_wait=lambda _:None,
        LIST=lambda *xs:Items(xs),LEXICON=lambda *xs:harness.Record(zip(xs[::2],xs[1::2])),
        stateGet=lambda k,d='':saved.get(k,d),stateGetNum=lambda k,d=0:saved.get(k,d),
        stateSet=lambda k,v:saved.update({str(k):copy.deepcopy(v)}),
        stateRemove=lambda k:saved.pop(k,None),getTarget=lambda *_:target.NAME,
        _fs=lambda value,n:Text(str(round(value,n))),missionTargetBody=lambda:target,orbitSummary=lambda:None,
        _getTargetPatch=lambda *_:world['patch'],
        findArrivalPatch=lambda *_:0 if world['patch']==0 else harness.Record([('patch',world['patch']),('entryUt',env['TIME'].SECONDS+ship.ORBIT.NEXTPATCHETA)]),
        thrustCutoffOk=lambda:events.append('cutoff') or True,
        yieldToPrompt=lambda:env.update(phaseShouldYield=True),archivePhaseLog=lambda:events.append('archive'))
    def clean(prefix):
        for key in list(saved):
            if key.startswith(prefix):saved.pop(key)
    env['stateRemovePrefix']=clean
    def remove(nd):assert nd is node;env['HASNODE']=False;events.append('remove-owned-node')
    def alarm(name,ut,*_):alarms[str(name)]=ut;events.append(('alarm',str(name),ut));return Text(name)
    env.update(fixture_remove=remove,kacEnsureAlarm=alarm,ensureSoiAlarm=lambda body,ut,*_:alarm('SOI: '+str(body.NAME),ut))
    def forbidden(*_):raise AssertionError('Never replan/reburn/stage the flown departure')
    env.update(executeManeuver=forbidden,planTransfer=forbidden,_findClosestApproach=forbidden)
    for source,names in ((departure.SOURCE,['transferCorrectionFollows']),
                         (BURN,['maneuverBurnInterrupted','maneuverDepartureFlown','maneuverAcceptHandoff','_ren','_cpb']),
                         (PHASES,['nextPhase']),
                         (CONTROL,re.findall(r'(?:LOCAL|GLOBAL) FUNCTION (\w+)',CONTROL))):
        for name in names:env[name]=lambda *args,source=source,name=name:harness.invoke(source,name,env,*args)
    harness.SHARED.update(('BURN_RESUME_REQUESTED','phaseShouldYield'))
    return env,saved,events,alarms,target,world


def check_native_tail_and_successful_impact():
    for success in (False,True):
        env,saved,events,alarms,_,_=fixture(success=success);report=saved['last_burn_report']
        env['phaseTransfer']()
        assert saved['phase']=='BPLANE' and env['phaseShouldYield'] and not env['HASNODE']
        assert saved['last_burn_report']==report and 'burn_pending' not in saved and 'burn_started' not in saved
        assert 'burn_departure_time' not in saved
        if not success:assert 'decision=arrival-correction-required' in saved['last_burn_handoff']
        assert len(alarms)==2 and 'SOI: Mun' in alarms and 'Correct impact: Mun' in alarms
        assert alarms['Correct impact: Mun']==alarms['SOI: Mun']-1800
        assert events.index('cutoff')<events.index('archive')
        assert ('remove-owned-node' in events)==(not success)
    env,saved,_,alarms,_,_=fixture(pe=15000)
    env['phaseTransfer']()
    assert saved['phase']=='BPLANE' and not env['phaseShouldYield'] and not alarms
    assert 'decision=accept-live-trajectory' in saved['last_burn_handoff']
    print('PASS: exact native856.600/0.176211516 reversal tail and successful impact advance to BPLANE/manual-stage review, preserving strict cutoff evidence, removing only owned residual and arming both real alarms; positive handoff remains automatic')


def check_impact_recovery_guards():
    for fault in ('abort','yield','warp','active','pilot','raw','thrust','nan-thrust','atmo',
                  'no-correction','wrong-parent','late','degenerate','missing-patch','foreign-node','foreign-burn',
                  'missing-report','forced','not-stopped','watchdog','large-tail','nan-tail','no-departure-receipt',
                  'stale-cutoff','nan-cutoff','future-cutoff','unknown-cutoff','infinite-entry','wrong-first-body'):
        env,saved,events,alarms,target,world=fixture()
        if fault=='abort':env['ABORT']=True
        if fault=='yield':env['phaseShouldYield']=True
        if fault=='warp':env['WARP']=3
        if fault=='active':env['KUNIVERSE'].ACTIVEVESSEL=NS()
        if fault=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.1
        if fault=='raw':env['SHIP'].CONTROL.MAINTHROTTLE=.1
        if fault=='thrust':env['SHIP'].THRUST=1
        if fault=='nan-thrust':env['SHIP'].THRUST=float('nan')
        if fault=='atmo':target.ATM.EXISTS=True
        if fault=='no-correction':env['xferSeq']=Items(['XING','COAST_1HALF'])
        if fault=='wrong-parent':target.BODY=NS()
        if fault=='late':env['SHIP'].ORBIT.NEXTPATCHETA=1800
        if fault=='degenerate':world['patch'].PERIAPSIS=-target.RADIUS
        if fault=='missing-patch':world['patch']=0;env['SHIP'].ORBIT.HASNEXTPATCH=False
        if fault=='foreign-node':env['NEXTNODE'].TIME+=100
        if fault=='foreign-burn':saved['burn_body']='Minmus'
        if fault=='missing-report':saved.pop('last_burn_report')
        if fault=='forced':saved['last_burn_report']=Text(saved['last_burn_report'].replace('shutdownAttempted=False','shutdownAttempted=True'))
        if fault=='not-stopped':saved['last_burn_report']=Text(saved['last_burn_report'].replace('thrustStopped=True','thrustStopped=False'))
        if fault=='watchdog':saved['burn_abort_reason']='live-impulse-limit'
        if fault=='large-tail':saved['burn_abort_residual']=.31
        if fault=='nan-tail':saved['burn_abort_residual']=float('nan')
        if fault=='no-departure-receipt':saved.pop('burn_departure_time')
        if fault=='stale-cutoff':saved['burn_abort_time']=saved['burn_departure_time']-1
        if fault=='nan-cutoff':saved['burn_abort_time']=float('nan')
        if fault=='future-cutoff':saved['burn_abort_time']=env['TIME'].SECONDS+1
        if fault=='unknown-cutoff':saved['last_burn_report']=Text(saved['last_burn_report'].replace('reason=live-vector-passed-target','reason=node-vector-unstable'))
        if fault=='infinite-entry':env['SHIP'].ORBIT.NEXTPATCHETA=float('inf')
        if fault=='wrong-first-body':env['SHIP'].ORBIT.NEXTPATCH=NS(BODY=NS(NAME='Minmus'))
        before=copy.deepcopy(saved)
        env['phaseTransfer']()
        assert saved['phase']=='XING' and env['HASNODE'] and not alarms,(fault,saved,events)
        assert saved==before and 'remove-owned-node' not in events,fault
    print('PASS: unsafe/late/foreign/degenerate/missing encounters, disabled correction, nonfinite data, hard cutoff faults and large/unknown interruptions preserve XING and its node; no fresh departure or capture authorized')


def check_cleanup_reboot_and_review_alarm():
    class Reboot(Exception):pass
    for key in ('intent','node','cleanup'):
        env,saved,events,alarms,_,_=fixture();put=env['stateSet'];remove=env['fixture_remove'];drop=env['stateRemove'];hit=[False]
        def crash():
            if not hit[0]:hit[0]=True;raise Reboot()
        def save(k,v):
            put(k,v)
            if key=='intent' and k=='xing_impact_handoff':crash()
        def ren(nd):
            remove(nd)
            if key=='node':crash()
        def clear(k):
            drop(k)
            if key=='cleanup' and k=='burn_phase':crash()
        env.update(stateSet=save,fixture_remove=ren,stateRemove=clear)
        try:env['phaseTransfer']()
        except Reboot:pass
        env['phaseTransfer']()
        assert saved['phase']=='BPLANE' and env['phaseShouldYield'] and events.count('remove-owned-node')==1
    # Review alarm is not a resident wait: BPLANE consumes it on explicit
    # reboot, retaining the SOI alarm; Abort must leave the review deadline.
    code=function_body((ROOT/'lib/arrival_bplane.ks').read_text(),'phaseBplane').split('IF maneuverBurnInterrupted()',1)[0]
    for abort in (False,True):
        env,saved,_,alarms,_,_=fixture();env['phaseTransfer']();env['phaseShouldYield']=False;env['ABORT']=abort
        env['DELETEALARM']=lambda alarm:alarms.pop(str(alarm))
        from check_burn_completion import execute
        execute(code,env)
        assert ('Correct impact: Mun' in alarms)==abort and 'SOI: Mun' in alarms
    print('PASS: saved handoff resumes across intent/node/cleanup interruptions without another burn or duplicate deletion; explicit BPLANE start consumes only its review alarm, Abort retains it')


def check_cheap_impact_preference():
    for enabled in (False,True):
        for pe,expected in ((-5000,enabled),(-7000,enabled),(-7001,False),(15000,True),(-200001,False)):
            env,nd,target=departure.fixture(lambda _:pe);env['TRANSFER_IMPACT_TARGET']=int(enabled)
            assert env['transferDepartureReady'](nd,target,15000)==expected,(enabled,pe)
    env,nd,target=departure.fixture(lambda node:15000+100000*node.NORMAL)
    env.update(TRANSFER_IMPACT_TARGET=1,CAPTURE_PE=15000)
    assert env['transferDepartureAim'](target,15000)==-5000
    assert env['_refineLocalDeparturePe'](nd,target,-5000)
    assert abs(15000+100000*nd.NORMAL+5000)<=500 and abs(nd.NORMAL)<=5
    for fault in ('late','no-bplane','wrong-first','atmosphere','no-thrust','cap'):
        env,nd,target=departure.fixture(lambda node:15000+1000*node.NORMAL)
        env.update(TRANSFER_IMPACT_TARGET=1,CAPTURE_PE=15000)
        if fault=='late':env['findArrivalPatch']=lambda *_:{'entryUt':nd.TIME+1800}
        if fault=='no-bplane':env['SEQUENCE']=departure.KList(('XING','CAPTURE'))
        if fault=='wrong-first':env['_firstPatchBodyName']=lambda _:'Minmus'
        if fault=='atmosphere':target.ATM.EXISTS=True
        if fault=='no-thrust':env['SHIP'].AVAILABLETHRUST=0
        if fault=='cap':env['TRANSFER_IMPACT_REFINE_DV_CAP']=.001
        assert not env['_refineLocalDeparturePe'](nd,target,-5000),fault
        if fault=='cap':assert abs(nd.NORMAL)<=.001001
    # Both solves stay inside the raw planner's shortlist, not an extra
    # unbounded Newton pass in the wrapper. Prove the fallback call itself.
    code=function_body(departure.SOURCE,'_planLocalTransfer')
    code=code[code.index('LOCAL departureSolved IS'):code.index('RETURN nd.',code.index('LOCAL departureSolved IS'))]
    calls=[]
    from check_burn_completion import execute
    execute(code,dict(nd=nd,targetBody=target,targetPe=-5000,safePe=15000,scanTimes=[],hohmannDv=860,
        _refineLocalDepartureCandidates=lambda node,body,pe,*_:calls.append(pe) or pe>0))
    assert calls==[-5000,15000]
    print('PASS: opt-in local airless impact band is bounded to5m/s polish and sufficient burn/SOI lead; capture15km remains unchanged/accepted fallback, while atmosphere, absent BPLANE, wrong-body and insufficient budgets reject impact authorization')


if __name__=='__main__':
    check_native_tail_and_successful_impact()
    check_impact_recovery_guards()
    check_cleanup_reboot_and_review_alarm()
    check_cheap_impact_preference()
