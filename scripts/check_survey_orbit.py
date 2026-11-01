"""Manual scan changes against independent impulse/Kepler/map fixtures, not KSP."""
import math
import re
from functools import lru_cache
from types import SimpleNamespace as NS

import check_relay_constellation as harness
from check_codebase import ROOT, function_body, closure, dependency_tables, command_entrypoint_errors
from check_espoir_fleet import Items, Text, native
import check_landing_guidance as ks

SOURCE=(ROOT/'lib/survey_orbit.ks').read_text().replace('ADD nd.','fixture_add(nd).')
SOURCE=SOURCE.replace('FROM { LOCAL j IS 0. } UNTIL j >= 384 STEP { SET j TO j + 1. } DO {',
    'FOR j IN fixture_indices(384) {')
GROUND=(ROOT/'lib/landing_math.ks').read_text()
COMMAND=(ROOT/'cmd/scanorbit.ks').read_text().replace('IF DEFINED EXCURSION_RESERVE_DV', 'IF fixtureDefined()')
SHAPE=(ROOT/'lib/orbit_shape.ks').read_text()


def source_call(source,name,env,*args):
    # These helpers mutate passed records or call fixture primitives, never
    # assign shared scalar globals. Plain function-local dicts avoid millions
    # of Scope.__getitem__ calls while running the same compiled source.
    names,defaults,(code,_)=harness.prepared(source,name)
    assert '__fixture_evaluate' not in code.co_names
    try:exec(code,env,{**defaults,**dict(zip(names,args))})
    except ks.Returned as result:return result.value


def dot(a,b):return sum(x*y for x,y in zip(a,b))
def add(a,b):return tuple(x+y for x,y in zip(a,b))
def mul(a,k):return tuple(x*k for x in a)
def norm(a):return math.sqrt(dot(a,a))
def unit(a):return mul(a,1/norm(a))
def cross(a,b):return (a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0])
def deg(x):return math.degrees(x)
def rad(x):return math.radians(x)


@lru_cache(maxsize=32768)
def propagate(mu,a,e,mean,epoch,peri_axis,transverse_axis,ut):
    # Exact immutable inputs only: repeated native-node previews can share
    # ephemerides, while changed elements, bodies and epochs cannot. Preserve
    # all eight Newton steps and every requested sample time without rounding.
    n=2*math.pi/(2*math.pi*math.sqrt(a**3/mu))
    mean=(mean+n*(ut-epoch)+math.pi)%(2*math.pi)-math.pi
    ea=mean
    for _ in range(8):ea-=(ea-e*math.sin(ea)-mean)/(1-e*math.cos(ea))
    cos_ea=math.cos(ea);sin_ea=math.sin(ea);root=math.sqrt(1-e*e)
    along=a*(cos_ea-e);across=a*root*sin_ea
    rate=n*a/(1-e*cos_ea);v_along=-sin_ea;v_across=root*cos_ea
    pos=tuple(peri_axis[k]*along+transverse_axis[k]*across for k in range(3))
    vel=tuple((peri_axis[k]*v_along+transverse_axis[k]*v_across)*rate for k in range(3))
    return pos,vel


class Orbit:
    """Recover a conic from independent Cartesian states, then solve Kepler."""
    def __init__(self,bdy,pos,vel,epoch):
        self.BODY=bdy;self.epoch=epoch;self.HASNEXTPATCH=False
        h=cross(pos,vel);hm=norm(h);self.hat=unit(h)
        ev=add(mul(cross(vel,h),1/bdy.MU),mul(unit(pos),-1))
        self.ECCENTRICITY=norm(ev)
        self.SEMIMAJORAXIS=1/(2/norm(pos)-dot(vel,vel)/bdy.MU)
        self.p=unit(ev) if norm(ev)>1e-9 else unit(pos)
        self.qq=cross(self.hat,self.p)
        f=math.atan2(dot(pos,self.qq),dot(pos,self.p));e=self.ECCENTRICITY
        ea=2*math.atan2(math.sqrt(1-e)*math.sin(f/2),math.sqrt(1+e)*math.cos(f/2))
        self.mean=ea-e*math.sin(ea)
        self.INCLINATION=deg(math.acos(max(-1,min(1,self.hat[2]))))
        node=cross((0,0,1),h);self.LAN=deg(math.atan2(node[1],node[0]))%360
        self.ARGUMENTOFPERIAPSIS=deg(math.atan2(dot(cross(unit(node),self.p),self.hat),dot(unit(node),self.p)))%360 if norm(node)>1e-10 else 0
    PERIOD=property(lambda s:2*math.pi*math.sqrt(s.SEMIMAJORAXIS**3/s.BODY.MU))
    APOAPSIS=property(lambda s:s.SEMIMAJORAXIS*(1+s.ECCENTRICITY)-s.BODY.RADIUS)
    PERIAPSIS=property(lambda s:s.SEMIMAJORAXIS*(1-s.ECCENTRICITY)-s.BODY.RADIUS)
    def state(self,ut):
        return propagate(self.BODY.MU,self.SEMIMAJORAXIS,self.ECCENTRICITY,self.mean,self.epoch,self.p,self.qq,ut)


