"""Reported Kolniya apsis errors and scoped precision; source fixtures, not KSP."""
import math
import re
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_codebase import ROOT, function_body
from check_minmus_kolniya import configuration
from check_shape_minimum import SOURCE, Lex, fixture


def execute(name, env):
    source = re.sub(r'PARAMETER [^.]+\.', '', function_body(SOURCE, name))
    source = source.replace('ADD nd.', 'fixture_add(nd).')
    source = source.replace('REMOVE nd.', 'fixture_remove(nd).')
    source = source.replace('REMOVE NEXTNODE.', 'fixture_remove(NEXTNODE).')
    def strip(nodes):
        return [(text, strip(yes), strip(no)) for text, yes, no in nodes
                if not text.startswith('PRINT ')]
    try:
        ks.run(strip(ks.parse(source)), env)
    except ks.Returned as result:
        return result.value


def check_shared_floor():
    env = dict(SHAPE_MIN_PE=10000, SHIP=NS(BODY=NS(ATM=NS(EXISTS=False))))
    assert execute('_peFloor', env) == 10000
    env['SHAPE_MIN_PE'] = 9000
    assert execute('_peFloor', env) == 9000
    env['SHIP'].BODY.ATM = NS(EXISTS=True, HEIGHT=70000)
    assert execute('_peFloor', env) == 80000 # Cannot weaken atmospheric clearance.
    env['SHAPE_MIN_PE'] = 90000
    assert execute('_peFloor', env) == 90000
    for name in ('planPlaneMatch', '_refinePlaneNode', '_nodeUnsafe', '_burnCostOf'):
        assert '_peFloor()' in function_body(SOURCE, name)
    env['SHIP'].BODY.ATM.EXISTS = False
    env['SHAPE_MIN_PE'] = configuration()['SHAPE_MIN_PE']
    env['_peFloor'] = lambda: execute('_peFloor', env)
    for pe, ecc, unsafe in ((8999, .7, True), (9000, .7, False), (9300, .7, False), (9300, 1, True)):
        env['nd'] = NS(ORBIT=NS(PERIAPSIS=pe, ECCENTRICITY=ecc))
        assert execute('_nodeUnsafe', env) == unsafe
    print('PASS: shared SHAPE floor retains10km default/atmosphere+10km, admits the explicit9.3km target only above9km, and rejects low/unbound candidates in all refiners')


def phase_fixture():
    env, removed, events = fixture()
    cfg = configuration()
    env.update(cfg)
    targets = Lex(AP=397272, PE=9300, INC=63.4, LAN=79.2, AOP=90)
    env.update(phaseLabel='SHAPE', prefix='SHAPE_', MAX_SHAPE_BURNS=12, MAX_RETRIES=5,
               xferSeq=[], shapeTargetsWithPrefix=lambda _: targets,
               _targetSummary=lambda _: '', _errorSummary=lambda _: '', orbitSummary=lambda: None,
               yieldToPrompt=lambda: events.append('hold'), nextPhase=lambda _: events.append('advance'))
    return env, targets, removed, events


def check_precision_scope():
    for outcome in (True, False):
        for precision, initial_abs, initial_max in ((.001, .05, .05), (.001, .0005, .0002), (-1, .05, .05)):
            env, targets, removed, events = phase_fixture()
            node = NS(DELTAV=NS(MAG=.02344), ETA=14400)
            attempts = []
            def plan(_):
                env['NEXTNODE'] = node
                env['HASNODE'] = True
                return Lex(node=node, label='set-ap')
            def burn():
                attempts.append((env['BURN_TRIM_ABS_COMPLETE_DV'], env['BURN_TRIM_COMPLETE_MAX_DV']))
                env['HASNODE'] = False
                return outcome
            env.update(SHAPE_BURN_TOLERANCE=precision, BURN_TRIM_ABS_COMPLETE_DV=initial_abs,
                       BURN_TRIM_COMPLETE_MAX_DV=initial_max, shapeNextBurn=plan,
                       shapeErrors=lambda _: Lex(AP=-770, PE=960, PLANE=.012, AOP=.045),
                       shapeConverged=lambda _: bool(attempts), executeManeuver=burn,
                       _shapeReserveBurn=lambda _: True, MAX_RETRIES=1)
            execute('_runShapePhase', env)
            expected_abs = min(initial_abs, .001) if precision > 0 else initial_abs
            expected_max = min(initial_max, expected_abs) if precision > 0 else initial_max
            assert attempts == [(expected_abs, expected_max)]
            assert env['BURN_TRIM_ABS_COMPLETE_DV'] == initial_abs
            assert env['BURN_TRIM_COMPLETE_MAX_DV'] == initial_max
            assert events.count('advance') == int(outcome)
    env, targets, removed, events = phase_fixture()
    env.update(_peFloor=lambda: 10000, shapeErrors=lambda _: Lex(PE=960))
    # A contradictory profile must hold before planning or burning.
    execute('_runShapePhase', env)
    assert events == ['hold'] and not removed
    print('PASS: SHAPE precision is active for the executor, restored on success/failure, never loosens stricter residual settings; impossible Pe target holds before planning')


