"""Source-driven node-frame/timing regression, not KSP propagation or slew."""
import math
from types import SimpleNamespace as NS

import check_landing_guidance as ks
import check_midcourse as mid
from check_arrival_pe_recovery import Node
from check_codebase import ROOT, function_body
from check_runtime_contracts import run

SOURCE=(ROOT/'lib/arrival_bplane.ks').read_text()+'\n'+(ROOT/'lib/lib_bplane_math.ks').read_text()
SOURCE=SOURCE.replace('WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.','fixture_settle().')
SOURCE=SOURCE.replace('REMOVE nd.','fixture_remove(nd).')
ks.SOURCES=SOURCE+'\n'+ks.SOURCES


def fixture(entry=1866063.7):
    env,saved,events,_,moon,_=mid.retry_environment()
    env['TIME'].SECONDS=1865900.9
    env['SHIP'].DELTAV=NS(VACUUM=1982.9)
    nodes,holds=[],[]
    parent=env['SHIP'].BODY
    class TargetPatch:
        BODY=moon
        HASNEXTPATCH=False
        INCLINATION=90
        LAN=0
        def __init__(self,node=None):self.node=node
        @property
        def PERIAPSIS(self):return 13610+1000*self.node.PROGRADE if self.node else 13610
    class ParentPatch:
        BODY=parent
        HASNEXTPATCH=True
        def __init__(self,node=None):self.NEXTPATCH=TargetPatch(node)
        @property
        def NEXTPATCHETA(self):return entry-env['TIME'].SECONDS
    class FramedNode(Node):
        def __init__(self,*args):
            super().__init__(*args)
            # Model the game's frame change; no conic/dynamics claim.
            self.ORBIT=ParentPatch(self) if self.TIME<entry else TargetPatch(self)
    env['SHIP'].ORBIT=ParentPatch()
    env.update(NODE=FramedNode,fixture_add=nodes.append,fixture_remove=nodes.remove,
               fixture_wait=lambda _:None,_bplaneHoldCorrection=lambda reason,*_:holds.append(reason),
               BPLANE_LEAD=300,SOI_BUFFER_TIME=120,BPLANE_EXISTING_NODE_MIN_ETA=30,
               ALLOW_GRAVITY_ASSIST=0,_bplaneAllowGravityAssist=lambda:False,
               FD_STEP=.05,ROUND=round,BPLANE_PE_TOL=2000)
    for name in ('findArrivalPatch','_bplaneCreateCorrectionNode','_bplaneNodeAxisGet','_bplaneNodeAxisSet'):
        env[name]=lambda *args,name=name:ks.call(name,env,*args)
    env['measureArrival']=lambda node,target:env['findArrivalPatch'](node,target)
    return env,moon,nodes,holds,entry


def check_reported_boundary_and_both_seeds():
    for mode in ('full','pe-only'):
        env,moon,nodes,holds,entry=fixture()
        raw=env['findArrivalPatch'](0,moon)
        old_node=env['NODE'](env['TIME'].SECONDS+300,0,0,0)
        assert raw and old_node.ORBIT.BODY is moon
        assert env['findArrivalPatch'](old_node,moon)==0  # Exact old failure.
        if mode=='full':
            # Execute the real seed/measurement/acquisition prefix. The
            # full Newton kernel has separate numerical fixtures.
            seed=function_body(SOURCE,'_bplanePlanFullAttempt').split(
                'LOCAL err0 IS _bplaneCorridorError(',1)[0]+'RETURN nd.'
            env.update(targetBody=moon,wantPe=15000,wantInc=90,wantLan=-1,
                       dvCap=100,pristineLog='',allowMidcourseRetry=True,
                       bplaneResetWarnings=lambda:None)
            result=run(seed,env)
        else:
            result=ks.call('_bplanePlanPeOnly',env,moon,15000,100,True)
        assert result and not holds and nodes==[result]
        assert result.ORBIT.BODY is env['SHIP'].BODY
        assert abs(result.TIME-(entry-123))<1e-8
        assert 30<result.TIME-env['TIME'].SECONDS<43
        assert env['findArrivalPatch'](result,moon)
    print('PASS: logged T-163s case reproduces a lost node-relative patch at old +300s; both solver seeds now choose a measurable pre-SOI node with an estimated half-burn margin with the 120s buffer intact')


