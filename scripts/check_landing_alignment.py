"""Source-driven wrong-attitude ignition/staging and finite-slew regressions.

The slew model has a prescribed turn rate, flat terrain and constant mass;
it is not kOS SteeringManager, rigid-body dynamics or KSP flight validation.
"""
import math
from types import SimpleNamespace as NS

from check_landing_braking import fixture, call, Vec


def rotated(direction, angle):
    cosine, sine = math.cos(math.radians(angle)), math.sin(math.radians(angle))
    return Vec((direction[0]*cosine-direction[2]*sine, 0,
                direction[0]*sine+direction[2]*cosine))


def reported_flight(economy):
    env, ctx = fixture(horizontal=521.5, down=46, height=4415)
    ctx.update(MAX_ACC=46.06, PLAN_ACC=2.72, RESERVE_ACC=2.72,
               STATE='BRAKE_ALIGN')
    env['LANDING_ECONOMY_BRAKE'] = economy
    return env, ctx


def check_wrong_attitude():
    for economy in (0, 1):
        for error in (180, 119.2, 116.7, 45, 15.01):
            env, ctx = reported_flight(economy)
            info = call('_landingBrakeSteeringInfo', env, ctx)
            env['SHIP'].FACING.FOREVECTOR = rotated(ctx['steering'], -error)
            assert call('_landingBrakeGateInfo', env, ctx)['V_NOW']
            call('_landingBrakeAlignTick', env, ctx)
            assert ctx['STATE'] == 'BRAKE_ALIGN' and ctx['throttle'] == 0
            assert ctx['BRAKE_ALIGN_BLOCKED']
            # Live braking must also cut the previously positive command.
            ctx.update(STATE='BRAKING_BURN', throttle=1, TARGET_THROTTLE=1)
            call('_landingBrakingTick', env, ctx)
            assert ctx['throttle'] == 0
        env, ctx = reported_flight(economy)
        call('_landingBrakeSteeringInfo', env, ctx)
        env['SHIP'].FACING.FOREVECTOR = ctx['steering']
        call('_landingBrakeAlignTick', env, ctx)
        assert ctx['STATE'] == 'BRAKING_BURN'
        call('_landingBrakingTick', env, ctx)
        assert ctx['throttle'] > 0
        # The stage changes the required vector, even without attitude motion.
        ctx.update(MAX_ACC=2.76, PLAN_ACC=2.76)
        call('_landingBrakingTick', env, ctx)
        assert ctx['throttle'] == 0 and ctx['BRAKE_ALIGN_BLOCKED']
        env['SHIP'].FACING.FOREVECTOR = ctx['steering']
        call('_landingBrakingTick', env, ctx)
        assert ctx['throttle'] > 0 and not ctx['BRAKE_ALIGN_BLOCKED']
    # A near-horizontal command can be within 15 degrees while the actual
    # engine still points down. Preserve the no-engine-down invariant too.
    env, ctx = reported_flight(1)
    call('_landingBrakeSteeringInfo', env, ctx)
    env['SHIP'].FACING.FOREVECTOR = Vec((-math.cos(math.radians(1)), 0,
                                       -math.sin(math.radians(1))))
    info = call('_landingBrakeSteeringInfo', env, ctx)
    assert info['ALIGN_ERR'] < 15 and info['THROTTLE'] == 0
    print('PASS: reported 116.7/119.2-degree urgent ignition blocked in both modes; live braking and weaker-stage vector changes cut throttle; actual engine-down attitude blocked')


class LogNumber(float):
    """kOS permits number-to-string addition in its flight report."""
    def __radd__(self, other):
        return other + str(float(self)) if isinstance(other, str) else other + float(self)


