"""Source-driven incremental terrain search and powered-descent regressions.

Flat position/altitude fixtures with prescribed terrain query results; no KSP
terrain mesh, actual CPU scheduling, fuel capacity or full landing dynamics.
"""
from types import SimpleNamespace as NS
import math
import re

import check_landing_guidance as ks
from check_landing_braking import fixture as brake_fixture, call, Vec
from check_codebase import function_body
from check_runtime_contracts import run

SOURCE = (ks.ROOT / 'lib/landing_divert.ks').read_text()


def fixture(gravity=1.63, radius=200000):
    env, ctx = brake_fixture(gravity=gravity, twr=2.76/gravity, horizontal=17.55, down=28.28, height=857)
    ctx.update(TARGET_LAT=29584/radius*180/math.pi, TARGET_LNG=0,
               TARGET_ELEVATION=3000, REQUESTED_LAT=9, REQUESTED_LNG=1,
               HOVER_TERRAIN_DONE=False, TARGET_THROTTLE=1, throttle=1,
               POSITION=Vec((0,0,857)), STATE='BRAKING_BURN')
    events, samples, light_calls = [], [], []
    overrides=dict(SEQUENCE=['LAND_ASSIST','SURFACE_RETURN_SETUP'], RETURN_PE=53000)
    scale=radius*math.pi/180
    def geo(lat,lng):
        return NS(LAT=lat,LNG=lng,TERRAINHEIGHT=env['elevation_at'](lat*scale,lng*scale),
                  POSITION=Vec((lat*scale,lng*scale,0)))
    env['SHIP'].BODY=NS(RADIUS=radius, GEOPOSITIONOF=lambda pos: geo(pos[0]/scale,pos[1]/scale))
    env['SHIP'].POSITION=ctx['POSITION']
    env['SHIP'].ALTITUDE=3857
    def refresh(c):
        env['SHIP'].POSITION=c['POSITION']
        env['SHIP'].ALTITUDE=3000+c['height']
        events.append('refresh')
    def grade(lat,lng,step):
        assert step==20
        samples.append((round(lat*scale,6),round(lng*scale,6)))
        return env['grade_at'](lat*scale,lng*scale)
    def light(*args):
        light_calls.append(args)
        return dict(OK=True,REASON='ok',SUN=20.2,KERBIN=7.26)
    env.update(LANDING_FLEXIBLE_SITE=1, LANDING_REQUIRE_KERBIN=1, MAX_TILT=12,
               LANDING_DIVERT_EMERGENCY_SLOPE=0, elevation_at=lambda x,y:3000,
               grade_at=lambda x,y:.02, landingTerrainGrade=grade,
               LATLNG=geo, landingLightWindow=light,
               lmTimeToImpact=lambda: (math.sqrt(ctx['V_SPEED']**2+2*ctx['height']*ctx['GRAV'])+ctx['V_SPEED'])/ctx['GRAV'],
               lmDistanceToTarget=lambda lat,lng: math.hypot(lat*scale-ctx['POSITION'][0],lng*scale-ctx['POSITION'][1]),
               geoDistance=lambda a,b,c,d: math.hypot(a-c,b-d)*scale,
               ADDONS=NS(TR=NS(AVAILABLE=True,SETTARGET=lambda point:events.append('target'))),
               missionOverrideUpdate=lambda changes:overrides.update(changes),
               _landingCacheTick=refresh, landingAbortFlag=False,
               _landingTerrainCheck=lambda *args: (_ for _ in ()).throw(AssertionError('blocking grid')),
               thrustCutoffOk=lambda *args: (_ for _ in ()).throw(AssertionError('search cut throttle')))
    for name in ('_landingDivertStart','_landingDivertCandidate','_landingDivertRetryReady','landingReviewReachableSite'):
        env[name]=lambda *args,name=name:call(name,env,*args)
    return env,ctx,events,overrides,samples,light_calls


def tick(env,ctx,now=0):
    env['TIME'].SECONDS=now
    return call('landingReviewReachableSite',env,ctx)


