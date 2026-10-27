"""Source-driven finite-burn, entry-time and cutoff fixtures; not the kOS VM."""
import math
import re
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_codebase import ROOT, function_body, mask, closure, dependency_tables
from check_deorbit_geometry import Vec as BaseVec
from check_surface_return import defaults, read_settings, emit_profile, expression

SOURCE=(ROOT/'lib/aerobrake_assist.ks').read_text()
MATH=(ROOT/'lib/aerobrake_ap_math.ks').read_text()
CONFIG=(ROOT/'lib/aerobrake_config.ks').read_text()
AERO=(ROOT/'lib/aerobrake.ks').read_text()
ks.SOURCES+='\n'+CONFIG+'\n'+SOURCE+'\n'+MATH+'\n'+AERO


class Vec(BaseVec):
    # These fixtures always use three components. Avoid NumPy's general
    # dot dispatch on every suffix read; keep the same vectors and steps.
    @property
    def MAG(self):return math.hypot(self[0],self[1],self[2])


def slew(current,desired,maximum_degrees):
    error=math.atan2(desired[1],desired[0])-math.atan2(current[1],current[0])
    error=(error+math.pi)%(2*math.pi)-math.pi
    angle=math.atan2(current[1],current[0])+max(-math.radians(maximum_degrees),min(math.radians(maximum_degrees),error))
    return Vec((math.cos(angle),math.sin(angle),0))


