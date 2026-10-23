"""Source-driven moon-return Pe refinement; not native KSP propagation."""
import re
import math
from types import SimpleNamespace as NS

import numpy as np

import check_landing_guidance as ks
from check_codebase import ROOT, function_body, mask
from check_runtime_contracts import run

SOURCE=(ROOT/'lib/return_escape.ks').read_text()
ks.SOURCES+='\n'+SOURCE


class Node:
    def __init__(self, dv=170.2):self.PROGRADE=dv;self.NORMAL=0;self.TIME=2024
    @property
    def DELTAV(self):return NS(MAG=math.hypot(self.PROGRADE,self.NORMAL))
    def ISTYPE(self,name):return name=='Node'


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
    assert phase.index('IF ABORT OR NOT _returnEscapeEntryValid(')<phase.index('executeManeuver()')
    assert 'OR nd:DELTAV:MAG > SHIP:DELTAV:VACUUM' in phase
    clean=mask(function_body(SOURCE,'_polishReturnEscapePe'))
    assert not re.search(r'\b(?:ADD|REMOVE|STAGE|LOCK|UNLOCK|REBOOT)\b',clean)
    mcc=function_body((ROOT/'lib/maneuver_mcc.ks').read_text(),'_mccReturn')
    assert 'newtonTarget(nd, target, "PE", targetPe' in mcc
    assert '_mccAerobrakePatchSafe(SHIP:ORBIT, target, targetPe)' in mcc
    print('PASS: refinement precedes final validation without executing/removing the node; original entry/fuel guards and actual-orbit return MCC remain')


def joint_fixture(predict, budget=1195.756958):
    env=ks.environment();node=Node(190.2493);queries=[]
    env['SHIP'].ORBIT=NS(PERIOD=2*math.pi*math.sqrt(69750**3/1.7658e9))
    env['SHIP'].DELTAV=NS(VACUUM=budget)
    def patch(nd,parent):
        queries.append((nd.TIME,nd.PROGRADE,nd.NORMAL))
        pe=predict(nd)
        return 0 if pe is None else NS(PERIAPSIS=pe)
    env.update(_targetPatch=patch,fixture_wait=lambda seconds:setattr(env['TIME'],'SECONDS',env['TIME'].SECONDS+seconds))
    env['_returnEscapeTrial']=lambda *args:ks.call('_returnEscapeTrial',env,*args)
    return env,node,queries


def joint(env,node,seed=190.2493):return ks.call('_jointReturnEscape',env,node,NS(NAME='Kerbin',MU=3.5316e12,RADIUS=600000),53000,seed)


def check_stationary_plane_and_joint_bounds():
    # Reproduce a flat prograde response at a bad fixed-plane minimum, with
    # the reported Pe. A normal adjustment is necessary to reach the corridor.
    def prediction(nd):
        return 53000+((nd.TIME-2024)*30)**2/1000+(nd.PROGRADE-190.2493)**2*1000+(nd.NORMAL-40)**2*953.49135
    env,node,queries=joint_fixture(prediction)
    assert not polish(env,node) and abs(prediction(node)-1578586.16)<1
    assert joint(env,node),(node.TIME,node.PROGRADE,node.NORMAL,prediction(node))
    assert abs(prediction(node)-53000)<=1000 and abs(node.NORMAL)>30
    assert len(queries)<=280 and node.DELTAV.MAG<=1195.756958
    assert env['RETURN_ESCAPE_PE_TOLERANCE']==1000
    for fault in ('no-patch','flat','fuel','abort','deadline'):
        law=(lambda nd:None) if fault=='no-patch' else (lambda nd:1578586.16)
        env,node,queries=joint_fixture(law,budget=10 if fault=='fuel' else 1195.756958)
        if fault=='abort':env['ABORT']=True
        if fault=='deadline':env['fixture_wait']=lambda seconds:setattr(env['TIME'],'SECONDS',env['TIME'].SECONDS+5)
        assert not joint(env,node)
        assert len(queries)<=230 and node.DELTAV.MAG<=env['SHIP'].DELTAV.VACUUM
        if fault=='abort':assert not queries
        if fault=='deadline':assert len(queries)<=4
    print('PASS: reported-scale flat-plane minimum requires a coupled normal correction; joint native-response search obeys fuel/trial/deadline/Abort bounds without widening the1km entry gate')


