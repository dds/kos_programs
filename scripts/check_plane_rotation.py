"""Large SHAPE plane seeds against independent 3D impulsive conics, not KSP."""
import math
import re
from types import SimpleNamespace as NS
import numpy as np

from check_codebase import ROOT, function_body
from check_minmus_kolniya import execute as run_source
from check_arrival_budget import shape_admission

SOURCE=(ROOT/'lib/orbit_shape.ks').read_text()


def execute(source,env):
    return run_source(re.sub(r'PARAMETER [^.]+\.', '', source),env)


def angle(a,b):
    return math.degrees(math.acos(np.clip(np.dot(a,b)/np.linalg.norm(a)/np.linalg.norm(b),-1,1)))


class Sequence(list):
    LENGTH=property(len)


class Node:
    def __init__(self,fixture,ut=1000):
        self.fixture=fixture;self.TIME=ut
        self.NORMAL=self.PROGRADE=self.RADIALOUT=0
        self.ta=fixture['SHIP'].ORBIT.TRUEANOMALY
        self.alive=True
    ETA=property(lambda self:self.TIME-self.fixture['TIME'].SECONDS)
    DELTAV=property(lambda self:NS(MAG=math.sqrt(self.NORMAL**2+self.PROGRADE**2+self.RADIALOUT**2)))
    @property
    def ORBIT(self):
        assert self.alive,'detached node inspected'
        env=self.fixture;ship=env['SHIP'];mu=ship.BODY.MU
        ecc=ship.ORBIT.ECCENTRICITY;p=ship.ORBIT.SEMIMAJORAXIS*(1-ecc*ecc)
        radius=p/(1+ecc*math.cos(math.radians(self.ta)))
        vr=math.sqrt(mu/p)*ecc*math.sin(math.radians(self.ta))
        vt=math.sqrt(mu*p)/radius
        inc=math.radians(ship.ORBIT.INCLINATION)
        r=np.array([radius,0,0]);v=np.array([vr,vt*math.cos(inc),vt*math.sin(inc)])
        h=np.cross(r,v);normal=h/np.linalg.norm(h)
        prograde=v/np.linalg.norm(v)
        radial=np.cross(prograde,normal)
        after=v+self.PROGRADE*prograde+self.NORMAL*normal*env['normal_sign']+self.RADIALOUT*radial*env['radial_sign']
        h=np.cross(r,after);energy=np.dot(after,after)/2-mu/radius
        evec=np.cross(after,h)/mu-r/radius
        e=float(np.linalg.norm(evec));sma=-mu/(2*energy)
        n=h/np.linalg.norm(h)
        o=NS(ECCENTRICITY=e,PERIAPSIS=sma*(1-e)-ship.BODY.RADIUS,
             APOAPSIS=sma*(1+e)-ship.BODY.RADIUS,normal=n,
             INCLINATION=angle(n,np.array([0,0,1])),LAN=127.92)
        if env.get('fault')=='floor':o.PERIAPSIS=79999
        if env.get('fault')=='unbound':o.ECCENTRICITY=1
        if env.get('fault')=='nan':o.APOAPSIS=math.nan
        return o


def fixture(inc=55.156,target_inc=0,ecc=0,ta=0,normal_sign=-1,radial_sign=1):
    rp=3463250 if ecc==0 else 1300000
    sma=rp/(1-ecc);radius=600000;mu=3.5316e12
    ship=NS(BODY=NS(NAME='Kerbin',RADIUS=radius,MU=mu),
            PERIAPSIS=rp-radius,APOAPSIS=sma*(1+ecc)-radius,
            ORBIT=NS(INCLINATION=inc,LAN=127.92,TRUEANOMALY=ta,
                ECCENTRICITY=ecc,SEMIMAJORAXIS=sma,PERIOD=2*math.pi*math.sqrt(sma**3/mu)))
    env=dict(SHIP=ship,TIME=NS(SECONDS=0),WARP=0,ABORT=False,normal_sign=normal_sign,radial_sign=radial_sign,
        _shapePlanningReady=lambda:True,_peFloor=lambda:80000,
        LIST=lambda *xs:Sequence(xs),SQRT=math.sqrt,
        SIN=lambda x:math.sin(math.radians(x)),COS=lambda x:math.cos(math.radians(x)),
        VANG=angle,_planeErrOf=lambda o,n:angle(o.normal,n),
        fixture_wait=lambda _:None,ROUND=round,maneuverUiArchiveLog=lambda _:None)
    env['_radiusAtTa']=lambda f:sma*(1-ecc*ecc)/(1+ecc*math.cos(math.radians(f)))
    env['_speedAtTa']=lambda f:math.sqrt(mu*(2/env['_radiusAtTa'](f)-1/sma))
    env['_planeNodeCost']=lambda nd,n,pe,ap,floor:execute(function_body(SOURCE,'_planeNodeCost'),
        dict(env,nd=nd,nTgt=n,pe0=pe,ap0=ap,peFloor=floor))
    # Adapt native nested delegate syntax; run its actual cost body against
    # the helper's current scope. The orbit response above is independent.
    def seed(nd,f,theta,n):
        nd.ta=f
        local=dict(env,nd=nd,burnTa=f,theta=theta,nTgt=n)
        code=function_body(SOURCE,'_seedPlaneRotation')
        cost=function_body(code,'cost')
        code=re.sub(r'LOCAL FUNCTION cost \{.*?\n    \}', '',code,flags=re.S).replace('cost@','fixture_cost')
        local['fixture_cost']=lambda:execute(cost,local)
        local['_stableEval']=lambda fn:execute(function_body(SOURCE,'_stableEval'),dict(local,costFn=NS(CALL=fn)))
        return execute(code,local)
    env['_seedPlaneRotation']=seed
    target=np.array([0,-math.sin(math.radians(target_inc)),math.cos(math.radians(target_inc))])
    node=Node(env)
    return env,node,target,abs(inc-target_inc)