def fixture(available=869, before_entry=None, saved=None, thrust=2.74):
    env=ks.environment()
    mu,radius,pe,ap=3.5316e12,600000.,653000.,47600000.
    semi=(pe+ap)/2;ecc=(ap-pe)/(ap+pe);motion=math.sqrt(mu/semi**3)
    anomaly=0.
    if before_entry is not None:
        interface_e=math.acos((1-670000/semi)/ecc)
        time_to_pe=(interface_e-ecc*math.sin(interface_e))/motion+before_entry
        mean=-motion*time_to_pe
        anomaly=-.5
        for _ in range(30):anomaly-=(anomaly-ecc*math.sin(anomaly)-mean)/(1-ecc*math.cos(anomaly))
    rr=semi*(1-ecc*math.cos(anomaly))
    state=dict(pos=[semi*(math.cos(anomaly)-ecc),semi*math.sqrt(1-ecc**2)*math.sin(anomaly)],
               vel=[-semi*motion*math.sin(anomaly)/(1-ecc*math.cos(anomaly)),
                    semi*motion*math.sqrt(1-ecc**2)*math.cos(anomaly)/(1-ecc*math.cos(anomaly))],
               mass=1.,actual_dv=0.,throttle='0',steering='',min_pe=53000.,max_pe=53000.,
               thrust_history=[],state_history=[],drag=0.,turn_rate=math.inf)
    dry=math.exp(-available/(315*9.80665))
    data={} if saved is None else dict(saved)
    ship=NS(BODY=NS(NAME='Kerbin',RADIUS=radius,MU=mu,POSITION=Vec((0,0,0)),ROTATIONPERIOD=21600),
            STATUS='ORBITING',MASS=1.,THRUST=0.,AVAILABLETHRUST=thrust,Q=.02,
            ALTITUDE=rr-radius,PERIAPSIS=53000,APOAPSIS=47e6,
            ORBIT=NS(ECCENTRICITY=ecc),DELTAV=NS(VACUUM=available),
            CONTROL=NS(MAINTHROTTLE=0.,PILOTMAINTHROTTLE=0.),
            VELOCITY=NS(),FACING=NS(FOREVECTOR=Vec((0,-1,0))),
            ENGINES=[NS(IGNITION=True,FLAMEOUT=False,AVAILABLETHRUST=thrust,THROTTLELOCK=False,VISP=315)])
    stage=NS(NUMBER=1,DELTAV=NS(VACUUM=available))
    def refresh():
        x,y=state['pos'];vx,vy=state['vel'];rr=math.hypot(x,y)
        h=x*vy-y*vx;energy=(vx*vx+vy*vy)/2-mu/rr
        ecc=math.sqrt(max(0,1+2*energy*h*h/(mu*mu)))
        ship.PERIAPSIS=h*h/(mu*(1+ecc))-radius
        ship.APOAPSIS=-mu/energy-(ship.PERIAPSIS+radius)-radius if energy<0 else 1e30
        ship.ORBIT.ECCENTRICITY=ecc;ship.ALTITUDE=rr-radius;ship.MASS=state['mass']
        ship.POSITION=Vec((x,y,0));ship.VELOCITY.ORBIT=Vec((vx,vy,0))
        spin=2*math.pi/21600
        ship.VELOCITY.SURFACE=Vec((vx+spin*y,vy-spin*x,0))
        ship.DELTAV.VACUUM=stage.DELTAV.VACUUM=max(0,315*9.80665*math.log(state['mass']/dry))
        state['min_pe']=min(state['min_pe'],ship.PERIAPSIS);state['max_pe']=max(state['max_pe'],ship.PERIAPSIS)
        if energy<0 and ecc>1e-8:
            semi=-mu/(2*energy)
            ea=math.atan2((x*vx+y*vy)/math.sqrt(mu*semi),(1-rr/semi))
            mean=ea-ecc*math.sin(ea)
            env['ETA'].PERIAPSIS=(-mean)%(2*math.pi)/math.sqrt(mu/semi**3)
        else:env['ETA'].PERIAPSIS=0
    def facing(dt):
        if state['steering']:
            direction=(-ship.VELOCITY.SURFACE if 'SRFRETROGRADE' in state['steering']
                       else ks.evaluate(state['steering'],env))
            if direction.MAG>0:
                # Preserve the full vector in the ideal-attitude cases and
                # avoid trigonometry there. Finite-slew checks still rotate.
                if math.isinf(state['turn_rate']):ship.FACING.FOREVECTOR=direction.NORMALIZED
                else:ship.FACING.FOREVECTOR=slew(ship.FACING.FOREVECTOR,direction,state['turn_rate']*dt)
    def persist(key,value):
        assert ship.THRUST<=.001,'no persistent state I/O during thrust'
        state['state_history'].append((key,value));data[key]=value
    def lock(statement):
        if statement.startswith('LOCK THROTTLE TO '):state['throttle']=statement[17:]
        elif statement.startswith('LOCK STEERING TO '):state['steering']=statement[17:]
    def physics(dt):
        if dt<=0:return
        facing(dt)
        throttle=ks.evaluate(state['throttle'],env)
        assert 0<=throttle<=1
        ship.CONTROL.MAINTHROTTLE=throttle;ship.THRUST=throttle*ship.AVAILABLETHRUST
        state['thrust_history'].append((env['TIME'].SECONDS,ship.THRUST))
        x,y=state['pos'];vx,vy=state['vel'];rr=math.hypot(x,y);vv=math.hypot(vx,vy)
        mass_before=state['mass'];flow=ship.THRUST/(315*9.80665)
        accel=ship.THRUST/(mass_before-flow*dt/2);direction=ship.FACING.FOREVECTOR
        # Independent small-step point mass; midpoint gravity/mass and exact
        # propellant accounting avoid a first-order impulse bias at high TWR.
        drag=state['drag'] if ship.ALTITUDE<70000 else 0
        mx,my=x+vx*dt/2,y+vy*dt/2;mr=math.hypot(mx,my)
        ax=-mu*mx/mr**3+accel*direction[0]-drag*vx/vv
        ay=-mu*my/mr**3+accel*direction[1]-drag*vy/vv
        state['pos']=[x+vx*dt+ax*dt*dt/2,y+vy*dt+ay*dt*dt/2]
        state['vel']=[vx+ax*dt,vy+ay*dt]
        state['mass']-=flow*dt
        state['actual_dv']+=315*9.80665*math.log(mass_before/state['mass']);env['TIME'].SECONDS+=dt
        refresh()
    def cutoff():
        owner=env.get('control')
        if owner is not None:
            assert owner['REASON']
            assert ks.call('_aeroApSafeThrottle',env,1,owner)==0
        state['throttle']='0';ship.THRUST=ship.CONTROL.MAINTHROTTLE=ship.CONTROL.PILOTMAINTHROTTLE=0
        return True
    env.update(SHIP=ship,STAGE=stage,HASNODE=False,ABORT=False,SAS=False,CONFIG=NS(IPU=150),ETA=NS(PERIAPSIS=0),
               AEROBRAKE_AP_BURN=1,AEROBRAKE_REENTRY_DIR='RETROGRADE',LOG_ARCHIVE_DEFERRED=0,
               V=lambda a,b,c:Vec((a,b,c)),LN=math.log,CONSTANT=NS(PI=math.pi,E=math.e,G0=9.80665),
               VANG=lambda a,b:math.degrees(math.acos(max(-1,min(1,float(a@b)/a.MAG/b.MAG)))),
               stateGet=lambda key,default=None:data.get(key,default),
               stateGetNum=lambda key,default=0:data.get(key,default),stateSet=persist,
               stateRemove=lambda key:data.pop(key,None),fixture_lock=lock,fixture_wait=physics,
               thrustCutoffOk=cutoff,phaseShouldYield=False)
    for name in re.findall(r'(?:GLOBAL|LOCAL) FUNCTION (\w+)',SOURCE+'\n'+MATH):
        env[name]=lambda *args,name=name:ks.call(name,env,*args)
    refresh();ship.FACING.FOREVECTOR=-ship.VELOCITY.ORBIT.NORMALIZED
    return env,state,data,refresh