def check_diversion():
    env,ctx,events,overrides,samples,lights=fixture()
    original=(ctx['REQUESTED_LAT'],ctx['REQUESTED_LNG'])
    assert tick(env,ctx) and ctx['DIVERT_PENDING']  # Remote old target rejected cheaply.
    assert not samples and ctx['TARGET_THROTTLE']==1
    assert tick(env,ctx,.05) and not ctx['DIVERT_PENDING']
    assert len(samples)==1 and ctx['HOVER_TERRAIN_DONE']
    assert ctx['TARGET_LAT']<1 and ctx['TARGET_ELEVATION']==3000
    assert (ctx['REQUESTED_LAT'],ctx['REQUESTED_LNG'])==original
    assert overrides['SEQUENCE']==['LAND_ASSIST','SURFACE_RETURN_SETUP']
    assert overrides['RETURN_PE']==53000 and overrides['TARGET_LAT']==ctx['TARGET_LAT']
    assert ctx['TARGET_THROTTLE']==1 and lights[0][-2:]==(7,0)
    assert env['LANDING_REQUIRE_KERBIN']==1 and 'target' in events
    env,ctx,events,overrides,samples,_=fixture()
    env['ADDONS'].TR.AVAILABLE=False
    tick(env,ctx)
    tick(env,ctx,.05)
    assert not ctx['DIVERT_PENDING'] and 'target' not in events
    for precision, speed, validated in ((True,17,False),(False,355,False),(False,0,True)):
        env,ctx,events,overrides,samples,_=fixture()
        env['LANDING_FLEXIBLE_SITE']=0 if precision else 1
        ctx.update(H_SPEED=speed,HOVER_TERRAIN_DONE=validated)
        if validated: ctx['TARGET_LAT']=ctx['TARGET_LNG']=0
        assert tick(env,ctx) and not ctx['DIVERT_PENDING'] and not events and not samples
    print('PASS: local post-brake site replaces 29.6 km target without blocking grids/cutoff; return intent, original request and optional radio policy retained; precision and fast coast unchanged')


def check_candidates_and_search():
    for failure in ('steep','sun','radio','budget','high-site'):
        env,ctx,events,overrides,samples,_=fixture()
        if failure=='steep': env['grade_at']=lambda x,y:.238
        if failure in ('sun','radio'):
            env['landingLightWindow']=lambda *args:dict(OK=False,REASON=failure,SUN=0,KERBIN=0)
            if failure=='radio': env['LANDING_DIVERT_REQUIRE_KERBIN']=1
        if failure=='budget': env['lmDistanceToTarget']=lambda *args:29584
        if failure=='high-site': env['elevation_at']=lambda *args:4000
        point=call('_landingDivertCandidate',env,ctx,0,0,5)
        assert not point['OK'] and 'TARGET_LAT' not in overrides
        assert ctx['TARGET_THROTTLE']==1 and not events
    env,ctx,events,overrides,samples,_=fixture()
    ctx.update(H_SPEED=0,H_VEL=Vec((0,0,0)))
    env.update(LANDING_DIVERT_SEARCH_RADIUS=200,LANDING_DIVERT_SEARCH_TIME=1000,
               grade_at=lambda x,y:.238)
    for step in range(40):
        before=len(samples)
        assert tick(env,ctx,step*.05)
        assert len(samples)-before<=1
    assert ctx['DIVERT_PENDING'] and ctx['DIVERT_SEARCH']['EXHAUSTED']
    assert len(samples)==25 and len(set(samples))==25
    assert set(samples)=={(float(x),float(y)) for x in range(-200,201,100) for y in range(-200,201,100)}
    assert ctx['TARGET_THROTTLE']==1 and 'TARGET_LAT' not in overrides
    # A steep center does not hide a nearby flat candidate.
    env,ctx,events,overrides,samples,_=fixture()
    ctx.update(H_SPEED=0,H_VEL=Vec((0,0,0)))
    env['grade_at']=lambda x,y:.238 if abs(x)+abs(y)<50 else .02
    for step in range(5): tick(env,ctx,step*.05)
    assert not ctx['DIVERT_PENDING'] and len(samples)==2
    print('PASS: slope/Sun/strict radio/clearance/reachability reject individual sites without aborting control; bounded spiral visits every point once and finds a flat neighbor')


