"""Execute Pe-only solver source against synthetic patch-response functions.

Tests optimization/control flow, not KSP patched conics or actual recovery
affordability. Run: python3 -B scripts/check_arrival_pe_recovery.py
"""
import math
import re
from types import SimpleNamespace as NS
import check_landing_guidance as ks
from check_launch_and_staging import body
from arrival_fixture import install, torch_hardware

SOURCE = (ks.ROOT / 'lib/arrival_bplane.ks').read_text() + '\n' + (ks.ROOT / 'lib/midcourse.ks').read_text()
COMMAND = (ks.ROOT / 'cmd/arrival.ks').read_text()
ks.SOURCES += '\n' + SOURCE.replace('REMOVE nd.', 'fixture_remove(nd).')


class KList(list):
    ADD = list.append
    LENGTH = property(len)


class Node:
    def __init__(self, time, radial, normal, prograde):
        self.TIME, self.RADIALOUT, self.NORMAL, self.PROGRADE = time, radial, normal, prograde

    @property
    def DELTAV(self):
        return NS(MAG=math.sqrt(self.PROGRADE**2+self.RADIALOUT**2+self.NORMAL**2))


def solve(response, cap, tolerance=2000, public=False):
    nodes, holds = [], []
    def patch(nd, target):
        pe = response(nd or Node(0,0,0,0))
        return 0 if pe is None else dict(patch=NS(PERIAPSIS=pe),entryUt=11000)
    env = dict(NODE=Node, TIME=NS(SECONDS=1000), BPLANE_LEAD=300,
               WARP=0,SHIP=NS(BODY=NS(NAME='Kerbin')),SOI_BUFFER_TIME=120,
               BPLANE_EXISTING_NODE_MIN_ETA=30,
               BPLANE_PE_TOL=tolerance, FD_STEP=.05, ABORT=False, LIST=lambda *xs: KList(xs),
               SQRT=math.sqrt, ROUND=round, findArrivalPatch=patch,
               fixture_add=nodes.append, fixture_wait=lambda _: None,
               _bplaneNodeAxisGet=lambda nd, axis: getattr(nd,axis),
               _bplaneNodeAxisSet=lambda nd, axis, value: setattr(nd,axis,value),
               _bplaneHoldCorrection=holds.append)
    env['MIN_EXEC_DV']=.3
    install(env);torch_hardware(env)
    env['_bplaneCreateCorrectionNode']=lambda *args:ks.call('_bplaneCreateCorrectionNode',env,*args)
    if public:
        env.update(MIN_EXEC_DV=float(re.search(r'LOCAL MIN_EXEC_DV\s+IS ([0-9.]+)\.', SOURCE)[1]),
                   BPLANE_PE_ONLY=1, BPLANE_REQUIRE_PLANE=0, BPLANE_DV_CAP=cap,
                   phaseShouldYield=False, _bplaneCurrentCorridorOk=lambda *_: False,
                   _bplaneMinimumSkip=dict(ACCEPTED=False),
                   _bplaneTrimCap=lambda *_: cap, fixture_remove=nodes.remove,
                   maneuverUiArchiveLog=lambda _: None)
        for name in ('_bplanePlanPeOnly', '_bplaneCorrectionAboveMinimum'):
            env[name]=lambda *args,name=name:ks.call(name,env,*args)
        result=ks.call('planBplaneCorrection',env,NS(NAME='Mun'),15000)
    else:
        result=ks.call('_bplanePlanPeOnly',env,NS(NAME='Mun'),15000,cap)
    return result, nodes, holds