def patched_conic_prediction(inclination=25.14, ascending_node=0, mirror=1):
    """Independent Cartesian Kepler orbit -> moon SOI -> parent Pe oracle.

    Instantaneous burn and spherical SOI, not native KSP/finite-burn proof.
    """
    mu, parent_mu, moon_distance, soi=1.7658e9,3.5316e12,47e6,2247428.
    rp,ra=69500.,70000.;semi=(rp+ra)/2;ecc=(ra-rp)/(ra+rp)
    rate=math.sqrt(mu/semi**3);moon_rate=math.sqrt(parent_mu/moon_distance**3)
    inc,lan=math.radians(inclination),math.radians(ascending_node)
    peri=np.array((math.cos(lan),math.sin(lan),0.))
    transverse=np.array((-math.sin(lan)*math.cos(inc),math.cos(lan)*math.cos(inc),math.sin(inc)))
    plane=np.cross(peri,transverse)
    def predict(nd):
        mean=nd.TIME*rate;anomaly=mean
        for _ in range(5):anomaly-=(anomaly-ecc*math.sin(anomaly)-mean)/(1-ecc*math.cos(anomaly))
        pos=semi*((math.cos(anomaly)-ecc)*peri+math.sqrt(1-ecc**2)*math.sin(anomaly)*transverse)
        vel=semi*rate/(1-ecc*math.cos(anomaly))*(-math.sin(anomaly)*peri+math.sqrt(1-ecc**2)*math.cos(anomaly)*transverse)
        vel=vel+nd.PROGRADE*vel/np.linalg.norm(vel)+mirror*nd.NORMAL*plane
        radius=np.linalg.norm(pos);energy=np.dot(vel,vel)/2-mu/radius
        if energy<=0:return None
        hvec=np.cross(pos,vel);h2=np.dot(hvec,hvec)
        evec=np.cross(vel,hvec)/mu-pos/radius;e=np.linalg.norm(evec)
        if e<=1:return None
        latus=h2/mu;cosine=(latus/soi-1)/e
        if abs(cosine)>1:return None
        nu=math.acos(cosine);sin_nu=math.sin(nu)
        peri_axis=evec/e;cross_axis=np.cross(hvec/math.sqrt(h2),peri_axis)
        current_sin=np.dot(pos/radius,cross_axis);current_cos=np.dot(pos/radius,peri_axis)
        def anomaly_time(sin_angle,cos_angle):
            hyper=math.asinh(math.sqrt(e*e-1)*sin_angle/(1+e*cos_angle))
            return math.sqrt((mu/(2*energy))**3/mu)*(e*math.sinh(hyper)-hyper)
        travel=anomaly_time(sin_nu,cosine)-anomaly_time(current_sin,current_cos)
        boundary=soi*(cosine*peri_axis+sin_nu*cross_axis)
        outward=math.sqrt(mu/latus)*(-sin_nu*peri_axis+(e+cosine)*cross_axis)
        phase=(nd.TIME+travel)*moon_rate
        parent_pos=moon_distance*np.array((math.cos(phase),math.sin(phase),0.))+boundary
        parent_vel=moon_distance*moon_rate*np.array((-math.sin(phase),math.cos(phase),0.))+outward
        parent_h=np.cross(parent_pos,parent_vel);parent_h2=np.dot(parent_h,parent_h)
        parent_energy=np.dot(parent_vel,parent_vel)/2-parent_mu/np.linalg.norm(parent_pos)
        parent_e=math.sqrt(max(0,1+2*parent_energy*parent_h2/parent_mu**2))
        return parent_h2/(parent_mu*(1+parent_e))-600000
    return predict