def run_assist(env):
    source=function_body(SOURCE,'aerobrakeApAssist').replace('SAS OFF.','SET SAS TO FALSE.')
    env.update(atmHeight=70000,peLow=52000,peHigh=54000,targetPe=53000)
    try:ks.run(ks.parse(source),env)
    except ks.Returned as result:return result.value


def control(env):
    return dict(REASON='',DEADLINE=1000,UPDATED=0,ATMO=70000,LOW=52000,HIGH=54000,
                BODY='Kerbin',STAGE=1,DV=869,APPLIED=0,TARGET_AP=71000,PEAK_FACING_ERR=0,
                DIR=-env['SHIP'].VELOCITY.ORBIT.NORMALIZED)


def check_live_cutoffs():
    for case in ('ok','off','abort','deadline','stale','landed','body','stage','node',
                 'pe-low','pe-high','q','fuel','dv','ap','thrust','angle','wind','nan-command'):
        env,sim,data,refresh=fixture();owner=control(env);ship=env['SHIP'];command=.7
        if case=='off':env['AEROBRAKE_AP_BURN']=0
        if case=='abort':env['ABORT']=True
        if case=='deadline':env['TIME'].SECONDS=1000
        if case=='stale':env['TIME'].SECONDS=1
        if case=='landed':ship.STATUS='LANDED'
        if case=='body':ship.BODY.NAME='Mun'
        if case=='stage':env['STAGE'].NUMBER=0
        if case=='node':env['HASNODE']=True
        if case=='pe-low':ship.PERIAPSIS=52099
        if case=='pe-high':ship.PERIAPSIS=53901
        if case=='q':ship.Q=.11
        if case=='fuel':env['STAGE'].DELTAV.VACUUM=0
        if case=='dv':owner['APPLIED']=869
        if case=='ap':ship.APOAPSIS=70999
        if case=='thrust':ship.AVAILABLETHRUST=0
        if case=='angle':ship.FACING.FOREVECTOR=Vec((1,0,0))
        if case=='wind':ship.VELOCITY.SURFACE=Vec((3000,0,0))
        if case=='nan-command':command=float('nan')
        actual=env['_aeroApSafeThrottle'](command,owner)
        assert actual==(.7 if case=='ok' else 0),(case,actual,owner)
        if case!='ok':
            assert owner['REASON'];owner.update(UPDATED=env['TIME'].SECONDS,DEADLINE=env['TIME'].SECONDS+60)
            assert env['_aeroApSafeThrottle'](1,owner)==0
    print('PASS: live abort/disable/deadline/freshness/body/stage/node/upper+lower Pe/pressure/reserve/forecast/Ap/thrust/alignment guards latch zero')