def check_reported_apsis_recovery():
    env, targets, removed, events = phase_fixture()
    env.update(SQRT=math.sqrt, TIME=NS(SECONDS=0), BURN_TRIM_ABS_COMPLETE_DV=.05,
               BURN_TRIM_COMPLETE_MAX_DV=.05)
    ship = env['SHIP']
    ship.BODY = NS(MU=1.7658e9, RADIUS=60000, ATM=NS(EXISTS=False))
    ship.APOAPSIS, ship.PERIAPSIS = 397272-770, 9300+960
    ship.ORBIT.ARGUMENTOFPERIAPSIS = 90.045
    burns = []
    def errors(_):
        return Lex(AP=ship.APOAPSIS-targets['AP'], PE=ship.PERIAPSIS-targets['PE'],
                   PLANE=.012, INC=-.006, LAN=-.012, AOP=.045)
    env['shapeErrors'] = errors
    env['shapeConverged'] = lambda target: execute('shapeConverged', dict(env, targets=target))
    def radius(ta):
        env['burnRadius'] = ship.BODY.RADIUS + (ship.PERIAPSIS if ta == 0 else ship.APOAPSIS)
        return env['burnRadius']
    def speed(ta):
        rb = radius(ta)
        return math.sqrt(ship.BODY.MU*(2/rb-2/(ship.APOAPSIS+ship.PERIAPSIS+2*ship.BODY.RADIUS)))
    def orbit(rb, velocity):
        far = 2/(2/rb-velocity**2/ship.BODY.MU)-rb
        return NS(PERIAPSIS=min(rb,far)-ship.BODY.RADIUS,
                  APOAPSIS=max(rb,far)-ship.BODY.RADIUS,
                  ECCENTRICITY=abs(rb-far)/(rb+far), INCLINATION=63.4,
                  LAN=79.2, ARGUMENTOFPERIAPSIS=90.045)
    def node(ut, radial, normal, prograde):
        rb = env['burnRadius']
        vnow = speed(0 if abs(rb-ship.BODY.RADIUS-ship.PERIAPSIS)<.01 else 180)
        return NS(TIME=ut, ETA=ut, RADIALOUT=radial, NORMAL=normal, PROGRADE=prograde,
                  DELTAV=NS(MAG=abs(prograde)), ORBIT=orbit(rb, vnow+prograde), rb=rb, vnow=vnow)
    def add(nd):
        env.update(HASNODE=True, NEXTNODE=nd)
    def call(name, **params):
        local = dict(env, **params)
        result = execute(name, local)
        if '_shapeMinimumSkipped' in local:
            env['_shapeMinimumSkipped'] = local['_shapeMinimumSkipped']
        return result
    env.update(NODE=node, fixture_add=add, _radiusAtTa=radius, _speedAtTa=speed,
               maneuverUiArchiveLog=lambda _: None, _peFloor=lambda: call('_peFloor'),
               _nodeUnsafe=lambda nd: call('_nodeUnsafe', nd=nd), _nodeWrecksPlane=lambda _: False,
               _refineBurnNode=lambda *_: 0) # Exact tangent seed; no optimizer/attitude model.
    env['_planTangentBurnAt'] = lambda eta, ta, alt, label: call('_planTangentBurnAt',
        burnEta=eta, burnTa=ta, targetAlt=alt, label=label)
    env['_finishShapeNode'] = lambda nd, label, target: call('_finishShapeNode', nd=nd, label=label, targets=target)
    env['_apsisBurn'] = lambda eta, ta, alt, label, target: call('_apsisBurn',
        burnEta=eta, burnTa=ta, targetAlt=alt, label=label, targets=target)
    env['shapeNextBurn'] = lambda target: call('shapeNextBurn', targets=target)
    def burn():
        nd = env['NEXTNODE']
        tol = env['BURN_TRIM_ABS_COMPLETE_DV']
        assert nd.DELTAV.MAG > tol
        delivered = math.copysign(nd.DELTAV.MAG-tol, nd.PROGRADE)
        achieved = orbit(nd.rb, nd.vnow+delivered)
        ship.APOAPSIS, ship.PERIAPSIS = achieved.APOAPSIS, achieved.PERIAPSIS
        assert ship.PERIAPSIS >= env['_peFloor']()
        burns.append(nd.DELTAV.MAG)
        env['HASNODE'] = False
        return True
    env.update(executeManeuver=burn, _shapeReserveBurn=lambda _: True)
    execute('_runShapePhase', env)
    assert len(burns) == 2 and .02 < burns[0] < .03 and .18 < burns[1] < .20, burns
    assert abs(errors(None)['AP']) <= 100 and abs(errors(None)['PE']) <= 100, errors(None)
    assert 'hold' not in events and events.count('advance') == 1
    assert env['BURN_TRIM_ABS_COMPLETE_DV'] == env['BURN_TRIM_COMPLETE_MAX_DV'] == .05
    print(f'PASS: reported-770m Ap/+960m Pe recovers via real SHAPE/tangent source with {burns[0]:.4f}/{burns[1]:.4f}m/s trims,1mm/s residual model, both errors<100m, explicit floor intact; not native flight proof')


