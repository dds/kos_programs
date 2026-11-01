"""Native capture scalars + real phase/cleanup code, not a KSP reflight."""
import copy
import json
import math
import re
from types import SimpleNamespace as NS

import check_relay_constellation as harness
from check_codebase import ROOT, function_body, dependency_tables, closure
from check_espoir_fleet import Items, Text, native

RECOVERY=(ROOT/'lib/orbit_burn_recovery.ks').read_text()
BURN=(ROOT/'lib/maneuver.ks').read_text().replace('REMOVE NEXTNODE.','fixture_remove(NEXTNODE).')
CAPTURE=(ROOT/'lib/capture.ks').read_text()
SHAPE=(ROOT/'lib/orbit_shape.ks').read_text().replace('REMOVE NEXTNODE.','fixture_remove(NEXTNODE).')


def fixture(phase='CAPTURE'):
    bdy=NS(NAME=Text('Mun'),RADIUS=200000,SOIRADIUS=2429559,ATM=NS(EXISTS=False,HEIGHT=0))
    ship=NS(BODY=bdy,STATUS=Text('ORBITING'),PERIAPSIS=13700,APOAPSIS=1737000,
        THRUST=0,CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0),
        ORBIT=NS(ECCENTRICITY=.8012,HASNEXTPATCH=False),DELTAV=NS(VACUUM=3290))
    report=Text('STATS last-burn phase='+phase+' body=Mun ut=5187836.9 plannedDv=87.325495 '
        'thrustDv=87.432952 impulseCap=88.199 residual=0.23022048 residualLimit=0.05 '
        'reason=live-vector-passed-target cutoffFault=residual-outside-tolerance '
        'shutdownAttempted=False thrustStopped=True')
    state=dict(phase=Text(phase),mission_id=Text('mun_contract_survey_return'),launch_time=native(5156306),
        burn_phase=Text(phase),burn_body=Text('Mun'),burn_node_time=5187829.9,
        burn_pending=Text('true'),burn_started=Text('true'),burn_start_time=5187827.4,
        burn_abort_time=5187837.3,burn_dv=87.325495,burn_abort_reason=Text('residual-outside-tolerance'),
        burn_abort_residual=.23022048,last_burn_report=report,shape_budget_id=Text('Mun:5156306'),shape_budget_spent=25)
    node=NS(TIME=5187829.9,DELTAV=NS(MAG=.23022048));events=[];world=dict(cutoff=True)
    env=dict(SHIP=ship,KUNIVERSE=NS(ACTIVEVESSEL=ship,TIMEWARP=NS(ISSETTLED=True)),
        TIME=NS(SECONDS=5187840),ABORT=False,WARP=0,phaseShouldYield=False,BURN_RESUME_REQUESTED=True,
        HASNODE=True,NEXTNODE=node,ALLNODES=Items([node]),ORBIT_RESIDUAL_RECOVERY_DV=.25,
        LIST=lambda *xs:Items(xs),LEXICON=lambda *xs:harness.Record(zip(xs[::2],xs[1::2])),
        MIN=min,MAX=max,ABS=abs,ROUND=round,_fs=lambda n,p:Text(str(round(n,p))),
        stateGet=lambda k,d='':state.get(str(k),d),stateGetNum=lambda k,d=0:state.get(str(k),d),
        stateRemove=lambda k:state.pop(str(k),None),fixture_wait=lambda _:None,
        fixture_text=Text,mLog=lambda row:events.append(str(row)),mLogWarn=lambda row:events.append(str(row)),
        mLogSummary=lambda row:events.append(str(row)),mLogError=lambda row:events.append(str(row)),
        thrustCutoffOk=lambda:world['cutoff'],yieldToPrompt=lambda:events.append('hold'),
        CAPTURE_RESERVE_DV=1200,CAPTURE_MIN_PE=13000,CAPTURE_MAX_PE=17000,CAPTURE_ACCEPT_BOUND=0,
        TARGET_AP=1737680,missionTargetBody=lambda:bdy,midcourseClearReviewAlarm=lambda:None,
        orbitSummary=lambda:None,nextPhase=lambda _:events.append('advance'),MAX_RETRIES=5,
        xferSeq=Items([Text('CAPTURE'),Text('SHAPE'),Text('SCIENCE_OPS')]))
    def put(key,value):
        json.dumps(value);state[str(key)]=copy.deepcopy(value)
    def remove(nd):
        assert nd is node and env['NEXTNODE'] is node,'foreign node removal'
        env['HASNODE']=False;env['ALLNODES'].clear();events.append('remove')
    env.update(stateSet=put,fixture_remove=remove)
    for source,names in ((RECOVERY,re.findall(r'(?:LOCAL|GLOBAL) FUNCTION (\w+)',RECOVERY)),
                         (BURN,['maneuverBurnInterrupted','maneuverAcceptHandoff','_ren','_cpb']),
                         (CAPTURE,['_captureRecoverResidual','_captureUnflownNode','phaseCapture'])):
        for name in names:env[name]=lambda *args,source=source,name=name:harness.invoke(source,name,env,*args)
    def forbidden(*_):raise AssertionError('recovery repeated capture planning/execution')
    env.update(planCapture=forbidden,executeManeuver=forbidden)
    return env,ship,state,node,events,world