def check_entry_and_direction():
    for lead in (0,180,900):
        env,sim,data,refresh=fixture(before_entry=lead)
        assert abs(env['aerobrakeApEntryEta'](70000)-lead)<1e-5
        pos,vel=env['SHIP'].POSITION,env['SHIP'].VELOCITY.ORBIT
        direction=env['aeroApDirection'](pos,vel,3.5316e12,653000,2.74)
        plus=env['aeroApOrbit'](pos,vel+.001*direction,3.5316e12)
        minus=env['aeroApOrbit'](pos,vel-.001*direction,3.5316e12)
        assert abs((plus['PE']-minus['PE'])/.002)<.01
        assert float(direction@vel)<0
    env,sim,data,refresh=fixture();env['SHIP'].ALTITUDE=69000
    assert env['aerobrakeApEntryEta'](70000)==0
    # Hyperbolic/parabolic timing has an independent numerical quadrature check.
    for ecc in (1,1.2,.9):
        p=653000*(1+ecc);angle=.3;count=1000;step=angle/count
        integral=sum((p/(1+ecc*math.cos((i+.5)*step)))**2/math.sqrt(3.5316e12*p)*step for i in range(count))
        actual=env['_aeroApConicTime'](ecc,p,3.5316e12,math.cos(angle),math.sin(angle))
        assert abs(actual-integral)<1e-5,(ecc,actual,integral)
    print('PASS: true atmospheric-interface ETA and constant-Pe energy descent agree with independent conic/time/finite-difference calculations')


def check_live_entry_orientation(mode):
    # Each direction suffix is a SNAPSHOT. Only reading it again observes
    # the rotating velocity vector; a stored Direction stays unchanged.
    env=ks.environment();env.update(AEROBRAKE_REENTRY_DIR=mode,SAS=False)
    class MovingShip:
        FACING=NS(FOREVECTOR=Vec((0,1,0)))
        @property
        def SRFPROGRADE(self):
            angle=math.radians(6*env['TIME'].SECONDS)
            return NS(FOREVECTOR=Vec((math.cos(angle),math.sin(angle),0)))
        @property
        def SRFRETROGRADE(self):return NS(FOREVECTOR=-self.SRFPROGRADE.FOREVECTOR)
    env['SHIP']=MovingShip();steering=''
    def lock(statement):
        nonlocal steering
        assert statement.startswith('LOCK STEERING TO ')
        steering=statement[17:]
    def tick(dt):
        env['TIME'].SECONDS+=dt
        desired=ks.evaluate(steering,env).FOREVECTOR
        current=env['SHIP'].FACING.FOREVECTOR
        env['SHIP'].FACING.FOREVECTOR=slew(current,desired,30*dt)
    env.update(fixture_lock=lock,fixture_wait=tick,
               _aerobrakeEntryDirection=lambda:ks.call('_aerobrakeEntryDirection',env),
               VANG=lambda a,b:math.degrees(math.acos(max(-1,min(1,float(a@b)/a.MAG/b.MAG)))))
    logs=[];env['fixture_log']=logs.append
    source=function_body(AERO,'_aerobrakeOrient').replace('SAS OFF.','SET SAS TO FALSE.').replace('mLog(','fixture_log(')
    source=re.sub(r'WAIT UNTIL (.*?)\.',r'UNTIL \1 { WAIT 0.05. }',source,flags=re.S)
    try:ks.run(ks.parse(source),env)
    except ks.Returned:pass
    assert env['TIME'].SECONDS<60
    # The same installed steering lock must keep tracking AFTER the helper
    # returns, through a coast in which the heading changes substantially.
    for _ in range(80):tick(.05)
    desired=getattr(env['SHIP'],'SRFPROGRADE' if mode=='PROGRADE' else 'SRFRETROGRADE').FOREVECTOR
    error=env['VANG'](env['SHIP'].FACING.FOREVECTOR,desired)
    assert error<2,(mode,error,steering)
    before=len(logs)
    try:ks.run(ks.parse(source),env)
    except ks.Returned:pass
    assert len(logs)==before,'aligned hold must not repeat the orienting/oriented log pair'
    print(f'PASS: {mode} entry lock and alignment test track moving velocity with finite slew, including after orientation returns')


def check_finite_plan():
    env,sim,data,refresh=fixture(before_entry=180)
    plan=env['_aeroApPlan'](70000,52000,54000,53000)
    assert plan['OK'],plan
    assert 0<plan['DV']<=869 and 652100<=plan['PE']<=653900
    assert plan['AP']<47600000 and plan['IGNITE']>5
    assert env['CONFIG'].IPU==150 and 'aerobrake_prior_ipu' not in data
    print('PASS: finite variable-mass three-minute plan selects useful energy reduction within both Pe bounds using actual fuel')