def check_solver():
    # A normal-dominated response is still a Pe-only target. The old two-axis
    # solve could fail despite an inexpensive unforced-plane correction.
    response=lambda nd: 1780000 + 200*nd.PROGRADE + 100*nd.RADIALOUT + 20000*nd.NORMAL
    result,nodes,holds=solve(response,100)
    assert result and not holds and result.DELTAV.MAG < 89
    assert abs(response(result)-15000)<=500
    result,nodes,holds=solve(response,20)
    assert result==0 and holds==['pe-recovery-not-converged-within-budget']
    assert nodes[-1].DELTAV.MAG<=20.001
    # An in-corridor candidate at the budget boundary is useful even though
    # the tighter internal 500 m aim cannot be reached within that budget.
    response=lambda nd: 36000 - 1000*nd.PROGRADE
    result,nodes,holds=solve(response,20)
    assert result and not holds and abs(response(result)-15000)==1000
    assert result.PROGRADE==20
    # Lost positive probes fall back to the negative derivative direction.
    response=lambda nd: None if nd.NORMAL>0 else 45000+2000*nd.NORMAL
    result,nodes,holds=solve(response,20)
    assert result and not holds and abs(response(result)-15000)<=500
    # Both signs losing their patch must restore the starting node, not leave
    # the rejected finite-difference sample active.
    response=lambda nd: 50000 if nd.DELTAV.MAG==0 else None
    result,nodes,holds=solve(response,20)
    assert result==0 and nodes[-1].DELTAV.MAG==0 and holds
    response=lambda nd: None if nd.PROGRADE>10 else 45000-2000*nd.PROGRADE
    result,nodes,holds=solve(response,20)
    assert result==0 and holds and 9 < nodes[-1].PROGRADE <= 10
    assert response(nodes[-1]) is not None  # Failed line search restored best.
    # Convex scalar response needs the optimum to rotate along the budget
    # boundary; clipping the increment alone can stall before reaching it.
    response=lambda nd: 15000+1000*((nd.PROGRADE-8)**2+4*(nd.RADIALOUT-8)**2-12)
    result,nodes,holds=solve(response,10)
    assert result and not holds and abs(response(result)-15000)<=2000
    assert result.DELTAV.MAG<=10.001
    print('PASS: normal-efficient correction, hard cap, corridor acceptance, lost patches, budget-boundary steps')


def check_shared_minimum():
    minimum=float(re.search(r'LOCAL MIN_EXEC_DV\s+IS ([0-9.]+)\.', SOURCE)[1])
    for mode in (0,1):
        for dv in (0,.042,.1,.299,.3,.3001,.5,1):
            node=Node(1300,0,0,dv)
            removed, dispatched=[],[]
            env=dict(MIN_EXEC_DV=minimum, BPLANE_PE_ONLY=mode, BPLANE_REQUIRE_PLANE=0,
                     BPLANE_DV_CAP=20, phaseShouldYield=False,ABORT=False,
                     _bplaneMinimumSkip=dict(ACCEPTED=False),
                     _bplaneCurrentCorridorOk=lambda *_:False, _bplaneTrimCap=lambda *_:20,
                     fixture_remove=removed.append, maneuverUiArchiveLog=lambda _:None)
            for branch in (0,1):
                def plan(*_,branch=branch):
                    dispatched.append(branch)
                    return node
                env['_bplanePlanPeOnly' if branch else '_bplanePlanFullCorrection']=plan
            env['_bplaneCorrectionAboveMinimum']=lambda nd:ks.call('_bplaneCorrectionAboveMinimum',env,nd)
            result=ks.call('planBplaneCorrection',env,None,15000)
            assert dispatched==[mode]
            assert (result is node)==(dv>minimum)
            assert removed==([] if dv>minimum else [node])
            if dv<=minimum:
                # No lower-cutoff override or executor call can admit a
                # retained node below the same shared minimum, either.
                env['NEXTNODE']=node
                env['executeManeuver']=lambda:(_ for _ in ()).throw(AssertionError('tiny burn executed'))
                assert ks.call('_bplaneExecuteCorrection',env) is False
    # Exercise the real Pe solver through public admission, not only stubs.
    result,nodes,holds=solve(lambda nd:18000-30000*nd.PROGRADE,20,public=True)
    assert result==0 and nodes==[] and not holds  # Mathematical 0.1 m/s candidate.
    result,nodes,holds=solve(lambda nd:18000-6000*nd.PROGRADE,20,public=True)
    assert result and result.DELTAV.MAG==.5 and nodes==[result] and not holds
    common=body(SOURCE,'planBplaneCorrection')
    assert common.count('_bplaneCorrectionAboveMinimum(')==1
    for solver in ('_bplanePlanPeOnly','_bplanePlanFullCorrection'):
        assert common.index(solver+'(')<common.index('_bplaneCorrectionAboveMinimum(')
        assert 'MIN_EXEC_DV' not in body(SOURCE,solver)
    assert '_bplaneCorrectionAboveMinimum(nd)' in body(SOURCE,'_bplaneExistingNodeAcceptable')
    print('PASS: both solvers share one inclusive 0.3 m/s floor; real 0.1 candidate removed, 0.5 admitted; retained tiny nodes cannot execute')