def check_recorded_large_plane():
    env,node,target,theta=fixture()
    speed=env['_speedAtTa'](0)
    node.NORMAL=2*speed*math.sin(math.radians(theta/2))
    old=node.ORBIT
    assert abs(old.INCLINATION-12.36)<.03 # Native seedErr12.36 atUT4868219.
    assert old.APOAPSIS-env['SHIP'].APOAPSIS>10000000
    assert env['_seedPlaneRotation'](node,0,theta,target)
    after=node.ORBIT
    assert angle(after.normal,target)<1e-5
    assert abs(after.PERIAPSIS-env['SHIP'].PERIAPSIS)<1e-5
    assert abs(after.APOAPSIS-env['SHIP'].APOAPSIS)<1e-5
    assert 828<abs(node.NORMAL)<831 and -435<node.PROGRADE<-431
    assert 934<node.DELTAV.MAG<936
    print('PASS: reported55.156deg circular seed reproduces12.36deg error and >10000km Ap inflation; actual coupled seed preserves apsides and reaches target plane at~935m/s')


def check_eccentric_rotation_and_guards():
    cases=0
    for ecc in (0,.25,.82):
        for ta in (0,40,220):
            for inc,target_inc in ((55.156,0),(99,55),(169.41,180),(0,180)):
                for n_sign,r_sign in ((1,1),(1,-1),(-1,1),(-1,-1)):
                    env,node,target,theta=fixture(inc,target_inc,ecc,ta,n_sign,r_sign)
                    assert env['_seedPlaneRotation'](node,ta,theta,target)
                    after=node.ORBIT
                    assert angle(after.normal,target)<1e-5
                    assert abs(after.PERIAPSIS-env['SHIP'].PERIAPSIS)<1e-5
                    assert abs(after.APOAPSIS-env['SHIP'].APOAPSIS)<1e-4
                    assert after.PERIAPSIS>=80000 and after.ECCENTRICITY<1
                    cases+=1
    for fault in ('floor','unbound','nan'):
        env,node,target,theta=fixture();env['fault']=fault
        assert not env['_seedPlaneRotation'](node,0,theta,target)
    # The correction's physical cost must STILL pass all three admission
    # checks. Native boot012 had935.5m/s before its122.05m/s circularization.
    cfg=dict(SHAPE_DV_CAP=1600,SHAPE_TOTAL_DV_CAP=5000,SHAPE_RESERVE_DV=100)
    assert not shape_admission(cfg,935,3379.9,813.5)
    assert shape_admission(cfg,935,3379.9,1100)
    assert not shape_admission(dict(cfg,SHAPE_TOTAL_DV_CAP=4135.8),935,3379.9,1100)
    print(f'PASS: {cases} independent eccentric/circular/prograde/retrograde rotations preserve speed/apsides with either native axis sign; unsafe/unbound/invalid predictions and insufficient fuel/allowance remain rejected')


def check_planner_integration():
    env,_,target,theta=fixture();created=[];removed=[]
    inc=env['SHIP'].ORBIT.INCLINATION
    env.update(targetInc=0,targetLan=127.92,beforeUt=-1,
        _shipNormal=lambda:np.array([0,-math.sin(math.radians(inc)),math.cos(math.radians(inc))]),
        planeNormalFromIncLan=lambda *_:target,
        orbitNodeAngleToRelativeAscending=lambda *_:0,orbitNodeAngleToRelativeDescending=lambda *_:180,
        etaToTrueAnomaly=lambda f:1000+f,
        _refinePlaneNode=lambda nd,n:angle(nd.ORBIT.normal,n))
    def node(ut,radial,normal,prograde):
        nd=Node(env,ut);nd.RADIALOUT=radial;nd.NORMAL=normal;nd.PROGRADE=prograde
        created.append(nd);return nd
    def remove(nd):nd.alive=False;removed.append(nd)
    env.update(NODE=node,fixture_add=lambda _:None,fixture_remove=remove)
    code=function_body(SOURCE,'planPlaneMatch').replace('ADD nd.','fixture_add(nd).').replace('REMOVE nd.','fixture_remove(nd).')
    nd=execute(code,env)
    assert nd is created[0] and nd.alive and not removed
    assert angle(nd.ORBIT.normal,target)<1e-5
    # Existing hard rejection of a failed numerical refiner remains.
    env['_refinePlaneNode']=lambda *_:20.41
    assert execute(code,env)==0 and removed==[created[-1]]
    print('PASS: actual planner uses the coupled seed before native refinement, returns the validated node and still discards a20.41deg failed refinement')


if __name__=='__main__':
    check_recorded_large_plane()
    check_eccentric_rotation_and_guards()
    check_planner_integration()