def check_reported_capture_reboot_and_immediate_handoff():
    for deleted in (False,True):
        env,_,state,_,events,_=fixture();before=state.copy()
        if deleted:env['HASNODE']=False;env['ALLNODES'].clear()
        env['phaseCapture']()
        assert events[-1]=='advance' and not env['HASNODE'] and 'hold' not in events
        assert state['last_burn_report']==before['last_burn_report']
        assert state['shape_budget_spent']==25 and 'burn_pending' not in state and 'burn_started' not in state
        assert 'accept-achieved-orbit' in state['last_burn_handoff']
        assert state['orbit_burn_recovery']['RESIDUAL']==.23022048
        # Receipt replay proves the captured orbit, not another capture burn.
        assert env['_captureRecoverResidual'](env['SHIP'].BODY)
    env,ship,state,node,events,_=fixture()
    env.update(HASNODE=False);env['ALLNODES'].clear()
    state.clear();state.update(phase=Text('CAPTURE'),mission_id=Text('mun_contract_survey_return'),launch_time=native(5156306))
    ship.STATUS=Text('ESCAPING');ship.ORBIT.ECCENTRICITY=1.2509;ship.APOAPSIS=-2117300
    saved=fixture()[2];calls=[]
    def plan(*_):env['HASNODE']=True;env['ALLNODES'].append(node);calls.append('plan');return node
    def burn():
        calls.append('burn');state.update(saved)
        ship.STATUS=Text('ORBITING');ship.ORBIT.ECCENTRICITY=.8012;ship.APOAPSIS=1737000
        return False
    env.update(planCapture=plan,executeManeuver=burn)
    env['phaseCapture']()
    assert calls==['plan','burn'] and events[-1]=='advance' and not env['HASNODE']
    print('PASS: exact native87.325495/0.23022048m/s capture accepts its achieved13.7x1737km orbit at reboot or immediate cutoff, preserves raw failure evidence/budgets and never repeats insertion')


