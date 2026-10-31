"""Optional arrival-plane feasibility, real solver source; no native KSP VM."""
import math
from types import SimpleNamespace as NS
import numpy as np

import check_entry_landing as entry
from check_bplane_measurement import Vector,MATH,ARRIVAL
from check_deorbit_geometry import dot,cross
from check_espoir_fleet import Map,Items,profile
from check_arrival_pe_recovery import Node


def angle(a,b):return math.degrees(math.acos(np.clip(dot(a,b)/(a.MAG*b.MAG),-1,1)))


def fixture(declination=.3,vinf2=2375493.76499886):
    pole=Vector((0,-1,0))
    # Recorded Ike Lander2 asymptote azimuth; the fitted node logged0.3deg
    # offPlane. This fixture freezes that tilt and supplies a linear native
    # response adapter; it is not a replay of KSP's undisclosed Jacobian.
    horizontal=Vector((.983897459579055,0,.178699442273261));horizontal/=horizontal.MAG
    s=math.cos(math.radians(declination))*horizontal+math.sin(math.radians(declination))*pole
    t=cross(s,pole)
    if t.MAG<1e-8:t=cross(s,Vector((1,0,0)))
    t=t.NORMALIZED;r=cross(s,t).NORMALIZED
    body=NS(NAME='Duna',RADIUS=320000,MU=3.0136321e11,SOIRADIUS=47921949,ANGULARVEL=pole)
    scale=body.MU/vinf2
    world=dict(base=np.array((-26193932.6761307,-20412772.9099809)),valid=True)
    jac=np.array(((2e6,.1e6,.3e6),(.3e6,1.2e6,2.3e6)))
    def point(node):
        return world['base'] if not node else world['base']+jac@np.array((node.PROGRADE,node.RADIALOUT,node.NORMAL))
    def conic(node):
        bt,br=point(node);b=bt*t+br*r;bmag=b.MAG;bhat=b/bmag
        h=-cross(s,bhat).NORMALIZED
        pe=math.hypot(scale,bmag)-scale-body.RADIUS
        ecc=1+(body.RADIUS+pe)*vinf2/body.MU
        ehat=s/ecc+math.sqrt(1-1/ecc**2)*bhat
        return Map(S=s,hHat=h,bHat=bhat,eHat=ehat,bMag=bmag,bt=bt,br=br,tHat=t,rHat=r,
            dotBT=dot(bhat,t),dotBR=dot(bhat,r),tHatMag=1,rHatMag=1,bHatMag=1,vinf2=vinf2,
            pe=pe,inc=angle(h,pole),lan=115.022615390784)
    def measure(node,target):return conic(node) if world['valid'] else 0
    def patch(node=0):
        m=conic(node)
        return NS(PERIAPSIS=m['pe'],INCLINATION=m['inc'],LAN=m['lan'])
    env=dict(V=lambda *xs:Vector(xs),VDOT=dot,VCRS=cross,VANG=angle,SQRT=math.sqrt,
        SIN=lambda x:math.sin(math.radians(x)),COS=lambda x:math.cos(math.radians(x)),
        ARCCOS=lambda x:math.degrees(math.acos(x)),LEX=lambda *xs:Map(zip(xs[::2],xs[1::2])),
        _BPLANE_OFFPLANE_WARNED=False,fixture_log=lambda:None,
        BPLANE_REQUIRE_PLANE=0,BPLANE_ANG_TOL=.2,BPLANE_PE_TOL=5000,BPLANE_OFFPLANE_TOL=10,
        measureArrival=measure,findArrivalPatch=lambda *_:dict(patch=patch()),arrivalGoalPolicyOk=lambda *_:True,
        FD_STEP=.05,NEWTON_DAMP=.7,LIST=lambda *xs:Items(xs),fixture_wait=lambda _:None,
        fixture_iterations=range(16),BPLANE_REVIEW_UNCONVERGED=0,ABORT=False)
    for name in ('_arrivalInclinationNormal','targetBplaneVector'):
        env[name]=lambda *args,name=name:entry.call(MATH,name,env,*args)
    for name in ('_bplaneElementPlaneError','_bplaneCorridorError','_bplaneCorridorOk','_bplanePlaneFeasible',
                 '_bplanePlanScore','_bplaneCurrentCorridorOk','_bplaneNewtonStep','_bplaneNodeAxisSet','_bplaneNodeAxisGet'):
        env[name]=lambda *args,name=name:entry.call(ARRIVAL,name,env,*args)
    return env,body,world,measure,point,patch


def check_recorded_optional_equatorial_floor():
    env,body,world,measure,_,_=fixture()
    initial=measure(0,body)
    target=env['targetBplaneVector'](body,initial,85000,0,-1,True)
    assert abs(target['offPlane']-.3)<1e-9
    assert abs(dot(target['normal'],initial['S']))<1e-12
    assert abs(angle(target['normal'],body.ANGULARVEL)-.3)<1e-9
    # Exact85km/closest-plane conic, despite its native0.3deg inclination.
    world['base']=np.array((target['bt'],target['br']))
    meas=measure(0,body);err=env['_bplaneCorridorError'](body,meas,85000,0,-1)
    assert abs(meas['inc']-.3)<1e-9 and err['planeErr']<1e-5
    assert env['_bplaneCorridorOk'](err,0,5000,.2) and env['_bplanePlanScore'](err,body,0)==0
    assert env['_bplaneCurrentCorridorOk'](body,85000,0,-1)
    # Required-plane mode must still reject exactly the same physical conic.
    env['BPLANE_REQUIRE_PLANE']=1
    required=env['_bplaneCorridorError'](body,meas,85000,0,-1)
    assert abs(required['planeErr']-.3)<1e-9
    assert not env['_bplaneCorridorOk'](required,0,5000,.2)
    assert not env['_bplaneCurrentCorridorOk'](body,85000,0,-1)
    assert env['_bplanePlanScore'](required,body,0)>0
    env['BPLANE_REQUIRE_PLANE']=0;world['valid']=False
    assert not env['_bplaneCurrentCorridorOk'](body,85000,0,-1) # Raw incl alone cannot prove projected admission.
    for mission in ('ike_lander','ike_orbital_surveyor'):
        cfg=profile(mission)
        assert cfg['BPLANE_REQUIRE_PLANE']==0 and cfg['CAPTURE_INC']==0
        assert cfg['IKE_MISSION_SETTINGS']['BPLANE_REQUIRE_PLANE']==1
    assert profile('duna_lander')['BPLANE_REQUIRE_PLANE']==1
    print('PASS: recorded85km/0.3deg conic passes the shared optional-plane metric/current-patch path, fails required-plane mode and fails unavailable-vector proof; both Ike parent captures are optional and their final polar captures stay required')


