"""Recorded escape cutoff + independent parent conic; not a native reflight."""
import copy
import json
import math
import re
from types import SimpleNamespace as NS

import check_orbit_burn_recovery as orbit
import check_survey_orbit as physics
from check_relay_constellation import invoke
from check_espoir_fleet import Items,Text,native
from check_codebase import ROOT,dependency_tables,closure,command_entrypoint_errors

HANDOFF=(ROOT/'lib/escape_handoff.ks').read_text().replace('LIST BODIES IN bodies.','SET bodies TO fixture_bodies().')
HANDOFF=HANDOFF.replace('IF DEFINED SHAPE_MIN_PE','IF fixture_shape_floor_defined()')
ESCAPE=(ROOT/'lib/return_escape.ks').read_text().replace('REMOVE nd.','fixture_remove(nd).')
COMMAND=(ROOT/'cmd/escaperecover.ks').read_text().replace('RUNPATH("1:/lib/boot_lib").','fixture_boot().')
COMMAND=COMMAND.replace('RUNPATH("0:/lib/escape_handoff.ks").','fixture_refresh().')
COMMAND=COMMAND.replace('RUNPATH("0:/lib/return_escape.ks").','fixture_refresh().')
STATE=(ROOT/'lib/state.ks').read_text()


def fixture(mode='SHAPE'):
    env,ship,state,node,events,world=orbit.fixture('ESCAPE')
    parent=NS(NAME=Text('Kerbin'),RADIUS=600000,MU=3.5316e12,SOIRADIUS=84159286,
              ATM=NS(EXISTS=True,HEIGHT=70000),HASBODY=True,BODY=NS(NAME=Text('Sun')))
    origin=ship.BODY;origin.HASBODY=True;origin.BODY=parent
    rp=3620000;ra=12000000
    speed=math.sqrt(parent.MU*(2/ra-2/(rp+ra)))
    conic=physics.Orbit(parent,(ra,0,0),(0,speed,0),5649140)
    patch=NS(BODY=parent,PERIAPSIS=conic.PERIAPSIS,APOAPSIS=conic.APOAPSIS,
             ECCENTRICITY=conic.ECCENTRICITY,HASNEXTPATCH=False)
    ship.ORBIT=NS(ECCENTRICITY=.9149,HASNEXTPATCH=True,NEXTPATCH=patch)
    state.update(phase=Text('ESCAPE'),mission_id=Text('goto'),launch_time=5642520,
        burn_mission_id=Text('goto'),burn_launch_time=5642520,burn_status=Text('interrupted'),
        burn_node_time=5649086.15,burn_start_time=5649082.2,burn_abort_time=5649093.8,
        burn_dv=169.097883,burn_abort_residual=.591772374)
    state['last_burn_report']=Text('STATS last-burn phase=ESCAPE body=Mun ut=5649093.42 '
        'plannedDv=169.097883 thrustDv=169.350808 impulseCap=170.789 residual=0.591772374 '
        'residualLimit=0.05 reason=live-vector-passed-target cutoffFault=residual-outside-tolerance '
        'shutdownAttempted=False thrustStopped=True')
    node.TIME=state['burn_node_time'];node.DELTAV.MAG=.591772374
    node.ISTYPE=lambda kind:kind=='Node'
    env.update(BODY=origin,TIME=NS(SECONDS=5649140),ESCAPE_RESIDUAL_RECOVERY_DV=1,
        SHAPE_MIN_PE=80000,ESCAPE_PE=3020000,REENTRY_PE=30000,RETURN_ESCAPE_PE_TOLERANCE=1000,
        xferSeq=Items([Text('ESCAPE'),Text('COAST'),Text(mode),Text('DONE')]),
        fixture_bodies=lambda:Items([origin,parent]),getTarget=lambda *_:parent.NAME,
        fixture_shape_floor_defined=lambda:True)
    env['SEQUENCE']=env['xferSeq']
    for source in (HANDOFF,ESCAPE):
        for name in re.findall(r'(?:LOCAL|GLOBAL) FUNCTION (\w+)',source):
            env[name]=lambda *args,name=name,source=source:invoke(source,name,env,*args)
    def forbidden(*_):raise AssertionError('flown escape was planned/executed again')
    env.update(_planReturnEscape=forbidden,executeManeuver=forbidden)
    return env,ship,state,node,events,world,patch,parent