def check_emergency_limits():
    for allowance,grade,accepted in ((0,.238,False),(15,.238,True),(15,math.tan(math.radians(16)),False)):
        env,ctx,events,overrides,samples,_=fixture()
        env.update(LANDING_DIVERT_EMERGENCY_SLOPE=allowance,
                   LANDING_DIVERT_SEARCH_TIME=1,grade_at=lambda x,y:grade)
        for step in range(80):
            assert tick(env,ctx,step*.05)
            if 'TARGET_LAT' in overrides: break
            if step<20: assert 'TARGET_LAT' not in overrides
        assert ('TARGET_LAT' in overrides)==accepted,(allowance,grade,ctx)
        if accepted:
            assert ctx['DIVERT_SEARCH']['EMERGENCY'] and ctx['DIVERT_SEARCH']['SLOPE_LIMIT']==15
        else:
            assert ctx['DIVERT_PENDING'] and ctx['DIVERT_SEARCH']['EXHAUSTED']
            call('_landingBrakeSteeringInfo',env,ctx)
            env['SHIP'].FACING.FOREVECTOR=ctx['steering']
            call('_landingBrakingTick',env,ctx)
            assert ctx['TARGET_THROTTLE']>0 and ctx['STATE']=='BRAKING_BURN'
            assert not env['landingAbortFlag']
    for vehicle in ('RO8','RO9'):
        for moon in ('mun','minmus'):
            profile=(ks.ROOT/f'missions/{vehicle}/{moon}_economy_return.ks').read_text()
            assert 'SET LANDING_DIVERT_EMERGENCY_SLOPE TO 15.' in profile
    print('PASS: 13.4-degree site rejected normally and accepted only after authorized 15-degree fallback; steeper sites and default strict policy retain powered control with no accepted target')


def check_reported_failure_recovery():
    env,ctx,events,overrides,samples,_=fixture()
    env.update(LANDING_DIVERT_EMERGENCY_SLOPE=15,grade_at=lambda x,y:.238)
    minimum=ctx['height']
    accepted_at=None
    dt=.1
    for step in range(1500):
        now=step*dt
        env['TIME'].SECONDS=now
        env['SHIP'].FACING.FOREVECTOR=ctx.get('steering',ctx['UP_VEC'])
        env['_landingCacheTick'](ctx)
        before=len(samples)
        call('_landingBrakingTick',env,ctx)
        assert len(samples)-before<=1
        if ctx['DIVERT_PENDING']:
            assert ctx['STATE']=='BRAKING_BURN' and not env['landingAbortFlag']
        elif accepted_at is None and 'TARGET_LAT' in overrides:
            accepted_at=now
            assert ctx['DIVERT_SEARCH']['EMERGENCY']
        if ctx['STATE']!='BRAKING_BURN': break
        # Keep the existing three-second no-thrust latency reserve.
        command=ctx['TARGET_THROTTLE'] if now>=3 else 0
        thrust=ctx.get('steering',ctx['UP_VEC'])*(command*ctx['MAX_ACC'])
        velocity=ctx['SURFACE_VEL']+(thrust-ctx['UP_VEC']*ctx['GRAV'])*dt
        ctx.update(H_VEL=Vec((velocity[0],velocity[1],0)),H_SPEED=math.hypot(velocity[0],velocity[1]),
                   V_SPEED=velocity[2],DOWN_SPEED=max(0,-velocity[2]),SURFACE_VEL=velocity)
        ctx['POSITION']+=velocity*dt
        ctx['height']=ctx['POSITION'][2]
        minimum=min(minimum,ctx['height'])
        assert minimum>0,(now,ctx)
    assert accepted_at is not None and accepted_at>=15
    assert ctx['STATE'] in ('APPROACH','TARGET_REFINE','VERTICAL_DESCENT'),ctx
    assert minimum>100 and ctx['H_SPEED']<18,(minimum,ctx)
    print(f'PASS: reported 857 m / -28.28 m/s / 17.55 m/s restart, 2.76 m/s2, 3-second delay and 13.4-degree terrain retains powered guidance; emergency site at {accepted_at:.1f}s, terminal handoff above {minimum:.0f} m')