def check_state_entry():
    # Exercise the actual state-entry publication as well as tick functions.
    # The common point-mass fixture stubs _landingSetState and cannot prove it.
    for error in (116.7, 0):
        env, ctx = reported_flight(1)
        call('_landingBrakeSteeringInfo', env, ctx)
        env['SHIP'].FACING.FOREVECTOR = rotated(ctx['steering'], -error)
        gate = call('_landingBrakeGateInfo', env, ctx)
        for key, value in gate.items():
            if isinstance(value, bool): gate[key] = str(value)
        saved = {}
        env.update(_landingStateLog=lambda *args: None,
                   stateSet=lambda key, value: saved.update({key: value}),
                   _landingEnsureStateTrack=lambda *args: None,
                   _landingBrakeGateInfo=lambda *args: gate,
                   landingAbortFlag=False,
                   ROUND=lambda *args: str(round(*args)),
                   STAGE=NS(NUMBER=LogNumber(2)), CONFIG=NS(IPU=LogNumber(2000)),
                   LANDING_ECONOMY_BRAKE=LogNumber(1),LANDING_STAGE_BRAKE_CREDIT=LogNumber(0))
        call('_landingSetState', env, ctx, 'BRAKING_BURN', 'fixture forced entry')
        assert (ctx['throttle'] == 0) == (error > 15)
        assert 'throttle=' in saved['last_landing_brake']
    print('PASS: actual BRAKING_BURN entry uses guarded throttle even if its caller bypasses alignment; persisted ignition includes the command')


def check_finite_slew():
    env, ctx = reported_flight(1)
    call('_landingBrakeSteeringInfo', env, ctx)
    env['SHIP'].FACING.FOREVECTOR = rotated(ctx['steering'], -119.2)
    first_burn, blocked_impulse, impulse, staged = None, 0., 0., False
    dt, turn_rate = .1, 12  # About ten seconds to turn, not instantaneous.
    for step in range(250):
        now = step*dt
        env['TIME'].SECONDS = now
        if first_burn is not None and now >= first_burn+2 and not staged:
            ctx.update(MAX_ACC=2.76, PLAN_ACC=2.76)
            staged = True
        if ctx['STATE'] == 'BRAKE_ALIGN':
            call('_landingBrakeAlignTick', env, ctx)
        else:
            call('_landingBrakingTick', env, ctx)
        # A stubbed transition publishes on the following tick, unlike the
        # separately tested real state entry. Physics follows actual facing.
        actual = env['SHIP'].FACING.FOREVECTOR
        applied = ctx['throttle']*ctx['MAX_ACC']*dt
        error = env['VANG'](actual, ctx['steering'])
        if error > 15 or actual[2] < 0: blocked_impulse += applied
        if applied > 0 and first_burn is None: first_burn = now
        impulse += applied
        thrust = actual*(ctx['throttle']*ctx['MAX_ACC'])
        velocity = Vec((ctx['H_VEL'][0], 0, ctx['V_SPEED']))
        velocity += (thrust-ctx['UP_VEC']*ctx['GRAV'])*dt
        ctx.update(H_VEL=Vec((velocity[0], 0, 0)), H_SPEED=abs(velocity[0]),
                   V_SPEED=velocity[2], DOWN_SPEED=max(0, -velocity[2]),
                   SURFACE_VEL=velocity)
        ctx['height'] += velocity[2]*dt
        current_angle = math.atan2(actual[2], actual[0])
        desired_angle = math.atan2(ctx['steering'][2], ctx['steering'][0])
        delta = (desired_angle-current_angle+math.pi) % (2*math.pi)-math.pi
        turn = max(-turn_rate*dt, min(turn_rate*dt, math.degrees(delta)))
        env['SHIP'].FACING.FOREVECTOR = rotated(actual, turn)
    assert first_burn is not None and first_burn > 8
    assert blocked_impulse == 0 and impulse > 50 and staged
    assert ctx['H_SPEED'] < 521.5 and ctx['height'] > 100
    print(f'PASS: 119.2-degree, 12 deg/s slew and 46.06->2.76 m/s2 stage change: first thrust at {first_burn:.1f}s, zero impulse outside the alignment/upward guard')


if __name__ == '__main__':
    check_wrong_attitude()
    check_state_entry()
    check_finite_slew()