class Node:
    def __init__(self,env,ut,ra,no,pr):
        self.env=env;self.TIME=ut;self.RADIALOUT=ra;self.NORMAL=no;self.PROGRADE=pr;self.alive=True
    ETA=property(lambda s:s.TIME-s.env['TIME'].SECONDS)
    DELTAV=property(lambda s:NS(MAG=math.sqrt(s.PROGRADE**2+s.NORMAL**2+s.RADIALOUT**2)))
    @property
    def ORBIT(self):
        assert self.alive,'detached node inspected'
        key=(self.TIME,self.RADIALOUT,self.NORMAL,self.PROGRADE)
        if getattr(self,'_key',None)==key:return self._orbit
        orb=self.env['SHIP'].ORBIT;pos,vel=orb.state(self.TIME)
        pro=unit(vel);normal=unit(cross(pos,vel));ra=cross(pro,normal)
        vel=add(vel,add(mul(pro,self.PROGRADE),add(mul(normal,self.NORMAL),mul(ra,self.RADIALOUT))))
        self._key=key;self._orbit=Orbit(orb.BODY,pos,vel,self.TIME)
        return self._orbit


class Ship:
    APOAPSIS=property(lambda s:s.ORBIT.APOAPSIS)
    PERIAPSIS=property(lambda s:s.ORBIT.PERIAPSIS)