def defer_fixture():
    env=ks.environment()
    moon=NS(NAME='Minmus',ATM=NS(EXISTS=False),SOIRADIUS=2247428,RADIUS=60000)
    hit=dict(patch=NS(PERIAPSIS=18000),entryUt=11000)
    env.update(TIME=NS(SECONDS=1000),BPLANE_PE_ONLY=1,MIN_EXEC_DV=.3,
               SHIP=NS(BODY='Kerbin',ORBIT=NS(HASNEXTPATCH=True,NEXTPATCH=NS(BODY=moon)),
                       DELTAV=NS(VACUUM=1000)),
               BPLANE_CAPTURE_MARGIN=400,CAPTURE_PE=15000,
               xferSeq=KList(('XING','BPLANE','COAST_1HALF','REFINE_BPLANE','COAST_2HALF','CAPTURE')),
               findArrivalPatch=lambda *_:hit,_bplaneTrimCap=lambda *_:10,
               bplaneCaptureCost=lambda *_:180)
    install(env)
    env['_bplaneHasMidcourseRefinement']=lambda:ks.call('_bplaneHasMidcourseRefinement',env)
    return env,moon,hit


def check_midcourse_deferral():
    env,moon,hit=defer_fixture()
    assert ks.call('_bplaneDeferPeToMidcourse',env,moon,15000)
    # A 3 km Pe error is beyond the fine 2 km corridor, yet safe to leave
    # for the scheduled refinement. Distance and node dV are not the policy.
    for pe,expected in ((10000,True),(25000,True),(9999,False),(25001,False),
                        (-1,False),(1780000,False),(math.nan,False)):
        hit['patch'].PERIAPSIS=pe
        assert ks.call('_bplaneDeferPeToMidcourse',env,moon,15000)==expected
    for changes in (dict(BPLANE_PE_ONLY=0),dict(BPLANE_REQUIRE_PLANE=1),
                    dict(BPLANE_EARLY_PE_TOL=0),dict(ABORT=True),
                    dict(xferSeq=KList(('BPLANE','COAST','CAPTURE'))),
                    dict(xferSeq=KList(('BPLANE','COAST_1HALF'))),
                    dict(_bplaneTrimCap=lambda *_:.3),
                    dict(SHIP=NS(ORBIT=NS(HASNEXTPATCH=False))),
                    dict(SHIP=NS(ORBIT=NS(HASNEXTPATCH=True,NEXTPATCH=NS(BODY='Mun'))))):
        base,target,_=defer_fixture()
        base.update(changes)
        assert not ks.call('_bplaneDeferPeToMidcourse',base,target,15000)
    for seconds,expected in ((900,False),(901,True)):
        base,target,prediction=defer_fixture()
        prediction['entryUt']=base['TIME'].SECONDS+seconds
        assert ks.call('_bplaneDeferPeToMidcourse',base,target,15000)==expected
    for fuel,expected in ((589.9,False),(590,True)):
        base,target,_=defer_fixture()
        base['SHIP'].DELTAV.VACUUM=fuel
        assert ks.call('_bplaneDeferPeToMidcourse',base,target,15000)==expected
    base,target,_=defer_fixture()
    target.ATM.EXISTS=True
    assert not ks.call('_bplaneDeferPeToMidcourse',base,target,15000)
    base,target,_=defer_fixture()
    base['findArrivalPatch']=lambda *_:0
    assert not ks.call('_bplaneDeferPeToMidcourse',base,target,15000)
    # Run the real early phase: no solver, reserve, executor, or Pe target
    # change is needed. Only the existing coast/refinement pair is entered.
    base,target,_=defer_fixture()
    advanced,cleared=[],[]
    base.update(HASNODE=False, maneuverBurnInterrupted=lambda:False,
                _bplaneHandoffMidcourseRetry=lambda *_:False,
                _bplaneTargetBody=lambda:target,bplanePauseForReview=lambda:False,
                _bplaneEnsureSoiAlarm=lambda *_:None,
                _bplaneCoastOutOfDepartureSoi=lambda _:True,_bplaneWantInc=lambda:-1,
                bplaneResetWarnings=lambda:None,_bplaneLogBaseline=lambda *_:None,
                _bplaneClearCoastTimes=lambda:cleared.append(True),
                nextPhase=advanced.append)
    base['_bplaneDeferPeToMidcourse']=lambda *args:ks.call('_bplaneDeferPeToMidcourse',base,*args)
    ks.call('phaseBplane',base)
    assert advanced==[base['xferSeq']] and cleared==[True] and base['CAPTURE_PE']==15000
    phase=body(SOURCE,'phaseBplane')
    assert phase.index('_bplaneDeferPeToMidcourse(')<phase.index('planBplaneCorrection(')
    assert '_bplaneDeferPeToMidcourse(' not in body(SOURCE,'phaseRefineBplane')
    assert '_bplaneCurrentCorridorOk(targetBody, wantPe, -1, -1)' in body(SOURCE,'_bplaneFinishPeRecovery')
    print('PASS: early safe Pe left to midcourse; unsafe/missing encounters, absent refinement, plane contracts, fuel and time shortages cannot defer')


