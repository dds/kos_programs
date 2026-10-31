"""Run departure refinement/gates against synthetic encounter responses.

Includes an analytic hyperbolic Pe response; not a KSP transfer simulation.
Run: python3 -B scripts/check_departure_pe.py
"""
import math
from types import SimpleNamespace as NS
import check_landing_guidance as ks
from check_launch_and_staging import body

SOURCE = (ks.ROOT / 'lib/maneuver_transfer.ks').read_text()
ks.SOURCES += '\n' + SOURCE


class KList(list):
    ADD = list.append


class Node:
    def __init__(self):
        self.PROGRADE, self.RADIALOUT, self.NORMAL = 860., 0., 0.
        self.TIME = 1000.
        self.ORBIT = NS(HASNEXTPATCH=False)

    @property
    def DELTAV(self):
        return NS(MAG=math.sqrt(self.PROGRADE**2+self.RADIALOUT**2+self.NORMAL**2))

    def ISTYPE(self, name):
        return name == 'Node'


def fixture(response, cap=100, first='Mun'):
    nd = Node()
    primary = NS(NAME='Kerbin', MU=3.5316e12, BODY=0)
    target = NS(NAME='Mun', BODY=primary)

    class LivePatch:
        @property
        def PERIAPSIS(self):
            return response(nd)

    patch = LivePatch()
    env = dict(BODY=primary, TIME=NS(SECONDS=0), TRANSFER_PE_TOL=2000, TRANSFER_PE_REFINE_DV_CAP=cap,
               LIST=lambda *xs: KList(xs), SQRT=math.sqrt, ROUND=round,
               fixture_wait=lambda _: None,
               _getTargetPatch=lambda *_: 0 if response(nd) is None else patch,
               _nodeAxisGet=lambda node, axis: getattr(node, axis),
               _nodeAxisSet=lambda node, axis, value: setattr(node, axis, value),
               _firstPatchBodyName=lambda _: first)
    for name in ('transferDepartureReady', '_refineLocalDeparturePe', '_refineLocalDepartureCandidates'):
        env[name] = lambda *args, name=name: ks.call(name, env, *args)
    return env, nd, target


def check_refinement():
    mu, radius, vinf = 6.5138398e10, 200000, 350
    rp = radius + 2200000
    b0 = math.sqrt(rp**2 + 2*mu*rp/vinf**2)
    def response(nd):
        impact = b0 + 80000*nd.RADIALOUT + 10000*nd.NORMAL
        return mu/vinf**2*(math.sqrt(1+(impact*vinf**2/mu)**2)-1)-radius
    env, nd, target = fixture(response)
    assert not ks.call('transferDepartureReady', env, nd, target, 15000)
    assert ks.call('_refineLocalDeparturePe', env, nd, target, 15000)
    assert abs(response(nd)-15000) <= 500
    assert nd.PROGRADE == 860  # Prograde alone cannot solve this encounter.
    assert math.hypot(nd.RADIALOUT, nd.NORMAL) < 100
    assert ks.call('transferDepartureReady', env, nd, target, 15000)
    print('PASS: live-patch 2200 km hyperbolic approach refined to 15 km without prograde sensitivity')

    for response, cap in ((lambda nd: 2200000, 100),
                          (lambda nd: 2200000+80000*nd.NORMAL, 1),
                          (lambda nd: 2200000 if nd.NORMAL == nd.RADIALOUT == 0 and nd.PROGRADE == 860 else None, 100)):
        env, nd, target = fixture(response, cap)
        assert not ks.call('_refineLocalDeparturePe', env, nd, target, 15000)
        assert not ks.call('transferDepartureReady', env, nd, target, 15000)
        assert math.sqrt((nd.PROGRADE-860)**2+nd.RADIALOUT**2+nd.NORMAL**2) <= cap
        assert response(nd) is not None  # Rejected probes restored.
    response = lambda nd: None if nd.NORMAL > 0 else 45000+2000*nd.NORMAL
    env, nd, target = fixture(response)
    assert ks.call('_refineLocalDeparturePe', env, nd, target, 15000)
    assert abs(response(nd)-15000) <= 500
    print('PASS: flat gradients, refinement budget, lost probes and negative-direction fallback')

    response = lambda nd: 15000+1000*((nd.PROGRADE-868)**2+4*(nd.RADIALOUT-8)**2-12)
    env, nd, target = fixture(response, cap=10)
    assert ks.call('_refineLocalDeparturePe', env, nd, target, 15000)
    assert abs(response(nd)-15000) <= 2000
    assert math.sqrt((nd.PROGRADE-860)**2+nd.RADIALOUT**2+nd.NORMAL**2) <= 10.000001
    print('PASS: correction can turn along its budget boundary without exceeding the vector-change cap')