def fixture(inc=85,body='Minmus'):
    bdy=NS(NAME=Text(body),RADIUS=60000,MU=1.7658e9,SOIRADIUS=2247428,ROTATIONPERIOD=40400,ATM=NS(EXISTS=False,HEIGHT=0))
    if body=='Duna':bdy.RADIUS=320000;bdy.MU=3.0136321e11;bdy.SOIRADIUS=47921949;bdy.ATM=NS(EXISTS=True,HEIGHT=50000)
    if body=='Kerbin':
        bdy.RADIUS=600000;bdy.MU=3.5316e12;bdy.SOIRADIUS=84159286;bdy.ROTATIONPERIOD=21549.425
        bdy.ATM=NS(EXISTS=True,HEIGHT=70000)
    radius=bdy.RADIUS+(100000 if body=='Kerbin' else 70000);speed=math.sqrt(bdy.MU/radius);ln=rad(40);ic=rad(inc)
    initial=Orbit(bdy,(radius*math.cos(ln),radius*math.sin(ln),0),
        (-speed*math.sin(ln)*math.cos(ic),speed*math.cos(ln)*math.cos(ic),speed*math.sin(ic)),1000)
    ship=Ship();ship.ORBIT=initial;ship.BODY=bdy;ship.STATUS=Text('ORBITING');ship.THRUST=0
    ship.CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0);ship.DELTAV=NS(VACUUM=1000);ship.AVAILABLETHRUST=2
    ship.PARTS=Items([NS(HASMODULE=lambda mod:mod=='SCANsat')])
    clock=NS(SECONDS=1000.);state={'phase':Text('SCANSAT_OPS'),'vehicle':Text('Espoir'),
        'mission_id':Text('minmus_orbital_surveyor'),'launch_time':100,'shape_budget_id':Text(body+':100'),'shape_budget_spent':10}
    universe=NS(ACTIVEVESSEL=ship,REALTIME=0,TIMEWARP=NS(ISSETTLED=True));events=[];nodes=[];coverage=set()
    env=dict(SHIP=ship,KUNIVERSE=universe,TIME=clock,WARP=0,ABORT=False,HASNODE=False,
        ALLNODES=Items(),STAGE=NS(DELTAV=NS(VACUUM=500)),ETA=NS(PERIAPSIS=500,APOAPSIS=500+initial.PERIOD/2),
        SHAPE_DV_CAP=100,SHAPE_TOTAL_DV_CAP=500,SHAPE_RESERVE_DV=300,SHAPE_MIN_PE=10000,
        stateGet=lambda k,d='':state.get(str(k),d),stateGetNum=lambda k,d=0:state.get(str(k),d),
        stateSet=lambda k,v:state.update({str(k):v}),stateRemove=lambda k:state.pop(str(k),None),
        MAX=max,MIN=min,ABS=abs,SQRT=math.sqrt,FLOOR=math.floor,MOD=lambda x,y:x%y,
        COS=lambda x:math.cos(rad(x)),SIN=lambda x:math.sin(rad(x)),ROUND=round,
        LIST=lambda *xs:Items(xs),LEXICON=lambda *xs:harness.Record(zip(xs[::2],xs[1::2])),
        LATLNG=lambda a,b:NS(LAT=a,LNG=b),fixture_text=Text,fixture_indices=lambda n:range(int(n)),
        fixture_wait=lambda dt:None,fixture_settle=lambda:None,fixtureDefined=lambda:False,
        diagnosticArchiveLine=lambda report,row:events.append(str(row)),
        mLog=lambda row:events.append(str(row)),mLogWarn=lambda row:events.append(str(row)),
        mLogSummary=lambda row:events.append(str(row)),yieldToPrompt=lambda:events.append('hold'))
    def put(nd):
        assert not env['HASNODE'];env.update(HASNODE=True,NEXTNODE=nd)
        env['ALLNODES'].append(nd);nodes.append(nd)
    def remove(nd):
        assert env['NEXTNODE'] is nd and nd.alive;nd.alive=False
        env.update(HASNODE=False);env['ALLNODES'].clear();events.append('remove')
    env.update(NODE=lambda *args:Node(env,*args),fixture_add=put,fixture_remove=remove)
    # The plane optimizer itself is covered by check_plane_rotation. This
    # adapter supplies its physical velocity rotation at a relative node;
    # the actual search, propagation, cost checks and map ranking run below.
    def plane(want,lan):
        assert abs(lan-40)<1e-7,'mirror must keep LAN, not reverse the orbit'
        ut=1000+initial.PERIOD;pos,vel=initial.state(ut);theta=rad(want-inc);sp=norm(vel)
        nd=Node(env,ut,0,sp*math.sin(theta),sp*(math.cos(theta)-1));put(nd);return nd
    def position(ut):
        if env['HASNODE'] and ut>=env['NEXTNODE'].TIME:return env['NEXTNODE'].ORBIT.state(ut)[0]
        return initial.state(ut)[0]
    def geo(pos):
        return NS(LAT=deg(math.atan2(pos[2],math.hypot(pos[0],pos[1]))),
                  LNG=deg(math.atan2(pos[1],pos[0]))-360*clock.SECONDS/bdy.ROTATIONPERIOD)
    env.update(planPlaneMatch=plane,POSITIONAT=lambda obj,ut:position(ut))
    def eta(ta):
        orb=ship.ORBIT;ecc=orb.ECCENTRICITY
        ea=2*math.atan2(math.sqrt(1-ecc)*math.sin(rad(ta)/2),math.sqrt(1+ecc)*math.cos(rad(ta)/2))
        mean=ea-ecc*math.sin(ea)
        live=orb.mean+2*math.pi*(clock.SECONDS-orb.epoch)/orb.PERIOD
        return ((mean-live)%(2*math.pi))*orb.PERIOD/(2*math.pi)
    env['etaToTrueAnomaly']=eta
    bdy.GEOPOSITIONOF=geo
    world=dict(bad_map=False,all_done=False,coverage=coverage,query=0)
    def cell(geo):return math.floor(geo.LAT+90),math.floor((geo.LNG+180)%360)
    def complete(obj,geo):
        world['query']+=1
        if world['bad_map']:return Text('unavailable')
        done=world['all_done'] or cell(geo) in coverage
        return Items([Text('HIRESALTIMETRY')]) if done else Items()
    scan=NS(AVAILABLE=True,COMPLETEDSCANS=complete,
        ALLSCANTYPES=Items([Text('BIOME'),Text('HIRESALTIMETRY')]),
        GETCOVERAGE=lambda obj,kind:80 if kind=='BIOME' else 94)
    env['ADDONS']=NS(AVAILABLE=lambda _:True,SCANSAT=scan)
    env['lmGroundGeoAt']=lambda *args:source_call(GROUND,'lmGroundGeoAt',env,*args)
    for name in re.findall(r'(?:GLOBAL|LOCAL) FUNCTION (\w+)',SOURCE):
        env[name]=lambda *args,name=name:source_call(SOURCE,name,env,*args)
    env['shapeReserveBurn']=lambda nd:harness.invoke(SHAPE,'_shapeReserveBurn',env,nd)
    env['shapePeFloor']=lambda:harness.invoke(SHAPE,'shapePeFloor',dict(env,_peFloor=lambda:harness.invoke(SHAPE,'_peFloor',env)))
    env.update(HOMECONNECTION=NS(ISCONNECTED=True),bootPreamble=lambda:None,bootLibLoad=lambda _:None,
        bootArchivePath=lambda _:Text('profile'),bootMissionProfileId=lambda *args:args[-1],
        bootLocalScriptPath=lambda _:Text('local_profile'),
        bootMissionProfileIntent=lambda *_:None,applyMissionOverrides=lambda:None,
        EXISTS=lambda _:True,RUNPATH=lambda *_:None,RUNONCEPATH=lambda *_:None,
        diagnosticArchiveOpen=lambda _:harness.Record([('READY',True)]),
        diagnosticArchiveClose=lambda *_:True,action=Text('preview'),mode=Text('auto'),scanType=Text(''),cap=native(50),reserve=native(100))
    for key,value in ks.EVAL_GLOBALS.items():env.setdefault(key,value)
    env.update(__fixture_Returned=ks.Returned,__fixture_Broken=ks.Broken,
               __fixture_AssertionError=AssertionError)
    return env,ship,state,events,nodes,world,cell