def check_recorded_cutoff_and_later_soi():
    for deleted in (False,True):
        env,ship,state,node,events,_,patch,parent=fixture();before=state.copy()
        if deleted:env['HASNODE']=False;env['ALLNODES'].clear()
        env['phaseEscape']()
        assert events[-1]=='advance' and not env['HASNODE'] and 'hold' not in events
        assert 'burn_pending' not in state and state['last_burn_report']==before['last_burn_report']
        assert state['shape_budget_spent']==25 and state['escape_burn_handoff']['RESIDUAL']==.591772374
        assert 'accept-achieved-escape' in state['last_burn_handoff']
        assert abs(patch.PERIAPSIS-3020000)<1e-7 and abs(patch.APOAPSIS-11400000)<1e-7
        # A receipt replay after crossing the SOI validates the new current
        # Kerbin orbit, never tries a solar departure or repeats the Mun burn.
        ship.BODY=parent;ship.ORBIT=patch;env['BODY']=parent
        env['phaseEscape']();assert events[-1]=='advance'
    print('PASS: recorded169.097883m/s escape with0.591772374m/s normal-stop tail accepts independently reconstructed safe Kerbin conic, preserves raw cutoff/budgets and resumes before/after SOI with no second burn')


def check_fault_and_ownership_matrix():
    changes={
        'large':lambda e,s,st,n,w,p:st.update(burn_abort_residual=1.00001),
        'fraction':lambda e,s,st,n,w,p:st.update(burn_dv=20),
        'nan':lambda e,s,st,n,w,p:st.update(burn_abort_residual=math.nan),
        'disabled':lambda e,s,st,n,w,p:e.update(ESCAPE_RESIDUAL_RECOVERY_DV=0),
        'mission':lambda e,s,st,n,w,p:st.update(burn_mission_id=Text('other')),
        'launch':lambda e,s,st,n,w,p:st.update(burn_launch_time=1),
        'not-started':lambda e,s,st,n,w,p:st.update(burn_started=Text('false')),
        'wrong-phase':lambda e,s,st,n,w,p:st.update(burn_phase=Text('XING')),
        'bad-origin':lambda e,s,st,n,w,p:st.update(burn_body=Text('Duna')),
        'bad-status':lambda e,s,st,n,w,p:st.update(burn_status=Text('paused')),
        'future-abort':lambda e,s,st,n,w,p:st.update(burn_abort_time=1e10),
        'old-start':lambda e,s,st,n,w,p:st.update(burn_start_time=1),
        'impulse':lambda e,s,st,n,w,p:st.update(last_burn_report=Text(st['last_burn_report'].replace('live-vector-passed-target','live-impulse-limit'))),
        'shutdown':lambda e,s,st,n,w,p:st.update(last_burn_report=Text(st['last_burn_report'].replace('shutdownAttempted=False','shutdownAttempted=True'))),
        'not-stopped':lambda e,s,st,n,w,p:st.update(last_burn_report=Text(st['last_burn_report'].replace('thrustStopped=True','thrustStopped=False'))),
        'abort':lambda e,s,st,n,w,p:e.update(ABORT=True),
        'warp':lambda e,s,st,n,w,p:e.update(WARP=1),
        'thrust':lambda e,s,st,n,w,p:setattr(s,'THRUST',.1),
        'pilot':lambda e,s,st,n,w,p:setattr(s.CONTROL,'PILOTMAINTHROTTLE',.1),
        'inactive':lambda e,s,st,n,w,p:setattr(e['KUNIVERSE'],'ACTIVEVESSEL',NS()),
        'foreign-retry':lambda e,s,st,n,w,p:setattr(n,'TIME',n.TIME+60),
        'tail-enlarged':lambda e,s,st,n,w,p:setattr(n.DELTAV,'MAG',1.001),
        'multiple':lambda e,s,st,n,w,p:e['ALLNODES'].append(NS()),
        'not-escaping':lambda e,s,st,n,w,p:setattr(s.ORBIT,'HASNEXTPATCH',False),
        'impact':lambda e,s,st,n,w,p:setattr(p,'PERIAPSIS',-1),
        'atmosphere':lambda e,s,st,n,w,p:setattr(p,'PERIAPSIS',79999),
        'unbound':lambda e,s,st,n,w,p:setattr(p,'ECCENTRICITY',1),
        'soi-edge':lambda e,s,st,n,w,p:setattr(p,'APOAPSIS',100000000),
        'next-encounter':lambda e,s,st,n,w,p:setattr(p,'HASNEXTPATCH',True),
        'no-correction':lambda e,s,st,n,w,p:e.update(xferSeq=Items([Text('ESCAPE'),Text('COAST'),Text('DONE')])),
        'wrong-target':lambda e,s,st,n,w,p:e.update(getTarget=lambda *_:Text('Duna')),
        'cutoff':lambda e,s,st,n,w,p:w.update(cutoff=False),
    }
    for fault,change in changes.items():
        env,ship,state,node,events,world,patch,_=fixture();change(env,ship,state,node,world,patch)
        before=copy.deepcopy(state)
        assert not env['returnEscapeRecover'](env['xferSeq']),fault
        assert state==before and env['HASNODE'] and not events,fault
    for fault in ('node','mission','orbit'):
        env,ship,state,node,events,_,patch,_=fixture();before=copy.deepcopy(state)
        def change():
            if fault=='node':node.TIME+=1
            if fault=='mission':state['mission_id']=Text('other')
            if fault=='orbit':patch.PERIAPSIS=79999
            return True
        env['thrustCutoffOk']=change
        assert not env['returnEscapeRecover'](env['xferSeq']) and env['HASNODE']
        assert 'escape_burn_handoff' not in state and not events
    print(f'PASS: {len(changes)} cutoff/provenance/ownership/actual-parent-orbit/route/idle faults retain node/state; late node, mission and orbit changes cannot authorize cleanup')


