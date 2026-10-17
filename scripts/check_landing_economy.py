"""Source-driven economy braking: vector limits and idealized point masses.

No terrain mesh, kOS scheduling, attitude dynamics or engine spool. These are
regressions and model checks, not evidence of a safe or optimal KSP landing.
"""
import math
import random

from check_landing_braking import fixture,call,simulate,Vec


def check_vector_and_flare_budget():
    rng=random.Random(92)
    env,ctx=fixture()
    for _ in range(200):
        grav=rng.uniform(.1,3)
        acc=grav*rng.uniform(1.2,20)
        hs=rng.uniform(20,600)
        down=rng.uniform(0,200)
        term=rng.uniform(0,down+grav*hs/acc)
        thrust=call('lmEconomyBrakeThrust',env,Vec((hs,0,0)),-down,-term,ctx['UP_VEC'],acc,grav)
        assert thrust.MAG<=acc+1e-9 and thrust[2]>=-1e-9
        if math.hypot(hs,down-term)>acc: assert abs(thrust.MAG-acc)<1e-8
    for _ in range(40):
        grav=rng.uniform(.2,2)
        plan=grav*rng.uniform(1.2,10)
        current=plan*rng.uniform(1,3)
        current_g=rng.uniform(.01,grav)
        hs,down,height=rng.uniform(20,600),rng.uniform(0,200),rng.uniform(500,20000)
        delay=env['LANDING_BRAKE_REACTION_TIME']
        term=-call('lmBrakeDescentTarget',env,hs,down,height,current,plan,grav,delay,current_g)
        assert 0<=term<=down+current_g*hs/current+1e-9
        if term<1e-6: continue  # An already urgent state requests full arrest.
        future=down+grav*delay
        speed=math.hypot(hs,future-term)
        cosine=(future-term)/speed
        net=min(plan,-grav*cosine+math.sqrt(plan**2-grav**2*(1-cosine**2)))
        # Independent scalar oracle for the existing conservative flare.
        flare_down=term+grav*delay
        flare_time=math.hypot(env['APPROACH_HSPEED'],flare_down)/(env['LANDING_BRAKE_ACCEL_FRACTION']*(plan-grav))*env['BURN_MARGIN']
        required=down*delay+grav*delay**2/2+(future+term)*speed/net*env['BURN_MARGIN']/2
        required+=term*delay+grav*delay**2/2+flare_down*flare_time/2+max(env['BRAKE_MARGIN'],env['LANDING_BRAKE_CLEARANCE'])
        assert required<=height+1e-7,(required,height,term)
        # The endpoint minimum bounds every effective gravity in between.
        for effective in (0,grav*.25,grav*.5,grav*.75,grav):
            exact=-effective*cosine+math.sqrt(plan**2-effective**2*(1-cosine**2))
            assert net<=exact+1e-9
    assert call('lmBrakeDescentTarget',env,400,60,5000,5,1,1.63,3,1.63)==0
    print('PASS: 200 thrust vectors bounded/no engine-down; 40 flare budgets retain delay, 80% reserve, residual lateral speed, clearance and weaker stage across gravity bounds')


def check_ballistic_gate():
    env,ctx=fixture(twr=4,horizontal=400,down=5,height=5000)
    ctx['downrange']=4000
    original=call('_landingBrakeGateInfo',env,ctx)
    assert original['H_NOW'] and not original['V_NOW']
    env['LANDING_ECONOMY_BRAKE']=1
    revised=call('_landingBrakeGateInfo',env,ctx)
    assert not revised['H_NOW'] and not revised['H_OVERSHOT']
    for key in ('V_NOW','V_GATE','V_ETA'): assert revised[key]==original[key]
    call('_landingCoastTick',env,ctx)
    assert ctx['STATE']=='COAST' and ctx['throttle']==0
    ctx['height']=revised['V_GATE']-1
    call('_landingCoastTick',env,ctx)
    assert ctx['STATE']=='BRAKE_ALIGN'
    call('_landingBrakeAlignTick',env,ctx)
    assert ctx['STATE']=='BRAKING_BURN'
    print('PASS: economy geographic target cannot force an early burn; unchanged full velocity/terrain gate still starts urgent braking')


def check_descent_efficiency():
    # Deliberately expose the old premature horizontal gate: 4000 m range
    # while still 5000 m high and descending only 5 m/s.
    old=simulate(1.63,4,400,5,start_height=5000,downrange=4000,dt=.2)
    new=simulate(1.63,4,400,5,economy=True,start_height=5000,downrange=4000,dt=.2)
    assert old['hover']>30 and new['hover']<1,(old,new)
    assert new['spent']<old['spent']*.9 and new['elapsed']<old['elapsed'],(old,new)
    print(f'PASS: paired model hover {old["hover"]:.1f}->{new["hover"]:.1f} s; brake-to-approach impulse {old["spent"]:.1f}->{new["spent"]:.1f} m/s (not whole-flight savings)')
    for args in ((.491,7.45,120,60),(1.63,12,400,60,3)):
        result=simulate(*args,economy=True,dt=.2)
        assert result['hover']<1 and result['minimum']>100
    result=simulate(1.63,4,400,5,economy=True,start_height=5000,downrange=4000,dt=.2,curvature_radius=200000)
    assert result['hover']<1 and result['minimum']>100
    print('PASS: Mun/Minmus delayed ignition, weak next-stage interruption and changing centrifugal support retain positive clearance without high hover')


if __name__=='__main__':
    check_vector_and_flare_budget()
    check_ballistic_gate()
    check_descent_efficiency()