def check_powered_alignment(turn_rate):
    env,sim,data,refresh=fixture(before_entry=180,thrust=55)
    sim['turn_rate']=turn_rate
    assert run_assist(env)['OK']
    if turn_rate==0:
        assert sim['actual_dv']==0 and env['control']['REASON']=='alignment-timeout'
    else:
        assert sim['actual_dv']>300
        assert env['control']['PEAK_FACING_ERR']<=5
    assert env['SHIP'].THRUST==0 and not data['aerobrake_ap_active']
    print(f'PASS: {turn_rate}deg/s attitude fixture: powered ignition requires actual alignment and stalled steering spends no fuel')


def check_source_execution():
    env,sim,data,refresh=fixture(before_entry=180)
    before=env['SHIP'].APOAPSIS
    result=run_assist(env)
    assert result['OK'],result
    assert env['SHIP'].APOAPSIS<before*.9 and sim['actual_dv']>0
    assert 52000<=sim['min_pe']<=sim['max_pe']<=54000
    assert not data['aerobrake_ap_active'] and data['aerobrake_ap_pass_used']
    assert env['SHIP'].THRUST==env['SHIP'].CONTROL.MAINTHROTTLE==env['SHIP'].CONTROL.PILOTMAINTHROTTLE==0
    assert env['CONFIG'].IPU==150 and env['LOG_ARCHIVE_DEFERRED']==0
    print('PASS: source owner executes its calculated ignition/guidance, reduces apoapsis, preserves Pe, restores IPU and verifies physical cutoff in idealized planar flight')


def check_uncapped_fuel(available,reserve):
    env,sim,data,refresh=fixture(before_entry=180,thrust=55,available=available)
    env['AEROBRAKE_AP_RESERVE_DV']=reserve
    retained=max(10,reserve)
    result=run_assist(env)
    assert result['OK'],result
    assert sim['actual_dv']>300 and sim['actual_dv']<=available-retained+.2
    assert 52000<=sim['min_pe']<=sim['max_pe']<=54000
    assert env['SHIP'].DELTAV.VACUUM>=retained-.2
    if available==869:
        assert abs(result['DV']-(available-retained))<1e-6
        # Independent 50 ms impulse sampling can differ from the owner's
        # trapezoidal feedback; exact propellant accounting stays within 1 m/s.
        assert abs(sim['actual_dv']-(available-retained))<1
    else:
        assert result['REASON']=='apoapsis-target'
        assert env['SHIP'].DELTAV.VACUUM>1000
        assert abs(env['SHIP'].APOAPSIS-71000)<500
    print(f'PASS: {available}m/s fuel, {reserve}m/s configured reserve retains at least {retained}m/s: no preset 150/300 cap; stop at available budget or useful apoapsis target')


def check_repair_reserve():
    settings=read_settings(CONFIG,{},'GLOBAL')
    assert settings['AEROBRAKE_AP_RESERVE_DV']==10
    for configured in (0,10,100):
        retained=max(10,configured)
        for limited in ('ship','stage'):
            for delta in (-.1,0,.1):
                env,_,_,_=fixture()
                env['AEROBRAKE_AP_RESERVE_DV']=configured
                assert env['aerobrakeApReserveDv']()==retained
                if limited=='ship':env['SHIP'].DELTAV.VACUUM=retained+delta
                else:env['STAGE'].DELTAV.VACUUM=retained+delta
                owner=control(env)
                actual=env['_aeroApSafeThrottle'](.7,owner)
                assert actual==(.7 if delta>0 else 0),(configured,limited,delta,owner)
                if delta<=0:
                    assert owner['REASON']=='fuel-reserve'
                    env['SHIP'].DELTAV.VACUUM=env['STAGE'].DELTAV.VACUUM=869
                    assert env['_aeroApSafeThrottle'](1,owner)==0 # Latched cutoff.
    for available in (0,9.9,10,10.1):
        env,sim,_,_=fixture(available=available,before_entry=180)
        env['AEROBRAKE_AP_RESERVE_DV']=0 # Legacy generated profile.
        assert not run_assist(env)['OK'] and sim['actual_dv']==0
    print('PASS: 10m/s default/minimum applies to old zero-reserve profiles; larger reserves win, ship/stage fuel bounds latch cutoff and a craft with only the repair allowance cannot start assistance')


