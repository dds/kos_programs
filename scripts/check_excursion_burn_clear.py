"""Explicit review acknowledgement, real guard and shared executor cleanup; no KSP VM."""
import math
from types import SimpleNamespace as NS

import check_entry_landing as entry
import check_espoir_minmus as excursions
import check_orbit_burn_recovery as recovery
from check_codebase import ROOT, function_body, command_entrypoint_errors
from check_espoir_fleet import Text, native

SOURCE=(ROOT/'cmd/burnclear.ks').read_text()
STATE=(ROOT/'lib/state.ks').read_text().replace('("" + _cache[stateKey]) = ("" + values[key])',
    'fixture_string(_cache[stateKey]) = fixture_string(values[key])')
BODY=function_body(SOURCE,'_cmdBurnclear')
TAIL='GLOBAL FUNCTION commandTail {\n'+BODY[BODY.index('IF NOT ready() {'):]+'\n}'


def fixture():
    env,ship,state,node,events,world=recovery.fixture('SCIENCE_OPS')
    # Native boot035 cutoff; operator removed its visible0.05016m/s tail.
    state.update(vehicle=Text('Espoir'),burn_status=Text('interrupted'),
        burn_mission_id=state['mission_id'],burn_launch_time=state['launch_time'],
        burn_dv=4.754102,burn_abort_residual=.050157477)
    state['last_burn_report']=Text('STATS last-burn phase=SCIENCE_OPS body=Mun ut=5187836.9 '
        'plannedDv=4.754102 residual=0.050157477 residualLimit=0.05 '
        'reason=live-thrust-axis-trim cutoffFault=residual-outside-tolerance '
        'shutdownAttempted=False thrustStopped=True')
    env.update(HASNODE=False,MISSION_EXCURSIONS=1,getTarget=lambda:Text('Mun'),
        vehicle=state['vehicle'],mid=state['mission_id'],phase_=state['phase'],
        fixture_settle=lambda:None,fixture_log=lambda:None,fixture_string=str)
    class Cache:
        HASKEY=state.__contains__
        REMOVE=state.pop
        def __getitem__(self,key):return state[key]
    env.update(_cache=Cache(),_ensureLoaded=lambda:None,_flush=lambda:events.append('flush'))
    env['stateRemoveMatchingPrefixed']=lambda *args:entry.call(STATE,'stateRemoveMatchingPrefixed',env,*args)
    env['ALLNODES'].clear()
    for name in ('excursionBlockReason','excursionOrbitSafe'):
        env[name]=lambda name=name:entry.call(excursions.SOURCE,name,env)
    env['ready']=lambda:entry.call(SOURCE,'ready',env)
    return env,ship,state,node,events,world


def run(env):
    entry.call(TAIL,'commandTail',env)


def check_manual_tail_acknowledgement():
    for phase in ('SCIENCE_OPS','SCANSAT_OPS','DONE','LANDING_REVIEW','SURFACE_REVIEW'):
        env,_,state,_,events,_=fixture()
        state.update(phase=Text(phase),burn_phase=Text(phase))
        state['last_burn_report']=Text(state['last_burn_report'].replace('phase=SCIENCE_OPS ','phase='+phase+' '))
        env['phase_']=state['phase']
        before=state.copy()
        # Unrelated recovery/hardware fields must survive the whitelist.
        state['burn_departure_target']=Text('Mun')
        state['engine_thrust_restore']=dict(engine=Text('saved'))
        assert env['ready']()
        run(env)
        assert not env['HASNODE'] and 'remove' not in events and 'advance' not in events
        assert state['phase']==before['phase'] and state['mission_id']==before['mission_id']
        assert state['shape_budget_spent']==before['shape_budget_spent']
        assert state['last_burn_report']==before['last_burn_report']
        assert 'burn_pending' not in state and 'burn_started' not in state
        assert 'operator-accept-achieved-orbit' in state['last_burn_handoff']
        assert state['burn_departure_target']=='Mun' and state['engine_thrust_restore']==dict(engine='saved')
        assert events==['flush'] # Atomic exact-field removal, real state helper.
        assert env['excursionBlockReason']()==''
        assert not env['ready']() # No acknowledgement of another/future attempt.
    assert not command_entrypoint_errors(SOURCE)
    assert BODY.index('bootPreamble().') < BODY.index('bootApplyMissionConfig(') < BODY.index('IF NOT ready() {')
    assert all(token not in SOURCE for token in ('REMOVE NEXTNODE.','executeManeuver(',
        'nextPhase(', 'stateRemovePrefix(', 'missionOverrideUpdate(', 'DELETEALARM(', 'STAGE.'))
    print('PASS: explicit manual0.050157477m/s tail acknowledgement uses real atomic state cleanup, preserves reports/phase/mission/budget/departure/hardware intent and never deletes nodes, changes phase, burns or stages')