def check_inclined_minmus_conics():
    results=[]
    vinf=math.sqrt(3.5316e12/47e6)-math.sqrt(3.5316e12*(2/47e6-2/(47e6+653000)))
    seed=math.sqrt(vinf**2+2*1.7658e9/69500)-math.sqrt(1.7658e9*(2/69500-1/69750))
    for lan,mirror in ((0,1),(90,1),(180,1),(90,-1)):
        predict=patched_conic_prediction(ascending_node=lan,mirror=mirror)
        env,node,queries=joint_fixture(predict)
        assert joint(env,node,seed),(lan,mirror,node.TIME,node.PROGRADE,node.NORMAL,predict(node),len(queries))
        assert abs(predict(node)-53000)<=1000 and node.DELTAV.MAG<=1195.756958
        results.append((lan,mirror,round(node.DELTAV.MAG,1),round(predict(node))))
    print('PASS: independent25deg 9.5x10km Minmus Kepler/SOI conics reach unchanged Kerbin entry corridor with both normal signs; (LAN,handedness,dV,Pe)=',results)


def check_optional_ksc_preference():
    env,node,queries=joint_fixture(lambda nd:53000)
    env['ESCAPE_KSC_TARGET']=1
    env['SHIP'].BODY.ORBIT=NS(SEMIMAJORAXIS=47e6)
    env['_escapeKscPenalty']=lambda nd,*args:10000-nd.TIME
    assert joint(env,node)
    assert node.TIME>env['SHIP'].ORBIT.PERIOD*.85
    assert node.DELTAV.MAG<=1195.756958
    print('PASS: optional KSC longitude penalty remains a secondary preference among corridor-valid fallback candidates; it cannot buy acceptance outside the entry gate')


def without_prints(nodes):
    return [(statement,without_prints(yes),without_prints(no)) for statement,yes,no in nodes
            if not statement.startswith('PRINT ')]


def check_rejected_plan_cleanup():
    source=function_body(SOURCE,'phaseEscape').replace('REMOVE nd.','fixture_remove(nd).')
    for fault in ('entry','fuel','lost-patch','abort','operator-node','accepted'):
        env,node,_=joint_fixture(lambda nd:1578586.16)
        nodes=[];events=[]
        parent=NS(NAME='Kerbin')
        env.update(BODY=NS(BODY=parent,NAME='Minmus'),HASNODE=fault=='operator-node',
                   xferSeq=['ESCAPE','COAST','MCC'],ROUND=round,
                   _returnTargetPe=lambda:53000,
                   fixture_remove=lambda nd:events.append(('remove',nd)) or nodes.remove(nd),
                   _returnEscapeEntryValid=lambda pe,target:ks.call('_returnEscapeEntryValid',env,pe,target),
                   yieldToPrompt=lambda:events.append(('yield',)),
                   nextPhase=lambda seq:events.append(('advance',)),
                   executeManeuver=lambda:events.append(('burn',)) or True)
        env['SHIP'].ORBIT.ECCENTRICITY=.0035;env['SHIP'].ORBIT.HASNEXTPATCH=False
        def plan(*args):
            nodes.append(node)
            if fault=='abort':env['ABORT']=True
            return node
        env['_planReturnEscape']=plan
        env['_targetPatch']=lambda *args:0 if fault=='lost-patch' else NS(PERIAPSIS=1578586.16 if fault=='entry' else 53000)
        if fault=='fuel':env['SHIP'].DELTAV.VACUUM=100
        if fault=='operator-node':nodes.append('manual')
        try:ks.run(without_prints(ks.parse(source)),env)
        except ks.Returned:pass
        if fault=='accepted':
            assert events==[('burn',),('advance',)]
        elif fault=='operator-node':
            assert nodes==['manual'] and events==[('yield',)]
        else:
            assert not nodes and events==[('remove',node),('yield',)],(fault,events)
    print('PASS: actual ESCAPE entry/fuel/patch/Abort rejection removes only its unflown node before yielding; pre-existing operator nodes are preserved and accepted nodes alone reach the burn')


if __name__=='__main__':
    check_reported_weighted_score()
    check_nonlinear_and_failure_guards()
    check_acceptance_and_pipeline()
    check_stationary_plane_and_joint_bounds()
    check_inclined_minmus_conics()
    check_optional_ksc_preference()
    check_rejected_plan_cleanup()