def check_timing_and_body_rejections():
    for entry,expected in ((1866050,'insufficient-pre-soi-burn-lead'),
                           (math.nan,'invalid-arrival-time'),(math.inf,'invalid-arrival-time')):
        env,moon,nodes,holds,_=fixture(entry)
        assert env['_bplaneCreateCorrectionNode'](moon,True)==0
        assert not nodes and holds==[expected]
    env,moon,nodes,holds,_=fixture()
    env['SHIP'].BODY=moon
    assert env['_bplaneCreateCorrectionNode'](moon,True)==0
    assert not nodes and holds==['entered-target-before-correction-plan']
    env,moon,nodes,holds,_=fixture(entry=1869000)
    result=env['_bplaneCreateCorrectionNode'](moon,True)
    assert result.TIME==env['TIME'].SECONDS+300 and not holds
    print('PASS: too-short/invalid/already-entered windows create no node and report timing/body reasons; ordinary early planning retains its configured 300s lead')


def check_warp_settles_before_epoch_read():
    for abort in (False,True):
        env,moon,nodes,holds,entry=fixture()
        env.update(targetBody=moon,missionOwned=True,WARP=3)
        def settled():
            assert env['WARP']==0
            env['TIME'].SECONDS+=5
            env['ABORT']=abort
        env['fixture_settle']=settled
        result=run(function_body(SOURCE,'_bplaneCreateCorrectionNode'),env)
        if abort:assert result==0 and not nodes
        else:
            assert result.TIME==entry-123 and result.TIME-env['TIME'].SECONDS>=30
            assert not holds and result.ORBIT.BODY is env['SHIP'].BODY
    print('PASS: native time/frame is reread after settling warp; an abort during settling creates no node')


def check_postsolve_timing_gate():
    for fault in ('none','planning-age','entry-retimed'):
        env,moon,_,holds,entry=fixture()
        node=env['_bplaneCreateCorrectionNode'](moon,True)
        original=dict(entryUt=entry,patch=NS(PERIAPSIS=15000,INCLINATION=90,LAN=0))
        planned=dict(original)
        if fault=='planning-age':env['TIME'].SECONDS=node.TIME-29
        if fault=='entry-retimed':planned['entryUt']=node.TIME+119
        env.update(nd=node,targetBody=moon,phaseCap=100,checkCorridor=True,missionOwned=False,
                   _bplaneTrimCap=lambda *_:100,_bplaneTrimSpent=lambda _:0,
                   _bplaneElementPlaneError=lambda *_:0,_bplaneWantInc=lambda:90,
                   bplaneCaptureCost=lambda *_:280,BPLANE_CAPTURE_MARGIN=900,
                   BPLANE_MAX_ARRIVAL_SHIFT=600,BPLANE_MAX_CAPTURE_DV_INCREASE=5,
                   findArrivalPatch=lambda nd,_:planned if nd else original)
        guard=function_body(SOURCE,'bplaneCorrectionAllowed').replace(
            'PARAMETER nd, targetBody, phaseCap.','PARAMETER nd. PARAMETER targetBody. PARAMETER phaseCap.')
        assert run(guard,env)==(fault=='none')
        assert holds==([] if fault=='none' else ['insufficient-pre-soi-burn-lead'])
    print('PASS: final admission rechecks remaining node lead and solved SOI timing; slow planning or a retimed encounter cannot bypass the timing buffer')


if __name__=='__main__':
    check_reported_boundary_and_both_seeds()
    check_timing_and_body_rejections()
    check_warp_settles_before_epoch_read()
    check_postsolve_timing_gate()
