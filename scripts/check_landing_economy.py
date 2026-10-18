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
    assert ctx['STATE']=='BRAKE_ALIGN' and ctx['throttle']==0
    env['SHIP'].FACING.FOREVECTOR = ctx['steering']
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


def check_staged_and_curved_descent():
    for args in ((.491,7.45,120,60),(1.63,12,400,60,3)):
        result=simulate(*args,economy=True,dt=.2)
        assert result['hover']<1 and result['minimum']>100
    result=simulate(1.63,4,400,5,economy=True,start_height=5000,downrange=4000,dt=.2,curvature_radius=200000)
    assert result['hover']<1 and result['minimum']>100
    print('PASS: Mun/Minmus delayed ignition, weak next-stage interruption and changing centrifugal support retain positive clearance without high hover')


def check_reported_weak_lander():
    # Operator entry after the alignment fix: 7.3 km, hs=355.72, vs=-30.11.
    # Conservatively give the whole modeled burn to the previously measured
    # 2.76 m/s2 lander, without credit for transfer fuel or rising TWR.
    # Keep the existing three-second delayed ignition and changing gravity.
    result=simulate(1.63,2.76/1.63,355.72,30.11,economy=True,
                    start_height=7300,dt=.5,curvature_radius=210000)
    assert result['hover']<1 and result['minimum']>100
    print('PASS: reported 7.3 km/356 m/s entry with TWR below 1.7 reaches modeled terminal capture without high hover; not a complete landing or a fuel-budget proof')


def check_terminal_stopping_profile():
    rng=random.Random(118)
    env,_=fixture()
    extended=0
    for _ in range(300):
        grav=rng.uniform(.1,3)
        acc=grav*rng.uniform(1.1,20)
        height=rng.uniform(0,2000)
        horizontal=rng.uniform(0,1)
        scheduled=call('lmDescentSpeed',env,height,2,3,30)
        down=call('lmEconomyDescentSpeed',env,scheduled,height,horizontal,acc,grav)
        assert math.isfinite(down) and down>=scheduled
        if down>scheduled+1e-9:
            # Independent exact coupled envelope, not the quadratic bound.
            delay=env['LANDING_BRAKE_REACTION_TIME']
            future=down+grav*delay
            net=(acc-grav)*env['LANDING_BRAKE_ACCEL_FRACTION']
            required=down*delay+grav*delay**2/2
            required+=future*math.hypot(horizontal,future)/net*env['BURN_MARGIN']/2
            required+=max(env['BRAKE_MARGIN'],env['LANDING_BRAKE_CLEARANCE'])
            assert required<=height+1e-7,(required,height,down)
            extended+=1
    assert extended>100
    for height in (0,.2,3,15,50,100):
        scheduled=call('lmDescentSpeed',env,height,2,3,30)
        assert call('lmEconomyDescentSpeed',env,scheduled,height,.6,3.27,1.63)==scheduled
    assert call('lmEconomyDescentSpeed',env,10,1000,0,1,1.63)==10
    print('PASS: 300 terminal speed inversions stay inside the independent coupled stopping reserve whenever faster than the old schedule; 80% thrust, full gravity, delay, clearance and gentle touchdown remain')


def check_terminal_delay_models():
    from collections import deque
    env,_=fixture()
    modeled=0
    for grav in (.491,1.63):
        for ratio in (1.4,2.2,4,8):
            acc=grav*ratio
            if .8*(acc-grav)<2*8*6/97:
                for height,scheduled in ((100,8),(1000,20),(2000,30)):
                    assert call('lmEconomyDescentSpeed',env,scheduled,height,0,acc,grav)==scheduled
                continue
            modeled+=1
            dt=.05
            queue=deque([0.]*4) # 0.2s physical actuation delay.
            height=1000.
            initial=call('lmEconomyDescentSpeed',env,20,height,0,acc,grav)
            speed=-min(20,initial*.8)
            for step in range(20000):
                scheduled=call('lmDescentSpeed',env,height,2,3,30)
                planned=call('lmEconomyDescentSpeed',env,scheduled,height,0,acc,grav)
                throttle=call('lmVerticalThrottle',env,-planned,acc,grav,speed)
                queue.append(throttle)
                speed+=(queue.popleft()*acc-grav)*dt
                height+=speed*dt
                assert speed<1,'no climb/hover arc in the nominal vertical model'
                if height<=.2:break
            else:raise AssertionError('terminal descent did not reach contact')
            assert speed>=-2.5,(grav,ratio,height,speed)
    assert modeled==5
    print('PASS: five eligible airless terminal point masses reach gentle modeled contact with 0.2s actuation lag and no hover; three low-authority cases keep the original schedule; not kOS/attitude/terrain proof')


if __name__=='__main__':
    check_terminal_stopping_profile()
    check_terminal_delay_models()
    check_vector_and_flare_budget()
    check_ballistic_gate()
    check_descent_efficiency()
    check_staged_and_curved_descent()
    check_reported_weak_lander()