def check_precision_governor():
    from check_burn_watchdog import fixture as governor_fixture
    for initial in (.023442, .1909, .0021):
        env, control, node, command = governor_fixture(acc=.8, cap=initial+.05)
        env.update(BURN_TRIM_ABS_COMPLETE_DV=.001, BURN_TRIM_COMPLETE_MAX_DV=.001)
        remaining, prior = initial, 0
        for tick in range(1000):
            env['TIME'].SECONDS = tick*.02
            control['heartbeat'] = tick*.02
            env['SHIP'].THRUST = prior*.8
            node.DELTAV = ks.Vec((remaining, 0, 0))
            prior = command(1)
            remaining -= prior*.8*.02
            assert remaining >= 0
            if control['reason']:
                break
        else:
            raise AssertionError('Precision governor did not cut off')
        assert control['reason'] == 'live-node-trim'
        assert 0 <= remaining <= .001 and remaining < initial
        assert control['impulse'] < control['impulseCap']
        # It remains latched even if later telemetry grows again.
        node.DELTAV = ks.Vec((1, 0, 0))
        assert command(1) == 0
    print('PASS: real live throttle governor delivers0.0234/0.1909/0.0021m/s corrections to1mm/s residual without sign overshoot; impulse watchdog and latched cutoff remain active')


def check_precision_matches_tolerance():
    cfg = configuration()
    later = cfg['SURFACE_RETURN_ORBIT']
    for ap, pe, tol in ((cfg['SHAPE_AP'], cfg['SHAPE_PE'], cfg['SHAPE_ALT_TOL']),
                        (later['AP'], later['PE'], later['ALT_TOL'])):
        # At either apsis, a miss just OUTSIDE tolerance must still yield
        # an admissible burn, and the executor residual must be smaller.
        def speed(rb, rf):
            return math.sqrt(1.7658e9*(2/rb-2/(rb+rf)))
        for burn_radius, far_radius in ((pe+60000, ap+60000), (ap+60000, pe+60000)):
            dv = abs(speed(burn_radius, far_radius+tol)-speed(burn_radius, far_radius))
            assert cfg['SHAPE_BURN_TOLERANCE'] < cfg['SHAPE_MIN_BURN_DV'] < dv, (ap, pe, tol, dv)
    print('PASS: both contract orbit tolerance boundaries require burns above their precision minimum and residual; fine corrections cannot become unplannable just outside tolerance')


if __name__ == '__main__':
    check_shared_floor()
    check_precision_scope()
    check_reported_apsis_recovery()
    check_precision_governor()
    check_precision_matches_tolerance()