def check_whole_solver_optional_vs_required():
    loop=ARRIVAL.replace('FROM { LOCAL i IS 0. } UNTIL i >= MAX_NEWTON_ITER STEP { SET i TO i + 1. } DO {',
                         'FOR i IN fixture_iterations {').replace('REMOVE nd.','fixture_remove(nd).')
    for required,declination in ((False,.3),(True,.3),(False,.35),(True,.35)):
        env,body,world,measure,point,_=fixture(declination,2015506.3588431 if declination==.35 else 2375493.76499886)
        if declination==.35:world['base']=np.array((25353717.6053679,-21950976.423671))
        nodes=[];removed=[];decisions=[]
        def create(*_):
            nd=Node(1300,0,0,0);nodes.append(nd);return nd
        env.update(BPLANE_REQUIRE_PLANE=int(required),_bplaneCreateCorrectionNode=create,
            bplaneResetWarnings=lambda:None,_bplaneFallbackSearch=lambda *_:False,
            _bplaneHoldCorrection=lambda *_:decisions.append('hold'),
            _bplaneQueueMidcourseRetry=lambda reason:decisions.append(reason) or False,
            fixture_remove=removed.append)
        result=entry.call(loop,'_bplanePlanFullAttempt',env,body,85000,0,-1,150,'',True)
        if required:
            assert result==-1 and removed==nodes and decisions==['unconverged-optional-correction']
        else:
            assert result is nodes[0] and not removed and not decisions
            assert .3<result.DELTAV.MAG<20
            meas=measure(result,body)
            assert abs(meas['pe']-85000)<=5000 and abs(meas['inc']-declination)<.2
            assert not env['_bplaneCurrentCorridorOk'](body,85000,0,-1) # Unburned orbit is still far away.
            world['base']=point(result)
            assert env['_bplaneCurrentCorridorOk'](body,85000,0,-1)
    print('PASS: actual bounded Newton kernel converges the synthetic native-scale16m/s-class correction only in optional mode; required mode removes the failed node/delegates retry, and a pending candidate never substitutes for the unburned orbit')


def check_inclination_boundaries_and_degeneracy():
    # Independent feasible interval: |asin(S.north)| <= inclination <=180-that.
    cases=0
    for declination in (0,.05,math.degrees(math.asin(.00350690249477888)),.3,.35,8,30,80,90,-.3,-80):
        env,body,_,measure,_,_=fixture(declination)
        meas=measure(0,body)
        floor=abs(declination)
        for requested in (0,.1,5,20,63.4,90,116.6,175,180):
            expected=max(floor,min(180-floor,requested))
            desired=env['_arrivalInclinationNormal'](body,meas,requested)
            assert abs(angle(desired,body.ANGULARVEL)-requested)<1e-5,(declination,requested,desired)
            target=env['targetBplaneVector'](body,meas,85000,requested,-1,True)
            normal=target['normal']
            assert np.isfinite(normal).all() and abs(normal.MAG-1)<1e-10
            assert abs(dot(normal,meas['S']))<1e-8,(declination,requested,normal)
            assert abs(angle(normal,body.ANGULARVEL)-expected)<1e-5,(declination,requested,expected,normal)
            assert abs(target['offPlane']-abs(expected-requested))<1e-5
            cases+=1
    # Keep native Pe/angle guards: proximity to a feasible plane cannot
    # accept a missed Pe, wrong plane, failed policy or nonfinite elements.
    env,body,world,measure,_,patch=fixture();initial=measure(0,body)
    target=env['targetBplaneVector'](body,initial,85000,0,-1,True)
    world['base']=np.array((target['bt'],target['br']))
    baseline=world['base'].copy()
    for fault in ('pe-low','pe-high','native-policy','wrong-plane','nan-plane'):
        world['base']=baseline.copy()
        p=patch()
        if fault=='pe-low':p.PERIAPSIS=79999
        if fault=='pe-high':p.PERIAPSIS=90001
        if fault=='native-policy':env['arrivalGoalPolicyOk']=lambda *_:False
        if fault=='wrong-plane':world['base']=world['base'][::-1].copy()
        if fault=='nan-plane':p.INCLINATION=math.nan
        env['findArrivalPatch']=lambda *_:dict(patch=p)
        assert not env['_bplaneCurrentCorridorOk'](body,85000,0,-1),fault
        env['arrivalGoalPolicyOk']=lambda *_:True
    print(f'PASS:{cases} independent inclination/asymptote pairs hit the analytically nearest feasible boundary, including polar/prograde/retrograde degeneracy; Pe/native-policy/nonfinite/wrong-plane guards remain')


if __name__=='__main__':
    check_recorded_optional_equatorial_floor()
    check_whole_solver_optional_vs_required()
    check_inclination_boundaries_and_degeneracy()