def record_current_track(env,world,cell):
    # Current path is completely mapped at the actual comparison epochs;
    # unchanged orbit must score0, with physical alternate tracks left blank.
    period=env['SHIP'].ORBIT.PERIOD
    start=env['TIME'].SECONDS+env['etaToTrueAnomaly'](-env['SHIP'].ORBIT.ARGUMENTOFPERIAPSIS)+2*period
    for j in range(384):
        ut=start+6*period*(j+.5)/384
        world['coverage'].add(cell(env['lmGroundGeoAt'](ut)))


def search(env,mode='auto',cap=100):
    return env['surveyOrbitSearch'](Text('HIRESALTIMETRY'),Text(mode),cap,300,harness.Record())


def check_drift_and_geometric_mirror(body):
    env,ship,_,events,nodes,world,cell=fixture(body=body)
    record_current_track(env,world,cell)
    result=search(env)
    assert result['OK'] and result['BEST']['MODE'] in ('raise-ap','lower-pe')
    nd=result['NODE'];assert env['HASNODE'] and sum(n.alive for n in nodes)==1
    assert .3<nd.DELTAV.MAG<10 and nd.DELTAV.MAG<2*math.sqrt(ship.BODY.MU/(ship.BODY.RADIUS+70000))*math.sin(rad(5))
    assert nd.ORBIT.PERIAPSIS>=63000 and nd.ORBIT.APOAPSIS<=77000
    assert nd.ORBIT.PERIOD!=ship.ORBIT.PERIOD
    env['fixture_remove'](nd)
    env['SHAPE_DV_CAP']=500
    mirror=search(env,'mirror',500)
    assert mirror['OK'];nd=mirror['NODE']
    assert abs(nd.ORBIT.INCLINATION-95)<1e-7 and abs(nd.ORBIT.LAN-40)<1e-7
    old_lat=max(abs(env['SHIP'].BODY.GEOPOSITIONOF(ship.ORBIT.state(1000+j*ship.ORBIT.PERIOD/400)[0]).LAT) for j in range(401))
    new_lat=max(abs(env['SHIP'].BODY.GEOPOSITIONOF(nd.ORBIT.state(nd.TIME+j*nd.ORBIT.PERIOD/400)[0]).LAT) for j in range(401))
    assert abs(old_lat-85)<1e-7 and abs(new_lat-85)<1e-7
    assert len(nodes)<=17 and world['query']<=384*19 #14 distinct trials, winner, then mirror/winner; two baselines.
    print('PASS: '+body+' real search prefers cheap period detuning over10deg mirror; mirror keeps LAN, speed/apsides and85deg latitude envelope')


