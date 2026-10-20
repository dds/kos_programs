"""Execute B-plane Newton/control source against synthetic responses.

Independent NumPy least-squares and conic geometry check the math. These
responses are not a reconstruction of KSP's native patch propagation.
"""
import math
import re
from types import SimpleNamespace as NS

import numpy as np

import check_landing_guidance as ks
from check_codebase import ROOT, function_body
from check_runtime_contracts import KList
from check_arrival_pe_recovery import Node
from check_surface_return import read_settings

SOURCE=(ROOT/'lib/arrival_bplane.ks').read_text()
# Mechanical loop adapter for the fixture subset; preserve iteration body,
# maximum count, line search, caps, convergence and node restoration.
SOURCE=SOURCE.replace('FROM { LOCAL i IS 0. } UNTIL i >= MAX_NEWTON_ITER STEP { SET i TO i + 1. } DO {',
                      'FOR i IN fixture_iterations {')
SOURCE=SOURCE.replace('REMOVE nd.','fixture_remove(nd).')
ks.SOURCES=SOURCE+'\n'+ks.SOURCES


def environment():
    env=dict(FD_STEP=.05,NEWTON_DAMP=.7,LIST=lambda *xs:KList(xs),
             fixture_wait=lambda _:None,SQRT=math.sqrt,ROUND=round,ABORT=False,
             _bplaneNodeAxisSet=lambda nd,axis,val:setattr(nd,axis,val),
             _bplaneNodeAxisGet=lambda nd,axis:getattr(nd,axis))
    env['_bplaneNewtonStep']=lambda *args:ks.call('_bplaneNewtonStep',env,*args)
    return env


def components(nd):return np.array((nd.PROGRADE,nd.RADIALOUT,nd.NORMAL))


def check_minimum_norm_step():
    rng=np.random.default_rng(927)
    for index in range(50):
        env=environment()
        jac=rng.normal(size=(2,3))*20000
        if index==0:
            # Radial and normal alone are singular; prograde is essential.
            jac=np.array(((0,3000,6000),(20000,0,0)))
        residual=rng.normal(size=2)*600000
        initial=rng.normal(size=3)
        nd=Node(1300,initial[1],initial[2],initial[0])
        desired=rng.normal(size=(2,3))*1000
        def measure(node,target):
            delta=components(node)-initial
            sample=residual+(jac+desired)@delta
            return dict(bt=sample[0],br=sample[1],desired=desired@delta)
        env['measureArrival']=measure
        env['targetBplaneVector']=lambda target,meas,*_:dict(bt=meas['desired'][0],br=meas['desired'][1])
        step=env['_bplaneNewtonStep'](nd,None,15000,90,-1,*residual)
        reference=np.linalg.lstsq(jac,-residual,rcond=None)[0]*env['NEWTON_DAMP']
        assert np.allclose(step,reference,rtol=1e-8,atol=1e-8),(step,reference)
        assert np.allclose(jac@step,-residual*env['NEWTON_DAMP'])
        # Minimum norm also means no unnecessary null-space component.
        null=np.linalg.svd(jac)[2][-1]
        assert abs(np.dot(null,step))<1e-7
        assert np.array_equal(components(nd),initial)
    print('PASS: 50 three-axis Newton steps match independent least squares, including essential prograde authority and a moving target vector; probes restore the original node')


def check_lost_and_singular_probes():
    env=environment()
    nd=Node(1300,0,0,0)
    residual=np.array((10000,20000))
    jac=np.array(((1000,2000,0),(0,1000,3000)))
    probes=[]
    def measure(node,target):
        vals=components(node)
        probes.append(vals.copy())
        if max(vals)>0:return 0
        sample=residual+jac@vals
        return dict(bt=sample[0],br=sample[1])
    env.update(measureArrival=measure,targetBplaneVector=lambda *_:dict(bt=0,br=0))
    step=env['_bplaneNewtonStep'](nd,None,15000,90,-1,*residual)
    assert len(probes)==6 and np.allclose(step,-.7*np.linalg.pinv(jac)@residual)
    assert nd.DELTAV.MAG==0
    for response in (lambda *_:0,lambda *_:dict(bt=10000,br=20000),
                     lambda node,_:dict(bt=10000+node.PROGRADE,br=20000+2*node.PROGRADE)):
        env['measureArrival']=response
        assert env['_bplaneNewtonStep'](nd,None,15000,90,-1,*residual)==[]
        assert nd.DELTAV.MAG==0
    print('PASS: lost positive probes try the opposite sign; lost/zero/rank-one response cannot invent a step or leave a sample node active')