def check_stale_reachability():
    for captured_after_hold in (True, False):
        env,ctx,events,overrides,samples,_=fixture(gravity=.491,radius=60000)
        ctx.update(H_SPEED=12,H_VEL=Vec((12,0,0)),V_SPEED=0,DOWN_SPEED=0,
                   height=1481,POSITION=Vec((0,0,1481)),TARGET_LAT=7980/60000*180/math.pi)
        env.update(MAX_TILT=12,LANDING_DIVERT_EMERGENCY_SLOPE=15,LANDING_DIVERT_SEARCH_TIME=1,
                   grade_at=lambda x,y:.1)
        env['_landingCacheTick'](ctx)
        # At 12 m/s the conservative Minmus approach budget cannot accept
        # even the center. Reproduce both passes rejecting before capture.
        for step in range(50):
            if (not captured_after_hold and ctx['DIVERT_SEARCH'].get('EMERGENCY')
                    and step*.05-ctx['DIVERT_SEARCH']['STARTED']>=1):
                ctx.update(H_SPEED=0,H_VEL=Vec((0,0,0)))
            tick(env,ctx,step*.05)
            if ctx['DIVERT_SEARCH']['EXHAUSTED'] or ctx['DIVERT_SEARCH']['RETRIED']:
                break
        assert 'TARGET_LAT' not in overrides and not samples
        if captured_after_hold:
            assert ctx['DIVERT_SEARCH']['EXHAUSTED']
            assert ctx['DIVERT_SEARCH']['REJECTS']['reachability']>0
            ctx.update(H_SPEED=9,H_VEL=Vec((9,0,0)))
            step+=1
            tick(env,ctx,step*.05)
            assert ctx['DIVERT_SEARCH']['EXHAUSTED'] and not ctx['DIVERT_SEARCH']['RETRIED']
            ctx.update(H_SPEED=0,H_VEL=Vec((0,0,0)))
        assert call('_landingDivertCandidate',env,ctx,0,0,15)['OK']
        # An unchanged exhausted search used to hover forever despite this
        # now-valid nearby site. The retry must still begin with normal slope.
        for more in range(100):
            before=len(samples)
            tick(env,ctx,(step+more+1)*.05)
            assert len(samples)-before<=1
            if 'TARGET_LAT' in overrides: break
        assert 'TARGET_LAT' in overrides and not ctx['DIVERT_PENDING']
        search=ctx['DIVERT_SEARCH']
        assert search['RETRIED'] and search['EMERGENCY'] and search['SLOPE_LIMIT']==15
        assert search['REJECTS']['terrain-grade']>0  # 5-degree pass was retained.
        assert search['REJECTS']['reachability']>0   # Original 8km site still rejected.
        assert abs(ctx['TARGET_LAT'])<1e-9 and abs(ctx['TARGET_LNG'])<1e-9
        assert overrides['RETURN_PE']==53000 and ctx['TARGET_THROTTLE']==1
    print('PASS: Minmus 1481m/7980m target miss retries stale reachability after velocity capture, before or after exhaustion; 5-degree search precedes authorized 15-degree site and one-candidate work bound remains')


def check_retry_bound_and_rejections():
    env,ctx,_,overrides,_,_=fixture(gravity=.491,radius=60000)
    ctx.update(H_SPEED=12,H_VEL=Vec((12,0,0)))
    env.update(MAX_TILT=12,LANDING_DIVERT_EMERGENCY_SLOPE=15,LANDING_DIVERT_SEARCH_TIME=1,
               grade_at=lambda x,y:.4)
    for step in range(45): tick(env,ctx,step*.05)
    assert ctx['DIVERT_SEARCH']['EXHAUSTED']
    ctx.update(H_SPEED=0,H_VEL=Vec((0,0,0)))
    for step in range(45,140): tick(env,ctx,step*.05)
    search=ctx['DIVERT_SEARCH']
    assert search['RETRIED'] and search['EXHAUSTED'] and ctx['DIVERT_PENDING']
    assert search['REJECTS']['terrain-grade']>0 and 'TARGET_LAT' not in overrides
    # Further motion cannot create an unbounded series of searches.
    ctx['POSITION'][0]+=500
    env['_landingCacheTick'](ctx)
    for step in range(140,180): tick(env,ctx,step*.05)
    assert ctx['DIVERT_SEARCH'] is search
    for failure in ('terrain-grade','altitude-clearance','eclipse'):
        env,ctx,_,_,_,_=fixture()
        ctx.update(H_SPEED=0,H_VEL=Vec((0,0,0)))
        env['LANDING_DIVERT_SEARCH_RADIUS']=0
        if failure=='terrain-grade': env['grade_at']=lambda x,y:.4
        if failure=='altitude-clearance': env['elevation_at']=lambda x,y:4000
        if failure=='eclipse': env['landingLightWindow']=lambda *args:dict(OK=False,REASON='eclipse',SUN=20,KERBIN=10)
        for step in range(6): tick(env,ctx,step*.05)
        counts=ctx['DIVERT_SEARCH']['REJECTS']
        category='light' if failure=='eclipse' else failure
        assert counts[category]>0 and ctx['DIVERT_SEARCH']['LAST_REASON']==failure
        assert ctx['DIVERT_SEARCH']['EXHAUSTED'] and ctx['DIVERT_PENDING']
    print('PASS: only one changed-reachability retry; unsafe grade/clearance/light still reject, exhausted control retained and failure totals identify inner-site causes')


