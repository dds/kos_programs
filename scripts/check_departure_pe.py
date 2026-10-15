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
    env = dict(BODY=primary, TRANSFER_PE_TOL=2000, TRANSFER_PE_REFINE_DV_CAP=cap,
               LIST=lambda *xs: KList(xs), SQRT=math.sqrt, ROUND=round,
               fixture_wait=lambda _: None,
               _getTargetPatch=lambda *_: 0 if response(nd) is None else patch,
               _nodeAxisGet=lambda node, axis: getattr(node, axis),
               _nodeAxisSet=lambda node, axis, value: setattr(node, axis, value),
               _firstPatchBodyName=lambda _: first)
    for name in ('transferDepartureReady', '_refineLocalDeparturePe'):
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


def check_plan_gate():
    for pe, first, accepted in ((2200000, 'Mun', False), (15000, 'Mun', True),
                                (13000, 'Mun', True), (17000, 'Mun', True),
                                (17001, 'Mun', False), (-100, 'Mun', False),
                                (0, 'Mun', False), (None, 'Mun', False),
                                (15000, 'Minmus', False)):
        env, nd, target = fixture(lambda _: pe, first=first)
        assert ks.call('transferDepartureReady', env, nd, target, 15000) == accepted
        # A raw planner/refiner returning a node is not proof it is usable.
        # Exercise the actual planTransfer return gate, including failed refinement.
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
    check_plan_gate()