def check_mcc_corridor_and_immediate_failure_hold():
    for pe,accepted in ((52000,True),(53000,True),(54000,True),(51999,False),(54001,False)):
        env,_,state,_,events,_,patch,_=fixture('MCC');env['ESCAPE_PE']=53000;patch.PERIAPSIS=pe
        assert env['returnEscapeRecover'](env['xferSeq'])==accepted
    # Exercise the real planner/executor boundary. Once a burn has actually
    # started, failure is never converted into another escape-plan attempt.
    for actual_safe in (True,False):
        env,ship,state,node,events,_,patch,_=fixture();saved=state.copy();calls=[]
        for key in list(state):
            if key.startswith('burn_'):state.pop(key)
        env['HASNODE']=False;env['ALLNODES'].clear();ship.ORBIT.HASNEXTPATCH=False
        def plan(*_):
            calls.append('plan');env['HASNODE']=True;env['ALLNODES'].append(node);return node
        def burn():
            calls.append('burn');state.update(saved);ship.ORBIT.HASNEXTPATCH=True
            if not actual_safe:patch.PERIAPSIS=79999
            return False
        env.update(_planReturnEscape=plan,executeManeuver=burn,_targetPatch=lambda *_:NS(PERIAPSIS=3020000))
        env['phaseEscape']()
        assert calls==['plan','burn']
        assert events[-1]==('advance' if actual_safe else 'hold')
        assert env['HASNODE']==(not actual_safe)
    print('PASS: atmospheric-return MCC keeps its original52–54km corridor; actual ESCAPE failure either reconciles the safe achieved orbit or holds its tail after exactly one plan/burn, without a26m/s retry')