def check_shifted_stopping_point():
    env,ctx,_,overrides,_,_=fixture(gravity=.491,radius=60000)
    ctx.update(H_SPEED=0,H_VEL=Vec((0,0,0)))
    env.update(LANDING_DIVERT_SEARCH_RADIUS=0,
               grade_at=lambda x,y:.02 if x>400 else .4)
    for step in range(5): tick(env,ctx,step*.05)
    assert ctx['DIVERT_SEARCH']['EXHAUSTED'] and 'TARGET_LAT' not in overrides
    ctx['POSITION'][0]=500
    env['_landingCacheTick'](ctx)
    for step in range(5,10): tick(env,ctx,step*.05)
    assert ctx['DIVERT_SEARCH']['RETRIED'] and not ctx['DIVERT_PENDING']
    assert abs(ctx['TARGET_LAT']*60000*math.pi/180-500)<1e-6
    assert ctx['DIVERT_SEARCH']['EMERGENCY'] is False
    print('PASS: a materially shifted stopping point refreshes the local search even at unchanged speed, accepting only newly checked normal-limit terrain')


def check_paused_minmus_hover():
    env,ctx,_,overrides,_,_=fixture(gravity=.491,radius=60000)
    ctx.update(H_SPEED=0,H_VEL=Vec((0,0,0)),V_SPEED=0,DOWN_SPEED=0,
               SURFACE_VEL=Vec((0,0,0)),height=1481,POSITION=Vec((0,0,1481)),
               TARGET_LAT=7980/60000*180/math.pi)
    env.update(LANDING_DIVERT_EMERGENCY_SLOPE=15,grade_at=lambda *args:.1)
    accepted=None
    coasted=False
    dt=.1
    for step in range(2500):
        env['TIME'].SECONDS=step*dt
        env['SHIP'].FACING.FOREVECTOR=ctx.get('steering',ctx['UP_VEC'])
        env['_landingCacheTick'](ctx)
        handler={'COAST':'_landingCoastTick','BRAKE_ALIGN':'_landingBrakeAlignTick',
                 'BRAKING_BURN':'_landingBrakingTick'}[ctx['STATE']]
        call(handler,env,ctx)
        if 'TARGET_LAT' in overrides and accepted is None: accepted=step*dt
        coasted|=ctx['STATE']=='COAST' and accepted is not None
        if ctx['STATE'] in ('VERTICAL_DESCENT','TARGET_REFINE','APPROACH'): break
        command=ctx['TARGET_THROTTLE'] if step*dt>=3 else 0
        thrust=ctx.get('steering',ctx['UP_VEC'])*(command*ctx['MAX_ACC'])
        velocity=ctx['SURFACE_VEL']+(thrust-ctx['UP_VEC']*ctx['GRAV'])*dt
        ctx.update(SURFACE_VEL=velocity,V_SPEED=velocity[2],DOWN_SPEED=max(0,-velocity[2]),
                   H_SPEED=math.hypot(velocity[0],velocity[1]),H_VEL=Vec((velocity[0],velocity[1],0)))
        ctx['POSITION']+=velocity*dt
        ctx['height']=ctx['POSITION'][2]
        assert ctx['height']>0
    assert accepted is not None and accepted>=15 and coasted
    assert ctx['STATE']=='VERTICAL_DESCENT' and 100<ctx['height']<1000
    assert ctx['V_SPEED'] < -5 and not ctx['DIVERT_PENDING']
    assert overrides['RETURN_PE']==53000
    print(f'PASS: paused Minmus 1481m/zero-velocity/7980m miss restart selects a checked local site at {accepted:.1f}s, leaves search braking for coast and reaches descending terminal handoff at {ctx["height"]:.0f}m; flat point mass, not flight proof')