def check_operator_flow():
    from check_surface_return import read_settings, literal
    for spent in (0,12,30):
        values=ks.call('bplaneRecoveryBudgetValues',dict(
            _bplaneTargetBody=lambda: 'Mun', _bplaneTrimSpent=lambda _: spent,
            LEX=lambda *xs: dict(zip(xs[::2],xs[1::2]))),100)
        assert values==dict(BPLANE_DV_CAP=100,REFINE_BPLANE_DV_CAP=100,
                            BPLANE_TRIM_DV_CAP=100,BPLANE_TRIM_TOTAL_DV_CAP=spent+100)
        profile=(ks.ROOT/'missions/RO9/mun_economy_return.ks').read_text()
        overrides='\n'.join(f'SET {key} TO {literal(value)}.' for key,value in values.items())
        rebooted=read_settings(overrides,read_settings(profile,{}))
        assert rebooted['BPLANE_CAPTURE_MARGIN']==rebooted['CAPTURE_RESERVE_DV']==1500
        assert rebooted['CAPTURE_PE']==rebooted['TARGET_AP']==15000
        assert rebooted['BPLANE_TRIM_TOTAL_DV_CAP']-spent==100
    preview=body(SOURCE,'bplanePreviewCorrection')
    for forbidden in ('executeManeuver','resumeMission','nextPhase','_bplaneReserveCorrection'):
        assert forbidden not in preview
    assert 'ABORT OR maneuverBurnInterrupted()' in preview
    assert 'SHIP:BODY = targetBody' in preview
    assert 'planBplaneCorrection' in preview and '_bplaneOfferReview' in preview
    budget=body(COMMAND,'_arrivalCommand').split('IF action = "budget" {',1)[1].split('IF action = "plan"',1)[0]
    assert '_arrivalWriteOverrides(values)' in budget
    for forbidden in ('resumeMission','stateSet(', 'CAPTURE_MARGIN TO','CAPTURE_RESERVE_DV TO'):
        assert forbidden not in budget
    writer=body(COMMAND,'_arrivalWriteOverrides')
    assert 'missionOverrideUpdate(values)' in writer
    assert 'applyMissionOverrides()' in writer
    print('PASS: explicit allowance preserves spent ledger/reserves; preview cannot burn or advance mission; overrides retained')


if __name__=='__main__':
    check_solver()
    check_shared_minimum()
    check_midcourse_deferral()
    check_operator_flow()