def check_polar_solver_and_budget():
    env=environment()
    moon=NS(NAME='Mun',RADIUS=200000,SOIRADIUS=2429559)
    mu,vinf=6.5138398e10,272.804
    scale=mu/vinf**2
    radius=moon.RADIUS+15000
    desired=np.array((0,-math.sqrt(radius**2+2*scale*radius)))
    baseline=np.array((-638900.,-13900.))  # Supplied flight B-vector.
    jac=np.array(((5000,20000,0),(-20000,0,5000)))
    nodes,removed,holds,decisions=[],[],[],[]
    def measure(node,target):
        point=baseline+jac@components(node)
        bmag=np.linalg.norm(point)
        pe=math.hypot(scale,bmag)-scale-moon.RADIUS
        plane=math.degrees(math.acos(np.clip(np.dot(point,desired)/(bmag*np.linalg.norm(desired)),-1,1)))
        return dict(bt=point[0],br=point[1],pe=pe,plane=plane)
    target=dict(bt=desired[0],br=desired[1],offPlane=0)
    env.update(NODE=Node,TIME=NS(SECONDS=1000),BPLANE_LEAD=300,
               BPLANE_PE_TOL=2000,BPLANE_ANG_TOL=.2,BPLANE_REQUIRE_PLANE=1,
               BPLANE_REVIEW_UNCONVERGED=0,BPLANE_OFFPLANE_TOL=10,
               fixture_iterations=range(int(re.search(r'LOCAL MAX_NEWTON_ITER\s+IS (\d+)',SOURCE)[1])),
               fixture_add=nodes.append,fixture_remove=removed.append,
               bplaneResetWarnings=lambda:None,measureArrival=measure,
               targetBplaneVector=lambda *_:target,
               _bplaneCorridorError=lambda bod,meas,pe,*_:dict(peErr=meas['pe']-pe,planeErr=meas['plane'],target=target),
               _bplaneFallbackSearch=lambda *_:False,
               _bplaneHoldCorrection=holds.append,
               _bplaneQueueMidcourseRetry=lambda reason:decisions.append(reason) or False)
    for name in ('_bplaneCorridorOk','_bplanePlanScore','_bplanePlaneFeasible'):
        env[name]=lambda *args,name=name:ks.call(name,env,*args)
    assert 8000<measure(Node(0,0,0,0),moon)['pe']<9000
    assert 88<measure(Node(0,0,0,0),moon)['plane']<90
    result=ks.call('_bplanePlanFullAttempt',env,moon,15000,90,-1,10,'',True)
    assert result==-1 and nodes[-1] in removed and not holds
    assert nodes[-1].DELTAV.MAG<=10.00001 and decisions==['unconverged-optional-correction']
    result=ks.call('_bplanePlanFullAttempt',env,moon,15000,90,-1,100,'',True)
    assert result and result!=-1 and result not in removed and not holds
    final=measure(result,moon)
    assert abs(final['pe']-15000)<=2000 and final['plane']<=.2 and result.DELTAV.MAG<=100
    cfg=read_settings((ROOT/'missions/RO9/mun_landing_return.ks').read_text(),{})
    assert cfg['BPLANE_REQUIRE_PLANE']==1 and cfg['CAPTURE_INC']==90
    assert cfg['BPLANE_DV_CAP']==cfg['BPLANE_TRIM_DV_CAP']==100
    assert cfg['REFINE_BPLANE_DV_CAP']==100 and cfg['BPLANE_TRIM_TOTAL_DV_CAP']==150
    assert cfg['BPLANE_TRIM_RESERVE_DV']==cfg['BPLANE_CAPTURE_MARGIN']==900
    assert cfg['BPLANE_MAX_ARRIVAL_SHIFT']==600 and cfg['BPLANE_MAX_CAPTURE_DV_INCREASE']==5
    # Independent conic capture estimate, not a proof of the live burn cost.
    parking_ap=moon.RADIUS+cfg['TARGET_AP']
    capture=math.sqrt(vinf**2+2*mu/radius)-math.sqrt(mu*(2/radius-2/(radius+parking_ap)))
    assert result.DELTAV.MAG+capture+cfg['BPLANE_CAPTURE_MARGIN']<2019.1
    gate=function_body(SOURCE,'bplaneCorrectionAllowed')
    assert 'required-arrival-corridor' in gate and 'correction-plus-capture-budget' in gate
    env['ABORT']=True
    assert ks.call('_bplanePlanFullAttempt',env,moon,15000,90,-1,100,'',True)==0
    assert nodes[-1] in removed
    print('PASS: full source solver on a synthetic polar encounter rejects a saturated 10 m/s candidate and converges within 100 m/s; RO9 keeps finite caps, required plane, arrival/capture guards and 900 m/s after-capture margin')


if __name__=='__main__':
    check_minimum_norm_step()
    check_lost_and_singular_probes()
    check_polar_solver_and_budget()