def check_cpu_and_scan_order():
    main=function_body((ks.ROOT/'lib/landing_main.ks').read_text(),'landExecute')
    setup=main[main.index('LOCAL priorIpu'):main.index('IF SHIP:BODY:ATM:EXISTS')]
    boot=function_body((ks.ROOT/'lib/boot_lib.ks').read_text(),'bootPreamble')
    for initial in (150,500,2000,2500):
        saved={}
        env=ks.environment()
        env.update(CONFIG=NS(IPU=initial),stateSet=lambda k,v: saved.update({k:v}),
                   stateGetNum=lambda k,d: saved.get(k,d),
                   stateRemove=lambda k: saved.pop(k,None),bootLibLoad=lambda _: None)
        run(setup,env)
        assert env['CONFIG'].IPU==max(initial,2000)
        run(boot,env)
        assert env['CONFIG'].IPU==initial and not saved
    for marker in ('IF landingAbortFlag {','LOCAL landed IS _landingFinish(ctx).'):
        tail=main[main.index(marker):]
        assert tail.index('SET CONFIG:IPU TO priorIpu.')<tail.index('RETURN ')
    assert main.index('_landingFinalTerrainCheck(ctx)')<main.index('LOCK THROTTLE TO ctx[')
    # Low-altitude economy reboots must not survey a remote saved target
    # before establishing guidance. Precision keeps its original surveys.
    setup=main[main.index('LOCAL targetElevation'):main.index('LOCAL crossPid')]
    for flexible in (0,1):
        surveys=[]
        env=ks.environment()
        env.update(_hasTarget=True,LANDING_FLEXIBLE_SITE=flexible,
                   LATLNG=lambda *args:NS(TERRAINHEIGHT=3000),
                   _landingTerrainCheck=lambda *args: surveys.append(args) or dict(LAT=0,LNG=0,ELEVATION=3000))
        run(setup,env)
        assert len(surveys)==1-flexible and env['terrainDone']
        assert env['targetElevation']==3000
    env=ks.environment()
    env.update(LANDING_FLEXIBLE_SITE=1,
               _landingTerrainCheck=lambda *args: (_ for _ in ()).throw(AssertionError('blocking final grid')))
    call('_landingFinalTerrainCheck',env,{})
    review=function_body(SOURCE,'landingReviewReachableSite')
    assert review.count('_landingDivertCandidate(')==1
    for forbidden in ('_landingTerrainCheck(', 'thrustCutoffOk(', 'WAIT '):
        assert forbidden not in review
    print('PASS: CPU restoration retained; economy reboot skips remote grids and incremental search has one candidate/tick; precision survey retained')


def check_library_scope():
    # The fixture interpreter intentionally combines files. Check the split
    # files separately too: a LOCAL function cannot cross a compiled unit.
    names=('landing_main','landing_divert','landing_light','landing_light_math',
           'landing_coast','landing_brake','landing_terminal')
    files={name:(ks.ROOT/f'lib/{name}.ks').read_text() for name in names}
    for owner,source in files.items():
        for private in re.findall(r'LOCAL FUNCTION (\w+)',source):
            for caller,text in files.items():
                if caller!=owner:
                    assert not re.search(r'\b'+private+r'\s*\(',text),(owner,caller,private)
    print('PASS: shared geometry/diversion functions are exported; file-private helpers stay in their compiled unit')


if __name__=='__main__':
    check_diversion()
    check_candidates_and_search()
    check_emergency_limits()
    check_reported_failure_recovery()
    check_stale_reachability()
    check_retry_bound_and_rejections()
    check_shifted_stopping_point()
    check_paused_minmus_hover()
    check_cpu_and_scan_order()
    check_library_scope()