def check_alternate_windows():
    def response(nd):
        if nd.TIME == 1000: return 1058000
        return 30000+2000*nd.NORMAL
    env, nd, target = fixture(response)
    attempts=[]
    def refine(*args):
        attempts.append((nd.TIME, nd.PROGRADE, nd.NORMAL, nd.RADIALOUT))
        return ks.call('_refineLocalDeparturePe',env,*args)
    env['_refineLocalDeparturePe']=refine
    assert ks.call('_refineLocalDepartureCandidates',env,nd,target,15000,KList((10,1000,2000,3000)),860)
    assert [attempt[0] for attempt in attempts]==[1000,2000]
    assert attempts[1]==(2000,860,0,0)
    assert abs(response(nd)-15000)<=500 and nd.TIME==2000
    # If every window fails, retain the best error rather than the last trial.
    env, nd, target = fixture(lambda nd: {1000:1058000,2000:500000,3000:700000}[nd.TIME])
    assert not ks.call('_refineLocalDepartureCandidates',env,nd,target,15000,KList((2000,3000)),860)
    assert nd.TIME==2000
    assert not ks.call('transferDepartureReady',env,nd,target,15000)
    env, nd, target = fixture(lambda _: 15000)
    assert ks.call('_refineLocalDepartureCandidates',env,nd,target,15000,KList((2000,3000)),860)
    assert nd.TIME==1000  # An already-good plan must not be replaced.
    local_plan=body(SOURCE,'_planLocalTransfer')
    assert local_plan.index('_refineLocalDepartureCandidates(')<local_plan.index('RETURN nd.')
    assert '_refineLocalDeparturePe(' not in body(SOURCE,'planTransfer')
    print('PASS: alternate window solves after flat 1058 km seed; expired/duplicate seeds skipped; best failure restored')


def check_minmus_close_pass_probe():
    mu,radius,vinf=1.7658e9,60000,100
    def periapsis(impact):
        return mu/vinf**2*(math.sqrt(1+(impact*vinf**2/mu)**2)-1)-radius
    near_r=radius+25000
    near_b=-math.sqrt(near_r**2+2*mu*near_r/vinf**2)
    # Exact conic response: the large probe crosses the B-vector minimum.
    # Its apparent derivative has the opposite sign from the local one.
    coarse=(periapsis(near_b+1e6)-periapsis(near_b))/.1
    fine=(periapsis(near_b+100)-periapsis(near_b))/.00001
    assert coarse*fine<0
    for axis in ('PROGRADE','RADIALOUT','NORMAL'):
        for pe0 in (1e6,1.338e6,2e6):
            rr=radius+pe0;b0=math.sqrt(rr**2+2*mu*rr/vinf**2)
            seed=860 if axis=='PROGRADE' else 0
            response=lambda node:periapsis(b0-6e6*(getattr(node,axis)-seed))
            env,nd,target=fixture(response);samples=[]
            original=env['_nodeAxisSet']
            def set_axis(node,key,value):
                samples.append(abs(value-getattr(node,key)));original(node,key,value)
            env['_nodeAxisSet']=set_axis
            assert ks.call('_refineLocalDeparturePe',env,nd,target,15000),(axis,pe0,response(nd))
            assert abs(response(nd)-15000)<=500
            assert any(abs(step-.01)<1e-8 for step in samples)
            assert math.sqrt((nd.PROGRADE-860)**2+nd.NORMAL**2+nd.RADIALOUT**2)<=100
            assert ks.call('transferDepartureReady',env,nd,target,15000)
    # Even a false-flat coarse probe must shrink rather than reject the
    # window: arrange equal Pe at the initial signed B and its0.1m/s probe.
    rr=radius+30000;b0=math.sqrt(rr**2+2*mu*rr/vinf**2)
    env,nd,target=fixture(lambda node:periapsis(b0-20*b0*node.NORMAL))
    assert ks.call('_refineLocalDeparturePe',env,nd,target,15000)
    assert abs(periapsis(b0-20*b0*nd.NORMAL)-15000)<=500
    print('PASS: independent Minmus hyperbola proves reversed0.1m/s slope near25km; adaptive source solves9 far-to15km encounters across all3 axes plus false-flat probe, preserving2km gate/100m/s ball and24-iteration limit')


def check_plan_gate():
    for pe, first, accepted in ((2200000, 'Mun', False), (15000, 'Mun', True),
                                (13000, 'Mun', True), (17000, 'Mun', True),
                                (17001, 'Mun', False), (-100, 'Mun', False),
                                (0, 'Mun', False), (None, 'Mun', False),
                                (15000, 'Minmus', False)):
        env, nd, target = fixture(lambda _: pe, first=first)
        assert ks.call('transferDepartureReady', env, nd, target, 15000) == accepted
        # A raw planner returning a node is not proof it is usable.
        # Exercise the actual planTransfer return gate after a failed refinement.
        env.update(CAPTURE_DIR='', CAPTURE_INC=-1, HASNODE=False,
                   _planLocalTransfer=lambda *_: nd,
                   _refineLocalDeparturePe=lambda *_: False,
                   maneuverUiArchiveLog=lambda *_: None)
        result = ks.call('planTransfer', env, target, 15000)
        assert (result is nd) == accepted
    phase = body((ks.ROOT/'lib/xfer_plan.ks').read_text(), 'phaseTransfer')
    assert phase.index('transferDepartureReady(existing') < phase.index('executeManeuver()')
    assert 'IF NOT maneuverBurnInterrupted() AND NOT maneuverDepartureFlown()' in phase
    print('PASS: bad/absent/impact/wrong-body plans rejected; valid corridor accepted; saved-node gate precedes burn')


if __name__ == '__main__':
    check_refinement()
    check_alternate_windows()
    check_minmus_close_pass_probe()
    check_plan_gate()