def check_manual_clear_guards():
    changes={
        'visible-node':lambda e,s,st,w:e.update(HASNODE=True),
        'abort':lambda e,s,st,w:e.update(ABORT=True),
        'warp':lambda e,s,st,w:e.update(WARP=1),
        'inactive':lambda e,s,st,w:setattr(e['KUNIVERSE'],'ACTIVEVESSEL',NS()),
        'disabled':lambda e,s,st,w:e.update(MISSION_EXCURSIONS=0),
        'target':lambda e,s,st,w:e.update(getTarget=lambda:Text('Minmus')),
        'thrust':lambda e,s,st,w:setattr(s,'THRUST',.01),
        'raw':lambda e,s,st,w:setattr(s.CONTROL,'MAINTHROTTLE',.1),
        'pilot':lambda e,s,st,w:setattr(s.CONTROL,'PILOTMAINTHROTTLE',.1),
        'falling':lambda e,s,st,w:setattr(s,'STATUS',Text('SUB_ORBITAL')),
        'low-pe':lambda e,s,st,w:setattr(s,'PERIAPSIS',9999),
        'atmosphere':lambda e,s,st,w:setattr(s.BODY.ATM,'EXISTS',True),
        'patch':lambda e,s,st,w:setattr(s.ORBIT,'HASNEXTPATCH',True),
        'ecc':lambda e,s,st,w:setattr(s.ORBIT,'ECCENTRICITY',1),
        'bad-ap':lambda e,s,st,w:setattr(s,'APOAPSIS',math.nan),
        'escape-ap':lambda e,s,st,w:setattr(s,'APOAPSIS',s.BODY.SOIRADIUS),
        'wrong-phase':lambda e,s,st,w:st.update(phase=Text('SHAPE')),
        'wrong-burn-phase':lambda e,s,st,w:st.update(burn_phase=Text('SHAPE')),
        'wrong-body':lambda e,s,st,w:st.update(burn_body=Text('Minmus')),
        'wrong-mission':lambda e,s,st,w:st.update(burn_mission_id=Text('other')),
        'wrong-launch':lambda e,s,st,w:st.update(burn_launch_time=1),
        'no-pending':lambda e,s,st,w:st.update(burn_pending=Text('false')),
        'not-started':lambda e,s,st,w:st.update(burn_started=Text('false')),
        'deorbit':lambda e,s,st,w:st.update(deorbit_burn_started=Text('true')),
        'route':lambda e,s,st,w:st.update(hop_route_active=True),
        'not-aborted':lambda e,s,st,w:st.update(burn_status=Text('burning')),
        'different-fault':lambda e,s,st,w:st.update(burn_abort_reason=Text('no-thrust')),
        'large-residual':lambda e,s,st,w:st.update(burn_abort_residual=.250001),
        'larger-than-plan':lambda e,s,st,w:st.update(burn_dv=.01),
        'nan-residual':lambda e,s,st,w:st.update(burn_abort_residual=math.nan),
        'negative-residual':lambda e,s,st,w:st.update(burn_abort_residual=-1),
        'zero-plan':lambda e,s,st,w:st.update(burn_dv=0),
        'nan-plan':lambda e,s,st,w:st.update(burn_dv=math.nan),
        'missing-report':lambda e,s,st,w:st.update(last_burn_report=Text('')),
        'report-phase':lambda e,s,st,w:st.update(last_burn_report=Text(st['last_burn_report'].replace('phase=SCIENCE_OPS','phase=SHAPE'))),
        'not-stopped':lambda e,s,st,w:st.update(last_burn_report=Text(st['last_burn_report'].replace('thrustStopped=True','thrustStopped=False'))),
        'shutdown':lambda e,s,st,w:st.update(last_burn_report=Text(st['last_burn_report'].replace('shutdownAttempted=False','shutdownAttempted=True'))),
        'impulse-limit':lambda e,s,st,w:st.update(last_burn_report=Text(st['last_burn_report'].replace('live-thrust-axis-trim','live-impulse-limit'))),
        'old-start':lambda e,s,st,w:st.update(burn_start_time=1),
        'early-abort':lambda e,s,st,w:st.update(burn_abort_time=1),
        'future-abort':lambda e,s,st,w:st.update(burn_abort_time=1e10),
        'future-node':lambda e,s,st,w:st.update(burn_node_time=1e10),
        'missing-node-ut':lambda e,s,st,w:st.pop('burn_node_time'),
        'failed-cutoff':lambda e,s,st,w:w.update(cutoff=False),
    }
    for fault,change in changes.items():
        env,ship,state,_,events,world=fixture();change(env,ship,state,world)
        before=state.copy();run(env)
        assert state==before and not events,fault
    for change in (lambda e,s,st:e.update(HASNODE=True),lambda e,s,st:st.update(phase=Text('XING')),
                   lambda e,s,st:setattr(s,'THRUST',1)):
        env,ship,state,_,events,_=fixture();before=state.copy()
        env['fixture_settle']=lambda:change(env,ship,state)
        run(env)
        expected=before.copy()
        if state['phase']=='XING':expected['phase']=Text('XING')
        assert state==expected and not events
    print(f'PASS: {len(changes)} unsafe/foreign/unproven attempts retain all saved evidence; warp-settle context changes also prevent acknowledgement')


