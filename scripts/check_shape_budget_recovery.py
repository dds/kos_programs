"""RO9 missed plane node / cumulative allowance recovery; source fixtures, not KSP."""
import math
from types import SimpleNamespace as NS

from check_codebase import ROOT, function_body
from check_burn_completion import execute as run_source
from check_shape_precision import execute, phase_fixture
from check_shape_minimum import Lex, SOURCE
from check_arrival_budget import shape_admission

COMMAND=(ROOT/'cmd/shapebudget.ks').read_text()
COMMAND_BODY=function_body(COMMAND,'_cmdShapebudget').replace(
    'SHIP:BODY:NAME + ":" + stateGetNum("launch_time", 0)','fixture_id')


def command_fixture():
    saved=dict(phase='SHAPE',shape_budget_id='Kerbin:4704531',shape_budget_spent=1749.3,
               mission_id='kerbin_semisynchronous_satellite')
    overrides=dict(SHAPE_TOTAL_DV_CAP=1900,SHAPE_DV_CAP=1300,SHAPE_RESERVE_DV=100,TARGET_AP=1581668)
    writes=[]
    def update(values):
        writes.append(values.copy());overrides.update(values)
    env=dict(additionalDv=1500,ABORT=False,HASNODE=False,fixture_id='Kerbin:4704531',
        SHIP=NS(STATUS='ORBITING',THRUST=0,CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0)),
        RUNPATH=lambda *_:None,bootPreamble=lambda:None,stateGet=saved.get,stateGetNum=saved.get,
        missionOverrideUpdate=update,LEXICON=lambda *xs:Lex(zip(xs[::2],xs[1::2])))
    return env,saved,overrides,writes


def check_allowance_and_reserves():
    env,saved,settings,writes=command_fixture();before=saved.copy()
    run_source(COMMAND_BODY,env)
    assert writes==[dict(SHAPE_TOTAL_DV_CAP=3249.3)] and saved==before
    assert settings['SHAPE_DV_CAP']==1300 and settings['SHAPE_RESERVE_DV']==100
    # Native log: 945.4 burn,1749.3 charged,2185.2 TOTAL available. The519
    # active-stage readout is not the value read by the real admission helper.
    assert not shape_admission(dict(settings,SHAPE_TOTAL_DV_CAP=1900),945.4,1749.3,2185.2)
    assert shape_admission(settings,945.4,1749.3,2185.2)
    assert not shape_admission(settings,1300.1,1749.3,2185.2)
    assert not shape_admission(settings,945.4,1749.3,1045.3)
    assert not shape_admission(settings,945.4,3000,2185.2)
    env,saved,settings,writes=command_fixture();saved['shape_budget_id']='Mun:older'
    run_source(COMMAND_BODY,env)
    assert writes==[dict(SHAPE_TOTAL_DV_CAP=1500)] and saved['shape_budget_spent']==1749.3
    print('PASS: actual command grants1500 further m/s without resetting expenditure/mission or per-burn/reserve caps; real budget admits reported plane burn using total ship fuel, still rejects every independent cap')


def check_command_rejections():
    for fault in ('zero','negative','nan','infinite','phase','abort','node','status',
                  'thrust','nan-thrust','raw','pilot','ledger'):
        env,saved,settings,writes=command_fixture();before=settings.copy()
        if fault in ('zero','negative','nan','infinite'):
            env['additionalDv']={'zero':0,'negative':-1,'nan':math.nan,'infinite':math.inf}[fault]
        if fault=='phase':saved['phase']='SCIENCE_OPS'
        if fault=='abort':env['ABORT']=True
        if fault=='node':env['HASNODE']=True
        if fault=='status':env['SHIP'].STATUS='SUB_ORBITAL'
        if fault=='thrust':env['SHIP'].THRUST=1
        if fault=='nan-thrust':env['SHIP'].THRUST=math.nan
        if fault=='raw':env['SHIP'].CONTROL.MAINTHROTTLE=.1
        if fault=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.1
        if fault=='ledger':saved['shape_budget_spent']=math.nan
        saved_before=saved.copy()
        run_source(COMMAND_BODY,env)
        assert not writes and settings==before and saved==saved_before,fault
    print('PASS: invalid allowance/ledger, wrong phase/orbit, abort, node and nonzero/invalid controls leave overrides and mission untouched')


def check_expired_node_and_warp():
    env,_,removed,events=phase_fixture();calls=[]
    env.update(WARP=7,KUNIVERSE=NS(TIMEWARP=NS(ISSETTLED=False)),
        shapeErrors=lambda _:Lex(AP=1000),shapeConverged=lambda _:False)
    def wait(dt):
        assert env['WARP']==0
        calls.append('settle');env['KUNIVERSE'].TIMEWARP.ISSETTLED=True
    env['fixture_wait']=wait
    node=NS(ETA=-9455.7,DELTAV=NS(MAG=945.4))
    def plan(_):
        assert env['WARP']==0 and env['KUNIVERSE'].TIMEWARP.ISSETTLED
        calls.append('plan');env.update(HASNODE=True,NEXTNODE=node)
        return Lex(node=node,label='plane')
    def forbidden(*_):raise AssertionError('expired node reached budget or ignition')
    env.update(shapeNextBurn=plan,_shapeReserveBurn=forbidden,executeManeuver=forbidden)
    execute('_runShapePhase',env)
    assert calls==['settle','plan'] and removed==[node] and events==['hold']
    assert function_body(SOURCE,'planPlaneMatch').index('_shapePlanningReady()')<function_body(SOURCE,'planPlaneMatch').index('_shipNormal()')
    # Lead boundaries and invalid timing must also fail closed at zero warp.
    for eta,accepted in ((-13920,False),(0,False),(59.99,False),(60,True),
                         (300,True),(math.nan,False),(math.inf,False)):
        env,_,_,_=phase_fixture()
        assert env['_shapeNodeTimingReady'](NS(ETA=eta))==accepted
    print('PASS: actual phase releases warp before planning and rejects recorded-9455.7s node before spending or ignition;60s lead, finite timing and shared plane-planner entry guarded')


if __name__=='__main__':
    check_allowance_and_reserves()
    check_command_rejections()
    check_expired_node_and_warp()
