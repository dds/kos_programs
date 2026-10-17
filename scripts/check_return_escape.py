"""Source-driven moon-return Pe refinement; not native KSP propagation."""
import re
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_codebase import ROOT, function_body, mask

SOURCE=(ROOT/'lib/return_escape.ks').read_text()
ks.SOURCES+='\n'+SOURCE


class Node:
    def __init__(self, dv=170.2):self.PROGRADE=dv
    @property
    def DELTAV(self):return NS(MAG=abs(self.PROGRADE))


def fixture(predict, dv=170.2):
    env=ks.environment()
    node=Node(dv)
    queries=[]
    def patch(nd,target):
        queries.append(nd.PROGRADE)
        pe=predict(nd.PROGRADE-dv)
        return 0 if pe is None else NS(PERIAPSIS=pe)
    def wait(seconds):env['TIME'].SECONDS+=seconds
    env.update(_targetPatch=patch,fixture_wait=wait,RETURN_ESCAPE_PE_TOLERANCE=1000)
    return env,node,queries


def polish(env,node):return ks.call('_polishReturnEscapePe',env,node,NS(NAME='Kerbin'),53000)


def check_reported_weighted_score():
    # The actual objective's fuel gradient has a biased minimum away from
    # the requested Pe. Reproduce the reported 54,717m/170.2m/s combination.
    sensitivity=1e10*.01/(2*1717)
    env,node,queries=fixture(lambda x:54717-sensitivity*x)
    exact=Node(node.PROGRADE+1717/sensitivity)
    target=NS(NAME='Kerbin')
    old=ks.call('_escapeScore',env,node,target,53000)['SCORE']
    accurate=ks.call('_escapeScore',env,exact,target,53000)['SCORE']
    assert old<accurate
    assert not ks.call('_returnEscapeEntryValid',env,54717,53000)
    assert polish(env,node)
    final=env['_targetPatch'](node,target).PERIAPSIS
    assert abs(final-53000)<1 and 0<node.PROGRADE-170.2<.1
    assert node.DELTAV.MAG<1038
    assert env['RETURN_ESCAPE_PE_TOLERANCE']==1000
    print('PASS: production score prefers reported 54.717km miss over exact Pe; native-response polishing fixes its synthetic node with <0.1m/s and preserves the 1km/fuel gates')


def check_nonlinear_and_failure_guards():
    for predict in (lambda x:54717-30000*x,
                    lambda x:51283-30000*x,
                    lambda x:54717-1000*x-6000*x*x):
        env,node,queries=fixture(predict)
        assert polish(env,node)
        assert abs(predict(node.PROGRADE-170.2)-53000)<=250
        assert abs(node.PROGRADE-170.2)<=10 and len(queries)<=44
    # Missing/flat response, no parent patch and unreachable correction
    # keep a bounded node and leave acceptance to the unchanged hold.
    for predict in (lambda x:54717,
                    lambda x:54717 if x==0 else None,
                    lambda x:None,
                    lambda x:200000-10*x):
        env,node,queries=fixture(predict)
        assert not polish(env,node)
        assert abs(node.PROGRADE-170.2)<=10 and len(queries)<=44
    env,node,queries=fixture(lambda x:54717-30000*x)
    env['ABORT']=True
    assert not polish(env,node) and node.PROGRADE==170.2
    # An already acceptable fuel-optimized node is not made more expensive.
    env,node,queries=fixture(lambda x:53900-30000*x)
    assert polish(env,node) and node.PROGRADE==170.2 and len(queries)==2
    # A failed linear step must shrink before a nonlinear node is accepted.
    env,node,queries=fixture(lambda x:54717-1000*x-6000*x*x)
    assert polish(env,node)
    assert any(abs(54717-1000*(dv-170.2)-6000*(dv-170.2)**2-53000)>1717 for dv in queries)
    print('PASS: both Pe error signs and nonlinear backtracking converge; missing/flat patches, bounds and abort hold safely; already-valid nodes retain their fuel cost')


def check_acceptance_and_pipeline():
    entry=function_body(SOURCE,'_returnEscapeEntryValid')
    assert 'RETURN ABS(predictedPe - targetPe) <= RETURN_ESCAPE_PE_TOLERANCE.' in entry
    planning=function_body(SOURCE,'_planReturnEscape')
    assert planning.index('_polishReturnEscapePe(nd,targetBody,targetPe)')<planning.index('LOCAL finalSeed')
    phase=function_body(SOURCE,'phaseEscape')
    assert phase.index('IF NOT _returnEscapeEntryValid(')<phase.index('executeManeuver()')
    assert 'OR nd:DELTAV:MAG > SHIP:DELTAV:VACUUM' in phase
    clean=mask(function_body(SOURCE,'_polishReturnEscapePe'))
    assert not re.search(r'\b(?:ADD|REMOVE|STAGE|LOCK|UNLOCK|REBOOT)\b',clean)
    mcc=function_body((ROOT/'lib/maneuver_mcc.ks').read_text(),'_mccReturn')
    assert 'newtonTarget(nd, target, "PE", targetPe' in mcc
    assert '_mccAerobrakePatchSafe(SHIP:ORBIT, target, targetPe)' in mcc
    print('PASS: refinement precedes final validation without executing/removing the node; original entry/fuel guards and actual-orbit return MCC remain')


if __name__=='__main__':
    check_reported_weighted_score()
    check_nonlinear_and_failure_guards()
    check_acceptance_and_pipeline()