def check_no_gain_failures_and_safety():
    env,ship,state,events,nodes,world,cell=fixture()
    world['all_done']=True
    assert not search(env)['OK'] and not env['HASNODE'] and state['shape_budget_spent']==10
    world['bad_map']=True
    assert search(env)['REASON']=='baseline-unavailable-or-deadline' and not env['HASNODE']
    world['bad_map']=False;world['all_done']=False;record_current_track(env,world,cell)
    for key,value in (('SHAPE_DV_CAP',.1),('SHAPE_TOTAL_DV_CAP',10),('SHAPE_RESERVE_DV',1000)):
        before=env[key];env[key]=value
        assert not search(env)['OK'] and not env['HASNODE'];env[key]=before
    env['STAGE'].DELTAV.VACUUM=0
    assert not search(env)['OK'] and not env['HASNODE'] # Never credit future stages.
    env['STAGE'].DELTAV.VACUUM=500
    assert not env['surveyOrbitAffordable'](float('nan'),100,100)
    assert not env['surveyOrbitAffordable'](.2999,100,100)
    for setting in ('ABORT','WARP'):
        env[setting]=1;assert not env['surveyOrbitIdle'](ship,False);env[setting]=0
    for setting in ('burn_pending','burn_started','hop_route_active'):
        state[setting]=True if setting=='hop_route_active' else Text('true')
        assert not env['surveyOrbitIdle'](ship,False);state.pop(setting)
    state['phase']=Text('XING');assert not env['surveyOrbitIdle'](ship,False)
    env,ship,_,_,_,_,_=fixture(body='Duna')
    assert env['surveyOrbitFloor']()==60000 # The existing SHAPE atmosphere guard.
    bad=NS(**vars(ship.ORBIT));bad.PERIOD=ship.ORBIT.PERIOD;bad.PERIAPSIS=54000;bad.APOAPSIS=70000
    assert not env['surveyOrbitSafe'](bad,0,1e29)
    env['SHAPE_MIN_PE']=72000
    assert env['surveyOrbitFloor']()==72000 and not env['surveyOrbitSafe'](ship.ORBIT,0,1e29)
    print('PASS: completed/unknown maps, mission caps/reserves, exhausted active stage, tiny/NaN burns, Abort/warp/pending operations and atmospheric floor retain safeguards')


def check_polar_caps_and_opposite_tilt():
    env,ship,_,_,_,world,cell=fixture()
    # Missing polar caps: mirrored inclination still cannot get above85deg.
    env['ADDONS'].SCANSAT.COMPLETEDSCANS=lambda obj,geo:Items([Text('HIRESALTIMETRY')]) if abs(geo.LAT)<85.2 else Items()
    assert not search(env,'mirror')['OK'] and not env['HASNODE']
    result=search(env,'polar')
    assert result['OK'] and abs(result['NODE'].ORBIT.INCLINATION-90)<1e-7
    env,ship,_,_,_,world,cell=fixture(inc=95);record_current_track(env,world,cell)
    result=search(env,'mirror')
    assert result['OK'] and abs(result['NODE'].ORBIT.INCLINATION-85)<1e-7
    print('PASS: polar-cap gaps require exactly polar, not the mirrored latitude envelope;95->85deg mirror also keeps the prograde/retrograde plane-change geometry correct')


def check_command_ledger(action):
    env,_,state,_,nodes,world,cell=fixture();record_current_track(env,world,cell)
    env['action']=Text(action);before=state.copy()
    harness.invoke(COMMAND,'_cmdScanorbit',env)
    assert env['HASNODE']==(action=='plan')
    assert all(state[k]==v for k,v in before.items() if k!='shape_budget_spent')
    if action=='plan':assert abs(state['shape_budget_spent']-10-env['NEXTNODE'].DELTAV.MAG)<1e-7
    else:assert state==before and not any(n.alive for n in nodes)
    print('PASS: actual command '+action+' preserves mission/science/phase and reserves only its retained plan in the shared SHAPE ledger')


def check_command_type_and_foreign_node():
    env,ship,state,events,nodes,world,cell=fixture();record_current_track(env,world,cell)
    harness.invoke(COMMAND,'_cmdScanorbit',env)
    assert any('type=HIRESALTIMETRY' in row for row in events)
    assert 'executeManeuver' not in COMMAND and not command_entrypoint_errors(COMMAND)
    # Foreign node must survive without even reading its propagation.
    foreign=NS();env.update(HASNODE=True,NEXTNODE=foreign,ALLNODES=Items([foreign]))
    harness.invoke(COMMAND,'_cmdScanorbit',env)
    assert env['NEXTNODE'] is foreign and env['HASNODE']
    print('PASS: live scan type selected without a burn/stage primitive; a pre-existing foreign node is preserved without propagation')