def check_receipt_reboot_command_and_band():
    class PowerLoss(Exception):pass
    for where in ('before-remove','after-remove','mid-markers'):
        env,_,state,node,events,_,_,_=fixture();remove=env['fixture_remove'];drop=env['stateRemove']
        def crash_remove(nd):
            if where=='before-remove':raise PowerLoss()
            remove(nd)
            if where=='after-remove':raise PowerLoss()
        def crash_drop(key):
            drop(key)
            if where=='mid-markers' and key=='burn_phase':raise PowerLoss()
        env.update(fixture_remove=crash_remove,stateRemove=crash_drop)
        try:env['returnEscapeRecover'](env['xferSeq'])
        except PowerLoss:pass
        else:raise AssertionError('crash point missed')
        serialized=native(json.loads(json.dumps(state)));state.clear();state.update(serialized)
        env.update(fixture_remove=remove,stateRemove=drop)
        env['phaseEscape']();assert events[-1]=='advance' and not env['HASNODE']
    env,_,state,_,events,_,_,_=fixture();env['phaseShouldYield']=True
    env.update(fixture_boot=lambda:None,fixture_refresh=lambda:events.append('refresh'),
        bootPreamble=lambda:None,bootLibLoad=lambda _:None,
        bootApplyMissionConfig=lambda *_:True,HOMECONNECTION=NS(ISCONNECTED=True),
        stateSaveReloadState=lambda *args:invoke(STATE,'stateSaveReloadState',env,*args),
        phaseBandForPhase=lambda _:Text('XFER_ARRIVE'),fixture_settle=lambda:None)
    state['vehicle']=Text('Espoir')
    invoke(COMMAND,'_cmdEscapeRecover',env)
    assert state['phase']=='COAST' and not env['HASNODE'] and 'burn_pending' not in state
    assert env['phaseShouldYield'] # Manual recovery does not restart the phase runner.
    assert events.count('refresh')==2
    # An old buggy planner's future26m/s retry is not the stopped169m/s
    # escape tail. The command preserves it, the report and the held phase.
    state.clear();state.update(fixture()[2]);events.clear()
    env['HASNODE']=True;env['NEXTNODE'].TIME+=60
    env['NEXTNODE'].DELTAV.MAG=26.2;env['ALLNODES'].append(env['NEXTNODE'])
    before=copy.deepcopy(state)
    invoke(COMMAND,'_cmdEscapeRecover',env)
    assert state==before and env['HASNODE'] and events==['refresh','refresh']
    assert not command_entrypoint_errors((ROOT/'cmd/escaperecover.ks').read_text())
    deps,phases,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    assert 'escape_handoff' in closure(phases['escape'],deps)
    assert not {'orbit_shape','arrival_bplane','landing_main'}&closure(phases['escape'],deps)
    print('PASS: receipt survives three cleanup power-loss points; actual archive command checkpoints COAST without burning, and ESCAPE retains a small independent recovery provider')


def check_completed_receipt_cannot_block_new_mission():
    for field,value in (('mission_id',Text('new-route')),('launch_time',5649141)):
        env,ship,state,node,events,_,_,_=fixture()
        assert env['returnEscapeRecover'](env['xferSeq'])
        state[field]=value;ship.ORBIT.HASNEXTPATCH=False;ship.ORBIT.ECCENTRICITY=.1
        calls=[]
        env['_planReturnEscape']=lambda *_:calls.append('new-plan') or 0
        env['phaseEscape']()
        assert calls==['new-plan'] and events[-1]=='hold'
        invoke(orbit.BURN,'_mpb',env,node,10,env['TIME'].SECONDS+5)
        assert 'escape_burn_handoff' not in state and state['burn_mission_id']==state['mission_id']
    print('PASS: completed receipt from another mission/launch cannot approve or block a fresh escape; the next actual executor plan invalidates that old receipt')


if __name__=='__main__':
    check_recorded_cutoff_and_later_soi()
    check_fault_and_ownership_matrix()
    check_mcc_corridor_and_immediate_failure_hold()
    check_receipt_reboot_command_and_band()
    check_completed_receipt_cannot_block_new_mission()