def check_disturbance_and_stale_control(drag):
    env,sim,data,refresh=fixture(before_entry=180,thrust=55)
    sim['drag']=drag
    physics=env['fixture_wait'];fired=False
    def pause(dt):
        nonlocal fired
        physics(dt)
        if env['SHIP'].THRUST>.001 and not fired and drag==0:
            fired=True
            env['TIME'].SECONDS+=1
            assert env['_aeroApSafeThrottle'](1,env['control'])==0
    env['fixture_wait']=pause
    assert run_assist(env)['OK']
    assert env['SHIP'].THRUST==0 and not data['aerobrake_ap_active']
    if drag==0:assert fired and env['control']['REASON']=='stale-control'
    elif drag>=10:
        # Drag during the pre-ignition coast can invalidate the forecast.
        # Once Pe is outside the corridor the burn must never start.
        assert sim['actual_dv']==0 and env['control']['REASON']=='periapsis-corridor'
    else:
        assert env['control']['REASON'] in ('periapsis-corridor','entry-attitude','forecast-or-energy-target','apoapsis-target')
        assert sim['actual_dv']<869 and sim['min_pe']>52000
    print(f'PASS: disturbance={drag} is stopped by live orbit/attitude/freshness feedback and verified cutoff, independent of the vacuum forecast')


def check_interrupted_owner():
    env,sim,data,refresh=fixture(before_entry=180,thrust=55)
    lock=env['fixture_lock']
    def interrupt(statement):
        if statement.startswith('LOCK THROTTLE TO _aeroApSafeThrottle'):
            raise RuntimeError('simulated reboot')
        lock(statement)
    env['fixture_lock']=interrupt
    try:run_assist(env)
    except RuntimeError as error:assert str(error)=='simulated reboot'
    else:raise AssertionError('interruption not reached')
    assert data['aerobrake_ap_active'] and data['aerobrake_ap_pass_used']
    assert data['aerobrake_prior_ipu']==150
    env.pop('control') # RAM scope lost at reboot; physical cutoff still required.
    assert env['aerobrakeApRecover']() and not data['aerobrake_ap_active']
    assert data['aerobrake_ap_pass_used']
    env,sim,data,refresh=fixture(before_entry=180,thrust=55)
    cutoff=env['thrustCutoffOk']
    def forced_shutdown():
        cutoff();env['phaseShouldYield']=True
        return False
    env['thrustCutoffOk']=forced_shutdown
    assert run_assist(env)['OK']
    assert data['aerobrake_ap_active'] and env['phaseShouldYield']
    assert data['aerobrake_prior_ipu']==150 and env['LOG_ARCHIVE_DEFERRED']==1
    print('PASS: interrupted ownership retains pass/IPU recovery markers; failed cutoff cannot clear active state or resume archive I/O')


def check_interruption_and_opt_in():
    for case in ('off','used','reserve','node','solid','prograde','late'):
        env,sim,data,refresh=fixture(before_entry=180)
        if case=='off':env['AEROBRAKE_AP_BURN']=0
        if case=='used':data['aerobrake_ap_pass_used']=True
        if case=='reserve':env['AEROBRAKE_AP_RESERVE_DV']=869
        if case=='node':env['HASNODE']=True
        if case=='solid':env['SHIP'].ENGINES[0].THROTTLELOCK=True
        if case=='prograde':env['AEROBRAKE_REENTRY_DIR']='PROGRADE'
        if case=='late':env['SHIP'].ALTITUDE=69000
        assert not run_assist(env)['OK'] and sim['actual_dv']==0 and not sim['thrust_history']
    env,sim,data,refresh=fixture(before_entry=180,saved=dict(aerobrake_ap_pass_used=True,aerobrake_ap_active=True))
    assert env['aerobrakeApRecover']() and not data['aerobrake_ap_active']
    env['aerobrakeApObserve'](70000);assert data['aerobrake_ap_pass_used']
    env['SHIP'].ALTITUDE=69000;env['aerobrakeApObserve'](70000)
    assert data['aerobrake_ap_entered'] and data['aerobrake_ap_pass_used']
    env['SHIP'].ALTITUDE=71000;env['aerobrakeApObserve'](70000)
    assert not data['aerobrake_ap_pass_used'] and not data['aerobrake_ap_entered']
    print('PASS: opt-out/unavailable fuel/hardware/node/late entry never burn; interrupted pre-entry attempts re-arm only after measured entry and exit')