def check_generated_local_profile():
    # Ike/assist operations can have a generated local profile and no archive
    # profile. Replay it (plus runtime overrides) instead of dropping caps.
    env,_,state,_,_,world,cell=fixture();record_current_track(env,world,cell)
    loaded=[];env.update(bootArchivePath=lambda _:Text(''),RUNPATH=lambda path:loaded.append(str(path)))
    harness.invoke(COMMAND,'_cmdScanorbit',env)
    assert 'local_profile' in loaded and state['shape_budget_spent']==10 and not env['HASNODE']
    print('PASS: generated local profile plus runtime overrides retain mission caps when no archive profile exists')


def check_sampling_deadlines_and_context():
    env,ship,_,_,nodes,world,cell=fixture();record_current_track(env,world,cell)
    original=env['ADDONS'].SCANSAT.COMPLETEDSCANS
    def late(obj,geo):
        if env['HASNODE']:env['TIME'].SECONDS+=50
        return original(obj,geo)
    env['ADDONS'].SCANSAT.COMPLETEDSCANS=late
    assert not search(env)['OK'] and not env['HASNODE'] and not any(n.alive for n in nodes)
    env,ship,_,_,nodes,world,cell=fixture();record_current_track(env,world,cell)
    original=env['ADDONS'].SCANSAT.COMPLETEDSCANS
    def switch(obj,geo):
        if env['HASNODE']:env['KUNIVERSE'].ACTIVEVESSEL=NS()
        return original(obj,geo)
    env['ADDONS'].SCANSAT.COMPLETEDSCANS=switch
    assert not search(env)['OK'] and env['HASNODE'] and nodes[-1].alive
    print('PASS: expired sampling discards only owned probes; a vessel switch retains its preview for inspection')


def check_isolation():
    deps,phases,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    for roots in phases.values():assert 'survey_orbit' not in closure(roots,deps)
    assert 'VELOCITYAT' not in SOURCE and 'POSITIONAT(SHIP, ut)' in function_body(GROUND,'lmGroundGeoAt')
    assert 'executeManeuver' not in SOURCE and 'STAGE.' not in SOURCE
    print('PASS: shared proven ground projection, command-only search; no new library in flight bands, automatic burn/stage or mission rewrite')


def check_deferred_native_node_removal():
    env,_,_,events,nodes,world,cell=fixture();record_current_track(env,world,cell)
    remove=env['fixture_remove'];pending=[]
    def deferred(nd):
        assert env['HASNODE'] and nd is env['NEXTNODE']
        pending.append(nd)
    def tick(dt):
        if dt>0 and pending:remove(pending.pop())
    env.update(fixture_remove=deferred,fixture_wait=tick)
    # Reproduce the observed old sequencing: immediate next context check
    # still sees our old node; only yielding publishes its removal.
    nd=env['NODE'](2000,0,0,1);env['fixture_add'](nd);deferred(nd)
    assert not env['surveyOrbitIdle'](env['SHIP'],False)
    tick(.1)
    result=search(env)
    assert result['OK'] and len(nodes)>=6 and not pending
    assert sum(n.alive for n in nodes)==1
    # A real context change remains distinct from a timing deadline, with
    # the flags included in the archived report for native falsification.
    env['fixture_remove'](result['NODE']);tick(.1);env['ABORT']=True
    assert env['_surveyOrbitStop'](env['SHIP'],1e9,1e9,harness.Record())=='context-changed'
    assert any('scanorbit context' in row and 'abort=True' in row for row in events)
    env['ABORT']=False
    assert env['_surveyOrbitStop'](env['SHIP'],0,1e9,harness.Record())=='game-deadline'
    assert env['_surveyOrbitStop'](env['SHIP'],1e9,0,harness.Record())=='wall-deadline'
    print('PASS: native-like deferred REMOVE reproduces old immediate context rejection; settled cleanup evaluates subsequent candidates and preserves explicit context/game/wall diagnostics')


if __name__=='__main__':
    check_drift_and_geometric_mirror('Minmus')
    check_drift_and_geometric_mirror('Duna')
    check_no_gain_failures_and_safety()
    check_polar_caps_and_opposite_tilt()
    check_command_ledger('preview')
    check_command_ledger('plan')
    check_command_type_and_foreign_node()
    check_generated_local_profile()
    check_sampling_deadlines_and_context()
    check_isolation()
    check_deferred_native_node_removal()
