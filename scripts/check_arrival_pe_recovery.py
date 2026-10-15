"""Execute Pe-only solver source against synthetic patch-response functions.

Tests optimization/control flow, not KSP patched conics or actual recovery
affordability. Run: python3 -B scripts/check_arrival_pe_recovery.py
"""
import math
from types import SimpleNamespace as NS
import check_landing_guidance as ks
from check_launch_and_staging import body

SOURCE = (ks.ROOT / 'lib/arrival_bplane.ks').read_text()
COMMAND = (ks.ROOT / 'cmd/arrival.ks').read_text()
ks.SOURCES += '\n' + SOURCE


class KList(list):
    ADD = list.append


class Node:
    def __init__(self, time, radial, normal, prograde):
        self.TIME, self.RADIALOUT, self.NORMAL, self.PROGRADE = time, radial, normal, prograde

    @property
    def DELTAV(self):
        return NS(MAG=math.sqrt(self.PROGRADE**2+self.RADIALOUT**2+self.NORMAL**2))


def solve(response, cap, tolerance=2000):
    nodes, holds = [], []
    def patch(nd, target):
        pe = response(nd or Node(0,0,0,0))
        return 0 if pe is None else dict(patch=NS(PERIAPSIS=pe))
    env = dict(NODE=Node, TIME=NS(SECONDS=1000), BPLANE_LEAD=300,
               BPLANE_PE_TOL=tolerance, FD_STEP=.05, LIST=lambda *xs: KList(xs),
               SQRT=math.sqrt, ROUND=round, findArrivalPatch=patch,
               fixture_add=nodes.append, fixture_wait=lambda _: None,
               _bplaneNodeAxisGet=lambda nd, axis: getattr(nd,axis),
               _bplaneNodeAxisSet=lambda nd, axis, value: setattr(nd,axis,value),
               _bplaneHoldCorrection=holds.append)
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
    assert 'FOR line IN previous' in writer and 'FOR key IN values:KEYS' in writer
    assert 'applyMissionOverrides()' in writer
    print('PASS: explicit allowance preserves spent ledger/reserves; preview cannot burn or advance mission; overrides retained')


if __name__=='__main__':
    check_solver()
    check_operator_flow()