def check_profile_command_and_entry_alignment():
    settings=read_settings(CONFIG,{},'GLOBAL');assert settings['AEROBRAKE_AP_BURN']==0
    setup=(ROOT/'lib/return_setup.ks').read_text();writer=function_body(setup,'_writeCoastAutomation')
    rows=re.findall(r'LOG ("SET AEROBRAKE_AP_.*?) TO profilePath\.',writer);assert len(rows)==5
    def serialize(env):return '\n'.join(expression(row,env) for row in rows)
    initial=defaults()|settings
    initial.update(AEROBRAKE_AP_BURN=1,AEROBRAKE_AP_RESERVE_DV=0,BODY_NAME='MINMUS')
    initial.update(PARKING_ALT=initial['SURFACE_RETURN_PARKING_ALT'],
                   LAUNCH_INCLINATION=initial['SURFACE_RETURN_INCLINATION'],LAUNCH_AZIMUTH=90)
    surface=read_settings(emit_profile('phaseSurfaceReturnSetup',initial)+'\n'+serialize(initial),defaults()|settings)
    surface['targetPe']=53000
    home=read_settings(emit_profile('phaseReturnSetup',surface)+'\n'+serialize(surface),defaults()|settings)
    for key in settings:assert home[key]==surface[key]==initial[key],key
    # Legacy serialized zero remains compatible without erasing unrelated
    # policy; the effective reserve still protects ten at execution time.
    env,_,_,_=fixture();env.update(home)
    assert env['aerobrakeApReserveDv']()==10
    deps,phases,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    assert 'aerobrake_assist' in closure(['aerobrake'],deps)
    assert 'aerobrake_assist' not in closure(['return_setup'],deps)
    command=(ROOT/'cmd/aeroassist.ks').read_text()
    assert len(re.findall(r'\bPARAMETER ',command))==2
    assert 'missionOverrideUpdate(' in command and not re.search(r'\b(?:stateSet|stateRemove|missionOverrideClear|nextPhase)\(',command)
    assert not re.search(r'(?<!:)\b(?:REBOOT|STAGE|LOCK|UNLOCK|REMOVE)\b',mask(command))
    phase=function_body(AERO,'phaseAerobrake')
    assert phase.index('aerobrakeApRecover()')<phase.index('mLogPhase(')
    assert 'approachEta-AEROBRAKE_AP_PLAN_LEAD' in phase and 'OR inPass' in phase
    owner=function_body(SOURCE,'aerobrakeApAssist')
    assert owner.index('stateSet("aerobrake_ap_active",TRUE)')<owner.index('LOCK THROTTLE TO _aeroApSafeThrottle')
    assert owner.index('thrustCutoffOk()')<owner.index('stateSet("aerobrake_ap_active",FALSE)')<owner.index('result reason=')
    assert not re.search(r'\b(?:STAGE|ADD|REMOVE|REBOOT|ACTIVATE|COPYPATH|OPEN|LOG)\b(?!:)',mask(SOURCE))
    assert 'aerobrake_prior_ipu' in function_body((ROOT/'lib/boot_lib.ks').read_text(),'bootPreamble')
    assert 'SET AEROBRAKE_AP_BURN TO 1.' in (ROOT/'craft/RO9.ks').read_text()
    orient=function_body(AERO,'_aerobrakeOrient')
    assert 'LOCK STEERING TO _aerobrakeEntryDirection().' in orient
    assert 'LOCAL steerDir' not in orient and 'LOCAL refVec' not in orient
    assert not re.search(r'AEROBRAKE_AP_(?:DV_CAP|PASS_DV_CAP|MAX_TIME|HEIGHT_WINDOW|TARGET)\b',SOURCE+CONFIG+command)
    print('PASS: boolean policy/RO9 default survive both return profiles; entry integration and archive command preserve phase/node, and interruption restores CPU budget')


if __name__=='__main__':
    check_live_cutoffs()
    check_repair_reserve()
    check_entry_and_direction()
    for mode in ('RETROGRADE','PROGRADE'):check_live_entry_orientation(mode)
    check_finite_plan()
    for turn_rate in (0,5):check_powered_alignment(turn_rate)
    check_source_execution()
    for args in ((869,0),(869,100),(3200,0)):check_uncapped_fuel(*args)
    for drag in (0,1,10):check_disturbance_and_stale_control(drag)
    check_interrupted_owner()
    check_interruption_and_opt_in()
    check_profile_command_and_entry_alignment()