def check_guard_matrix():
    changes={
        'large':lambda e,s,st,n,w:st.update(burn_abort_residual=.2500001),
        'fraction':lambda e,s,st,n,w:st.update(burn_dv=1),
        'nan':lambda e,s,st,n,w:st.update(burn_abort_residual=math.nan),
        'impulse-limit':lambda e,s,st,n,w:st.update(last_burn_report=Text(st['last_burn_report'].replace('live-vector-passed-target','live-impulse-limit'))),
        'rebound':lambda e,s,st,n,w:st.update(last_burn_report=Text(st['last_burn_report'].replace('live-vector-passed-target','live-residual-rebound'))),
        'shutdown':lambda e,s,st,n,w:st.update(last_burn_report=Text(st['last_burn_report'].replace('shutdownAttempted=False','shutdownAttempted=True'))),
        'not-stopped':lambda e,s,st,n,w:st.update(last_burn_report=Text(st['last_burn_report'].replace('thrustStopped=True','thrustStopped=False'))),
        'alignment':lambda e,s,st,n,w:st.update(burn_abort_reason=Text('stage-alignment-failed')),
        'wrong-burn-mission':lambda e,s,st,n,w:st.update(burn_mission_id=Text('other')),
        'wrong-burn-launch':lambda e,s,st,n,w:st.update(burn_launch_time=100),
        'old-start':lambda e,s,st,n,w:st.update(burn_start_time=1),
        'future-abort':lambda e,s,st,n,w:st.update(burn_abort_time=1e10),
        'disabled':lambda e,s,st,n,w:e.update(ORBIT_RESIDUAL_RECOVERY_DV=0),
        'bad-phase':lambda e,s,st,n,w:st.update(burn_phase=Text('XING')),
        'report-body':lambda e,s,st,n,w:st.update(last_burn_report=Text(st['last_burn_report'].replace('body=Mun','body=Duna'))),
        'abort':lambda e,s,st,n,w:e.update(ABORT=True),
        'warp':lambda e,s,st,n,w:e.update(WARP=1),
        'thrust':lambda e,s,st,n,w:setattr(s,'THRUST',.1),
        'pilot':lambda e,s,st,n,w:setattr(s.CONTROL,'PILOTMAINTHROTTLE',.1),
        'unbound':lambda e,s,st,n,w:setattr(s.ORBIT,'ECCENTRICITY',1),
        'impact':lambda e,s,st,n,w:setattr(s,'PERIAPSIS',-1),
        'floor':lambda e,s,st,n,w:setattr(s,'PERIAPSIS',12999),
        'ceiling':lambda e,s,st,n,w:setattr(s,'PERIAPSIS',17001),
        'escape':lambda e,s,st,n,w:setattr(s.ORBIT,'HASNEXTPATCH',True),
        'soi-ap':lambda e,s,st,n,w:setattr(s,'APOAPSIS',3000000),
        'fuel':lambda e,s,st,n,w:setattr(s.DELTAV,'VACUUM',1199),
        'foreign-node':lambda e,s,st,n,w:setattr(n,'TIME',n.TIME+1),
        'new-large-tail':lambda e,s,st,n,w:setattr(n.DELTAV,'MAG',.251),
        'cutoff-recheck':lambda e,s,st,n,w:w.update(cutoff=False),
        'other-vessel':lambda e,s,st,n,w:setattr(e['KUNIVERSE'],'ACTIVEVESSEL',NS()),
    }
    for fault,change in changes.items():
        env,ship,state,node,events,world=fixture();change(env,ship,state,node,world);before=state.copy()
        assert not env['_captureRecoverResidual'](ship.BODY),fault
        assert state==before and env['HASNODE'] and not events,fault
    for phase in ('XING','BPLANE','MCC','ESCAPE','LAND_PREP'):
        env,_,state,_,_,_=fixture(phase)
        assert not env['orbitBurnRecover'](Text(phase),10000,-1)
    env,ship,state,node,events,_=fixture()
    def changed_during_verification():node.TIME+=1;return True
    env['thrustCutoffOk']=changed_during_verification;before=state.copy()
    assert not env['_captureRecoverResidual'](ship.BODY) and state==before and env['HASNODE']
    print(f'PASS: {len(changes)} fault/ownership/provenance/fuel/native-orbit guards preserve the node and strict report; recovery cannot approve departures, arrival corrections, entry or landing preparation')