def check_real_executor_failure_status():
    # The cutoff briefly records aborted-residual, then the common failure
    # exit persists interrupted. Match the durable state the operator sees.
    env,_,state,_,_,_=fixture()
    body=function_body(recovery.BURN,'executeManeuver')
    start=body.index('burnThrustRestore().',body.index('IF burnAbort <> "" {',body.index('stateSet("last_burn_report"')))
    end=body.index('mLog("STATS burn abort',start)
    fragment='GLOBAL FUNCTION executorFailure {\n'+body[start:end]+'\n}'
    env.update(burnThrustRestore=lambda:None,burnAbort=Text('residual-outside-tolerance'),
        burnAbortDetail=Text('remaining=0.050157477 limit=0.05 stop=live-thrust-axis-trim'),
        res=.050157477,totalPaused=0)
    state['burn_status']=Text('aborted-residual')
    entry.call(fragment,'executorFailure',env)
    assert state['burn_status']=='interrupted' and env['ready']()
    run(env)
    assert 'burn_pending' not in state and 'burn_started' not in state
    print('PASS: real executor failure exit produces interrupted status and is accepted only by the explicit safe manual-review cleanup')


def check_clear_then_polar_excursion():
    env,_,state,_,events,_=fixture();run(env)
    values={}
    env.update(excursions.fleet.profile('mun_contract_survey_return'),EXCURSION_RESERVE_DV=400,
        opts=native(dict(after='scan')),HOMECONNECTION=NS(ISCONNECTED=True),
        fixtureScalar=lambda:native(999),
        bootPreamble=lambda:None,bootLibLoad=lambda *_:None,RUNPATH=lambda *_:None,
        bootApplyMissionConfig=lambda *_:True,missionOverrideUpdate=values.update,
        phaseBandForPhase=lambda _:'EXCURSION',
        stateSaveReloadState=lambda reason,phase,band:state.update(phase=phase,reload_reason=reason,reload_next_band=band))
    for name in ('excursionIdle','excursionSelect'):
        env[name]=lambda *args,name=name:entry.call(excursions.SOURCE,name,env,*args)
    entry.call((ROOT/'cmd/orbit.ks').read_text(),'_cmdOrbit',env)
    assert state['phase']=='EXCURSION_READY' and events==['flush']
    assert [values['SHAPE_'+key] for key in ('AP','PE','INC','LAN','AOP')]==[90000,70000,90,-1,-1]
    assert values['SEQUENCE']==['EXCURSION_READY','SHAPE','SCANSAT_OPS','RETURN_SETUP']
    assert state['shape_budget_spent']==25 and state['mission_id']=='mun_contract_survey_return'
    assert 'operator-accept-achieved-orbit' in state['last_burn_handoff']
    print('PASS: explicit cleanup followed by the real orbit command selects70km polar surveying and preserves the Mun mission return sequence and budget without burning')


if __name__=='__main__':
    check_manual_tail_acknowledgement()
    check_manual_clear_guards()
    check_real_executor_failure_status()
    check_clear_then_polar_excursion()