def check_cleanup_crash_receipt_and_context():
    class PowerLoss(Exception):pass
    for where in ('before-remove','after-remove','mid-markers'):
        env,ship,state,node,events,_=fixture();remove=env['fixture_remove'];drop=env['stateRemove']
        def crash_remove(nd):
            if where=='before-remove':raise PowerLoss()
            remove(nd)
            if where=='after-remove':raise PowerLoss()
        def crash_drop(key):
            drop(key)
            if where=='mid-markers' and key=='burn_phase':raise PowerLoss()
        env.update(fixture_remove=crash_remove,stateRemove=crash_drop)
        try:env['_captureRecoverResidual'](ship.BODY)
        except PowerLoss:pass
        else:raise AssertionError('crash checkpoint not reached')
        assert 'orbit_burn_recovery' in state
        # Fresh invocation models restored serialized state, with no executing
        # call stack or volatile "success" flag surviving the reboot.
        serialized=native(json.loads(json.dumps(state)));state.clear();state.update(serialized)
        env.update(fixture_remove=remove,stateRemove=drop)
        env['phaseCapture']()
        assert events[-1]=='advance' and not env['HASNODE']
        state['mission_id']=Text('other')
        assert not env['_captureRecoverResidual'](ship.BODY)
    env,_,state,node,_,_=fixture()
    assert env['_captureRecoverResidual'](env['SHIP'].BODY)
    # A genuinely new executor plan invalidates the old accepted intent.
    harness.invoke(BURN,'_mpb',env,node,1,env['TIME'].SECONDS+100)
    assert 'orbit_burn_recovery' not in state and state['burn_mission_id']==state['mission_id']
    print('PASS: durable mission/body/launch/phase receipt survives three cleanup power-loss checkpoints without replaying capture; new burns invalidate it and record mission provenance')


def check_shape_remeasure_and_library_isolation():
    from check_shape_precision import phase_fixture, execute
    from check_shape_minimum import Lex
    for reaches_goal in (True,False):
        env,targets,removed,events=phase_fixture();calls=[];count=[0]
        def plan(_):
            if count[0]:return 0
            env.update(HASNODE=True,NEXTNODE=NS(ETA=1000,DELTAV=NS(MAG=20)))
            return Lex(node=env['NEXTNODE'],label='set-ap')
        def burn():count[0]+=1;return False
        def recover(_):env['HASNODE']=False;calls.append('recover');return True
        env.update(shapeNextBurn=plan,executeManeuver=burn,_shapeReserveBurn=lambda _:True,
            _shapeRecoverResidual=recover,shapeConverged=lambda _:bool(count[0] and reaches_goal),
            shapeErrors=lambda _:Lex(AP=0 if reaches_goal else 10000))
        execute('_runShapePhase',env)
        assert calls==['recover'] and events.count('advance')==int(reaches_goal)
        assert ('hold' in events)==(not reaches_goal)
    # The phase adapter must apply its actual floor and fuel reserve.
    env,ship,state,node,events,_=fixture('SHAPE')
    env.update(SHAPE_RESERVE_DV=650,_peFloor=lambda:13000)
    env['_shapeRecoverResidual']=lambda label:harness.invoke(SHAPE,'_shapeRecoverResidual',env,label)
    assert env['_shapeRecoverResidual'](Text('SHAPE'))
    # Cleanup may already have removed the interruption markers when a new
    # manual node appears. Do not let SHAPE's ordinary replan delete it.
    foreign=NS(TIME=node.TIME+100,DELTAV=NS(MAG=5))
    env.update(HASNODE=True,NEXTNODE=foreign);env['ALLNODES'].append(foreign)
    before=state.copy();nremoved=events.count('remove')
    assert harness.invoke(SHAPE,'_shapeInterruptedHold',env,Text('SHAPE'))
    assert env['NEXTNODE'] is foreign and events.count('remove')==nremoved and state==before
    deps,phases,bands=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    assert 'orbit_burn_recovery' in closure(phases['shape']+phases['capture'],deps)
    for phase in ('xing','bplane','refine_bplane','aerobrake'):
        assert 'orbit_burn_recovery' not in closure(phases[phase],deps),phase
    for band,contents in bands.items():
        if 'bplane' in contents or 'aerobrake' in contents or 'xing' in contents:
            roots=[lib for phase in contents for lib in phases.get(phase,[])]
            assert 'orbit_burn_recovery' not in closure(roots,deps),band
    print('PASS: recovered SHAPE remeasures the real orbit, advances only on original goal convergence, preserves budget/floor admission, and does not add the recovery provider to departure/BPLANE/entry bands')


if __name__=='__main__':
    check_reported_capture_reboot_and_immediate_handoff()
    check_guard_matrix()
    check_cleanup_crash_receipt_and_context()
    check_shape_remeasure_and_library_isolation()
